"""Offline contract tests for the request-scoped Supabase client factories."""

from __future__ import annotations

import base64
import json
import unittest
from typing import Any
from unittest.mock import Mock

from server.supabase_clients import service_client, user_client


def _jwt_with_role(role: str) -> str:
    """Build an unsigned JWT-shaped value for local role-validation tests."""

    def encoded(value: dict[str, str]) -> str:
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    return f"{encoded({'alg': 'none'})}.{encoded({'role': role})}.signature"


class SupabaseClientFactoryTests(unittest.TestCase):
    url = "https://swara.example.supabase.co/"
    publishable_key = "sb_publishable_test_only"
    secret_key = "sb_secret_test_only"
    access_token = _jwt_with_role("authenticated")

    def _injected_factories(self) -> tuple[Mock, Mock]:
        return Mock(return_value=object()), Mock(return_value=object())

    def test_user_client_injects_request_authorization_without_persistence(self) -> None:
        factory, options_factory = self._injected_factories()

        client = user_client(
            self.url,
            self.publishable_key,
            self.access_token,
            factory=factory,
            options_factory=options_factory,
        )

        options_factory.assert_called_once_with(
            headers={"Authorization": f"Bearer {self.access_token}"},
            persist_session=False,
            auto_refresh_token=False,
        )
        factory.assert_called_once_with(
            "https://swara.example.supabase.co",
            self.publishable_key,
            options=options_factory.return_value,
        )
        self.assertIs(client, factory.return_value)

    def test_service_client_uses_no_authorization_header_or_session_persistence(self) -> None:
        factory, options_factory = self._injected_factories()

        client = service_client(
            self.url,
            self.secret_key,
            factory=factory,
            options_factory=options_factory,
        )

        options_factory.assert_called_once_with(persist_session=False, auto_refresh_token=False)
        factory.assert_called_once_with(
            "https://swara.example.supabase.co",
            self.secret_key,
            options=options_factory.return_value,
        )
        self.assertIs(client, factory.return_value)

    def test_each_user_call_creates_a_new_client_and_options_object(self) -> None:
        first_client, second_client = object(), object()
        first_options, second_options = object(), object()
        factory = Mock(side_effect=[first_client, second_client])
        options_factory = Mock(side_effect=[first_options, second_options])

        first = user_client(
            self.url,
            self.publishable_key,
            self.access_token,
            factory=factory,
            options_factory=options_factory,
        )
        second = user_client(
            self.url,
            self.publishable_key,
            self.access_token,
            factory=factory,
            options_factory=options_factory,
        )

        self.assertIs(first, first_client)
        self.assertIs(second, second_client)
        self.assertIsNot(first, second)
        self.assertEqual(options_factory.call_count, 2)
        self.assertEqual(factory.call_count, 2)
        self.assertIs(factory.call_args_list[0].kwargs["options"], first_options)
        self.assertIs(factory.call_args_list[1].kwargs["options"], second_options)

    def test_partial_factory_injection_keeps_the_explicit_factory(self) -> None:
        factory = Mock(return_value=object())
        options_factory = Mock(return_value=object())

        client = user_client(
            self.url,
            self.publishable_key,
            self.access_token,
            factory=factory,
            options_factory=options_factory,
        )

        self.assertIs(client, factory.return_value)
        self.assertEqual(factory.call_count, 1)
        self.assertEqual(options_factory.call_count, 1)

    def test_publishable_key_rejects_service_or_secret_keys_without_leaking_them(self) -> None:
        rejected_keys = (self.secret_key, "service_role_key", _jwt_with_role("service_role"))

        for key in rejected_keys:
            with self.subTest(key_kind=key.split(".")[0]), self.assertRaises(ValueError) as raised:
                user_client(
                    self.url,
                    key,
                    self.access_token,
                    factory=Mock(),
                    options_factory=Mock(),
                )
            self.assertNotIn(key, str(raised.exception))

    def test_secret_key_rejects_publishable_public_and_anon_keys_without_leaking_them(self) -> None:
        rejected_keys = (
            self.publishable_key,
            "sbp_test_only",
            "anon_test_only",
            "public_test_only",
            _jwt_with_role("anon"),
            _jwt_with_role("authenticated"),
        )

        for key in rejected_keys:
            with self.subTest(key_kind=key.split(".")[0]), self.assertRaises(ValueError) as raised:
                service_client(
                    self.url,
                    key,
                    factory=Mock(),
                    options_factory=Mock(),
                )
            self.assertNotIn(key, str(raised.exception))

    def test_user_client_rejects_a_service_role_access_token(self) -> None:
        service_token = _jwt_with_role("service_role")

        with self.assertRaises(ValueError) as raised:
            user_client(
                self.url,
                self.publishable_key,
                service_token,
                factory=Mock(),
                options_factory=Mock(),
            )

        self.assertNotIn(service_token, str(raised.exception))

    def test_invalid_urls_are_rejected_before_dependencies_are_called(self) -> None:
        invalid_urls = ("", "  ", "swara.example.supabase.co", "ftp://swara.example.supabase.co", "https:///missing-host")

        for url in invalid_urls:
            for create in (user_client, service_client):
                with self.subTest(url=url, factory=create.__name__):
                    factory = Mock()
                    options_factory = Mock()
                    args: tuple[Any, ...] = (
                        (url, self.publishable_key, self.access_token)
                        if create is user_client
                        else (url, self.secret_key)
                    )
                    with self.assertRaises(ValueError):
                        create(*args, factory=factory, options_factory=options_factory)
                    factory.assert_not_called()
                    options_factory.assert_not_called()

    def test_invalid_credentials_are_rejected_before_factory_or_options_creation(self) -> None:
        factory = Mock()
        options_factory = Mock()

        with self.assertRaises(ValueError):
            user_client(
                self.url,
                self.publishable_key,
                " ",
                factory=factory,
                options_factory=options_factory,
            )

        factory.assert_not_called()
        options_factory.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
