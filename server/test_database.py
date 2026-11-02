"""Offline tests for the private psycopg3 pool boundary."""

from __future__ import annotations

import unittest
from contextlib import asynccontextmanager
from typing import Any

from server.database import DatabaseError, DatabaseNotOpenError, DatabasePool


class FakeConnection:
    def __init__(self) -> None:
        self.transactions = 0

    @asynccontextmanager
    async def transaction(self):
        self.transactions += 1
        yield self


class FakeAsyncPool:
    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.open_calls: list[bool] = []
        self.wait_calls: list[float] = []
        self.close_calls = 0
        self.connection_timeouts: list[float | None] = []
        self.connection_instance = FakeConnection()
        self.fail_open = False

    async def open(self, *, wait: bool = False) -> None:
        self.open_calls.append(wait)
        if self.fail_open:
            raise RuntimeError("postgresql://secret@example.test/swra")

    async def wait(self, timeout: float = 30.0) -> None:
        self.wait_calls.append(timeout)

    async def close(self) -> None:
        self.close_calls += 1

    @asynccontextmanager
    async def connection(self, *, timeout: float | None = None):
        self.connection_timeouts.append(timeout)
        yield self.connection_instance


class DatabasePoolTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.created: list[FakeAsyncPool] = []

    def factory(self, **kwargs: Any) -> FakeAsyncPool:
        pool = FakeAsyncPool(**kwargs)
        self.created.append(pool)
        return pool

    def database(self, **kwargs: Any) -> DatabasePool:
        return DatabasePool(
            "postgresql://swara:do-not-log@example.test:5432/postgres",
            pool_factory=self.factory,
            **kwargs,
        )

    async def test_constructor_is_lazy_and_safe_to_represent(self) -> None:
        database = self.database()

        self.assertEqual(self.created, [])
        self.assertFalse(database.is_open)
        self.assertNotIn("do-not-log", repr(database))
        self.assertNotIn("example.test", str(database))

    async def test_open_waits_once_with_bounded_pool_options(self) -> None:
        database = self.database(min_size=2, max_size=4, acquire_timeout=3, open_timeout=4, max_waiting=9)

        await database.open()
        await database.open()

        pool = self.created[0]
        self.assertTrue(database.is_open)
        self.assertEqual(pool.kwargs["conninfo"], "postgresql://swara:do-not-log@example.test:5432/postgres")
        self.assertEqual(pool.kwargs["min_size"], 2)
        self.assertEqual(pool.kwargs["max_size"], 4)
        self.assertEqual(pool.kwargs["timeout"], 3.0)
        self.assertEqual(pool.kwargs["max_waiting"], 9)
        self.assertFalse(pool.kwargs["open"])
        self.assertEqual(pool.open_calls, [False])
        self.assertEqual(pool.wait_calls, [4.0])

    async def test_transaction_uses_bounded_connection_and_transaction_context(self) -> None:
        database = self.database(acquire_timeout=7)
        await database.open()

        async with database.transaction() as connection:
            self.assertIs(connection, self.created[0].connection_instance)

        self.assertEqual(self.created[0].connection_timeouts, [7.0])
        self.assertEqual(connection.transactions, 1)

    async def test_transaction_requires_explicit_open(self) -> None:
        with self.assertRaises(DatabaseNotOpenError):
            async with self.database().transaction():
                pass

    async def test_lifespan_opens_then_closes(self) -> None:
        database = self.database()

        async with database.lifespan() as opened:
            self.assertIs(opened, database)
            self.assertTrue(database.is_open)

        self.assertFalse(database.is_open)
        self.assertEqual(self.created[0].close_calls, 1)

    async def test_open_failure_closes_and_does_not_leak_dsn(self) -> None:
        database = self.database()
        # Trigger the failure after the factory builds the injected fake.
        original_factory = self.factory

        def failing_factory(**kwargs: Any) -> FakeAsyncPool:
            pool = original_factory(**kwargs)
            pool.fail_open = True
            return pool

        database = DatabasePool(
            "postgresql://swara:do-not-log@example.test:5432/postgres",
            pool_factory=failing_factory,
        )
        with self.assertRaises(DatabaseError) as captured:
            await database.open()

        self.assertFalse(database.is_open)
        self.assertNotIn("do-not-log", str(captured.exception))
        self.assertNotIn("example.test", repr(captured.exception))
        self.assertEqual(self.created[0].close_calls, 1)

    async def test_close_is_idempotent_and_allows_a_fresh_lifecycle(self) -> None:
        database = self.database()
        await database.open()
        first_pool = self.created[0]

        await database.close()
        await database.close()
        await database.open()

        self.assertEqual(first_pool.close_calls, 1)
        self.assertEqual(len(self.created), 2)
        self.assertTrue(database.is_open)

    def test_rejects_unbounded_or_invalid_configuration(self) -> None:
        for kwargs in (
            {"min_size": 0},
            {"max_size": 11},
            {"min_size": 4, "max_size": 3},
            {"acquire_timeout": 0},
            {"open_timeout": 61},
            {"max_waiting": 0},
            {"transaction_pooler": "yes"},
        ):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.database(**kwargs)

    async def test_transaction_pooler_disables_prepared_statements(self) -> None:
        database = self.database(transaction_pooler=True)
        await database.open()

        self.assertEqual(self.created[0].kwargs["kwargs"], {"prepare_threshold": None})

    async def test_session_or_direct_mode_leaves_prepared_statements_enabled(self) -> None:
        database = self.database(transaction_pooler=False)
        await database.open()

        self.assertNotIn("kwargs", self.created[0].kwargs)


if __name__ == "__main__":
    unittest.main()
