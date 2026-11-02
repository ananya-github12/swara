"""Offline tests for the Swara authentication boundary."""

from __future__ import annotations

import base64
import json
import unittest
from typing import Any
from unittest.mock import Mock

from server.auth import (
    ExpiredTokenError,
    InsufficientRoleError,
    InvalidTokenError,
    JWTVerifier,
    MalformedCredentialsError,
    MissingCredentialsError,
    parse_bearer_authorization,
    parse_websocket_subprotocol,
)


USER_ID = "11111111-1111-4111-8111-111111111111"
SESSION_ID = "22222222-2222-4222-8222-222222222222"
DEVICE_ID = "44444444-4444-4444-8444-444444444444"
CORRELATION_ID = "33333333-3333-4333-8333-333333333333"
FUTURE_EXPIRATION = 4_102_444_800  # 2100-01-01, independent of the test clock.


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _compact_jwt(
    *,
    algorithm: str = "RS256",
    key_id: str | None = "key-1",
    payload: str = "e30",
) -> str:
    header: dict[str, str] = {"alg": algorithm, "typ": "JWT"}
    if key_id is not None:
        header["kid"] = key_id
    encoded_header = _base64url(json.dumps(header, separators=(",", ":")).encode())
    return f"{encoded_header}.{payload}.signature"


def _websocket_token(token: str) -> str:
    return _base64url(token.encode("utf-8"))


def _claims(**overrides: Any) -> dict[str, Any]:
    claims: dict[str, Any] = {
        "sub": USER_ID,
        "session_id": SESSION_ID,
        "role": "authenticated",
        "exp": FUTURE_EXPIRATION,
    }
    claims.update(overrides)
    return claims


class AuthParsingTests(unittest.TestCase):
    def test_bearer_parser_accepts_one_case_insensitive_scheme_and_token(self) -> None:
        self.assertEqual(parse_bearer_authorization("Bearer access-token"), "access-token")
        self.assertEqual(parse_bearer_authorization("bEaReR access-token"), "access-token")

    def test_bearer_parser_rejects_missing_or_malformed_credentials(self) -> None:
        with self.assertRaises(MissingCredentialsError):
            parse_bearer_authorization(None)

        malformed_values: tuple[object, ...] = (
            123,
            "",
            " Bearer token",
            "Bearer token ",
            "Bearer  token",
            "Bearer\ttoken",
            "Basic token",
            "Bearer",
            "Bearer token\nextra",
        )
        for value in malformed_values:
            with self.subTest(value=value), self.assertRaises(MalformedCredentialsError):
                parse_bearer_authorization(value)

    def test_websocket_parser_accepts_both_documented_protocol_forms(self) -> None:
        token = _compact_jwt()
        encoded = _websocket_token(token)

        self.assertEqual(
            parse_websocket_subprotocol(f"swara.auth.{encoded}"),
            token,
        )
        self.assertEqual(
            parse_websocket_subprotocol(f"swara.auth, {encoded}"),
            token,
        )

    def test_websocket_parser_accepts_already_separated_protocols(self) -> None:
        token = _compact_jwt()
        self.assertEqual(
            parse_websocket_subprotocol(["swara.auth", _websocket_token(token)]),
            token,
        )

    def test_websocket_parser_rejects_missing_raw_and_malformed_credentials(self) -> None:
        token = _compact_jwt()
        encoded = _websocket_token(token)

        with self.assertRaises(MissingCredentialsError):
            parse_websocket_subprotocol(None)

        malformed_values: tuple[object, ...] = (
            token,
            "swara.auth",
            "swara.auth.",
            "swara.auth, " + token,
            f"swara.auth.{encoded},extra",
            f"swara.auth, {encoded}, extra",
            ["swara.auth", encoded, "extra"],
            ["swara.auth", "not base64"],
            ["swara.auth", encoded + " "],
            123,
        )
        for value in malformed_values:
            with self.subTest(value=value), self.assertRaises(MalformedCredentialsError):
                parse_websocket_subprotocol(value)


