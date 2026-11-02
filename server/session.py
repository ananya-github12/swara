"""Persistent live voice sessions.

FastAPI owns the browser-facing async WebSocket. Sarvam's installed SDK exposes
sync streaming sockets, so small worker threads own those sockets and bridge
messages through thread-safe queues without blocking the application event
loop.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import queue
import threading
from contextlib import suppress
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from api_auth import vault_repository_for_websocket
from config import require
from conversation_prompts import (
    SESSION_PERSONA,
    build_opening_prompt,
    build_observation_prompt,
    build_turn_prompt,
)
from execution_loop import ExecutionLoop, PendingActionBatch
from repositories.vault import VaultRepository
from schemas import ActionResult, ContextItem, PageContext
from session_schemas import (
    AgentCancel,
    AUDIO_SAMPLE_RATE,
    AgentPause,
    AgentResume,
    AgentSkip,
    AgentObservation,
    VAD_SETTINGS,
    SessionStart,
    Turn,
    TurnResult,
)


logger = logging.getLogger("swara.session")

router = APIRouter()

# Conversation is latency-bound in a way batch planning is not: one second of
# thinking reads as responsive, three reads as broken. flash-lite answers in
# ~1s against ~3.4s for the larger flash models, which matters more here than
# the extra reasoning headroom. Override with SWARA_SESSION_MODEL.
SESSION_MODEL = os.environ.get("SWARA_SESSION_MODEL", "gemini-3.1-flash-lite")

STT_MODEL = "saaras:v3"
TTS_MODEL = "bulbul:v3"
TTS_SPEAKER = "advait"
TTS_DEFAULT_LANGUAGE = "en-IN"
TTS_MIME_TYPE = "audio/mpeg"  # canonical; MediaSource rejects "audio/mp3"


def _sarvam_client() -> Any:
    try:
        from sarvamai import SarvamAI
    except ImportError as exc:
        raise RuntimeError(
            "Sarvam SDK is unavailable. Install server/requirements.txt."
        ) from exc
    return SarvamAI(api_subscription_key=require("SARVAM_API_KEY"))


def _context_for_session(repository: VaultRepository, session_id: str) -> list[ContextItem]:
    """Load active context through the authenticated RLS Vault repository."""
    items = [
        *repository.list_context_items(limit=200, scope="persistent"),
        *[row for row in repository.list_context_items(limit=200, scope="session") if row.get("browser_session_id") == session_id],
        *[row for row in repository.list_context_items(limit=200, scope="task") if row.get("task_id") == session_id],
    ]
    projected = [ContextItem.model_validate({
        "id": row.get("id"), "type": row.get("type"), "category": row.get("category"),
        "key": row.get("key"), "value": row.get("value"), "source": row.get("source_type"),
        "source_type": row.get("source_type"), "scope": row.get("scope"),
        "session_id": row.get("browser_session_id") or row.get("task_id"),
        "document_id": row.get("source_document_id"),
    }) for row in items]
    seen: set[str] = set()
    unique: list[ContextItem] = []
    for item in projected:
        marker = item.id or f"{item.scope}:{item.session_id}:{item.key}:{item.value}"
        if marker not in seen:
            seen.add(marker)
            unique.append(item)
    return unique


def _apply_memory_update(repository: VaultRepository, update: Any) -> None:
    """Persist accepted persistent memory through the append-only Vault API."""
    if update.scope != "persistent":
        return
    active = next((row for row in repository.list_context_items(limit=200, scope="persistent") if row.get("key") == update.key), None)
    if active is None:
        repository.insert_first_context_item({
            "type": update.type, "key": update.key, "value": update.value,
            "category": "general", "scope": "persistent", "source_type": "voice",
        })
    elif active.get("value") != update.value:
        repository.append_correction(str(active["id"]), update.value)


def run_turn(
    *,
    session_id: str,
    page: PageContext,
    context_items: list[ContextItem],
    history: list[Turn],
    utterance: str | None = None,
    opening: bool = False,
    observation: str | None = None,
    step: int | None = None,
    max_steps: int | None = None,
    memory_repository: VaultRepository | None = None,
) -> TurnResult:
    """Run one schema-constrained Gemini turn and persist learned memory."""
    try:
        from google import genai
        from google.genai import types
    except ImportError as exc:
        raise RuntimeError(
            "Google Gen AI SDK is unavailable. Install server/requirements.txt."
        ) from exc

    if opening:
        prompt = build_opening_prompt(page, context_items)
    elif observation is not None:
        prompt = build_observation_prompt(
            page,
            context_items,
            history,
            observation,
            step=step or 1,
            max_steps=max_steps or 1,
        )
    else:
        if utterance is None:
            raise ValueError("A conversational turn requires an utterance.")
        prompt = build_turn_prompt(page, context_items, history, utterance)

    client = genai.Client(api_key=require("GOOGLE_API_KEY"))
    try:
        response = client.models.generate_content(
            model=SESSION_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=SESSION_PERSONA,
                response_mime_type="application/json",
                response_schema=TurnResult,
                # One attempt. The default backoff silently turns an exhausted
                # quota into seconds of dead air per turn, which is felt as the
                # agent being slow rather than as the hard failure it is.
                http_options=types.HttpOptions(
                    retry_options=types.HttpRetryOptions(attempts=1)
                ),
            ),
        )
    except Exception as exc:
        if "RESOURCE_EXHAUSTED" in str(exc) or "429" in str(exc):
            raise RuntimeError(
                f"The {SESSION_MODEL} quota is exhausted. Enable billing on the "
                "Google API key, or set SWARA_SESSION_MODEL to a model with "
                "remaining quota."
            ) from exc
        raise
    result = TurnResult.model_validate_json(response.text or "")

    # Drop actions naming ids the page never offered. Models will invent a
    # plausible id for a question they can see but have no handle on — a
    # Google Form's radio groups, for instance, are div[role=radio] and were
    # invisible to the extractor. Executing those does nothing while the agent
    # cheerfully reports success, so discard them before they are announced.
    result.actions = _safe_actions(page, result.actions)

    # Browser observations describe a transient DOM transition, not new user
    # information. Never let an autonomous follow-up step write to the Vault.
    if observation is not None:
        result.memory_updates = []
        return result

    if memory_repository is None and result.memory_updates:
        raise RuntimeError("Authenticated Vault repository is required for memory updates")
    for update in result.memory_updates:
        _apply_memory_update(memory_repository, update)
    return result


_IRREVERSIBLE_CONTROL = re.compile(
    r"\b(?:submit|send|pay|payment|purchase|buy|delete|remove|cancel|"
    r"apply|place\s+order|confirm\s+order)\b",
    re.IGNORECASE,
)
_BROWSER_ACTIONS = {
    "open_url",
    "navigate",
    "open_tab",
    "switch_tab",
    "close_tab",
    "go_back",
    "go_forward",
    "wait_for_page",
}


def _safe_actions(page: PageContext, actions: list[Any]) -> list[Any]:
    """Keep model output constrained to this page and reversible operations.

    The extension independently refuses submit controls, but this is a
    server-side safety boundary: no model response can put an irreversible
    action on the wire, including on later agent-loop steps.
    """
    capabilities = set(page.capabilities or [])
    browser_navigation = "browserNavigation" in capabilities
    known_fields = {field.field_id for field in page.fields}
    controls = {control.control_id: control for control in page.controls}
    known = known_fields | set(controls)
    kept = []
    for action in actions:
        action_name = action.action
        if action_name in _BROWSER_ACTIONS:
            # `open_url` is an established capability. The other navigation
            # primitives remain opt-in until the browser explicitly advertises
            # its multi-page executor.
            allowed = (
                action_name == "open_url" and "openUrl" in capabilities
            ) or (action_name != "open_url" and browser_navigation)
            if not allowed:
                logger.warning("Dropped unavailable browser action: %s", action_name)
                continue
            kept.append(action)
            continue
        if action.field_id not in known:
            logger.warning("Dropped action for unknown target: %s", action.field_id)
            continue
        control = controls.get(action.field_id)
        if action_name == "click" and control is None:
            logger.warning("Dropped click for non-control target: %s", action.field_id)
            continue
        if action_name == "click" and control is not None and (
            control.role == "submit" or _IRREVERSIBLE_CONTROL.search(control.label)
        ):
            logger.warning("Dropped irreversible click: %s", control.label)
            continue
        kept.append(action)
    return kept



SPEECH_ONLY_SUFFIX = """

