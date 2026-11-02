"""Offline route-level security contracts for the FastAPI application."""

from __future__ import annotations

from dataclasses import replace
import inspect
import unittest
from typing import Any
from unittest.mock import patch

from fastapi.testclient import TestClient

import app as app_module
from api_auth import require_authenticated_context
from config import _cors_allow_origins
from request_context import RequestContext
import repositories.vault as vault_repository_module
import vault_routes
from vault_routes import _repository


USER_ID = "11111111-1111-4111-8111-111111111111"
SESSION_ID = "22222222-2222-4222-8222-222222222222"


class _Vault:
    def __init__(self) -> None:
        self.calls: list[tuple[str, Any]] = []

    def list_documents(self, limit: int, *, include_deleted: bool) -> list[dict[str, str]]:
        self.calls.append(("list_documents", (limit, include_deleted)))
        return [{"id": "vault-document-1"}]


class AppSecurityTests(unittest.TestCase):
    def _client(self, *, origins: tuple[str, ...] = ()) -> TestClient:
        configured = replace(app_module.settings, cors_allow_origins=origins)
        with patch.object(app_module, "settings", configured):
            application = app_module.create_app()
        return TestClient(application)

    def test_health_is_public_but_vault_requires_a_verified_context(self) -> None:
        client = self._client()

        self.assertEqual(client.get("/health").status_code, 200)
        denied = client.get("/vault/documents")
        self.assertEqual(denied.status_code, 401)
        self.assertEqual(denied.json()["detail"]["code"], "credentials_missing")

    def test_authenticated_vault_route_uses_the_request_scoped_repository_contract(self) -> None:
        client = self._client()
        vault = _Vault()
        context = RequestContext(user_id=USER_ID, auth_session_id=SESSION_ID)
        client.app.dependency_overrides[require_authenticated_context] = lambda: context
        client.app.dependency_overrides[_repository] = lambda: vault

        response = client.get("/vault/documents?limit=7")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), [{"id": "vault-document-1"}])
        self.assertEqual(vault.calls, [("list_documents", (7, False))])

    def test_cors_accepts_only_configured_exact_origins_and_preflight_stays_offline(self) -> None:
        client = self._client(origins=("https://extension.example",))
        headers = {
            "Origin": "https://extension.example",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "Authorization",
        }

        allowed = client.options("/vault/documents", headers=headers)
        self.assertEqual(allowed.status_code, 200)
        self.assertEqual(allowed.headers["access-control-allow-origin"], "https://extension.example")
        self.assertNotIn("*", allowed.headers["access-control-allow-origin"])

        denied = client.options(
            "/vault/documents",
            headers={**headers, "Origin": "https://untrusted.example"},
        )
        self.assertNotIn("access-control-allow-origin", denied.headers)

    def test_cors_configuration_rejects_wildcards_and_non_origins(self) -> None:
        for value in ("*", "https://extension.example/path", "file:///tmp/extension"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _cors_allow_origins(value)

    def test_legacy_root_and_document_routes_are_not_mounted(self) -> None:
        client = self._client()
        legacy_requests = (
            ("get", "/context"),
            ("post", "/context/seed"),
            ("post", "/memory/apply"),
            ("post", "/plan"),
            ("get", "/documents"),
            ("post", "/documents/upload"),
            ("get", "/activity"),
        )

        for method, path in legacy_requests:
            with self.subTest(path=path):
                self.assertEqual(getattr(client, method)(path).status_code, 404)

    def test_active_vault_surface_cannot_access_the_legacy_documents_bucket(self) -> None:
        repository_source = inspect.getsource(vault_routes)
        app_source = inspect.getsource(app_module)

        self.assertNotIn("from vault import", app_source)
        self.assertNotIn(".storage", repository_source)
        self.assertNotIn('"documents"', repository_source)
        self.assertIn('"vault_documents"', inspect.getsource(vault_repository_module))


if __name__ == "__main__":
    unittest.main(verbosity=2)
