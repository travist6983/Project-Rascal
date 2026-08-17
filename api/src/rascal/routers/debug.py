"""Local-only debug routes.

Registered only when `ENVIRONMENT == "local"`, the same gating as `dev-login`. These exist
because building the daily loop means running the daily loop dozens of times in one evening,
and waiting until 5am tomorrow is not a development strategy.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends
from pydantic import Field
from sqlalchemy import delete, select

from rascal.constants import DAILY_SLOTS, SLOTS
from rascal.deps import (
    ChildAccess,
    CurrentUser,
    SessionDep,
    child_access_from_body,
    require_child_access,
)
from rascal.models import Assignment, Guardian, Prompt
from rascal.schemas.common import ApiModel
from rascal.services.dates import today_in
from rascal.services.scheduler import run_scheduler

router = APIRouter(prefix="/debug", tags=["debug"])


class SchedulerRunRequest(ApiModel):
    date: dt.date | None = Field(
        default=None, description="Run this calendar day. Defaults to now, per child timezone."
    )
    child_id: uuid.UUID | None = None
    seed: int | None = Field(default=None, description="Seed the picker for a repeatable run.")


class SchedulerRunResponse(ApiModel):
    created: int
    skipped_existing: int
    expired: int
    exhausted: list[str]


class ResetTodayRequest(ApiModel):
    child_id: uuid.UUID
    date: dt.date | None = None


class ResetTodayResponse(ApiModel):
    child_id: uuid.UUID
    date: dt.date
    deleted: int


@router.post(
    "/scheduler/run",
    response_model=SchedulerRunResponse,
    summary="Run the scheduler for an arbitrary date",
    description="Idempotent, exactly like the real job. Rerunning the same date creates nothing.",
)
async def scheduler_run(
    payload: SchedulerRunRequest, session: SessionDep, user: CurrentUser
) -> SchedulerRunResponse:
    # Scoped to the caller's own children even here, so a shared local database is never a
    # way to schedule for someone else's kid — and running the scheduler writes assignments,
    # so `parent` is the bar, exactly as it is on the two routes below. `child_id` is optional
    # in this payload, which is the one thing `child_access_from_body` cannot express, so this
    # calls the same check the dependency wraps rather than restating it.
    if payload.child_id is not None:
        access = await require_child_access(session, user, payload.child_id, "parent")
        child_ids = {access.child_id}
    else:
        child_ids = set(
            (
                await session.execute(
                    select(Guardian.child_id).where(
                        Guardian.user_id == user.id,
                        Guardian.role == "parent",
                        Guardian.revoked_at.is_(None),
                    )
                )
            ).scalars()
        )

    totals = SchedulerRunResponse(created=0, skipped_existing=0, expired=0, exhausted=[])
    for child_id in sorted(child_ids):
        run = await run_scheduler(
            session, as_of_date=payload.date, child_id=child_id, seed=payload.seed
        )
        totals.created += run.created
        totals.skipped_existing += run.skipped_existing
        totals.expired += run.expired
        totals.exhausted.extend(run.exhausted)
    return totals


@router.post(
    "/reset-today",
    response_model=ResetTodayResponse,
    summary="Clear a child's assignments for a day",
    description=(
        "So the loop can be re-run against a changed prompt library. This is the one place "
        "in the service that hard-deletes rows — assignments are scheduler output, not "
        "archive, and it exists only in a local build."
    ),
)
async def reset_today(
    payload: ResetTodayRequest,
    session: SessionDep,
    access: ChildAccess = Depends(child_access_from_body("parent")),
) -> ResetTodayResponse:
    day = payload.date or today_in(access.child.family_timezone)
    result = await session.execute(
        delete(Assignment).where(
            Assignment.child_id == access.child_id, Assignment.assigned_on == day
        )
    )
    return ResetTodayResponse(child_id=access.child_id, date=day, deleted=result.rowcount or 0)


class BoardResetRequest(ApiModel):
    child_id: uuid.UUID
    kinds: list[str] = Field(
        default_factory=lambda: ["question", "photo", "video", "audio", "activity"],
        description="One pending assignment per kind, in this order.",
    )


class BoardResetResponse(ApiModel):
    date: dt.date
    cleared: int
    created: list[str]
    unavailable: list[str]


@router.post(
    "/board",
    response_model=BoardResetResponse,
    summary="Reset today to exactly one assignment per kind",
    description=(
        "A test fixture, not a scheduler. The real scheduler fills slots — a question, a photo "
        "mission, a second mission — so it cannot produce one of every *kind* on demand, and "
        "exercising the photo and video paths meant hand-editing rows. This does that in one "
        "call. Local only, like every route in this file."
    ),
)
async def reset_board(
    payload: BoardResetRequest,
    session: SessionDep,
    access: ChildAccess = Depends(child_access_from_body("parent")),
) -> BoardResetResponse:
    day = today_in(access.child.family_timezone)

    # Hard delete, like reset-today: assignments are scheduler output rather than archive, and
    # this is the one place in the service allowed to treat them that way.
    cleared = await session.execute(
        delete(Assignment).where(
            Assignment.child_id == access.child_id, Assignment.assigned_on == day
        )
    )

    created: list[str] = []
    unavailable: list[str] = []

    # `uq_assignments_child_id_assigned_on_slot` allows one assignment per slot per day — the
    # "one child, one slot, one date" signature in docs/data-model.md. A test board wanting one
    # of every *kind* therefore has to spread them across slots, because photo, video and
    # activity would otherwise all want `mission` and the second insert would fail.
    #
    # Derived from `SLOTS` rather than listed, because a hardcoded copy is one more place a new
    # slot has to be remembered — and this one was already missing `mission_b` and `letter`.
    # `question` and `letter` are excluded because the two branches below claim them by kind.
    spare_slots = [slot for slot in SLOTS if slot not in ("question", "letter")]

    for kind in payload.kinds:
        prompt = await session.scalar(
            select(Prompt)
            .where(Prompt.kind == kind, Prompt.active.is_(True), Prompt.cadence == "daily")
            .order_by(Prompt.id)
            .limit(1)
        )
        if prompt is None:
            # A kind with no daily prompt to serve. Nothing is inactive today — video came
            # back with multipart upload and audio with the recorder — but saying so beats
            # silently returning a shorter board than was asked for.
            unavailable.append(kind)
            continue

        if kind == "question":
            slot = "question"
        elif kind == "letter":
            slot = "letter"
        elif spare_slots:
            slot = spare_slots.pop(0)
        else:
            unavailable.append(kind)
            continue

        session.add(
            Assignment(
                child_id=access.child_id,
                # The caller is a guardian of this child — `child_access` proved it — so a
                # board built for them is a board they own. Daily slots require an owner and
                # shared slots must not have one, per `ck_assignments_user_id_by_slot`.
                user_id=access.user.id if slot in DAILY_SLOTS else None,
                prompt_id=prompt.id,
                slot=slot,
                assigned_on=day,
                expires_on=day + dt.timedelta(days=14),
                status="pending",
            )
        )
        created.append(kind)

    await session.flush()
    return BoardResetResponse(
        date=day, cleared=cleared.rowcount or 0, created=created, unavailable=unavailable
    )
