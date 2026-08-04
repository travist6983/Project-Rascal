"""On This Day."""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, Query

from rascal.deps import ChildAccess, SessionDep, child_access
from rascal.schemas.moments import MomentGroup, MomentsResponse
from rascal.services.dates import today_in
from rascal.services.entries import moments_for, to_entry_out

router = APIRouter(tags=["moments"])


@router.get(
    "/children/{child_id}/moments",
    response_model=MomentsResponse,
    summary="Entries from this month and day in prior years",
    description=(
        "Grouped by years-ago. When there is nothing, `fallback` is `random` and `entries` "
        "carries a handful of real memories instead, so the screen is never a void."
    ),
)
async def moments(
    child_id: uuid.UUID,
    session: SessionDep,
    date: dt.date | None = Query(default=None, description="Defaults to the child's today."),
    access: ChildAccess = Depends(child_access("viewer")),
) -> MomentsResponse:
    on = date or today_in(access.child.family_timezone)
    grouped, fallback = await moments_for(session, access.child, on)

    if grouped:
        return MomentsResponse(
            date=on,
            fallback=None,
            groups=[
                MomentGroup(years_ago=years, entries=[to_entry_out(e) for e in rows])
                for years, rows in grouped
            ],
            entries=[],
        )
    return MomentsResponse(
        date=on,
        fallback="random",
        groups=[],
        entries=[to_entry_out(entry) for entry in fallback],
    )
