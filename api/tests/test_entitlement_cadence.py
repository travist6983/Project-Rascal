"""Phase 107. The trial, the entitlement gate, and the weekday cadence.

Three things arrived together and they are tested together because they are one behaviour: a
household is entitled or it is not, the calendar says what a day holds, and `GET /today`
serves the intersection.

**The load-bearing property in this file is the cooldown one** —
`test_a_free_households_day_does_not_burn_the_cooldown`. A served prompt writes an assignment
and consumes 180 days against a 133-prompt pool, so filling slots a free parent can never see
would spend their runway invisibly and hand them repeats on the day they subscribe. Every
other test here would survive a refactor that broke that one, which is why it is called out.

**What is asserted elsewhere and deliberately not repeated:** that `entitlements.tier` has
exactly one writer lives in `test_app_store.py::test_tier_has_exactly_one_writer` and is
untouched by this phase — the trial is a column beside `tier`, not a value inside it, and if
that test ever fails the trial has been written wrong.
"""

from __future__ import annotations

import ast
import datetime as dt
import pathlib
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import (
    grant,
    make_assignment,
    make_child,
    make_device,
    make_family,
    make_prompt,
    make_user,
)
from helpers import auth_headers
from rascal.constants import DAILY_SLOTS, FREE_SLOTS, LOCKED_KIND_HINTS, SLOTS, TRIAL_DAYS
from rascal.models import Assignment, Entitlement, Prompt
from rascal.services.dates import local_date, zone
from rascal.services.guardians import access_for, eligible_at
from rascal.services.scheduler import _active_parents as active_parents
from rascal.services.scheduler import (
    ensure_day_filled,
    locked_slots_for,
    run_scheduler,
    select_prompt,
    slots_for,
)

# One of each weekday, all in the same week, none of them the 1st or the 15th — so every
# assertion below is about the rotation and never about a monthly or a letter riding along.
MONDAY = dt.date(2026, 8, 17)  # future-date: explicit, pure
TUESDAY = dt.date(2026, 8, 18)  # future-date: explicit, pure
WEDNESDAY = dt.date(2026, 8, 19)  # future-date: explicit, pure
THURSDAY = dt.date(2026, 8, 20)  # future-date: explicit, pure
FRIDAY = dt.date(2026, 8, 21)  # future-date: explicit, pure
SATURDAY = dt.date(2026, 8, 22)  # future-date: explicit, pure
SUNDAY = dt.date(2026, 8, 23)  # future-date: explicit, pure

# A Saturday that is also the 1st: the worst day the calendar can produce, and the one
# `data-model.md` states the ceiling from.
SATURDAY_THE_FIRST = dt.date(2026, 8, 1)  # future-date: explicit, pure

# UTC+13 in August (Auckland is on NZST, UTC+12, in August — Kiritimati is the reliable one).
# Any zone a whole calendar day off UTC will do; what matters is that the *weekday* differs.
AHEAD = "Pacific/Kiritimati"
BEHIND = "Pacific/Midway"
AUCKLAND = "Pacific/Auckland"
DETROIT = "America/Detroit"


def _yesterday() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC) - dt.timedelta(days=1)


def _next_month() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=30)


async def _pool(session: AsyncSession) -> None:
    """Enough library that every slot a day can ask for has a candidate.

    Deliberately more than one kind per slot: a pool holding only questions would make the
    "a free household gets exactly one item" tests pass against any implementation at all.
    """
    await make_prompt(session, kind="question", cadence="daily", completion_mode="text")
    await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    await make_prompt(session, kind="audio", cadence="daily", completion_mode="media")
    await make_prompt(session, kind="activity", cadence="daily", completion_mode="did_it")
    await make_prompt(session, kind="activity", cadence="weekly", completion_mode="did_it")
    await make_prompt(session, kind="measurement", cadence="monthly", completion_mode="text")
    await make_prompt(session, kind="letter", cadence="monthly", completion_mode="text")


async def _household(
    session: AsyncSession,
    *,
    tier: str = "free",
    trial_ends_at: object,
    timezone: str = DETROIT,
):
    """A one-parent household with a child and a full pool, in a named entitlement state."""
    family = await make_family(session, tier=tier, trial_ends_at=trial_ends_at)
    user = await make_user(session, family=family)
    child = await make_child(session, parent=user, timezone=timezone)
    await _pool(session)
    await session.commit()
    return user, child


def _slots(items: list[dict]) -> set[str]:
    return {item["slot"] for item in items}


async def _rows(session: AsyncSession, child_id, on: dt.date) -> list[Assignment]:
    """Every assignment row for one child on one day, ordered so a failure reads cleanly."""
    result = await session.execute(
        sa.select(Assignment)
        .where(Assignment.child_id == child_id, Assignment.assigned_on == on)
        .order_by(Assignment.slot)
    )
    return list(result.scalars().all())


# --- Task 1: the trial is a column, and `access` is computed from it ---------------------------


