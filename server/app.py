"""FastAPI entry point for Swara's authenticated server surface."""

from __future__ import annotations

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from config import settings
from api_auth import authenticated_websocket, require_authenticated_context
from pipecat_session import pipecat_session
from platform_routes import router as platform_router
from session import live_session
from vault_routes import router as vault_router
from voice import router as voice_router


def create_app() -> FastAPI:
    """Create an app with no public data APIs or wildcard browser access."""

    application = FastAPI(title="Swara server", docs_url=None, redoc_url=None, openapi_url=None)
    application.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_allow_origins),
        allow_credentials=True,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type", "X-Correlation-Id", "X-Swara-Device-Id"],
    )

    @application.exception_handler(RuntimeError)
    async def runtime_error_handler(_, exc: RuntimeError) -> JSONResponse:
        """Surface missing configuration cleanly instead of an opaque 500 body."""
        return JSONResponse(status_code=503, content={"detail": str(exc)})

    @application.get("/health")
    def health() -> dict[str, bool | str]:
        return {
            "status": "ok",
            "supabase": bool(settings.supabase_url and settings.supabase_publishable_key),
            "sarvam": bool(settings.sarvam_api_key),
            "gemini": bool(settings.google_api_key),
            "alterity": bool(settings.alterity_control_plane_url),
        }

    application.include_router(vault_router)
    application.include_router(platform_router, dependencies=[Depends(require_authenticated_context)])
    application.include_router(voice_router, dependencies=[Depends(require_authenticated_context)])
    application.add_api_websocket_route("/session/live", authenticated_websocket(live_session))
    application.add_api_websocket_route("/session/pipecat", authenticated_websocket(pipecat_session))
    return application


app = create_app()
