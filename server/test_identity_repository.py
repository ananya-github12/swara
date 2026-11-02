"""Offline contract tests for the request-scoped identity repository."""

from __future__ import annotations

import unittest
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from server.request_context import RequestContext
from server.repositories.common import NotFoundError, RepositoryError
from server.repositories.identity import IdentityRepository


@dataclass
class _Response:
    data: list[dict[str, Any]]


class _FakeQuery:
    def __init__(self, response: _Response | Exception) -> None:
        self.response = response
        self.calls: list[tuple[Any, ...]] = []

    def select(self, columns: str) -> _FakeQuery:
        self.calls.append(("select", columns))
        return self

    def update(self, payload: dict[str, Any]) -> _FakeQuery:
        self.calls.append(("update", payload))
        return self

    def insert(self, payload: dict[str, Any]) -> _FakeQuery:
        self.calls.append(("insert", payload))
        return self

    def eq(self, column: str, value: Any) -> _FakeQuery:
        self.calls.append(("eq", column, value))
        return self

    def is_(self, column: str, value: Any) -> _FakeQuery:
        self.calls.append(("is", column, value))
        return self

    def or_(self, expression: str) -> _FakeQuery:
        self.calls.append(("or", expression))
        return self

    def order(self, column: str, *, desc: bool = False) -> _FakeQuery:
        self.calls.append(("order", column, desc))
        return self

    def execute(self) -> _Response:
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


class _FakeClient:
    def __init__(self, responses: dict[str, _Response | Exception]) -> None:
        self.responses = responses
        self.queries: list[tuple[str, _FakeQuery]] = []

    def table(self, name: str) -> _FakeQuery:
        query = _FakeQuery(self.responses[name])
        self.queries.append((name, query))
        return query


class IdentityRepositoryTests(unittest.TestCase):
    user_id = "11111111-1111-1111-1111-111111111111"

    def setUp(self) -> None:
        self.context = RequestContext(
            user_id=self.user_id,
            auth_session_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        )

    def repository(self, **responses: _Response | Exception) -> tuple[IdentityRepository, _FakeClient]:
        client = _FakeClient(responses)
        return IdentityRepository(client, self.context), client

    def assert_user_scope(self, query: _FakeQuery) -> None:
        self.assertIn(("eq", "user_id", self.user_id), query.calls)

    def test_profile_reads_and_updates_are_owned_and_hide_soft_deleted(self) -> None:
        repository, client = self.repository(profiles=_Response([{"user_id": self.user_id}]))
        self.assertEqual(repository.get_profile()["user_id"], self.user_id)
        profile_query = client.queries[-1][1]
        self.assert_user_scope(profile_query)
        self.assertIn(("is", "deleted_at", "null"), profile_query.calls)

        repository.update_profile({"display_name": "Swara"})
        update_query = client.queries[-1][1]
        self.assert_user_scope(update_query)
        self.assertIn(("update", {"display_name": "Swara"}), update_query.calls)
        self.assertIn(("is", "deleted_at", "null"), update_query.calls)

    def test_profile_and_settings_reject_forbidden_fields(self) -> None:
        repository, client = self.repository(profiles=_Response([]), user_settings=_Response([]))
        with self.assertRaises(ValueError):
            repository.update_profile({"user_id": "other"})
        with self.assertRaises(ValueError):
            repository.update_settings({"created_at": "no"})
        self.assertEqual(client.queries, [])

    def test_invisible_singletons_are_not_found(self) -> None:
        repository, _ = self.repository(profiles=_Response([]), user_settings=_Response([]))
        with self.assertRaises(NotFoundError):
            repository.get_profile()
        with self.assertRaises(NotFoundError):
            repository.get_settings()

    def test_settings_reads_and_updates_are_owned(self) -> None:
        repository, client = self.repository(user_settings=_Response([{"user_id": self.user_id}]))
        repository.get_settings()
        self.assert_user_scope(client.queries[-1][1])
        repository.update_settings({"privacy_mode": "local-first"})
        query = client.queries[-1][1]
        self.assert_user_scope(query)
        self.assertIn(("update", {"privacy_mode": "local-first"}), query.calls)

    def test_device_listing_scopes_user_and_filters_revocation_by_default(self) -> None:
        repository, client = self.repository(devices=_Response([]))
        repository.list_devices()
        query = client.queries[-1][1]
        self.assert_user_scope(query)
        self.assertIn(("is", "revoked_at", "null"), query.calls)
        self.assertIn(("order", "last_seen_at", True), query.calls)

        repository.list_devices(include_revoked=True)
        self.assertNotIn(("is", "revoked_at", "null"), client.queries[-1][1].calls)

    def test_current_policy_listing_scopes_user_and_expiry(self) -> None:
        repository, client = self.repository(domain_policies=_Response([]))
        repository.list_current_domain_policies(now=datetime(2026, 8, 24, tzinfo=timezone.utc))
        query = client.queries[-1][1]
        self.assert_user_scope(query)
        self.assertIn(("or", "expires_at.is.null,expires_at.gt.2026-08-24T00:00:00+00:00"), query.calls)

    def test_consent_is_append_only_and_explicitly_sets_owner(self) -> None:
        repository, client = self.repository(consent_records=_Response([{"id": "consent-1"}]))
        repository.append_consent(
            consent_type="terms", policy_version="2026-08", granted=True, metadata={"source": "ui"}
        )
        query = client.queries[-1][1]
        self.assertEqual(client.queries[-1][0], "consent_records")
        self.assertIn(
            (
                "insert",
                {
                    "user_id": self.user_id,
                    "consent_type": "terms",
                    "policy_version": "2026-08",
                    "granted": True,
                    "metadata": {"source": "ui"},
                },
            ),
            query.calls,
        )
        self.assertFalse(any(call[0] in {"update", "delete"} for call in query.calls))

    def test_consent_listing_scopes_user_and_optional_type(self) -> None:
        repository, client = self.repository(consent_records=_Response([]))
        repository.list_consents(consent_type="analytics")
        query = client.queries[-1][1]
        self.assert_user_scope(query)
        self.assertIn(("eq", "consent_type", "analytics"), query.calls)
        self.assertIn(("order", "recorded_at", True), query.calls)

    def test_provider_errors_are_opaque(self) -> None:
        repository, _ = self.repository(profiles=RuntimeError("provider secret: token"))
        with self.assertRaisesRegex(RepositoryError, "^Persistence operation failed$"):
            repository.get_profile()


if __name__ == "__main__":
    unittest.main()
