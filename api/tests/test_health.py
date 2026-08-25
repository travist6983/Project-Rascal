"""`GET /health` and `GET /health/db` — the two unauthenticated routes outside auth.

The split is a cost decision with a durability edge to it, and the load-bearing test here is
`test_health_issues_no_database_queries`: Fly polls `/health` every 30 seconds against a
machine that is always up, so a single query in that handler is enough to hold a Neon compute
awake for the entire month. A test that asserted only on the response body would pass against
a handler that queried and threw the answer away, which is exactly the regression this file
exists to prevent — so it counts cursor executions on the engine the app is bound to.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Iterator

import pytest
import sqlalchemy as sa
from fastapi import FastAPI
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from rascal import db as db_module


@pytest.fixture
def statements(engine: AsyncEngine) -> Iterator[list[str]]:
    """Every SQL statement the app executes, in order, on both engines it could use.

    `before_cursor_execute` fires on the DBAPI cursor, so it sees the work no matter which
    layer asked for it — a handler, a dependency, a lazy load. It does **not** see a
    `pool_pre_ping`, which SQLAlchemy issues through `dialect.do_ping` on the raw connection;
    that is a gap in this instrument and it is named rather than papered over. It does not
    matter for what this asserts: a route with no session dependency checks no connection out,
    so there is nothing to pre-ping.

    Listening on the app's own `rascal.db.get_engine()` as well as the test engine is the other
    half. The `app` fixture overrides `get_session`, so a handler that reached past the
    dependency and used the module-level engine directly would be invisible to a listener bound
    only to the fixture's engine — and would pass this test while querying on every probe.
    """
    seen: list[str] = []

    def record(conn, cursor, statement, parameters, context, executemany) -> None:
        seen.append(statement)

    engines = [engine.sync_engine, db_module.get_engine().sync_engine]
    for target in engines:
        sa.event.listen(target, "before_cursor_execute", record)
    yield seen
    for target in engines:
        sa.event.remove(target, "before_cursor_execute", record)


async def test_health_reports_the_process_is_up(client: AsyncClient) -> None:
    response = await client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_health_issues_no_database_queries(
    client: AsyncClient, statements: list[str]
) -> None:
    """The whole point of the phase. See this module's docstring."""
    response = await client.get("/health")

    assert response.status_code == 200
    assert statements == []


async def test_the_statement_counter_sees_a_route_that_does_query(
    client: AsyncClient, statements: list[str]
) -> None:
    """The control for the test above.

    A listener attached to the wrong engine records nothing and makes the zero-query
    assertion pass for the wrong reason. This proves the instrument is live by pointing it at
    a route that is *supposed* to query.
    """
    response = await client.get("/health/db")

    assert response.status_code == 200
    assert [s for s in statements if "SELECT 1" in s]


async def test_health_db_reports_the_database_is_reachable(client: AsyncClient) -> None:
    response = await client.get("/health/db")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "db": "ok"}


async def test_health_db_fails_loudly_when_the_database_is_unreachable(
    app: FastAPI, client: AsyncClient
) -> None:
    """Non-200, and a body that names the failure.

    Not 200-with-a-degraded-body: `deploy.yml` compares the success body byte-for-byte
    precisely because a probe that reports its own failure with a 200 is a probe a poller
    accepts.
    """
    unreachable = sa.engine.make_url(os.environ["DATABASE_URL"]).set(port=1)
    dead = create_async_engine(unreachable, poolclass=sa.pool.NullPool)
    factory = async_sessionmaker(bind=dead, expire_on_commit=False, autoflush=False)

    async def _override() -> AsyncIterator[AsyncSession]:
        async with factory() as s:
            yield s

    app.dependency_overrides[db_module.get_session] = _override
    try:
        response = await client.get("/health/db")
    finally:
        await dead.dispose()

    assert response.status_code == 503
    assert response.json() == {
        "error": {
            "code": "database_unreachable",
            "message": "The database could not be reached.",
            "field": None,
        }
    }


async def test_neither_health_route_needs_a_bearer_token(client: AsyncClient) -> None:
    # No Authorization header at all, and still a 200 — Fly's health check has no
    # credentials, and neither does a smoke run from a phone.
    assert (await client.get("/health")).status_code == 200
    assert (await client.get("/health/db")).status_code == 200


async def test_unknown_route_uses_the_standard_error_shape(client: AsyncClient) -> None:
    response = await client.get("/nope")

    assert response.status_code == 404
    assert response.json() == {
        "error": {"code": "not_found", "message": "Not Found", "field": None}
    }
