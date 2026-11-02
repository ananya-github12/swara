"""Configuration for the server.

Importing this module is deliberately safe without credentials.  Call
``require`` at the integration boundary that actually needs a credential.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

try:
    from dotenv import load_dotenv
except ImportError:  # Keep basic imports usable before dependencies are installed.
    def load_dotenv(*_: object, **__: object) -> bool:
        return False


ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)


@dataclass(frozen=True)
class Settings:
    sarvam_api_key: str | None
    google_api_key: str | None
    supabase_url: str | None
    supabase_publishable_key: str | None
    supabase_service_key: str | None
    alterity_control_plane_url: str | None
    alterity_swara_service_token: str | None
    swara_product_key: str
    cors_allow_origins: tuple[str, ...]

    def value_for(self, name: str) -> str | None:
        try:
            return {
                "SARVAM_API_KEY": self.sarvam_api_key,
                "GOOGLE_API_KEY": self.google_api_key,
                "SUPABASE_URL": self.supabase_url,
                "SUPABASE_PUBLISHABLE_KEY": self.supabase_publishable_key,
                "SUPABASE_SERVICE_KEY": self.supabase_service_key,
                "ALTERITY_CONTROL_PLANE_URL": self.alterity_control_plane_url,
                "ALTERITY_SWARA_SERVICE_TOKEN": self.alterity_swara_service_token,
            }[name]
        except KeyError as exc:
            raise ValueError(f"Unknown configuration key: {name}") from exc


def _cors_allow_origins(value: str | None) -> tuple[str, ...]:
    """Parse exact browser origins; an unset list deliberately allows none."""

    if not value:
        return ()
    origins = tuple(origin.strip() for origin in value.split(",") if origin.strip())
    for origin in origins:
        parsed = urlparse(origin)
        if (
            origin == "*"
            or parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.path
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("SWARA_CORS_ALLOW_ORIGINS must contain exact http(s) origins")
    return origins


settings = Settings(
    sarvam_api_key=os.getenv("SARVAM_API_KEY"),
    google_api_key=os.getenv("GOOGLE_API_KEY"),
    supabase_url=os.getenv("SUPABASE_URL"),
    supabase_publishable_key=os.getenv("SUPABASE_PUBLISHABLE_KEY"),
    supabase_service_key=os.getenv("SUPABASE_SERVICE_KEY"),
    alterity_control_plane_url=os.getenv("ALTERITY_CONTROL_PLANE_URL"),
    alterity_swara_service_token=os.getenv("ALTERITY_SWARA_SERVICE_TOKEN"),
    swara_product_key=os.getenv("SWARA_PRODUCT_KEY", "swara"),
    cors_allow_origins=_cors_allow_origins(os.getenv("SWARA_CORS_ALLOW_ORIGINS")),
)


def require(name: str) -> str:
    """Return a configured secret, or raise an actionable error when used."""
    value = settings.value_for(name)
    if not value:
        raise RuntimeError(
            f"Missing required configuration: {name}. "
            f"Set it in {ENV_FILE} or in the process environment."
        )
    return value
