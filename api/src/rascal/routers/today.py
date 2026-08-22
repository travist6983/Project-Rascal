"""The Today screen and the two actions it can take on an assignment."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import selectinload

from rascal.constants import LOCKED_KIND_HINTS
from rascal.deps import ChildAccess, SessionDep, assignment_access, child_access
from rascal.errors import not_found
from rascal.models import Assignment
from rascal.schemas.child import ChildSummary
from rascal.schemas.today import (
    AssignmentOut,
    CustomAssignmentRequest,
    LockedSlot,
    TodayResponse,
)
from rascal.services.dates import age_in_months, local_date
from rascal.services.guardians import access_for_family
from rascal.services.scheduler import ensure_day_filled, locked_slots_for
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
        "never by a client.\n\n"
        "`access` and `trial_ends_at` describe the caller's household, and `locked` lists the "
        "slots today holds that it may not have — slot and a kind hint, never a prompt. "
        "`locked` is `[]` for an entitled household and is never absent."
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
    # the same instant read the scheduler takes. Everything downstream — which slots today
    # holds, which of them are locked, the `done_today` window — is derived from this one
    # date, so a Saturday in Auckland is a Saturday here and not the Friday UTC would say.
    local_today = local_date(dt.datetime.now(tz=dt.UTC), child.family_timezone)
    on = date or local_today

    # **The gate, and this endpoint is its authority.** Read once, from the one function that
    # `GET /families/me` and `GET /families/{id}/entitlement` also read — not recomputed here,
    # because an entitlement check copied into a second place is the one that eventually
    # disagrees with the first about whether somebody paid.
    #
    # The caller's household rather than the child's: the daily slots are served per guardian,
    # so the rows this reader can see are the ones the scheduler wrote against this same
    # household. Read and write agree by construction.
    household = await access_for_family(session, access.user.family_id)

    # The scheduler is an optimisation, not a dependency. A missed run — a stopped machine,
    # a Fly outage, a database that was asleep at 5am — costs a few milliseconds here
    # instead of a whole day of the archive.
    #
    # Only for the real local date. `?date=` is a debugging override, and a read endpoint
    # that can be made to write assignments into an arbitrary past or future is a different
    # and much worse thing than a read endpoint.
    #
    # This is also what makes subscribing mid-day work: `ensure_day_filled` re-reads the
    # household's entitlement itself, so the first read after a webhook lands fills the
    # missions this morning's run correctly refused to.
    if on == local_today:
        await ensure_day_filled(session, child, local_today)

    today_items, waiting, done_today = await assignments_for(
        session, child, on, access.user.id, entitled=household.entitled
    )

    return TodayResponse(
        date=on,
        child=ChildSummary(
            id=child.id,
            name=child.name,
            age_months=age_in_months(child.birthdate, on),
        ),
        access=household.access,
        trial_ends_at=household.trial_ends_at,
        today=[to_assignment_out(item) for item in today_items],
        # The shape of what is missing, never the thing itself: no id, no body, no prompt and
        # no theme. `[]` for an entitled household — a value, not an absence.
        locked=[
            LockedSlot(slot=slot, kind_hint=LOCKED_KIND_HINTS[slot])
            for slot in locked_slots_for(on, entitled=household.entitled)
        ],
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
