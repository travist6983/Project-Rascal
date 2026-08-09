"""`POST /v1/children/{id}/recompute-ages` — the escape hatch for a birthdate typo.

`entries.child_age_months` is computed at write and stored on purpose (docs/data-model.md),
so correcting a birthdate does not silently reshape an archive of 500 entries. The price of
that is that a typo is otherwise permanent. This route is the deliberate, user-invoked
correction.

Every expected age in this file is **hand-computed** and shown as arithmetic in a comment.
Asserting against a second call to `age_at_instant` would assert nothing at all.
"""

from __future__ import annotations

import datetime as dt
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.models import Child, Entry, User

# EDT is UTC-4 and EST is UTC-5, so a late-evening UTC instant lands on the previous local
# day. Every occurred_at below is chosen with that in mind.
TIMEZONE = "America/Detroit"
TYPO = dt.date(2021, 6, 1)


async def _world(session: AsyncSession, *, birthdate: dt.date = TYPO) -> tuple[User, Child]:
    parent = await make_user(session, display_name="The parent")
    child = await make_child(session, birthdate=birthdate, timezone=TIMEZONE)
    await grant(session, parent, child, "parent")
    return parent, child


async def _entry(
    session: AsyncSession,
    child: Child,
    author: User,
    occurred_at: dt.datetime,
    stored_age: int,
    *,
    deleted: bool = False,
) -> Entry:
    """An entry written straight through the ORM, with its stored age set by hand.

    Going through the ORM rather than `POST /entries` is what lets a test arrange the exact
    stale value a birthdate typo would have left behind.
    """
    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=author.id,
        occurred_at=occurred_at,
        child_age_months=stored_age,
        body="Something worth keeping.",
        entry_type="text",
        deleted_at=dt.datetime(2026, 8, 1, tzinfo=dt.UTC) if deleted else None,
    )
    session.add(entry)
    await session.flush()
    return entry


async def _correct_the_birthdate(session: AsyncSession, child: Child, to: dt.date) -> None:
    """The typo fix itself. Recompute is never a side effect of this — that is the point."""
    child.birthdate = to
    await session.flush()
    await session.commit()


async def _age(session: AsyncSession, entry: Entry) -> int:
    return await session.scalar(sa.select(Entry.child_age_months).where(Entry.id == entry.id))


async def _updated_at(session: AsyncSession, entry: Entry) -> dt.datetime:
    return await session.scalar(sa.select(Entry.updated_at).where(Entry.id == entry.id))


# --- The correction ----------------------------------------------------------------------


