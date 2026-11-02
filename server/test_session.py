"""Local end-to-end test for the live-session WebSocket.

No network calls are made: Sarvam, Gemini, and the context vault are replaced
with deterministic fakes.
"""

from __future__ import annotations

import queue
import unittest
from contextlib import contextmanager
from typing import Any
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from fastapi.testclient import TestClient

import app
import api_auth
import session
from request_context import RequestContext
from schemas import Action, ActionResult, PageContext
from session_schemas import Turn, TurnResult


class FakeSTTSocket:
    def __init__(self) -> None:
        self.responses: queue.Queue[Any] = queue.Queue()
        self.transcriptions: list[tuple[str, str, int]] = []
        self.closed = False

    def __iter__(self):
        while True:
            response = self.responses.get()
            if response is None:
                return
            yield response

    def transcribe(
        self,
        audio: str,
        encoding: str = "audio/wav",
        sample_rate: int = 16_000,
    ) -> None:
        # The real SDK validates this as a literal and raises on anything else.
        # The fake must too: without it this test passed against an encoding
        # the live API rejects, which is how the bug reached a browser.
        if encoding != "audio/wav":
            raise ValueError(
                f"encoding must be 'audio/wav', got {encoding!r}"
            )
        self.transcriptions.append((audio, encoding, sample_rate))
        self.responses.put(
            {"type": "events", "data": {"signal_type": "START_SPEECH"}}
        )
        self.responses.put(
            {"type": "events", "data": {"signal_type": "END_SPEECH"}}
        )
        self.responses.put(
            {
                "type": "data",
                "data": {
                    "transcript": "fill it",
                    "language_code": "en-IN",
                },
            }
        )

    def flush(self) -> None:
        return None

    def close(self) -> None:
        if not self.closed:
            self.closed = True
            self.responses.put(None)


class FakeTTSSocket:
    def __init__(self, owner: "FakeSarvam") -> None:
        self.owner = owner
        self.text = ""
        self.closed = False

    def configure(self, **kwargs: Any) -> None:
        self.owner.tts_configurations.append(kwargs)

    def convert(self, text: str) -> None:
        self.text = text

    def flush(self) -> None:
        return None

    def __iter__(self):
        yield {
            "type": "audio",
            "data": {
                "audio": f"audio:{self.text}",
                "content_type": "audio/mp3",
            },
        }
        yield {"type": "event", "data": {"event_type": "final"}}

    def close(self) -> None:
        self.closed = True


class FakeSTTStreaming:
    def __init__(self, owner: "FakeSarvam") -> None:
        self.owner = owner

    @contextmanager
    def connect(self, **kwargs: Any):
        self.owner.stt_connect_kwargs.append(kwargs)
        try:
            yield self.owner.stt_socket
        finally:
            self.owner.stt_socket.close()


class FakeTTSStreaming:
    def __init__(self, owner: "FakeSarvam") -> None:
        self.owner = owner

    @contextmanager
    def connect(self, **kwargs: Any):
        self.owner.tts_connect_kwargs.append(kwargs)
        socket = FakeTTSSocket(self.owner)
        try:
            yield socket
        finally:
            socket.close()


class FakeSarvam:
    def __init__(self) -> None:
        self.stt_socket = FakeSTTSocket()
        self.stt_connect_kwargs: list[dict[str, Any]] = []
        self.tts_connect_kwargs: list[dict[str, Any]] = []
        self.tts_configurations: list[dict[str, Any]] = []
        self.speech_to_text_streaming = FakeSTTStreaming(self)
        self.text_to_speech_streaming = FakeTTSStreaming(self)



class FakeLLMStreamBridge:
    """Stand in for the streaming Gemini call.

    The streaming pass speaks; the structured pass (fake_run_turn) decides what
    changes. Both must be faked or the test reaches the network.
    """

    def __init__(self, loop: Any, prompt: str) -> None:
        self._loop = loop
        self.events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        self._prompt = prompt

    def start(self) -> None:
        text = "Still here." if "recover" in self._prompt else "Hello there."
        self.events.put_nowait(("sentence", text))
        self.events.put_nowait(("done", None))

    def stop(self) -> None:
        return None


