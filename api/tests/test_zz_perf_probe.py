"""TEMPORARY query-count probe. Delete after review."""

from __future__ import annotations

import datetime as dt
from collections import Counter

import pytest
import sqlalchemy as sa
from sqlalchemy import event

from factories import make_child, make_family, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Guardian
from rascal.services.scheduler import run_scheduler


class Counted:
    def __init__(self) -> None:
        self.statements: list[str] = []

    @property
    def n(self) -> int:
        return len(self.statements)

    def summary(self) -> Counter:
        out = Counter()
        for s in self.statements:
            head = " ".join(s.split())[:90]
            out[head] += 1
        return out


def attach(engine) -> Counted:
    counted = Counted()
    sync_engine = engine.sync_engine

    def before(conn, cursor, statement, parameters, context, executemany):
        counted.statements.append(statement)

    event.listen(sync_engine, "before_cursor_execute", before)
    return counted


async def _seed_pool(session):
    for cadence, kinds in (
        ("daily", ["question", "photo", "video", "audio", "activity"]),
        ("weekly", ["photo", "activity"]),
        ("monthly", ["measurement", "letter"]),
    ):
        for kind in kinds:
            for i in range(6):
                await make_prompt(
                    session,
                    body=f"{cadence}-{kind}-{i} prompt body",
                    kind=kind,
                    cadence=cadence,
                )


@pytest.mark.asyncio
@pytest.mark.parametrize("n_children,n_parents", [(1, 1), (1, 2), (5, 2), (10, 2)])
async def test_scheduler_query_count(session, engine, n_children, n_parents):
    await _seed_pool(session)
    family = await make_family(session, tier="subscribed")
    parents = [
        await make_user(session, display_name=f"p{i}", family=family) for i in range(n_parents)
    ]
    for c in range(n_children):
        child = await make_child(session, name=f"kid{c}", parent=parents[0])
        for p in parents[1:]:
            session.add(Guardian(user_id=p.id, child_id=child.id, role="parent"))
    await session.commit()

    counted = attach(engine)
    run = await run_scheduler(session, as_of_date=dt.date(2026, 8, 18), seed=1)
    await session.commit()
    print(
        f"\n=== children={n_children} parents={n_parents}: "
        f"{counted.n} statements, created={run.created} ==="
    )
    for stmt, count in counted.summary().most_common(12):
        print(f"  {count:4d}  {stmt}")


@pytest.mark.asyncio
async def test_families_me_query_count(session, engine, client):
    family = await make_family(session, tier="subscribed")
    a = await make_user(session, display_name="A", family=family)
    b = await make_user(session, display_name="B", family=family)
    child = await make_child(session, name="kid", parent=a)
    session.add(Guardian(user_id=b.id, child_id=child.id, role="parent"))
    await session.commit()

    counted = attach(engine)
    resp = await client.get("/v1/families/me", headers=auth_headers(a))
    assert resp.status_code == 200, resp.text
    print(f"\n=== GET /families/me: {counted.n} statements ===")
    for stmt, count in counted.summary().most_common(20):
        print(f"  {count:4d}  {stmt}")


@pytest.mark.asyncio
async def test_guardians_child_id_plan(session, engine):
    """Is `_active_parents`'s predicate indexed?"""
    family = await make_family(session)
    a = await make_user(session, display_name="A", family=family)
    child = await make_child(session, name="kid", parent=a)
    await session.commit()
    rows = (
        await session.execute(
            sa.text(
                "EXPLAIN SELECT user_id FROM guardians WHERE child_id = :c "
                "AND revoked_at IS NULL AND role = 'parent' ORDER BY granted_at, user_id"
            ),
            {"c": child.id},
        )
    ).all()
    print("\n=== EXPLAIN _active_parents ===")
    for r in rows:
        print("  ", r[0])
    idx = (
        await session.execute(
            sa.text("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'guardians'")
        )
    ).all()
    print("=== guardians indexes ===")
    for r in idx:
        print("  ", r[0], "|", r[1])
