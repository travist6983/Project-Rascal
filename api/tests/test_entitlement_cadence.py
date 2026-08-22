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
import io
import json
import pathlib
import uuid
import zipfile
from typing import get_args

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
from rascal.constants import (
    ACCESS_STATES,
    DAILY_SLOTS,
    FREE_SLOTS,
    LOCKED_KIND_HINTS,
    SLOTS,
    TIERS,
    TRIAL_DAYS,
    AccessState,
)
from rascal.models import Assignment, Entitlement, Prompt
from rascal.services.dates import local_date, zone
from rascal.services.guardians import access_for, eligible_at
from rascal.services.scheduler import _active_parents as active_parents
from rascal.services.scheduler import (
    _history,
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


async def test_the_factory_can_actually_build_a_household_with_no_trial(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**A fixture that silently builds the opposite world is worse than a missing fixture.**

    `Entitlement.trial_ends_at` has a Python-side `default=`, and SQLAlchemy omits a
    `None`-valued attribute from the INSERT — an explicit `None` is indistinguishable from an
    absent one, so the default fires and the row gets a fourteen-day trial. `make_family` used
    to hit exactly that: `trial_ends_at=None` wrote `now + 14 days`.

    Nothing caught it, because no test used that path yet. A test written next week to build
    the free tier would have got a household in its trial, and `assert locked == []` would have
    held for the wrong reason — passing against an implementation with no gate at all.

    So this drives the value all the way to the wire rather than stopping at the row.
    """
    family = await make_family(session, tier="free", trial_ends_at=None)
    user = await make_user(session, family=family)
    child = await make_child(session, parent=user)
    await _pool(session)
    await session.commit()

    stored = await session.get(Entitlement, family.id)
    assert stored is not None
    assert stored.trial_ends_at is None, (
        "the factory gave a trial to a household asked to have none"
    )

    body = (
        await client.get(
            f"/v1/children/{child.id}/today?date={SATURDAY.isoformat()}",
            headers=auth_headers(user),
        )
    ).json()
    assert body["access"] == "free"
    assert body["trial_ends_at"] is None
    assert [item["slot"] for item in body["locked"]] == ["mission", "mission_b", "weekly"]


async def test_the_factory_stores_the_trial_it_is_given(session: AsyncSession) -> None:
    """The other two paths, so the fix above cannot break them silently.

    Omitting the argument must still produce the column default — that is what keeps the
    hundred-odd tests written before the free tier existed exercising a full board.
    """
    default_trial = await make_family(session)
    await session.commit()
    row = await session.get(Entitlement, default_trial.id)
    assert row is not None and row.trial_ends_at is not None
    expected = dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=TRIAL_DAYS)
    assert abs((row.trial_ends_at - expected).total_seconds()) < 120

    moment = dt.datetime(2027, 3, 1, 12, 0, tzinfo=dt.UTC)  # future-date: explicit, pure
    explicit = await make_family(session, trial_ends_at=moment)
    await session.commit()
    row = await session.get(Entitlement, explicit.id)
    assert row is not None and row.trial_ends_at == moment


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


def _aliases_of(tree: ast.AST, name: str) -> set[str]:
    """Local names assigned straight from something that reads `.<name>`.

    `ends = entitlement.trial_ends_at` and its walrus form both put the value behind a plain
    `Name`, which a comparison can then use without the attribute appearing in it at all. One
    pass over the module collects those names so the comparison walk can see through them.

    Module-wide rather than per-function on purpose: it costs a handful of false positives at
    worst — a name reused for something else in another function — and a false positive here is
    a loud test failure somebody reads, while a false negative is a second entitlement authority
    nobody ever hears about.
    """
    aliases: set[str] = set()
    for node in ast.walk(tree):
        value = None
        targets: list[ast.expr] = []
        if isinstance(node, ast.Assign):
            value, targets = node.value, list(node.targets)
        # `AnnAssign` is `x: T = ...`; `NamedExpr` is the walrus. Both bind one target.
        elif isinstance(node, ast.AnnAssign | ast.NamedExpr):
            value, targets = node.value, [node.target]
        if value is None:
            continue
        if not any(isinstance(sub, ast.Attribute) and sub.attr == name for sub in ast.walk(value)):
            continue
        for target in targets:
            if isinstance(target, ast.Name):
                aliases.add(target.id)
    return aliases


def _comparisons_touching(src: pathlib.Path, name: str) -> list[str]:
    """Every `<`/`>`/`<=`/`>=` comparison anywhere under `src` that reads `.<name>`, directly or
    through a local name assigned from it.

    **Parsed rather than grepped, and the difference is the whole point of the test.** A regex
    over lines is defeated by anything the author happens to write differently — a comparison
    the formatter split across two lines, `x > y` instead of `y < x`, one inside a
    comprehension, an intermediate variable, a walrus. Every one of those is a second
    entitlement authority and every one slips past a line-oriented pattern.

    **What it still cannot see, measured rather than guessed.** Two shapes get past it: a value
    returned from a helper (`now < get(e)`) and one stored on *another object's* attribute
    (`o.x = e.trial_ends_at; now < o.x`). Following either is a dataflow analysis, and a test
    helper is the wrong place for one. What it does catch is every shape a person writing the
    comparison by hand would plausibly produce, which is the failure being guarded against.

    It is a tripwire, not a proof, and
    :func:`test_the_ast_walk_would_actually_catch_a_second_authority` pins both halves — the
    shapes it catches *and* the two it does not — so the limit is a known quantity rather than
    something a future reader discovers while trusting it.
    """
    found: list[str] = []
    for path in sorted(src.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        aliases = _aliases_of(tree, name)
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
                (isinstance(sub, ast.Attribute) and sub.attr == name)
                or (isinstance(sub, ast.Name) and sub.id in aliases)
                for operand in operands
                for sub in ast.walk(operand)
            )
            if reads_it:
                where = enclosing.get(node, "<module>")
                found.append(f"{path.relative_to(src)}::{where}:{node.lineno}")
    return found


def test_access_for_can_produce_exactly_the_three_documented_states() -> None:
    """**The wire vocabulary, pinned by sweeping the inputs rather than by restating the list.**

    An iOS client decodes these three strings. A fourth is a contract change, not an
    implementation detail — so this walks every reachable combination of the two columns
    `access_for` reads and asserts the set of values it can produce is exactly
    `ACCESS_STATES`, and that the tuple and the `Literal` have not drifted apart.

    Not tautological: it calls the real function over real inputs. An implementation that
    returned `"trialing"`, or that could return `None` for some combination, fails here.
    """
    now = dt.datetime.now(tz=dt.UTC)
    trials = [None, now - dt.timedelta(days=1), now + dt.timedelta(days=1), now]
    produced = {
        access_for(Entitlement(tier=tier, trial_ends_at=trial), now=now).access
        for tier in TIERS
        for trial in trials
    }

    assert produced == set(ACCESS_STATES)
    assert set(get_args(AccessState)) == set(ACCESS_STATES), (
        "the Literal and the tuple have drifted apart"
    )

    # And the two properties that make the mapping unambiguous, over the same sweep.
    for trial in trials:
        assert access_for(Entitlement(tier="subscribed", trial_ends_at=trial), now=now).access == (
            "subscribed"
        ), "subscribed must beat trial for every trial value, including a future one"
    # `now == trial_ends_at` is the boundary: the trial has ended, because the comparison is
    # strict. Stated so the edge is a decision rather than an accident of `<` versus `<=`.
    assert access_for(Entitlement(tier="free", trial_ends_at=now), now=now).access == "free"


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
        "through an intermediate variable": (
            "def f(e, now):\n"
            "    ends = e.trial_ends_at\n"
            "    return ends is not None and now < ends\n"
        ),
        "through a walrus": (
            "def f(e, now):\n    return (ends := e.trial_ends_at) is not None and now < ends\n"
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

    # **And the blind spots, pinned as blind spots.** Following a value out through a helper's
    # return or onto another object's attribute is a dataflow analysis, and a test helper is the
    # wrong place for one. Asserting them here makes the limit a known quantity rather than
    # something a future reader discovers while trusting the tripwire — and if the walk ever
    # does grow that reach, this fails and the docstring gets corrected with it.
    blind = {
        "through a helper's return": (
            "def get(e):\n    return e.trial_ends_at\ndef f(e, now):\n    return now < get(e)\n"
        ),
        "onto another object's attribute": (
            "def f(e, o, now):\n    o.x = e.trial_ends_at\n    return now < o.x\n"
        ),
    }
    for label, source in blind.items():
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "indirect.py").write_text(source)
            assert _comparisons_touching(root, "trial_ends_at") == [], (
                f"the walk now catches {label} — good, but update its docstring to say so"
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

    # And nothing in four years of calendar beats it — every weekday lands on every
    # day-of-month over that span, which is what the ceiling depends on. The exhaustive
    # version is `test_every_shape_the_calendar_can_produce_is_one_of_exactly_six`, which
    # sweeps 28 years: the Gregorian weekday cycle, and exactly 1461 whole weeks.
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


def test_every_shape_the_calendar_can_produce_is_one_of_exactly_six() -> None:
    """The full enumeration, because prose about this drifted once already.

    An earlier draft of `slots_for`'s docstring said *"the 15th is three or four"* — wrong for a
    Saturday the 15th, which is five, in the same sentence that correctly named five as the
    ceiling. A table in a docstring is a claim; this is the assertion behind it.

    Swept over eight years so every weekday-by-date combination occurs, rather than over seven
    hand-picked fixtures that could all miss the same case.
    """
    shapes: dict[tuple[str, str], set[int]] = {}
    day = dt.date(2024, 1, 1)  # future-date: explicit, pure
    for offset in range(366 * 8):
        on = day + dt.timedelta(days=offset)
        weekday = "Sat" if on.weekday() == 5 else "Sun" if on.weekday() == 6 else "weekday"
        occasion = "1st" if on.day == 1 else "15th" if on.day == 15 else "plain"
        shapes.setdefault((weekday, occasion), set()).add(len(slots_for(on)))

    # Each combination produces exactly one length — no combination is sometimes-N-sometimes-M.
    for key, lengths in shapes.items():
        assert len(lengths) == 1, f"{key} produced {sorted(lengths)} different day lengths"

    counts = {key: lengths.pop() for key, lengths in shapes.items()}
    assert counts == {
        ("weekday", "plain"): 2,
        ("weekday", "1st"): 3,
        ("weekday", "15th"): 3,
        ("Sun", "plain"): 3,
        ("Sun", "1st"): 4,
        ("Sun", "15th"): 4,
        ("Sat", "plain"): 4,
        ("Sat", "1st"): 5,
        ("Sat", "15th"): 5,
    }
    assert min(counts.values()) == 2, "the floor is an ordinary weekday"
    assert max(counts.values()) == 5, "the ceiling is a Saturday that is also the 1st or 15th"


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


async def test_a_free_households_prompts_never_enter_the_cooldown_window(
    session: AsyncSession,
) -> None:
    """Requirement 8's own wording, asserted against the thing the cooldown is actually made of.

    **The first version of this test could not fail, and the reason is worth keeping.** It
    asserted `select_prompt(...) is not None` 181 days on — but `choose_prompt`'s ladder ends
    with *"anything in the pool"*, so it returns a prompt whether or not the cooldown was burnt.
    Every assertion in it held just as well against an implementation that served the whole day
    to a free household. A test whose subject is a 180-day window has to look at the window.

    `_history` is that window: it maps prompt id → how many days ago this child saw it, over the
    180-day horizon, and it is the exact input `choose_prompt` filters on. So this compares two
    households that differ in one respect, and asserts the cooldown map differs the same way.
    """
    entitled_user, entitled_child = await _household(session, trial_ends_at=_next_month())
    free_user, free_child = await _household(session, trial_ends_at=_yesterday())
    rows = await session.execute(sa.select(Prompt).where(Prompt.kind == "photo"))
    photos = list(rows.scalars().all())
    assert photos, "the fixture must contain a photo prompt or this proves nothing"

    assert "mission" in slots_for(MONDAY), "MONDAY must be a photo-mission day"
    await run_scheduler(session, as_of_date=MONDAY, child_id=entitled_child.id, seed=2)
    await run_scheduler(session, as_of_date=MONDAY, child_id=free_child.id, seed=2)
    await session.commit()

    entitled_served, _ = await _history(session, entitled_child.id, MONDAY, entitled_user.id)
    free_served, _ = await _history(session, free_child.id, MONDAY, free_user.id)

    # **The control.** The entitled household really did spend a photo prompt, so the mechanism
    # this test is about demonstrably works — without this line the assertion below could pass
    # because nothing was ever served to anybody.
    assert any(prompt.id in entitled_served for prompt in photos), (
        "the entitled household did not consume a photo prompt, so there is no cooldown to compare"
    )

    # **The property.** The free household spent none of them.
    assert not any(prompt.id in free_served for prompt in photos), (
        "a free household burnt a photo prompt's 180-day cooldown on a slot it cannot see"
    )
    # And it was served at all — otherwise the line above would hold for an empty run.
    assert free_served, "the free household's scheduler run served nothing whatsoever"

    # **Where the 181 comes from.** `_history`'s horizon is `as_of_date - 180 days`, so the
    # entitled household's prompt leaves the window on day 181 and the free household's was
    # never in it. Asserting both is what makes 180 a real number rather than a comment.
    entitled_later, _ = await _history(
        session, entitled_child.id, MONDAY + dt.timedelta(days=181), entitled_user.id
    )
    assert not any(prompt.id in entitled_later for prompt in photos), (
        "the 180-day horizon does not appear to be 180 days"
    )


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


async def _reopened_locked_mission(client: AsyncClient, session: AsyncSession, user, child):
    """Drive the one route sequence that leaves a **pending** assignment with a **live entry**.

    Dismiss a mission; answer it anyway (an entry against a non-pending assignment saves and
    leaves the status alone, because the archive matters more than the bookkeeping); then
    rewrite it with `POST /assignments/{id}/custom`, which makes a dismissed assignment live
    again. Every step is a route a parent can reach.
    """
    import uuid as uuidlib

    headers = auth_headers(user)
    photo = await make_prompt(
        session, kind="photo", cadence="daily", completion_mode="media", body="LIBRARY MISSION"
    )
    today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    mission = await make_assignment(
        session, child, photo, slot="mission", assigned_on=today, user=user
    )
    await session.commit()

    assert (
        await client.post(f"/v1/assignments/{mission.id}/dismiss", headers=headers)
    ).status_code == 200
    entry = await client.post(
        "/v1/entries",
        headers={**headers, "Idempotency-Key": str(uuidlib.uuid4())},
        json={
            "id": str(uuidlib.uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(mission.id),
            "body": "He built a tower.",
            "occurred_at": dt.datetime.now(tz=dt.UTC).isoformat().replace("+00:00", "Z"),
        },
    )
    assert entry.status_code == 201, entry.text
    rewritten = await client.post(
        f"/v1/assignments/{mission.id}/custom", headers=headers, json={"body": "MY OWN WORDS"}
    )
    assert rewritten.status_code == 200, rewritten.text
    # The state this helper exists to construct, asserted rather than assumed.
    assert rewritten.json()["status"] == "pending"
    return mission


async def test_a_reopened_locked_mission_does_not_appear_in_today_and_locked_at_once(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The same slot cannot be live and locked in one response.**

    A row that is `pending` *and* has a live entry dated today reaches `assignments_for`
    through the completed-today leg rather than the pending leg — and the pending leg is the
    only one the entitlement gate narrows. Without `status == "done"` on the completed leg, a
    free household got the locked slot in `today[]` **and** in `locked[]` simultaneously.

    That is worse than an extra item. The iOS client keys a locked card's identity on `slot`,
    so it would draw a live mission card and a locked mission card for the same slot on the
    same board.

    Nothing of the library leaks either way — a rewritten assignment serves its `custom_body`,
    which is the parent's own words — so this is a contract defect rather than a disclosure.
    """
    user, child = await _household(session, trial_ends_at=_next_month())
    mission = await _reopened_locked_mission(client, session, user, child)

    entitlement = await session.get(Entitlement, user.family_id)
    entitlement.trial_ends_at = _yesterday()
    await session.commit()

    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()

    assert body["access"] == "free"
    live = _slots(body["today"]) | _slots(body["waiting"])
    locked = {item["slot"] for item in body["locked"]}
    assert not (live & locked), f"{sorted(live & locked)} is both offered and locked"
    assert "mission" not in live
    assert str(mission.id) not in {item["id"] for item in body["today"] + body["waiting"]}


async def test_an_entitled_household_still_sees_a_reopened_mission(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The other direction, so the fix above cannot pass by hiding the row from everybody.

    An entitled household reaches the identical row through the **pending** leg, which the
    gate does not narrow, so rewriting a dismissed mission still puts it back on the board.
    """
    user, child = await _household(session, trial_ends_at=_next_month())
    mission = await _reopened_locked_mission(client, session, user, child)

    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()

    assert body["access"] == "trial"
    assert body["locked"] == []
    offered = {item["id"]: item for item in body["today"]}
    assert str(mission.id) in offered, "rewriting a dismissed mission must put it back"
    assert offered[str(mission.id)]["body"] == "MY OWN WORDS"


async def test_a_hidden_mission_still_expires_on_its_own_fourteen_day_clock(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**What actually happens to a locked row as it ages, decided rather than left to chance.**

    The phase brief says a locked slot *"never expires against the parent"*, and the `waiting`
    half of that is enforced in the query and tested above. The expiry half is **not**
    suppressed, and that is deliberate — the alternative is worse.

    `_expire_stale` flips any pending row past `expires_on`, with no entitlement filter. So a
    mission served on day 0 while entitled, hidden by a lapse on day 1, is flipped to `expired`
    on day 15 by the nightly job, having been invisible for a fortnight.

    **Suppressing that would mean a household that lapses for a year and comes back finds a
    year-old mission in `waiting`** — which is the infinite backlog *"items stack; expire at 14
    days"* exists to prevent, and a settled decision this phase has no licence to reverse. The
    row ages on the same clock as any other; entitlement decides what is *served*, not what
    time does. A household that returns inside the window gets it back with the days it has
    left, which is the case that matters and is asserted below.

    The cost is named rather than hidden: such a row counts toward `resolved` in the admin
    console's per-household figures, alongside done and dismissed. That is a small distortion
    on one number, and it is the price of not reversing the expiry decision.
    """
    user, child = await _household(session, trial_ends_at=_next_month())
    photo = await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    served_on = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone) - dt.timedelta(
        days=20
    )
    mission = await make_assignment(
        session, child, photo, slot="mission", assigned_on=served_on, user=user
    )
    assert mission.expires_on == served_on + dt.timedelta(days=14)

    # The lapse, after the row was written.
    entitlement = await session.get(Entitlement, user.family_id)
    entitlement.trial_ends_at = _yesterday()
    await session.commit()

    # Invisible while it ages — the `waiting` exclusion, which is the enforced half.
    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()
    assert str(mission.id) not in {item["id"] for item in body["waiting"] + body["today"]}

    # And the nightly job ages it anyway, on its own clock.
    await run_scheduler(session, as_of_date=served_on + dt.timedelta(days=15), child_id=child.id)
    await session.commit()
    await session.refresh(mission)
    assert mission.status == "expired", (
        "a hidden row must still age, or a lapse of a year returns a year-old mission"
    )


async def test_a_household_that_returns_inside_the_window_gets_its_missions_back(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The case that actually matters, and the reason the row is not deleted on a lapse.

    Re-entitled before `expires_on`, the row is served again with the days it has left. This is
    what *"the rows keep existing and simply stop being served"* buys, and it is why the phase
    forbids cleanup.
    """
    user, child = await _household(session, trial_ends_at=_yesterday())
    photo = await make_prompt(session, kind="photo", cadence="daily", completion_mode="media")
    served_on = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone) - dt.timedelta(days=3)
    mission = await make_assignment(
        session, child, photo, slot="mission", assigned_on=served_on, user=user
    )
    await session.commit()
    headers = auth_headers(user)

    hidden = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert str(mission.id) not in {item["id"] for item in hidden["waiting"]}

    entitlement = await session.get(Entitlement, user.family_id)
    entitlement.trial_ends_at = _next_month()
    await session.commit()

    back = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert str(mission.id) in {item["id"] for item in back["waiting"]}, (
        "a household that came back inside the window did not get its pending mission back"
    )


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


# --- The governing constraint: the archive is never locked ------------------------------------


async def test_a_free_households_archive_stays_readable_searchable_and_exportable(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The sentence the whole phase is built under, asserted end to end.**

    D3 as narrowed: *the archive is never locked, the day is.* A free household keeps unlimited
    text and `did_it` entries, full export, full-text search, and **every entry it already
    has** — including the ones a mission produced while it was entitled, and including the
    prompt that asked for them.

    Everything else in this file checks that something is *withheld*. This checks that nothing
    else is, which is the half a gate gets wrong. It goes through four separate read paths,
    because "the archive is fine" is a claim about all of them and any one of them could have
    grown an entitlement check.
    """
    user, child = await _household(session, trial_ends_at=_next_month())
    headers = auth_headers(user)
    photo = await make_prompt(
        session,
        kind="photo",
        cadence="daily",
        completion_mode="media",
        body="Photograph the thing he built today.",
    )
    today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    mission = await make_assignment(
        session, child, photo, slot="mission", assigned_on=today, user=user
    )
    await session.commit()

    entry_id = str(uuid.uuid4())
    created = await client.post(
        "/v1/entries",
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
        json={
            "id": entry_id,
            "child_id": str(child.id),
            "assignment_id": str(mission.id),
            "body": "He built a wobbling tower of blocks and called it a lighthouse.",
            "occurred_at": dt.datetime.now(tz=dt.UTC).isoformat().replace("+00:00", "Z"),
        },
    )
    assert created.status_code == 201, created.text

    # Now take the missions away. The entry was made under a trial; the household is free.
    entitlement = await session.get(Entitlement, user.family_id)
    entitlement.trial_ends_at = _yesterday()
    await session.commit()

    board = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert board["access"] == "free", "the fixture must actually be on the free tier"

    # 1. The timeline still has it.
    listed = (await client.get(f"/v1/entries?child_id={child.id}", headers=headers)).json()
    assert entry_id in {item["id"] for item in listed["entries"]}, "a free tier hid an entry"

    # 2. Full-text search still finds it — by a word from the body.
    found = (
        await client.get(f"/v1/entries?child_id={child.id}&q=lighthouse", headers=headers)
    ).json()
    assert entry_id in {item["id"] for item in found["entries"]}, "search stopped at the paywall"
    # A negative control, so the assertion above is not passing because `q` is ignored — which
    # would make it prove nothing at all.
    missed = (
        await client.get(f"/v1/entries?child_id={child.id}&q=zzzznotaword", headers=headers)
    ).json()
    assert missed["entries"] == [], "`q` is not filtering, so the search assertion is vacuous"

    # 3. The prompt that asked for it is still readable on the entry, which is the part D3 as
    #    narrowed positively requires — suppressing it would be the bug, not the fix.
    detail = next(item for item in listed["entries"] if item["id"] == entry_id)
    assert detail.get("prompt_body") == "Photograph the thing he built today."

    # 4. Export is whole. `zipfile` rather than a status check, because "always free and
    #    complete" is a claim about the bytes.
    dump = await client.get(f"/v1/children/{child.id}/export", headers=headers)
    assert dump.status_code == 200, dump.text
    archive = zipfile.ZipFile(io.BytesIO(dump.content))
    entries = json.loads(archive.read("entries.json"))
    exported = entries["entries"] if isinstance(entries, dict) else entries
    assert entry_id in {item["id"] for item in exported}, "export dropped an entry on the free tier"
    assert "lighthouse" in archive.read("entries.json").decode()


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


async def test_the_admin_lever_cannot_free_a_subscribed_household(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The lever exists for the owner, and the owner's household is `subscribed`.**

    `subscribed` beats `trial`, so setting the trial to yesterday leaves such a household on
    `subscribed` — the one control built so the owner could see the free tier he is designing
    does nothing for him. That is not fixable here: `tier` has exactly one writer by D5, and a
    console button that set it would be a person disagreeing with Apple.

    So it is pinned rather than papered over. The date **is** stored — it matters the day the
    subscription lapses — and the response reports the truth instead of implying success. The
    route description, the service docstring, the console copy and both runbooks now say the
    same thing, and point at `runbook-deploy.md` §7a as the way out.
    """
    user, _child = await _household(session, tier="subscribed", trial_ends_at=_next_month())
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.commit()

    response = await client.put(
        f"/v1/admin/families/{user.family_id}/trial",
        headers=auth_headers(admin),
        json={"trial_ends_at": _yesterday().isoformat().replace("+00:00", "Z")},
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["access"] == "subscribed", "the tier outranks the trial and must keep doing so"
    assert body["tier"] == "subscribed", "the lever must never touch the tier"
    # The write still happened — a lapse later has to find the date the owner set.
    stored = await session.get(Entitlement, user.family_id)
    await session.refresh(stored)
    assert stored.trial_ends_at is not None
    assert stored.trial_ends_at < dt.datetime.now(tz=dt.UTC)

    # And the same household, once its tier goes back to free, does move — which is what makes
    # the runbook's reverse statement the actual answer rather than a shrug.
    stored.tier = "free"
    await session.commit()
    after = (
        await client.get(f"/v1/families/{user.family_id}/entitlement", headers=auth_headers(user))
    ).json()
    assert after["access"] == "free"


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