def receive_through(websocket: Any, final_type: str) -> list[dict[str, Any]]:
    messages = []
    while True:
        message = websocket.receive_json()
        messages.append(message)
        if message["type"] == final_type:
            return messages


def assert_subsequence(test: unittest.TestCase, actual: list[str], expected: list[str]) -> None:
    position = 0
    for item in actual:
        if position < len(expected) and item == expected[position]:
            position += 1
    test.assertEqual(
        position,
        len(expected),
        f"Expected subsequence {expected!r}, got {actual!r}",
    )


class LiveSessionTest(unittest.TestCase):
    def test_fake_streaming_session_and_turn_recovery(self) -> None:
        fake_sarvam = FakeSarvam()
        turn_calls: list[dict[str, Any]] = []

        def fake_run_turn(**kwargs: Any) -> TurnResult:
            turn_calls.append(kwargs)
            if kwargs["opening"]:
                return TurnResult(speech="I can help with this application.")
            utterance = kwargs["utterance"]
            if utterance == "fill it":
                return TurnResult(
                    speech="I filled the name.",
                    actions=[
                        Action(
                            field_id="full-name",
                            action="fill",
                            value="Ada Lovelace",
                        )
                    ],
                )
            if kwargs["observation"] is not None:
                return TurnResult(speech="The name is filled.", done=True)
            if utterance == "explode":
                raise RuntimeError("simulated turn failure")
            if utterance == "recover":
                return TurnResult(speech="Still here.")
            raise AssertionError(f"Unexpected utterance: {utterance}")

        page = {
            "url": "https://example.test/apply",
            "title": "Example application",
            "heading": "Apply",
            "fields": [
                {
                    "fieldId": "full-name",
                    "label": "Full name",
                    "question": "What is your full name?",
                    "type": "text",
                    "required": True,
                }
            ],
        }

        with (
            patch.object(session, "_sarvam_client", return_value=fake_sarvam),
            patch.object(session, "_context_for_session", return_value=[]),
            patch.object(session, "vault_repository_for_websocket", return_value=MagicMock()),
            patch.object(session, "run_turn", side_effect=fake_run_turn),
            patch.object(session, "_LLMStreamBridge", FakeLLMStreamBridge),
            patch.object(
                api_auth,
                "authenticate_websocket",
                AsyncMock(
                    return_value=RequestContext(
                        user_id="11111111-1111-4111-8111-111111111111",
                        auth_session_id="22222222-2222-4222-8222-222222222222",
                    )
                ),
            ),
            TestClient(app.app) as client,
            client.websocket_connect("/session/live") as websocket,
        ):
            websocket.send_json(
                {
                    "type": "session.start",
                    "sessionId": "test-session",
                    "page": page,
                }
            )
            opening = receive_through(websocket, "agent.audio.end")
            opening.extend(receive_through(websocket, "state"))
            opening_types = [message["type"] for message in opening]
            assert_subsequence(
                self,
                opening_types,
                [
                    "state",
                    # Speech streams: each sentence is emitted and spoken before
                    # the next is written, so text and audio interleave instead
                    # of the whole reply arriving at once.
                    "agent.text",
                    "agent.audio",
                    "agent.audio.end",
                    # Reasoning arrives from the concurrent structured pass.
                    "context.used",
                    "state",
                ],
            )
            self.assertEqual(opening[-1], {"type": "state", "state": "listening"})

            websocket.send_json({"type": "audio.chunk", "data": "cGNt"})
            # Speech streams first now; the concurrent structured pass emits
            # actions once it resolves, after the audio has finished.
            streamed = receive_through(websocket, "agent.audio.end")
            streamed.extend(receive_through(websocket, "agent.actions"))
            streamed_types = [message["type"] for message in streamed]
            assert_subsequence(
                self,
                streamed_types,
                [
                    "speech.start",
                    "speech.end",
                    "transcript.final",
                    "state",
                    # Speech streams: each sentence is emitted and spoken
                    # before the next is written, so text and audio interleave
                    # rather than the whole reply landing at once.
                    "agent.text",
                    "agent.audio",
                    "agent.audio.end",
                    # Actions and reasoning arrive from the concurrent
                    # structured pass once it resolves.
                    "context.used",
                    "agent.actions",
                ],
            )
            action_message = next(
                message
                for message in streamed
                if message["type"] == "agent.actions"
            )
            self.assertEqual(
                action_message["actions"][0],
                {
                    "fieldId": "full-name",
                    "action": "fill",
                    "value": "Ada Lovelace",
                },
            )
            self.assertEqual(action_message["step"], 1)
            self.assertEqual(action_message["maxSteps"], 8)
            self.assertIsInstance(action_message["batchId"], str)

            websocket.send_json(
                {
                    "type": "agent.observation",
                    "batchId": action_message["batchId"],
                    "results": [{"fieldId": "full-name", "ok": True}],
                    "page": {
                        **page,
                        "fields": [
                            {
                                **page["fields"][0],
                                "currentValue": "Ada Lovelace",
                            }
                        ],
                    },
                }
            )
            observed = receive_through(websocket, "agent.audio.end")
            observed.extend(receive_through(websocket, "state"))
            self.assertEqual(observed[-1], {"type": "state", "state": "idle"})
            websocket.send_json({"type": "text.turn", "text": "explode"})
            failed = receive_through(websocket, "error")
            failed.extend(receive_through(websocket, "state"))
            error = next(message for message in failed if message["type"] == "error")
            self.assertEqual(error["fatal"], False)
            self.assertIn("simulated turn failure", error["message"])
            self.assertEqual(failed[-1], {"type": "state", "state": "listening"})

            # A second turn on the same socket proves the prior exception did
            # not end the session.
            websocket.send_json({"type": "text.turn", "text": "recover"})
            recovered = receive_through(websocket, "agent.audio.end")
            recovered.extend(receive_through(websocket, "state"))
            self.assertTrue(
                any(
                    message == {"type": "agent.text", "text": "Still here."}
                    for message in recovered
                )
            )
            websocket.send_json({"type": "session.stop"})

        self.assertEqual(
            fake_sarvam.stt_connect_kwargs,
            [
                {
                    "language_code": "unknown",
                    "model": "saaras:v3",
                    "mode": "transcribe",
                    "input_audio_codec": "pcm_s16le",
                    "sample_rate": "16000",
                    **session.VAD_SETTINGS,
                }
            ],
        )
        self.assertEqual(
            fake_sarvam.stt_socket.transcriptions,
            [("cGNt", "audio/wav", 16_000)],
        )
        self.assertTrue(
            all(
                kwargs
                == {"model": "bulbul:v3", "send_completion_event": "true"}
                for kwargs in fake_sarvam.tts_connect_kwargs
            )
        )
        self.assertTrue(
            all(
                kwargs["target_language_code"] == "en-IN"
                and kwargs["speaker"] == "advait"
                for kwargs in fake_sarvam.tts_configurations
            )
        )
        recovery_history = next(
            call["history"]
            for call in turn_calls
            if call["utterance"] == "recover"
        )
        self.assertTrue(
            any("full-name: succeeded" in turn.text for turn in recovery_history)
        )

        print(
            "ORDER:",
            " -> ".join(streamed_types),
        )
        print(
            "RECOVERY:",
            "non-fatal turn error followed by successful turn on same WebSocket",
        )
        print(
            "SARVAM:",
            fake_sarvam.stt_connect_kwargs[0],
            fake_sarvam.tts_connect_kwargs[0],
            fake_sarvam.tts_configurations[0],
        )


