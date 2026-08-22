"""Pool health: the cliff, made visible before it arrives."""

from __future__ import annotations

import datetime as dt

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import PromptSuppression
from rascal.services.pool_health import (
    _INTERVAL_SWEEP_DAYS,
    _INTERVAL_SWEEP_START,
    RELAXATION_COOLDOWN_90,
    RELAXATION_NONE,
    pool_health,
    serve_interval_days,
)
from rascal.services.scheduler import slots_for

TODAY = dt.date(2026, 8, 14)  # future-date: explicit, pure


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    return user, child


def _question(report):
    return next(row for row in report if row.slot == "question")


async def test_counts_are_correct_against_a_known_fixture(session: AsyncSession) -> None:
    """Five eligible questions: one suppressed, one served last week, one out of the age window."""
    user, child = await _world(session)

    available_one = await make_prompt(session, kind="question", body="A.")
    available_two = await make_prompt(session, kind="question", body="B.")
    suppressed = await make_prompt(session, kind="question", body="C.")
    recent = await make_prompt(session, kind="question", body="D.")
    # The child is 50 months old at TODAY; this one starts at 200 months.
    await make_prompt(session, kind="question", body="E.", min_age_months=200)

    session.add(PromptSuppression(child_id=child.id, prompt_id=suppressed.id))
    await make_assignment(
        session, child, recent, slot="question", assigned_on=TODAY - dt.timedelta(days=7)
    )
    await session.flush()

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    # The out-of-window one is not counted as eligible at all.
    assert row.eligible == 4
    assert row.suppressed == 1
    assert row.served_within_cooldown == 1
    assert row.available_now == 2
    assert {available_one.id, available_two.id}  # named for readability


async def test_the_estimate_divides_by_the_observed_rate_not_the_nominal_one(
    session: AsyncSession,
) -> None:
    """**The correction.** This used to assert `available * SERVE_INTERVAL_DAYS[slot]`, which
    reads the cadence a slot is *supposed* to run at. Production has served `mission` zero times
    a day while that constant said one, so the report counted down to a repeat that could not
    arrive. The rate now comes from assignments that actually exist.
    """
    user, child = await _world(session)
    for index in range(6):
        await make_prompt(session, kind="question", body=f"Q{index}.")
    # Served on fourteen of the last twenty-eight days: half a prompt a day.
    for day in range(1, 29, 2):
        served = await make_prompt(session, kind="question", body=f"Served {day}.")
        await make_assignment(
            session, child, served, slot="question", assigned_on=TODAY - dt.timedelta(days=day)
        )

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    assert row.served_in_window == 14
    assert row.observation_window_days == 28
    assert row.nominal_interval_days == 1
    assert row.estimate_basis == "observed_rate"
    # Six available at half a day each — twice what the nominal daily rate would have claimed.
    assert row.estimated_days_until_first_repeat == row.available_now * 2


def test_the_nominal_cadence_is_counted_off_the_scheduler_not_written_down_twice() -> None:
    """**The instrument must not develop a permanent false reading.**

    `nominal_interval_days` exists so the gap between intended and observed cadence is legible;
    a slot supposedly served daily that reports `served_in_window: 0` is the shape of the defect
    PR #57 found. Phase 107's weekday rotation made the old hand-written table — `mission: 1`,
    `mission_b: 1` — false, which would have put a permanent, spurious gap on both mission slots
    and turned that panel into a thing you learn to ignore.

    It is counted off `slots_for` now. This pins the values *and* that the derivation is real:
    `mission` five days a week, `mission_b` four, and the shared slots at their own cadence.
    """
    intervals = serve_interval_days()

    assert intervals["question"] == 1.0, "the question is the free tier and fires every day"
    assert intervals["mission"] == 1.4, "Mon, Wed, Fri and both weekend days — five in seven"
    assert intervals["mission_b"] == 1.75, "Tue, Thu and both weekend days — four in seven"
    assert intervals["weekly"] == 7.0
    assert intervals["monthly"] == intervals["letter"] == 30.44

    # **Every slot the calendar produces has an interval, and that is now true by
    # construction rather than by vigilance** — `serve_interval_days` builds its keys *from*
    # `slots_for`, so a slot added there appears here automatically. Asserted anyway, because
    # the property is what `test_every_registry_keyed_by_slot_covers_every_slot` relies on, and
    # because it would stop being free the day somebody hand-writes an entry back in.
    day = dt.date(2026, 1, 1)  # future-date: explicit, pure
    produced = {slot for n in range(366 * 4) for slot in slots_for(day + dt.timedelta(days=n))}
    assert produced == set(intervals), (
        "the interval table and the calendar disagree about which slots exist"
    )

    # **The derivation, checked against the calendar rather than restated.** Counting how often
    # each slot actually fires over the same 28-year window and dividing gives the table back —
    # which is what makes the numbers above measurements rather than four literals somebody
    # typed. An implementation that returned a hand-written dict fails here.
    counts: dict[str, int] = {}
    for offset in range(_INTERVAL_SWEEP_DAYS):
        for slot in slots_for(_INTERVAL_SWEEP_START + dt.timedelta(days=offset)):
            counts[slot] = counts.get(slot, 0) + 1
    assert intervals == {
        slot: round(_INTERVAL_SWEEP_DAYS / count, 2) for slot, count in counts.items()
    }


