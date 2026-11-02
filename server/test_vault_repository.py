"""Offline contract tests for the request-scoped Vault repository."""

from __future__ import annotations

import unittest
from dataclasses import dataclass
from typing import Any

from server.repositories.common import NotFoundError, RepositoryError
from server.repositories.vault import MAX_LIMIT, VaultRepository
from server.request_context import RequestContext


USER_ID = "11111111-1111-4111-8111-111111111111"


@dataclass
class FakeResponse:
    data: list[dict[str, Any]]
    error: Any = None


class FakeChain:
    def __init__(self, client: "FakeClient", table: str) -> None:
        self.client = client
        self.table_name = table
        self.operations: list[tuple[str, Any]] = []

    def select(self, columns: str) -> "FakeChain":
        self.operations.append(("select", columns))
        return self

    def insert(self, payload: dict[str, Any]) -> "FakeChain":
        self.operations.append(("insert", payload))
        self.client.inserts.append((self.table_name, payload))
        return self

    def eq(self, field: str, value: Any) -> "FakeChain":
        self.operations.append(("eq", (field, value)))
        return self

    def neq(self, field: str, value: Any) -> "FakeChain":
        self.operations.append(("neq", (field, value)))
        return self

    def is_(self, field: str, value: Any) -> "FakeChain":
        self.operations.append(("is", (field, value)))
        return self

    def ilike(self, field: str, value: Any) -> "FakeChain":
        self.operations.append(("ilike", (field, value)))
        return self

    def or_(self, value: str) -> "FakeChain":
        self.operations.append(("or", value))
        return self

    def order(self, field: str, *, desc: bool = False) -> "FakeChain":
        self.operations.append(("order", (field, desc)))
        return self

    def limit(self, value: int) -> "FakeChain":
        self.operations.append(("limit", value))
        return self

    def execute(self) -> FakeResponse:
        self.client.chains.append(self)
        response = self.client.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class FakeClient:
    def __init__(self, *responses: FakeResponse | Exception) -> None:
        self.responses = list(responses)
        self.chains: list[FakeChain] = []
        self.inserts: list[tuple[str, dict[str, Any]]] = []
        self.tables: list[str] = []

    def table(self, name: str) -> FakeChain:
        self.tables.append(name)
        return FakeChain(self, name)


def repository(client: FakeClient) -> VaultRepository:
    return VaultRepository(
        client,
        RequestContext(
            user_id=USER_ID,
            auth_session_id="22222222-2222-4222-8222-222222222222",
        ),
    )