async def test_it_corrects_stored_ages_after_a_birthdate_fix(
    client: AsyncClient, session: AsyncSession
) -> None:
    parent, child = await _world(session)

    # 16:00Z in June is 12:00 EDT — local date 2022-06-01.
    # Under the typo 2021-06-01: (2022-2021)*12 + (6-6) = 12, day 1 >= 1, so 12.
    first = await _entry(session, child, parent, dt.datetime(2022, 6, 1, 16, tzinfo=dt.UTC), 12)
    # 12:00Z is 08:00 EDT — local date 2024-09-15.
    # Under the typo: (2024-2021)*12 + (9-6) = 39, day 15 >= 1, so 39.
    second = await _entry(session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    # 03:00Z on Oct 1 is 23:00 EDT on Sep 30 — local date 2024-09-30, not 2024-10-01.
    # Under the typo: (2024-2021)*12 + (9-6) = 39, day 30 >= 1, so 39.
    third = await _entry(session, child, parent, dt.datetime(2024, 10, 1, 3, tzinfo=dt.UTC), 39)
    await session.commit()

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    assert response.json() == {
        "child_id": str(child.id),
        "entries_updated": 3,
        "birthdate": "2021-05-01",
    }

    # Hand-computed against the corrected birthdate 2021-05-01:
    #   2022-06-01 → (2022-2021)*12 + (6-5) = 13, day 1 >= 1 → 13
    assert await _age(session, first) == 13
    #   2024-09-15 → (2024-2021)*12 + (9-5) = 40, day 15 >= 1 → 40
    assert await _age(session, second) == 40
    #   2024-09-30 → (2024-2021)*12 + (9-5) = 40, day 30 >= 1 → 40
    # If this were computed from the UTC date (2024-10-01) it would be 41. It is 40, so the
    # child's family_timezone is what decides the day.
    assert await _age(session, third) == 40


async def test_the_day_of_month_rule_survives_the_correction(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Whole months only: the 15th is not yet a month old against a birthdate on the 20th."""
    parent, child = await _world(session)
    # Both are local 2024-09-15 and 2024-09-25; under the typo 2021-06-01 both are
    # (2024-2021)*12 + (9-6) = 39.
    before_the_day = await _entry(
        session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39
    )
    after_the_day = await _entry(
        session, child, parent, dt.datetime(2024, 9, 25, 12, tzinfo=dt.UTC), 39
    )
    await session.commit()

    await _correct_the_birthdate(session, child, dt.date(2021, 6, 20))

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    # Against 2021-06-20: (2024-2021)*12 + (9-6) = 39, then day 15 < 20 takes one off → 38.
    assert await _age(session, before_the_day) == 38
    # Same 39, and day 25 >= 20 takes nothing off → 39, unchanged.
    assert await _age(session, after_the_day) == 39
    assert response.json()["entries_updated"] == 1


async def test_soft_deleted_entries_are_recomputed(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Nothing is deleted in this system. A restored entry must not carry a stale age."""
    parent, child = await _world(session)
    live = await _entry(session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    deleted = await _entry(
        session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39, deleted=True
    )
    await session.commit()

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    assert response.json()["entries_updated"] == 2
    # 2024-09-15 against 2021-05-01 → (2024-2021)*12 + (9-5) = 40, day 15 >= 1 → 40.
    assert await _age(session, live) == 40
    assert await _age(session, deleted) == 40
    # Still deleted. A correction is not a restore.
    assert (
        await session.scalar(sa.select(Entry.deleted_at).where(Entry.id == deleted.id))
    ) is not None


# --- What it must not touch --------------------------------------------------------------


async def test_unchanged_rows_do_not_get_a_bumped_updated_at(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The correction has to reach every client. The rest of the archive must not.

    `set_updated_at()` fires on every UPDATE, so writing a row back with the value it
    already had would push eighteen years of entries through the sync cursor on every
    invocation of this route.
    """
    parent, child = await _world(session)
    # Local 2024-09-15 against 2021-06-01 → (2024-2021)*12 + (9-6) = 39. Already right.
    correct = await _entry(session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    # Local 2022-06-01 against 2021-06-01 → 12. Stored as 7, so this one is wrong.
    stale = await _entry(session, child, parent, dt.datetime(2022, 6, 1, 16, tzinfo=dt.UTC), 7)
    await session.commit()

    correct_before = await _updated_at(session, correct)
    stale_before = await _updated_at(session, stale)

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    # Rows changed, not rows examined.
    assert response.json()["entries_updated"] == 1
    assert await _age(session, stale) == 12
    assert await _updated_at(session, stale) > stale_before
    assert await _age(session, correct) == 39
    assert await _updated_at(session, correct) == correct_before


async def test_a_second_call_changes_nothing(client: AsyncClient, session: AsyncSession) -> None:
    parent, child = await _world(session)
    entry = await _entry(session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    await session.commit()

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))

    first = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )
    assert first.json()["entries_updated"] == 1
    settled = await _updated_at(session, entry)

    second = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert second.status_code == 200
    assert second.json()["entries_updated"] == 0
    assert await _updated_at(session, entry) == settled
    assert await _age(session, entry) == 40


async def test_it_never_touches_occurred_at_or_created_at(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`occurred_at` is when it happened, `created_at` is when it was logged. Neither moves."""
    parent, child = await _world(session)
    occurred = dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC)
    entry = await _entry(session, child, parent, occurred, 39)
    await session.commit()
    created_before = await session.scalar(sa.select(Entry.created_at).where(Entry.id == entry.id))

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))
    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    after = (
        await session.execute(
            sa.select(Entry.occurred_at, Entry.created_at).where(Entry.id == entry.id)
        )
    ).one()
    assert after.occurred_at == occurred
    assert after.created_at == created_before


async def test_it_leaves_another_child_alone(client: AsyncClient, session: AsyncSession) -> None:
    parent, child = await _world(session)
    sibling = await make_child(session, name="Sibling", birthdate=TYPO, timezone=TIMEZONE)
    await grant(session, parent, sibling, "parent")
    mine = await _entry(session, child, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    theirs = await _entry(session, sibling, parent, dt.datetime(2024, 9, 15, 12, tzinfo=dt.UTC), 39)
    await session.commit()

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))
    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    assert response.json()["entries_updated"] == 1
    assert await _age(session, mine) == 40
    assert await _age(session, theirs) == 39


# --- Authorization -----------------------------------------------------------------------


