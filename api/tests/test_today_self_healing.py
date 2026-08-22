"""`GET /today` creates today's assignments if the scheduler never did.

The scheduler runs on a machine, and a machine can be stopped, restarting, or on the wrong
side of a Fly outage at 5am. When that happens the Today screen is simply empty, which reads
as a broken product rather than as a sleeping machine — and the day is not recoverable
afterwards, because tomorrow the scheduler will fill tomorrow.

So the read repairs it. These tests are the proof that it does, that it costs nothing when
there is nothing to repair, that two readers cannot race it into duplicates, and that it
uses the *child's* today rather than the server's.
"""

from __future__ import annotations

import asyncio
import datetime as dt

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Assignment, Child
from rascal.services.dates import local_date
from rascal.services.scheduler import ensure_day_filled, run_scheduler

# A Saturday that is neither the 1st nor the 15th, so `weekly` is tested on its own.
SATURDAY = dt.date(2026, 8, 22)  # future-date: explicit, pure
# The 1st, and a Tuesday, so `monthly` is tested without `weekly` riding along.
FIRST = dt.date(2026, 9, 1)  # future-date: explicit, pure
# A plain Wednesday: `question` + `mission` under phase 107's rotation, and nothing else.
# It was "the daily three" before the rotation; the date did not change, the day's shape did.
WEEKDAY = dt.date(2026, 8, 19)  # future-date: explicit, pure

# UTC+14 and UTC-11. At any instant at least one of them is on a different calendar date
# from UTC: before 11:00Z the Midway date is yesterday's, and from 10:00Z the Kiritimati
# date is tomorrow's. `_zone_that_differs_from_utc` picks whichever currently applies.
AHEAD = "Pacific/Kiritimati"
BEHIND = "Pacific/Midway"


def _zone_that_differs_from_utc(now: dt.datetime) -> tuple[str, dt.date]:
    """A timezone whose calendar date is *not* UTC's right now, and that date.

    Asserted rather than assumed: a test for "today comes from `family_timezone`" that
    silently ran in a zone agreeing with UTC would pass while proving nothing, and would go
    on passing for years.
    """
    for name in (BEHIND, AHEAD):
        local = local_date(now, name)
        if local != now.date():
            return name, local
    raise AssertionError(  # pragma: no cover - arithmetic above makes this unreachable
        f"neither {BEHIND} nor {AHEAD} differs from UTC at {now.isoformat()}"
    )


async def _pool(session: AsyncSession) -> None:
    """Enough of a library that every slot a day can ask for has a candidate."""
    await make_prompt(session, kind="question", cadence="daily", completion_mode="text")
    await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    # `mission_b` draws video/audio/activity. Without a daily one of those the third slot is
    # exhausted every day, and the tests below that assert "nothing was left empty" would be
    # asserting it against a hole this fixture dug.
    await make_prompt(session, kind="audio", cadence="daily", completion_mode="media")
    await make_prompt(session, kind="activity", cadence="weekly", completion_mode="did_it")
    await make_prompt(session, kind="measurement", cadence="monthly", completion_mode="text")
    await make_prompt(session, kind="letter", cadence="monthly", completion_mode="text")


async def _world(session: AsyncSession, *, timezone: str = "America/Detroit"):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14), timezone=timezone)
    await grant(session, user, child, "parent")
    await _pool(session)
    return user, child


async def _rows(session: AsyncSession, child_id, day: dt.date | None = None) -> list[Assignment]:
    statement = sa.select(Assignment).where(Assignment.child_id == child_id)
    if day is not None:
        statement = statement.where(Assignment.assigned_on == day)
    return list((await session.execute(statement.order_by(Assignment.slot))).scalars().all())


# --- Through the endpoint ------------------------------------------------------------------


async def test_today_creates_the_days_assignments_when_the_scheduler_never_ran(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The whole point. An untouched database still serves a full Today screen."""
    user, child = await _world(session)
    await session.commit()

    assert await _rows(session, child.id) == []

    # Read the clock *before* the call, the way the local-date test below does. Deriving the
    # expectation from a read taken afterwards puts a whole scheduler run between the server's
    # notion of today and the test's, so a local midnight crossing in that window fails a
    # server that behaved correctly.
    now = dt.datetime.now(tz=dt.UTC)
    response = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))

    assert response.status_code == 200
    body = response.json()
    assert {item["slot"] for item in body["today"]} >= {"question", "mission"}
    assert body["waiting"] == []

    created = await _rows(session, child.id)
    assert {row.slot for row in created} >= {"question", "mission"}
    assert all(row.status == "pending" for row in created)
    # Written for the child's local date, not the server's.
    expected = local_date(now, child.family_timezone)
    assert {row.assigned_on for row in created} == {expected}


async def test_a_second_read_creates_nothing_further(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The repair is a no-op once there is nothing to repair — no extra rows, no duplicates."""
    user, child = await _world(session)
    await session.commit()

    first = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))
    assert first.status_code == 200
    after_first = await _rows(session, child.id)
    assert after_first != []

    second = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))
    assert second.status_code == 200
    after_second = await _rows(session, child.id)

    assert [row.id for row in after_second] == [row.id for row in after_first]
    slots = [row.slot for row in after_second]
    assert len(slots) == len(set(slots)), f"duplicate slots: {slots}"
    assert first.json()["today"] == second.json()["today"]


