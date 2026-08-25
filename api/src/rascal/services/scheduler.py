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

from sqlalchemy import or_, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    DAILY_SLOTS,
    DEFAULT_EXPIRY_DAYS,
    FREE_SLOTS,
    SHARED_SLOTS,
    Slot,
)
from rascal.models import Assignment, Child, Entitlement, Guardian, Prompt, PromptSuppression, User
from rascal.services.dates import local_date, local_hour
from rascal.services.grants import has_active_grant
from rascal.services.guardians import access_for

# The two partial unique indexes' predicates, spelled exactly as `models/assignment.py`
# spells them. ON CONFLICT against a partial index has to repeat its WHERE clause, and if
# these two strings ever drift from the index definitions the inference stops matching.
_DAILY_PREDICATE = "slot IN (" + ", ".join(f"'{s}'" for s in DAILY_SLOTS) + ")"
_SHARED_PREDICATE = "slot IN (" + ", ".join(f"'{s}'" for s in SHARED_SLOTS) + ")"

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
PHOTO_MISSION_KINDS = ("photo",)
MISSION_B_KINDS = ("video", "audio", "activity")


@dataclass(frozen=True)
class SlotSpec:
    cadence: str
    kinds: tuple[str, ...] | None  # None means any kind at that cadence


SLOT_SPECS: dict[Slot, SlotSpec] = {
    "question": SlotSpec(cadence="daily", kinds=("question",)),
    "mission": SlotSpec(cadence="daily", kinds=PHOTO_MISSION_KINDS),
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


async def _active_parents(
    session: AsyncSession, child_id: uuid.UUID, *, now: dt.datetime | None = None
) -> dict[uuid.UUID, bool]:
    """The guardians a daily slot is served to, oldest grant first, each mapped to whether
    **their** household is entitled to more than the daily question.

    **`parent` only.** A `viewer` reads what is there and is never served a prompt of their
    own — phase 30 is iceboxed and this does not un-ice it, but the filter belongs here now
    rather than as a surprise later.

    **Ordering is deterministic and load-bearing**, which is why this returns a dict rather
    than a set: two concurrent runs must take the unique index's locks in the same order so
    one waits rather than deadlocking, exactly as slot order already does. Python dicts keep
    insertion order, so iterating the keys is the old `list` unchanged.

    **Who is a parent and whether that parent is entitled are one query, not two.** They were
    two when phase 107 first wrote the gate — one scan of `guardians` for the list and another
    for the entitlement — on the hottest read in the app, and worse than the cost was that two
    scans of the same table can disagree: a guardian revoked between them would be in one
    answer and not the other, and the day would be filled for a parent the gate never
    evaluated.

    Entitlement is family-level per D4 and a child is reached through `guardians` rather than
    through a family — there is no `children.family_id` and deliberately so — hence the join
    out to the user's household. It is read through :func:`services.guardians.access_for` so
    the formula is not restated here.

    **Per parent rather than per child, because a daily slot is served per parent.** In every
    ordinary household the two parents share one `entitlements` row and this map holds one
    value twice. It differs only where a child is guarded from two households — reachable,
    because accepting an invite moves a user's family without revoking the guardian rows they
    already had — and there the right answer is that each parent's own household governs their
    own board.

    **A `LEFT JOIN`, so a missing entitlement row cannot drop a parent from the board.**
    `create_household` writes one with every family and nothing deletes them, so `None` here is
    a data anomaly rather than a state — and the safe response to an anomaly is to serve the
    parent, not to silently stop scheduling for them. It is recorded as entitled and logged.
    """
    # Resolved once, here, rather than left `None` for `access_for` to fill in per row. The SQL
    # predicate needs a real timestamp to bind, and one clock for the whole scan is the right
    # answer anyway: a grant expiring mid-loop must not hold for the first parent and not the
    # second.
    now = now or dt.datetime.now(tz=dt.UTC)
    rows = await session.execute(
        # The grant is a correlated `EXISTS` beside the entitlement rather than a third scan.
        # Same argument as the join above: one query, so a grant revoked mid-scan cannot be in
        # one answer and not the other. The predicate is `services/grants.has_active_grant`,
        # which correlates `unexpired` to this row's household — this selects it, it does not
        # restate it.
        select(Guardian.user_id, Entitlement, has_active_grant(User.family_id, now))
        .join(User, User.id == Guardian.user_id)
        .outerjoin(Entitlement, Entitlement.family_id == User.family_id)
        .where(
            Guardian.child_id == child_id,
            Guardian.revoked_at.is_(None),
            Guardian.role == "parent",
        )
        .order_by(Guardian.granted_at, Guardian.user_id)
    )
    parents: dict[uuid.UUID, bool] = {}
    for user_id, entitlement, granted in rows:
        if entitlement is None:
            log.warning(
                "guardian has no entitlement row",
                extra={"child_id": str(child_id), "user_id": str(user_id)},
            )
            parents[user_id] = True
            continue
        parents[user_id] = access_for(entitlement, granted=granted, now=now).entitled
    return parents


def _serve(slot: Slot, user_id: uuid.UUID | None, entitled: dict[uuid.UUID, bool]) -> bool:
    """Whether the scheduler may fill this (slot, guardian) pair.

    **This is an optimisation and `GET /today` is the authority** — the standing rule that the
    scheduler is not a dependency cuts both ways, and a household that subscribes at 2pm gets
    its missions from the next read rather than from tomorrow's run. What this buys is the
    thing the read cannot undo: **a served prompt writes an assignment and consumes the 180-day
    cooldown against a 133-prompt pool.** Filling slots a free parent can never see would burn
    their runway invisibly, and hand them repeats on the day they subscribe. Do not replace this
    with "fill it and hide it".

    Three cases, and the last two both fail **open**:

    * A free slot — today, the daily question — is always filled. It is the free tier.
    * A daily slot names its guardian, so it is that guardian's own household that decides. A
      guardian with no row in the map is unknown rather than unentitled, and an unknown
      household is served: refusing on missing data is how a paying family loses a day.
    * A shared slot belongs to the child rather than to a guardian, so it is filled if **any**
      household guarding the child is entitled. A child with no active parent has no household
      to ask and keeps the behaviour it has always had — shared slots fire, daily slots do not,
      because there is nobody to serve them to.
    """
    if slot in FREE_SLOTS:
        return True
    if user_id is not None:
        return entitled.get(user_id, True)
    return not entitled or any(entitled.values())


async def _history(
    session: AsyncSession,
    child_id: uuid.UUID,
    as_of_date: dt.date,
    user_id: uuid.UUID | None = None,
) -> tuple[dict[uuid.UUID, int], set[str]]:
    """How long ago this child saw each prompt, and the themes from the last two days.

    **`user_id` scopes it to one parent, and that is decision 1 of phase 36.** For a daily
    pick the history is *that parent's* daily rows plus every shared row, because a weekly or
    a letter was served to the household and both of them saw it. Two parents therefore have
    their own runway through the pool and may be served the same prompt on different days —
    which is the feature, not a collision.

    For a shared pick `user_id` is None and the history is the child's, unchanged from before
    phase 36. That keeps the weekly, monthly and letter slots behaving exactly as they did.

    Cross-cadence rows are harmless in `served_recently` — `_candidates` filters by cadence,
    so a daily prompt is never a candidate for a weekly slot — but they matter for
    `recent_themes`, which is shared across cadences and is the reason the scoping is applied
    to the whole query rather than to one of the two return values.

    The theme window includes `as_of_date` itself, so a slot picked seconds after another one
    does not land on the same theme.

    **This generalises to any number of slots in a day, and it does so by construction rather
    than by arithmetic.** It was written when a day held two daily picks and now holds three.
    `_fill_slot` inserts each assignment before the next slot is selected, and this function
    re-reads the child's history per pick inside the same transaction — so the third pick sees
    the first two, exactly as the second saw the first. Nothing here counts slots, so nothing
    here needed changing for a fourth, and nothing needed changing for a second guardian.
    """
    horizon = as_of_date - dt.timedelta(days=COOLDOWN_DAYS)
    clauses = [Assignment.child_id == child_id, Assignment.assigned_on >= horizon]
    if user_id is not None:
        # This parent's own daily rows, plus every shared row — a weekly went to the
        # household and both of them saw it.
        clauses.append(or_(Assignment.user_id == user_id, Assignment.user_id.is_(None)))
    rows = (
        await session.execute(
            select(Assignment.prompt_id, Assignment.assigned_on, Prompt.theme)
            .join(Prompt, Prompt.id == Assignment.prompt_id)
            .where(*clauses)
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
    user_id: uuid.UUID | None = None,
) -> Prompt | None:
    """The signature `docs/data-model.md` describes: one child, one slot, one date.

    A thin wrapper that loads the pool and this child's history, then hands both to the pure
    :func:`choose_prompt`.

    `user_id` names the guardian a daily slot is being picked for, and scopes the history to
    them. It stays None for the shared slots, whose behaviour is unchanged.
    """
    from rascal.services.dates import age_in_months

    spec = SLOT_SPECS[slot]
    candidates = await _candidates(session, spec, child.id)
    served, themes = await _history(session, child.id, as_of_date, user_id)
    return choose_prompt(
        candidates,
        age_months=age_in_months(child.birthdate, as_of_date),
        month=as_of_date.month,
        served_recently=served,
        recent_themes=themes,
        rng=rng or random.Random(),
    )


#: The daily slots each weekday produces, keyed on `dt.date.weekday()` — Monday is 0.
#:
#: **The rotation is phase 107 and it replaces "all three, every day".** A weekday now carries
#: the question and *one* mission; the weekend carries both. That gives `mission` five days a
#: week and `mission_b` four, which is the split row 111 of `docs/decisions.md` made the two
#: slots for — a photo is the thing a parent can do in ten seconds, and the video, audio and
#: activity pool is the one that needs an afternoon.
#:
#: **The pools are untouched.** `mission` is still photo-only and `mission_b` is still
#: video/audio/activity, per row 112, whose narrowing is already migration-dated. The rotation
#: is what changed; widening either pool to compensate would make rows on three sides of two
#: decisions all "correct" at once.
_DAILY_ROTATION: dict[int, tuple[Slot, ...]] = {
    0: ("question", "mission"),  # Monday
    1: ("question", "mission_b"),  # Tuesday
    2: ("question", "mission"),  # Wednesday
    3: ("question", "mission_b"),  # Thursday
    4: ("question", "mission"),  # Friday
    5: ("question", "mission", "mission_b"),  # Saturday
    6: ("question", "mission", "mission_b"),  # Sunday
}


def slots_for(day: dt.date) -> list[Slot]:
    """What this calendar day holds: the rotation, plus whatever the date itself fires.

    **`day` is a date in the child's `family_timezone`, always.** Every caller derives it
    through :func:`rascal.services.dates.local_date` and this function takes it as given — it
    has no clock and no zone of its own, which is what keeps a Saturday in Auckland from being
    read as a Friday because UTC said so. A parent in Auckland is entitled to the Saturday.

    The daily slots rotate by weekday (see :data:`_DAILY_ROTATION`): question plus `mission` on
    Monday, Wednesday and Friday; question plus `mission_b` on Tuesday and Thursday; question
    plus both at the weekend.

    The weekly, monthly and letter slots fire **on top of them, unconditionally** — they are
    not suppressed to keep the count down. Every shape the calendar produces, enumerated rather
    than described, because an earlier draft of this sentence got the 15th wrong:

    ====================  =====
    Day                   Items
    ====================  =====
    ordinary weekday          2
    weekday, 1st or 15th      3
    Sunday                    3
    Sunday, 1st or 15th       4
    Saturday                  4
    Saturday, 1st or 15th     5
    ====================  =====

    So **the worst day the calendar can produce is still five** — a Saturday that is also the
    1st or the 15th — and the floor dropped from three to two. The rotation lowered the floor
    without moving the ceiling, which is why `docs/data-model.md`'s stated maximum did not
    change. `test_entitlement_cadence.py` walks four years and asserts nothing beats five.

    The letter stays on the 15th rather than the 1st for the reason it was moved there: it
    keeps the money letter from losing a coin flip to a height measurement every month.
    """
    slots: list[Slot] = list(_DAILY_ROTATION[day.weekday()])
    if day.weekday() == 5:  # Saturday
        slots.append("weekly")
    if day.day == 1:
        slots.append("monthly")
    if day.day == 15:
        slots.append("letter")
    return slots


def locked_slots_for(day: dt.date, *, entitled: bool) -> list[Slot]:
    """The slots this day holds that a household may not have. `[]` when it is entitled.

    The complement of :data:`rascal.constants.FREE_SLOTS` within :func:`slots_for`, computed
    from the same list so a slot cannot be added to the day and forgotten here. `GET /today`
    renders these as `locked[]`, and it is the only thing that does.
    """
    if entitled:
        return []
    return [slot for slot in slots_for(day) if slot not in FREE_SLOTS]


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
    user_id: uuid.UUID | None = None,
) -> None:
    """Fill one slot for one child — and, for a daily slot, for one guardian.

    `user_id` is required for the three daily slots and must be None for the three shared
    ones. `ck_assignments_user_id_by_slot` enforces that, so a caller that gets it wrong
    fails loudly at the INSERT rather than writing a row nothing will ever read.
    """
    is_daily = slot in DAILY_SLOTS

    # Cheap pre-check so an already-filled slot does not burn a selection. The unique index
    # is still what guarantees correctness under a concurrent run.
    clauses = [
        Assignment.child_id == child.id,
        Assignment.assigned_on == day,
        Assignment.slot == slot,
    ]
    if is_daily:
        clauses.append(Assignment.user_id == user_id)
    already = await session.scalar(select(Assignment.id).where(*clauses))
    if already is not None:
        run.skipped_existing += 1
        return

    prompt = await select_prompt(child, slot, day, session, rng=rng, user_id=user_id)
    if prompt is None:
        # No fake data and no fallback prompt: an empty slot is honest, and the log line
        # says which child and which slot to go and fix.
        run.exhausted.append(f"{child.id}:{slot}")
        log.warning(
            "no eligible prompt",
            extra={
                "child_id": str(child.id),
                "slot": slot,
                "assigned_on": day.isoformat(),
                "user_id": str(user_id) if user_id else None,
            },
        )
        return

    # **Both arms must name their partial index's predicate.** Postgres will not infer a
    # partial unique index from `index_elements` alone — without `index_where` this raises
    # "no unique or exclusion constraint matching the ON CONFLICT specification", and with
    # the *wrong* predicate it would silently match nothing. This is what keeps reruns free.
    if is_daily:
        conflict = {
            "index_elements": [
                Assignment.child_id,
                Assignment.user_id,
                Assignment.assigned_on,
                Assignment.slot,
            ],
            "index_where": text(_DAILY_PREDICATE),
        }
    else:
        conflict = {
            "index_elements": [
                Assignment.child_id,
                Assignment.assigned_on,
                Assignment.slot,
            ],
            "index_where": text(_SHARED_PREDICATE),
        }

    result = await session.execute(
        insert(Assignment)
        .values(
            id=uuid.uuid4(),
            child_id=child.id,
            user_id=user_id if is_daily else None,
            prompt_id=prompt.id,
            slot=slot,
            assigned_on=day,
            expires_on=day + dt.timedelta(days=DEFAULT_EXPIRY_DAYS),
            status="pending",
        )
        .on_conflict_do_nothing(**conflict)
        .returning(Assignment.id)
    )
    if result.scalar_one_or_none() is None:
        run.skipped_existing += 1
    else:
        run.created += 1


async def _filled_slots(
    session: AsyncSession, child_id: uuid.UUID, day: dt.date
) -> set[tuple[str, uuid.UUID | None]]:
    """Which (slot, guardian) pairs already have a row for this child on that day.

    One indexed lookup. Since phase 36 the key is a pair rather than a slot name, because
    `question` filled for one parent says nothing about the other.
    """
    rows = await session.execute(
        select(Assignment.slot, Assignment.user_id).where(
            Assignment.child_id == child_id, Assignment.assigned_on == day
        )
    )
    return {(slot, user_id) for slot, user_id in rows.all()}


def _wanted_pairs(
    day: dt.date,
    parents: list[uuid.UUID],
    entitled: dict[uuid.UUID, bool] | None = None,
) -> list[tuple[Slot, uuid.UUID | None]]:
    """Every (slot, guardian) this child should have on `day`, entitlement already applied.

    A daily slot is owed once per parent; a shared slot once per child. With one parent this
    produces exactly what the pre-phase-36 scheduler produced, which is what makes the change
    invisible to a single-guardian household.

    `entitled` maps each active parent to whether their household may be served more than the
    daily question — see :func:`_active_parents`. **`None` means "do not gate"**, which is what
    a caller that has already decided (or a test exercising the calendar alone) wants; it is
    not a default anything in production takes.
    """
    pairs: list[tuple[Slot, uuid.UUID | None]] = []
    for slot in slots_for(day):
        if slot in DAILY_SLOTS:
            pairs.extend((slot, parent) for parent in parents)
        else:
            pairs.append((slot, None))
    if entitled is None:
        return pairs
    return [pair for pair in pairs if _serve(pair[0], pair[1], entitled)]


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
    parents = await _active_parents(session, child.id)
    wanted = _wanted_pairs(day, list(parents), parents)
    present = await _filled_slots(session, child.id, day)
    missing = [pair for pair in wanted if pair not in present]
    run.skipped_existing = len(wanted) - len(missing)
    if not missing:
        return run

    rng = random.Random(seed)
    for slot, user_id in missing:
        # Slot and guardian order are both deterministic, so two concurrent readers take the
        # unique index's locks in the same order and one simply waits rather than deadlocking.
        await _fill_slot(session, child, slot, day, rng, run, user_id)
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

    **Entitlement is evaluated as of the run, never as of `as_of_date`, and a backfill is the
    case that makes the difference visible.** Backfilling a week a household was subscribed
    for, after it has lapsed, fills only the question — because the alternative is writing
    assignment rows for a household that cannot see them, which burns the 180-day cooldown
    exactly as filling today's would. The archive is not being reconstructed here; slots are
    being offered, and an offer is made in the present.
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
        parents = await _active_parents(session, child.id, now=instant)
        if not parents:
            # A child with no active parent gets no daily prompts, because there is nobody to
            # serve them to. Shared slots still fire — they belong to the child. Worth a line
            # in the log rather than silence: it is either a revoked guardian or a data bug.
            log.warning("child has no active parent", extra={"child_id": str(child.id)})
        for slot, user_id in _wanted_pairs(day, list(parents), parents):
            await _fill_slot(session, child, slot, day, rng, run, user_id)

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
