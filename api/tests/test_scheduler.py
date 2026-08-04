"""The scheduler.

The selection rules are exercised against the pure `choose_prompt`; the runner is exercised
against a real database, because idempotency is a unique index and nothing else.
"""

from __future__ import annotations

import datetime as dt
import random
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Assignment, Prompt
from rascal.services.scheduler import (
    COOLDOWN_DAYS,
    RELAXED_COOLDOWN_DAYS,
    choose_prompt,
    run_scheduler,
    select_prompt,
    slots_for,
)

# A Saturday that is neither the 1st nor the 15th, so the weekly slot is tested alone.
SATURDAY = dt.date(2026, 8, 22)
SUNDAY = dt.date(2026, 8, 16)
FIRST = dt.date(2026, 9, 1)
RNG = random.Random(1234)


def _prompt(
    *,
    theme: str = "everyday-ordinary",
    min_age: int = 24,
    max_age: int = 216,
    months: list[int] | None = None,
    kind: str = "question",
) -> Prompt:
    """A detached Prompt. `choose_prompt` is pure, so it never needs a session."""
    return Prompt(
        id=uuid.uuid4(),
        kind=kind,
        cadence="daily",
        completion_mode="text",
        body=f"prompt {uuid.uuid4().hex[:6]}",
        theme=theme,
        min_age_months=min_age,
        max_age_months=max_age,
        month_tags=months or [],
        source="seeded",
        active=True,
        content_hash=uuid.uuid4().hex,
    )


def _choose(candidates, **overrides):
    kwargs = {
        "age_months": 48,
        "month": 8,
        "served_recently": {},
        "recent_themes": set(),
        "rng": RNG,
    }
    kwargs.update(overrides)
    return choose_prompt(candidates, **kwargs)


# --- The pure selector -------------------------------------------------------------------


def test_a_prompt_outside_the_age_window_is_not_picked() -> None:
    too_old = _prompt(min_age=60, max_age=216)
    just_right = _prompt(min_age=24, max_age=120)

    for _ in range(20):
        assert _choose([too_old, just_right]) is just_right


def test_a_seasonal_prompt_is_only_picked_in_its_months() -> None:
    snow = _prompt(months=[12, 1, 2])
    any_month = _prompt()

    assert _choose([snow, any_month], month=8) is any_month
    # In December both are eligible, so over many draws the snow prompt does appear.
    picks = {_choose([snow, any_month], month=12).id for _ in range(50)}
    assert snow.id in picks


def test_the_180_day_cooldown_excludes_a_recent_prompt() -> None:
    recent = _prompt()
    old = _prompt()
    served = {recent.id: 30, old.id: COOLDOWN_DAYS + 1}

    for _ in range(20):
        assert _choose([recent, old], served_recently=served) is old


def test_a_prompt_just_outside_the_cooldown_is_available_again() -> None:
    prompt = _prompt()
    assert _choose([prompt], served_recently={prompt.id: COOLDOWN_DAYS + 1}) is prompt


def test_a_theme_served_in_the_last_two_days_is_skipped() -> None:
    same_theme = _prompt(theme="voice")
    other_theme = _prompt(theme="food")

    for _ in range(20):
        assert _choose([same_theme, other_theme], recent_themes={"voice"}) is other_theme


def test_pool_exhaustion_relaxes_the_cooldown_before_the_age_window() -> None:
    """An age-inappropriate prompt is worse than a repeat, so the age window gives last."""
    repeat = _prompt(min_age=24, max_age=120)  # right age, seen 100 days ago
    wrong_age = _prompt(min_age=180, max_age=216)  # never seen, wrong age
    served = {repeat.id: 100}  # inside 180 days, outside 90

    for _ in range(20):
        assert _choose([repeat, wrong_age], served_recently=served) is repeat


def test_the_age_window_relaxes_only_when_nothing_else_is_left() -> None:
    wrong_age = _prompt(min_age=180, max_age=216)
    assert _choose([wrong_age]) is wrong_age


def test_theme_rotation_gives_before_the_cooldown_fully_lapses() -> None:
    """With one candidate left and its theme just served, a repeated theme beats nothing."""
    only = _prompt(theme="voice")
    assert _choose([only], recent_themes={"voice"}) is only


def test_an_empty_pool_returns_none_rather_than_inventing_something() -> None:
    assert _choose([]) is None


