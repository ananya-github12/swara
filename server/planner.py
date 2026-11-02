"""Gemini-backed form planning."""

from __future__ import annotations

from typing import Any

from config import require
from context_store import list_context
from prompts import SYSTEM_PROMPT, build_user_prompt
from schemas import ContextItem, PlanRequest, PlanResponse


# Pinned deliberately rather than using -latest: a model swapping under us
# mid-demo is not a risk worth taking. 2.5-flash is retired for new API keys.
MODEL = "gemini-3.6-flash"


def _context_for_session(session_id: str) -> list[ContextItem]:
    """Persistent profile plus session/task instructions for this form only."""
    items = [
        *list_context(scope="persistent"),
        *list_context(scope="session", session_id=session_id),
        *list_context(scope="task", session_id=session_id),
    ]
    # Keys can appear in multiple scope levels; retain each row while avoiding
    # an accidental duplicate returned by a backend query.
    seen: set[str] = set()
    unique = []
    for item in items:
        marker = item.id or f"{item.scope}:{item.session_id}:{item.key}:{item.value}"
        if marker not in seen:
            seen.add(marker)
            unique.append(item)
    return unique


def plan(request: PlanRequest) -> PlanResponse:
    """Request a strictly schema-shaped plan from Gemini.

    Credential and network errors intentionally propagate: callers receive a
    clear service error rather than a fabricated form plan.
    """
    try:
        from google import genai
        from google.genai import types
    except ImportError as exc:
        raise RuntimeError("Google Gen AI SDK is unavailable. Install server/requirements.txt.") from exc

    client = genai.Client(api_key=require("GOOGLE_API_KEY"))
    response = client.models.generate_content(
        model=MODEL,
        contents=build_user_prompt(request, _context_for_session(request.session_id)),
        config=types.GenerateContentConfig(
            # Carried as a system instruction rather than a turn, so it keeps
            # its weight when later turns are appended.
            system_instruction=SYSTEM_PROMPT,
            response_mime_type="application/json",
            response_schema=PlanResponse,
        ),
    )

    try:
        return PlanResponse.model_validate_json(response.text or "")
    except Exception as exc:
        return PlanResponse(
            status="needs_clarification",
            clarifications=[f"Could not parse Gemini's structured response: {exc}"],
        )