class VaultRepositoryTests(unittest.TestCase):
    def test_document_listing_redundantly_scopes_user_and_hides_deleted(self) -> None:
        client = FakeClient(FakeResponse([{"id": "document-1"}]))

        rows = repository(client).list_documents(limit=7)

        self.assertEqual(rows, [{"id": "document-1"}])
        self.assertEqual(client.tables, ["vault_documents"])
        operations = client.chains[0].operations
        self.assertIn(("eq", ("user_id", USER_ID)), operations)
        self.assertIn(("neq", ("status", "deleted")), operations)
        self.assertIn(("is", ("deleted_at", "null")), operations)
        self.assertIn(("limit", 7), operations)

    def test_context_listing_and_search_are_scoped_and_bounded(self) -> None:
        client = FakeClient(FakeResponse([]), FakeResponse([]))
        repo = repository(client)

        repo.list_context_items(11)
        repo.search_context_items("graduation", 12)

        for chain in client.chains:
            self.assertIn(("eq", ("user_id", USER_ID)), chain.operations)
            self.assertIn(("eq", ("status", "active")), chain.operations)
        self.assertIn(("ilike", ("value", "%graduation%")), client.chains[1].operations)
        self.assertIn(("limit", 12), client.chains[1].operations)

    def test_first_context_insert_uses_allowlist_and_sets_ownership(self) -> None:
        client = FakeClient(FakeResponse([{"id": "item-1", "user_id": USER_ID}]))

        result = repository(client).insert_first_context_item(
            {
                "type": "fact",
                "key": "profile.name",
                "value": "Swara",
                "category": "profile",
                "scope": "persistent",
            }
        )

        self.assertEqual(result["id"], "item-1")
        table, payload = client.inserts[0]
        self.assertEqual(table, "swara_context_items")
        self.assertEqual(payload["user_id"], USER_ID)
        self.assertEqual(payload["version"], 1)
        self.assertEqual(payload["status"], "active")
        self.assertNotIn("supersedes_id", payload)

    def test_forbidden_client_owned_fields_are_rejected_before_provider_call(self) -> None:
        client = FakeClient(FakeResponse([]))
        forbidden = ("id", "user_id", "status", "version", "supersedes_id", "created_at", "updated_at")

        for field in forbidden:
            item = {"type": "fact", "key": "name", "value": "Swara", field: "attacker-value"}
            with self.subTest(field=field), self.assertRaises(ValueError):
                repository(client).insert_first_context_item(item)
        self.assertEqual(client.tables, [])

    def test_correction_reads_active_prior_and_appends_only_a_new_row(self) -> None:
        prior = {
            "id": "item-1",
            "user_id": USER_ID,
            "key": "profile.name",
            "value": "Svara",
            "category": "profile",
            "sensitivity": "standard",
            "scope": "persistent",
            "version": 3,
            "status": "active",
            "source_document_id": "document-1",
        }
        corrected = {"id": "item-2", "type": "correction", "value": "Swara"}
        client = FakeClient(FakeResponse([prior]), FakeResponse([corrected]))

        result = repository(client).append_correction("item-1", "Swara")

        self.assertEqual(result, corrected)
        self.assertEqual(client.tables, ["swara_context_items", "swara_context_items"])
        lookup = client.chains[0].operations
        self.assertIn(("eq", ("user_id", USER_ID)), lookup)
        self.assertIn(("eq", ("id", "item-1")), lookup)
        self.assertIn(("eq", ("status", "active")), lookup)
        payload = client.inserts[0][1]
        self.assertEqual(
            payload,
            {
                "user_id": USER_ID,
                "type": "correction",
                "key": "profile.name",
                "value": "Swara",
                "category": "profile",
                "sensitivity": "standard",
                "scope": "persistent",
                "source_type": "correction",
                "version": 4,
                "supersedes_id": "item-1",
                "status": "active",
                "source_document_id": "document-1",
            },
        )
        self.assertFalse(any(operation[0] == "update" for chain in client.chains for operation in chain.operations))

    def test_absent_rows_are_not_found_and_provider_errors_are_opaque(self) -> None:
        with self.assertRaises(NotFoundError):
            repository(FakeClient(FakeResponse([]))).get_document("missing")

        provider_error = RuntimeError("secret URL and SQL details")
        with self.assertRaises(RepositoryError) as raised:
            repository(FakeClient(provider_error)).list_documents()
        self.assertNotIn("secret URL", str(raised.exception))
        self.assertNotIn("SQL details", str(raised.exception))

    def test_all_public_limits_are_bounded(self) -> None:
        for action in (
            lambda repo: repo.list_documents(MAX_LIMIT + 1),
            lambda repo: repo.list_context_items(MAX_LIMIT + 1),
            lambda repo: repo.search_context_items("x", MAX_LIMIT + 1),
        ):
            with self.subTest(action=action), self.assertRaises(ValueError):
                action(repository(FakeClient()))

    def test_repository_never_requests_private_or_legacy_tables(self) -> None:
        client = FakeClient(FakeResponse([]), FakeResponse([]))
        repo = repository(client)
        repo.list_documents()
        repo.list_context_items()
        self.assertEqual(set(client.tables), {"vault_documents", "swara_context_items"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
