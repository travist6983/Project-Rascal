"""The daily scheduler.

Runs 5am in each child's `family_timezone`. `assigned_on` is the date **in that zone**,
derived from the run instant, so two children in different zones get different dates from
the same UTC moment — and that is correct.

Selection is split in two. :func:`choose_prompt` is pure: candidates in, one prompt out, no
database and no clock. :func:`run_scheduler` is the impure half that reads the pool and
writes rows. The pure half is where the cooldown, theme rotation, and age-window rules live,
and it is the half worth unit tests.
"""

from __future__ import annotations

import datetime as dt
import logging
import random
import uuid
from dataclasses import dataclass, field

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import DEFAULT_EXPIRY_DAYS, Slot
from rascal.models import Assignment, Child, Prompt, PromptSuppression
from rascal.services.dates import local_date, local_hour

log = logging.getLogger("rascal.scheduler")

# docs/data-model.md: "Runs 5am in each child's family_timezone."
SCHEDULER_LOCAL_HOUR = 5

# docs/data-model.md §Scheduler logic.
COOLDOWN_DAYS = 180
RELAXED_COOLDOWN_DAYS = 90
THEME_ROTATION_DAYS = 2

# A prompt this child has never seen beats one they have. Everything else is even.
UNSEEN_WEIGHT = 3.0
SEEN_WEIGHT = 1.0

# What the weekly and monthly slots draw from. **Unchanged by the three-slot split**, and it
# is not the daily mission pool any more — `mission` and `mission_b` name their own kinds
# below. Editing this changes the monthly measurement slot, which this is not the lever for.
MISSION_KINDS = ("photo", "video", "audio", "activity", "measurement")

# The two daily doing-slots, split so a photo mission and a longer one can both be served.
# `mission` narrowed to photo without being renamed — see docs/decisions.md; rows written
# before migration 0008 hold other kinds here and are correct for the day they were served.
MISSION_KINDS_PHOTO = ("photo",)
MISSION_B_KINDS = ("video", "audio", "activity")


@dataclass(frozen=True)
class SlotSpec:
    cadence: str
    kinds: tuple[str, ...] | None  # None means any kind at that cadence


SLOT_SPECS: dict[Slot, SlotSpec] = {
    "question": SlotSpec(cadence="daily", kinds=("question",)),
    "mission": SlotSpec(cadence="daily", kinds=MISSION_KINDS_PHOTO),
    "mission_b": SlotSpec(cadence="daily", kinds=MISSION_B_KINDS),
    "weekly": SlotSpec(cadence="weekly", kinds=None),
    # Measurement and the camera-roll backfill, never a letter — letters have their own slot
    # so the money letter cannot lose a coin flip to a height measurement forever.
    "monthly": SlotSpec(cadence="monthly", kinds=MISSION_KINDS),
    "letter": SlotSpec(cadence="monthly", kinds=("letter",)),
}


@dataclass
class SchedulerRun:
    """What a run did, for the log line and for the debug route's response."""

    as_of: dt.date | None = None
    expired: int = 0
    created: int = 0
    skipped_existing: int = 0
    # Children the hourly job passed over because it is not 5am where they live.
    skipped_off_hour: int = 0
    exhausted: list[str] = field(default_factory=list)


# --- The pure half -----------------------------------------------------------------------


def _eligible(prompt: Prompt, age_months: int, month: int) -> bool:
    """Cadence and kind are filtered in SQL; this is the age window and the seasonal tag."""
    return prompt.covers_age(age_months) and prompt.covers_month(month)


