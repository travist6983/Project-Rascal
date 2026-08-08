"""Application settings, read once from the environment at import time."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# api/src/rascal/config.py -> api/src/rascal -> api/src -> api -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


class DatabaseSettings(BaseSettings):
    """Just enough configuration to open a connection, and nothing else.

    Alembic and the seed job are not the API. A migration needs a database; it does not need
    an S3 bucket, AWS credentials, or an Apple bundle id. Requiring those would mean any
    context that only migrates — the pre-flight workflow against Neon, a restore drill, a
    one-off shell — has to invent five values it will never use, and inventing them is how a
    real misconfiguration gets papered over. `Settings` extends this, so the connection
    fields are still declared exactly once.
    """

    model_config = SettingsConfigDict(
        env_file=REPO_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    database_url: str
    # Optional second connection string, used only by Alembic. Neon's pooled endpoint is
    # PgBouncer in transaction mode, which does not support the session-level machinery a
    # migration needs — advisory locks, prepared statements, some DDL. The app wants the
    # pooler; migrations want the direct endpoint. Unset locally, where there is no pooler.
    direct_database_url: str | None = None

    @property
    def sync_database_url(self) -> str:
        """What Alembic connects with. psycopg3 drives both sync and async off one scheme.

        Prefers `DIRECT_DATABASE_URL` when set, because a migration run through a
        transaction-mode pooler fails in ways that read like anything but the real cause.
        """
        return self.direct_database_url or self.database_url


class Settings(DatabaseSettings):
    """Every knob the service has. Missing required keys fail loudly at startup."""

    environment: Literal["local", "prod"] = "local"

    jwt_secret: str

    s3_bucket: str
    s3_region: str
    aws_access_key_id: str
    aws_secret_access_key: str

    # Any S3-compatible endpoint. RASCAL stores media on Tigris, which speaks S3 but is not
    # AWS, so the client has to be pointed at it explicitly — the credential names stay
    # AWS-shaped because that is the protocol's convention, not because Amazon is involved.
    # `None` means real AWS, which is exactly how this behaved before Tigris, so an existing
    # deployment that never sets it is unaffected. See docs/tigris-setup.md.
    s3_endpoint_url: str | None = None

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

    @field_validator("s3_endpoint_url", mode="after")
    @classmethod
    def _blank_endpoint_is_unset(cls, value: str | None) -> str | None:
        """`S3_ENDPOINT_URL=` means AWS, not an endpoint named empty string.

        A blank value is what a half-filled `.env` or an unset CI secret produces, and boto3
        given `""` fails in a way that names neither. Treating it as unset is the only reading
        that is ever useful.
        """
        return value.strip() or None if value else None

    @property
    def is_local(self) -> bool:
        """Gates dev-login and the /debug routes. Nothing else may branch on environment."""
        return self.environment == "local"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]


@lru_cache(maxsize=1)
def get_database_settings() -> DatabaseSettings:
    """For the connection alone. The app itself always goes through `get_settings`, so a
    missing `JWT_SECRET` still fails at startup rather than at the first request."""
    return DatabaseSettings()  # type: ignore[call-arg]
