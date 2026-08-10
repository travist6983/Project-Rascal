"""The Today screen and the two actions it can take on an assignment."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import selectinload

from rascal.deps import ChildAccess, SessionDep, assignment_access, child_access
from rascal.errors import not_found
from rascal.models import Assignment
from rascal.schemas.child import ChildSummary
from rascal.schemas.today import AssignmentOut, CustomAssignmentRequest, TodayResponse
from rascal.services.dates import age_in_months, local_date
from rascal.services.scheduler import ensure_day_filled
from rascal.services.today import assignments_for, to_assignment_out

router = APIRouter(tags=["today"])


async def _reload(session, assignment_id: uuid.UUID) -> Assignment:
    from sqlalchemy import select

    assignment = await session.scalar(
        select(Assignment)
        .where(Assignment.id == assignment_id)
        .options(selectinload(Assignment.prompt))
    )
    if assignment is None:
        raise not_found("Assignment")
    return assignment


@router.get(
    "/children/{child_id}/today",
    response_model=TodayResponse,
    summary="Everything the Today screen renders, in one call",
    description=(
        "`today` is what was assigned for the child's local date, `waiting` is pending "
        "assignments from previous days oldest first, and `done_today` is anything completed "
        "with `occurred_at` today. The date is computed in the child's `family_timezone`, "
        "never by a client."
    ),
)
async def today(
    child_id: uuid.UUID,
    session: SessionDep,
    date: dt.date | None = Query(
        default=None, description="Override the computed local date. Mostly for debugging."
    ),
    access: ChildAccess = Depends(child_access("viewer")),
) -> TodayResponse:
    child = access.child
    # The one definition of "today": the date in this child's own family_timezone, which is
    # the same instant read the scheduler takes.
    local_today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    on = date or local_today

    # The scheduler is an optimisation, not a dependency. A missed run — a stopped machine,
    # a Fly outage, a database that was asleep at 5am — costs a few milliseconds here
    # instead of a whole day of the archive.
    #
    # Only for the real local date. `?date=` is a debugging override, and a read endpoint
    # that can be made to write assignments into an arbitrary past or future is a different
    # and much worse thing than a read endpoint.
    if on == local_today:
        await ensure_day_filled(session, child, local_today)

    today_items, waiting, done_today = await assignments_for(session, child, on)

    return TodayResponse(
        date=on,
        child=ChildSummary(
            id=child.id,
            name=child.name,
            age_months=age_in_months(child.birthdate, on),
        ),
        today=[to_assignment_out(item) for item in today_items],
        waiting=[to_assignment_out(item) for item in waiting],
        done_today=[to_assignment_out(item) for item in done_today],
    )


@router.post(
    "/assignments/{assignment_id}/dismiss",
    response_model=AssignmentOut,
    summary="Dismiss an assignment",
    description="Not every prompt fits every family. Dismissing is not failing.",
)
async def dismiss(
    assignment_id: uuid.UUID,
    session: SessionDep,
    access: ChildAccess = Depends(assignment_access("parent")),
) -> AssignmentOut:
    assignment = await _reload(session, assignment_id)
    if assignment.status == "pending":
        assignment.status = "dismissed"
        await session.flush()
    return to_assignment_out(assignment)


@router.post(
    "/assignments/{assignment_id}/custom",
    response_model=AssignmentOut,
    summary="Replace an assignment with a parent-authored one",
    description="Keeps the slot filled. `custom_body` wins over the prompt it replaced.",
)
async def customize(
    assignment_id: uuid.UUID,
    payload: CustomAssignmentRequest,
    session: SessionDep,
    access: ChildAccess = Depends(assignment_access("parent")),
) -> AssignmentOut:
    assignment = await _reload(session, assignment_id)
    assignment.custom_body = payload.body
    # Rewriting the item makes it live again — you would not author one to leave it dismissed.
    if assignment.status in ("dismissed", "expired"):
        assignment.status = "pending"
    await session.flush()
    return to_assignment_out(assignment)
