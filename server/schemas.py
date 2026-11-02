"""Shared contract schemas for Swara.

This mirrors `extension/src/types/index.ts`. The two files are one contract in
two languages — change both together or the halves silently disagree.

Wire format is camelCase (the extension speaks TypeScript); the aliases below
handle the translation so Python code stays snake_case.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

FieldType = Literal[
    "text", "textarea", "select", "checkbox", "radio", "contenteditable"
]
ActionType = Literal[
    "fill", "select", "check", "uncheck", "clear", "click", "scroll_to",
    "open_url", "navigate", "open_tab", "switch_tab", "close_tab",
    "go_back", "go_forward", "wait_for_page",
]
AssistantCapability = Literal[
    "readablePageText", "contentEditableFill", "openUrl", "browserNavigation"
]
MemoryType = Literal["fact", "correction", "preference", "instruction"]
MemoryScope = Literal["persistent", "session", "task"]
ContextItemType = Literal[
    "fact", "document", "preference", "correction", "instruction"
]


class Base(BaseModel):
    """camelCase on the wire, snake_case in Python, populate by either name."""

    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
    )


# --------------------------------------------------------------------- #
# Page / form extraction
# --------------------------------------------------------------------- #


class FieldOption(Base):
    value: str
    label: str


class FormField(Base):
    field_id: str
    label: str
    question: str
    type: FieldType
    required: bool = False
    options: list[FieldOption] = Field(default_factory=list)
    placeholder: str | None = None
    max_length: int | None = None
    current_value: str | None = None


class PageControl(Base):
    """A clickable control on the page.

    `role="submit"` marks anything whose label reads as irreversible (submit,
    apply, send, pay, delete). The executor refuses those outright — the agent
    must never be able to submit someone's job application.
    """

    control_id: str
    label: str
    role: Literal["button", "link", "tab", "submit"] = "button"
    disabled: bool = False


class PageContext(Base):
    url: str
    title: str
    heading: str | None = None
    readable_text: str | None = None
    capabilities: list[AssistantCapability] | None = None
    fields: list[FormField] = Field(default_factory=list)
    controls: list[PageControl] = Field(default_factory=list)


# --------------------------------------------------------------------- #
# Actions
# --------------------------------------------------------------------- #


class Action(Base):
    field_id: str
    action: ActionType
    value: str = ""
    reasoning: str | None = None


class ActionVerification(Base):
    """Browser-observed navigation state attached to an action result."""

    url: str | None = None
    title: str | None = None
    tab_id: int | None = None
    ready: bool | None = None
    navigated: bool | None = None


class ActionResult(Base):
    """Reported back by the content script so the agent can be honest about
    what actually happened rather than assuming its plan succeeded."""

    field_id: str
    ok: bool
    error: str | None = None
    # A deterministic content-script recovery may attach its match evidence.
    healed: bool | None = None
    healing_confidence: float | None = Field(default=None, ge=0, le=1)
    # Navigation actions attach the browser-observed destination. This is
    # additive, so older extension builds can continue to report field results.
    verification: ActionVerification | None = None


# --------------------------------------------------------------------- #
# Memory classification
# --------------------------------------------------------------------- #


class MemoryUpdate(Base):
    type: MemoryType
    key: str
    value: str
    old_value: str | None = None
    scope: MemoryScope
    reason: str


# --------------------------------------------------------------------- #
# Planning
# --------------------------------------------------------------------- #


class ContextUsage(Base):
    key: str
    summary: str
    reason: str


class PlanRequest(Base):
    session_id: str
    page: PageContext
    instruction: str


class MemoryApplyRequest(Base):
    """Commit the memory the planner proposed, once the user accepts the plan.

    Applied on confirmation rather than at plan time: the preview promises
    "here is what I will remember", so nothing is remembered until the user
    agrees to it, and re-planning cannot accumulate duplicates.
    """

    session_id: str
    memory_updates: list[MemoryUpdate] = Field(default_factory=list)


class PlanResponse(Base):
    status: Literal["ready", "needs_clarification"] = "ready"
    actions: list[Action] = Field(default_factory=list)
    clarifications: list[str] = Field(default_factory=list)
    memory_updates: list[MemoryUpdate] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)
    relevant_context: list[ContextUsage] = Field(default_factory=list)
    excluded_context: list[ContextUsage] = Field(default_factory=list)
    spoken_summary: str = ""


# --------------------------------------------------------------------- #
# Voice
# --------------------------------------------------------------------- #

SarvamLanguage = Literal[
    "unknown",  # lets Saarika auto-detect code-switched speech
    "en-IN", "hi-IN", "ta-IN", "te-IN", "kn-IN", "ml-IN",
    "mr-IN", "bn-IN", "gu-IN", "pa-IN", "od-IN",
]


class TranscriptResponse(Base):
    transcript: str
    language: str | None = None


class SpeechRequest(Base):
    text: str
    # Always explicit: leaving the language unset skews Bulbul's pronunciation.
    language: SarvamLanguage = "en-IN"


class SpeechResponse(Base):
    audio_base64: str
    mime_type: str = "audio/wav"


# --------------------------------------------------------------------- #
# Context vault rows (mirrors the Supabase schema)
# --------------------------------------------------------------------- #


class ContextItem(Base):
    id: str | None = None
    type: ContextItemType
    category: str | None = None
    key: str
    value: str
    source: str | None = None
    source_type: str | None = None
    confidence: float = 1.0
    scope: MemoryScope = "persistent"
    session_id: str | None = None
    document_id: str | None = None
    superseded_by: str | None = None