async def test_two_concurrent_reads_produce_exactly_one_assignment_per_slot(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Correctness here is the unique index, not a read-then-write check that can be raced."""
    user, child = await _world(session)
    await session.commit()

    headers = auth_headers(user)
    url = f"/v1/children/{child.id}/today"
    left, right = await asyncio.gather(
        client.get(url, headers=headers), client.get(url, headers=headers)
    )

    assert left.status_code == 200
    assert right.status_code == 200

    rows = await _rows(session, child.id)
    slots = [row.slot for row in rows]
    assert sorted(slots) == sorted(set(slots)), f"a slot was filled twice: {slots}"
    assert set(slots) >= {"question", "mission"}


async def test_today_is_the_childs_local_date_not_the_servers(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The 9pm-tomorrow's-mission bug, asserted from the far side.

    The child lives in a zone that is on a different calendar date from UTC at this instant.
    Everything the endpoint reports and everything it writes must be that date.
    """
    now = dt.datetime.now(tz=dt.UTC)
    timezone, local_today = _zone_that_differs_from_utc(now)
    assert local_today != now.date(), "the fixture must not agree with UTC, or it proves nothing"

    user, child = await _world(session, timezone=timezone)
    await session.commit()

    response = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))

    assert response.status_code == 200
    assert response.json()["date"] == local_today.isoformat()

    rows = await _rows(session, child.id)
    assert rows != []
    assert {row.assigned_on for row in rows} == {local_today}


async def test_an_expired_assignment_is_not_resurrected_by_the_read(
    client: AsyncClient, session: AsyncSession
) -> None:
    """This path fills today's empty slots. It does not reach into the past."""
    user, child = await _world(session)
    stale = await make_prompt(session, kind="photo", completion_mode="media", body="Long gone.")
    lapsed = await make_assignment(
        session,
        child,
        stale,
        slot="mission",
        assigned_on=dt.date(2026, 1, 5),
        status="pending",
        expires_in_days=14,
    )
    await session.commit()

    # Captured before the request for the same reason as above: the server's "today" and the
    # test's have to come from the same instant, not from two clock reads with a scheduler run
    # between them.
    now = dt.datetime.now(tz=dt.UTC)
    response = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))
    assert response.status_code == 200

    await session.refresh(lapsed)
    # Still pending, still not expired *by this path* — the read did not touch it either way.
    assert lapsed.status == "pending"
    assert lapsed.assigned_on == dt.date(2026, 1, 5)

    # And no assignment was invented for any day but today.
    local_today = local_date(now, child.family_timezone)
    other_days = {row.assigned_on for row in await _rows(session, child.id)} - {
        local_today,
        dt.date(2026, 1, 5),
    }
    assert other_days == set()


