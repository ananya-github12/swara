"""Pipecat-backed live voice sessions.

The browser protocol remains the JSON/base64 contract used by ``session.py``.
Only the audio carried by ``agent.audio`` differs: Pipecat emits headerless
signed 16-bit mono PCM instead of Sarvam's MP3 stream.
"""

from __future__ import annotations

import asyncio
import base64
import importlib
import json
import logging
import sys
import threading
import types
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any

import onnxruntime
from fastapi import APIRouter, WebSocket
from loguru import logger as pipecat_logger

from api_auth import vault_repository_for_websocket
from config import require
from conversation_prompts import (
    SESSION_PERSONA,
    build_opening_prompt,
    build_turn_prompt,
)
from pipecat.audio.turn.smart_turn.base_smart_turn import (
    BaseSmartTurn,
    SmartTurnParams,
)
from pipecat.audio.turn.smart_turn.local_smart_turn_v3 import (
    LocalSmartTurnAnalyzerV3,
)
from pipecat.audio.vad.silero import SileroOnnxModel, SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADAnalyzer, VADParams
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    ErrorFrame,
    Frame,
    InputAudioRawFrame,
    InputTransportMessageFrame,
    InterimTranscriptionFrame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMMessagesAppendFrame,
    LLMTextFrame,
    OutputAudioRawFrame,
    OutputTransportMessageFrame,
    OutputTransportMessageUrgentFrame,
    TranscriptionFrame,
    TTSUpdateSettingsFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineTask
from pipecat.pipeline.worker import PipelineParams
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.serializers.base_serializer import FrameSerializer
from pipecat.services.sarvam.stt import SarvamSTTService
from pipecat.services.sarvam.tts import SarvamTTSService
from pipecat.transports.websocket.fastapi import (
    FastAPIWebsocketParams,
    FastAPIWebsocketTransport,
)
from pipecat.turns.user_stop import TurnAnalyzerUserTurnStopStrategy
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.utils.env import env_truthy
from schemas import ActionResult, ContextItem, PageContext
from repositories.vault import VaultRepository
from session import (
    SESSION_MODEL,
    _action_result_text,
    _context_for_session,
    run_turn,
)
from session_schemas import AUDIO_SAMPLE_RATE, SessionStart, Turn, TurnResult


log = logging.getLogger("swara.pipecat_session")
router = APIRouter()

TTS_MODEL = "bulbul:v3"
TTS_VOICE = "advait"
TTS_LANGUAGE = "en-IN"
TTS_SAMPLE_RATE = 24_000

_SPEECH_ONLY_SUFFIX = """\

## Streaming speech channel

Return only the natural words to speak aloud. Do not output JSON, field names, \
actions, memory updates, or reasoning metadata. A separate structured pass \
handles page actions and memory. Keep the spoken response consistent with what \
the instructions above permit you to do."""


class SwaraFrameSerializer(FrameSerializer):
    """Translate between Pipecat frames and Swara's ordered JSON protocol."""

    async def serialize(self, frame: Frame) -> str | bytes | None:
        if self.should_ignore_frame(frame):
            return None
        if isinstance(frame, OutputAudioRawFrame):
            return json.dumps(
                {
                    "type": "agent.audio",
                    "data": base64.b64encode(frame.audio).decode("ascii"),
                    "mimeType": "audio/pcm",
                },
                separators=(",", ":"),
            )
        if isinstance(
            frame, (OutputTransportMessageFrame, OutputTransportMessageUrgentFrame)
        ):
            return json.dumps(frame.message, separators=(",", ":"))
        # Interruption, cancellation, and lifecycle frames have no wire-level
        # representation in the existing ServerMessage union.
        return None

    async def deserialize(self, data: str | bytes) -> Frame | None:
        if isinstance(data, bytes):
            data = data.decode("utf-8")
        message = json.loads(data)
        if not isinstance(message, dict):
            return InputTransportMessageFrame(message=message)
        if message.get("type") != "audio.chunk":
            return InputTransportMessageFrame(message=message)

        encoded = message.get("data")
        if not isinstance(encoded, str) or not encoded:
            raise ValueError("audio.chunk requires non-empty base64 data.")
        try:
            audio = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error) as exc:
            raise ValueError("audio.chunk data must be valid base64.") from exc
        if not audio or len(audio) % 2:
            raise ValueError("audio.chunk must contain complete Int16 PCM samples.")
        return InputAudioRawFrame(
            audio=audio,
            sample_rate=AUDIO_SAMPLE_RATE,
            num_channels=1,
        )


