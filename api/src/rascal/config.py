"""Application settings, read once from the environment at import time."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

# api/src/rascal/config.py -> api/src/rascal -> api/src -> api -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    """Every knob the service has. Missing required keys fail loudly at startup."""

    model_config = SettingsConfigDict(
        env_file=REPO_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    environment: Literal["local", "prod"] = "local"

    database_url: str
    jwt_secret: str

    s3_bucket: str
    s3_region: str
    aws_access_key_id: str
    aws_secret_access_key: str

    apple_bundle_id: str

    # Token lifetimes. Fixed by docs/api-contract.md; here so tests can reason about them.
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_days: int = 30

    # Apple's JWKS is stable for hours; a per-request fetch would be a self-inflicted outage.
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    apple_issuer: str = "https://appleid.apple.com"
    apple_jwks_cache_seconds: int = 3600

    # Anything at or under this goes out as a single presigned PUT; above it, multipart.
    multipart_threshold_bytes: int = 15 * 1024 * 1024
    multipart_chunk_bytes: int = 8 * 1024 * 1024
    presign_ttl_seconds: int = 3600

    assignment_expiry_days: int = 14

    @property
    def is_local(self) -> bool:
        """Gates dev-login and the /debug routes. Nothing else may branch on environment."""
        return self.environment == "local"

    @property
    def sync_database_url(self) -> str:
        """The same URL for Alembic. psycopg3 drives both sync and async off one scheme."""
        return self.database_url


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