async def test_a_viewer_cannot_recompute(client: AsyncClient, session: AsyncSession) -> None:
    """Read-only guardians read. Rewriting every age in the archive is the parent's."""
    parent, child = await _world(session)
    viewer = await make_user(session, display_name="Grandma")
    await grant(session, viewer, child, "viewer")
    entry = await _entry(session, child, parent, dt.datetime(2022, 6, 1, 16, tzinfo=dt.UTC), 7)
    await session.commit()

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(viewer)
    )

    assert response.status_code == 403
    # The precedent every other write route in this repo sets — see test_authorization.py.
    assert response.json()["error"]["code"] == "not_authorized"
    assert await _age(session, entry) == 7


async def test_a_guardian_of_another_child_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    parent, child = await _world(session)
    outsider, _ = await _world(session)
    entry = await _entry(session, child, parent, dt.datetime(2022, 6, 1, 16, tzinfo=dt.UTC), 7)
    await session.commit()

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(outsider)
    )

    # 403, not 404: the sweep in test_authorization_sweep.py establishes that a guardian of
    # nothing gets 403 on a child-scoped route, and leaking existence is fine here.
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "not_authorized"
    assert await _age(session, entry) == 7


async def test_it_requires_a_token(client: AsyncClient, session: AsyncSession) -> None:
    _, child = await _world(session)
    await session.commit()

    response = await client.post(f"/v1/children/{child.id}/recompute-ages")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


# --- The whole archive at once -----------------------------------------------------------


async def test_recompute_ages_500_entries(client: AsyncClient, session: AsyncSession) -> None:
    """500 entries across sixteen months, corrected in one call and one transaction.

    The correctness assertion does not call the production age function. It moves the
    birthdate back by exactly one calendar month, keeping the day of month — which shifts
    `(y2-y1)*12 + (m2-m1)` up by one and leaves the `day <` adjustment identical — so every
    single age must land at exactly its previous value plus one. Two rows are additionally
    pinned to values computed by hand.
    """
    parent, child = await _world(session)
    start = dt.datetime(2022, 1, 1, 15, tzinfo=dt.UTC)
    entries = [
        await _entry(session, child, parent, start + dt.timedelta(days=offset), 0)
        for offset in range(500)
    ]
    await session.commit()

    # Baseline: every stored age is 0, so the first call rewrites all 500 against the
    # birthdate they were written under.
    baseline_response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )
    assert baseline_response.status_code == 200
    assert baseline_response.json()["entries_updated"] == 500

    baseline = {
        row.id: row.child_age_months
        for row in (
            await session.execute(
                sa.select(Entry.id, Entry.child_age_months).where(Entry.child_id == child.id)
            )
        ).all()
    }
    # 15:00Z on 2022-01-01 is 10:00 EST — local date 2022-01-01.
    # Against 2021-06-01: (2022-2021)*12 + (1-6) = 7, day 1 >= 1 → 7.
    assert baseline[entries[0].id] == 7
    # 499 days after 2022-01-01 is 2023-05-15; 15:00Z is 11:00 EDT — local date 2023-05-15.
    # Against 2021-06-01: (2023-2021)*12 + (5-6) = 23, day 15 >= 1 → 23.
    assert baseline[entries[-1].id] == 23

    await _correct_the_birthdate(session, child, dt.date(2021, 5, 1))

    response = await client.post(
        f"/v1/children/{child.id}/recompute-ages", headers=auth_headers(parent)
    )

    assert response.status_code == 200
    assert response.json()["entries_updated"] == 500

    corrected = (
        await session.execute(
            sa.select(Entry.id, Entry.child_age_months).where(Entry.child_id == child.id)
        )
    ).all()
    assert len(corrected) == 500
    # A birthdate one whole month earlier makes every entry exactly one month older.
    assert all(row.child_age_months == baseline[row.id] + 1 for row in corrected)
    assert {row.id for row in corrected} == set(baseline)
    # The two hand-computed anchors, moved by the one month the birthdate moved.
    ages = {row.id: row.child_age_months for row in corrected}
    assert ages[entries[0].id] == 8
    assert ages[entries[-1].id] == 24

    # One transaction, not five hundred. Every row version written by the same transaction
    # carries that transaction's id in `xmin`, and `set_updated_at()` stamps `now()`, which
    # is transaction-*start* time — so a partial or chunked recompute would show up here as
    # more than one of either.
    row_versions = sa.text("SELECT count(DISTINCT xmin::text) FROM entries WHERE child_id = :child")
    versions = await session.scalar(row_versions.bindparams(child=child.id))
    assert versions == 1
    stamps = await session.scalar(
        sa.select(sa.func.count(sa.distinct(Entry.updated_at))).where(Entry.child_id == child.id)
    )
    assert stamps == 1
