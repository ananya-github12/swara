"""Private, request-scoped execution persistence for Swara.

This repository is deliberately narrower than the browser execution loop.  It
persists only the redacted operational columns defined in the private execution
schema: no instructions, filled values, browser content, cookies, screenshots,
or provider request/response bodies can cross this boundary.
"""

from __future__ import annotations

import inspect
import json
import re
from collections.abc import Mapping, Sequence
from typing import Any, Final, Protocol, TypeVar
from urllib.parse import urlsplit
from uuid import UUID

from server.database import DatabasePool
from server.request_context import RequestContext
from server.repositories.common import NotFoundError, RepositoryError


class _Connection(Protocol):
    def execute(self, query: str, params: Sequence[Any]) -> Any: ...


_Row = TypeVar("_Row")

_UUID_PATTERN: Final = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z"
)
_HASH_PATTERN: Final = re.compile(r"[0-9a-f]{64}\Z")
_CODE_PATTERN: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*\Z")
_MODEL_PATTERN: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}\Z")

_SESSION_MODES: Final = frozenset({"browser", "voice", "hybrid"})
_SESSION_CLOSE_STATUSES: Final = frozenset({"ended", "failed", "revoked"})
_TASK_KINDS: Final = frozenset({"browser", "voice", "workflow", "hybrid"})
_TASK_STATUSES: Final = frozenset(
    {"queued", "running", "paused", "cancelled", "succeeded", "failed", "safety_blocked", "expired"}
)
_TASK_TERMINAL_STATUSES: Final = frozenset(
    {"cancelled", "succeeded", "failed", "safety_blocked", "expired"}
)
_CHECKPOINT_TASK_STATUSES: Final = frozenset(
    {"running", "paused", "cancelled", "succeeded", "failed", "safety_blocked"}
)
_STEP_ACTIONS: Final = frozenset(
    {
        "navigate",
        "read",
        "click",
        "fill",
        "select",
        "scroll",
        "wait",
        "download",
        "upload",
        "submit",
        "script",
        "safety_check",
        "other",
    }
)
_STEP_STATUSES: Final = frozenset(
    {"planned", "dispatched", "running", "paused", "skipped", "cancelled", "succeeded", "failed", "safety_blocked"}
)
_STEP_TERMINAL_STATUSES: Final = frozenset(
    {"skipped", "cancelled", "succeeded", "failed", "safety_blocked"}
)
_HEALING_STATUSES: Final = frozenset({"not_attempted", "attempted", "healed", "rejected"})
_EVENT_TYPES: Final = frozenset(
    {
        "planned",
        "dispatched",
        "paused",
        "resumed",
        "skipped",
        "cancelled",
        "succeeded",
        "failed",
        "safety-blocked",
        "selector-healed",
    }
)
_PROVIDER_OPERATIONS: Final = frozenset({"llm", "stt", "tts", "ocr", "embedding", "browser", "other"})
_PROVIDER_STATUSES: Final = frozenset({"queued", "running", "succeeded", "failed", "cancelled"})

_STEP_FIELDS: Final = frozenset(
    {
        "action_type",
        "target_fingerprint_hash",
        "status",
        "healed",
        "healing_status",
        "healing_confidence",
        "healing_metadata",
        "verification",
        "latency_ms",
        "error_code",
    }
)
_HEALING_METADATA_FIELDS: Final = frozenset(
    {"strategy", "candidate_count", "candidate_fingerprint_hash"}
)
_VERIFICATION_FIELDS: Final = frozenset(
    {"outcome", "assertion_count", "content_hash", "url_hash", "safety_rule_id"}
)
_EVENT_METADATA_FIELDS: Final = frozenset(
    {
        "reason_code",
        "checkpoint_count",
        "message_hash",
        "source_origin_hash",
        "safety_rule_id",
        "retry_count",
        "provider",
        "operation",
    }
)
_PROVIDER_FIELDS: Final = frozenset(
    {
        "provider",
        "model",
        "operation",
        "status",
        "input_tokens",
        "output_tokens",
        "audio_input_seconds",
        "audio_output_seconds",
        "ocr_pages",
        "latency_ms",
        "retry_count",
        "provider_request_id",
        "estimated_cost_micros",
        "billed_cost_micros",
        "currency_code",
        "error_code",
    }
)
_FORBIDDEN_FIELDS: Final = frozenset(
    {
        "api_key",
        "authorization",
        "browser_content",
        "cookie",
        "cookies",
        "dom",
        "filled_value",
        "html",
        "instruction",
        "instructions",
        "payload",
        "provider_payload",
        "raw_instruction",
        "request",
        "response",
        "screenshot",
        "screenshot_bytes",
        "token",
        "transcript",
        "value",
    }
)

