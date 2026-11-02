"""HTTP surface for Swara's Alterity control-plane bootstrap."""

from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException

from alterity_bridge import (
    AlterityBridgeClient,
    AlterityBridgeRejected,
    PlatformBootstrap,
)
from config import settings


router = APIRouter(prefix="/platform", tags=["platform"])


def _bridge() -> AlterityBridgeClient:
    if not settings.alterity_control_plane_url:
        raise HTTPException(
            status_code=503,
            detail="Alterity control-plane integration is not configured",
        )
    return AlterityBridgeClient(
        endpoint=settings.alterity_control_plane_url,
        service_token=settings.alterity_swara_service_token,
        product_key=settings.swara_product_key,
    )


def _bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Bearer access token is required")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Bearer access token is required")
    return token


@router.get("/status")
def platform_status() -> dict[str, bool | str]:
    configured = bool(settings.alterity_control_plane_url)
    return {
        "mode": "alterity" if configured else "standalone",
        "configured": configured,
        "meteringConfigured": bool(settings.alterity_swara_service_token),
        "product": settings.swara_product_key,
    }


@router.post("/bootstrap", response_model=PlatformBootstrap)
def platform_bootstrap(
    authorization: str | None = Header(default=None),
) -> PlatformBootstrap:
    try:
        return _bridge().bootstrap(_bearer_token(authorization))
    except AlterityBridgeRejected as exc:
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
