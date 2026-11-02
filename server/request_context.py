"""Immutable, request-scoped identity for Swara server work.

This module deliberately keeps bearer tokens out of the request context.  Code
that needs to call Supabase on behalf of a user receives the verified token at
the narrow client-factory boundary instead; application code should carry this
small, non-secret context object.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final
from uuid import UUID, uuid4


class RequestContextError(ValueError):
    """Raised when untrusted request identity metadata is malformed."""


_MAX_IDENTIFIER_LENGTH: Final = 255


def new_correlation_id() -> str:
    """Return an opaque correlation identifier suitable for logs and tracing."""

    return str(uuid4())


def _normalise_identifier(value: object, field_name: str) -> str:
    if not isinstance(value, str):
        raise RequestContextError(f"{field_name} must be a string")
    if not value or value != value.strip():
        raise RequestContextError(f"{field_name} must not be empty or padded")
    if len(value) > _MAX_IDENTIFIER_LENGTH:
        raise RequestContextError(f"{field_name} is too long")
    if any(character.isspace() or not character.isprintable() for character in value):
        raise RequestContextError(f"{field_name} contains unsafe characters")
    return value


def _normalise_uuid(value: object, field_name: str) -> str:
    identifier = _normalise_identifier(value, field_name)
    try:
        parsed = UUID(identifier)
    except (TypeError, ValueError, AttributeError) as error:
        raise RequestContextError(f"{field_name} must be a UUID") from error
    canonical = str(parsed)
    if identifier.lower() != canonical:
        raise RequestContextError(f"{field_name} must be a canonical UUID")
    return canonical


def normalise_optional_device_id(device_id: object | None) -> str | None:
    """Validate the optional, opaque Swara device identifier."""

    if device_id is None:
        return None
    return _normalise_uuid(device_id, "device_id")


def normalise_correlation_id(correlation_id: object | None) -> str:
    """Validate a canonical UUID correlation ID or generate a safe one."""

    if correlation_id is None:
        return new_correlation_id()
    if not isinstance(correlation_id, str) or correlation_id != correlation_id.strip():
        raise RequestContextError("correlation_id must be an unpadded UUID string")
    try:
        parsed = UUID(correlation_id)
    except (TypeError, ValueError, AttributeError) as error:
        raise RequestContextError("correlation_id must be a UUID") from error
    canonical = str(parsed)
    if correlation_id.lower() != canonical:
        raise RequestContextError("correlation_id must be a canonical UUID")
    return canonical


@dataclass(frozen=True, slots=True)
class RequestContext:
    """Verified identity carried through one HTTP or WebSocket request.

    ``device_id`` is intentionally optional because an authenticated user can
    use Swara before registering a device.  It is still a field on every
    context, so downstream repositories never need a parallel identity shape.
    """

    user_id: str
    auth_session_id: str
    device_id: str | None = None
    correlation_id: str = field(default_factory=new_correlation_id)

    def __post_init__(self) -> None:
        object.__setattr__(self, "user_id", _normalise_uuid(self.user_id, "user_id"))
        object.__setattr__(
            self,
            "auth_session_id",
            _normalise_uuid(self.auth_session_id, "auth_session_id"),
        )
        object.__setattr__(
            self,
            "device_id",
            normalise_optional_device_id(self.device_id),
        )
        object.__setattr__(
            self,
            "correlation_id",
            normalise_correlation_id(self.correlation_id),
        )


def build_request_context(
    *,
    user_id: str,
    auth_session_id: str,
    token_device_id: str | None = None,
    requested_device_id: str | None = None,
    correlation_id: str | None = None,
) -> RequestContext:
    """Build a context without allowing a request to override token identity.

    A verified custom access-token hook may include ``device_id``.  When a
    client also sends the device header, it must agree with that signed claim;
    otherwise the request is rejected rather than silently changing identity.
    """

    signed_device_id = normalise_optional_device_id(token_device_id)
    header_device_id = normalise_optional_device_id(requested_device_id)
    if signed_device_id and header_device_id and signed_device_id != header_device_id:
        raise RequestContextError("device_id does not match the verified token")

    return RequestContext(
        user_id=user_id,
        auth_session_id=auth_session_id,
        device_id=header_device_id or signed_device_id,
        correlation_id=normalise_correlation_id(correlation_id),
    )
