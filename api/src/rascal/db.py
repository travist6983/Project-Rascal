"""Engine, session factory, and the request-scoped session dependency."""

from __future__ import annotations

from collections.abc import AsyncIterator
from functools import lru_cache

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from rascal.config import get_database_settings


@lru_cache(maxsize=1)
def get_engine() -> AsyncEngine:
    # The engine needs a URL, not the whole configuration surface. That is what lets the
    # seed job run in a context that has a database and no S3 credentials.
    return create_async_engine(
        get_database_settings().database_url,
        pool_pre_ping=True,
        # Neon closes idle connections; recycling well inside that window avoids a cold 500.
        pool_recycle=1800,
        # **A database error must not print what it was writing.** SQLAlchemy's default renders
        # the failing statement *and its bound parameters* into `str(exc)`, so any handler that
        # logs a traceback publishes the row it was trying to save. That became a real leak in
        # phase 127, which added `credentials.apple_refresh_token` — a live Apple credential, and
        # the only secret at rest in this schema: a dropped connection mid-flush would have put
        # it in a log line, verbatim, under a message saying it had *not* been stored.
        #
        # Set here rather than only at that one call site, because this protects every statement
        # that binds the column including ones nobody has written yet — the same reasoning
        # `CredentialOut` uses for being an allowlist rather than an exclusion. The cost is that
        # `[parameters: ...]` disappears from every SQLAlchemy error in the service; nothing sets
        # `echo=`, so nothing was relying on it, and a statement worth seeing can be logged
        # deliberately.
        hide_parameters=True,
        future=True,
    )


@lru_cache(maxsize=1)
def get_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(
        bind=get_engine(),
        expire_on_commit=False,
        autoflush=False,
    )


async def get_session() -> AsyncIterator[AsyncSession]:
    """One session and one transaction per request; committed only if the handler returns."""
    async with get_sessionmaker()() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
