"""Framework-neutral verification primitives for Swara user access tokens.

No function in this module logs or retains an access token.  Framework adapters
should parse their request/header objects and pass only the resulting string to
``JWTVerifier.verify`` at the authentication boundary.

WebSocket credentials intentionally use a subprotocol rather than a query
parameter.  The accepted forms are exactly one of:

* ``Sec-WebSocket-Protocol: swara.auth.<base64url-access-token>``
* ``Sec-WebSocket-Protocol: swara.auth, <base64url-access-token>``

The latter is useful for clients whose WebSocket API only accepts a list of
subprotocols.  The base64url value decodes to the JWT; raw JWTs are never
accepted as a WebSocket protocol value.
"""

from __future__ import annotations

import base64
import binascii
import json
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Final
from urllib.request import Request, urlopen
from uuid import UUID

from server.request_context import RequestContext, RequestContextError, build_request_context


_ALLOWED_ALGORITHMS: Final = ("RS256", "ES256")
_B64URL_CHARS: Final = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)
_DEFAULT_JWKS_CACHE_TTL_SECONDS: Final = 600
_DEFAULT_JWKS_TIMEOUT_SECONDS: Final = 5.0


class AuthError(Exception):
    """Base class for authentication failures safe to expose to a client."""

    status_code: Final[int] = 401
    code: Final[str] = "authentication_failed"
    public_message: Final[str] = "Authentication failed"

    def __str__(self) -> str:
        return self.public_message


class MissingCredentialsError(AuthError):
    code = "credentials_missing"
    public_message = "Authentication credentials are required"


class MalformedCredentialsError(AuthError):
    code = "credentials_malformed"
    public_message = "Authentication credentials are malformed"


class InvalidTokenError(AuthError):
    code = "token_invalid"
    public_message = "Authentication token is invalid"


class ExpiredTokenError(InvalidTokenError):
    code = "token_expired"
    public_message = "Authentication token has expired"


class InsufficientRoleError(AuthError):
    """A signed token is valid but is not a Swara user session (HTTP 403)."""

    status_code = 403
    code = "authenticated_role_required"
    public_message = "An authenticated Swara user session is required"


class AuthServiceUnavailableError(AuthError):
    """Verification could not obtain the configured public signing key (HTTP 503)."""

    status_code = 503
    code = "authentication_unavailable"
    public_message = "Authentication verification is temporarily unavailable"


def parse_bearer_authorization(value: object | None) -> str:
    """Return the sole RFC 6750 bearer token from an Authorization value.

    The parser is deliberately stricter than a generic whitespace split: it
    permits exactly ``Bearer`` followed by one visible, non-whitespace token.
    Callers should pass a single header value; duplicate Authorization headers
    must be rejected by their HTTP adapter before reaching this function.
    """

    if value is None:
        raise MissingCredentialsError()
    if not isinstance(value, str):
        raise MalformedCredentialsError()
    if not value or value != value.strip():
        raise MalformedCredentialsError()
    scheme, separator, token = value.partition(" ")
    if scheme.lower() != "bearer" or separator != " " or not token:
        raise MalformedCredentialsError()
    if token[0].isspace() or any(character.isspace() or not character.isprintable() for character in token):
        raise MalformedCredentialsError()
    return token


def _decode_base64url(value: str) -> bytes:
    if not value or any(character not in _B64URL_CHARS for character in value):
        raise MalformedCredentialsError()
    try:
        return base64.urlsafe_b64decode(value + ("=" * (-len(value) % 4)))
    except (ValueError, binascii.Error) as error:
        raise MalformedCredentialsError() from error