class JWTVerifierTests(unittest.TestCase):
    def _verifier(
        self,
        *,
        claims: dict[str, Any] | None = None,
        keys: list[dict[str, Any]] | None = None,
        fetcher: Mock | None = None,
        decoder: Mock | None = None,
        loader: Mock | None = None,
        clock: Mock | None = None,
        ttl: int = 600,
    ) -> tuple[JWTVerifier, Mock, Mock, Mock, Mock]:
        fetcher = fetcher or Mock(return_value={"keys": keys or [{"kid": "key-1", "alg": "RS256"}]})
        decoder = decoder or Mock(return_value=claims or _claims())
        loader = loader or Mock(side_effect=lambda jwk: ("loaded", jwk["kid"], jwk["alg"]))
        clock = clock or Mock(return_value=100.0)
        verifier = JWTVerifier(
            issuer="https://swara.supabase.co/auth/v1",
            audience="authenticated",
            jwks_url="https://swara.supabase.co/auth/v1/.well-known/jwks.json",
            jwks_cache_ttl_seconds=ttl,
            decoder=decoder,
            jwks_fetcher=fetcher,
            jwk_loader=loader,
            clock=clock,
        )
        return verifier, fetcher, decoder, loader, clock

    def test_verifier_selects_matching_kid_and_algorithm_and_forwards_claim_contract(self) -> None:
        keys = [
            {"kid": "key-1", "alg": "ES256", "use": "sig"},
            {"kid": "key-1", "alg": "RS256", "use": "enc"},
            {"kid": "key-2", "alg": "RS256", "use": "sig"},
            {"kid": "key-1", "alg": "RS256", "use": "sig", "kty": "RSA"},
        ]
        verifier, fetcher, decoder, loader, _ = self._verifier(keys=keys)
        token = _compact_jwt()

        context = verifier.verify(
            token,
            requested_device_id=DEVICE_ID,
            correlation_id=CORRELATION_ID,
        )

        self.assertEqual(context.user_id, USER_ID)
        self.assertEqual(context.auth_session_id, SESSION_ID)
        self.assertEqual(context.device_id, DEVICE_ID)
        self.assertEqual(context.correlation_id, CORRELATION_ID)
        fetcher.assert_called_once_with("https://swara.supabase.co/auth/v1/.well-known/jwks.json")
        loader.assert_called_once_with(keys[3])
        decoder.assert_called_once_with(
            token,
            key=("loaded", "key-1", "RS256"),
            algorithms=("RS256", "ES256"),
            audience="authenticated",
            issuer="https://swara.supabase.co/auth/v1",
        )

    def test_verifier_rejects_unsupported_algorithm_and_missing_kid_before_jwks_fetch(self) -> None:
        fetcher = Mock(return_value={"keys": []})
        verifier, _, decoder, loader, _ = self._verifier(fetcher=fetcher)

        for token in (_compact_jwt(algorithm="HS256"), _compact_jwt(key_id=None)):
            with self.subTest(token=token), self.assertRaises(InvalidTokenError):
                verifier.verify(token)

        fetcher.assert_not_called()
        decoder.assert_not_called()
        loader.assert_not_called()

    def test_verifier_rejects_unknown_kid_or_algorithm_mismatch(self) -> None:
        for key in (
            {"kid": "other", "alg": "RS256", "use": "sig"},
            {"kid": "key-1", "alg": "ES256", "use": "sig"},
            {"kid": "key-1", "alg": "RS256", "use": "enc"},
        ):
            verifier, fetcher, decoder, loader, _ = self._verifier(keys=[key])
            with self.subTest(key=key), self.assertRaises(InvalidTokenError):
                verifier.verify(_compact_jwt())
            fetcher.assert_called_once()
            decoder.assert_not_called()
            loader.assert_not_called()

    def test_verifier_caches_jwks_until_ttl_and_refetches_after_expiry(self) -> None:
        now = [100.0]
        clock = Mock(side_effect=lambda: now[0])
        fetcher = Mock(return_value={"keys": [{"kid": "key-1", "alg": "RS256"}]})
        verifier, _, _, _, _ = self._verifier(fetcher=fetcher, clock=clock, ttl=10)
        token = _compact_jwt()

        verifier.verify(token)
        now[0] = 109.99
        verifier.verify(token)
        self.assertEqual(fetcher.call_count, 1)

        now[0] = 110.0
        verifier.verify(token)
        self.assertEqual(fetcher.call_count, 2)

    def test_verifier_requires_https_and_bounded_cache_ttl(self) -> None:
        common = {
            "issuer": "issuer",
            "audience": "audience",
            "jwks_url": "https://example.test/jwks",
        }
        with self.assertRaises(ValueError):
            JWTVerifier(**{**common, "jwks_url": "http://example.test/jwks"})
        with self.assertRaises(ValueError):
            JWTVerifier(**{**common, "jwks_cache_ttl_seconds": 601})

    def test_authenticated_role_is_required(self) -> None:
        verifier, _, _, _, _ = self._verifier(claims=_claims(role="anon"))
        with self.assertRaises(InsufficientRoleError):
            verifier.verify(_compact_jwt())

    def test_sub_and_session_id_must_be_uuid_strings(self) -> None:
        invalid_claims = (
            {"sub": "not-a-uuid"},
            {"session_id": "not-a-uuid"},
            {"sub": None},
            {"session_id": None},
            {"exp": None},
            {"exp": True},
            {"exp": "4102444800"},
        )
        for overrides in invalid_claims:
            verifier, _, _, _, _ = self._verifier(claims=_claims(**overrides))
            with self.subTest(overrides=overrides), self.assertRaises(InvalidTokenError):
                verifier.verify(_compact_jwt())

    def test_expiration_is_enforced_at_the_request_context_boundary(self) -> None:
        verifier, _, _, _, _ = self._verifier(claims=_claims(exp=1))
        with self.assertRaises(ExpiredTokenError):
            verifier.verify(_compact_jwt())

    def test_device_id_mismatch_is_rejected_and_matching_device_is_propagated(self) -> None:
        verifier, _, _, _, _ = self._verifier(claims=_claims(device_id=DEVICE_ID))

        with self.assertRaises(InvalidTokenError):
            verifier.verify(_compact_jwt(), requested_device_id="another-device")

        context = verifier.verify(_compact_jwt(), requested_device_id=DEVICE_ID)
        self.assertEqual(context.device_id, DEVICE_ID)

    def test_no_token_is_retained_in_context_or_exposed_in_auth_errors(self) -> None:
        token = _compact_jwt()
        verifier, _, _, _, _ = self._verifier(claims=_claims(role="anon"))

        with self.assertRaises(InsufficientRoleError) as raised:
            verifier.verify(token)
        self.assertNotIn(token, str(raised.exception))
        self.assertNotIn(token, repr(raised.exception))

        verifier, _, _, _, _ = self._verifier()
        context = verifier.verify(token)
        self.assertNotIn(token, repr(context))
        self.assertFalse(hasattr(context, "token"))
        self.assertNotIn(token, context.__slots__)


if __name__ == "__main__":
    unittest.main()