def test_a_prompt_this_child_has_never_seen_is_weighted_higher() -> None:
    unseen = _prompt()
    seen = _prompt()
    served = {seen.id: RELAXED_COOLDOWN_DAYS + 200}
    rng = random.Random(7)

    picks = [
        choose_prompt(
            [unseen, seen],
            age_months=48,
            month=8,
            served_recently=served,
            recent_themes=set(),
            rng=rng,
        ).id
        for _ in range(400)
    ]
    # UNSEEN_WEIGHT is 3 against SEEN_WEIGHT 1, so roughly three to one.
    assert picks.count(unseen.id) > picks.count(seen.id) * 1.8


# --- Slot calendar -----------------------------------------------------------------------


def test_the_weekly_slot_only_fires_on_saturday() -> None:
    assert slots_for(SATURDAY) == ["question", "mission", "weekly"]
    assert slots_for(SUNDAY) == ["question", "mission"]


def test_the_monthly_slot_only_fires_on_the_first() -> None:
    assert "monthly" in slots_for(FIRST)
    assert "monthly" not in slots_for(dt.date(2026, 9, 2))


# --- The runner --------------------------------------------------------------------------


async def _library(session: AsyncSession) -> None:
    """Enough of a library that every slot can be filled."""
    for index in range(6):
        await make_prompt(session, kind="question", theme=f"theme-{index}")
    for index, kind in enumerate(("photo", "video", "audio", "activity", "photo", "audio")):
        await make_prompt(
            session, kind=kind, completion_mode="media", theme=f"mission-theme-{index}"
        )
    for index in range(3):
        await make_prompt(
            session,
            kind="activity",
            cadence="weekly",
            completion_mode="media",
            theme=f"weekly-{index}",
        )
    for index in range(3):
        await make_prompt(
            session,
            kind="measurement",
            cadence="monthly",
            completion_mode="media",
            theme=f"monthly-{index}",
        )


async def test_running_twice_for_the_same_date_creates_no_duplicates(
    session: AsyncSession,
) -> None:
    """The unique index on (child_id, assigned_on, slot) is what makes reruns free."""
    await make_child(session)
    await _library(session)
    await session.commit()

    first = await run_scheduler(session, as_of_date=SUNDAY, seed=1)
    await session.commit()
    second = await run_scheduler(session, as_of_date=SUNDAY, seed=2)
    await session.commit()

    assert first.created == 2  # question and mission
    assert second.created == 0
    assert second.skipped_existing == 2

    total = await session.scalar(sa.select(sa.func.count()).select_from(Assignment))
    assert total == 2


async def test_two_children_in_different_zones_get_different_dates_from_one_instant(
    session: AsyncSession,
) -> None:
    auckland = await make_child(session, name="Kea", timezone="Pacific/Auckland")
    detroit = await make_child(session, name="Miles", timezone="America/Detroit")
    await _library(session)
    await session.commit()

    # 2026-08-15 06:00 UTC is still Aug 15 in Detroit (02:00) but already Aug 15 18:00 in
    # Auckland; at 14:00 UTC Auckland has rolled over to Aug 16 while Detroit is on Aug 15.
    instant = dt.datetime(2026, 8, 15, 14, 0, tzinfo=dt.UTC)
    await run_scheduler(session, as_of=instant, seed=3)
    await session.commit()

    dates = dict(
        (
            await session.execute(sa.select(Assignment.child_id, Assignment.assigned_on).distinct())
        ).all()
    )
    assert dates[auckland.id] == dt.date(2026, 8, 16)
    assert dates[detroit.id] == dt.date(2026, 8, 15)
    assert dates[auckland.id] != dates[detroit.id]


async def test_saturday_adds_the_weekly_slot(session: AsyncSession) -> None:
    child = await make_child(session)
    await _library(session)
    await session.commit()

    await run_scheduler(session, as_of_date=SATURDAY, seed=4)
    await session.commit()

    slots = set(
        (await session.execute(sa.select(Assignment.slot).where(Assignment.child_id == child.id)))
        .scalars()
        .all()
    )
    assert slots == {"question", "mission", "weekly"}


async def test_the_first_of_the_month_adds_the_monthly_slot(session: AsyncSession) -> None:
    child = await make_child(session)
    await _library(session)
    await session.commit()

    await run_scheduler(session, as_of_date=FIRST, seed=5)
    await session.commit()

    slots = set(
        (await session.execute(sa.select(Assignment.slot).where(Assignment.child_id == child.id)))
        .scalars()
        .all()
    )
    assert "monthly" in slots