def choose_prompt(
    candidates: list[Prompt],
    *,
    age_months: int,
    month: int,
    served_recently: dict[uuid.UUID, int],
    recent_themes: set[str],
    rng: random.Random,
) -> Prompt | None:
    """Pick one prompt. Pure — no database, no clock, no randomness you cannot seed.

    `served_recently` maps a prompt id to how many days ago this child last saw it.

    The pool narrows from strictest to loosest, and the order matters: an age-inappropriate
    prompt is worse than a repeat, so the age window is the *last* thing to give.

      1. age + season, 180-day cooldown, no theme served in the last two days
      2. age + season, 90-day cooldown, theme rotation still on   <- cooldown relaxes first
      3. age + season, 90-day cooldown, theme rotation dropped
      4. age + season, no cooldown at all
      5. season only                                              <- age window relaxes last
      6. anything in the pool
    """
    in_window = [p for p in candidates if _eligible(p, age_months, month)]
    in_season = [p for p in candidates if p.covers_month(month)]

    def outside(pool: list[Prompt], cooldown: int) -> list[Prompt]:
        return [p for p in pool if served_recently.get(p.id, cooldown + 1) > cooldown]

    def fresh_theme(pool: list[Prompt]) -> list[Prompt]:
        return [p for p in pool if p.theme not in recent_themes]

    ladders = (
        fresh_theme(outside(in_window, COOLDOWN_DAYS)),
        fresh_theme(outside(in_window, RELAXED_COOLDOWN_DAYS)),
        outside(in_window, RELAXED_COOLDOWN_DAYS),
        in_window,
        in_season,
        candidates,
    )
    for pool in ladders:
        if pool:
            return _weighted_pick(pool, served_recently, rng)
    return None


def _weighted_pick(
    pool: list[Prompt], served_recently: dict[uuid.UUID, int], rng: random.Random
) -> Prompt:
    weights = [UNSEEN_WEIGHT if p.id not in served_recently else SEEN_WEIGHT for p in pool]
    return rng.choices(pool, weights=weights, k=1)[0]


# --- The impure half ---------------------------------------------------------------------


async def _candidates(session: AsyncSession, spec: SlotSpec, child_id: uuid.UUID) -> list[Prompt]:
    """The candidate pool, with this child's suppressions already removed.

    **Suppression is enforced here and nowhere else, and that placement is the rule.** The
    ladder in :func:`choose_prompt` relaxes the cooldown, then drops theme rotation, then drops
    the cooldown entirely, then the age window, and finally falls back to "anything in the
    pool". A suppressed prompt has to survive none of that — so it is removed before selection
    begins rather than filtered at any rung. There is no rung that can resurrect a prompt that
    was never in the list.

    Both callers reach this through :func:`select_prompt`: the nightly scheduler via
    ``run_scheduler`` and the Phase 12 read path via ``ensure_day_filled``. One query, one
    exclusion, no chance of the two diverging — which over years would corrupt variety in a way
    nothing would notice.
    """
    clauses = [Prompt.active.is_(True), Prompt.cadence == spec.cadence]
    if spec.kinds is not None:
        clauses.append(Prompt.kind.in_(spec.kinds))
    rows = await session.execute(
        select(Prompt).where(
            *clauses,
            ~select(PromptSuppression.prompt_id)
            .where(
                PromptSuppression.child_id == child_id,
                PromptSuppression.prompt_id == Prompt.id,
                # A withdrawn suppression stops excluding. The soft delete is what makes the
                # decision reversible.
                PromptSuppression.revoked_at.is_(None),
            )
            .exists(),
        )
    )
    return list(rows.scalars().all())


async def _history(
    session: AsyncSession, child_id: uuid.UUID, as_of_date: dt.date
) -> tuple[dict[uuid.UUID, int], set[str]]:
    """How long ago this child saw each prompt, and the themes from the last two days.

    The theme window includes `as_of_date` itself, so a slot picked seconds after another one
    does not land on the same theme.

    **This generalises to any number of slots in a day, and it does so by construction rather
    than by arithmetic.** It was written when a day held two daily picks and now holds three.
    `_fill_slot` inserts each assignment before the next slot is selected, and this function
    re-reads the child's history per pick inside the same transaction — so the third pick sees
    the first two, exactly as the second saw the first. Nothing here counts slots, so nothing
    here needed changing for a fourth.
    """
    horizon = as_of_date - dt.timedelta(days=COOLDOWN_DAYS)
    rows = (
        await session.execute(
            select(Assignment.prompt_id, Assignment.assigned_on, Prompt.theme)
            .join(Prompt, Prompt.id == Assignment.prompt_id)
            .where(Assignment.child_id == child_id, Assignment.assigned_on >= horizon)
        )
    ).all()

    served: dict[uuid.UUID, int] = {}
    themes: set[str] = set()
    theme_cutoff = as_of_date - dt.timedelta(days=THEME_ROTATION_DAYS)
    for prompt_id, assigned_on, theme in rows:
        days_ago = (as_of_date - assigned_on).days
        served[prompt_id] = min(served.get(prompt_id, days_ago), days_ago)
        if assigned_on >= theme_cutoff:
            themes.add(theme)
    return served, themes