def parse_websocket_subprotocol(value: object | None) -> str:
    """Extract a JWT from the documented Swara WebSocket protocol forms.

    ``value`` may be the raw header string or a sequence of already separated
    protocol values.  Empty values, duplicate values, raw JWTs and any extra
    protocol are rejected.  This keeps browser intermediaries and server logs
    from receiving query-string credentials.
    """

    if value is None:
        raise MissingCredentialsError()
    if isinstance(value, str):
        # RFC 6455 permits optional whitespace around comma-separated values.
        # Browsers commonly serialize ``["swara.auth", encoded]`` as
        # ``swara.auth, encoded``.
        protocols = [protocol.strip() for protocol in value.split(",")]
    elif isinstance(value, Sequence) and not isinstance(value, (bytes, bytearray)):
        protocols = list(value)
    else:
        raise MalformedCredentialsError()

    if not protocols or any(not isinstance(protocol, str) for protocol in protocols):
        raise MalformedCredentialsError()
    if any(not protocol or protocol != protocol.strip() for protocol in protocols):
        raise MalformedCredentialsError()

    encoded: str
    if len(protocols) == 1 and protocols[0].startswith("swara.auth."):
        encoded = protocols[0][len("swara.auth.") :]
    elif len(protocols) == 2 and protocols[0] == "swara.auth":
        encoded = protocols[1]
    else:
        raise MalformedCredentialsError()

    try:
        token = _decode_base64url(encoded).decode("utf-8")
    except UnicodeDecodeError as error:
        raise MalformedCredentialsError() from error
    _validate_compact_jwt(token)
    return token


def _validate_compact_jwt(token: str) -> None:
    """Ensure a token has a non-empty compact-JWT shape without decoding claims."""

    parts = token.split(".")
    if len(parts) != 3 or any(not part for part in parts):
        raise MalformedCredentialsError()
    for part in parts:
        if any(character not in _B64URL_CHARS for character in part):
            raise MalformedCredentialsError()


def _unverified_header(token: str) -> Mapping[str, object]:
    """Read only the key-selection header; never trust it for authorization."""

    _validate_compact_jwt(token)
    try:
        header = json.loads(_decode_base64url(token.split(".", 1)[0]))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidTokenError() from error
    if not isinstance(header, dict):
        raise InvalidTokenError()
    return header


def _default_jwks_fetcher(url: str) -> Mapping[str, object]:
    request = Request(url, headers={"Accept": "application/json"})
    try:
        with urlopen(request, timeout=_DEFAULT_JWKS_TIMEOUT_SECONDS) as response:  # nosec B310 - configured HTTPS URL
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuthServiceUnavailableError() from error
    if not isinstance(payload, dict) or not isinstance(payload.get("keys"), list):
        raise AuthServiceUnavailableError()
    return payload


def _default_decoder(
    token: str,
    *,
    key: object,
    algorithms: Sequence[str],
    audience: str,
    issuer: str,
) -> Mapping[str, object]:
    """Lazily import PyJWT so this module stays importable before dependency setup."""

    try:
        import jwt  # type: ignore[import-not-found]
    except ImportError as error:
        raise AuthServiceUnavailableError() from error
    try:
        claims = jwt.decode(
            token,
            key=key,
            algorithms=list(algorithms),
            audience=audience,
            issuer=issuer,
            options={"require": ["exp", "sub", "role", "session_id"]},
        )
    except jwt.ExpiredSignatureError as error:
        raise ExpiredTokenError() from error
    except jwt.InvalidTokenError as error:
        raise InvalidTokenError() from error
    if not isinstance(claims, dict):
        raise InvalidTokenError()
    return claims


def _jwk_key(jwk: Mapping[str, object]) -> object:
    try:
        import jwt  # type: ignore[import-not-found]
    except ImportError as error:
        raise AuthServiceUnavailableError() from error
    try:
        return jwt.PyJWK.from_dict(dict(jwk)).key
    except (TypeError, ValueError) as error:
        raise InvalidTokenError() from error


Decoder = Callable[..., Mapping[str, object]]
JWKSFetcher = Callable[[str], Mapping[str, object]]
JWKLoader = Callable[[Mapping[str, object]], object]
Clock = Callable[[], float]


