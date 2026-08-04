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

from rascal.deps import ChildAccess, CurrentUser, SessionDep, child_access_from_body
from rascal.errors import not_authorized
from rascal.models import Assignment, Guardian
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
    # way to schedule for someone else's kid.
    mine = set(
        (
            await session.execute(
                select(Guardian.child_id).where(
                    Guardian.user_id == user.id, Guardian.revoked_at.is_(None)
                )
            )
        ).scalars()
    )
    if payload.child_id is not None:
        if payload.child_id not in mine:
            raise not_authorized()
        mine = {payload.child_id}

    totals = SchedulerRunResponse(created=0, skipped_existing=0, expired=0, exhausted=[])
    for child_id in sorted(mine):
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