async def select_prompt(
    child: Child,
    slot: Slot,
    as_of_date: dt.date,
    session: AsyncSession,
    *,
    rng: random.Random | None = None,
) -> Prompt | None:
    """The signature `docs/data-model.md` describes: one child, one slot, one date.

    A thin wrapper that loads the pool and this child's history, then hands both to the pure
    :func:`choose_prompt`.
    """
    from rascal.services.dates import age_in_months

    spec = SLOT_SPECS[slot]
    candidates = await _candidates(session, spec, child.id)
    served, themes = await _history(session, child.id, as_of_date)
    return choose_prompt(
        candidates,
        age_months=age_in_months(child.birthdate, as_of_date),
        month=as_of_date.month,
        served_recently=served,
        recent_themes=themes,
        rng=rng or random.Random(),
    )


def slots_for(day: dt.date) -> list[Slot]:
    """The daily three, the weekly on Saturday, the monthly on the 1st, a letter on the 15th.

    The three daily slots fire every day. The weekly, monthly and letter slots fire **on top
    of them, unconditionally** — they are not suppressed to keep the count down. So a Saturday
    is four items, the 15th is four, and a Saturday that is also the 15th is five.

    That is a deliberate change to the old ceiling. The letter was originally moved off the
    1st because "four items on one day breaks two-items-is-the-most-that-survives-a-bad-
    Tuesday"; the third daily mission raises the floor past that on every day of the year, and
    the owner has taken that call knowing the worst day now reaches five. Splitting the letter
    away from the measurement mission still earns its keep — it keeps the money letter from
    losing a coin flip to a height measurement every month — so the 15th stays.
    """
    slots: list[Slot] = ["question", "mission", "mission_b"]
    if day.weekday() == 5:  # Saturday
        slots.append("weekly")
    if day.day == 1:
        slots.append("monthly")
    if day.day == 15:
        slots.append("letter")
    return slots


async def _expire_stale(session: AsyncSession, child: Child, today: dt.date) -> int:
    result = await session.execute(
        update(Assignment)
        .where(
            Assignment.child_id == child.id,
            Assignment.status == "pending",
            Assignment.expires_on < today,
        )
        .values(status="expired")
    )
    return result.rowcount or 0


async def _fill_slot(
    session: AsyncSession,
    child: Child,
    slot: Slot,
    day: dt.date,
    rng: random.Random,
    run: SchedulerRun,
) -> None:
    # Cheap pre-check so an already-filled slot does not burn a selection. The unique index
    # is still what guarantees correctness under a concurrent run.
    already = await session.scalar(
        select(Assignment.id).where(
            Assignment.child_id == child.id,
            Assignment.assigned_on == day,
            Assignment.slot == slot,
        )
    )
    if already is not None:
        run.skipped_existing += 1
        return

    prompt = await select_prompt(child, slot, day, session, rng=rng)
    if prompt is None:
        # No fake data and no fallback prompt: an empty slot is honest, and the log line
        # says which child and which slot to go and fix.
        run.exhausted.append(f"{child.id}:{slot}")
        log.warning(
            "no eligible prompt",
            extra={"child_id": str(child.id), "slot": slot, "assigned_on": day.isoformat()},
        )
        return

    result = await session.execute(
        insert(Assignment)
        .values(
            id=uuid.uuid4(),
            child_id=child.id,
            prompt_id=prompt.id,
            slot=slot,
            assigned_on=day,
            expires_on=day + dt.timedelta(days=DEFAULT_EXPIRY_DAYS),
            status="pending",
        )
        # The unique index on (child_id, assigned_on, slot) is what makes reruns free.
        .on_conflict_do_nothing(
            index_elements=[Assignment.child_id, Assignment.assigned_on, Assignment.slot]
        )
        .returning(Assignment.id)
    )
    if result.scalar_one_or_none() is None:
        run.skipped_existing += 1
    else:
        run.created += 1


async def _filled_slots(session: AsyncSession, child_id: uuid.UUID, day: dt.date) -> set[str]:
    """Which slots already have a row for this child on that day. One indexed lookup."""
    rows = await session.execute(
        select(Assignment.slot).where(
            Assignment.child_id == child_id, Assignment.assigned_on == day
        )
    )
    return set(rows.scalars().all())


