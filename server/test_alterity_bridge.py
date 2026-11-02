from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta
from typing import Any

from pydantic import ValidationError

from alterity_bridge import (
    AlterityBridgeClient,
    AlterityBridgeRejected,
    AlterityBridgeUnavailable,
    UsageCommit,
    UsageReservation,
)


def _bootstrap_body() -> dict[str, Any]:
    return {
        "principal": {
            "userId": "user-1",
            "email": "owner@example.com",
            "name": "Owner",
            "role": "owner",
        },
        "tenant": {
            "clientId": "client-1",
            "businessName": "Example",
            "currency": "INR",
            "subClientIds": ["branch-1"],
        },
        "entitlement": {
            "product": "swara",
            "enabled": True,
            "plan": "team",
            "capabilities": ["browser_automation", "voice"],
        },
        "wallet": {"balance": 1000, "currency": "INR", "lowBalance": False},
        "knowledgeBases": [{"id": "kb-1", "name": "Support", "status": "ready"}],
        "runtime": {"stt": ["sarvam"], "tts": ["sarvam"], "llm": ["gemini"]},
        "leaseExpiresAt": (datetime.now(UTC) + timedelta(minutes=10)).isoformat(),
    }


class FakeTransport:
    def __init__(self, responses: list[tuple[int, dict[str, Any]]]) -> None:
        self.responses = responses
        self.calls: list[dict[str, Any]] = []

    def request(self, **kwargs: Any) -> tuple[int, dict[str, Any]]:
        self.calls.append(kwargs)
        return self.responses.pop(0)


class AlterityBridgeClientTests(unittest.TestCase):
    def test_bootstrap_forwards_user_token_and_hydrates_shared_state(self) -> None:
        transport = FakeTransport([(200, _bootstrap_body())])
        client = AlterityBridgeClient(
            endpoint="https://example.supabase.co/functions/v1/swara-platform",
            transport=transport,
        )

        bootstrap = client.bootstrap("user-jwt")

        self.assertEqual(bootstrap.tenant.client_id, "client-1")
        self.assertEqual(bootstrap.knowledge_bases[0].id, "kb-1")
        call = transport.calls[0]
        self.assertEqual(call["headers"]["Authorization"], "Bearer user-jwt")
        self.assertEqual(call["payload"], {"action": "bootstrap", "product": "swara"})

    def test_metering_uses_service_identity_and_idempotency_key(self) -> None:
        transport = FakeTransport([(
            201,
            {
                "eventId": "evt-1",
                "reservationId": "res-1",
                "state": "reserved",
                "billableQuantity": 1,
                "currency": "INR",
                "duplicate": False,
            },
        )])
        client = AlterityBridgeClient(
            endpoint="https://example.supabase.co/functions/v1/swara-platform",
            service_token="service-jwt",
            transport=transport,
        )

        receipt = client.reserve_usage(
            UsageReservation(
                event_id="evt-1",
                session_id="session-1",
                client_id="client-1",
                meter="browser_session",
                quantity=1,
            ),
            idempotency_key="session-1:reserve",
        )

        self.assertEqual(receipt.state, "reserved")
        call = transport.calls[0]
        self.assertEqual(call["headers"]["Authorization"], "Bearer service-jwt")
        self.assertEqual(call["headers"]["Idempotency-Key"], "session-1:reserve")
        self.assertEqual(call["payload"]["clientId"], "client-1")

    def test_metering_fails_closed_without_server_credential(self) -> None:
        client = AlterityBridgeClient(
            endpoint="https://example.supabase.co/functions/v1/swara-platform",
            transport=FakeTransport([]),
        )

        with self.assertRaises(AlterityBridgeUnavailable):
            client.commit_usage(
                UsageCommit(
                    event_id="evt-1",
                    reservation_id="res-1",
                    actual_quantity=1,
                ),
                idempotency_key="session-1:commit",
            )

    def test_non_2xx_response_preserves_control_plane_status(self) -> None:
        client = AlterityBridgeClient(
            endpoint="https://example.supabase.co/functions/v1/swara-platform",
            transport=FakeTransport([(403, {"error": "Swara is not enabled"})]),
        )

        with self.assertRaises(AlterityBridgeRejected) as raised:
            client.bootstrap("user-jwt")

        self.assertEqual(raised.exception.status_code, 403)
        self.assertEqual(str(raised.exception), "Swara is not enabled")

    def test_invalid_bootstrap_contract_is_rejected(self) -> None:
        client = AlterityBridgeClient(
            endpoint="https://example.supabase.co/functions/v1/swara-platform",
            transport=FakeTransport([(200, {"entitlement": {"enabled": True}})]),
        )

        with self.assertRaises(ValidationError):
            client.bootstrap("user-jwt")


if __name__ == "__main__":
    unittest.main(verbosity=2)