async def test_the_date_override_stays_read_only(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`?date=` is for debugging. A read must not write assignments into another day."""
    user, child = await _world(session)
    await session.commit()

    # Being ahead of the clock is the assertion itself: `?date=` must never fill.
    far_off = dt.date(2027, 3, 9)  # future-date: the override must not self-heal
    response = await client.get(
        f"/v1/children/{child.id}/today",
        params={"date": far_off.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert response.json()["today"] == []
    assert await _rows(session, child.id, far_off) == []


# --- Through the service, where the day can be chosen ---------------------------------------


async def test_saturday_fills_the_weekly_slot(session: AsyncSession) -> None:
    _, child = await _world(session)
    await session.flush()

    await ensure_day_filled(session, child, SATURDAY)

    assert {row.slot for row in await _rows(session, child.id, SATURDAY)} == {
        "question",
        "mission",
        "mission_b",
        "weekly",
    }


async def test_the_first_of_the_month_fills_the_monthly_slot(session: AsyncSession) -> None:
    _, child = await _world(session)
    await session.flush()

    await ensure_day_filled(session, child, FIRST)

    # FIRST is a Tuesday, so the rotation gives `question` + `mission_b`, and the 1st adds
    # `monthly` on top.
    assert {row.slot for row in await _rows(session, child.id, FIRST)} == {
        "question",
        "mission_b",
        "monthly",
    }


async def test_only_the_missing_slot_is_filled(session: AsyncSession) -> None:
    """A partially-filled day is completed, not duplicated and not replaced."""
    _, child = await _world(session)
    existing = await make_prompt(session, kind="question", body="Already there.")
    kept = await make_assignment(session, child, existing, slot="question", assigned_on=WEEKDAY)
    await session.flush()

    run = await ensure_day_filled(session, child, WEEKDAY)

    # question was already there; `mission` was the gap. A Wednesday holds those two.
    assert run.created == 1
    assert run.skipped_existing == 1
    rows = await _rows(session, child.id, WEEKDAY)
    assert {row.slot for row in rows} == {"question", "mission"}
    question = next(row for row in rows if row.slot == "question")
    assert question.id == kept.id
    assert question.prompt_id == existing.id


async def test_the_read_path_honours_cooldown_and_theme_rotation_like_the_scheduler(
    session: AsyncSession,
) -> None:
    """The two paths must not be able to diverge.

    The pool is arranged so exactly one answer is correct under the rules — a prompt served
    yesterday is inside the 180-day cooldown, and a second prompt shares that prompt's theme
    so the two-day theme rotation rules it out too. One candidate survives, whichever code
    picks it. Both paths get the identical fixture and must land on it.
    """
    user = await make_user(session)
    repaired = await make_child(session, name="Repaired", birthdate=dt.date(2022, 6, 14))
    scheduled = await make_child(session, name="Scheduled", birthdate=dt.date(2022, 6, 14))
    await grant(session, user, repaired, "parent")
    await grant(session, user, scheduled, "parent")

    served = await make_prompt(session, kind="question", theme="bath-time", body="Served.")
    same_theme = await make_prompt(session, kind="question", theme="bath-time", body="Theme.")
    correct = await make_prompt(
        session, kind="question", theme="everyday-ordinary", body="Correct."
    )
    # So the mission slot has somewhere to go and cannot influence the question slot.
    await make_prompt(session, kind="photo", completion_mode="media", theme="firsts")

    yesterday = WEEKDAY - dt.timedelta(days=1)
    for child in (repaired, scheduled):
        await make_assignment(session, child, served, slot="question", assigned_on=yesterday)
    await session.flush()

    await ensure_day_filled(session, repaired, WEEKDAY, seed=1)
    await run_scheduler(session, as_of_date=WEEKDAY, child_id=scheduled.id, seed=1)

    def question_of(rows: list[Assignment]) -> Assignment:
        return next(row for row in rows if row.slot == "question")

    from_read = question_of(await _rows(session, repaired.id, WEEKDAY))
    from_scheduler = question_of(await _rows(session, scheduled.id, WEEKDAY))

    assert from_read.prompt_id == correct.id
    assert from_read.prompt_id == from_scheduler.prompt_id
    assert from_read.prompt_id not in (served.id, same_theme.id)


async def test_two_separate_transactions_racing_the_same_day_still_fill_each_slot_once(
    engine, session: AsyncSession
) -> None:
    """The endpoint test races two requests; this races two *transactions*, which is the
    thing the unique index actually has to survive.

    Both sessions run their existence check before either commits, so both believe the day
    is empty and both go on to insert. Postgres blocks the second on the index until the
    first commits, and `ON CONFLICT DO NOTHING` then makes it a no-op. If the code ever
    stopped relying on the index and started trusting its own pre-check, this is the test
    that would go red.
    """
    _, child = await _world(session)
    await session.commit()

    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)

    async def fill() -> None:
        async with factory() as racer:
            reloaded = await racer.get(Child, child.id)
            assert reloaded is not None
            await ensure_day_filled(racer, reloaded, WEEKDAY)
            await racer.commit()

    await asyncio.gather(fill(), fill())

    rows = await _rows(session, child.id, WEEKDAY)
    slots = [row.slot for row in rows]
    assert sorted(slots) == ["mission", "question"], f"a slot was filled twice: {slots}"


async def test_the_read_path_does_not_expire_anything(session: AsyncSession) -> None:
    """`run_scheduler` expires lapsed work. This deliberately does not — same fixture, both."""
    _, child = await _world(session)
    stale = await make_prompt(session, kind="photo", completion_mode="media")
    lapsed = await make_assignment(
        session,
        child,
        stale,
        slot="mission",
        assigned_on=WEEKDAY - dt.timedelta(days=30),
        status="pending",
    )
    await session.flush()

    run = await ensure_day_filled(session, child, WEEKDAY)

    assert run.expired == 0
    await session.refresh(lapsed)
    assert lapsed.status == "pending"

    # The scheduler, given the same row, does expire it. That contrast is the design.
    await run_scheduler(session, as_of_date=WEEKDAY, child_id=child.id)
    await session.refresh(lapsed)
    assert lapsed.status == "expired"


async def test_a_fully_filled_day_writes_nothing(session: AsyncSession) -> None:
    """The hot path: the scheduler already ran, so this must not select or insert."""
    _, child = await _world(session)
    await session.flush()
    await ensure_day_filled(session, child, WEEKDAY)
    before = [(row.id, row.prompt_id) for row in await _rows(session, child.id, WEEKDAY)]

    run = await ensure_day_filled(session, child, WEEKDAY)

    assert run.created == 0
    assert run.exhausted == []
    assert run.skipped_existing == len(before)
    assert [(row.id, row.prompt_id) for row in await _rows(session, child.id, WEEKDAY)] == before