@dataclass(slots=True)
class JWTVerifier:
    """Verify Swara access tokens against one exact asymmetric-key issuer.

    ``decoder`` and ``jwks_fetcher`` are injectable to make unit tests fully
    offline.  A decoder receives keyword arguments ``key``, ``algorithms``,
    ``audience`` and ``issuer`` and must verify the signature and registered
    claims before returning a mapping of claims.
    """

    issuer: str
    audience: str
    jwks_url: str
    jwks_cache_ttl_seconds: int = _DEFAULT_JWKS_CACHE_TTL_SECONDS
    decoder: Decoder = _default_decoder
    jwks_fetcher: JWKSFetcher = _default_jwks_fetcher
    jwk_loader: JWKLoader = _jwk_key
    clock: Clock = time.monotonic
    _cached_jwks: Mapping[str, object] | None = field(default=None, init=False, repr=False)
    _jwks_cached_at: float = field(default=0.0, init=False, repr=False)

    def __post_init__(self) -> None:
        for field_name in ("issuer", "audience", "jwks_url"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value or value != value.strip():
                raise ValueError(f"{field_name} must be a non-empty, unpadded string")
        if not self.jwks_url.startswith("https://"):
            raise ValueError("jwks_url must use HTTPS")
        if not isinstance(self.jwks_cache_ttl_seconds, int) or not 0 <= self.jwks_cache_ttl_seconds <= 600:
            raise ValueError("jwks_cache_ttl_seconds must be between 0 and 600")

    def verify(
        self,
        token: str,
        *,
        requested_device_id: str | None = None,
        correlation_id: str | None = None,
    ) -> RequestContext:
        """Verify one access token and return its non-secret request context."""

        if not isinstance(token, str):
            raise MalformedCredentialsError()
        header = _unverified_header(token)
        algorithm = header.get("alg")
        key_id = header.get("kid")
        if algorithm not in _ALLOWED_ALGORITHMS or not isinstance(key_id, str) or not key_id:
            raise InvalidTokenError()

        claims = self.decoder(
            token,
            key=self.jwk_loader(self._key_for(key_id, algorithm)),
            algorithms=_ALLOWED_ALGORITHMS,
            audience=self.audience,
            issuer=self.issuer,
        )
        return _context_from_claims(
            claims,
            requested_device_id=requested_device_id,
            correlation_id=correlation_id,
        )

    def _key_for(self, key_id: str, algorithm: str) -> Mapping[str, object]:
        jwks = self._jwks()
        keys = jwks.get("keys")
        if not isinstance(keys, list):
            raise AuthServiceUnavailableError()
        for key in keys:
            if (
                isinstance(key, dict)
                and key.get("kid") == key_id
                and key.get("alg") == algorithm
                and key.get("use", "sig") == "sig"
            ):
                return key
        raise InvalidTokenError()

    def _jwks(self) -> Mapping[str, object]:
        now = self.clock()
        if self._cached_jwks is None or now - self._jwks_cached_at >= self.jwks_cache_ttl_seconds:
            try:
                jwks = self.jwks_fetcher(self.jwks_url)
            except AuthError:
                raise
            except Exception as error:
                raise AuthServiceUnavailableError() from error
            if not isinstance(jwks, Mapping) or not isinstance(jwks.get("keys"), list):
                raise AuthServiceUnavailableError()
            self._cached_jwks = jwks
            self._jwks_cached_at = now
        return self._cached_jwks


def _context_from_claims(
    claims: Mapping[str, object],
    *,
    requested_device_id: str | None,
    correlation_id: str | None,
) -> RequestContext:
    if not isinstance(claims, Mapping):
        raise InvalidTokenError()
    if claims.get("role") != "authenticated":
        raise InsufficientRoleError()

    subject = claims.get("sub")
    session_id = claims.get("session_id")
    expiration = claims.get("exp")
    try:
        user_id = str(UUID(subject)) if isinstance(subject, str) else None
        verified_session_id = str(UUID(session_id)) if isinstance(session_id, str) else None
    except (TypeError, ValueError, AttributeError) as error:
        raise InvalidTokenError() from error
    if user_id is None or verified_session_id is None or isinstance(expiration, bool) or not isinstance(expiration, (int, float)):
        raise InvalidTokenError()
    if expiration <= time.time():
        raise ExpiredTokenError()

    token_device_id = claims.get("device_id")
    if token_device_id is not None and not isinstance(token_device_id, str):
        raise InvalidTokenError()
    try:
        return build_request_context(
            user_id=user_id,
            auth_session_id=verified_session_id,
            token_device_id=token_device_id,
            requested_device_id=requested_device_id,
            correlation_id=correlation_id,
        )
    except RequestContextError as error:
        raise InvalidTokenError() from error


__all__ = [
    "AuthError",
    "AuthServiceUnavailableError",
    "ExpiredTokenError",
    "InsufficientRoleError",
    "InvalidTokenError",
    "JWTVerifier",
    "MalformedCredentialsError",
    "MissingCredentialsError",
    "parse_bearer_authorization",
    "parse_websocket_subprotocol",
]
