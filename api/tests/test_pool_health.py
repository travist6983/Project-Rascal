"""Pool health: the cliff, made visible before it arrives."""

from __future__ import annotations

import datetime as dt

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import PromptSuppression
from rascal.services.pool_health import (
    RELAXATION_COOLDOWN_90,
    RELAXATION_NONE,
    pool_health,
)

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
