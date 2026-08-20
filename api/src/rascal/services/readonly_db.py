"""A second, read-only connection, so the console can look at production from a laptop.

**Why this exists rather than just repointing `DATABASE_URL`.** That variable is read by
everything: `make migrate`, `make seed`, `make test` — which does `DROP DATABASE IF EXISTS
"<db>_test"` and `CREATE DATABASE` — and `make reset-db`, which runs `alembic downgrade base`.
Aim `DATABASE_URL` at Neon and every one of those becomes a command that destroys the archive,
sitting in a Makefile, one tab-completion away. `dev-login` is the other half: `config.py`
already warns that a local API pointed at a real database would hand out an `is_admin` session
for a live account to whoever types the right domain.

So the console gets its own connection and nothing else in the service knows it exists. The
destructive targets keep talking to `localhost` because they never learned another address.

**Read-only by construction, not by discipline.** The connection sets
`default_transaction_read_only=on` at the server, so a write through this engine is refused by
Postgres itself with `cannot execute INSERT in a read-only transaction`. That holds even if the
credential is a full-access role, even if a future handler forgets which session it was handed,
and even if somebody wires a write route to it by mistake. A read-only *role* would be better
still and is what the setup note recommends; this is the belt that does not depend on it.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from functools import lru_cache
from urllib.parse import urlsplit

from sqlalchemy import event
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

log = logging.getLogger("rascal.readonly")

#: Named so a test can assert the guarantee rather than trust the comment above it.
READ_ONLY_STATEMENT = "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"


def normalise(url: str) -> str:
    """Accept the string Neon's console hands you, unchanged.

    Neon copies out `postgresql://…`; SQLAlchemy needs a driver, and without one it fails with
    a "can't load plugin" message that names neither the setting nor the fix. Pasting the
    connection string exactly as the provider gives it is the whole point of this being easy,
    so the scheme is rewritten here instead of in a note somebody has to read first.
    """
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://") :]
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://") :]
    return url


def describe(url: str) -> str:
    """The host, for the chip in the console's top bar. Never the credential.

    A console reading production must say so on every screen, and the sentence that does it
    cannot be the one that leaks the password into a browser's DOM.
    """
    try:
        host = urlsplit(normalise(url).replace("+psycopg", "")).hostname or "unknown"
    except ValueError:
        return "unknown"
    return host


@lru_cache(maxsize=4)
def get_engine(url: str) -> AsyncEngine:
    """One engine per distinct URL, built on first use and reused after.

    Cached because a console left open in a tab polls a handful of routes, and an engine per
    request would open a new pool against Neon every time. Keyed on the URL rather than
    `maxsize=1` so a settings change in a test does not hand back the previous target's pool.
    """
    engine = create_async_engine(
        normalise(url),
        pool_pre_ping=True,
        # Neon closes idle connections; the app's own engine recycles at the same interval.
        pool_recycle=1800,
        # Small, and deliberately so. This is one browser tab, and Neon's connection budget is
        # the scarce resource the production app is already competing for.
        pool_size=2,
        max_overflow=0,
        future=True,
    )

    @event.listens_for(engine.sync_engine, "connect")
    def _read_only(dbapi_connection: object, _record: object) -> None:
        """The guarantee, issued on every physical connection.

        `connect_args={"options": "-c default_transaction_read_only=on"}` does the same job and
        was the first attempt. It is invisible: it never appears in `create_connect_args`, so
        nothing can assert it is still there and a driver change could drop it in silence. An
        explicit statement on connect is the same protection somewhere a test can see it.

        Postgres now refuses every write on this connection — whatever the credential is
        allowed to do, and whatever a future handler wired to the wrong session asks for.
        """
        cursor = dbapi_connection.cursor()  # type: ignore[attr-defined]
        try:
            cursor.execute(READ_ONLY_STATEMENT)
        finally:
            cursor.close()

    return engine


@lru_cache(maxsize=4)
def get_sessionmaker(url: str) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(bind=get_engine(url), expire_on_commit=False, autoflush=False)


class Unreachable(Exception):
    """The configured database did not answer. Carries a sentence, never a connection string."""


async def session_for(url: str) -> AsyncIterator[AsyncSession]:
    """A session that is never committed, because there is nothing here to commit.

    A connection failure is turned into `Unreachable` rather than allowed to propagate.
    SQLAlchemy's `OperationalError` stringifies to the host, the port, every resolved IP and
    the failing username — which is a 500 body with most of a connection string in it, and the
    single likeliest thing to happen on the first paste of a URL.
    """
    try:
        maker = get_sessionmaker(url)
        async with maker() as session:
            try:
                yield session
            finally:
                # Rollback rather than commit, always. The transaction is read-only at the
                # server so a commit would be a no-op — but writing `commit()` here would be
                # the line a future reader copies into somewhere it matters.
                await session.rollback()
    except SQLAlchemyError as exc:
        raise Unreachable(reason(exc)) from None


def reason(exc: BaseException) -> str:
    """One clause about what went wrong, chosen from the driver's text without quoting it."""
    detail = str(exc).lower()
    if "password authentication failed" in detail or "authentication" in detail:
        return "the credentials were rejected"
    if "sslmode" in detail or "insecure" in detail:
        return "the server requires SSL — add ?sslmode=require to the URL"
    if "does not exist" in detail:
        return "that database or role does not exist"
    if "timeout" in detail or "timed out" in detail:
        return "it did not answer in time"
    return "the connection failed"


def reset() -> None:
    """Drop the cached engines. For tests, and for a settings change without a restart."""
    get_sessionmaker.cache_clear()
    get_engine.cache_clear()
