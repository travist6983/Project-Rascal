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

from sqlalchemy import select
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

# The ladder `choose_prompt` walks, named so the report can say which rung is load-bearing
# right now rather than just "relaxed: true".
RELAXATION_NONE = "none"
RELAXATION_COOLDOWN_90 = "cooldown_relaxed_to_90_days"
RELAXATION_THEME_DROPPED = "theme_rotation_dropped"
RELAXATION_COOLDOWN_DROPPED = "cooldown_dropped"
RELAXATION_AGE_WINDOW_DROPPED = "age_window_dropped"
RELAXATION_EXHAUSTED = "pool_exhausted"


async def pool_health(session: AsyncSession, child: Child, *, as_of: dt.date) -> list[SlotHealth]:
    """One row per slot, per kind the slot draws from.

    The estimate is an **estimate** and the field name says so. It divides what is available
    today by how often the slot is served, which assumes nothing is suppressed tomorrow and that
    the age window does not widen — both of which it will. It is a smoke alarm, not a forecast.
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
    served_rows = (
        await session.execute(
            select(Assignment.prompt_id, Assignment.assigned_on).where(
                Assignment.child_id == child.id, Assignment.assigned_on >= horizon
            )
        )
    ).all()
    days_ago: dict[uuid.UUID, int] = {}
    for prompt_id, assigned_on in served_rows:
        gap = (as_of - assigned_on).days
        days_ago[prompt_id] = min(days_ago.get(prompt_id, gap), gap)

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
                    estimated_days_until_first_repeat=_estimate_days(slot, len(available)),
                    relaxation_active=_relaxation_step(live, available, in_window)
                    != RELAXATION_NONE,
                    relaxation_step=_relaxation_step(live, available, in_window),
                )
            )
    return report


def _estimate_days(slot: Slot, available: int) -> int | None:
    """How long until the pool runs dry at the current serve rate.

    `None` when nothing is available: the pool is already dry, and a projection of "0 days
    until the first repeat" reads like a countdown rather than like a thing that has happened.
    """
    if available <= 0:
        return None
    return available * SERVE_INTERVAL_DAYS.get(slot, 1)


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
