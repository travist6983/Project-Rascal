"""Test fixtures.

Every test runs against a real Postgres — the schema is full of CHECK constraints, partial
indexes, functional indexes, and a trigger, and SQLite would verify none of it. The suite
owns a separate database (``<dbname>_test``), builds it once per session by running the
real migrations, and truncates between tests.
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import pytest
import sqlalchemy as sa
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

API_DIR = Path(__file__).resolve().parents[1]


os.environ.setdefault("ENVIRONMENT", "local")

from rascal import db as db_module  # noqa: E402
from rascal.config import get_database_settings, get_settings  # noqa: E402


def _install_test_database_url() -> None:
    """Point everything at ``<dbname>_test`` so a dev database is never dropped.

    Read through Settings first so the repo-root ``.env`` is honoured — that way ``pytest``
    works the same whether it was launched by ``make test`` or by hand. The result goes into
    the environment because alembic runs in a subprocess and has to see it too.
    """
    configured = sa.engine.make_url(get_settings().database_url)
    test_url = configured.set(database=f"{configured.database}_test")
    os.environ["DATABASE_URL"] = test_url.render_as_string(hide_password=False)
    # Environment beats .env, so the next read of either is the test URL.
    get_settings.cache_clear()
    get_database_settings.cache_clear()


_install_test_database_url()

from rascal.main import create_app  # noqa: E402
from rascal.models import Base  # noqa: E402


def _admin_url() -> str:
    """A sync URL against the ``postgres`` database, for CREATE/DROP DATABASE."""
    url = sa.engine.make_url(os.environ["DATABASE_URL"])
    return url.set(database="postgres").render_as_string(hide_password=False)


@pytest.fixture(scope="session", autouse=True)
def database() -> Iterator[None]:
    """Drop, recreate, and migrate the test database once per session."""
    target = sa.engine.make_url(os.environ["DATABASE_URL"]).database
    admin = sa.create_engine(_admin_url(), isolation_level="AUTOCOMMIT", future=True)
    with admin.connect() as conn:
        conn.execute(
            sa.text(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = :name AND pid <> pg_backend_pid()"
            ),
            {"name": target},
        )
        conn.execute(sa.text(f'DROP DATABASE IF EXISTS "{target}"'))
        conn.execute(sa.text(f'CREATE DATABASE "{target}"'))
    admin.dispose()

    subprocess.run(
        ["alembic", "upgrade", "head"],
        cwd=API_DIR,
        check=True,
        env={**os.environ},
        capture_output=True,
    )
    yield


@pytest.fixture(autouse=True)
def _truncate() -> Iterator[None]:
    """Empty every table before each test.

    Cleaning up front rather than after means a failing test leaves its rows behind to be
    inspected, and no test can be made to pass by a neighbour's leftovers.
    """
    sync = sa.create_engine(os.environ["DATABASE_URL"], future=True)
    tables = ", ".join(f'"{t.name}"' for t in reversed(Base.metadata.sorted_tables))
    if tables:
        with sync.begin() as conn:
            conn.execute(sa.text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    sync.dispose()
    yield


@pytest.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    """A fresh engine per test, bound to that test's event loop, then disposed.

    NullPool because pytest-asyncio gives every test its own loop, and a pooled connection
    opened on a loop that has since closed is a hang waiting to happen.
    """
    eng = create_async_engine(os.environ["DATABASE_URL"], poolclass=sa.pool.NullPool)
    yield eng
    await eng.dispose()


@pytest.fixture
async def session(engine) -> AsyncIterator[AsyncSession]:
    """A session for arranging fixtures and asserting on rows directly."""
    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)
    async with factory() as s:
        yield s


@pytest.fixture
async def app(engine: AsyncEngine) -> FastAPI:
    """The real application, with the request session bound to the test engine."""
    application = create_app(get_settings())
    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)

    async def _override() -> AsyncIterator[AsyncSession]:
        async with factory() as s:
            try:
                yield s
                await s.commit()
            except Exception:
                await s.rollback()
                raise

    application.dependency_overrides[db_module.get_session] = _override
    return application


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[AsyncClient]:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