async def test_a_family_inside_its_trial_reads_trial_and_gets_the_whole_day(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 1. Fourteen days of everything, on a `free` tier."""
    user, child = await _household(session, trial_ends_at=_next_month())

    body = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY.isoformat()}",
            headers=auth_headers(user),
        )
    ).json()

    assert body["access"] == "trial"
    assert body["trial_ends_at"] is not None
    assert body["locked"] == []

    # And the board itself, through the write path, so "the whole day" means the rows exist.
    await ensure_day_filled(session, child, SATURDAY)
    await session.commit()
    assert {row.slot for row in await _rows(session, child.id, SATURDAY)} == set(
        slots_for(SATURDAY)
    )


async def test_a_new_household_starts_in_a_trial_rather_than_on_the_free_tier(
    session: AsyncSession,
) -> None:
    """The column defaults on the model, so **every** creator gets it — including the ones
    written after this phase, which is the point of putting it there rather than in
    `create_household`."""
    from rascal.services.guardians import create_household

    family = await create_household(session)
    await session.commit()

    entitlement = await session.get(Entitlement, family.id)
    assert entitlement is not None
    assert entitlement.trial_ends_at is not None
    expected = dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=TRIAL_DAYS)
    assert abs((entitlement.trial_ends_at - expected).total_seconds()) < 120
    assert access_for(entitlement).access == "trial"
    # The tier is untouched, which is the whole design.
    assert entitlement.tier == "free"


async def test_a_lapsed_trial_on_a_free_tier_reads_free(session: AsyncSession) -> None:
    entitlement = Entitlement(tier="free", trial_ends_at=_yesterday())
    access = access_for(entitlement)
    assert access.access == "free"
    assert access.entitled is False


async def test_a_cleared_trial_reads_free_rather_than_erroring(session: AsyncSession) -> None:
    """`null` is a real value: a household with no trial, which is what the admin lever's
    Clear button produces. It must not be mistaken for a missing row."""
    access = access_for(Entitlement(tier="free", trial_ends_at=None))
    assert access.access == "free"
    assert access.trial_ends_at is None


async def test_a_subscribed_household_with_a_past_trial_is_still_entitled(
    session: AsyncSession,
) -> None:
    """Requirement 3, and its mirror: `subscribed` beats `trial` in both directions."""
    lapsed_trial = access_for(Entitlement(tier="subscribed", trial_ends_at=_yesterday()))
    assert lapsed_trial.entitled is True
    assert lapsed_trial.access == "subscribed"

    stale_future_trial = access_for(Entitlement(tier="subscribed", trial_ends_at=_next_month()))
    assert stale_future_trial.access == "subscribed", (
        "a paying household must never be rendered as one on a countdown"
    )


async def test_a_trial_expiring_leaves_lapsed_at_and_eligible_at_null(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 4, and it is the one with photographs behind it.

    `lapsed_at` is about a *subscription* ending, per D3, and `eligible_at` is the media
    deletion clock computed from it. A trial quietly running out must start neither — a
    household that tried the app for a fortnight and stopped has not lapsed, and pointing a
    deletion timer at them would be this phase deleting somebody's archive by arithmetic.
    """
    user, _child = await _household(session, trial_ends_at=_yesterday())
    entitlement = await session.get(Entitlement, user.family_id)
    assert entitlement is not None

    assert access_for(entitlement).access == "free"
    assert entitlement.lapsed_at is None
    assert eligible_at(entitlement.tier, entitlement.lapsed_at, dt.datetime.now(tz=dt.UTC)) is None

    body = (
        await client.get(f"/v1/families/{user.family_id}/entitlement", headers=auth_headers(user))
    ).json()
    assert body["access"] == "free"
    assert body["lapsed_at"] is None
    assert body["eligible_at"] is None


async def test_the_two_family_routes_and_today_report_one_answer(
    client: AsyncClient, session: AsyncSession
) -> None:
    """One authority, three shapes. Three routes that computed it separately is the bug."""
    user, child = await _household(session, trial_ends_at=_next_month())
    headers = auth_headers(user)

    me = (await client.get("/v1/families/me", headers=headers)).json()
    entitlement = (
        await client.get(f"/v1/families/{user.family_id}/entitlement", headers=headers)
    ).json()
    today = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()

    assert me["access"] == entitlement["access"] == today["access"] == "trial"
    assert me["trial_ends_at"] == entitlement["trial_ends_at"] == today["trial_ends_at"]
    # `tier` is additive-safe: unchanged meaning, unchanged values.
    assert me["tier"] == entitlement["tier"] == "free"


#: The one function allowed to know how a trial turns into an entitlement.
THE_ONE_AUTHORITY = ("services/guardians.py", "access_for")


def _comparisons_touching(src: pathlib.Path, name: str) -> list[str]:
    """Every `<`/`>`/`<=`/`>=` comparison anywhere under `src` that reads `.<name>`.

    **Parsed rather than grepped, and the difference is the whole point of the test.** A regex
    over lines is defeated by anything the author happens to write differently — a comparison
    split across two lines by the formatter, an intermediate variable, `x > y` instead of
    `y < x`, or a walrus. Every one of those is a second entitlement authority and every one of
    them slips past a line-oriented pattern. The AST sees the comparison whatever it looks like.
    """
    found: list[str] = []
    for path in sorted(src.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        # Which function each node sits inside, so a failure names it rather than a line number.
        enclosing: dict[ast.AST, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
                for child in ast.walk(node):
                    enclosing.setdefault(child, node.name)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Compare):
                continue
            if not any(isinstance(op, ast.Lt | ast.LtE | ast.Gt | ast.GtE) for op in node.ops):
                continue
            operands = [node.left, *node.comparators]
            reads_it = any(
                isinstance(sub, ast.Attribute) and sub.attr == name
                for operand in operands
                for sub in ast.walk(operand)
            )
            if reads_it:
                where = enclosing.get(node, "<module>")
                found.append(f"{path.relative_to(src)}::{where}:{node.lineno}")
    return found


def test_nothing_else_in_src_recomputes_the_entitlement_formula() -> None:
    """**The adversarial one, and it is aimed at the failure the phase prompt named.**

    An entitlement check copied into a second place is the one that eventually disagrees with
    the first about whether somebody paid — and the disagreement is silent, because both
    answers look reasonable.

    So: **exactly one ordering comparison against `.trial_ends_at` may exist anywhere in
    `src/`**, and it must be inside `services/guardians.access_for`. Anything else — a router
    deciding for itself, a job with its own opinion, a metric that "just needs a boolean" — is
    a second authority and fails here.

    Deliberately an AST walk rather than a grep. A line-oriented pattern is defeated by a
    comparison the formatter split across two lines, by an intermediate variable, or by writing
    the operands the other way round; all three are the same defect and none of them would have
    tripped a regex. See :func:`_comparisons_touching`.
    """
    src = pathlib.Path(__file__).resolve().parents[1] / "src" / "rascal"
    sites = _comparisons_touching(src, "trial_ends_at")

    assert len(sites) == 1, (
        "exactly one place may compare `trial_ends_at` against a clock, and it is "
        f"{THE_ONE_AUTHORITY[0]}::{THE_ONE_AUTHORITY[1]}. Found: " + ", ".join(sites)
    )
    module, function = sites[0].split("::")[0], sites[0].split("::")[1].rsplit(":", 1)[0]
    assert (module, function) == THE_ONE_AUTHORITY, (
        f"the one authority moved to {module}::{function}; it must stay "
        f"{THE_ONE_AUTHORITY[0]}::{THE_ONE_AUTHORITY[1]}"
    )


def test_the_ast_walk_would_actually_catch_a_second_authority() -> None:
    """**A test for the test**, because a tripwire that cannot fire is worse than none.

    `test_nothing_else_in_src_recomputes_the_entitlement_formula` is the only thing standing
    between this codebase and a second opinion about whether somebody paid. If it silently
    stopped matching — a rename, a refactor, an over-narrowed walk — it would go on passing
    forever while the thing it guards rotted.

    So it is exercised against four shapes a real second authority could take, including the
    three a line-oriented grep would have missed.
    """
    import tempfile

    shapes = {
        "the obvious copy": (
            "def f(e, now):\n    return e.trial_ends_at is not None and now < e.trial_ends_at\n"
        ),
        "operands reversed": "def f(e, now):\n    return e.trial_ends_at > now\n",
        "split by the formatter": (
            "def f(entitlement, now):\n"
            "    return (\n"
            "        now\n"
            "        < entitlement.trial_ends_at\n"
            "    )\n"
        ),
        "inside a comprehension": (
            "def f(rows, now):\n    return [r for r in rows if r.trial_ends_at >= now]\n"
        ),
    }
    for label, source in shapes.items():
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "impostor.py").write_text(source)
            assert _comparisons_touching(root, "trial_ends_at"), (
                f"the AST walk would not have caught a second authority written as: {label}"
            )

    # And it does not fire on something that merely mentions the attribute.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "innocent.py").write_text(
            "def f(e):\n"
            "    #: a comment about e.trial_ends_at < now\n"
            '    """A docstring mentioning trial_ends_at."""\n'
            "    return {'trial_ends_at': e.trial_ends_at, 'same': e.trial_ends_at == None}\n"
        )
        assert _comparisons_touching(root, "trial_ends_at") == [], (
            "the AST walk fires on a read that is not an ordering comparison"
        )


