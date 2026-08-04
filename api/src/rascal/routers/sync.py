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
from rascal.schemas.sync import SyncPushRequest, SyncPushResponse, SyncResponse
from rascal.services import sync as service

router = APIRouter(prefix="/sync", tags=["sync"])


@router.get(
    "",
    response_model=SyncResponse,
    summary="Everything that changed since a cursor",
    description=(
        "Entries, media, assignments, and entry-tag links whose `updated_at` is after "
        "`since`, **including soft-deleted rows** — a client cannot infer a delete from a "
        "missing record. Omit `since` for a full snapshot. Feed `cursor` back on the next call."
    ),
)
async def pull(
    session: SessionDep,
    since: dt.datetime | None = Query(
        default=None, description="Only rows updated strictly after this instant."
    ),
    access: ChildAccess = Depends(child_access_from_query("viewer")),
) -> SyncResponse:
    return await service.pull(session, access.child, since)


@router.post(
    "/push",
    response_model=SyncPushResponse,
    summary="Drain a batched offline queue",
    description=(
        "Per-record accept/conflict so a client reconciles without a full refetch. Last write "
        "wins on entries. `idempotency_keys` maps a record id to a key, so a retried batch "
        "applies nothing twice."
    ),
)
async def push(
    payload: SyncPushRequest,
    session: SessionDep,
    access: ChildAccess = Depends(child_access_from_body("parent")),
) -> SyncPushResponse:
    entries, media, cursor = await service.push(
        session,
        access.child,
        access.user,
        entries=payload.entries,
        media=payload.media,
        idempotency_keys=payload.idempotency_keys,
    )
    return SyncPushResponse(entries=entries, media=media, cursor=cursor)
