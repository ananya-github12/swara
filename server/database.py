"""Private Postgres access for the persistent Swara API.

The pool is intentionally lifecycle-managed: construct it during application
setup, call :meth:`open` from FastAPI's lifespan, and call :meth:`close` on
shutdown.  Constructing this object neither imports psycopg nor opens a
network connection, which keeps configuration and unit tests side-effect free.
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any, Protocol, cast


class _AsyncPool(Protocol):
    """Small ``psycopg_pool.AsyncConnectionPool`` contract used by this module."""

    async def open(self, *, wait: bool = False) -> None: ...

    async def wait(self, timeout: float = 30.0) -> None: ...

    async def close(self) -> None: ...

    def connection(self, *, timeout: float | None = None) -> Any: ...


PoolFactory = Callable[..., _AsyncPool]


class DatabaseError(RuntimeError):
    """A safe database boundary error that never carries connection details."""


class DatabaseNotOpenError(DatabaseError):
    """Raised when a request tries to use the pool outside the app lifespan."""


class DatabasePool:
    """A bounded, lazily-imported psycopg3 async pool for server-only queries.

    ``transaction_pooler=True`` supports a Supavisor/PgBouncer transaction
    endpoint.  It disables psycopg's automatic prepared statements, which that
    mode cannot safely retain between transactions.
    """

    _MAX_POOL_SIZE = 10
    _MAX_WAITING = 100
    _MAX_TIMEOUT_SECONDS = 60.0

    def __init__(
        self,
        dsn: str,
        *,
        min_size: int = 1,
        max_size: int = 5,
        acquire_timeout: float = 10.0,
        open_timeout: float = 10.0,
        max_waiting: int = 20,
        transaction_pooler: bool = False,
        pool_factory: PoolFactory | None = None,
    ) -> None:
        self._dsn = self._validate_dsn(dsn)
        self._min_size = self._validate_pool_size(min_size, name="min_size")
        self._max_size = self._validate_pool_size(max_size, name="max_size")
        if self._min_size > self._max_size:
            raise ValueError("min_size must not exceed max_size")
        self._acquire_timeout = self._validate_timeout(acquire_timeout, name="acquire_timeout")
        self._open_timeout = self._validate_timeout(open_timeout, name="open_timeout")
        self._max_waiting = self._validate_max_waiting(max_waiting)
        if not isinstance(transaction_pooler, bool):
            raise ValueError("transaction_pooler must be a boolean")

        self._transaction_pooler = transaction_pooler
        self._pool_factory = pool_factory
        self._pool: _AsyncPool | None = None
        self._is_open = False

    def __repr__(self) -> str:
        """Expose configuration safe for logs without exposing the DSN."""

        return (
            "DatabasePool("
            f"open={self._is_open}, min_size={self._min_size}, "
            f"max_size={self._max_size}, transaction_pooler={self._transaction_pooler})"
        )

    __str__ = __repr__

    @property
    def is_open(self) -> bool:
        """Whether ``open`` completed successfully and the pool is available."""

        return self._is_open

    async def open(self) -> None:
        """Create, open, and wait for the bounded pool during app startup."""

        if self._is_open:
            return
        pool = self._pool or self._create_pool()
        self._pool = pool
        try:
            await pool.open(wait=False)
            await pool.wait(timeout=self._open_timeout)
        except Exception:
            await self._close_after_failed_open(pool)
            self._pool = None
            raise DatabaseError("Database pool could not be opened") from None
        self._is_open = True

    async def close(self) -> None:
        """Close the pool during app shutdown; this operation is idempotent."""

        pool, self._pool = self._pool, None
        self._is_open = False
        if pool is None:
            return
        try:
            await pool.close()
        except Exception:
            raise DatabaseError("Database pool could not be closed") from None

    @asynccontextmanager
    async def lifespan(self) -> AsyncIterator[DatabasePool]:
        """FastAPI lifespan helper that opens, waits for, then closes the pool."""

        await self.open()
        try:
            yield self
        finally:
            await self.close()

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[Any]:
        """Yield one connection inside a transaction with a bounded acquisition."""

        pool = self._require_open_pool()
        try:
            async with pool.connection(timeout=self._acquire_timeout) as connection:
                async with connection.transaction():
                    yield connection
        except DatabaseError:
            raise
        except Exception:
            # Do not preserve a driver exception chain: connection failures can
            # contain a DSN and application logging may render the full trace.
            raise DatabaseError("Database transaction failed") from None

    def _create_pool(self) -> _AsyncPool:
        factory = self._pool_factory or _default_pool_factory
        kwargs: dict[str, Any] = {
            "conninfo": self._dsn,
            "min_size": self._min_size,
            "max_size": self._max_size,
            "timeout": self._acquire_timeout,
            "max_waiting": self._max_waiting,
            "open": False,
        }
        if self._transaction_pooler:
            kwargs["kwargs"] = {"prepare_threshold": None}
        try:
            return factory(**kwargs)
        except Exception:
            raise DatabaseError("Database pool could not be configured") from None

    def _require_open_pool(self) -> _AsyncPool:
        if not self._is_open or self._pool is None:
            raise DatabaseNotOpenError("Database pool is not open")
        return self._pool

    @staticmethod
    async def _close_after_failed_open(pool: _AsyncPool) -> None:
        try:
            await pool.close()
        except Exception:
            # Startup already has a safe, actionable error; avoid replacing it
            # with a teardown error whose message could include driver details.
            pass

    @classmethod
    def _validate_dsn(cls, dsn: str) -> str:
        if not isinstance(dsn, str) or not dsn.strip():
            raise ValueError("dsn must be a non-empty string")
        return dsn.strip()

    @classmethod
    def _validate_pool_size(cls, value: int, *, name: str) -> int:
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= cls._MAX_POOL_SIZE:
            raise ValueError(f"{name} must be an integer between 1 and {cls._MAX_POOL_SIZE}")
        return value

    @classmethod
    def _validate_timeout(cls, value: float, *, name: str) -> float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{name} must be a number")
        value = float(value)
        if not 0 < value <= cls._MAX_TIMEOUT_SECONDS:
            raise ValueError(f"{name} must be greater than 0 and at most {cls._MAX_TIMEOUT_SECONDS}")
        return value

    @classmethod
    def _validate_max_waiting(cls, value: int) -> int:
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= cls._MAX_WAITING:
            raise ValueError(f"max_waiting must be an integer between 1 and {cls._MAX_WAITING}")
        return value


def _default_pool_factory(**kwargs: Any) -> _AsyncPool:
    """Import psycopg-pool only when the application is actually started."""

    try:
        from psycopg_pool import AsyncConnectionPool
    except ImportError:  # pragma: no cover - depends on deployment extras
        raise DatabaseError("psycopg-pool is required for database access") from None
    return cast(_AsyncPool, AsyncConnectionPool(**kwargs))
