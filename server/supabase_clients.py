"""Narrow, safe factories for server-side Supabase clients.

This module deliberately creates a fresh client for every call.  In particular,
the client carrying a user's bearer token is request-scoped: it is never cached,
logged, or persisted by supabase-py.
"""

from __future__ import annotations

import base64
import json
from collections.abc import Callable
from typing import Any, Protocol, TypeAlias, cast
from urllib.parse import urlparse


class SupabaseClient(Protocol):
    """The intentionally small client contract consumed by Swara repositories."""

    def table(self, name: str) -> Any: ...

    auth: Any
    storage: Any
    functions: Any


class ClientFactory(Protocol):
    """Injection point for tests; compatible with ``supabase.create_client``."""

    def __call__(self, url: str, key: str, *, options: Any) -> SupabaseClient: ...


ClientOptionsFactory: TypeAlias = Callable[..., Any]


def _required_text(value: str, *, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value.strip()


def _validate_url(url: str) -> str:
    url = _required_text(url, name="url")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("url must be an absolute http(s) URL")
    return url.rstrip("/")


def _jwt_role(key: str) -> str | None:
    """Read an untrusted JWT payload only to reject obvious public keys."""

    parts = key.split(".")
    if len(parts) != 3:
        return None
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    role = claims.get("role")
    return role if isinstance(role, str) else None


def _validate_publishable_key(key: str) -> str:
    key = _required_text(key, name="publishable_key")
    lowered = key.lower()
    if lowered.startswith(("sb_secret_", "service_role", "secret_")) or _jwt_role(key) == "service_role":
        raise ValueError("publishable_key must not be a service or secret key")
    return key


def _validate_secret_key(key: str) -> str:
    key = _required_text(key, name="secret_key")
    lowered = key.lower()
    role = _jwt_role(key)
    public_prefixes = ("sb_publishable_", "sbp_", "anon", "public_")
    if lowered.startswith(public_prefixes) or role in {"anon", "authenticated"}:
        raise ValueError("secret_key must be a Supabase secret or service_role key")
    if not (lowered.startswith("sb_secret_") or role == "service_role"):
        raise ValueError("secret_key must be a Supabase secret or service_role key")
    return key


def _supabase_dependencies() -> tuple[ClientFactory, ClientOptionsFactory]:
    """Import lazily so configuration/tests do not need supabase-py at import time."""

    try:
        from supabase import create_client
        from supabase.lib.client_options import ClientOptions
    except ImportError as exc:  # pragma: no cover - depends on deployment extras
        raise RuntimeError("supabase-py is required to create Supabase clients") from exc
    return cast(ClientFactory, create_client), cast(ClientOptionsFactory, ClientOptions)


def user_client(
    url: str,
    publishable_key: str,
    access_token: str,
    *,
    factory: ClientFactory | None = None,
    options_factory: ClientOptionsFactory | None = None,
) -> SupabaseClient:
    """Create an RLS-scoped, non-persistent client for one verified request token."""

    url = _validate_url(url)
    publishable_key = _validate_publishable_key(publishable_key)
    access_token = _required_text(access_token, name="access_token")
    if _jwt_role(access_token) == "service_role":
        raise ValueError("access_token must be an end-user access token")
    if factory is None or options_factory is None:
        default_factory, default_options_factory = _supabase_dependencies()
        factory = factory or default_factory
        options_factory = options_factory or default_options_factory

    options = options_factory(
        headers={"Authorization": f"Bearer {access_token}"},
        persist_session=False,
        auto_refresh_token=False,
    )
    return factory(url, publishable_key, options=options)


def service_client(
    url: str,
    secret_key: str,
    *,
    factory: ClientFactory | None = None,
    options_factory: ClientOptionsFactory | None = None,
) -> SupabaseClient:
    """Create a backend-only client; callers must keep ``secret_key`` server-side."""

    url = _validate_url(url)
    secret_key = _validate_secret_key(secret_key)
    if factory is None or options_factory is None:
        default_factory, default_options_factory = _supabase_dependencies()
        factory = factory or default_factory
        options_factory = options_factory or default_options_factory

    # Service clients do not need an Auth session and must not write one to disk.
    options = options_factory(persist_session=False, auto_refresh_token=False)
    return factory(url, secret_key, options=options)
