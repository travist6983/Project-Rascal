"""How close a child's prompt pool is to repeating itself.

The library holds 113 active prompts and the scheduler serves three a day. Roughly 30 questions
are eligible at 48 months, so at one a day the question pool empties in about a month — at which
point the documented fallback relaxes the 180-day cooldown to 90 and the parent starts seeing
prompts they answered last month, during exactly the sixty-day window P1 exists to prove.

Nothing here fixes that. **This module reports and the scheduler decides**, and keeping those
apart is deliberate: a health check that quietly reshaped selection would make the number it
reports a description of itself.

Computed on every call, never cached. This is an admin-grade read, not a hot path.
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import Slot
from rascal.models import Assignment, Child, Prompt, PromptSuppression
from rascal.services.dates import age_in_months
from rascal.services.scheduler import (
    COOLDOWN_DAYS,
    SLOT_SPECS,
    _eligible,
)


@dataclass(frozen=True)
class SlotHealth:
    slot: Slot
    kind: str
    eligible: int
    suppressed: int
    served_within_cooldown: int
    available_now: int
    estimated_days_until_first_repeat: int | None
    #: How many times this slot was actually filled in the observation window. **The estimate is
    #: derived from this and not from the cadence the slot is nominally on**, because the two
    #: have disagreed in production: `mission` is nominally daily and was being served zero
    #: times a day, so a projection built on the nominal rate counted down to a repeat that
    #: could not happen.
    served_in_window: int
    #: The window those serves were counted over, so the rate is reproducible from the report.
    observation_window_days: int
    #: What the slot is *supposed* to be served at. Reported beside `served_in_window` so the
    #: gap between intended and actual is visible rather than inferred — that gap is the whole
    #: reason this endpoint was reporting fiction.
    nominal_interval_days: int
    #: Why the estimate is what it is. **A null estimate is not one thing**: the pool can be
    #: empty, or the slot can never have been served. Those need different responses and a bare
    #: null cannot tell them apart.
    estimate_basis: str
    relaxation_active: bool
    relaxation_step: str


# What each slot is served at, in days. The question and both mission slots go daily; weekly and
# monthly are named for their cadence; the letter is monthly too.
SERVE_INTERVAL_DAYS: dict[Slot, int] = {
    "question": 1,
    "mission": 1,
    "mission_b": 1,
    "weekly": 7,
    "monthly": 30,
    "letter": 30,
}

#: How far back to look when measuring how often a slot is actually served.
#:
#: Four weeks: long enough that a weekly slot registers four times and a monthly one at least
#: once, short enough that a slot switched off last month stops counting as served.
OBSERVATION_WINDOW_DAYS = 28

#: The estimate is a real projection from an observed rate.
ESTIMATE_OBSERVED = "observed_rate"
#: Nothing is available, so there is nothing to run out of. Pre-existing meaning, kept.
ESTIMATE_POOL_EMPTY = "pool_empty"
#: The slot was not served once in the window, so there is no rate to project from. **This is
#: not zero days and it is not infinity** — it is unmeasured, and saying so is the point.
ESTIMATE_NOT_OBSERVED = "not_observed"

# The ladder `choose_prompt` walks, named so the report can say which rung is load-bearing
# right now rather than just "relaxed: true".
RELAXATION_NONE = "none"
RELAXATION_COOLDOWN_90 = "cooldown_relaxed_to_90_days"
RELAXATION_THEME_DROPPED = "theme_rotation_dropped"
RELAXATION_COOLDOWN_DROPPED = "cooldown_dropped"
RELAXATION_AGE_WINDOW_DROPPED = "age_window_dropped"
RELAXATION_EXHAUSTED = "pool_exhausted"


async def pool_health(
    session: AsyncSession, child: Child, *, as_of: dt.date, viewer_id: uuid.UUID
) -> list[SlotHealth]:
    """One row per slot, per kind the slot draws from.

    The estimate is an **estimate** and the field name says so. It divides what is available
    today by how often the slot is **observed** to be served, which assumes nothing is suppressed
    tomorrow and that the age window does not widen — both of which it will. It is a smoke alarm,
    not a forecast.

    **It used to divide by the nominal cadence and that made it fiction for at least one slot.**
    `mission` is nominally daily; production was serving it zero times a day, so the report
    counted down to a first repeat that could not arrive because nothing was drawing from the
    pool. A number that confident and that wrong is worse than no number, and this file's own
    header promises it reports rather than decides — reporting an assumption as an observation
    breaks that promise.
    """
    age_months = age_in_months(child.birthdate, as_of)
    month = as_of.month

    suppressed_ids = set(
        (
            await session.execute(
                select(PromptSuppression.prompt_id).where(
                    PromptSuppression.child_id == child.id,
                    PromptSuppression.revoked_at.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )

    horizon = as_of - dt.timedelta(days=COOLDOWN_DAYS)
    # **Scoped to one guardian, because since phase 36 the scheduler's cooldown is.** This
    # file's whole job is to report the pool the scheduler actually sees; a child-wide read
    # would count both parents' daily rows and report a runway roughly half the real one for
    # this parent, while the scheduler happily kept serving. `_history` in `scheduler.py` is
    # the query this must mirror — shared rows (NULL `user_id`) went to the household and
    # count for everybody.
    served_rows = (
        await session.execute(
            select(Assignment.prompt_id, Assignment.assigned_on).where(
                Assignment.child_id == child.id,
                or_(Assignment.user_id == viewer_id, Assignment.user_id.is_(None)),
                Assignment.assigned_on >= horizon,
            )
        )
    ).all()
    days_ago: dict[uuid.UUID, int] = {}
    for prompt_id, assigned_on in served_rows:
        gap = (as_of - assigned_on).days
        days_ago[prompt_id] = min(days_ago.get(prompt_id, gap), gap)

    # **How often each slot is actually filled**, which is a different question from which
    # prompts are inside the cooldown and needs its own window. Counted per slot rather than per
    # prompt: the estimate asks how fast the pool drains, and a slot that fires every day drains
    # it at one a day whichever prompt it picks.
    #
    # Every assignment counts, whatever became of it. A `dismissed` or `expired` assignment still
    # consumed a prompt for that day and still put it inside the cooldown, so counting only
    # `done` would understate the drain by exactly the days nobody answered.
    window_start = as_of - dt.timedelta(days=OBSERVATION_WINDOW_DAYS)
    served_in_window: dict[Slot, int] = {}
    for slot_name, count in (
        await session.execute(
            select(Assignment.slot, func.count())
            .where(
                Assignment.child_id == child.id,
                # Same scoping as the cooldown read above. Unscoped, a two-parent household
                # would report `question` as serving twice a day and halve the estimated
                # runway — a smoke alarm that goes off because two people live in the house.
                or_(Assignment.user_id == viewer_id, Assignment.user_id.is_(None)),
                Assignment.assigned_on >= window_start,
                Assignment.assigned_on <= as_of,
            )
            .group_by(Assignment.slot)
        )
    ).all():
        served_in_window[slot_name] = count

    report: list[SlotHealth] = []
    for slot, spec in SLOT_SPECS.items():
        kinds = spec.kinds if spec.kinds is not None else (None,)
        for kind in kinds:
            clauses = [Prompt.active.is_(True), Prompt.cadence == spec.cadence]
            if kind is not None:
                clauses.append(Prompt.kind == kind)
            prompts = list((await session.execute(select(Prompt).where(*clauses))).scalars().all())

            in_window = [p for p in prompts if _eligible(p, age_months, month)]
            suppressed = [p for p in in_window if p.id in suppressed_ids]
            live = [p for p in in_window if p.id not in suppressed_ids]
            within_cooldown = [
                p for p in live if days_ago.get(p.id, COOLDOWN_DAYS + 1) <= COOLDOWN_DAYS
            ]
            available = [p for p in live if p.id not in {q.id for q in within_cooldown}]

            report.append(
                SlotHealth(
                    slot=slot,
                    kind=kind or "any",
                    eligible=len(in_window),
                    suppressed=len(suppressed),
                    served_within_cooldown=len(within_cooldown),
                    available_now=len(available),
                    **_estimate(slot, len(available), served_in_window.get(slot, 0)),
                    relaxation_active=_relaxation_step(live, available, in_window)
                    != RELAXATION_NONE,
                    relaxation_step=_relaxation_step(live, available, in_window),
                )
            )
    return report


def _estimate(slot: Slot, available: int, served: int) -> dict:
    """How long until the pool runs dry, at the rate the slot is **actually** served.

    Returns the four report fields together, because the estimate and the reason for it are one
    answer: a null with no basis is the ambiguity this function exists to remove.

    `None` when nothing is available: the pool is already dry, and a projection of "0 days until
    the first repeat" reads like a countdown rather than like a thing that has happened.

    `None` again when the slot was not served once in the window — **and that is a different
    null.** There is no rate to project from, so any number here would be invented. It is
    emphatically not "infinity days, all is well": a slot nobody is serving is usually a defect
    upstream, and the honest report says the pool is fine *and* nothing is drawing from it, and
    lets the reader draw the conclusion.

    The nominal cadence travels alongside rather than being used, so the gap between intended
    and observed is legible in the response instead of hidden in this arithmetic.
    """
    nominal = SERVE_INTERVAL_DAYS.get(slot, 1)
    common = {
        "served_in_window": served,
        "observation_window_days": OBSERVATION_WINDOW_DAYS,
        "nominal_interval_days": nominal,
    }
    if available <= 0:
        return {
            **common,
            "estimated_days_until_first_repeat": None,
            "estimate_basis": ESTIMATE_POOL_EMPTY,
        }
    if served <= 0:
        return {
            **common,
            "estimated_days_until_first_repeat": None,
            "estimate_basis": ESTIMATE_NOT_OBSERVED,
        }
    # Integer division on the way out, but the rate itself stays fractional — a weekly slot
    # served four times in twenty-eight days drains at 1/7 a day, and rounding that to zero or
    # one before dividing would put the answer out by a factor of seven.
    per_day = served / OBSERVATION_WINDOW_DAYS
    return {
        **common,
        "estimated_days_until_first_repeat": int(available / per_day),
        "estimate_basis": ESTIMATE_OBSERVED,
    }


def _relaxation_step(live: list[Prompt], available: list[Prompt], in_window: list[Prompt]) -> str:
    """Which rung of `choose_prompt`'s ladder the next selection would land on.

    Mirrors the ladder rather than re-deriving it: as long as something is outside the 180-day
    cooldown, nothing has relaxed. Theme rotation is deliberately not modelled here — it turns
    on the last two days' assignments and flickers day to day, which would make this field
    report "relaxed" on a pool that is perfectly healthy.
    """
    if available:
        return RELAXATION_NONE
    if live:
        return RELAXATION_COOLDOWN_90
    if in_window:
        return RELAXATION_COOLDOWN_DROPPED
    return RELAXATION_AGE_WINDOW_DROPPED