## This channel is speech only

Return only the words to say aloud. No JSON, no field names, no lists of
actions. A separate pass handles what changes on the page, so describe what you
are doing in natural speech and nothing more."""

# Sentence ends, including the Devanagari danda so Hindi splits correctly.
_SENTENCE_END = re.compile(r"(?<=[.!?।])\s+")

# Markup the speech channel is told never to produce, and occasionally does
# anyway: `<action type="fill" .../>`, stray JSON, fenced blocks.
_MARKUP = re.compile(r"</?[A-Za-z][^<>]*/?>|```[^`]*```|```")
_SPEAKABLE = re.compile(r"[^\W\d_]", re.UNICODE)


def speakable(sentence: str) -> str | None:
    """Strip model markup, or reject the sentence if nothing sayable is left.

    The spoken reply is generated by a separate pass that is instructed to emit
    words only, but instructions are not a guarantee. An action tag that slips
    through gets read aloud verbatim, and a sentence made *entirely* of markup
    is rejected outright by Sarvam ("must contain at least one character from
    the allowed languages"), which surfaces to the user as a synthesis failure
    on a turn that was otherwise fine.
    """
    cleaned = _MARKUP.sub(" ", sentence)
    cleaned = " ".join(cleaned.split())
    return cleaned if cleaned and _SPEAKABLE.search(cleaned) else None


class _LLMStreamBridge:
    """Stream Gemini's spoken reply sentence by sentence.

    Waiting for a complete response before speaking costs a second or more of
    dead air on every turn, which is most of what makes a voice agent feel
    slow. Sentences are emitted as they finish so synthesis can start on the
    first one while the rest is still being written.
    """

    def __init__(self, loop, prompt: str) -> None:
        self._loop = loop
        self._prompt = prompt
        self.events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        self._stopped = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name="swara-llm-stream", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stopped.set()

    def _publish(self, kind: str, payload: Any = None) -> None:
        with suppress(RuntimeError):
            self._loop.call_soon_threadsafe(self.events.put_nowait, (kind, payload))

    def _run(self) -> None:
        try:
            from google import genai
            from google.genai import types

            client = genai.Client(api_key=require("GOOGLE_API_KEY"))
            stream = client.models.generate_content_stream(
                model=SESSION_MODEL,
                contents=self._prompt + SPEECH_ONLY_SUFFIX,
                config=types.GenerateContentConfig(
                    system_instruction=SESSION_PERSONA,
                    http_options=types.HttpOptions(
                        retry_options=types.HttpRetryOptions(attempts=1)
                    ),
                ),
            )
            buffer = ""
            for chunk in stream:
                if self._stopped.is_set():
                    break
                buffer += getattr(chunk, "text", "") or ""
                parts = _SENTENCE_END.split(buffer)
                # The trailing fragment may still be mid-sentence, so hold it.
                for sentence in parts[:-1]:
                    if sentence.strip():
                        self._publish("sentence", sentence.strip())
                buffer = parts[-1]
            if buffer.strip() and not self._stopped.is_set():
                self._publish("sentence", buffer.strip())
        except Exception as exc:
            if "RESOURCE_EXHAUSTED" in str(exc) or "429" in str(exc):
                self._publish(
                    "error",
                    f"The {SESSION_MODEL} quota is exhausted. Enable billing on "
                    "the Google API key.",
                )
            else:
                self._publish("error", str(exc))
        finally:
            self._publish("done")


def _field(value: Any, name: str, default: Any = None) -> Any:
    if isinstance(value, dict):
        return value.get(name, default)
    return getattr(value, name, default)


def _close_sdk_socket(socket: Any) -> None:
    """Close an SDK socket even though v0.1.28 exposes no public close method."""
    close = getattr(socket, "close", None)
    if callable(close):
        with suppress(Exception):
            close()
        return
    raw_socket = getattr(socket, "_websocket", None)
    close = getattr(raw_socket, "close", None)
    if callable(close):
        with suppress(Exception):
            close()


class _STTBridge:
    """Own Sarvam STT's sync context manager and relay its events to asyncio."""

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        events: asyncio.Queue[tuple[str, Any]],
    ) -> None:
        self._loop = loop
        self._events = events
        self._commands: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=256)
        self._stopped = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="swara-sarvam-stt",
            daemon=True,
        )
        self._socket: Any = None

    def start(self) -> None:
        self._thread.start()

    def send_audio(self, audio_base64: str) -> bool:
        if self._stopped.is_set():
            return False
        try:
            self._commands.put_nowait(("audio", audio_base64))
        except queue.Full:
            return False
        return True

    def stop(self) -> None:
        if self._stopped.is_set():
            return
        try:
            self._commands.put_nowait(("stop", None))
        except queue.Full:
            # Preserve prompt shutdown over old audio if the sender fell behind.
            with suppress(queue.Empty):
                self._commands.get_nowait()
            with suppress(queue.Full):
                self._commands.put_nowait(("stop", None))

    def join(self, timeout: float = 2.0) -> None:
        if self._thread.is_alive():
            self._thread.join(timeout)

    def _publish(self, kind: str, payload: Any = None) -> None:
        with suppress(RuntimeError):
            self._loop.call_soon_threadsafe(
                self._events.put_nowait, (kind, payload)
            )

    def _read(self, socket: Any) -> None:
        try:
            for response in socket:
                self._publish("stt.message", response)
        except Exception as exc:
            if not self._stopped.is_set():
                self._publish("stt.error", str(exc))
        finally:
            with suppress(queue.Full):
                self._commands.put_nowait(("reader.done", None))

    def _run(self) -> None:
        try:
            client = _sarvam_client()
            with client.speech_to_text_streaming.connect(
                language_code="unknown",
                model=STT_MODEL,
                mode="transcribe",
                input_audio_codec="pcm_s16le",
                sample_rate=str(AUDIO_SAMPLE_RATE),
                **VAD_SETTINGS,
            ) as socket:
                self._socket = socket
                reader = threading.Thread(
                    target=self._read,
                    args=(socket,),
                    name="swara-sarvam-stt-reader",
                    daemon=True,
                )
                reader.start()

                while True:
                    command, payload = self._commands.get()
                    if command in {"stop", "reader.done"}:
                        if command == "stop":
                            with suppress(Exception):
                                socket.flush()
                        break
                    if command == "audio":
                        # `encoding` here is a fixed literal and rejects
                        # anything else; the real codec is declared once at
                        # connect() via input_audio_codec. Passing the codec
                        # per chunk raises on the first frame and kills this
                        # thread, after which every send reports "busy".
                        socket.transcribe(
                            payload,
                            encoding="audio/wav",
                            sample_rate=AUDIO_SAMPLE_RATE,
                        )
        except Exception as exc:
            if not self._stopped.is_set():
                self._publish("stt.error", str(exc))
        finally:
            self._stopped.set()
            if self._socket is not None:
                _close_sdk_socket(self._socket)
            self._publish("stt.closed")


