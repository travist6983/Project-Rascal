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
    assert slots_for(SATURDAY) == ["question", "mission", "mission_b", "weekly"]
    assert slots_for(SUNDAY) == ["question", "mission", "mission_b"]


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

    assert first.created == 3  # question, mission, mission_b
    assert second.created == 0
    assert second.skipped_existing == 3

    total = await session.scalar(sa.select(sa.func.count()).select_from(Assignment))
    assert total == 3


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
    assert slots == {"question", "mission", "mission_b", "weekly"}


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


async def test_the_scheduler_avoids_repeating_a_theme_across_the_daily_three(
    session: AsyncSession,
) -> None:
    """All three daily slots are picked seconds apart; none of them may match.

    This used to cover a pair, and the rule it tests was written for a pair. It generalises
    by construction rather than by arithmetic: `_fill_slot` inserts each assignment before the
    next slot is selected, and `_history` re-reads the child's day per pick inside the same
    transaction — so the third pick sees the first two exactly as the second saw the first.

    The pool is arranged so the right answer is **forced rather than lucky**. The first two
    slots have exactly one candidate each, so their themes are fixed. The third has three, two
    of which duplicate a theme already served *today* — one from the first slot, one from the
    second. Only `sleep` is fresh, so a scheduler that looked at neither, or at only the
    immediately preceding pick, would land somewhere this asserts against.
    """
    child = await make_child(session)
    # Slot 1, forced: "voice".
    await make_prompt(session, kind="question", theme="voice")
    # Slot 2, forced: "outdoors".
    await make_prompt(session, kind="photo", completion_mode="media", theme="outdoors")
    # Slot 3 has a choice, and two of the three are already spent today.
    await make_prompt(session, kind="audio", completion_mode="media", theme="voice")
    await make_prompt(session, kind="video", completion_mode="media", theme="outdoors")
    await make_prompt(session, kind="activity", completion_mode="did_it", theme="sleep")
    await session.commit()

    await run_scheduler(session, as_of_date=SUNDAY, seed=11)
    await session.commit()

    by_slot = dict(
        (
            await session.execute(
                sa.select(Assignment.slot, Prompt.theme)
                .join(Prompt, Prompt.id == Assignment.prompt_id)
                .where(Assignment.child_id == child.id)
            )
        ).all()
    )

    assert set(by_slot) == {"question", "mission", "mission_b"}
    assert by_slot["question"] == "voice"
    assert by_slot["mission"] == "outdoors"
    # The whole point: the third pick saw both of the first two, not just the last one.
    assert by_slot["mission_b"] == "sleep"
    assert len(set(by_slot.values())) == 3


