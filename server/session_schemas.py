"""Live voice-session protocol.

Mirrors `extension/src/types/session.ts` — change both together.

One WebSocket carries JSON control messages both ways plus base64 audio, so a
chunk can never overtake the state change that explains it.

Audio in is base64 Int16 PCM at 16 kHz. Sarvam's streaming STT accepts
wav / pcm_s16le / pcm_l16 / pcm_raw only — webm/opus is rejected, so the client
captures raw PCM via AudioWorklet rather than MediaRecorder.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from schemas import (
    Action,
    ActionResult,
    Base,
    ContextUsage,
    MemoryUpdate,
    PageContext,
)

AgentState = Literal[
    "connecting", "idle", "listening", "thinking", "speaking", "acting", "error"
]

AUDIO_SAMPLE_RATE = 16_000

# Sarvam streaming STT tuning. Deliberately a shade patient: cutting a speaker
# off mid-thought reads as broken, while a beat of silence reads as listening.
# Turn-taking. The failure these settings exist to prevent is chopping one
# sentence into several turns: people pause mid-thought, and every fragment
# costs a full model call and a spoken reply, so an eager VAD is felt as both
# "it only heard one word" and "it is slow".
VAD_SETTINGS = {
    "vad_signals": "true",
    # Deliberately NOT high sensitivity. High sensitivity ends a turn on the
    # briefest gap, which is exactly the fragmentation we are avoiding.
    "high_vad_sensitivity": "false",
    # Speech must be clearly present before a turn starts, so breaths and room
    # noise do not open one.
    "min_speech_frames": "10",
    # How confident the detector must be that a frame is speech. The default is
    # permissive enough that keyboard noise and background conversation open
    # turns, which the recogniser then dutifully transcribes as nonsense.
    "positive_speech_threshold": "0.6",
    "negative_speech_threshold": "0.4",
    # Silence required before a turn is considered finished. This is the single
    # most important value here: it is the pause you are allowed to take
    # mid-sentence without being cut off.
    "negative_frames_count": "28",
    "negative_frames_window": "36",
    # Audio retained from before the trigger, so the first phoneme survives.
    "pre_speech_pad_frames": "10",
    # Barge-in stays responsive: interrupting the agent should feel instant
    # even though ending a turn is patient.
    "interrupt_min_speech_frames": "4",
}


class SessionStart(Base):
    session_id: str
    page: PageContext


class AgentObservation(Base):
    """One atomic browser observation after an emitted action batch.

    Keeping results and the refreshed page together prevents the server from
    continuing a task against stale DOM context after navigation.
    """

    batch_id: str
    results: list[ActionResult]
    page: PageContext


class AgentPause(Base):
    """Explicit UI control; natural-language turns are never inferred as this."""

    type: Literal["agent.pause"]


class AgentResume(Base):
    """Resume with the current page, which is required before replanning."""

    type: Literal["agent.resume"]
    page: PageContext


class AgentCancel(Base):
    """Explicit UI control that invalidates an in-flight browser batch."""

    type: Literal["agent.cancel"]


class AgentSkip(Base):
    """Skip the outstanding batch and replan only from this fresh page."""

    type: Literal["agent.skip"]
    page: PageContext


class TurnResult(Base):
    """One turn's output: what to say, what to do, what was learned."""

    speech: str = ""
    actions: list[Action] = Field(default_factory=list)
    question: str | None = None
    memory_updates: list[MemoryUpdate] = Field(default_factory=list)
    relevant_context: list[ContextUsage] = Field(default_factory=list)
    excluded_context: list[ContextUsage] = Field(default_factory=list)
    # Set when the agent believes the task is finished, so the UI can settle.
    done: bool = False


class Turn(Base):
    """A single exchange, kept in session history."""

    role: Literal["user", "agent"]
    text: str
    actions: list[Action] = Field(default_factory=list)
    results: list[ActionResult] = Field(default_factory=list)