# --- Task 2: the weekday rotation --------------------------------------------------------------


def test_monday_wednesday_and_friday_carry_the_photo_mission() -> None:
    """Requirement 6, first third."""
    for day in (MONDAY, WEDNESDAY, FRIDAY):
        assert slots_for(day) == ["question", "mission"], f"{day:%A} {day}"


def test_tuesday_and_thursday_carry_the_other_mission() -> None:
    """Requirement 6, second third. **The pools did not widen** — `mission_b` is still
    video/audio/activity and `mission` is still photo-only, per decisions.md row 112. Only
    which day serves which moved."""
    for day in (TUESDAY, THURSDAY):
        assert slots_for(day) == ["question", "mission_b"], f"{day:%A} {day}"


def test_the_weekend_carries_both_missions() -> None:
    assert slots_for(SUNDAY) == ["question", "mission", "mission_b"]
    assert slots_for(SATURDAY) == ["question", "mission", "mission_b", "weekly"]


def test_a_saturday_that_is_also_the_first_is_still_the_five_item_ceiling() -> None:
    """Requirement 6, last third, and the sentence in `data-model.md` it pins.

    The rotation lowered the floor without moving the ceiling. Five is still the worst the
    calendar can do, and it is still a Saturday that is also the 1st or the 15th.
    """
    assert SATURDAY_THE_FIRST.weekday() == 5, "the fixture must actually be a Saturday"
    assert SATURDAY_THE_FIRST.day == 1, "the fixture must actually be the 1st"

    slots = slots_for(SATURDAY_THE_FIRST)
    assert slots == ["question", "mission", "mission_b", "weekly", "monthly"]
    assert len(slots) == 5

    # And nothing anywhere in the calendar beats it. 400 years covers every leap rule.
    day = dt.date(2026, 1, 1)
    worst = max(len(slots_for(day + dt.timedelta(days=n))) for n in range(366 * 4))
    assert worst == 5