# ---------------------------------------------------------------------------
# Shared ONNX sessions
# ---------------------------------------------------------------------------

_VAD_SESSION_LOCK = threading.Lock()
_VAD_SESSIONS: dict[tuple[str, bool], onnxruntime.InferenceSession] = {}
_TURN_SESSION_LOCK = threading.Lock()
_TURN_SESSIONS: dict[tuple[str, int], onnxruntime.InferenceSession] = {}


def _resource_path(package: str, filename: str) -> str:
    try:
        import importlib_resources as resources
    except ImportError:
        from importlib import resources
    return str(resources.files(package).joinpath(filename))


def _shared_vad_session(
    path: str, force_onnx_cpu: bool
) -> onnxruntime.InferenceSession:
    key = (path, force_onnx_cpu)
    if key in _VAD_SESSIONS:
        return _VAD_SESSIONS[key]
    with _VAD_SESSION_LOCK:
        if key in _VAD_SESSIONS:
            return _VAD_SESSIONS[key]
        options = onnxruntime.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        kwargs: dict[str, Any] = {"sess_options": options}
        if (
            force_onnx_cpu
            and "CPUExecutionProvider" in onnxruntime.get_available_providers()
        ):
            kwargs["providers"] = ["CPUExecutionProvider"]
        session = onnxruntime.InferenceSession(path, **kwargs)
        _VAD_SESSIONS[key] = session
        pipecat_logger.info("Loaded shared Silero VAD ONNX session")
        return session


class _SharedSileroOnnxModel(SileroOnnxModel):
    def __init__(self, path: str, force_onnx_cpu: bool = True) -> None:
        object.__init__(self)
        self.session = _shared_vad_session(path, force_onnx_cpu)
        self.reset_states()
        self.sample_rates = [8000, 16000]


class SharedSileroVADAnalyzer(SileroVADAnalyzer):
    """Silero analyzer with per-call state and one process-wide ORT session."""

    def __init__(
        self,
        *,
        sample_rate: int | None = None,
        params: VADParams | None = None,
    ) -> None:
        VADAnalyzer.__init__(self, sample_rate=sample_rate, params=params)
        model_path = _resource_path(
            "pipecat.audio.vad.data",
            "silero_vad.onnx",
        )
        self._model = _SharedSileroOnnxModel(model_path, force_onnx_cpu=True)
        self._last_reset_time = 0


def _shared_turn_session(path: str, cpu_count: int) -> onnxruntime.InferenceSession:
    key = (path, cpu_count)
    if key in _TURN_SESSIONS:
        return _TURN_SESSIONS[key]
    with _TURN_SESSION_LOCK:
        if key in _TURN_SESSIONS:
            return _TURN_SESSIONS[key]
        options = onnxruntime.SessionOptions()
        options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = cpu_count
        options.graph_optimization_level = (
            onnxruntime.GraphOptimizationLevel.ORT_ENABLE_ALL
        )
        session = onnxruntime.InferenceSession(path, sess_options=options)
        _TURN_SESSIONS[key] = session
        pipecat_logger.info("Loaded shared smart-turn ONNX session")
        return session


class SharedSmartTurnAnalyzerV3(LocalSmartTurnAnalyzerV3):
    """Smart-turn analyzer with independent buffers and one shared ORT session."""

    def __init__(
        self,
        *,
        sample_rate: int | None = None,
        params: SmartTurnParams | None = None,
        smart_turn_model_path: str | None = None,
        cpu_count: int = 1,
    ) -> None:
        BaseSmartTurn.__init__(self, sample_rate=sample_rate, params=params)
        self._log_data = env_truthy(
            "PIPECAT_SMART_TURN_LOG_DATA",
            default=False,
        )
        model_path = smart_turn_model_path or _resource_path(
            "pipecat.audio.turn.smart_turn.data",
            "smart-turn-v3.2-cpu.onnx",
        )
        self._session = _shared_turn_session(model_path, cpu_count)


