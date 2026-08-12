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

TODAY = dt.date(2026, 8, 14)


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    return user, child


def _question(report):
    return next(row for row in report if row.slot == "question")


async def test_counts_are_correct_against_a_known_fixture(session: AsyncSession) -> None:
    """Five eligible questions: one suppressed, one served last week, one out of the age window."""
    _user, child = await _world(session)

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

    row = _question(await pool_health(session, child, as_of=TODAY))

    # The out-of-window one is not counted as eligible at all.
    assert row.eligible == 4
    assert row.suppressed == 1
    assert row.served_within_cooldown == 1
    assert row.available_now == 2
    assert {available_one.id, available_two.id}  # named for readability


async def test_the_estimate_is_available_count_times_the_serve_interval(
    session: AsyncSession,
) -> None:
    _user, child = await _world(session)
    for index in range(3):
        await make_prompt(session, kind="question", body=f"Q{index}.")

    row = _question(await pool_health(session, child, as_of=TODAY))

    # Daily slot, three available.
    assert row.available_now == 3
    assert row.estimated_days_until_first_repeat == 3


async def test_a_dry_pool_reports_null_rather_than_a_countdown_to_zero(
    session: AsyncSession,
) -> None:
    _user, child = await _world(session)
    only = await make_prompt(session, kind="question", body="Served yesterday.")
    await make_assignment(
        session, child, only, slot="question", assigned_on=TODAY - dt.timedelta(days=1)
    )

    row = _question(await pool_health(session, child, as_of=TODAY))

    assert row.available_now == 0
    assert row.estimated_days_until_first_repeat is None
    assert row.relaxation_active
    assert row.relaxation_step == RELAXATION_COOLDOWN_90


async def test_a_healthy_pool_reports_no_relaxation(session: AsyncSession) -> None:
    _user, child = await _world(session)
    for index in range(5):
        await make_prompt(session, kind="question", body=f"Q{index}.")

    row = _question(await pool_health(session, child, as_of=TODAY))

    assert row.relaxation_active is False
    assert row.relaxation_step == RELAXATION_NONE


async def test_it_reports_and_does_not_fix(session: AsyncSession) -> None:
    """Reading pool health must not change what the scheduler would do next."""
    _user, child = await _world(session)
    prompt = await make_prompt(session, kind="question", body="Only one.")
    session.add(PromptSuppression(child_id=child.id, prompt_id=prompt.id))
    await session.flush()

    before = await pool_health(session, child, as_of=TODAY)
    after = await pool_health(session, child, as_of=TODAY)

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