def test_every_day_of_the_year_carries_the_question_and_never_two_missions_on_a_weekday() -> None:
    """The floor and the shape, asserted over a whole year rather than seven fixtures."""
    day = dt.date(2026, 1, 1)
    for offset in range(365):
        on = day + dt.timedelta(days=offset)
        slots = slots_for(on)
        assert slots[0] == "question", f"{on} does not lead with the question"
        assert slots.count("question") == 1
        daily = [slot for slot in slots if slot in DAILY_SLOTS]
        expected = 3 if on.weekday() >= 5 else 2
        assert len(daily) == expected, f"{on:%A} {on} produced {daily}"


async def test_the_weekday_is_read_in_the_childs_family_timezone(session: AsyncSession) -> None:
    """Requirement 7, and it is asserted through the scheduler's **real entry point**.

    `run_scheduler(as_of=<instant>)` is what `python -m rascal.jobs.scheduler` calls with the
    wall clock; the date each child gets is that instant read in their own zone. A Saturday in
    Auckland is a Friday in UTC and the parent is entitled to the Saturday.

    Every adjacent pair of weekdays produces a different slot list under the rotation, so a
    zone one calendar day off UTC always produces a *different day's board* — which is what
    makes this deterministic whenever it runs rather than only on the days it happens to work.
    """
    ahead_user = await make_user(session)
    ahead_child = await make_child(session, name="Ahead", parent=ahead_user, timezone=AHEAD)
    behind_user = await make_user(session)
    behind_child = await make_child(session, name="Behind", parent=behind_user, timezone=BEHIND)
    await _pool(session)
    await session.commit()

    instant = dt.datetime.now(tz=dt.UTC)
    ahead_date = local_date(instant, AHEAD)
    behind_date = local_date(instant, BEHIND)
    assert ahead_date != behind_date, (
        "the two fixture zones must straddle a date boundary, or this proves nothing"
    )

    await run_scheduler(session, as_of=instant)
    await session.commit()

    for child, on in ((ahead_child, ahead_date), (behind_child, behind_date)):
        rows = await _rows(session, child.id, on)
        assert {row.slot for row in rows} == set(slots_for(on)), (
            f"{child.name} ({child.family_timezone}) did not get {on:%A}'s board"
        )
        # And nothing was written for UTC's date when it is not this child's date.
        if on != instant.date():
            assert await _rows(session, child.id, instant.date()) == [], (
                f"{child.name} got a board for UTC's date rather than their own"
            )


async def test_an_auckland_saturday_is_not_a_utc_friday(session: AsyncSession) -> None:
    """The example the requirement names, pinned to a fixed instant so it cannot drift.

    2026-08-21T12:00Z is a Friday. In Pacific/Auckland (UTC+12 in August) it is already
    Saturday the 22nd, and a Saturday carries `weekly` — which a Friday does not.
    """
    instant = dt.datetime(2026, 8, 21, 12, 0, tzinfo=dt.UTC)  # future-date: explicit, pure
    assert instant.weekday() == 4, "the fixture instant must be a Friday in UTC"
    assert local_date(instant, AUCKLAND) == dt.date(2026, 8, 22)  # future-date: explicit, pure

    auckland_user = await make_user(session)
    auckland = await make_child(session, name="Kea", parent=auckland_user, timezone=AUCKLAND)
    detroit_user = await make_user(session)
    detroit = await make_child(session, name="Miles", parent=detroit_user, timezone=DETROIT)
    await _pool(session)
    await session.commit()

    await run_scheduler(session, as_of=instant)
    await session.commit()

    saturday = await _rows(session, auckland.id, dt.date(2026, 8, 22))  # future-date: explicit
    friday = await _rows(session, detroit.id, dt.date(2026, 8, 21))  # future-date: explicit
    assert {row.slot for row in saturday} == {"question", "mission", "mission_b", "weekly"}
    assert {row.slot for row in friday} == {"question", "mission"}


# --- Task 3: locked slots are not filled -------------------------------------------------------


async def test_a_free_households_scheduler_run_writes_one_row_for_the_day(
    session: AsyncSession,
) -> None:
    """Requirement 8, first half."""
    _user, child = await _household(session, trial_ends_at=_yesterday())

    run = await run_scheduler(session, as_of_date=SATURDAY, child_id=child.id, seed=1)
    await session.commit()

    assert run.created == 1
    rows = await _rows(session, child.id, SATURDAY)
    assert [row.slot for row in rows] == ["question"], (
        "a free household's Saturday must write the question and nothing else"
    )