async def test_a_slot_nobody_serves_reports_unmeasured_rather_than_a_countdown(
    session: AsyncSession,
) -> None:
    """**The production defect this phase exists for.** `mission` reads
    `served_within_cooldown=0` and `relaxation_active=False` because nothing draws from it. The
    old arithmetic answered "twenty days until the first repeat", which is a confident number
    about an event that cannot happen. Null plus a basis is the honest answer.

    It must not read as good news either: a healthy pool nobody is serving is usually a defect
    upstream, and the report says both halves and lets the reader join them.
    """
    user, child = await _world(session)
    for index in range(3):
        await make_prompt(session, kind="question", body=f"Q{index}.")

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    assert row.available_now == 3
    assert row.served_in_window == 0
    assert row.estimated_days_until_first_repeat is None
    assert row.estimate_basis == "not_observed"
    # The nominal cadence still travels, so the gap is legible rather than inferred.
    assert row.nominal_interval_days == 1


async def test_a_weekly_slots_rate_survives_being_smaller_than_one_a_day(
    session: AsyncSession,
) -> None:
    """A fractional rate rounded before dividing would put a weekly slot out by a factor of
    seven. The division stays fractional and only the answer is an integer.
    """
    user, child = await _world(session)
    for index in range(10):
        await make_prompt(session, kind="question", body=f"Q{index}.")
    # Four serves in twenty-eight days is one a week.
    for week in range(4):
        served = await make_prompt(session, kind="question", body=f"Weekly {week}.")
        await make_assignment(
            session,
            child,
            served,
            slot="question",
            assigned_on=TODAY - dt.timedelta(days=week * 7 + 1),
        )

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    assert row.served_in_window == 4
    assert row.estimate_basis == "observed_rate"
    # Ten available at one a week is seventy days, not ten.
    assert row.estimated_days_until_first_repeat == 70


async def test_a_dry_pool_reports_null_rather_than_a_countdown_to_zero(
    session: AsyncSession,
) -> None:
    user, child = await _world(session)
    only = await make_prompt(session, kind="question", body="Served yesterday.")
    await make_assignment(
        session, child, only, slot="question", assigned_on=TODAY - dt.timedelta(days=1)
    )

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    assert row.available_now == 0
    assert row.estimated_days_until_first_repeat is None
    # A dry pool and an unserved slot are different nulls, and the basis is what tells them
    # apart. This one was served — the pool emptied, it did not go untouched.
    assert row.estimate_basis == "pool_empty"
    assert row.relaxation_active
    assert row.relaxation_step == RELAXATION_COOLDOWN_90


async def test_a_healthy_pool_reports_no_relaxation(session: AsyncSession) -> None:
    user, child = await _world(session)
    for index in range(5):
        await make_prompt(session, kind="question", body=f"Q{index}.")

    row = _question(await pool_health(session, child, as_of=TODAY, viewer_id=user.id))

    assert row.relaxation_active is False
    assert row.relaxation_step == RELAXATION_NONE


async def test_it_reports_and_does_not_fix(session: AsyncSession) -> None:
    """Reading pool health must not change what the scheduler would do next."""
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="question", body="Only one.")
    session.add(PromptSuppression(child_id=child.id, prompt_id=prompt.id))
    await session.flush()

    before = await pool_health(session, child, as_of=TODAY, viewer_id=user.id)
    after = await pool_health(session, child, as_of=TODAY, viewer_id=user.id)

    assert [row.__dict__ for row in before] == [row.__dict__ for row in after]
    # And the suppression is untouched by having been counted.
    still = await session.get(PromptSuppression, (child.id, prompt.id))
    assert still is not None and still.revoked_at is None


async def test_the_route_reports_every_slot(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    await make_prompt(session, kind="question")

    await session.commit()

    response = await client.get(f"/v1/children/{child.id}/pool-health", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["child_id"] == str(child.id)
    assert {row["slot"] for row in payload["slots"]} == {
        "question",
        "mission",
        "mission_b",
        "weekly",
        "monthly",
        "letter",
    }
    # The field name carries the caveat, so a client cannot render a projection as a fact.
    assert "estimated_days_until_first_repeat" in payload["slots"][0]
