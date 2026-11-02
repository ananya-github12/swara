"""Request-scoped repository for Swara's personal Vault.

The repository deliberately accepts an already-authenticated, RLS-scoped
client.  It has no knowledge of URLs, keys, bearer tokens, FastAPI, or
Storage.  The explicit ``user_id`` predicates and insert fields are a second
ownership check alongside Supabase RLS.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Final, Protocol

from server.repositories.common import NotFoundError, RepositoryError, required_row, rows_from
from server.request_context import RequestContext


class UserClient(Protocol):
    """Small contract needed from an injected Supabase client."""

    def table(self, name: str) -> Any: ...


DEFAULT_LIMIT: Final = 50
MAX_LIMIT: Final = 200

_DOCUMENT_TABLE: Final = "vault_documents"
_CONTEXT_TABLE: Final = "swara_context_items"

_FIRST_ITEM_FIELDS: Final = frozenset(
    {
        "type",
        "key",
        "value",
        "category",
        "sensitivity",
        "source_document_id",
        "source_type",
        "scope",
    }
)
_ITEM_TYPES: Final = frozenset({"fact", "preference", "instruction", "document"})
_SCOPES: Final = frozenset({"persistent", "session", "task"})
_SENSITIVITIES: Final = frozenset({"standard", "sensitive", "restricted"})


def _bounded_limit(limit: int) -> int:
    if isinstance(limit, bool) or not isinstance(limit, int):
        raise ValueError("limit must be an integer")
    if not 1 <= limit <= MAX_LIMIT:
        raise ValueError(f"limit must be between 1 and {MAX_LIMIT}")
    return limit


def _safe_text(value: Any, *, field: str, maximum: int, required: bool = True) -> str | None:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    if required and not value:
        raise ValueError(f"{field} must not be empty")
    if value != value.strip() or any(not character.isprintable() for character in value):
        raise ValueError(f"{field} contains unsafe characters")
    if len(value) > maximum:
        raise ValueError(f"{field} is too long")
    return value


def _safe_content(value: Any, *, field: str, maximum: int) -> str:
    """Validate user text without rejecting ordinary spaces or paragraphs."""

    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")
    if any(ord(character) < 32 and character not in "\n\r\t" for character in value):
        raise ValueError(f"{field} contains unsafe characters")
    if len(value) > maximum:
        raise ValueError(f"{field} is too long")
    return value


def _safe_optional_text(value: Any, *, field: str, maximum: int) -> str | None:
    if value is None:
        return None
    return _safe_text(value, field=field, maximum=maximum)


class VaultRepository:
    """User-owned Vault persistence over an injected request-scoped client."""

    def __init__(self, client: UserClient, context: RequestContext) -> None:
        self._client = client
        self._context = context

    @property
    def user_id(self) -> str:
        """Expose only the verified context identity, never a caller argument."""

        return self._context.user_id

    def _table(self, name: str) -> Any:
        # Keeping table names private and explicit makes it impossible for this
        # repository to accidentally drift into private chunks or legacy
        # Storage objects.
        try:
            return self._client.table(name)
        except Exception:
            raise RepositoryError("Vault persistence operation failed") from None

    @staticmethod
    def _execute(query: Any, *, operation: str) -> Any:
        try:
            response = query.execute()
        except Exception:
            raise RepositoryError(f"Vault {operation} failed") from None
        # Some fakes and PostgREST adapters expose an error on the response
        # instead of raising it.  Do not stringify it: provider details may
        # contain URLs, SQL, or credentials.
        if getattr(response, "error", None):
            raise RepositoryError(f"Vault {operation} failed")
        return response

    @staticmethod
    def _inserted_row(response: Any) -> dict[str, Any]:
        rows = rows_from(response)
        if not rows:
            raise RepositoryError("Vault insert returned no row")
        if len(rows) != 1:
            raise RepositoryError("Vault insert returned multiple rows")
        return rows[0]

    def _visible_documents(self, query: Any, *, include_deleted: bool) -> Any:
        query = query.eq("user_id", self._context.user_id)
        if not include_deleted:
            query = query.neq("status", "deleted").is_("deleted_at", "null")
        return query

    def _visible_context(self, query: Any, *, include_history: bool) -> Any:
        query = query.eq("user_id", self._context.user_id)
        if not include_history:
            query = query.eq("status", "active")
        return query

    def list_documents(
        self,
        limit: int = DEFAULT_LIMIT,
        *,
        include_deleted: bool = False,
    ) -> list[dict[str, Any]]:
        """List this user's Vault document metadata, newest first."""

        limit = _bounded_limit(limit)
        query = self._visible_documents(
            self._table(_DOCUMENT_TABLE).select("*"),
            include_deleted=include_deleted,
        ).order("created_at", desc=True).limit(limit)
        return rows_from(self._execute(query, operation="document listing"))

    def get_document(
        self,
        document_id: str,
        *,
        include_deleted: bool = False,
    ) -> dict[str, Any]:
        """Return one visible document or an opaque not-found error."""

        document_id = _safe_text(document_id, field="document_id", maximum=255) or ""
        query = self._visible_documents(
            self._table(_DOCUMENT_TABLE).select("*"),
            include_deleted=include_deleted,
        ).eq("id", document_id).limit(1)
        return required_row(self._execute(query, operation="document lookup"))

    def list_context_items(
        self,
        limit: int = DEFAULT_LIMIT,
        *,
        include_history: bool = False,
        scope: str | None = None,
    ) -> list[dict[str, Any]]:
        """List active context items, optionally including immutable history."""

        limit = _bounded_limit(limit)
        if scope is not None and scope not in _SCOPES:
            raise ValueError("scope is invalid")
        query = self._visible_context(
            self._table(_CONTEXT_TABLE).select("*"),
            include_history=include_history,
        )
        if scope is not None:
            query = query.eq("scope", scope)
        query = query.order("updated_at", desc=True).limit(limit)
        return rows_from(self._execute(query, operation="context listing"))

    def search_context_items(
        self,
        search: str,
        limit: int = DEFAULT_LIMIT,
        *,
        include_history: bool = False,
    ) -> list[dict[str, Any]]:
        """Search this user's context values with a bounded result set."""

        search = _safe_content(search, field="search", maximum=512)
        limit = _bounded_limit(limit)
        # Escape PostgREST LIKE wildcards so search input stays a literal
        # substring.  The backslash is the PostgreSQL LIKE escape character.
        pattern = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        # Keep the search term as a bound PostgREST value.  Building an
        # ``or_`` filter string from caller text would create a second parser
        # boundary and could turn punctuation into filter syntax.
        query = self._visible_context(
            self._table(_CONTEXT_TABLE).select("*"),
            include_history=include_history,
        ).ilike("value", f"%{pattern}%")
        query = query.order("updated_at", desc=True).limit(limit)
        return rows_from(self._execute(query, operation="context search"))

    def insert_first_context_item(self, item: Mapping[str, Any]) -> dict[str, Any]:
        """Insert a new version-one item using a strict, safe field allowlist.

        Ownership, lifecycle, and chain fields are controlled by this method
        and the database.  A correction must use :meth:`append_correction`.
        """

        if not isinstance(item, Mapping):
            raise ValueError("context item must be a mapping")
        keys = set(item)
        forbidden = keys - _FIRST_ITEM_FIELDS
        if forbidden:
            raise ValueError("context item contains forbidden fields")
        for required in ("type", "key", "value"):
            if required not in item:
                raise ValueError(f"context item is missing {required}")

        item_type = _safe_text(item["type"], field="type", maximum=32)
        if item_type not in _ITEM_TYPES:
            raise ValueError("type is invalid for a first context item")
        key = _safe_text(item["key"], field="key", maximum=512)
        value = _safe_content(item["value"], field="value", maximum=65535)
        category = _safe_optional_text(item.get("category"), field="category", maximum=128)
        sensitivity = item.get("sensitivity", "standard")
        if sensitivity not in _SENSITIVITIES:
            raise ValueError("sensitivity is invalid")
        source_document_id = _safe_optional_text(
            item.get("source_document_id"), field="source_document_id", maximum=255
        )
        source_type = _safe_optional_text(item.get("source_type"), field="source_type", maximum=128)
        scope = item.get("scope", "persistent")
        if scope not in _SCOPES:
            raise ValueError("scope is invalid")

        payload: dict[str, Any] = {
            "user_id": self._context.user_id,
            "type": item_type,
            "key": key,
            "value": value,
            "sensitivity": sensitivity,
            "scope": scope,
            "version": 1,
            "status": "active",
        }
        if category is not None:
            payload["category"] = category
        if source_document_id is not None:
            payload["source_document_id"] = source_document_id
        if source_type is not None:
            payload["source_type"] = source_type

        response = self._execute(
            self._table(_CONTEXT_TABLE).insert(payload),
            operation="context insert",
        )
        return self._inserted_row(response)

    def append_correction(self, prior_id: str, value: str) -> dict[str, Any]:
        """Append a correction row; never update or overwrite the prior row."""

        prior_id = _safe_text(prior_id, field="prior_id", maximum=255) or ""
        value = _safe_content(value, field="value", maximum=65535)
        prior_query = (
            self._table(_CONTEXT_TABLE)
            .select("*")
            .eq("user_id", self._context.user_id)
            .eq("id", prior_id)
            .eq("status", "active")
            .limit(1)
        )
        prior = required_row(self._execute(prior_query, operation="correction lookup"))

        try:
            prior_row_id = _safe_text(prior["id"], field="prior row id", maximum=255)
            key = _safe_text(prior["key"], field="prior key", maximum=512)
            scope = prior["scope"]
            version = prior["version"]
            if scope not in _SCOPES or isinstance(version, bool) or not isinstance(version, int) or version < 1:
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise RepositoryError("Vault correction source is invalid") from None

        payload: dict[str, Any] = {
            "user_id": self._context.user_id,
            "type": "correction",
            "key": key,
            "value": value,
            "category": prior.get("category", "general"),
            "sensitivity": prior.get("sensitivity", "standard"),
            "scope": scope,
            "source_type": "correction",
            "version": version + 1,
            "supersedes_id": prior_row_id,
            "status": "active",
        }
        if prior.get("source_document_id") is not None:
            payload["source_document_id"] = prior["source_document_id"]

        response = self._execute(
            self._table(_CONTEXT_TABLE).insert(payload),
            operation="correction insert",
        )
        return self._inserted_row(response)

    # Explicit aliases keep the public vocabulary convenient without adding
    # alternate persistence paths or changing the security boundary.
    list_vault_documents = list_documents
    get_vault_document = get_document
    list_context = list_context_items
    search_context = search_context_items
    insert_context_item = insert_first_context_item
    append_context_correction = append_correction


__all__ = ["DEFAULT_LIMIT", "MAX_LIMIT", "VaultRepository"]