async def test_a_free_households_day_does_not_burn_the_cooldown(session: AsyncSession) -> None:
    """**Requirement 8, and the property a later refactor will break.**

    A served prompt writes an assignment and consumes the 180-day cooldown against a
    133-prompt pool. Filling slots a free parent can never see would spend their runway
    invisibly — and the day they subscribe they would be served repeats immediately.

    So: run a free household's scheduler over a stretch of days, then subscribe them, and
    assert every photo prompt in the pool is still reachable. "Fill it but hide it" fails
    here and passes almost everything else in this file.
    """
    _user, child = await _household(session, trial_ends_at=_yesterday())
    photos = [
        await make_prompt(
            session, kind="photo", cadence="daily", completion_mode="media", theme=f"p-{n}"
        )
        for n in range(4)
    ]
    await session.commit()

    # Ten days of a free household. Under a "fill it and hide it" implementation this is ten
    # `mission` picks, and a four-prompt pool would be exhausted several times over.
    for offset in range(10):
        await run_scheduler(
            session, as_of_date=MONDAY + dt.timedelta(days=offset), child_id=child.id, seed=offset
        )
    await session.commit()

    served = (
        (await session.execute(sa.select(Assignment.slot).where(Assignment.child_id == child.id)))
        .scalars()
        .all()
    )
    assert set(served) == {"question"}, f"a locked slot was filled: {sorted(set(served))}"

    # Nothing in the photo pool has been touched, so every one of them is still a candidate —
    # today, not in 181 days. That is the runway the gate is protecting.
    photo_ids = [prompt.id for prompt in photos]
    burned = await session.scalar(
        sa.select(sa.func.count())
        .select_from(Assignment)
        .where(Assignment.child_id == child.id, Assignment.prompt_id.in_(photo_ids))
    )
    assert burned == 0

    picked = set()
    for seed in range(40):
        import random

        prompt = await select_prompt(
            child, "mission", MONDAY + dt.timedelta(days=10), session, rng=random.Random(seed)
        )
        assert prompt is not None
        picked.add(prompt.id)
    assert picked == {p.id for p in photos}, (
        "a prompt the free household never saw is on cooldown, which means it was served"
    )


async def test_the_cooldown_is_still_intact_181_days_later(session: AsyncSession) -> None:
    """Requirement 8's own wording, asserted literally: the prompts that would have gone to
    `mission` and `mission_b` are still available to the household 181 days on.

    The 181 matters because 180 is the cooldown. A prompt served on day 0 is outside it on day
    181 — so a test that only looked *after* the window would pass even if every prompt had
    been burned. This looks at whether an assignment row exists at all.
    """
    _user, child = await _household(session, trial_ends_at=_yesterday())
    await run_scheduler(session, as_of_date=MONDAY, child_id=child.id, seed=2)
    await session.commit()

    later = MONDAY + dt.timedelta(days=181)
    mission = await select_prompt(child, "mission", later, session)
    mission_b = await select_prompt(child, "mission_b", later, session)
    assert mission is not None and mission.kind == "photo"
    assert mission_b is not None and mission_b.kind in ("video", "audio", "activity")

    # And the far more interesting version: they are available on day 1, because they were
    # never served in the first place.
    assert await select_prompt(child, "mission", MONDAY + dt.timedelta(days=1), session) is not None


async def test_a_household_that_subscribes_mid_day_gets_its_missions_on_the_next_read(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 9. **The read repairs the day it finds**, which is what makes the scheduler
    an optimisation rather than a dependency — and what makes subscribing feel immediate
    rather than "come back tomorrow"."""
    user, child = await _household(session, trial_ends_at=_yesterday())
    headers = auth_headers(user)

    before = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert before["access"] == "free"
    assert _slots(before["today"]) == set(FREE_SLOTS)
    assert before["locked"], "a free household's day must report what it is missing"

    # The lever the admin console pulls, and the same thing a webhook flipping `tier` reaches.
    entitlement = await session.get(Entitlement, user.family_id)
    assert entitlement is not None
    entitlement.trial_ends_at = _next_month()
    await session.commit()

    after = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert after["access"] == "trial"
    assert after["locked"] == []
    local_today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    assert _slots(after["today"]) == set(slots_for(local_today)), (
        "the read did not repair the day it found"
    )


# --- Task 4: `/today` reports what is locked ---------------------------------------------------


async def test_a_free_household_gets_one_item_and_the_rest_of_the_day_in_locked(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 2."""
    user, child = await _household(session, trial_ends_at=_yesterday())

    body = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY.isoformat()}",
            headers=auth_headers(user),
        )
    ).json()

    assert body["access"] == "free"
    assert len(body["today"]) <= 1
    assert _slots(body["today"]) <= set(FREE_SLOTS)
    assert [item["slot"] for item in body["locked"]] == ["mission", "mission_b", "weekly"]


async def test_locked_is_an_empty_list_for_an_entitled_household_and_never_absent(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 11. A value, not an inference from a missing key."""
    for tier, trial in (("free", _next_month()), ("subscribed", _yesterday())):
        user, child = await _household(session, tier=tier, trial_ends_at=trial)
        body = (
            await client.get(
                f"/v1/children/{child.id}/today?date={SATURDAY.isoformat()}",
                headers=auth_headers(user),
            )
        ).json()
        assert "locked" in body, f"{tier}: `locked` must always be present"
        assert body["locked"] == [], f"{tier}: an entitled household locks nothing"


async def test_a_locked_item_carries_no_prompt_no_id_and_no_theme(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The leak test.** `locked[]` is the shape of the thing, not a teaser for it.

    Serving the body would mean *picking* a prompt — which burns the cooldown this phase
    exists to protect — and D7 calls the mission library the one asset a competitor would
    actually want. Asserted as an exact key set so a field cannot be added by accident.
    """
    user, child = await _household(session, trial_ends_at=_yesterday())
    bodies = {
        prompt.body for prompt in ((await session.execute(sa.select(Prompt))).scalars().all())
    }

    body = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY.isoformat()}",
            headers=auth_headers(user),
        )
    ).json()

    assert body["locked"]
    for item in body["locked"]:
        assert set(item) == {"slot", "kind_hint"}, f"a locked item grew a field: {sorted(item)}"

    rendered = str(body["locked"])
    for prompt_body in bodies:
        assert prompt_body not in rendered, "a locked slot leaked the copy it is withholding"


