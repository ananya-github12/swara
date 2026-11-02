"""Request-scoped persistence for Swara identity data.

The database RLS policies are the primary authorization boundary.  This
repository deliberately repeats the ownership predicate on every query and
sets it on every insert, so a mistaken client configuration cannot turn an
identity operation into a cross-user operation.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timezone
from typing import Any

from server.request_context import RequestContext
from server.repositories.common import NotFoundError, RepositoryError, required_row, rows_from
from server.supabase_clients import SupabaseClient


class IdentityRepository:
    """Framework-neutral identity repository for one authenticated request."""

    _PROFILE_FIELDS = frozenset(
        {"display_name", "locale", "timezone", "onboarding_state", "avatar_path"}
    )
    _SETTINGS_FIELDS = frozenset(
        {
            "preferred_language",
            "voice_config",
            "privacy_mode",
            "history_retention_days",
            "save_transcripts",
            "cloud_workflow_sync",
            "personalization_enabled",
        }
    )

    def __init__(self, client: SupabaseClient, context: RequestContext) -> None:
        """Use only the caller's already-created, request-scoped client."""

        self._client = client
        self._context = context

    def get_profile(self) -> dict[str, Any]:
        """Return the visible, non-deleted profile for this request's user."""

        query = (
            self._table("profiles")
            .select("*")
            .eq("user_id", self._context.user_id)
            .is_("deleted_at", "null")
        )
        return required_row(self._execute(query))

    def update_profile(self, changes: Mapping[str, Any]) -> dict[str, Any]:
        """Update only explicitly mutable profile fields for this user."""

        payload = self._allowed_patch(changes, self._PROFILE_FIELDS, "profile")
        query = (
            self._table("profiles")
            .update(payload)
            .eq("user_id", self._context.user_id)
            .is_("deleted_at", "null")
        )
        return required_row(self._execute(query))

    def get_settings(self) -> dict[str, Any]:
        """Return the visible settings row for this request's user."""

        query = self._table("user_settings").select("*").eq("user_id", self._context.user_id)
        return required_row(self._execute(query))

    def update_settings(self, changes: Mapping[str, Any]) -> dict[str, Any]:
        """Update only explicitly mutable settings fields for this user."""

        payload = self._allowed_patch(changes, self._SETTINGS_FIELDS, "settings")
        query = (
            self._table("user_settings")
            .update(payload)
            .eq("user_id", self._context.user_id)
        )
        return required_row(self._execute(query))

    def list_devices(self, *, include_revoked: bool = False) -> list[dict[str, Any]]:
        """List this user's devices, hiding revoked records by default."""

        if not isinstance(include_revoked, bool):
            raise ValueError("include_revoked must be a boolean")
        query = (
            self._table("devices")
            .select("*")
            .eq("user_id", self._context.user_id)
        )
        if not include_revoked:
            query = query.is_("revoked_at", "null")
        return rows_from(self._execute(query.order("last_seen_at", desc=True)))

    def list_current_domain_policies(self, *, now: datetime | None = None) -> list[dict[str, Any]]:
        """List policies that are unexpired at ``now`` (or the current UTC time)."""

        if now is None:
            now = datetime.now(timezone.utc)
        if not isinstance(now, datetime):
            raise ValueError("now must be a datetime")
        if now.tzinfo is None or now.utcoffset() is None:
            raise ValueError("now must be timezone-aware")
        timestamp = now.astimezone(timezone.utc).isoformat()
        query = (
            self._table("domain_policies")
            .select("*")
            .eq("user_id", self._context.user_id)
            .or_(f"expires_at.is.null,expires_at.gt.{timestamp}")
            .order("domain_pattern")
        )
        return rows_from(self._execute(query))

    def append_consent(
        self,
        *,
        consent_type: str,
        policy_version: str,
        granted: bool,
        metadata: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Append a consent event; consent records are intentionally immutable."""

        if not isinstance(consent_type, str) or not consent_type.strip():
            raise ValueError("consent_type must be a non-empty string")
        if not isinstance(policy_version, str) or not policy_version.strip():
            raise ValueError("policy_version must be a non-empty string")
        if not isinstance(granted, bool):
            raise ValueError("granted must be a boolean")
        if metadata is not None and not isinstance(metadata, Mapping):
            raise ValueError("metadata must be a mapping")

        payload = {
            "user_id": self._context.user_id,
            "consent_type": consent_type,
            "policy_version": policy_version,
            "granted": granted,
            "metadata": dict(metadata or {}),
        }
        return required_row(self._execute(self._table("consent_records").insert(payload)))

    def list_consents(self, *, consent_type: str | None = None) -> list[dict[str, Any]]:
        """List this user's append-only consent history, newest first."""

        if consent_type is not None and (not isinstance(consent_type, str) or not consent_type.strip()):
            raise ValueError("consent_type must be a non-empty string when provided")
        query = self._table("consent_records").select("*").eq("user_id", self._context.user_id)
        if consent_type is not None:
            query = query.eq("consent_type", consent_type)
        return rows_from(self._execute(query.order("recorded_at", desc=True)))

    def _table(self, name: str) -> Any:
        try:
            return self._client.table(name)
        except Exception:
            raise RepositoryError("Persistence operation failed") from None

    @staticmethod
    def _allowed_patch(
        changes: Mapping[str, Any], allowed_fields: frozenset[str], label: str
    ) -> dict[str, Any]:
        if not isinstance(changes, Mapping) or not changes:
            raise ValueError(f"{label} changes must be a non-empty mapping")
        unknown = set(changes) - allowed_fields
        if unknown:
            raise ValueError(f"{label} changes contain forbidden fields")
        return dict(changes)

    @staticmethod
    def _execute(query: Any) -> Any:
        try:
            return query.execute()
        except Exception:
            raise RepositoryError("Persistence operation failed") from None