# ---------------------------------------------------------------------------
# Session coordination and protocol processors
# ---------------------------------------------------------------------------


@dataclass
class _SessionState:
    session_id: str = ""
    page: PageContext | None = None
    context_items: list[ContextItem] = field(default_factory=list)
    history: list[Turn] = field(default_factory=list)
    started: bool = False
    generation: int = 0
    interrupted_generation: int | None = None
    extraction_tasks: dict[int, asyncio.Task[TurnResult]] = field(
        default_factory=dict
    )
    agent_turns: dict[int, Turn] = field(default_factory=dict)
    done_generations: dict[int, bool] = field(default_factory=dict)
    output: "_SessionOutputProcessor | None" = None
    repository: VaultRepository | None = None

    def invalidate_current_turn(self) -> None:
        if self.generation:
            self.interrupted_generation = self.generation

    def is_current(self, generation: int) -> bool:
        return (
            generation == self.generation
            and generation != self.interrupted_generation
        )


class _TurnCoordinator:
    def __init__(self, state: _SessionState) -> None:
        self._state = state

    async def prepare(
        self,
        *,
        utterance: str | None = None,
        opening: bool = False,
    ) -> LLMMessagesAppendFrame:
        state = self._state
        if state.page is None:
            raise RuntimeError("The Pipecat session has no page context.")

        history_for_prompt = list(state.history)
        if opening:
            prompt = build_opening_prompt(state.page, list(state.context_items))
        else:
            if utterance is None:
                raise ValueError("A conversational turn requires an utterance.")
            prompt = build_turn_prompt(
                state.page,
                list(state.context_items),
                history_for_prompt,
                utterance,
            )
            state.history.append(Turn(role="user", text=utterance))

        state.generation += 1
        generation = state.generation
        state.interrupted_generation = None
        state.extraction_tasks[generation] = asyncio.create_task(
            asyncio.to_thread(
                run_turn,
                session_id=state.session_id,
                page=state.page,
                context_items=list(state.context_items),
                history=history_for_prompt,
                utterance=utterance,
                opening=opening,
                memory_repository=state.repository,
            ),
            name=f"swara-structured-turn-{generation}",
        )
        return LLMMessagesAppendFrame(
            messages=[
                {
                    "role": "user",
                    "content": prompt + _SPEECH_ONLY_SUFFIX,
                }
            ],
            run_llm=True,
        )

    async def cancel_pending(self) -> None:
        tasks = list(self._state.extraction_tasks.values())
        for task in tasks:
            if not task.done():
                task.cancel()
        for task in tasks:
            with suppress(asyncio.CancelledError, Exception):
                await task


