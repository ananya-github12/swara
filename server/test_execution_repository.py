"""Offline contract tests for private, request-scoped execution persistence."""

from __future__ import annotations

import unittest
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

from server.request_context import RequestContext
from server.repositories.common import NotFoundError, RepositoryError
from server.repositories.execution import ExecutionRepository


USER_ID = "11111111-1111-1111-1111-111111111111"
DEVICE_ID = "22222222-2222-2222-2222-222222222222"
SESSION_ID = "33333333-3333-3333-3333-333333333333"
TASK_ID = "44444444-4444-4444-4444-444444444444"
STEP_ID = "55555555-5555-5555-5555-555555555555"
BATCH_ID = "66666666-6666-4aaa-8aaa-666666666666"
BATCH_ID_2 = "77777777-7777-4bbb-8bbb-777777777777"
HASH = "a" * 64
CORRELATION_ID = "99999999-9999-4999-8999-999999999999"
OTHER_USER_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


@dataclass
class _Cursor:
    row: dict[str, Any] | None

    async def fetchone(self) -> dict[str, Any] | None:
        return self.row


class _FakeConnection:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...]]] = []
        self.fail = False
        self.task_user_id = USER_ID
        self.task_step_insert_count = 0
        self.fail_on_task_step_insert: int | None = None

    async def execute(self, query: str, params: tuple[Any, ...]) -> _Cursor:
        self.calls.append((query, params))
        if self.fail:
            raise RuntimeError("postgresql://secret@example.test/swara")
        statement = " ".join(query.lower().split())
        if "select task.id, task.user_id" in statement:
            if params[1] != self.task_user_id:
                return _Cursor(None)
            return _Cursor({"id": TASK_ID, "user_id": USER_ID, "status": "running", "completed_steps": 0, "max_steps": 25})
        if "private.task_steps" in statement and "returning" in statement:
            self.task_step_insert_count += 1
            if self.fail_on_task_step_insert == self.task_step_insert_count:
                raise RuntimeError("postgresql://secret@example.test/swara")
            return _Cursor({"id": STEP_ID, "user_id": USER_ID, "task_id": TASK_ID, "sequence": params[1], "action_index": params[3], "status": params[6], "batch_id": params[2], "created_at": "now"})
        if "private.task_events" in statement and "returning" in statement:
            return _Cursor({"id": "77777777-7777-7777-7777-777777777777", "user_id": USER_ID, "task_id": TASK_ID, "step_id": None, "sequence": params[1], "event_type": params[2], "occurred_at": "now"})
        if "private.provider_calls" in statement:
            return _Cursor({"id": "88888888-8888-8888-8888-888888888888", "user_id": USER_ID, "task_id": TASK_ID, "step_id": None, "provider": params[1], "operation": params[3], "status": params[4], "started_at": "now"})
        if "private.agent_tasks" in statement and statement.startswith("insert"):
            return _Cursor({"id": TASK_ID, "user_id": USER_ID, "session_id": SESSION_ID, "status": "queued", "completed_steps": 0, "correlation_id": CORRELATION_ID, "created_at": "now"})
        if "private.agent_tasks" in statement and statement.startswith("update"):
            return _Cursor({"id": TASK_ID, "user_id": USER_ID, "session_id": SESSION_ID, "status": params[1], "completed_steps": params[0], "correlation_id": CORRELATION_ID, "created_at": "now"})
        if "private.browser_sessions" in statement:
            return _Cursor({"id": SESSION_ID, "user_id": USER_ID, "device_id": DEVICE_ID, "status": "active", "interaction_mode": "browser", "started_at": "now", "correlation_id": CORRELATION_ID})
        raise AssertionError(f"Unexpected query: {query}")


class _FakeDatabase:
    def __init__(self) -> None:
        self.connection = _FakeConnection()
        self.transaction_count = 0
        self.commit_count = 0
        self.rollback_count = 0
        self.timeline: list[str] = []

    @asynccontextmanager
    async def transaction(self):
        self.transaction_count += 1
        self.timeline.append("begin")
        try:
            yield self.connection
        except Exception:
            self.rollback_count += 1
            raise
        else:
            self.commit_count += 1
        finally:
            self.timeline.append("end")


class ExecutionRepositoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.database = _FakeDatabase()
        context = RequestContext(
            user_id=USER_ID,
            auth_session_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            device_id=DEVICE_ID,
            correlation_id=CORRELATION_ID,
        )
        self.repository = ExecutionRepository(self.database, context)

    def assert_parameterized_and_owned(self, calls: list[tuple[str, tuple[Any, ...]]]) -> None:
        self.assertTrue(calls)
        for query, params in calls:
            with self.subTest(query=query):
                self.assertIn("%s", query)
                self.assertEqual(query.count("%s"), len(params))
                self.assertIn("user_id", query.lower())
                self.assertIn(USER_ID, params)
                self.assertNotIn(USER_ID, query)
                self.assertNotIn(SESSION_ID, query)
                self.assertNotIn(TASK_ID, query)

    async def test_session_open_and_close_are_parameterized_and_device_owned(self) -> None:
        await self.repository.open_browser_session(extension_version="1.2.3", policy_version="2026.08")
        await self.repository.close_browser_session(SESSION_ID, status="ended")

        self.assert_parameterized_and_owned(self.database.connection.calls)
        open_query = self.database.connection.calls[0][0].lower()
        close_query = self.database.connection.calls[1][0].lower()
        self.assertIn("from public.devices as device", open_query)
        self.assertIn("device.revoked_at is null", open_query)
        self.assertIn("exists (", close_query)
        self.assertIn("from public.devices as device", close_query)

    async def test_task_event_and_provider_operations_scope_every_query_to_user(self) -> None:
        await self.repository.create_task(
            SESSION_ID,
            redacted_summary="Continue the approved flow",
            diagnostic_hash=HASH,
            policy_version="2026.08",
            extension_version="1.2.3",
            source_origin="https://example.test",
        )
        await self.repository.append_event(
            TASK_ID,
            sequence=1,
            event_type="planned",
            event_metadata={"reason_code": "approved"},
        )
        await self.repository.record_provider_call(
            TASK_ID,
            {"provider": "sarvam", "operation": "stt", "status": "succeeded", "input_tokens": 12},
        )

        self.assert_parameterized_and_owned(self.database.connection.calls)
        task_query = self.database.connection.calls[0][0].lower()
        event_query = self.database.connection.calls[1][0].lower()
        provider_query = self.database.connection.calls[2][0].lower()
        self.assertIn("from private.browser_sessions as session", task_query)
        self.assertIn("from private.agent_tasks as task", event_query)
        self.assertIn("join private.browser_sessions as session", provider_query)
        self.assertNotIn("provider_payload", provider_query)
        self.assertNotIn("api_key", provider_query)

    async def test_checkpoint_groups_a_multi_action_batch_event_and_progress_in_one_transaction(self) -> None:
        result = await self.repository.persist_observation_checkpoint(
            TASK_ID,
            batch_id=BATCH_ID,
            sequence=1,
            steps=[
                {"action_type": "click", "status": "succeeded", "latency_ms": 40},
                {"action_type": "read", "status": "succeeded", "verification": {"outcome": "passed"}},
            ],
            event_sequence=3,
            event_type="dispatched",
            event_metadata={"reason_code": "observation"},
            task_status="running",
        )

        self.assertEqual(self.database.transaction_count, 1)
        self.assertEqual(self.database.timeline, ["begin", "end"])
        self.assertEqual(len(self.database.connection.calls), 5)
        self.assertIn("for update", self.database.connection.calls[0][0].lower())
        self.assertIn("private.task_steps", self.database.connection.calls[1][0])
        self.assertIn("private.task_steps", self.database.connection.calls[2][0])
        self.assertIn("private.task_events", self.database.connection.calls[3][0])
        self.assertIn("update private.agent_tasks", self.database.connection.calls[4][0].lower())
        self.assertEqual([step["sequence"] for step in result["steps"]], [1, 1])
        self.assertEqual([step["batch_id"] for step in result["steps"]], [BATCH_ID, BATCH_ID])
        self.assertEqual([step["action_index"] for step in result["steps"]], [0, 1])
        self.assertEqual(result["task"]["completed_steps"], 1)
        step_calls = self.database.connection.calls[1:3]
        self.assertTrue(all("action_index" in query.lower() for query, _ in step_calls))
        self.assertEqual(
            [(params[1], params[2], params[3]) for _, params in step_calls],
            [(1, BATCH_ID, 0), (1, BATCH_ID, 1)],
        )
        self.assert_parameterized_and_owned(self.database.connection.calls)

    async def test_next_batch_uses_the_next_sequence_and_restarts_action_indexes(self) -> None:
        await self.repository.persist_observation_checkpoint(
            TASK_ID,
            batch_id=BATCH_ID,
            sequence=1,
            steps=[{"action_type": "read", "status": "succeeded"}],
            event_sequence=1,
        )
        result = await self.repository.persist_observation_checkpoint(
            TASK_ID,
            batch_id=BATCH_ID_2,
            sequence=2,
            steps=[{"action_type": "click", "status": "succeeded"}],
            event_sequence=2,
        )

        self.assertEqual(result["steps"][0]["sequence"], 2)
        self.assertEqual(result["steps"][0]["batch_id"], BATCH_ID_2)
        self.assertEqual(result["steps"][0]["action_index"], 0)
        self.assertEqual(result["task"]["completed_steps"], 2)
        task_updates = [
            params
            for query, params in self.database.connection.calls
            if "update private.agent_tasks" in query.lower()
        ]
        self.assertEqual([params[0] for params in task_updates], [1, 2])

    async def test_checkpoint_validation_and_write_failure_do_not_commit_a_partial_batch(self) -> None:
        with self.assertRaises(ValueError):
            await self.repository.persist_observation_checkpoint(
                TASK_ID,
                batch_id=BATCH_ID.upper(),
                sequence=1,
                steps=[{"action_type": "read", "status": "succeeded"}],
                event_sequence=1,
            )
        with self.assertRaises(ValueError):
            await self.repository.persist_observation_checkpoint(
                TASK_ID,
                batch_id=BATCH_ID,
                sequence=1,
                steps=[{"action_index": 0, "action_type": "read", "status": "succeeded"}],
                event_sequence=1,
            )
        self.assertEqual(self.database.transaction_count, 0)
        self.assertEqual(self.database.connection.calls, [])

        self.database.connection.fail_on_task_step_insert = 2
        with self.assertRaisesRegex(RepositoryError, "^Execution persistence failed$") as captured:
            await self.repository.persist_observation_checkpoint(
                TASK_ID,
                batch_id=BATCH_ID,
                sequence=1,
                steps=[
                    {"action_type": "read", "status": "succeeded"},
                    {"action_type": "click", "status": "succeeded"},
                ],
                event_sequence=1,
            )
        self.assertNotIn("secret", str(captured.exception))
        self.assertEqual(self.database.transaction_count, 1)
        self.assertEqual(self.database.commit_count, 0)
        self.assertEqual(self.database.rollback_count, 1)
        self.assertFalse(
            any("private.task_events" in query.lower() for query, _ in self.database.connection.calls)
        )
        self.assertFalse(
            any("update private.agent_tasks" in query.lower() for query, _ in self.database.connection.calls)
        )

    async def test_checkpoint_cross_owner_task_is_denied_before_insert(self) -> None:
        foreign_context = RequestContext(
            user_id=OTHER_USER_ID,
            auth_session_id="bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            device_id=DEVICE_ID,
            correlation_id=CORRELATION_ID,
        )
        foreign_repository = ExecutionRepository(self.database, foreign_context)

        with self.assertRaises(NotFoundError):
            await foreign_repository.persist_observation_checkpoint(
                TASK_ID,
                batch_id=BATCH_ID,
                sequence=1,
                steps=[{"action_type": "read", "status": "succeeded"}],
                event_sequence=1,
            )

        self.assertEqual(len(self.database.connection.calls), 1)
        query, params = self.database.connection.calls[0]
        self.assertIn("task.user_id = %s", query.lower())
        self.assertIn(OTHER_USER_ID, params)
        self.assertFalse(
            any("insert into private.task_steps" in call[0].lower() for call in self.database.connection.calls)
        )

    async def test_forbidden_fields_are_rejected_before_a_database_call(self) -> None:
        with self.assertRaises(ValueError):
            await self.repository.persist_observation_checkpoint(
                TASK_ID,
                batch_id=BATCH_ID,
                sequence=1,
                steps=[{"action_type": "fill", "status": "succeeded", "filled_value": "secret"}],
                event_sequence=1,
            )
        with self.assertRaises(ValueError):
            await self.repository.append_event(
                TASK_ID,
                sequence=1,
                event_type="planned",
                event_metadata={"dom": "<form>"},
            )
        with self.assertRaises(ValueError):
            await self.repository.record_provider_call(
                TASK_ID,
                {"provider": "sarvam", "operation": "stt", "status": "failed", "provider_payload": {"secret": "x"}},
            )
        with self.assertRaises(TypeError):
            await self.repository.create_task(
                SESSION_ID,
                redacted_summary="safe",
                diagnostic_hash=HASH,
                policy_version="2026.08",
                extension_version="1.2.3",
                raw_instruction="do not persist this",  # type: ignore[call-arg]
            )
        self.assertEqual(self.database.connection.calls, [])

    async def test_invisible_or_database_failures_are_opaque(self) -> None:
        self.database.connection.fail = True
        with self.assertRaisesRegex(RepositoryError, "^Execution persistence failed$") as captured:
            await self.repository.open_browser_session(extension_version="1.2.3", policy_version="2026.08")
        self.assertNotIn("secret", str(captured.exception))

        self.database.connection.fail = False
        original_execute = self.database.connection.execute

        async def no_row(query: str, params: tuple[Any, ...]) -> _Cursor:
            return _Cursor(None)

        self.database.connection.execute = no_row  # type: ignore[method-assign]
        with self.assertRaises(NotFoundError):
            await self.repository.close_browser_session(SESSION_ID)
        self.database.connection.execute = original_execute  # type: ignore[method-assign]


if __name__ == "__main__":
    unittest.main()