async def test_a_theme_collision_is_preferred_to_an_empty_slot(session: AsyncSession) -> None:
    """When the only candidate shares a theme already used today, it is still served.

    Theme rotation is a preference and the ladder relaxes it; a hole in the day is not a
    preference. This is the case the three-slot fixture above deliberately avoids, asserted
    here on its own so that relaxing is a decision rather than an accident.
    """
    child = await make_child(session)
    await make_prompt(session, kind="question", theme="voice")
    await make_prompt(session, kind="photo", completion_mode="media", theme="outdoors")
    # The only thing mission_b can draw, and it collides with the question's theme.
    await make_prompt(session, kind="audio", completion_mode="media", theme="voice")
    await session.commit()

    run = await run_scheduler(session, as_of_date=SUNDAY, seed=11)
    await session.commit()

    assert run.created == 3
    assert run.exhausted == []
    themes = sorted(
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
    assert themes == ["outdoors", "voice", "voice"]


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
    # All three daily slots, not two: an empty library exhausts mission_b as well.
    assert len(run.exhausted) == 3
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
    assert response.json()["created"] == 4  # question, mission, mission_b, weekly

    # And it is idempotent, exactly like the real job.
    again = await client.post(
        "/v1/debug/scheduler/run",
        json={"date": SATURDAY.isoformat(), "child_id": str(child.id), "seed": 10},
        headers=auth_headers(user),
    )
    assert again.json()["created"] == 0
    assert again.json()["skipped_existing"] == 4


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
    assert reset.json()["deleted"] == 3
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
    """The split that keeps the money letter from losing a coin flip to a height measurement.

    The original reason for this test — "four items on one day breaks two-items-is-the-most-
    that-survives-a-bad-Tuesday" — no longer holds, because the third daily mission puts every
    day past that ceiling. The owner took that call knowing the worst day now reaches five.

    **What survives is the part that was never about the count.** `monthly` and `letter` still
    must not share a day: they are the two occasional slots most likely to be skipped, and
    stacking them means the letter is the one that goes.
    """
    for day in (FIRST, FIFTEENTH):
        # Both fixtures are Tuesdays. Stated rather than assumed: on a Saturday the count below
        # would be five and the test would look broken when it was only badly dated.
        assert day.weekday() != 5, f"{day} is a Saturday; this test's count assumes it is not"
        slots = slots_for(day)
        assert not {"monthly", "letter"} <= set(slots)
        # Three daily plus exactly one occasional.
        assert len(slots) == 4


def test_a_saturday_that_is_also_the_fifteenth_is_the_five_item_day() -> None:
    """The worst the calendar can do, asserted rather than left to arithmetic.

    2026-08-15 is a Saturday *and* the 15th, so the weekly and the letter both fire on top of
    the daily three. Nothing suppresses either — that was decided, not overlooked.
    """
    saturday_the_fifteenth = dt.date(2026, 8, 15)
    assert saturday_the_fifteenth.weekday() == 5, "the fixture must actually be a Saturday"

    slots = slots_for(saturday_the_fifteenth)

    assert slots == ["question", "mission", "mission_b", "weekly", "letter"]
    assert len(slots) == 5


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


# --- C2: hourly firing, filtered on each child's local hour -------------------------------


async def test_the_hourly_job_only_serves_children_for_whom_it_is_five_am(
    session: AsyncSession,
) -> None:
    """One daily UTC cron is 5am in exactly one timezone. Hourly plus a filter is 5am in all."""
    detroit = await make_child(session, name="Miles", timezone="America/Detroit")
    await make_child(session, name="Kea", timezone="Pacific/Auckland")
    await _library(session)
    await session.commit()

    # 09:00 UTC on 2026-08-22 is 05:00 in Detroit (EDT, UTC-4) and 21:00 in Auckland.
    instant = dt.datetime(2026, 8, 22, 9, 0, tzinfo=dt.UTC)
    run = await run_scheduler(session, as_of=instant, only_local_hour=5, seed=30)
    await session.commit()

    assert run.skipped_off_hour == 1
    served = set((await session.execute(sa.select(Assignment.child_id).distinct())).scalars().all())
    assert served == {detroit.id}


async def test_every_timezone_gets_its_own_five_am_across_a_day_of_firings(
    session: AsyncSession,
) -> None:
    """The point of the change: nobody's mission arrives at 9pm."""
    detroit = await make_child(session, name="Miles", timezone="America/Detroit")
    auckland = await make_child(session, name="Kea", timezone="Pacific/Auckland")
    await _library(session)
    await session.commit()

    # Twenty-four hourly firings, exactly as the Fly machine would produce them.
    for hour in range(24):
        instant = dt.datetime(2026, 8, 22, hour, 0, tzinfo=dt.UTC)
        await run_scheduler(session, as_of=instant, only_local_hour=5, seed=31)
        await session.commit()

    served = dict(
        (
            await session.execute(sa.select(Assignment.child_id, Assignment.assigned_on).distinct())
        ).all()
    )
    assert set(served) == {detroit.id, auckland.id}
    # Each was served on their *own* local date, not on a shared UTC one. Within a single UTC
    # day of firings, 5am in Detroit (UTC-4) is the 22nd and 5am in Auckland (UTC+12) is
    # already the 23rd — which is exactly the point.
    assert served[detroit.id] == dt.date(2026, 8, 22)
    assert served[auckland.id] == dt.date(2026, 8, 23)


async def test_a_dst_shift_does_not_move_anyone_off_their_five_am(
    session: AsyncSession,
) -> None:
    """A fixed UTC hour drifts when the clocks change. A local-hour filter cannot."""
    child = await make_child(session, name="Miles", timezone="America/Detroit")
    await _library(session)
    await session.commit()

    # Detroit is UTC-4 in August and UTC-5 in December, so 5am local is a different UTC hour
    # on either side of the change. Both firings must find the child.
    summer = dt.datetime(2026, 8, 22, 9, 0, tzinfo=dt.UTC)
    winter = dt.datetime(2026, 12, 12, 10, 0, tzinfo=dt.UTC)

    for instant in (summer, winter):
        run = await run_scheduler(session, as_of=instant, only_local_hour=5, seed=32)
        await session.commit()
        assert run.skipped_off_hour == 0, instant

    days = set(
        (
            await session.execute(
                sa.select(Assignment.assigned_on).where(Assignment.child_id == child.id).distinct()
            )
        )
        .scalars()
        .all()
    )
    assert days == {dt.date(2026, 8, 22), dt.date(2026, 12, 12)}


async def test_an_hourly_run_is_idempotent_within_the_same_local_hour(
    session: AsyncSession,
) -> None:
    """A double-fire has to be free, because Fly's scheduler makes no exactly-once promise."""
    await make_child(session, timezone="America/Detroit")
    await _library(session)
    await session.commit()

    instant = dt.datetime(2026, 8, 22, 9, 0, tzinfo=dt.UTC)
    first = await run_scheduler(session, as_of=instant, only_local_hour=5, seed=33)
    await session.commit()
    second = await run_scheduler(session, as_of=instant, only_local_hour=5, seed=34)
    await session.commit()

    assert first.created == 4  # question, mission, mission_b, weekly (a Saturday)
    assert second.created == 0


async def test_without_the_filter_every_child_is_served(session: AsyncSession) -> None:
    """`--any-hour` and `--date` are deliberate manual runs; the wall clock stops mattering."""
    await make_child(session, name="Miles", timezone="America/Detroit")
    await make_child(session, name="Kea", timezone="Pacific/Auckland")
    await _library(session)
    await session.commit()

    run = await run_scheduler(session, as_of=dt.datetime(2026, 8, 22, 9, 0, tzinfo=dt.UTC), seed=35)
    await session.commit()

    assert run.skipped_off_hour == 0
    served = set((await session.execute(sa.select(Assignment.child_id).distinct())).scalars().all())
    assert len(served) == 2


# --- The relaxation order, which docs/data-model.md fixes deliberately ------------------------


def test_the_cooldown_relaxes_before_the_age_window() -> None:
    """**A repeat is a mild annoyance; an age-inappropriate prompt is a broken product.**

    `docs/data-model.md` states the 180-day cooldown relaxes to 90 *before* the age window
    gives, and this fails if that order is ever inverted.

    The fixture makes the two mutually exclusive. There is exactly one prompt inside the
    child's age window and it was served 100 days ago — inside the 180-day cooldown, outside
    the relaxed 90-day one. There is exactly one prompt outside the age window and it has never
    been served, so it is what a scheduler that relaxed the age window first would reach for.
    """
    in_window = _aged_prompt(min_age_months=24, max_age_months=72)
    out_of_window = _aged_prompt(min_age_months=180, max_age_months=216)

    chosen = choose_prompt(
        [in_window, out_of_window],
        age_months=48,
        month=8,
        # Inside 180, outside 90. Only the relaxed cooldown can reach it.
        served_recently={in_window.id: 100},
        recent_themes=set(),
        rng=random.Random(0),
    )

    assert chosen is in_window, (
        "the age window relaxed before the cooldown did — a four-year-old was served a "
        "prompt written for a teenager rather than one they saw three months ago"
    )


def test_a_recent_prompt_still_beats_one_outside_the_age_window() -> None:
    """The stronger form: even with the cooldown fully dropped, age wins.

    Served yesterday, so it fails the 180-day and the 90-day cooldown alike and is only
    reachable at ladder 4 — which still filters on the age window. The out-of-window prompt is
    not reachable until ladder 5.
    """
    in_window = _aged_prompt(min_age_months=24, max_age_months=72)
    out_of_window = _aged_prompt(min_age_months=180, max_age_months=216)

    chosen = choose_prompt(
        [in_window, out_of_window],
        age_months=48,
        month=8,
        served_recently={in_window.id: 1},
        recent_themes=set(),
        rng=random.Random(0),
    )

    assert chosen is in_window


def _aged_prompt(*, min_age_months: int, max_age_months: int) -> Prompt:
    """An unsaved `Prompt` with an id, for the pure half of selection."""
    return Prompt(
        id=uuid.uuid4(),
        kind="question",
        cadence="daily",
        completion_mode="text",
        body="A question.",
        theme="everyday-ordinary",
        min_age_months=min_age_months,
        max_age_months=max_age_months,
        month_tags=[],
        source="seeded",
        active=True,
        content_hash=uuid.uuid4().hex,
    )


# --- The three-slot day --------------------------------------------------------------------


TUESDAY = dt.date(2026, 8, 18)


async def _every_daily_kind(session: AsyncSession) -> None:
    """A daily prompt of every kind, so a slot drawing the wrong one has somewhere wrong to go.

    This is the point of the fixture: if `mission` could return a video, this pool contains a
    video for it to return. A pool holding only photos would make the purity tests below pass
    against any implementation at all.
    """
    for index in range(4):
        await make_prompt(session, kind="question", theme=f"q-{index}")
        await make_prompt(session, kind="photo", completion_mode="media", theme=f"p-{index}")
        await make_prompt(session, kind="video", completion_mode="media", theme=f"v-{index}")
        await make_prompt(session, kind="audio", completion_mode="media", theme=f"a-{index}")
        await make_prompt(session, kind="activity", completion_mode="did_it", theme=f"x-{index}")


async def test_an_ordinary_tuesday_creates_three_assignments_one_per_slot(
    session: AsyncSession,
) -> None:
    """Not a Saturday, not the 1st, not the 15th. Three, and one of each."""
    child = await make_child(session)
    await _every_daily_kind(session)
    await session.commit()

    run = await run_scheduler(session, as_of_date=TUESDAY, seed=3)
    await session.commit()

    assert run.created == 3
    assert run.exhausted == []

    rows = (
        (
            await session.execute(
                sa.select(Assignment.slot).where(
                    Assignment.child_id == child.id, Assignment.assigned_on == TUESDAY
                )
            )
        )
        .scalars()
        .all()
    )
    assert sorted(rows) == ["mission", "mission_b", "question"]


async def test_the_mission_slot_never_serves_a_non_photo_kind(session: AsyncSession) -> None:
    """200 draws against a pool that contains every kind it must not return."""
    child = await make_child(session)
    await _every_daily_kind(session)
    await session.commit()

    kinds = set()
    for seed in range(200):
        prompt = await select_prompt(child, "mission", TUESDAY, session, rng=random.Random(seed))
        assert prompt is not None, f"seed {seed} produced no prompt at all"
        kinds.add(prompt.kind)

    assert kinds == {"photo"}, f"the mission slot served: {sorted(kinds)}"


async def test_the_mission_b_slot_never_serves_a_photo_or_a_question(
    session: AsyncSession,
) -> None:
    """The same 200 draws, from the other side of the split."""
    child = await make_child(session)
    await _every_daily_kind(session)
    await session.commit()

    kinds = set()
    for seed in range(200):
        prompt = await select_prompt(child, "mission_b", TUESDAY, session, rng=random.Random(seed))
        assert prompt is not None, f"seed {seed} produced no prompt at all"
        kinds.add(prompt.kind)

    assert kinds <= {"video", "audio", "activity"}, f"mission_b served: {sorted(kinds)}"
    assert "photo" not in kinds
    assert "question" not in kinds
    # And it can actually reach all three, so this is not passing because one kind dominates.
    assert kinds == {"video", "audio", "activity"}


async def test_an_empty_photo_pool_empties_mission_without_touching_the_others(
    session: AsyncSession,
) -> None:
    """The thin-pool case, which is the one the real library is closest to.

    A slot with nothing eligible is left empty and logged — never filled with a fallback from
    another kind. The other two slots are unaffected, because an exhausted slot must not take
    the day down with it.
    """
    child = await make_child(session)
    await make_prompt(session, kind="question", theme="q")
    await make_prompt(session, kind="audio", completion_mode="media", theme="a")
    # Deliberately no daily photo prompt at all.
    await session.commit()

    run = await run_scheduler(session, as_of_date=TUESDAY, seed=5)
    await session.commit()

    assert run.created == 2
    assert run.exhausted == [f"{child.id}:mission"]

    rows = dict(
        (
            await session.execute(
                sa.select(Assignment.slot, Prompt.kind)
                .join(Prompt, Prompt.id == Assignment.prompt_id)
                .where(Assignment.child_id == child.id, Assignment.assigned_on == TUESDAY)
            )
        ).all()
    )
    assert set(rows) == {"question", "mission_b"}
    assert rows["question"] == "question"
    assert rows["mission_b"] == "audio"


# --- The slot name lives in five places, so nothing may drift ------------------------------


def test_every_registry_keyed_by_slot_covers_every_slot() -> None:
    """`mission_b` had to be added to five separate places, and a sixth would be easy to miss.

    `constants.SLOTS` is the list; `SLOT_SPECS` says what each slot draws; `SERVE_INTERVAL_DAYS`
    says how often it is served; `NOTIFICATION_SLOT_PRIORITY` says which one a notification
    carries. A slot missing from the first two is a `KeyError` in production. Missing from the
    third is worse — `.get(slot, 1)` returns a plausible wrong answer and the pool report is
    quietly incorrect. Missing from the fourth is a silent fallback to "first pending item".

    This is the test that fails when slot number seven is added to only some of them.
    """
    from rascal.constants import NOTIFICATION_SLOT_PRIORITY, SLOTS
    from rascal.services.pool_health import SERVE_INTERVAL_DAYS
    from rascal.services.scheduler import SLOT_SPECS

    assert set(SLOT_SPECS) == set(SLOTS), "SLOT_SPECS and constants.SLOTS disagree"
    assert set(SERVE_INTERVAL_DAYS) == set(SLOTS), "SERVE_INTERVAL_DAYS and SLOTS disagree"
    assert set(NOTIFICATION_SLOT_PRIORITY) == set(SLOTS), "the push ladder is missing a slot"


def test_slots_for_never_invents_a_slot_the_schema_would_reject() -> None:
    """Every value `slots_for` can produce, over a whole year, has to be a known slot.

    The database's CHECK constraint is the backstop and it would reject an unknown value with
    an IntegrityError at 5am. This catches it at a keystroke instead.
    """
    from rascal.constants import SLOTS

    day = dt.date(2026, 1, 1)
    produced: set[str] = set()
    while day < dt.date(2027, 1, 1):
        produced.update(slots_for(day))
        day += dt.timedelta(days=1)

    assert produced <= set(SLOTS), f"slots_for produced unknown slots: {produced - set(SLOTS)}"
    # And over a year it should actually exercise all six, or this proves less than it looks.
    assert produced == set(SLOTS)


async def test_the_debug_board_route_can_serve_one_of_every_kind(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The local fixture route that the iOS build uses to exercise every capture path.

    It had no test and a hardcoded list of three "spare" slots, which meant it could not place
    five kinds and knew nothing about `mission_b`. The slot list is derived from `SLOTS` now, so
    this asserts the whole default board lands rather than that a particular spread does — the
    spread is an implementation detail, one-assignment-per-kind is the promise.
    """
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    for kind in ("question", "photo", "video", "audio", "activity"):
        await make_prompt(session, kind=kind, cadence="daily", theme=f"t-{kind}")
    await session.commit()

    response = await client.post(
        "/v1/debug/board",
        json={"child_id": str(child.id)},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["unavailable"] == [], "every default kind should have found a home"
    assert sorted(body["created"]) == ["activity", "audio", "photo", "question", "video"]

    rows = (
        (await session.execute(sa.select(Assignment.slot).where(Assignment.child_id == child.id)))
        .scalars()
        .all()
    )
    # Five kinds, five distinct slots — the unique index is what forces the spread.
    assert len(rows) == 5
    assert len(set(rows)) == 5