class _ClientProtocolProcessor(FrameProcessor):
    def __init__(
        self,
        state: _SessionState,
        coordinator: _TurnCoordinator,
    ) -> None:
        super().__init__()
        self._state = state
        self._coordinator = coordinator
        self._task: PipelineTask | None = None

    def bind_task(self, task: PipelineTask) -> None:
        self._task = task

    async def _send(self, message: dict[str, Any]) -> None:
        await self.push_frame(OutputTransportMessageFrame(message=message))

    async def _fatal(self, message: str) -> None:
        await self._send({"type": "error", "message": message, "fatal": True})
        if self._task:
            await self._task.stop_when_done()

    async def process_frame(
        self,
        frame: Frame,
        direction: FrameDirection,
    ) -> None:
        await super().process_frame(frame, direction)
        if direction is FrameDirection.UPSTREAM:
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, InputAudioRawFrame):
            if not self._state.started:
                await self._fatal("The first message must be session.start.")
                return
            await self.push_frame(frame, direction)
            return

        if not isinstance(frame, InputTransportMessageFrame):
            await self.push_frame(frame, direction)
            return

        message = frame.message
        if not isinstance(message, dict) or not isinstance(
            message.get("type"), str
        ):
            await self._send(
                {
                    "type": "error",
                    "message": "Client messages must be JSON objects with a type.",
                    "fatal": not self._state.started,
                }
            )
            return

        message_type = message["type"]
        if not self._state.started:
            if message_type != "session.start":
                await self._fatal("The first message must be session.start.")
                return
            try:
                start = SessionStart.model_validate(message)
                self._state.session_id = start.session_id
                self._state.page = start.page
                self._state.context_items = await asyncio.to_thread(
                    _context_for_session,
                    self._state.repository,
                    start.session_id,
                )
                self._state.started = True
                prompt_frame = await self._coordinator.prepare(opening=True)
                await self._send({"type": "state", "state": "thinking"})
                await self.push_frame(prompt_frame)
            except Exception as exc:
                await self._fatal(str(exc))
            return

        try:
            if message_type == "text.turn":
                text = message.get("text")
                if not isinstance(text, str) or not text.strip():
                    raise ValueError("text.turn requires non-empty text.")
                self._state.invalidate_current_turn()
                await self.broadcast_interruption()
                prompt_frame = await self._coordinator.prepare(
                    utterance=text.strip()
                )
                await self._send({"type": "state", "state": "thinking"})
                await self.push_frame(prompt_frame)
            elif message_type == "action.result":
                raw_results = message.get("results")
                if not isinstance(raw_results, list):
                    raise ValueError("action.result requires a results array.")
                results = [
                    ActionResult.model_validate(item) for item in raw_results
                ]
                for turn in reversed(self._state.history):
                    if turn.role == "agent" and turn.actions:
                        turn.results.extend(results)
                        break
                if results:
                    self._state.history.append(
                        Turn(
                            role="user",
                            text=_action_result_text(results),
                            results=results,
                        )
                    )
            elif message_type == "page.update":
                self._state.page = PageContext.model_validate(message.get("page"))
            elif message_type == "agent.interrupt":
                self._state.invalidate_current_turn()
                await self.broadcast_interruption()
            elif message_type == "session.stop":
                if self._task:
                    await self._task.stop_when_done()
            elif message_type == "session.start":
                raise ValueError("The live session has already started.")
            elif message_type == "audio.chunk":
                # Audio messages are consumed by the serializer.
                raise ValueError("audio.chunk did not contain valid PCM audio.")
            else:
                raise ValueError(f"Unknown client message type: {message_type}")
        except Exception as exc:
            await self._send(
                {"type": "error", "message": str(exc), "fatal": False}
            )


class _TranscriptPromptProcessor(FrameProcessor):
    def __init__(
        self,
        state: _SessionState,
        coordinator: _TurnCoordinator,
    ) -> None:
        super().__init__()
        self._state = state
        self._coordinator = coordinator

    async def _send(self, message: dict[str, Any]) -> None:
        await self.push_frame(OutputTransportMessageFrame(message=message))

    async def process_frame(
        self,
        frame: Frame,
        direction: FrameDirection,
    ) -> None:
        await super().process_frame(frame, direction)
        if direction is FrameDirection.UPSTREAM:
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, InterimTranscriptionFrame):
            text = frame.text.strip()
            if text:
                await self._send({"type": "transcript.partial", "text": text})
            await self.push_frame(frame, direction)
            return
        if not isinstance(frame, TranscriptionFrame):
            await self.push_frame(frame, direction)
            return

        utterance = frame.text.strip()
        if not utterance:
            return
        final: dict[str, Any] = {
            "type": "transcript.final",
            "text": utterance,
        }
        if frame.language:
            final["language"] = str(frame.language)
        await self._send(final)
        try:
            if frame.language:
                # Keep Sarvam's required language explicit while mirroring the
                # language Saaras detected for this turn.
                await self.push_frame(
                    TTSUpdateSettingsFrame(
                        delta=SarvamTTSService.Settings(
                            language=frame.language,
                        )
                    )
                )
            prompt_frame = await self._coordinator.prepare(utterance=utterance)
            await self._send({"type": "state", "state": "thinking"})
            prompt = prompt_frame.messages[0]["content"]
            await self.push_frame(
                TranscriptionFrame(
                    text=str(prompt),
                    user_id=frame.user_id,
                    timestamp=frame.timestamp,
                    language=frame.language,
                    result=frame.result,
                    finalized=frame.finalized,
                ),
                direction,
            )
        except Exception as exc:
            await self._send(
                {"type": "error", "message": str(exc), "fatal": False}
            )