class SpeakableTests(unittest.TestCase):
    """The spoken channel is told to emit words only. It sometimes doesn't."""

    def test_strips_an_action_tag_the_model_leaked_into_speech(self) -> None:
        self.assertEqual(
            session.speakable(
                'Done. <action type="fill" fieldId="editor:body" value="Hi" />'
            ),
            "Done.",
        )

    def test_rejects_a_sentence_that_is_only_markup(self) -> None:
        # Sarvam refuses text with no letters, which surfaced to the user as a
        # synthesis failure on an otherwise good turn.
        self.assertIsNone(session.speakable('<action type="fill" value="x" />'))
        self.assertIsNone(session.speakable("```"))
        self.assertIsNone(session.speakable("   "))

    def test_keeps_ordinary_speech_untouched(self) -> None:
        for sentence in (
            "I've filled in most of it.",
            "मैंने आपका नाम भर दिया है।",
            "That's less than half, about 40 percent.",
        ):
            self.assertEqual(session.speakable(sentence), sentence)


class ExecutionLoopTests(unittest.IsolatedAsyncioTestCase):
    """The loop must only continue from the exact, refreshed observation."""

    @staticmethod
    def page(title: str = "First page") -> PageContext:
        return PageContext.model_validate(
            {
                "url": "https://example.test/one",
                "title": title,
                "fields": [
                    {
                        "fieldId": "name",
                        "label": "Name",
                        "question": "Name",
                        "type": "text",
                    }
                ],
            }
        )

    async def test_atomic_observation_advances_only_matching_batch(self) -> None:
        live = session._LiveSession(MagicMock())
        live.page = self.page()
        action = Action(field_id="name", action="fill", value="Ada")
        live.history = [Turn(role="agent", text="I’ll fill your name.", actions=[action])]
        live.execution.start()
        batch = live.execution.issue([action])
        live._begin_observation_response = AsyncMock()  # type: ignore[method-assign]

        with self.assertRaisesRegex(ValueError, "does not match"):
            await live._handle_observation(
                {
                    "type": "agent.observation",
                    "batchId": "stale-batch",
                    "results": [{"fieldId": "name", "ok": True}],
                    "page": self.page("Stale page").model_dump(by_alias=True),
                }
            )
        self.assertEqual(live.page.title, "First page")
        self.assertEqual(live.execution.pending, batch)
        live._begin_observation_response.assert_not_awaited()

        await live._handle_observation(
            {
                "type": "agent.observation",
                "batchId": batch.batch_id,
                "results": [{"fieldId": "name", "ok": True}],
                "page": self.page("Second page").model_dump(by_alias=True),
            }
        )

        self.assertEqual(live.page.title, "Second page")
        self.assertEqual(live.execution.completed_steps, 1)
        self.assertIsNone(live.execution.pending)
        self.assertTrue(live.history[0].results[0].ok)
        live._begin_observation_response.assert_awaited_once()
        observation_text, = live._begin_observation_response.await_args.args
        self.assertIn("name: succeeded", observation_text)
        self.assertEqual(
            live._begin_observation_response.await_args.kwargs["step"], 2
        )

        with self.assertRaisesRegex(ValueError, "no browser action batch"):
            await live._handle_observation(
                {
                    "type": "agent.observation",
                    "batchId": batch.batch_id,
                    "results": [{"fieldId": "name", "ok": True}],
                    "page": self.page("Stale page").model_dump(by_alias=True),
                }
            )
        self.assertEqual(live.page.title, "Second page")

    async def test_actions_carry_the_batch_contract(self) -> None:
        live = session._LiveSession(MagicMock())
        live.send = AsyncMock()  # type: ignore[method-assign]
        action = Action(field_id="name", action="fill", value="Ada")

        self.assertTrue(
            await live._emit_actions(
                [action], opening=False, observation=None
            )
        )

        action_message = live.send.await_args_list[-1].args[0]
        self.assertEqual(action_message["type"], "agent.actions")
        self.assertEqual(action_message["step"], 1)
        self.assertEqual(action_message["maxSteps"], 8)
        self.assertTrue(action_message["batchId"])
        self.assertEqual(action_message["actions"][0]["fieldId"], "name")

    async def test_new_user_turn_cancels_a_pending_browser_run(self) -> None:
        live = session._LiveSession(MagicMock())
        live.execution.start()
        live.execution.issue([Action(field_id="name", action="fill", value="Ada")])
        live._respond = AsyncMock()  # type: ignore[method-assign]

        await live._begin_response(utterance="Stop and do something else")
        self.assertFalse(live.execution.active)
        self.assertIsNone(live.execution.pending)
        self.assertEqual(live.history[-1].text, "Stop and do something else")
        if live.response_task is not None:
            await live.response_task

    def test_pause_resume_and_cancel_are_idempotent_and_gate_fresh_pages(self) -> None:
        loop = session.ExecutionLoop()
        action = Action(field_id="name", action="fill", value="Ada")
        loop.start()
        batch = loop.issue([action])

        self.assertTrue(loop.pause())
        self.assertFalse(loop.pause())
        self.assertFalse(loop.can_continue)

        # Results from the already-issued batch remain useful evidence, but a
        # paused run must not use them to issue a new autonomous step.
        loop.accept_observation(
            batch.batch_id,
            [ActionResult.model_validate({"fieldId": "name", "ok": True})],
        )
        self.assertEqual(loop.completed_steps, 1)
        self.assertFalse(loop.can_continue)

        self.assertTrue(loop.resume())
        self.assertFalse(loop.resume())
        self.assertTrue(loop.needs_fresh_page)
        self.assertFalse(loop.can_continue)
        self.assertTrue(loop.record_fresh_page())
        self.assertTrue(loop.can_continue)

        next_batch = loop.issue([action])
        self.assertTrue(loop.cancel())
        self.assertFalse(loop.cancel())
        with self.assertRaisesRegex(ValueError, "no browser action batch"):
            loop.accept_observation(
                next_batch.batch_id,
                [ActionResult.model_validate({"fieldId": "name", "ok": True})],
            )

    def test_skip_invalidates_pending_batch_without_completing_actions(self) -> None:
        loop = session.ExecutionLoop()
        action = Action(field_id="name", action="fill", value="Ada")
        loop.start()
        batch = loop.issue([action])

        self.assertTrue(loop.skip_current_step())
        self.assertFalse(loop.skip_current_step())
        self.assertEqual(loop.completed_steps, 0)
        self.assertIsNone(loop.pending)
        self.assertTrue(loop.needs_fresh_page)
        with self.assertRaisesRegex(ValueError, "no browser action batch"):
            loop.accept_observation(
                batch.batch_id,
                [ActionResult.model_validate({"fieldId": "name", "ok": True})],
            )
        self.assertTrue(loop.record_fresh_page())
        self.assertTrue(loop.can_continue)

    async def test_paused_observation_is_recorded_but_does_not_replan(self) -> None:
        live = session._LiveSession(MagicMock())
        live.page = self.page()
        live.send = AsyncMock()  # type: ignore[method-assign]
        action = Action(field_id="name", action="fill", value="Ada")
        live.history = [Turn(role="agent", text="", actions=[action])]
        live.execution.start()
        batch = live.execution.issue([action])
        live.execution.pause()
        live._begin_observation_response = AsyncMock()  # type: ignore[method-assign]

        await live._handle_observation(
            {
                "type": "agent.observation",
                "batchId": batch.batch_id,
                "results": [{"fieldId": "name", "ok": True}],
                "page": self.page("After action").model_dump(by_alias=True),
            }
        )

        self.assertEqual(live.execution.completed_steps, 1)
        self.assertTrue(live.history[0].results[0].ok)
        live._begin_observation_response.assert_not_awaited()

    async def test_skip_replans_from_new_page_without_recording_success(self) -> None:
        live = session._LiveSession(MagicMock())
        live.page = self.page()
        action = Action(field_id="name", action="fill", value="Ada")
        live.history = [Turn(role="agent", text="", actions=[action])]
        live.execution.start()
        batch = live.execution.issue([action])
        live._begin_observation_response = AsyncMock()  # type: ignore[method-assign]

        await live._handle_skip(
            {
                "type": "agent.skip",
                "page": self.page("Fresh after skip").model_dump(by_alias=True),
            }
        )

        self.assertEqual(live.page.title, "Fresh after skip")
        self.assertEqual(live.execution.completed_steps, 0)
        self.assertEqual(live.history[0].results, [])
        live._begin_observation_response.assert_awaited_once()
        text, = live._begin_observation_response.await_args.args
        self.assertIn("without assuming any skipped action succeeded", text)
        with self.assertRaisesRegex(ValueError, "no browser action batch"):
            live.execution.accept_observation(
                batch.batch_id,
                [ActionResult.model_validate({"fieldId": "name", "ok": True})],
            )

    async def test_step_limit_stops_without_replanning(self) -> None:
        live = session._LiveSession(MagicMock())
        live.page = self.page()
        live.execution = session.ExecutionLoop(max_steps=1)
        live.send = AsyncMock()  # type: ignore[method-assign]
        action = Action(field_id="name", action="fill", value="Ada")
        live.history = [Turn(role="agent", text="", actions=[action])]
        live.execution.start()
        batch = live.execution.issue([action])
        live._begin_observation_response = AsyncMock()  # type: ignore[method-assign]

        await live._handle_observation(
            {
                "type": "agent.observation",
                "batchId": batch.batch_id,
                "results": [{"fieldId": "name", "ok": True}],
                "page": self.page().model_dump(by_alias=True),
            }
        )

        self.assertFalse(live.execution.active)
        live._begin_observation_response.assert_not_awaited()
        self.assertEqual(live.send.await_args_list[-1].args[0], {"type": "state", "state": "listening"})


