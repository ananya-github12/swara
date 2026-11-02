import unittest
from dataclasses import FrozenInstanceError

from server.request_context import (
    RequestContext,
    RequestContextError,
    build_request_context,
)

USER_ID = "11111111-1111-4111-8111-111111111111"
AUTH_SESSION_ID = "22222222-2222-4222-8222-222222222222"
DEVICE_ID = "44444444-4444-4444-8444-444444444444"


class RequestContextTests(unittest.TestCase):
    def test_context_is_immutable(self) -> None:
        context = RequestContext(
            user_id=USER_ID,
            auth_session_id=AUTH_SESSION_ID,
            device_id=DEVICE_ID,
            correlation_id="33333333-3333-4333-8333-333333333333",
        )

        with self.assertRaises(FrozenInstanceError):
            context.user_id = "other-user"  # type: ignore[misc]
        with self.assertRaises(FrozenInstanceError):
            context.device_id = "55555555-5555-4555-8555-555555555555"  # type: ignore[misc]
        with self.assertRaises(FrozenInstanceError):
            context.correlation_id = "other-correlation"  # type: ignore[misc]

    def test_missing_correlation_id_is_generated(self) -> None:
        first = build_request_context(user_id=USER_ID, auth_session_id=AUTH_SESSION_ID)
        second = build_request_context(user_id=USER_ID, auth_session_id=AUTH_SESSION_ID)

        self.assertRegex(first.correlation_id, r"^[0-9a-f-]{36}$")
        self.assertRegex(second.correlation_id, r"^[0-9a-f-]{36}$")
        self.assertNotEqual(first.correlation_id, second.correlation_id)

    def test_supplied_correlation_id_is_preserved(self) -> None:
        context = build_request_context(
            user_id=USER_ID,
            auth_session_id=AUTH_SESSION_ID,
            correlation_id="33333333-3333-4333-8333-333333333333",
        )

        self.assertEqual(context.correlation_id, "33333333-3333-4333-8333-333333333333")

    def test_padded_identifiers_are_rejected(self) -> None:
        cases = (
            {"user_id": f" {USER_ID}"},
            {"user_id": f"{USER_ID} "},
            {"auth_session_id": f" {AUTH_SESSION_ID}"},
            {"auth_session_id": f"{AUTH_SESSION_ID} "},
            {"token_device_id": f" {DEVICE_ID}"},
            {"requested_device_id": f"{DEVICE_ID} "},
            {"correlation_id": " 33333333-3333-4333-8333-333333333333"},
            {"correlation_id": "33333333-3333-4333-8333-333333333333 "},
        )

        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(RequestContextError):
                build_request_context(
                    user_id=overrides.pop("user_id", USER_ID),
                    auth_session_id=overrides.pop("auth_session_id", AUTH_SESSION_ID),
                    **overrides,
                )

    def test_control_characters_are_rejected(self) -> None:
        cases = (
            {"user_id": "11111111-1111-4111-8111-11111111111\x00"},
            {"auth_session_id": "22222222-2222-4222-8222-22222222222\n"},
            {"token_device_id": "44444444-4444-4444-8444-44444444444\t"},
            {"requested_device_id": "44444444-4444-4444-8444-44444444444\r"},
            {"correlation_id": "33333333-3333-4333-8333-33333333333\n"},
        )

        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(RequestContextError):
                build_request_context(
                    user_id=overrides.pop("user_id", USER_ID),
                    auth_session_id=overrides.pop("auth_session_id", AUTH_SESSION_ID),
                    **overrides,
                )

    def test_oversized_identifiers_are_rejected(self) -> None:
        cases = (
            {"user_id": "u" * 256},
            {"auth_session_id": "s" * 256},
            {"token_device_id": "d" * 256},
            {"requested_device_id": "d" * 256},
            {"correlation_id": "c" * 129},
        )

        for overrides in cases:
            with self.subTest(field=next(iter(overrides))), self.assertRaises(RequestContextError):
                build_request_context(
                    user_id=overrides.pop("user_id", USER_ID),
                    auth_session_id=overrides.pop("auth_session_id", AUTH_SESSION_ID),
                    **overrides,
                )

    def test_signed_and_header_device_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(RequestContextError, "does not match"):
            build_request_context(
                user_id=USER_ID,
                auth_session_id=AUTH_SESSION_ID,
                token_device_id=DEVICE_ID,
                requested_device_id="55555555-5555-4555-8555-555555555555",
            )

    def test_signed_device_is_propagated_without_header(self) -> None:
        context = build_request_context(
            user_id=USER_ID,
            auth_session_id=AUTH_SESSION_ID,
            token_device_id=DEVICE_ID,
        )

        self.assertEqual(context.device_id, DEVICE_ID)

    def test_matching_header_device_is_propagated(self) -> None:
        context = build_request_context(
            user_id=USER_ID,
            auth_session_id=AUTH_SESSION_ID,
            token_device_id=DEVICE_ID,
            requested_device_id=DEVICE_ID,
        )

        self.assertEqual(context.device_id, DEVICE_ID)


if __name__ == "__main__":
    unittest.main()