async def test_locked_slots_are_ordered_by_the_calendar_and_deterministically(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The iOS lane renders server order and does not sort, so the order is a contract rather
    than an emergent property. Daily doing-slots first, then the occasional ones in the order
    the calendar fires them."""
    user, child = await _household(session, trial_ends_at=_yesterday())
    headers = auth_headers(user)

    saturday_the_first = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY_THE_FIRST.isoformat()}",
            headers=headers,
        )
    ).json()
    assert [item["slot"] for item in saturday_the_first["locked"]] == [
        "mission",
        "mission_b",
        "weekly",
        "monthly",
    ]

    # Twice, byte-identical: nothing in the path is a set or a database ordering.
    again = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY_THE_FIRST.isoformat()}",
            headers=headers,
        )
    ).json()
    assert again["locked"] == saturday_the_first["locked"]


async def test_the_kind_hint_covers_every_lockable_slot() -> None:
    """A slot added to the calendar without a hint would 500 the whole board, so the mapping
    is asserted as total rather than as a lookup that happens to work today."""
    lockable = [slot for slot in SLOTS if slot not in FREE_SLOTS]
    assert set(LOCKED_KIND_HINTS) == set(lockable)
    assert LOCKED_KIND_HINTS["mission"] == "photo"
    assert LOCKED_KIND_HINTS["mission_b"] == "mission"
    for slot in ("weekly", "monthly", "letter"):
        assert LOCKED_KIND_HINTS[slot] == slot
    assert "question" not in LOCKED_KIND_HINTS, "a question is never locked"


def test_locked_slots_for_is_the_complement_of_the_free_tier() -> None:
    """Computed from `slots_for`, so a slot cannot be added to a day and forgotten here."""
    for day in (MONDAY, TUESDAY, SATURDAY, SATURDAY_THE_FIRST):
        assert locked_slots_for(day, entitled=True) == []
        assert locked_slots_for(day, entitled=False) == [
            slot for slot in slots_for(day) if slot not in FREE_SLOTS
        ]


async def test_a_locked_slot_never_appears_in_waiting(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Requirement 10, and the exclusion is in the query rather than in the absence of rows.

    A household that lapsed **has** pending mission rows from when it was entitled, so relying
    on the scheduler not having written any would be relying on the scheduler having run since
    the lapse — exactly the dependency the read path is not allowed to have.
    """
    user, child = await _household(session, trial_ends_at=_yesterday())
    photo = await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    weekly = await make_prompt(session, kind="activity", cadence="weekly", completion_mode="did_it")
    yesterday = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone) - dt.timedelta(days=1)

    # Rows from before the lapse: pending, in the past, exactly what `waiting` collects.
    stale_mission = await make_assignment(
        session, child, photo, slot="mission", assigned_on=yesterday, user=user
    )
    stale_weekly = await make_assignment(
        session, child, weekly, slot="weekly", assigned_on=yesterday
    )
    await session.commit()

    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()

    assert body["access"] == "free"
    assert _slots(body["waiting"]) <= set(FREE_SLOTS)
    ids = {item["id"] for item in body["waiting"] + body["today"]}
    assert str(stale_mission.id) not in ids
    assert str(stale_weekly.id) not in ids

    # **The rows are not deleted.** They stop being served and go on existing; D3 as narrowed
    # locks the day, not the archive, and the phase deliberately adds no cleanup for this.
    assert await session.get(Assignment, stale_mission.id) is not None
    assert await session.get(Assignment, stale_weekly.id) is not None