class _SessionOutputProcessor(FrameProcessor):
    """Expose Pipecat state and the parallel structured pass to the client."""

    def __init__(self, state: _SessionState) -> None:
        super().__init__()
        self._state = state
        self._response_generation = 0
        self._response_text: list[str] = []
        self._user_speaking = False
        self._bot_speaking = False
        self._audio_ended = True
        self._delivery_tasks: dict[int, asyncio.Task[None]] = {}

    async def _send(self, message: dict[str, Any]) -> None:
        await self.push_frame(OutputTransportMessageFrame(message=message))

    async def _deliver_structured(self, generation: int) -> None:
        task = self._state.extraction_tasks.get(generation)
        if task is None:
            return
        try:
            result = await task
        except asyncio.CancelledError:
            return
        except Exception as exc:
            if self._state.is_current(generation):
                await self._send(
                    {
                        "type": "error",
                        "message": f"Structured turn extraction failed: {exc}",
                        "fatal": False,
                    }
                )
            return
        if not self._state.is_current(generation):
            return

        self._state.done_generations[generation] = result.done
        turn = self._state.agent_turns.get(generation)
        if turn is not None:
            turn.actions = list(result.actions)

        await self._send(
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
            await self._send(
                {
                    "type": "memory.learned",
                    "updates": [
                        update.model_dump(by_alias=True, exclude_none=True)
                        for update in result.memory_updates
                    ],
                }
            )
            try:
                self._state.context_items = await asyncio.to_thread(
                    _context_for_session,
                    self._state.repository,
                    self._state.session_id,
                )
            except Exception as exc:
                await self._send(
                    {
                        "type": "error",
                        "message": (
                            "Memory was saved but context refresh failed: "
                            f"{exc}"
                        ),
                        "fatal": False,
                    }
                )
        if result.question:
            await self._send(
                {"type": "agent.question", "text": result.question}
            )
        if result.actions:
            await self._send({"type": "state", "state": "acting"})
            await self._send(
                {
                    "type": "agent.actions",
                    "actions": [
                        action.model_dump(by_alias=True, exclude_none=True)
                        for action in result.actions
                    ],
                }
            )
            await self._send(
                {
                    "type": "state",
                    "state": (
                        "speaking"
                        if self._bot_speaking
                        else "idle"
                        if result.done
                        else "listening"
                    ),
                }
            )

    def _ensure_structured_delivery(self, generation: int) -> None:
        if generation in self._delivery_tasks:
            return
        self._delivery_tasks[generation] = self.create_task(
            self._deliver_structured(generation),
            name=f"swara-deliver-structured-{generation}",
        )

    async def process_frame(
        self,
        frame: Frame,
        direction: FrameDirection,
    ) -> None:
        await super().process_frame(frame, direction)

        if isinstance(
            frame, (VADUserStartedSpeakingFrame, UserStartedSpeakingFrame)
        ):
            if not self._user_speaking:
                self._user_speaking = True
                self._state.invalidate_current_turn()
                await self._send({"type": "speech.start"})
            await self.push_frame(frame, direction)
            return
        if isinstance(
            frame, (VADUserStoppedSpeakingFrame, UserStoppedSpeakingFrame)
        ):
            if self._user_speaking:
                self._user_speaking = False
                await self._send({"type": "speech.end"})
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, InterruptionFrame):
            if direction is FrameDirection.DOWNSTREAM and not self._audio_ended:
                self._audio_ended = True
                await self._send({"type": "agent.audio.end"})
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, BotStartedSpeakingFrame):
            self._bot_speaking = True
            self._audio_ended = False
            await self._send({"type": "state", "state": "speaking"})
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, BotStoppedSpeakingFrame):
            self._bot_speaking = False
            if not self._audio_ended:
                self._audio_ended = True
                await self._send({"type": "agent.audio.end"})
            done = self._state.done_generations.get(
                self._response_generation,
                False,
            )
            await self._send(
                {"type": "state", "state": "idle" if done else "listening"}
            )
            await self.push_frame(frame, direction)
            return
        if isinstance(frame, LLMFullResponseStartFrame):
            self._response_generation = self._state.generation
            self._response_text = []
            turn = Turn(role="agent", text="")
            self._state.agent_turns[self._response_generation] = turn
            self._state.history.append(turn)
            self._ensure_structured_delivery(self._response_generation)
        elif isinstance(frame, LLMTextFrame):
            self._response_text.append(frame.text)
            turn = self._state.agent_turns.get(self._response_generation)
            if turn is not None:
                turn.text = "".join(self._response_text).strip()
        elif isinstance(frame, LLMFullResponseEndFrame):
            text = "".join(self._response_text).strip()
            turn = self._state.agent_turns.get(self._response_generation)
            if turn is not None:
                turn.text = text
            if text and self._state.is_current(self._response_generation):
                await self._send({"type": "agent.text", "text": text})
            elif self._state.is_current(self._response_generation):
                self._audio_ended = True
                await self._send({"type": "agent.audio.end"})
                await self._send({"type": "state", "state": "listening"})
        elif isinstance(frame, ErrorFrame):
            await self._send(
                {
                    "type": "error",
                    "message": frame.error,
                    "fatal": frame.fatal,
                }
            )
            if not frame.fatal:
                await self._send({"type": "state", "state": "listening"})

        await self.push_frame(frame, direction)