async def ensure_day_filled(
    session: AsyncSession,
    child: Child,
    day: dt.date,
    *,
    seed: int | None = None,
) -> SchedulerRun:
    """Fill whatever slots this child is missing for `day`. The read path's safety net.

    ``GET /today`` calls this, which is what demotes the scheduler from a dependency to an
    optimisation: if the machine that runs it never woke up, the first read of the day
    creates what it should have created, and the archive has a gap of seconds rather than
    of a day nobody can get back.

    Deliberately narrower than :func:`run_scheduler`:

    * One child, one day — and `day` is passed in, already computed in the child's
      ``family_timezone`` by the caller. There is exactly one definition of "today" in this
      codebase and it is :func:`rascal.services.dates.local_date`; this function does not
      add a second one.
    * **Nothing is expired.** A pending assignment past its ``expires_on`` stays expired.
      This fills today's empty slots; it does not reach into the past and resurrect it.
    * The common case — the scheduler already ran — is one indexed SELECT and no writes.

    Selection is :func:`_fill_slot` unchanged, so the 180-day cooldown, the theme rotation,
    the age window and the seasonal filter are the scheduler's, not a copy of them. A second
    selection algorithm would diverge from this one invisibly and cost the archive years of
    variety before anyone noticed.
    """
    run = SchedulerRun(as_of=day)
    wanted = slots_for(day)
    present = await _filled_slots(session, child.id, day)
    missing = [slot for slot in wanted if slot not in present]
    run.skipped_existing = len(wanted) - len(missing)
    if not missing:
        return run

    rng = random.Random(seed)
    for slot in missing:
        # Slot order is deterministic, so two concurrent readers take the unique index's
        # locks in the same order and one simply waits rather than deadlocking.
        await _fill_slot(session, child, slot, day, rng, run)
    await session.flush()

    log.info(
        "today filled on read",
        extra={
            "child_id": str(child.id),
            "assigned_on": day.isoformat(),
            "assignments_created": run.created,
            "assignments_skipped": run.skipped_existing,
            "slots_exhausted": len(run.exhausted),
        },
    )
    return run


async def run_scheduler(
    session: AsyncSession,
    *,
    as_of: dt.datetime | None = None,
    as_of_date: dt.date | None = None,
    child_id: uuid.UUID | None = None,
    seed: int | None = None,
    only_local_hour: int | None = None,
) -> SchedulerRun:
    """Expire what lapsed, then fill every slot for every child.

    Pass `as_of` (an instant) for the real job: each child's date is that instant read in
    their own `family_timezone`. Pass `as_of_date` (a plain date) to run a specific calendar
    day for everyone, which is what backfilling and the debug route want.

    `only_local_hour` skips children for whom it is not currently that hour on the wall. The
    hourly job passes 5, so every timezone gets its 5am regardless of where it sits against
    UTC — and regardless of what DST did to that offset last weekend.
    """
    if as_of is not None and as_of_date is not None:
        raise ValueError("pass as_of or as_of_date, not both")
    instant = as_of or dt.datetime.now(tz=dt.UTC)

    rng = random.Random(seed)
    run = SchedulerRun(as_of=as_of_date)

    statement = select(Child)
    if child_id is not None:
        statement = statement.where(Child.id == child_id)
    children = list((await session.execute(statement)).scalars().all())

    for child in children:
        if only_local_hour is not None and (
            local_hour(instant, child.family_timezone) != only_local_hour
        ):
            run.skipped_off_hour += 1
            continue

        # Never UTC and never the server's local time: without this the 5am job hands you
        # tomorrow's mission at 9pm.
        day = as_of_date or local_date(instant, child.family_timezone)
        run.expired += await _expire_stale(session, child, day)
        for slot in slots_for(day):
            await _fill_slot(session, child, slot, day, rng, run)

    await session.flush()
    log.info(
        "scheduler run",
        # Deliberately prefixed: `created` and `message` are reserved LogRecord attributes
        # and logging raises rather than shadowing them.
        extra={
            "children": len(children),
            "children_off_hour": run.skipped_off_hour,
            "assignments_expired": run.expired,
            "assignments_created": run.created,
            "assignments_skipped": run.skipped_existing,
            "slots_exhausted": len(run.exhausted),
        },
    )
    return run