async def test_stale_pending_assignments_expire(session: AsyncSession) -> None:
    child = await make_child(session)
    prompt = await make_prompt(session)
    lapsed = await make_assignment(
        session,
        child,
        prompt,
        assigned_on=SUNDAY - dt.timedelta(days=20),
        expires_in_days=14,
    )
    still_open = await make_assignment(
        session, child, prompt, slot="mission", assigned_on=SUNDAY - dt.timedelta(days=2)
    )
    await _library(session)
    await session.commit()

    run = await run_scheduler(session, as_of_date=SUNDAY, seed=6)
    await session.commit()

    await session.refresh(lapsed)
    await session.refresh(still_open)
    assert run.expired == 1
    assert lapsed.status == "expired"
    assert still_open.status == "pending"


async def test_the_scheduler_avoids_repeating_a_theme_across_the_daily_pair(
    session: AsyncSession,
) -> None:
    """The question and the mission are picked seconds apart; they must not match."""
    child = await make_child(session)
    # Every mission prompt shares a theme with a question prompt except one.
    await make_prompt(session, kind="question", theme="voice")
    await make_prompt(session, kind="audio", completion_mode="media", theme="voice")
    await make_prompt(session, kind="photo", completion_mode="media", theme="outdoors")
    await session.commit()

    await run_scheduler(session, as_of_date=SUNDAY, seed=11)
    await session.commit()

    themes = list(
        (
            await session.execute(
                sa.select(Prompt.theme)
                .join(Assignment, Assignment.prompt_id == Prompt.id)
                .where(Assignment.child_id == child.id)
            )
        )
        .scalars()
        .all()
    )
    assert sorted(themes) == ["outdoors", "voice"]


async def test_the_cooldown_excludes_a_prompt_this_child_saw_recently(
    session: AsyncSession,
) -> None:
    child = await make_child(session)
    recent = await make_prompt(session, kind="question", theme="a")
    fresh = await make_prompt(session, kind="question", theme="b")
    await make_assignment(
        session, child, recent, assigned_on=SUNDAY - dt.timedelta(days=10), status="done"
    )
    await session.commit()

    chosen = await select_prompt(child, "question", SUNDAY, session, rng=random.Random(2))
    assert chosen.id == fresh.id


async def test_a_slot_with_no_eligible_prompt_is_left_empty_not_faked(
    session: AsyncSession,
) -> None:
    await make_child(session, birthdate=dt.date(2022, 6, 14))
    # Nothing at all in the library.
    await session.commit()

    run = await run_scheduler(session, as_of_date=SUNDAY, seed=7)
    await session.commit()

    assert run.created == 0
    assert len(run.exhausted) == 2
    assert await session.scalar(sa.select(sa.func.count()).select_from(Assignment)) == 0


async def test_a_run_can_be_scoped_to_one_child(session: AsyncSession) -> None:
    first = await make_child(session, name="One")
    await make_child(session, name="Two")
    await _library(session)
    await session.commit()

    await run_scheduler(session, as_of_date=SUNDAY, child_id=first.id, seed=8)
    await session.commit()

    children = set(
        (await session.execute(sa.select(Assignment.child_id).distinct())).scalars().all()
    )
    assert children == {first.id}


# --- Debug routes ------------------------------------------------------------------------


