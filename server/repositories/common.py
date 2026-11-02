"""Small framework-neutral helpers shared by Swara repositories."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


class RepositoryError(RuntimeError):
    """A persistence operation failed without exposing provider details."""


class NotFoundError(RepositoryError):
    """The requested user-owned resource does not exist or is not visible."""


class ConflictError(RepositoryError):
    """The requested mutation conflicts with current persisted state."""


def rows_from(response: Any) -> list[dict[str, Any]]:
    """Return mapping rows from a PostgREST response with a strict shape."""

    data = getattr(response, "data", None)
    if data is None:
        return []
    if not isinstance(data, list) or any(not isinstance(row, Mapping) for row in data):
        raise RepositoryError("Persistence provider returned an invalid response")
    return [dict(row) for row in data]


def required_row(response: Any) -> dict[str, Any]:
    """Return exactly one visible row, mapping absence to an opaque 404."""

    rows = rows_from(response)
    if not rows:
        raise NotFoundError("Resource not found")
    if len(rows) != 1:
        raise RepositoryError("Persistence provider returned multiple rows")
    return rows[0]


def optional_row(response: Any) -> dict[str, Any] | None:
    """Return zero or one row and reject ambiguous provider responses."""

    rows = rows_from(response)
    if not rows:
        return None
    if len(rows) != 1:
        raise RepositoryError("Persistence provider returned multiple rows")
    return rows[0]