_RETURNING_SESSION: Final = "id, user_id, device_id, status, interaction_mode, started_at, correlation_id"
_RETURNING_TASK: Final = "id, user_id, session_id, status, completed_steps, correlation_id, created_at"
_RETURNING_STEP: Final = "id, user_id, task_id, sequence, action_index, status, batch_id, created_at"
_RETURNING_EVENT: Final = "id, user_id, task_id, step_id, sequence, event_type, occurred_at"
_RETURNING_PROVIDER_CALL: Final = "id, user_id, task_id, step_id, provider, operation, status, started_at"


def _reject_unknown_fields(value: Mapping[str, Any], allowed: frozenset[str], *, label: str) -> None:
    keys = set(value)
    forbidden = keys & _FORBIDDEN_FIELDS
    if forbidden:
        raise ValueError(f"{label} contains forbidden privacy fields")
    if keys - allowed:
        raise ValueError(f"{label} contains unsupported fields")


def _safe_code(value: Any, *, field: str, maximum: int = 128) -> str:
    if (
        not isinstance(value, str)
        or not _CODE_PATTERN.fullmatch(value)
        or not 1 <= len(value) <= maximum
    ):
        raise ValueError(f"{field} is invalid")
    return value


def _safe_optional_code(value: Any, *, field: str, maximum: int = 128) -> str | None:
    if value is None:
        return None
    return _safe_code(value, field=field, maximum=maximum)