def _install_google_api_core_compatibility() -> None:
    """Supply the one optional exception class Pipecat imports.

    The pinned environment has ``google-genai`` but not ``google-api-core``.
    Pipecat's Gemini service only uses the missing package for an
    ``except DeadlineExceeded`` clause. Mapping that clause to ``TimeoutError``
    keeps the installed service usable without adding a dependency.
    """

    try:
        importlib.import_module("google.api_core.exceptions")
        return
    except ModuleNotFoundError as exc:
        if exc.name not in {"google.api_core", "google.api_core.exceptions"}:
            raise

    import google

    package = types.ModuleType("google.api_core")
    package.__path__ = []  # type: ignore[attr-defined]
    exceptions = types.ModuleType("google.api_core.exceptions")
    exceptions.DeadlineExceeded = TimeoutError  # type: ignore[attr-defined]
    package.exceptions = exceptions  # type: ignore[attr-defined]
    google.api_core = package  # type: ignore[attr-defined]
    sys.modules["google.api_core"] = package
    sys.modules["google.api_core.exceptions"] = exceptions


def _build_google_llm() -> FrameProcessor:
    _install_google_api_core_compatibility()
    from pipecat.services.google.llm import GoogleLLMService

    return GoogleLLMService(
        api_key=require("GOOGLE_API_KEY"),
        settings=GoogleLLMService.Settings(
            model=SESSION_MODEL,
            system_instruction=SESSION_PERSONA,
            max_tokens=512,
        ),
    )


class SwaraSarvamSTTService(SarvamSTTService):
    """Sarvam STT with the per-chunk encoding Sarvam actually accepts.

    Pipecat derives the per-chunk `encoding` by prefixing `input_audio_codec`
    with "audio/", but Sarvam accepts only the literal "audio/wav" there while
    still requiring "pcm_s16le" at connect time to interpret headerless PCM.
    Pipecat uses one value for both, so neither setting works unaided:
    "pcm_s16le" yields "audio/pcm_s16le" and every chunk is rejected, while
    "wav" makes Sarvam expect a RIFF container we never send and nothing is
    transcribed at all.
    """

    async def run_stt(self, audio: bytes):
        if not self._socket_client:
            yield None
            return
        try:
            kwargs = {
                "audio": base64.b64encode(audio).decode("utf-8"),
                "encoding": "audio/wav",
                # Our capture rate, not self.sample_rate: pipecat can carry the
                # 24 kHz output rate here, and audio labelled at the wrong rate
                # still trips VAD while transcribing to nothing.
                "sample_rate": AUDIO_SAMPLE_RATE,
            }
            if self._config.use_translate_method:
                await self._socket_client.translate(**kwargs)
            else:
                await self._socket_client.transcribe(**kwargs)
        except Exception as exc:
            yield ErrorFrame(error=f"Error sending audio to Sarvam: {exc}", exception=exc)
        yield None