class ActionSafetyTests(unittest.TestCase):
    def test_action_result_accepts_selector_healing_evidence(self) -> None:
        result = ActionResult.model_validate(
            {
                "fieldId": "phone",
                "ok": True,
                "healed": True,
                "healingConfidence": 0.91,
            }
        )
        self.assertTrue(result.healed)
        self.assertEqual(result.healing_confidence, 0.91)

    def test_observation_exposes_only_browser_verified_tab_reference(self) -> None:
        text = session._action_result_text(
            [
                ActionResult.model_validate(
                    {
                        "fieldId": "browser:new",
                        "ok": True,
                        "verification": {
                            "tabId": 42,
                            "url": "https://example.test/next",
                            "title": "Next",
                        },
                    }
                )
            ]
        )
        self.assertIn("controlled tab 42", text)

    def test_server_drops_submit_and_unknown_actions(self) -> None:
        page = PageContext.model_validate(
            {
                "url": "https://example.test/apply",
                "title": "Apply",
                "fields": [],
                "controls": [
                    {
                        "controlId": "submit",
                        "label": "Submit application",
                        "role": "submit",
                    },
                    {"controlId": "next", "label": "Next", "role": "button"},
                ],
            }
        )
        actions = [
            Action(field_id="submit", action="click"),
            Action(field_id="missing", action="click"),
            Action(field_id="next", action="click"),
        ]
        self.assertEqual(
            [action.field_id for action in session._safe_actions(page, actions)],
            ["next"],
        )

    def test_navigation_requires_the_advertised_capability(self) -> None:
        page = PageContext.model_validate(
            {
                "url": "https://example.test/one",
                "title": "One",
                "fields": [],
                "controls": [],
            }
        )
        action = Action(field_id="browser:active", action="go_back")
        self.assertEqual(session._safe_actions(page, [action]), [])
        page.capabilities = ["browserNavigation"]
        self.assertEqual(session._safe_actions(page, [action]), [action])


if __name__ == "__main__":
    unittest.main(verbosity=2)
