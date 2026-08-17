"""Sync: pull since a cursor, push a batched offline queue."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query

from rascal.deps import (
    ChildAccess,
    SessionDep,
    child_access_from_body,
    child_access_from_query,
)
from rascal.schemas.sync import MAX_PUSH_BATCH, SyncPushRequest, SyncPushResponse, SyncResponse
from rascal.services import sync as service

router = APIRouter(prefix="/sync", tags=["sync"])


@router.get(
    "",
    response_model=SyncResponse,
    summary="Everything that changed since a cursor",
    description=(
        "Entries, media, assignments, and entry-tag links whose `updated_at` is after "
        "`since`, **including soft-deleted rows** — a client cannot infer a delete from a "
        "missing record. Omit `since` for a full snapshot.\n\n"
        "**The response is a page.** Each of the four collections is capped at `limit` rows, "
        "and `has_more` is true while any of them was cut. Feed `cursor` back as `since` and "
        "call again until `has_more` is false; a client that stops earlier has a hole in its "
        "archive. The cursor is deliberately lagged, so a pull re-delivers rows already seen "
        "— upsert by id."
    ),
)
async def pull(
    session: SessionDep,
    since: dt.datetime | None = Query(
        default=None, description="Only rows updated strictly after this instant."
    ),
    limit: int = Query(
        default=service.DEFAULT_PAGE_SIZE,
        ge=1,
        le=service.MAX_PAGE_SIZE,
        description=(
            "Max rows per collection. Raise it if `cursor` stops advancing while `has_more` "
            "is true — that means one collection holds a whole page inside the cursor's "
            "overlap window."
        ),
    ),
    access: ChildAccess = Depends(child_access_from_query("viewer")),
) -> SyncResponse:
    return await service.pull(session, access.child, since, access.user.id, limit=limit)


@router.post(
    "/push",
    response_model=SyncPushResponse,
    summary="Drain a batched offline queue",
    description=(
        "Per-record accept/conflict so a client reconciles without a full refetch. Last write "
        "wins on entries. `idempotency_keys` maps a record id to a key, so a retried batch "
        "applies nothing twice.\n\n"
        f"**At most {MAX_PUSH_BATCH} entries and {MAX_PUSH_BATCH} media per call**; more is a "
        "`422` and the client drains in pages. The whole batch applies in one transaction, "
        "which has to finish inside the 30-second cursor overlap window — a longer one "
        "commits rows already behind another device's cursor.\n\n"
        "No cursor comes back: a cursor is the newest `updated_at` actually returned, and a "
        "push returns no rows. Pull afterwards from the cursor you already hold — that is "
        "also how the server's `entry_type` and `child_age_months` corrections reach you."
    ),
)
async def push(
    payload: SyncPushRequest,
    session: SessionDep,
    access: ChildAccess = Depends(child_access_from_body("parent")),
) -> SyncPushResponse:
    entries, media = await service.push(
        session,
        access.child,
        access.user,
        entries=payload.entries,
        media=payload.media,
        idempotency_keys=payload.idempotency_keys,
    )
    return SyncPushResponse(entries=entries, media=media)