def _safe_uuid(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not _UUID_PATTERN.fullmatch(value):
        raise ValueError(f"{field} must be a UUID")
    try:
        parsed = UUID(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} must be a UUID") from None
    if str(parsed) != value:
        raise ValueError(f"{field} must be a canonical UUID")
    return value


def _safe_hash(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not _HASH_PATTERN.fullmatch(value):
        raise ValueError(f"{field} must be a lowercase SHA-256 hash")
    return value


def _safe_nonnegative_int(value: Any, *, field: str, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise ValueError(f"{field} is invalid")
    return value


def _safe_optional_nonnegative_int(value: Any, *, field: str, maximum: int) -> int | None:
    if value is None:
        return None
    return _safe_nonnegative_int(value, field=field, maximum=maximum)


def _safe_nonnegative_number(value: Any, *, field: str, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} is invalid")
    value = float(value)
    if not 0 <= value <= maximum:
        raise ValueError(f"{field} is invalid")
    return value


def _safe_optional_text(value: Any, *, field: str, maximum: int) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or value != value.strip() or len(value) > maximum:
        raise ValueError(f"{field} is invalid")
    if any(ord(character) < 32 and character not in "\n\r\t" for character in value):
        raise ValueError(f"{field} is invalid")
    return value


def _safe_origin(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or value != value.strip() or len(value) > 2048:
        raise ValueError("source_origin is invalid")
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("source_origin is invalid")
    return f"{parsed.scheme.lower()}://{parsed.netloc.lower()}"


def _json(value: Mapping[str, Any]) -> str:
    """Encode already validated scalar-only metadata for psycopg jsonb input."""

    return json.dumps(dict(value), separators=(",", ":"), sort_keys=True)


async def _await_if_needed(value: _Row | Any) -> _Row:
    if inspect.isawaitable(value):
        return await value
    return value


async def _execute(connection: _Connection, query: str, params: Sequence[Any]) -> Any:
    return await _await_if_needed(connection.execute(query, params))


async def _fetch_one(cursor: Any) -> Any:
    fetchone = getattr(cursor, "fetchone", None)
    if fetchone is None:
        raise RepositoryError("Execution persistence returned an invalid response")
    return await _await_if_needed(fetchone())


def _row_to_mapping(cursor: Any, row: Any, fields: str) -> dict[str, Any]:
    if isinstance(row, Mapping):
        return dict(row)
    if isinstance(row, Sequence) and not isinstance(row, (str, bytes, bytearray)):
        description = getattr(cursor, "description", None)
        names = (
            [getattr(column, "name", column[0]) for column in description]
            if description
            else fields.split(", ")
        )
        if len(names) == len(row):
            return dict(zip(names, row, strict=True))
    raise RepositoryError("Execution persistence returned an invalid response")


class ExecutionRepository:
    """Persist one verified user's redacted browser and provider operations.

    Direct use is server-only: the private schema has no browser grants.  The
    explicit ``user_id`` predicates below remain mandatory defence in depth
    should a trusted connection ever be configured incorrectly.
    """

    def __init__(self, database: DatabasePool, context: RequestContext) -> None:
        self._database = database
        self._context = context

    @property
    def user_id(self) -> str:
        """Return only the verified request identity, never a caller value."""

        return self._context.user_id

    async def open_browser_session(
        self,
        *,
        extension_version: str,
        policy_version: str,
        interaction_mode: str = "browser",
        server_region: str | None = None,
    ) -> dict[str, Any]:
        """Open an active session only for the context's registered device."""

        device_id = _safe_uuid(self._context.device_id, field="context device_id")
        extension_version = _safe_code(extension_version, field="extension_version")
        policy_version = _safe_code(policy_version, field="policy_version", maximum=255)
        if interaction_mode not in _SESSION_MODES:
            raise ValueError("interaction_mode is invalid")
        server_region = _safe_optional_code(server_region, field="server_region")

        query = f"""
            insert into private.browser_sessions (
              user_id, device_id, status, interaction_mode, server_region,
              extension_version, policy_version, correlation_id
            )
            select %s, device.id, 'active', %s, %s, %s, %s, %s
            from public.devices as device
            where device.id = %s
              and device.user_id = %s
              and device.revoked_at is null
            returning {_RETURNING_SESSION}
        """
        return await self._one(query, (
            self.user_id,
            interaction_mode,
            server_region,
            extension_version,
            policy_version,
            self._context.correlation_id,
            device_id,
            self.user_id,
        ), _RETURNING_SESSION)

    async def close_browser_session(
        self,
        session_id: str,
        *,
        status: str = "ended",
        error_code: str | None = None,
    ) -> dict[str, Any]:
        """Close only an owned session, retaining an opaque diagnostic code."""

        session_id = _safe_uuid(session_id, field="session_id")
        if status not in _SESSION_CLOSE_STATUSES:
            raise ValueError("session close status is invalid")
        error_code = _safe_optional_code(error_code, field="error_code")
        query = f"""
            update private.browser_sessions as session
            set status = %s,
                ended_at = pg_catalog.now(),
                error_code = %s
            where session.id = %s
              and session.user_id = %s
              and exists (
                select 1
                from public.devices as device
                where device.id = session.device_id
                  and device.user_id = session.user_id
              )
              and session.status not in ('ended', 'failed', 'revoked')
            returning {_RETURNING_SESSION}
        """
        return await self._one(query, (status, error_code, session_id, self.user_id), _RETURNING_SESSION)

    async def create_task(
        self,
        session_id: str,
        *,
        redacted_summary: str | None,
        diagnostic_hash: str,
        policy_version: str,
        extension_version: str,
        task_kind: str = "browser",
        source_origin: str | None = None,
        max_steps: int = 25,
        history_enabled: bool = False,
    ) -> dict[str, Any]:
        """Create a task with only a redacted summary and one-way hash."""

        session_id = _safe_uuid(session_id, field="session_id")
        redacted_summary = _safe_optional_text(
            redacted_summary, field="redacted_summary", maximum=2000
        )
        diagnostic_hash = _safe_hash(diagnostic_hash, field="diagnostic_hash")
        policy_version = _safe_code(policy_version, field="policy_version", maximum=255)
        extension_version = _safe_code(extension_version, field="extension_version")
        if task_kind not in _TASK_KINDS:
            raise ValueError("task_kind is invalid")
        source_origin = _safe_origin(source_origin)
        if isinstance(max_steps, bool) or not isinstance(max_steps, int) or not 1 <= max_steps <= 1000:
            raise ValueError("max_steps is invalid")
        if not isinstance(history_enabled, bool):
            raise ValueError("history_enabled must be a boolean")

        query = f"""
            insert into private.agent_tasks (
              user_id, session_id, task_kind, source_origin, status,
              instruction_summary, instruction_hash, history_enabled,
              policy_version, extension_version, max_steps, correlation_id
            )
            select %s, session.id, %s, %s, 'queued', %s, %s, %s, %s, %s, %s, %s
            from private.browser_sessions as session
            where session.id = %s
              and session.user_id = %s
              and session.status in ('starting', 'active', 'paused')
            returning {_RETURNING_TASK}
        """
        return await self._one(query, (
            self.user_id,
            task_kind,
            source_origin,
            redacted_summary,
            diagnostic_hash,
            history_enabled,
            policy_version,
            extension_version,
            max_steps,
            self._context.correlation_id,
            session_id,
            self.user_id,
        ), _RETURNING_TASK)

    async def append_event(
        self,
        task_id: str,
        *,
        sequence: int,
        event_type: str,
        event_metadata: Mapping[str, Any] | None = None,
        step_id: str | None = None,
        error_code: str | None = None,
    ) -> dict[str, Any]:
        """Append one owned, redacted execution timeline event."""

        task_id = _safe_uuid(task_id, field="task_id")
        sequence = _safe_nonnegative_int(sequence, field="event sequence", maximum=100_000)
        if sequence < 1:
            raise ValueError("event sequence is invalid")
        if event_type not in _EVENT_TYPES:
            raise ValueError("event_type is invalid")
        step_id = None if step_id is None else _safe_uuid(step_id, field="step_id")
        if event_type == "selector-healed" and step_id is None:
            raise ValueError("selector-healed events require a step_id")
        metadata = self._event_metadata(event_metadata)
        error_code = _safe_optional_code(error_code, field="error_code")
        return await self._append_event(
            task_id=task_id,
            sequence=sequence,
            event_type=event_type,
            metadata=metadata,
            step_id=step_id,
            error_code=error_code,
            connection=None,
        )

    async def persist_observation_checkpoint(
        self,
        task_id: str,
        *,
        batch_id: str,
        sequence: int,
        steps: Sequence[Mapping[str, Any]],
        event_sequence: int,
        event_type: str = "dispatched",
        event_metadata: Mapping[str, Any] | None = None,
        task_status: str = "running",
    ) -> dict[str, Any]:
        """Durably commit one browser observation as an all-or-nothing unit.

        ``sequence`` identifies the whole browser batch, not an individual
        action.  Action mappings deliberately cannot choose either a sequence
        or an action index: this repository assigns contiguous, zero-based
        ``action_index`` values in the caller's action order.  The ordered
        inserts, append-only event, and task progress update share one database
        transaction.  A database trigger separately rejects ownership,
        sequence, batch, and max-step violations at the schema boundary.
        """

        task_id = _safe_uuid(task_id, field="task_id")
        batch_id = _safe_uuid(batch_id, field="batch_id")
        sequence = _safe_nonnegative_int(sequence, field="checkpoint sequence", maximum=1000)
        if sequence < 1:
            raise ValueError("checkpoint sequence is invalid")
        normalized_steps = self._checkpoint_steps(steps, sequence=sequence)
        event_sequence = _safe_nonnegative_int(
            event_sequence, field="event sequence", maximum=100_000
        )
        if event_sequence < 1:
            raise ValueError("event sequence is invalid")
        if event_type not in _EVENT_TYPES:
            raise ValueError("event_type is invalid")
        if task_status not in _CHECKPOINT_TASK_STATUSES:
            raise ValueError("task_status is invalid")
        metadata = self._event_metadata(event_metadata)
        if "checkpoint_count" in metadata and metadata["checkpoint_count"] != len(normalized_steps):
            raise ValueError("checkpoint_count is controlled by the repository")
        metadata["checkpoint_count"] = len(normalized_steps)

        try:
            async with self._database.transaction() as connection:
                task = await self._owned_task_for_update(connection, task_id)
                if task.get("status") in _TASK_TERMINAL_STATUSES:
                    raise RepositoryError("Execution task is not active")

                inserted_steps: list[dict[str, Any]] = []
                for step in normalized_steps:
                    inserted = await self._insert_checkpoint_step(connection, task_id, batch_id, step)
                    inserted_steps.append(
                        self._checkpoint_insert_invariant(
                            inserted,
                            user_id=self.user_id,
                            task_id=task_id,
                            batch_id=batch_id,
                            sequence=sequence,
                            action_index=step["action_index"],
                        )
                    )
                inserted_steps.sort(key=lambda step: step["action_index"])
                self._checkpoint_batch_invariant(
                    inserted_steps,
                    user_id=self.user_id,
                    task_id=task_id,
                    batch_id=batch_id,
                    sequence=sequence,
                )

                event_step_id = None
                if event_type == "selector-healed":
                    event_step_id = self._id_from_row(inserted_steps[-1], field="checkpoint step")
                event = await self._append_event(
                    task_id=task_id,
                    sequence=event_sequence,
                    event_type=event_type,
                    metadata=metadata,
                    step_id=event_step_id,
                    error_code=None,
                    connection=connection,
                )
                task = await self._advance_task(
                    connection,
                    task_id=task_id,
                    completed_steps=sequence,
                    status=task_status,
                )
        except (NotFoundError, RepositoryError):
            raise
        except Exception:
            raise RepositoryError("Execution checkpoint failed") from None

        return {"task": task, "steps": inserted_steps, "event": event}

    async def record_provider_call(
        self,
        task_id: str,
        metrics: Mapping[str, Any],
        *,
        step_id: str | None = None,
    ) -> dict[str, Any]:
        """Record allowlisted operational metrics without provider content."""

        task_id = _safe_uuid(task_id, field="task_id")
        step_id = None if step_id is None else _safe_uuid(step_id, field="step_id")
        values = self._provider_metrics(metrics)
        query = f"""
            insert into private.provider_calls (
              user_id, task_id, step_id, provider, model, operation, status,
              input_tokens, output_tokens, audio_input_seconds, audio_output_seconds,
              ocr_pages, latency_ms, retry_count, provider_request_id,
              estimated_cost_micros, billed_cost_micros, currency_code,
              correlation_id, error_code, completed_at
            )
            select %s, task.id, step.id, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                   %s, %s, %s, %s, %s, %s, %s, %s,
                   case when %s in ('succeeded', 'failed', 'cancelled') then pg_catalog.now() else null end
            from private.agent_tasks as task
            join private.browser_sessions as session
              on session.id = task.session_id
             and session.user_id = task.user_id
            left join private.task_steps as step
              on step.id = %s
             and step.task_id = task.id
             and step.user_id = task.user_id
            where task.id = %s
              and task.user_id = %s
              and (%s::uuid is null or step.id is not null)
            returning {_RETURNING_PROVIDER_CALL}
        """
        params = (
            self.user_id,
            values["provider"],
            values["model"],
            values["operation"],
            values["status"],
            values["input_tokens"],
            values["output_tokens"],
            values["audio_input_seconds"],
            values["audio_output_seconds"],
            values["ocr_pages"],
            values["latency_ms"],
            values["retry_count"],
            values["provider_request_id"],
            values["estimated_cost_micros"],
            values["billed_cost_micros"],
            values["currency_code"],
            self._context.correlation_id,
            values["error_code"],
            values["status"],
            step_id,
            task_id,
            self.user_id,
            step_id,
        )
        return await self._one(query, params, _RETURNING_PROVIDER_CALL)

    async def _owned_task_for_update(self, connection: _Connection, task_id: str) -> dict[str, Any]:
        query = """
            select task.id, task.user_id, task.status, task.completed_steps, task.max_steps
            from private.agent_tasks as task
            join private.browser_sessions as session
              on session.id = task.session_id
             and session.user_id = task.user_id
            where task.id = %s
              and task.user_id = %s
            for update
        """
        return await self._one(query, (task_id, self.user_id), "id, user_id, status, completed_steps, max_steps", connection)

    async def _insert_checkpoint_step(
        self,
        connection: _Connection,
        task_id: str,
        batch_id: str,
        step: Mapping[str, Any],
    ) -> dict[str, Any]:
        query = f"""
            insert into private.task_steps (
              user_id, task_id, sequence, batch_id, action_index, action_type,
              target_fingerprint_hash, status, healed, healing_status,
              healing_confidence, healing_metadata, verification, latency_ms,
              error_code, correlation_id, started_at, completed_at
            )
            select %s, task.id, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s::jsonb,
                   %s, %s, %s,
                   case when %s = 'planned' then null else pg_catalog.now() end,
                   case when %s in ('skipped', 'cancelled', 'succeeded', 'failed', 'safety_blocked')
                        then pg_catalog.now() else null end
            from private.agent_tasks as task
            join private.browser_sessions as session
              on session.id = task.session_id
             and session.user_id = task.user_id
            where task.id = %s
              and task.user_id = %s
              and task.status not in ('cancelled', 'succeeded', 'failed', 'safety_blocked', 'expired')
            returning {_RETURNING_STEP}
        """
        return await self._one(query, (
            self.user_id,
            step["sequence"],
            batch_id,
            step["action_index"],
            step["action_type"],
            step["target_fingerprint_hash"],
            step["status"],
            step["healed"],
            step["healing_status"],
            step["healing_confidence"],
            _json(step["healing_metadata"]),
            _json(step["verification"]),
            step["latency_ms"],
            step["error_code"],
            self._context.correlation_id,
            step["status"],
            step["status"],
            task_id,
            self.user_id,
        ), _RETURNING_STEP, connection)

    async def _append_event(
        self,
        *,
        task_id: str,
        sequence: int,
        event_type: str,
        metadata: Mapping[str, Any],
        step_id: str | None,
        error_code: str | None,
        connection: _Connection | None,
    ) -> dict[str, Any]:
        query = f"""
            insert into private.task_events (
              user_id, task_id, step_id, sequence, event_type, event_metadata,
              correlation_id, error_code
            )
            select %s, task.id, step.id, %s, %s, %s::jsonb, %s, %s
            from private.agent_tasks as task
            join private.browser_sessions as session
              on session.id = task.session_id
             and session.user_id = task.user_id
            left join private.task_steps as step
              on step.id = %s
             and step.task_id = task.id
             and step.user_id = task.user_id
            where task.id = %s
              and task.user_id = %s
              and (%s::uuid is null or step.id is not null)
            returning {_RETURNING_EVENT}
        """
        return await self._one(query, (
            self.user_id,
            sequence,
            event_type,
            _json(metadata),
            self._context.correlation_id,
            error_code,
            step_id,
            task_id,
            self.user_id,
            step_id,
        ), _RETURNING_EVENT, connection)

    async def _advance_task(
        self,
        connection: _Connection,
        *,
        task_id: str,
        completed_steps: int,
        status: str,
    ) -> dict[str, Any]:
        query = f"""
            update private.agent_tasks as task
            set completed_steps = greatest(task.completed_steps, %s),
                status = %s,
                started_at = coalesce(task.started_at, pg_catalog.now()),
                completed_at = case
                  when %s in ('cancelled', 'succeeded', 'failed', 'safety_blocked', 'expired')
                    then pg_catalog.now()
                  else null
                end
            where task.id = %s
              and task.user_id = %s
              and exists (
                select 1
                from private.browser_sessions as session
                where session.id = task.session_id
                  and session.user_id = task.user_id
              )
              and task.status not in ('cancelled', 'succeeded', 'failed', 'safety_blocked', 'expired')
            returning {_RETURNING_TASK}
        """
        return await self._one(
            query,
            (completed_steps, status, status, task_id, self.user_id),
            _RETURNING_TASK,
            connection,
        )

    async def _one(
        self,
        query: str,
        params: Sequence[Any],
        fields: str,
        connection: _Connection | None = None,
    ) -> dict[str, Any]:
        try:
            if connection is None:
                async with self._database.transaction() as connection:
                    return await self._one(query, params, fields, connection)
            cursor = await _execute(connection, query, params)
            row = await _fetch_one(cursor)
        except (NotFoundError, RepositoryError):
            raise
        except Exception:
            raise RepositoryError("Execution persistence failed") from None
        if row is None:
            raise NotFoundError("Execution resource not found")
        return _row_to_mapping(cursor, row, fields)

    @staticmethod
    def _id_from_row(row: Mapping[str, Any], *, field: str) -> str:
        try:
            value = row["id"]
            if isinstance(value, UUID):
                value = str(value)
            return _safe_uuid(value, field=f"{field} id")
        except (KeyError, TypeError, ValueError):
            raise RepositoryError("Execution persistence returned an invalid response") from None

    @staticmethod
    def _event_metadata(value: Mapping[str, Any] | None) -> dict[str, Any]:
        if value is None:
            return {}
        if not isinstance(value, Mapping):
            raise ValueError("event_metadata must be a mapping")
        _reject_unknown_fields(value, _EVENT_METADATA_FIELDS, label="event_metadata")
        metadata: dict[str, Any] = {}
        for key, item in value.items():
            if key in {"message_hash", "source_origin_hash"}:
                metadata[key] = _safe_hash(item, field=key)
            elif key in {"checkpoint_count", "retry_count"}:
                metadata[key] = _safe_nonnegative_int(item, field=key, maximum=100_000)
            elif key == "operation":
                if item not in _PROVIDER_OPERATIONS:
                    raise ValueError("event_metadata operation is invalid")
                metadata[key] = item
            elif key == "provider":
                metadata[key] = _safe_code(item, field="event_metadata provider")
            else:
                metadata[key] = _safe_code(item, field=f"event_metadata {key}")
        return metadata

    @staticmethod
    def _checkpoint_steps(
        steps: Sequence[Mapping[str, Any]], *, sequence: int
    ) -> list[dict[str, Any]]:
        if isinstance(steps, (str, bytes, bytearray)) or not isinstance(steps, Sequence):
            raise ValueError("steps must be a non-empty sequence")
        if not 1 <= len(steps) <= 100:
            raise ValueError("steps must contain between 1 and 100 entries")
        normalized: list[dict[str, Any]] = []
        for action_index, step in enumerate(steps):
            checkpoint = ExecutionRepository._checkpoint_step(step)
            checkpoint["sequence"] = sequence
            checkpoint["action_index"] = action_index
            normalized.append(checkpoint)
        ExecutionRepository._checkpoint_batch_invariant(
            normalized,
            user_id=None,
            task_id=None,
            batch_id=None,
            sequence=sequence,
        )
        return normalized

    @staticmethod
    def _checkpoint_step(value: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("checkpoint step must be a mapping")
        _reject_unknown_fields(value, _STEP_FIELDS, label="checkpoint step")
        if not {"action_type", "status"} <= set(value):
            raise ValueError("checkpoint step is missing required fields")
        action_type = value["action_type"]
        if action_type not in _STEP_ACTIONS:
            raise ValueError("action_type is invalid")
        status = value["status"]
        if status not in _STEP_STATUSES:
            raise ValueError("step status is invalid")
        healed = value.get("healed", False)
        if not isinstance(healed, bool):
            raise ValueError("healed must be a boolean")
        healing_status = value.get("healing_status", "not_attempted")
        if healing_status not in _HEALING_STATUSES or (healing_status == "healed") != healed:
            raise ValueError("healing_status is invalid")
        confidence = value.get("healing_confidence")
        if confidence is not None:
            confidence = _safe_nonnegative_number(
                confidence, field="healing_confidence", maximum=1.0
            )
            if healing_status == "not_attempted":
                raise ValueError("healing_confidence requires a healing attempt")
        return {
            "action_type": action_type,
            "target_fingerprint_hash": (
                None
                if value.get("target_fingerprint_hash") is None
                else _safe_hash(value["target_fingerprint_hash"], field="target_fingerprint_hash")
            ),
            "status": status,
            "healed": healed,
            "healing_status": healing_status,
            "healing_confidence": confidence,
            "healing_metadata": ExecutionRepository._healing_metadata(value.get("healing_metadata")),
            "verification": ExecutionRepository._verification(value.get("verification")),
            "latency_ms": _safe_optional_nonnegative_int(
                value.get("latency_ms"), field="latency_ms", maximum=3_600_000
            ),
            "error_code": _safe_optional_code(value.get("error_code"), field="error_code"),
        }

    @staticmethod
    def _returned_uuid(value: Any, *, field: str) -> str:
        if isinstance(value, UUID):
            value = str(value)
        return _safe_uuid(value, field=field)

    @classmethod
    def _checkpoint_insert_invariant(
        cls,
        row: Mapping[str, Any],
        *,
        user_id: str,
        task_id: str,
        batch_id: str,
        sequence: int,
        action_index: int,
    ) -> dict[str, Any]:
        """Normalize and verify the immutable checkpoint identity returned by Postgres."""

        normalized = dict(row)
        try:
            returned_user_id = cls._returned_uuid(normalized["user_id"], field="checkpoint user_id")
            returned_task_id = cls._returned_uuid(normalized["task_id"], field="checkpoint task_id")
            returned_batch_id = cls._returned_uuid(normalized["batch_id"], field="checkpoint batch_id")
            returned_sequence = _safe_nonnegative_int(
                normalized["sequence"], field="checkpoint sequence", maximum=1000
            )
            returned_action_index = _safe_nonnegative_int(
                normalized["action_index"], field="checkpoint action_index", maximum=99
            )
        except (KeyError, TypeError, ValueError):
            raise RepositoryError("Execution persistence returned an invalid checkpoint") from None
        if (
            returned_user_id != user_id
            or returned_task_id != task_id
            or returned_batch_id != batch_id
            or returned_sequence != sequence
            or returned_action_index != action_index
        ):
            raise RepositoryError("Execution persistence returned an invalid checkpoint")
        normalized["user_id"] = returned_user_id
        normalized["task_id"] = returned_task_id
        normalized["batch_id"] = returned_batch_id
        normalized["sequence"] = returned_sequence
        normalized["action_index"] = returned_action_index
        return normalized

    @staticmethod
    def _checkpoint_batch_invariant(
        steps: Sequence[Mapping[str, Any]],
        *,
        user_id: str | None,
        task_id: str | None,
        batch_id: str | None,
        sequence: int,
    ) -> None:
        """Require one immutable batch identity and contiguous returned action indexes."""

        action_indexes: list[int] = []
        for step in steps:
            try:
                step_sequence = _safe_nonnegative_int(
                    step["sequence"], field="checkpoint sequence", maximum=1000
                )
                action_index = _safe_nonnegative_int(
                    step["action_index"], field="checkpoint action_index", maximum=99
                )
                if user_id is not None and step["user_id"] != user_id:
                    raise ValueError("checkpoint user_id is invalid")
                if task_id is not None and step["task_id"] != task_id:
                    raise ValueError("checkpoint task_id is invalid")
                if batch_id is not None and step["batch_id"] != batch_id:
                    raise ValueError("checkpoint batch_id is invalid")
            except (KeyError, TypeError, ValueError):
                raise RepositoryError("Execution persistence returned an invalid checkpoint") from None
            if step_sequence != sequence:
                raise RepositoryError("Execution persistence returned an invalid checkpoint")
            action_indexes.append(action_index)
        if action_indexes != list(range(len(steps))):
            raise RepositoryError("Execution persistence returned an invalid checkpoint")

    @staticmethod
    def _healing_metadata(value: Any) -> dict[str, Any]:
        if value is None:
            return {}
        if not isinstance(value, Mapping):
            raise ValueError("healing_metadata must be a mapping")
        _reject_unknown_fields(value, _HEALING_METADATA_FIELDS, label="healing_metadata")
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if key == "candidate_count":
                normalized[key] = _safe_nonnegative_int(item, field=key, maximum=1000)
            elif key == "candidate_fingerprint_hash":
                normalized[key] = _safe_hash(item, field=key)
            else:
                normalized[key] = _safe_code(item, field=key, maximum=64)
        return normalized

    @staticmethod
    def _verification(value: Any) -> dict[str, Any]:
        if value is None:
            return {}
        if not isinstance(value, Mapping):
            raise ValueError("verification must be a mapping")
        _reject_unknown_fields(value, _VERIFICATION_FIELDS, label="verification")
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if key in {"content_hash", "url_hash"}:
                normalized[key] = _safe_hash(item, field=key)
            elif key == "assertion_count":
                normalized[key] = _safe_nonnegative_int(item, field=key, maximum=1000)
            elif key == "outcome":
                if item not in {"passed", "failed", "skipped", "unknown"}:
                    raise ValueError("verification outcome is invalid")
                normalized[key] = item
            else:
                normalized[key] = _safe_code(item, field=key)
        return normalized

    @staticmethod
    def _provider_metrics(value: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("provider metrics must be a mapping")
        _reject_unknown_fields(value, _PROVIDER_FIELDS, label="provider metrics")
        for required in ("provider", "operation", "status"):
            if required not in value:
                raise ValueError(f"provider metrics is missing {required}")
        provider = _safe_code(value["provider"], field="provider")
        if provider != provider.lower():
            raise ValueError("provider must be lowercase")
        model = value.get("model")
        if model is not None and (not isinstance(model, str) or not _MODEL_PATTERN.fullmatch(model)):
            raise ValueError("model is invalid")
        operation = value["operation"]
        if operation not in _PROVIDER_OPERATIONS:
            raise ValueError("provider operation is invalid")
        status = value["status"]
        if status not in _PROVIDER_STATUSES:
            raise ValueError("provider status is invalid")
        currency_code = value.get("currency_code", "USD")
        if not isinstance(currency_code, str) or not re.fullmatch(r"[A-Z]{3}", currency_code):
            raise ValueError("currency_code is invalid")
        provider_request_id = value.get("provider_request_id")
        if provider_request_id is not None:
            provider_request_id = _safe_code(
                provider_request_id, field="provider_request_id", maximum=512
            )
        return {
            "provider": provider,
            "model": model,
            "operation": operation,
            "status": status,
            "input_tokens": _safe_nonnegative_int(
                value.get("input_tokens", 0), field="input_tokens", maximum=10_000_000
            ),
            "output_tokens": _safe_nonnegative_int(
                value.get("output_tokens", 0), field="output_tokens", maximum=10_000_000
            ),
            "audio_input_seconds": _safe_nonnegative_number(
                value.get("audio_input_seconds", 0), field="audio_input_seconds", maximum=86_400
            ),
            "audio_output_seconds": _safe_nonnegative_number(
                value.get("audio_output_seconds", 0), field="audio_output_seconds", maximum=86_400
            ),
            "ocr_pages": _safe_nonnegative_int(value.get("ocr_pages", 0), field="ocr_pages", maximum=100_000),
            "latency_ms": _safe_optional_nonnegative_int(
                value.get("latency_ms"), field="latency_ms", maximum=3_600_000
            ),
            "retry_count": _safe_nonnegative_int(value.get("retry_count", 0), field="retry_count", maximum=100),
            "provider_request_id": provider_request_id,
            "estimated_cost_micros": _safe_nonnegative_int(
                value.get("estimated_cost_micros", 0), field="estimated_cost_micros", maximum=10**15
            ),
            "billed_cost_micros": _safe_nonnegative_int(
                value.get("billed_cost_micros", 0), field="billed_cost_micros", maximum=10**15
            ),
            "currency_code": currency_code,
            "error_code": _safe_optional_code(value.get("error_code"), field="error_code"),
        }


__all__ = ["ExecutionRepository"]