async def test_a_finished_mission_stays_on_the_board_after_a_lapse(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The narrowing of D3, asserted.** The archive is never locked; the day is.

    A parent who completed a mission this morning and lapsed at 2pm must not watch their own
    finished entry disappear. `done_today` is deliberately not filtered by entitlement.
    """
    user, child = await _household(session, trial_ends_at=_yesterday())
    photo = await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    done = await make_assignment(
        session, child, photo, slot="mission", assigned_on=today, status="done", user=user
    )
    await session.commit()

    entry = await client.post(
        "/v1/entries",
        headers=auth_headers(user),
        json={
            "id": str(__import__("uuid").uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(done.id),
            "body": "He built a tower.",
            "occurred_at": dt.datetime.now(tz=dt.UTC).isoformat().replace("+00:00", "Z"),
        },
    )
    assert entry.status_code in (200, 201), entry.text

    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()
    assert body["access"] == "free"
    assert str(done.id) in {item["id"] for item in body["done_today"]}, (
        "a free household lost sight of work it had already finished"
    )


# --- The leak the gate is really about ---------------------------------------------------------


async def test_a_lapsed_household_is_never_pushed_a_locked_missions_body(
    session: AsyncSession,
) -> None:
    """**The lock screen is the one surface a parent cannot dismiss without reading.**

    `ensure_day_filled` will not *create* a locked slot for a free household, so a household
    that has always been free is safe by construction. A household that **lapsed** is not: it
    still has the pending mission rows written while it was entitled, and
    `NOTIFICATION_SLOT_PRIORITY` puts the mission first on purpose — a nudge is for doing.

    Ungated, that pushes the body of a library prompt to a phone whose app correctly refuses
    to show it. A prompt on a lock screen with nothing behind it in the app is worse than no
    notification, and D7 calls the library the one asset a competitor would want.

    So the notification job reads the same one authority every other surface reads, and the
    only thing a free household can be sent is the question.
    """
    from rascal.services.notifications import run_notifications
    from rascal.services.push import StubPushClient

    family = await make_family(session, trial_ends_at=_yesterday())
    user = await make_user(
        session, family=family, notify_enabled=True, notify_local_time=dt.time(19, 0)
    )
    child = await make_child(session, parent=user, timezone=DETROIT)
    await make_device(session, user)
    question = await make_prompt(
        session, kind="question", cadence="daily", body="What did he say today?"
    )
    mission = await make_prompt(
        session,
        kind="photo",
        cadence="daily",
        completion_mode="media",
        body="Photograph the thing he built today.",
    )

    # The world a lapse leaves behind: both slots filled while entitled, both still pending.
    today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    await make_assignment(session, child, question, slot="question", assigned_on=today, user=user)
    await make_assignment(session, child, mission, slot="mission", assigned_on=today, user=user)
    await session.commit()

    at = dt.datetime.combine(today, dt.time(19, 5), tzinfo=zone(DETROIT)).astimezone(dt.UTC)
    push = StubPushClient()
    run = await run_notifications(session, client=push, as_of=at)
    await session.commit()

    assert run.sent == 1, "the free household should still get its question"
    assert len(push.sent) == 1
    assert push.sent[0].body == question.body
    assert mission.body not in push.sent[0].body, (
        "a locked mission's body reached a lock screen the app will not show it on"
    )


async def test_an_entitled_household_is_still_pushed_the_mission(
    session: AsyncSession,
) -> None:
    """The other half, so the test above cannot pass by breaking notifications outright."""
    from rascal.services.notifications import run_notifications
    from rascal.services.push import StubPushClient

    family = await make_family(session, trial_ends_at=_next_month())
    user = await make_user(
        session, family=family, notify_enabled=True, notify_local_time=dt.time(19, 0)
    )
    child = await make_child(session, parent=user, timezone=DETROIT)
    await make_device(session, user)
    await make_prompt(session, kind="question", cadence="daily", body="What did he say today?")
    mission = await make_prompt(
        session,
        kind="photo",
        cadence="daily",
        completion_mode="media",
        body="Photograph the thing he built today.",
    )
    today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    await make_assignment(session, child, mission, slot="mission", assigned_on=today, user=user)
    await session.commit()

    at = dt.datetime.combine(today, dt.time(19, 5), tzinfo=zone(DETROIT)).astimezone(dt.UTC)
    push = StubPushClient()
    run = await run_notifications(session, client=push, as_of=at)
    await session.commit()

    assert run.sent == 1
    assert push.sent[0].body == mission.body


# --- Task 5: the one admin lever ---------------------------------------------------------------


async def test_the_admin_lever_moves_a_household_between_free_and_trial(
    client: AsyncClient, session: AsyncSession
) -> None:
    """It exists because the owner is the only user and would otherwise never see the free
    tier he is designing."""
    user, _child = await _household(session, trial_ends_at=_next_month())
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()
    headers = auth_headers(admin)

    dropped = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=headers,
        json={"trial_ends_at": _yesterday().isoformat().replace("+00:00", "Z")},
    )
    assert dropped.status_code == 200, dropped.text
    assert dropped.json()["access"] == "free"
    assert dropped.json()["tier"] == "free", "the lever must not touch the tier"

    restored = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=headers,
        json={"trial_ends_at": _next_month().isoformat().replace("+00:00", "Z")},
    )
    assert restored.json()["access"] == "trial"

    cleared = await client.put(
        f"/v1/admin/families/{user.family_id}/trial", headers=headers, json={"trial_ends_at": None}
    )
    assert cleared.json()["access"] == "free"
    assert cleared.json()["trial_ends_at"] is None


async def test_an_offset_less_trial_date_is_refused_rather_than_crashing(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**A 422, not a 500**, and before the validator it was a 500.

    Pydantic parses `"2026-09-01T00:00:00"` into a naive `datetime`, `session.flush()` does not
    expire the attribute, and `access_for` then compares that naive value against an aware
    `now` — `TypeError`, rendered by the catch-all as `internal_error` with no field to point
    at, on the one route in this API a person is told to reach with `curl`.

    The console cannot produce it: `endOfDayIso` sends `toISOString()`. A human typing a
    timestamp can, easily, which is the whole reason this is a boundary guard rather than a
    normalisation inside the one authority — stamping a naive value with UTC would be this
    service inventing a timezone for something a person wrote.
    """
    user, _child = await _household(session, trial_ends_at=_next_month())
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()

    response = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=auth_headers(admin),
        json={"trial_ends_at": "2026-09-01T00:00:00"},  # future-date: explicit, and offset-less
    )

    assert response.status_code == 422, response.text
    body = response.json()
    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["field"] == "trial_ends_at"

    # And the household is untouched — the refusal happened before anything was written.
    entitlement = await session.get(Entitlement, user.family_id)
    await session.refresh(entitlement)
    assert access_for(entitlement).access == "trial"


