"""Typed client for Alterity's Swara control-plane contract.

Alterity owns identity, tenancy, entitlements, billing, model routing, and the
shared knowledge-base catalogue. Swara consumes those capabilities through one
server-side endpoint instead of reading or mutating Alterity tables directly.

The extension's user JWT is forwarded only for ``bootstrap``. Metering uses a
separate server credential, and every mutation carries an idempotency key.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Literal, Protocol
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from pydantic import Field

from schemas import Base


PRODUCT_KEY = "swara"


class AlterityBridgeError(RuntimeError):
    """Base error for failures at the Alterity control-plane boundary."""


class AlterityBridgeUnavailable(AlterityBridgeError):
    """The configured control-plane endpoint could not be reached."""


class AlterityBridgeRejected(AlterityBridgeError):
    """Alterity rejected an authenticated or metered operation."""

    def __init__(self, message: str, *, status_code: int) -> None:
        super().__init__(message)
        self.status_code = status_code


class PlatformPrincipal(Base):
    user_id: str
    email: str
    name: str
    role: str


class PlatformTenant(Base):
    client_id: str
    business_name: str
    currency: str = "INR"
    sub_client_ids: list[str] = Field(default_factory=list)


class ProductEntitlement(Base):
    product: Literal["swara"] = PRODUCT_KEY
    enabled: bool
    plan: str
    capabilities: list[str] = Field(default_factory=list)
    limits: dict[str, int | float | bool | str] = Field(default_factory=dict)
    valid_until: datetime | None = None


class WalletSnapshot(Base):
    balance: float
    currency: str = "INR"
    low_balance: bool = False


class KnowledgeBaseReference(Base):
    id: str
    name: str
    status: str


class RuntimeRouting(Base):
    stt: list[str] = Field(default_factory=list)
    tts: list[str] = Field(default_factory=list)
    llm: list[str] = Field(default_factory=list)
    config: dict[str, Any] = Field(default_factory=dict)


class PlatformBootstrap(Base):
    principal: PlatformPrincipal
    tenant: PlatformTenant
    entitlement: ProductEntitlement
    wallet: WalletSnapshot
    knowledge_bases: list[KnowledgeBaseReference] = Field(default_factory=list)
    runtime: RuntimeRouting = Field(default_factory=RuntimeRouting)
    lease_expires_at: datetime


UsageMeter = Literal[
    "browser_session",
    "browser_step",
    "voice_second",
    "llm_input_token",
    "llm_output_token",
    "ocr_page",
]


class UsageReservation(Base):
    event_id: str
    session_id: str
    client_id: str
    meter: UsageMeter
    quantity: float = Field(gt=0)
    sub_client_id: str | None = None
    attributes: dict[str, str | int | float | bool] = Field(default_factory=dict)


class UsageCommit(Base):
    event_id: str
    reservation_id: str
    actual_quantity: float = Field(gt=0)
    attributes: dict[str, str | int | float | bool] = Field(default_factory=dict)


class UsageRelease(Base):
    event_id: str
    reservation_id: str
    reason: str


class UsageReceipt(Base):
    event_id: str
    reservation_id: str
    state: Literal["reserved", "committed", "released"]
    billable_quantity: float
    currency: str
    amount: float | None = None
    duplicate: bool = False


class JsonTransport(Protocol):
    def request(
        self,
        *,
        url: str,
        method: str,
        headers: dict[str, str],
        payload: dict[str, Any],
        timeout_seconds: float,
    ) -> tuple[int, dict[str, Any]]: ...


class UrllibJsonTransport:
    """Small stdlib transport so the bridge adds no runtime dependency."""

    def request(
        self,
        *,
        url: str,
        method: str,
        headers: dict[str, str],
        payload: dict[str, Any],
        timeout_seconds: float,
    ) -> tuple[int, dict[str, Any]]:
        request = Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method=method,
        )
        try:
            with urlopen(request, timeout=timeout_seconds) as response:
                raw = response.read()
                body = json.loads(raw) if raw else {}
                return response.status, body
        except HTTPError as exc:
            raw = exc.read()
            try:
                body = json.loads(raw) if raw else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                body = {"error": "Alterity rejected the request"}
            return exc.code, body
        except (URLError, TimeoutError, OSError) as exc:
            raise AlterityBridgeUnavailable(
                "Alterity control plane is temporarily unavailable"
            ) from exc


@dataclass(frozen=True)
class AlterityBridgeClient:
    endpoint: str
    service_token: str | None = None
    product_key: str = PRODUCT_KEY
    timeout_seconds: float = 5.0
    transport: JsonTransport = UrllibJsonTransport()

    def __post_init__(self) -> None:
        if not self.endpoint.strip():
            raise ValueError("Alterity control-plane endpoint is required")

    def bootstrap(self, user_access_token: str) -> PlatformBootstrap:
        if not user_access_token.strip():
            raise AlterityBridgeRejected("A user access token is required", status_code=401)
        body = self._request(
            action="bootstrap",
            token=user_access_token,
            payload={},
        )
        return PlatformBootstrap.model_validate(body)

    def reserve_usage(
        self,
        reservation: UsageReservation,
        *,
        idempotency_key: str,
    ) -> UsageReceipt:
        return self._meter(
            "reserve_usage",
            reservation.model_dump(mode="json", by_alias=True),
            idempotency_key,
        )

    def commit_usage(
        self,
        commit: UsageCommit,
        *,
        idempotency_key: str,
    ) -> UsageReceipt:
        return self._meter(
            "commit_usage",
            commit.model_dump(mode="json", by_alias=True),
            idempotency_key,
        )

    def release_usage(
        self,
        release: UsageRelease,
        *,
        idempotency_key: str,
    ) -> UsageReceipt:
        return self._meter(
            "release_usage",
            release.model_dump(mode="json", by_alias=True),
            idempotency_key,
        )

    def _meter(
        self,
        action: str,
        payload: dict[str, Any],
        idempotency_key: str,
    ) -> UsageReceipt:
        if not self.service_token:
            raise AlterityBridgeUnavailable(
                "ALTERITY_SWARA_SERVICE_TOKEN is required for metering"
            )
        if not idempotency_key or len(idempotency_key) > 160:
            raise ValueError("idempotency_key must be between 1 and 160 characters")
        body = self._request(
            action=action,
            token=self.service_token,
            payload=payload,
            idempotency_key=idempotency_key,
        )
        return UsageReceipt.model_validate(body)

    def _request(
        self,
        *,
        action: str,
        token: str,
        payload: dict[str, Any],
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "X-Alterity-Product": self.product_key,
        }
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key

        status, body = self.transport.request(
            url=self.endpoint,
            method="POST",
            headers=headers,
            payload={"action": action, "product": self.product_key, **payload},
            timeout_seconds=self.timeout_seconds,
        )
        # Supabase endpoints can legitimately return any 2xx status. Do not
        # hard-code 200/201 (the OAuth token response changed in June 2026).
        if not 200 <= status < 300:
            message = body.get("error") or body.get("message") or "Alterity rejected the request"
            raise AlterityBridgeRejected(str(message), status_code=status)
        return body