def _build_stt() -> SarvamSTTService:
    return SwaraSarvamSTTService(
        api_key=require("SARVAM_API_KEY"),
        model="saaras:v3",
        mode="transcribe",
        sample_rate=AUDIO_SAMPLE_RATE,
        # Declares headerless PCM at connect time; the subclass above sends
        # the literal "audio/wav" per chunk, which is the only combination
        # Sarvam accepts.
        input_audio_codec="pcm_s16le",
        settings=SarvamSTTService.Settings(
            model="saaras:v3",
            language="unknown",
            # Silero and smart-turn own the boundaries. Disabling Sarvam's
            # boundary frames also enables Pipecat's flush-on-local-VAD path.
            vad_signals=False,
        ),
    )


def _build_tts() -> SarvamTTSService:
    return SarvamTTSService(
        api_key=require("SARVAM_API_KEY"),
        sample_rate=TTS_SAMPLE_RATE,
        settings=SarvamTTSService.Settings(
            model=TTS_MODEL,
            voice=TTS_VOICE,
            language=TTS_LANGUAGE,
        ),
    )


async def _run_pipecat_session(websocket: WebSocket) -> None:
    # Pipecat's FastAPI transport never accepts the socket itself, so without
    # this the handshake is rejected with a 403 even though the pipeline behind
    # it starts up perfectly.
    await websocket.accept()

    state = _SessionState()
    state.repository = vault_repository_for_websocket(websocket)
    coordinator = _TurnCoordinator(state)
    serializer = SwaraFrameSerializer()
    transport = FastAPIWebsocketTransport(
        websocket=websocket,
        params=FastAPIWebsocketParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_in_sample_rate=AUDIO_SAMPLE_RATE,
            audio_out_sample_rate=TTS_SAMPLE_RATE,
            audio_in_channels=1,
            audio_out_channels=1,
            add_wav_header=False,
            serializer=serializer,
        ),
    )

    vad = SharedSileroVADAnalyzer(
        params=VADParams(
            confidence=0.7,
            start_secs=0.2,
            stop_secs=0.2,
            min_volume=0.6,
        )
    )
    smart_turn = SharedSmartTurnAnalyzerV3()
    # Gemini receives SESSION_PERSONA through its native system_instruction.
    # session.start supplies the first user message before inference begins.
    context = LLMContext()
    aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=vad,
            user_turn_strategies=UserTurnStrategies(
                stop=[
                    TurnAnalyzerUserTurnStopStrategy(
                        turn_analyzer=smart_turn,
                    )
                ]
            ),
        ),
    )

    client_protocol = _ClientProtocolProcessor(state, coordinator)
    transcript_prompt = _TranscriptPromptProcessor(state, coordinator)
    output_protocol = _SessionOutputProcessor(state)
    state.output = output_protocol

    pipeline = Pipeline(
        [
            transport.input(),
            client_protocol,
            _build_stt(),
            transcript_prompt,
            aggregator.user(),
            _build_google_llm(),
            output_protocol,
            _build_tts(),
            transport.output(),
            aggregator.assistant(),
        ]
    )
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            audio_in_sample_rate=AUDIO_SAMPLE_RATE,
            audio_out_sample_rate=TTS_SAMPLE_RATE,
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
        enable_rtvi=False,
    )
    client_protocol.bind_task(task)

    @transport.event_handler("on_client_disconnected")
    async def _on_disconnected(_transport, _websocket) -> None:
        await task.cancel(reason="client disconnected")

    try:
        await PipelineRunner(handle_sigint=False).run(task)
    finally:
        await coordinator.cancel_pending()


@router.websocket("/session/pipecat")
async def pipecat_session(websocket: WebSocket) -> None:
    """Run the low-latency Pipecat session without touching /session/live."""

    try:
        await _run_pipecat_session(websocket)
    except Exception as exc:
        log.exception("Pipecat session failed")
        # Failures before the transport accepts the socket still need a useful
        # protocol response. Once accepted, send_json is also safe until close.
        with suppress(Exception):
            await websocket.accept()
        with suppress(Exception):
            await websocket.send_json(
                {"type": "error", "message": str(exc), "fatal": True}
            )
        with suppress(Exception):
            await websocket.close(code=1011)