async def test_an_offset_bearing_trial_date_in_any_zone_is_accepted(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The guard is about the *offset*, not about UTC. `+13:00` is a real thing a parent lives
    in and the console is not the only caller."""
    user, _child = await _household(session, trial_ends_at=_yesterday())
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()

    response = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=auth_headers(admin),
        json={"trial_ends_at": "2027-03-01T00:00:00+13:00"},  # future-date: explicit, pure
    )

    assert response.status_code == 200, response.text
    assert response.json()["access"] == "trial"


async def test_the_admin_lever_404s_on_a_household_that_does_not_exist(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**A typo is a 404, not a 500**, and before this test it was a 500.

    The lever takes a household id a human typed into a console. Routed through
    `entitlement_for` — which treats a missing row as an internal error, correctly, because
    every *other* caller reaches it through the caller's own `users.family_id` — a mistyped
    UUID became a 500 and made a `# pragma: no cover` branch reachable from an HTTP route.
    """
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()

    response = await client.put(
        f"/v1/admin/families/{uuid.uuid4()}/trial",
        headers=auth_headers(admin),
        json={"trial_ends_at": None},
    )
    assert response.status_code == 404, response.text
    assert response.json()["error"]["code"] == "not_found"


async def test_the_admin_lever_refuses_a_caller_who_is_not_an_admin(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`AdminUser` is the same gate the library has used since 0003 — reused, not reinvented."""
    user, _child = await _household(session, trial_ends_at=_next_month())
    response = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=auth_headers(user),
        json={"trial_ends_at": None},
    )
    assert response.status_code == 403


async def test_the_admin_lever_has_no_way_to_write_the_tier() -> None:
    """Pins the absence, the way phase 60 pinned the absence of a `subscribers` table.

    The console can reach both entitlement states without going near `tier`, and the day
    somebody adds a control that sets it they have to argue with D5 rather than around it.
    """
    from rascal.schemas.admin import AdminTrialIn

    assert set(AdminTrialIn.model_fields) == {"trial_ends_at"}


async def test_the_console_reports_access_beside_the_tier(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The lever needs a household to aim at, and a reader needs to see which state it is in.
    `tier` and `access` answer different questions and the console shows both."""
    user, _child = await _household(session, trial_ends_at=_next_month())
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()

    body = (await client.get("/v1/admin/snapshot", headers=auth_headers(admin))).json()
    rows = {row["id"]: row for row in body["signups"]}
    assert str(user.id) in rows
    row = rows[str(user.id)]
    assert row["family_id"] == str(user.family_id)
    assert row["access"] == "trial"
    assert row["tier"] == "free"
    assert row["trial_ends_at"] is not None


async def test_a_guardian_with_no_entitlement_row_is_served_rather_than_dropped(
    session: AsyncSession,
) -> None:
    """**Fails open, and the direction is the point.**

    `create_household` writes an `entitlements` row with every family and nothing deletes them,
    so a guardian whose household has none is a data anomaly rather than a state. The safe
    response to an anomaly is to serve the parent — refusing on missing data is how a paying
    family silently stops getting a board, and nothing would raise.
    """
    family = await make_family(session, trial_ends_at=_yesterday())
    user = await make_user(session, family=family)
    child = await make_child(session, parent=user)
    await _pool(session)
    # Remove the entitlement row entirely — the anomaly, arranged rather than imagined.
    entitlement = await session.get(Entitlement, family.id)
    await session.delete(entitlement)
    await session.commit()

    assert await active_parents(session, child.id) == {user.id: True}

    await run_scheduler(session, as_of_date=SATURDAY, child_id=child.id, seed=6)
    await session.commit()
    assert {row.slot for row in await _rows(session, child.id, SATURDAY)} == set(
        slots_for(SATURDAY)
    ), "a household with no entitlement row lost its board instead of keeping it"


async def test_who_is_a_parent_and_whether_they_are_entitled_is_one_query(
    session: AsyncSession,
) -> None:
    """They were two, and two scans of `guardians` can disagree.

    A guardian revoked between the two reads would be in one answer and not the other, and the
    day would be filled for a parent the gate never evaluated. Asserted by counting the SELECTs
    the function issues rather than by reading it.
    """
    family = await make_family(session, trial_ends_at=_yesterday())
    user = await make_user(session, family=family)
    child = await make_child(session, parent=user)
    await session.commit()

    statements: list[str] = []

    def record(conn, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("SELECT"):
            statements.append(statement)

    sa.event.listen(session.bind.sync_engine, "before_cursor_execute", record)
    try:
        await _rows(session, child.id, SATURDAY)  # warm the connection, then measure
        statements.clear()
        result = await active_parents(session, child.id)
    finally:
        sa.event.remove(session.bind.sync_engine, "before_cursor_execute", record)

    assert result == {user.id: False}
    assert len(statements) == 1, (
        f"resolving parents and their entitlement took {len(statements)} queries: {statements}"
    )


async def test_two_parents_in_one_free_household_both_get_only_the_question(
    session: AsyncSession,
) -> None:
    """The gate is per guardian because a daily slot is, and both parents of one household
    share one `entitlements` row — so both boards narrow together."""
    family = await make_family(session, trial_ends_at=_yesterday())
    one = await make_user(session, family=family, display_name="Travis")
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await _pool(session)
    await session.commit()

    run = await run_scheduler(session, as_of_date=SATURDAY, child_id=child.id, seed=4)
    await session.commit()

    assert run.created == 2, "one question each, and nothing else"
    rows = await _rows(session, child.id, SATURDAY)
    assert {row.slot for row in rows} == {"question"}
    assert {row.user_id for row in rows} == {one.id, two.id}