class _TTSBridge:
    """Stream a turn's speech through ONE Sarvam TTS connection.

    Sentences are pushed in as the model writes them and synthesised over a
    single socket. Opening a connection per sentence looks equivalent but is
    not: each connect costs seconds, and a multi-sentence reply spent longer
    negotiating sockets than speaking.
    """

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        language: str,
        text: str | None = None,
    ) -> None:
        self.events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        self._loop = loop
        self._language = language
        self._pending: queue.Queue[str | None] = queue.Queue()
        self._interrupted = threading.Event()
        self._socket: Any = None
        self._thread = threading.Thread(
            target=self._run, name="swara-sarvam-tts", daemon=True
        )
        if text:
            self.push(text)
            self.finish()

    @property
    def interrupted(self) -> bool:
        return self._interrupted.is_set()

    def start(self) -> None:
        self._thread.start()

    def push(self, text: str) -> None:
        """Queue another sentence onto the open connection."""
        if text.strip() and not self._interrupted.is_set():
            self._pending.put(text)

    def finish(self) -> None:
        """No more sentences; flush and let the socket complete."""
        self._pending.put(None)

    def interrupt(self) -> None:
        """Suppress queued audio now and close the blocking socket in parallel."""
        self._interrupted.set()
        self._pending.put(None)
        socket = self._socket
        if socket is not None:
            threading.Thread(
                target=_close_sdk_socket,
                args=(socket,),
                name="swara-sarvam-tts-close",
                daemon=True,
            ).start()

    def _publish(self, kind: str, payload: Any = None) -> None:
        if kind == "audio" and self._interrupted.is_set():
            return
        with suppress(RuntimeError):
            self._loop.call_soon_threadsafe(self.events.put_nowait, (kind, payload))

    def _read(self, socket: Any) -> None:
        try:
            for response in socket:
                if self._interrupted.is_set():
                    break
                response_type = str(_field(response, "type", ""))
                data = _field(response, "data")
                if response_type == "audio":
                    audio = _field(data, "audio")
                    mime_type = _field(data, "content_type", TTS_MIME_TYPE)
                    if isinstance(audio, str) and audio:
                        self._publish(
                            "audio",
                            {
                                "data": audio,
                                "mimeType": (
                                    mime_type
                                    if isinstance(mime_type, str)
                                    else TTS_MIME_TYPE
                                ),
                            },
                        )
                elif response_type == "event":
                    if _field(data, "event_type") == "final":
                        break
                elif response_type == "error":
                    message = _field(data, "message", "Speech synthesis failed.")
                    raise RuntimeError(str(message))
        except Exception as exc:
            if not self._interrupted.is_set():
                self._publish("error", str(exc))
        finally:
            self._publish("done")

    def _run(self) -> None:
        try:
            client = _sarvam_client()
            with client.text_to_speech_streaming.connect(
                model=TTS_MODEL,
                send_completion_event="true",
            ) as socket:
                self._socket = socket
                if self._interrupted.is_set():
                    return
                socket.configure(
                    target_language_code=self._language,
                    speaker=TTS_SPEAKER,
                )
                reader = threading.Thread(
                    target=self._read, args=(socket,),
                    name="swara-sarvam-tts-reader", daemon=True,
                )
                reader.start()

                while True:
                    text = self._pending.get()
                    if text is None or self._interrupted.is_set():
                        break
                    socket.convert(text)
                with suppress(Exception):
                    socket.flush()
                reader.join(timeout=30)
        except Exception as exc:
            if not self._interrupted.is_set():
                self._publish("error", str(exc))
                self._publish("done")


