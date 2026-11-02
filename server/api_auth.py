"""FastAPI adapters for Swara's verified Supabase request context.

The JWT verifier owns signature and registered-claim validation.  This module
only adapts HTTP/WebSocket headers, stores the non-secret context on the
request, and creates a short-lived RLS client at the repository boundary.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import HTTPException, Request, WebSocket

from auth import AuthError, AuthServiceUnavailableError, JWTVerifier, parse_bearer_authorization, parse_websocket_subprotocol
from config import settings
from repositories.vault import VaultRepository
from request_context import RequestContext
from supabase_clients import user_client


_verifier: JWTVerifier | None = None
_verifier_url: str | None = None


def _configured_verifier() -> JWTVerifier:
    """Return a cached verifier for the currently configured Supabase project."""

    global _verifier, _verifier_url
    url = settings.supabase_url.rstrip("/") if settings.supabase_url else None
    if not url:
        raise AuthServiceUnavailableError()
    if _verifier is None or _verifier_url != url:
        _verifier = JWTVerifier(
            issuer=f"{url}/auth/v1",
            audience="authenticated",
            jwks_url=f"{url}/auth/v1/.well-known/jwks.json",
        )
        _verifier_url = url
    return _verifier


def _one_header(headers: Any, name: str) -> str | None:
    values = headers.getlist(name)
    if len(values) > 1:
        from auth import MalformedCredentialsError

        raise MalformedCredentialsError()
    return values[0] if values else None


def _http_error(error: AuthError) -> HTTPException:
    return HTTPException(
        status_code=error.status_code,
        detail={"code": error.code, "message": error.public_message},
    )


def _verify_headers(headers: Any) -> tuple[RequestContext, str]:
    try:
        token = parse_bearer_authorization(_one_header(headers, "authorization"))
        context = _configured_verifier().verify(
            token,
            requested_device_id=_one_header(headers, "x-swara-device-id"),
            correlation_id=_one_header(headers, "x-correlation-id"),
        )
    except AuthError:
        raise
    except Exception as error:
        # Header parsing must not turn a bad value into an implementation leak.
        from auth import InvalidTokenError

        raise InvalidTokenError() from error
    return context, token


async def require_authenticated_context(request: Request) -> RequestContext:
    """Require a signed Supabase user JWT and expose its safe context only."""

    try:
        context, token = _verify_headers(request.headers)
    except AuthError as error:
        raise _http_error(error) from error
    request.state.request_context = context
    request.state.supabase_access_token = token
    return context


def vault_repository(request: Request, context: RequestContext) -> VaultRepository:
    """Build one RLS-scoped Vault repository from the verified bearer token."""

    token = getattr(request.state, "supabase_access_token", None)
    if not isinstance(token, str) or not token:
        raise HTTPException(status_code=500, detail="Verified request state is unavailable")
    if not settings.supabase_url or not settings.supabase_publishable_key:
        raise HTTPException(status_code=503, detail="Vault integration is not configured")
    return VaultRepository(
        user_client(settings.supabase_url, settings.supabase_publishable_key, token),
        context,
    )


def vault_repository_for_websocket(websocket: WebSocket) -> VaultRepository:
    """Build the same RLS-scoped Vault repository for an authenticated socket."""

    context = getattr(websocket.state, "request_context", None)
    token = getattr(websocket.state, "supabase_access_token", None)
    if not isinstance(context, RequestContext) or not isinstance(token, str) or not token:
        raise HTTPException(status_code=500, detail="Verified socket state is unavailable")
    if not settings.supabase_url or not settings.supabase_publishable_key:
        raise HTTPException(status_code=503, detail="Vault integration is not configured")
    return VaultRepository(
        user_client(settings.supabase_url, settings.supabase_publishable_key, token),
        context,
    )


async def authenticate_websocket(websocket: WebSocket) -> RequestContext:
    """Authenticate a socket before its handler accepts the connection."""

    try:
        token = parse_websocket_subprotocol(_one_header(websocket.headers, "sec-websocket-protocol"))
        context = _configured_verifier().verify(
            token,
            requested_device_id=_one_header(websocket.headers, "x-swara-device-id"),
            correlation_id=_one_header(websocket.headers, "x-correlation-id"),
        )
    except AuthError:
        raise
    websocket.state.request_context = context
    websocket.state.supabase_access_token = token
    return context


WebSocketHandler = Callable[[WebSocket], Awaitable[None]]


def authenticated_websocket(handler: WebSocketHandler) -> WebSocketHandler:
    """Wrap a socket handler so rejected credentials never reach application code."""

    async def wrapped(websocket: WebSocket) -> None:
        try:
            await authenticate_websocket(websocket)
        except AuthError as error:
            await websocket.close(code=1013 if error.status_code == 503 else 4401)
            return
        await handler(websocket)

    return wrapped
