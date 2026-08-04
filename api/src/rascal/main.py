"""The FastAPI application."""

from __future__ import annotations

from fastapi import Depends, FastAPI
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings, get_settings
from rascal.db import get_session
from rascal.errors import register_error_handlers
from rascal.logging_config import configure_logging


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging()

    app = FastAPI(
        title="RASCAL API",
        version="0.1.0",
        summary="A private archive of a childhood, built one prompt at a time.",
        description=(
            "Plain JSON over HTTPS. Bearer auth. All timestamps ISO 8601 UTC, all IDs UUID.\n\n"
            "Every route lives under `/v1` except `GET /health`."
        ),
    )

    register_error_handlers(app)

    @app.get(
        "/health",
        tags=["health"],
        summary="Liveness and database reachability",
        # Unauthenticated on purpose: Fly's health check hits this, and a green check has to
        # mean the app can actually serve, so it touches the database.
    )
    async def health(session: AsyncSession = Depends(get_session)) -> dict[str, str]:
        await session.execute(text("SELECT 1"))
        return {"status": "ok", "db": "ok"}

    return app


app = create_app()