def _target_language(language: str | None, text: str) -> str:
    if language and language != "unknown":
        return language
    if any("\u0900" <= character <= "\u097f" for character in text):
        return "hi-IN"
    return TTS_DEFAULT_LANGUAGE


def _action_result_text(results: list[ActionResult]) -> str:
    details = []
    for result in results:
        destination = ""
        if result.verification is not None:
            verified = result.verification
            bits = [
                value
                for value in (verified.title, verified.url)
                if value
            ]
            if verified.tab_id is not None:
                bits.append(f"controlled tab {verified.tab_id}")
            if bits:
                destination = " -> " + " — ".join(bits)
        if result.ok:
            details.append(f"{result.field_id}: succeeded{destination}")
        else:
            reason = f" ({result.error})" if result.error else ""
            details.append(f"{result.field_id}: failed{reason}{destination}")
    return "Action results from the page: " + "; ".join(details)


class _LiveSession:
    def __init__(self, websocket: WebSocket) -> None:
        self.websocket = websocket
        self.events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        self.send_lock = asyncio.Lock()
        self.session_id = ""
        self.page: PageContext | None = None
        self.context_items: list[ContextItem] = []
        self.history: list[Turn] = []
        self.last_language: str | None = None
        self.receiver_task: asyncio.Task[None] | None = None
        self.response_task: asyncio.Task[None] | None = None
        self.active_tts: _TTSBridge | None = None
        self.stt: _STTBridge | None = None
        self.execution = ExecutionLoop()
        self.generation = 0
        self.started = False
        self.peer_disconnected = False
        self.repository: VaultRepository | None = None

    async def send(self, message: dict[str, Any]) -> None:
        async with self.send_lock:
            await self.websocket.send_json(message)

    async def _receive(self) -> None:
        try:
            while True:
                message = await self.websocket.receive_json()
                await self.events.put(("client.message", message))
        except WebSocketDisconnect:
            await self.events.put(("client.disconnected", None))
        except Exception as exc:
            await self.events.put(("client.error", str(exc)))

    async def _start(self, message: dict[str, Any]) -> None:
        start = SessionStart.model_validate(message)
        self.session_id = start.session_id
        self.page = start.page
        self.repository = vault_repository_for_websocket(self.websocket)
        self.context_items = await asyncio.to_thread(
            _context_for_session, self.repository, self.session_id
        )
        self.started = True

        loop = asyncio.get_running_loop()
        self.stt = _STTBridge(loop, self.events)
        self.stt.start()
        await self._begin_response(opening=True)

    async def _cancel_response(self) -> None:
        task = self.response_task
        if task is None or task.done():
            return
        if self.active_tts is not None:
            self.active_tts.interrupt()
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        self.response_task = None

    async def _begin_response(
        self,
        *,
        utterance: str | None = None,
        opening: bool = False,
        observation: str | None = None,
        step: int | None = None,
    ) -> None:
        await self._cancel_response()
        # A new person-authored turn always supersedes any unfinished browser
        # run. An interrupt only stops speech; it does not retroactively
        # cancel browser actions the user has already seen and approved.
        if utterance is not None and observation is None:
            self.execution.cancel()
        self.generation += 1
        generation = self.generation
        history_for_prompt = list(self.history)
        if utterance is not None:
            self.history.append(Turn(role="user", text=utterance))
        self.response_task = asyncio.create_task(
            self._respond(
                generation=generation,
                history_for_prompt=history_for_prompt,
                utterance=utterance,
                opening=opening,
                observation=observation,
                step=step,
            )
        )

    async def _begin_observation_response(self, observation: str, step: int) -> None:
        """Re-plan only after the browser has atomically refreshed its view."""
        await self._begin_response(
            observation=observation,
            step=step,
        )

    async def _respond(
        self,
        *,
        generation: int,
        history_for_prompt: list[Turn],
        utterance: str | None,
        opening: bool,
        observation: str | None,
        step: int | None,
    ) -> None:
        try:
            if self.page is None:
                raise RuntimeError("The live session has no page context.")
            page = self.page
            context_items = list(self.context_items)
            await self.send({"type": "state", "state": "thinking"})

            # Two calls run at once. The streaming one starts speaking on its
            # first finished sentence, so audio begins in well under a second
            # instead of after the whole reply exists. The structured one
            # decides what changes on the page and lands whenever it is ready,
            # typically while the agent is still talking.
            structured = asyncio.create_task(
                asyncio.to_thread(
                    run_turn,
                    session_id=self.session_id,
                    page=page,
                    context_items=context_items,
                    history=history_for_prompt,
                    utterance=utterance,
                    opening=opening,
                    observation=observation,
                    step=step,
                    max_steps=self.execution.max_steps,
                    memory_repository=self.repository,
                )
            )
            spoken = await self._stream_speech(
                generation=generation,
                page=page,
                context_items=context_items,
                history_for_prompt=history_for_prompt,
                utterance=utterance,
                opening=opening,
                observation=observation,
                step=step,
            )

            try:
                result = await structured
            except Exception:
                structured.cancel()
                raise
            if generation != self.generation:
                return
            # The spoken words are what the user actually heard, so they are
            # what goes into history and onto the transcript.
            if spoken:
                result.speech = spoken

            self.history.append(
                Turn(role="agent", text=result.speech, actions=result.actions)
            )
            # The streaming pass already emitted each sentence; resending the
            # whole reply here would show it twice.
            if not spoken:
                await self.send({"type": "agent.text", "text": result.speech})
            await self.send(
                {
                    "type": "context.used",
                    "relevant": [
                        item.model_dump(by_alias=True, exclude_none=True)
                        for item in result.relevant_context
                    ],
                    "excluded": [
                        item.model_dump(by_alias=True, exclude_none=True)
                        for item in result.excluded_context
                    ],
                }
            )
            if result.memory_updates:
                await self.send(
                    {
                        "type": "memory.learned",
                        "updates": [
                            update.model_dump(by_alias=True, exclude_none=True)
                            for update in result.memory_updates
                        ],
                    }
                )
                try:
                    self.context_items = await asyncio.to_thread(
                        _context_for_session, self.repository, self.session_id
                    )
                except Exception as exc:
                    await self.send(
                        {
                            "type": "error",
                            "message": f"Memory was saved but context refresh failed: {exc}",
                            "fatal": False,
                        }
                    )
            if result.question:
                await self.send(
                    {"type": "agent.question", "text": result.question}
                )

            # Act before speaking, not after. Speech takes seconds; holding the
            # page until it finishes means hearing "I've filled that in" while
            # staring at an unchanged form. Filling first also means a barge-in
            # cannot strand actions the agent already announced.
            awaiting_observation = await self._emit_actions(
                result.actions,
                opening=opening,
                observation=observation,
            )

            if not awaiting_observation:
                if observation is not None:
                    # No further reversible step was proposed. A late or
                    # duplicated observation must not resurrect this run.
                    self.execution.cancel()
                await self.send(
                    {
                        "type": "state",
                        "state": "idle" if result.done else "listening",
                    }
                )
        except asyncio.CancelledError:
            if self.active_tts is not None:
                self.active_tts.interrupt()
            raise
        except Exception as exc:
            if generation == self.generation:
                await self.send(
                    {"type": "error", "message": str(exc), "fatal": False}
                )
                await self.send({"type": "state", "state": "listening"})

    async def _emit_actions(
        self,
        actions: list[Any],
        *,
        opening: bool,
        observation: str | None,
    ) -> bool:
        """Send one bounded action batch and wait for its atomic observation."""
        if not actions or opening:
            return False

        if observation is None:
            self.execution.start()
        if not self.execution.can_continue:
            # A cancelled run or step cap is a hard local safety boundary,
            # independent of whatever the model has just returned.
            await self.send(
                {
                    "type": "agent.question",
                    "text": "I’ve paused here. Tell me if you’d like me to continue.",
                }
            )
            return False

        batch: PendingActionBatch = self.execution.issue(actions)
        await self.send({"type": "state", "state": "acting"})
        await self.send(
            {
                "type": "agent.actions",
                "batchId": batch.batch_id,
                "step": batch.step,
                "maxSteps": self.execution.max_steps,
                "actions": [
                    action.model_dump(by_alias=True, exclude_none=True)
                    for action in batch.actions
                ],
            }
        )
        return True

    async def _stream_speech(
        self,
        *,
        generation: int,
        page: PageContext,
        context_items: list[ContextItem],
        history_for_prompt: list[Turn],
        utterance: str | None,
        opening: bool,
        observation: str | None,
        step: int | None,
    ) -> str:
        """Speak Gemini's reply as it is written, returning what was said."""
        prompt = (
            build_opening_prompt(page, context_items)
            if opening
            else build_observation_prompt(
                page,
                context_items,
                history_for_prompt,
                observation,
                step=step or 1,
                max_steps=self.execution.max_steps,
            )
            if observation is not None
            else build_turn_prompt(
                page, context_items, history_for_prompt, utterance or ""
            )
        )
        loop = asyncio.get_running_loop()
        llm = _LLMStreamBridge(loop, prompt)
        llm.start()

        # One TTS connection for the whole turn; sentences are pushed in as
        # they are written.
        tts = _TTSBridge(loop, _target_language(self.last_language, ""))
        self.active_tts = tts
        tts.start()

        said: list[str] = []
        spoke_any = False
        pump: asyncio.Task[None] | None = None

        async def pump_audio() -> None:
            while True:
                kind, payload = await tts.events.get()
                if kind == "done":
                    return
                if kind == "error":
                    await self.send(
                        {
                            "type": "error",
                            "message": f"Speech synthesis failed: {payload}",
                            "fatal": False,
                        }
                    )
                    return
                if kind == "audio" and generation == self.generation and not tts.interrupted:
                    await self.send(
                        {
                            "type": "agent.audio",
                            "data": payload["data"],
                            "mimeType": payload["mimeType"],
                        }
                    )

        try:
            while True:
                kind, payload = await llm.events.get()
                if kind == "done":
                    break
                if kind == "error":
                    await self.send(
                        {"type": "error", "message": str(payload), "fatal": False}
                    )
                    break
                if kind != "sentence" or generation != self.generation:
                    continue

                sentence = speakable(str(payload))
                if sentence is None:
                    continue
                said.append(sentence)
                # Words before audio, so the transcript leads the voice.
                await self.send({"type": "agent.text", "text": sentence})
                if not spoke_any:
                    await self.send({"type": "state", "state": "speaking"})
                    pump = asyncio.create_task(pump_audio())
                    spoke_any = True
                tts.push(sentence)
        finally:
            llm.stop()
            tts.finish()
            if pump is not None:
                with suppress(asyncio.CancelledError):
                    await pump
            tts.interrupt()
            if self.active_tts is tts:
                self.active_tts = None
            if generation == self.generation and spoke_any:
                await self.send({"type": "agent.audio.end"})

        return " ".join(said)

    async def _speak_sentence(
        self, generation: int, text: str, language: str
    ) -> None:
        """Synthesise one sentence, streaming its audio out as it arrives."""
        if not text.strip():
            return
        bridge = _TTSBridge(asyncio.get_running_loop(), text, language)
        self.active_tts = bridge
        bridge.start()
        try:
            while True:
                kind, payload = await bridge.events.get()
                if kind == "done":
                    break
                if kind == "error":
                    await self.send(
                        {
                            "type": "error",
                            "message": f"Speech synthesis failed: {payload}",
                            "fatal": False,
                        }
                    )
                    break
                if (
                    kind == "audio"
                    and generation == self.generation
                    and not bridge.interrupted
                ):
                    await self.send(
                        {
                            "type": "agent.audio",
                            "data": payload["data"],
                            "mimeType": payload["mimeType"],
                        }
                    )
        finally:
            bridge.interrupt()
            if self.active_tts is bridge:
                self.active_tts = None

    async def _speak(
        self,
        generation: int,
        text: str,
        language: str,
    ) -> None:
        await self.send({"type": "state", "state": "speaking"})
        if not text.strip():
            await self.send({"type": "agent.audio.end"})
            return

        bridge = _TTSBridge(asyncio.get_running_loop(), text, language)
        self.active_tts = bridge
        bridge.start()
        try:
            while True:
                kind, payload = await bridge.events.get()
                if kind == "done":
                    break
                if kind == "error":
                    await self.send(
                        {
                            "type": "error",
                            "message": f"Speech synthesis failed: {payload}",
                            "fatal": False,
                        }
                    )
                    break
                if (
                    kind == "audio"
                    and generation == self.generation
                    and not bridge.interrupted
                ):
                    await self.send(
                        {
                            "type": "agent.audio",
                            "data": payload["data"],
                            "mimeType": payload["mimeType"],
                        }
                    )
        finally:
            bridge.interrupt()
            if self.active_tts is bridge:
                self.active_tts = None
            if generation == self.generation:
                await self.send({"type": "agent.audio.end"})

    async def _interrupt_tts(self) -> None:
        if self.active_tts is not None:
            self.active_tts.interrupt()

    def _record_action_results(self, results: list[ActionResult]) -> str:
        """Attach browser-verified results to history exactly once."""
        for turn in reversed(self.history):
            if turn.role == "agent" and turn.actions and not turn.results:
                turn.results.extend(results)
                break
        observation = _action_result_text(results)
        self.history.append(
            Turn(role="user", text=observation, results=results)
        )
        return observation

    async def _handle_observation(self, message: dict[str, Any]) -> None:
        """Consume an action batch result and its refreshed page atomically."""
        observation = AgentObservation.model_validate(message)
        pending = self.execution.accept_observation(
            observation.batch_id, observation.results
        )
        # Do not make the new page visible to the agent unless its results
        # match the exact batch it issued. That rejects stale tab updates and
        # replayed results without allowing either to steer the next plan.
        self.page = observation.page
        observation_text = self._record_action_results(observation.results)

        # A pause does not discard verified evidence for actions that were
        # already sent, but it does prevent that evidence from autonomously
        # launching the next planning turn.
        if self.execution.paused:
            return

        if self.execution.at_limit:
            self.execution.cancel()
            await self.send(
                {
                    "type": "agent.question",
                    "text": (
                        "I’ve reached the safety limit for this task. "
                        "Please tell me if you’d like to continue from here."
                    ),
                }
            )
            await self.send({"type": "state", "state": "listening"})
            return

        await self._begin_observation_response(
            observation_text,
            step=pending.step + 1,
        )

    async def _handle_pause(self, message: dict[str, Any]) -> None:
        """Pause exactly once without invalidating an already-sent batch."""
        AgentPause.model_validate(message)
        if not self.execution.pause():
            return
        # Prevent an in-progress model response from racing the control and
        # issuing its next batch.  `pause()` is set first, so `_emit_actions`
        # has the same guard even if cancellation reaches it late.
        await self._cancel_response()
        await self.send({"type": "state", "state": "listening"})
        await self.send(
            {
                "type": "agent.question",
                "text": "Paused. I’ll keep the current page state and wait for you to resume.",
            }
        )

    async def _handle_resume(self, message: dict[str, Any]) -> None:
        """Resume a run only against a page freshly supplied by the client."""
        control = AgentResume.model_validate(message)
        if not self.execution.resume():
            return

        self.page = control.page
        # If a batch was outstanding when the user paused, its matching atomic
        # observation remains the required fresh evidence.  Otherwise this
        # resume frame supplies the snapshot we will replan against.
        self.execution.record_fresh_page()
        if self.execution.pending is not None:
            await self.send({"type": "state", "state": "acting"})
            return

        await self._begin_observation_response(
            "The user resumed the task with this freshly extracted page.",
            step=self.execution.completed_steps + 1,
        )

    async def _handle_cancel(self, message: dict[str, Any]) -> None:
        """Cancel idempotently and make every late result untrusted."""
        AgentCancel.model_validate(message)
        if not self.execution.cancel():
            return
        await self._cancel_response()
        await self.send({"type": "state", "state": "idle"})

    async def _handle_skip(self, message: dict[str, Any]) -> None:
        """Discard an unexecuted batch; it never becomes a successful result."""
        control = AgentSkip.model_validate(message)
        if not self.execution.skip_current_step():
            return

        # The skipped batch is intentionally not passed to
        # `_record_action_results`: the browser has not verified success and
        # the next model turn must not narrate it as completed.
        self.page = control.page
        self.execution.record_fresh_page()
        if self.execution.paused:
            return
        await self._begin_observation_response(
            "The user skipped the current action batch. Replan from this freshly extracted page without assuming any skipped action succeeded.",
            step=self.execution.completed_steps + 1,
        )

    async def _handle_stt(self, response: Any) -> None:
        response_type = str(_field(response, "type", ""))
        data = _field(response, "data")
        if response_type == "events":
            signal = str(_field(data, "signal_type", ""))
            if signal == "START_SPEECH":
                # Set the interrupt flag before sending the boundary so no
                # in-flight audio chunk can slip past the barge-in event.
                await self._interrupt_tts()
                await self.send({"type": "speech.start"})
            elif signal == "END_SPEECH":
                await self.send({"type": "speech.end"})
            return

        if response_type == "error":
            message = _field(data, "error", "Speech transcription failed.")
            await self.send(
                {"type": "error", "message": str(message), "fatal": False}
            )
            return
        if response_type != "data":
            return

        transcript = _field(data, "transcript")
        if not isinstance(transcript, str) or not transcript.strip():
            return
        transcript = transcript.strip()
        language = _field(data, "language_code")
        if isinstance(language, str) and language:
            self.last_language = language

        # Saaras v3's schema emits completed segments as `data`. Honour an
        # explicit false `is_final` from compatible SDK responses as interim.
        is_final = _field(data, "is_final", _field(response, "is_final", True))
        if is_final is False:
            await self.send({"type": "transcript.partial", "text": transcript})
            return

        final: dict[str, Any] = {"type": "transcript.final", "text": transcript}
        if isinstance(language, str) and language:
            final["language"] = language
        await self.send(final)
        await self._begin_response(utterance=transcript)

    async def _handle_client(self, message: Any) -> bool:
        if not isinstance(message, dict) or not isinstance(message.get("type"), str):
            await self.send(
                {
                    "type": "error",
                    "message": "Client messages must be JSON objects with a type.",
                    "fatal": not self.started,
                }
            )
            return self.started

        message_type = message["type"]
        if not self.started:
            if message_type != "session.start":
                await self.send(
                    {
                        "type": "error",
                        "message": "The first message must be session.start.",
                        "fatal": True,
                    }
                )
                return False
            try:
                await self._start(message)
            except Exception as exc:
                await self.send(
                    {"type": "error", "message": str(exc), "fatal": True}
                )
                return False
            return True

        try:
            if message_type == "audio.chunk":
                data = message.get("data")
                if not isinstance(data, str) or not data:
                    raise ValueError("audio.chunk requires non-empty base64 data.")
                if self.stt is None or not self.stt.send_audio(data):
                    raise RuntimeError("Speech transcription is unavailable or busy.")
            elif message_type == "text.turn":
                text = message.get("text")
                if not isinstance(text, str) or not text.strip():
                    raise ValueError("text.turn requires non-empty text.")
                await self._begin_response(utterance=text.strip())
            elif message_type == "action.result":
                raw_results = message.get("results")
                if not isinstance(raw_results, list):
                    raise ValueError("action.result requires a results array.")
                results = [ActionResult.model_validate(item) for item in raw_results]
                if results:
                    # Legacy clients may still report action results and page
                    # updates separately. Record them for conversational
                    # honesty, but never advance the loop on stale context.
                    self._record_action_results(results)
            elif message_type == "agent.observation":
                await self._handle_observation(message)
            elif message_type == "agent.pause":
                await self._handle_pause(message)
            elif message_type == "agent.resume":
                await self._handle_resume(message)
            elif message_type == "agent.cancel":
                await self._handle_cancel(message)
            elif message_type == "agent.skip":
                await self._handle_skip(message)
            elif message_type == "page.update":
                self.page = PageContext.model_validate(message.get("page"))
            elif message_type == "agent.interrupt":
                await self._interrupt_tts()
            elif message_type == "session.stop":
                self.execution.cancel()
                return False
            elif message_type == "session.start":
                raise ValueError("The live session has already started.")
            else:
                raise ValueError(f"Unknown client message type: {message_type}")
        except Exception as exc:
            await self.send(
                {"type": "error", "message": str(exc), "fatal": False}
            )
        return True

    async def run(self) -> None:
        await self.websocket.accept()
        self.receiver_task = asyncio.create_task(self._receive())
        keep_running = True
        try:
            while keep_running:
                kind, payload = await self.events.get()
                if kind == "client.message":
                    keep_running = await self._handle_client(payload)
                elif kind == "client.disconnected":
                    self.peer_disconnected = True
                    break
                elif kind == "client.error":
                    await self.send(
                        {"type": "error", "message": str(payload), "fatal": True}
                    )
                    break
                elif kind == "stt.message":
                    await self._handle_stt(payload)
                elif kind == "stt.error":
                    # Also log it: the client only ever showed a generic
                    # "unavailable or busy", which hid the real cause.
                    logger.error("Sarvam STT error: %s", payload)
                    await self.send(
                        {
                            "type": "error",
                            "message": f"Speech transcription failed: {payload}",
                            "fatal": False,
                        }
                    )
                elif kind == "stt.closed" and self.started:
                    # Typed turns remain available even if the STT provider
                    # disconnects, so this is deliberately non-fatal.
                    pass
        finally:
            self.generation += 1
            self.execution.cancel()
            await self._cancel_response()
            if self.active_tts is not None:
                self.active_tts.interrupt()
            if self.stt is not None:
                self.stt.stop()
                await asyncio.to_thread(self.stt.join)
            if self.receiver_task is not None:
                self.receiver_task.cancel()
                with suppress(asyncio.CancelledError):
                    await self.receiver_task
            if not self.peer_disconnected:
                with suppress(Exception):
                    await self.websocket.close(code=1000)


@router.websocket("/session/live")
async def live_session(websocket: WebSocket) -> None:
    await _LiveSession(websocket).run()