async def test_the_debug_route_runs_an_arbitrary_date(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    await _library(session)
    await session.commit()

    response = await client.post(
        "/v1/debug/scheduler/run",
        json={"date": SATURDAY.isoformat(), "child_id": str(child.id), "seed": 9},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert response.json()["created"] == 3  # question, mission, weekly

    # And it is idempotent, exactly like the real job.
    again = await client.post(
        "/v1/debug/scheduler/run",
        json={"date": SATURDAY.isoformat(), "child_id": str(child.id), "seed": 10},
        headers=auth_headers(user),
    )
    assert again.json()["created"] == 0
    assert again.json()["skipped_existing"] == 3


async def test_reset_today_clears_a_day_so_the_loop_can_be_rerun(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    await _library(session)
    await session.commit()

    await client.post(
        "/v1/debug/scheduler/run",
        json={"date": SUNDAY.isoformat(), "child_id": str(child.id)},
        headers=auth_headers(user),
    )
    reset = await client.post(
        "/v1/debug/reset-today",
        json={"child_id": str(child.id), "date": SUNDAY.isoformat()},
        headers=auth_headers(user),
    )

    assert reset.status_code == 200
    assert reset.json()["deleted"] == 2
    assert await session.scalar(sa.select(sa.func.count()).select_from(Assignment)) == 0


async def test_the_debug_routes_refuse_someone_elses_child(
    client: AsyncClient, session: AsyncSession
) -> None:
    owner = await make_user(session)
    child = await make_child(session)
    await grant(session, owner, child, "parent")
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    run = await client.post(
        "/v1/debug/scheduler/run",
        json={"child_id": str(child.id)},
        headers=auth_headers(stranger),
    )
    reset = await client.post(
        "/v1/debug/reset-today",
        json={"child_id": str(child.id)},
        headers=auth_headers(stranger),
    )
    assert run.status_code == 403
    assert reset.status_code == 403


async def test_the_debug_routes_are_not_registered_outside_local(engine) -> None:
    from rascal.config import get_settings
    from rascal.main import create_app

    prod = create_app(get_settings().model_copy(update={"environment": "prod"}))
    paths = prod.openapi()["paths"]
    assert not [path for path in paths if path.startswith("/v1/debug")]


# --- B1: letters get their own slot, on the 15th ------------------------------------------


FIFTEENTH = dt.date(2026, 9, 15)


def test_the_letter_slot_only_fires_on_the_fifteenth() -> None:
    assert "letter" in slots_for(FIFTEENTH)
    assert "letter" not in slots_for(FIRST)
    assert "letter" not in slots_for(SUNDAY)


def test_the_letter_and_the_measurement_never_land_on_the_same_day() -> None:
    """Four items on one day breaks "two items is the most that survives a bad Tuesday"."""
    for day in (FIRST, FIFTEENTH):
        slots = slots_for(day)
        assert not {"monthly", "letter"} <= set(slots)
        assert len(slots) <= 3


async def test_the_monthly_slot_never_serves_a_letter(session: AsyncSession) -> None:
    """A letter competing with the measurement is how the money letter never gets written."""
    child = await make_child(session)
    await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=18,
        theme="letters-forward",
    )
    await make_prompt(
        session,
        kind="measurement",
        cadence="monthly",
        completion_mode="media",
        theme="growth-measurement",
    )
    await session.commit()

    for _ in range(15):
        chosen = await select_prompt(child, "monthly", FIRST, session, rng=random.Random(0))
        assert chosen.kind == "measurement"


async def test_the_letter_slot_only_serves_letters(session: AsyncSession) -> None:
    child = await make_child(session)
    await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=18,
        theme="letters-forward",
    )
    await make_prompt(
        session,
        kind="measurement",
        cadence="monthly",
        completion_mode="media",
        theme="growth-measurement",
    )
    await session.commit()

    for _ in range(15):
        chosen = await select_prompt(child, "letter", FIFTEENTH, session, rng=random.Random(0))
        assert chosen.kind == "letter"


async def test_the_scheduler_fills_the_letter_slot_on_the_fifteenth(
    session: AsyncSession,
) -> None:
    child = await make_child(session)
    await _library(session)
    await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=16,
        theme="letters-forward",
    )
    await session.commit()

    await run_scheduler(session, as_of_date=FIFTEENTH, seed=21)
    await session.commit()

    rows = dict(
        (
            await session.execute(
                sa.select(Assignment.slot, Prompt.kind)
                .join(Prompt, Prompt.id == Assignment.prompt_id)
                .where(Assignment.child_id == child.id)
            )
        ).all()
    )
    assert rows["letter"] == "letter"
    assert "monthly" not in rows


async def test_an_entry_completing_a_letter_inherits_its_unlock_age(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Letters are sealed by default. The server owns that, not the client."""
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    await _library(session)
    letter = await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=18,
        theme="letters-forward",
        body="Write him something about money.",
    )
    await session.commit()

    await run_scheduler(session, as_of_date=FIFTEENTH, seed=22)
    await session.commit()

    assignment_id = await session.scalar(
        sa.select(Assignment.id).where(Assignment.child_id == child.id, Assignment.slot == "letter")
    )
    created = await client.post(
        "/v1/entries",
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(assignment_id),
            "occurred_at": "2026-09-15T21:00:00Z",
            "body": "The thing nobody told me at nineteen was that...",
        },
        headers=auth_headers(user),
    )

    assert created.status_code == 201
    assert created.json()["unlock_at_age"] == letter.default_unlock_age == 18
    assert created.json()["entry_type"] == "text"


async def test_a_client_may_override_the_inherited_unlock_age(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    letter = await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=18,
        theme="letters-forward",
    )
    assignment = await make_assignment(session, child, letter, slot="letter", assigned_on=FIFTEENTH)
    await session.commit()

    created = await client.post(
        "/v1/entries",
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(assignment.id),
            "occurred_at": "2026-09-15T21:00:00Z",
            "body": "He can have this one at thirteen.",
            "unlock_at_age": 13,
        },
        headers=auth_headers(user),
    )
    assert created.json()["unlock_at_age"] == 13
