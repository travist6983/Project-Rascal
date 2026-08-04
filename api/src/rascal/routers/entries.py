"""Entries: the archive."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response, status
from fastapi.encoders import jsonable_encoder

from rascal.constants import EntryType
from rascal.deps import (
    ChildAccess,
    SessionDep,
    child_access_from_body,
    child_access_from_query,
    entry_access,
)
from rascal.models import Prompt
from rascal.schemas.entry import EntryCreate, EntryDetail, EntryOut, EntryPage, EntryUpdate
from rascal.services import entries as service
from rascal.services.idempotency import remember, replay

router = APIRouter(tags=["entries"])

CREATE_ENDPOINT = "POST /v1/entries"


@router.post(
    "/entries",
    response_model=EntryOut,
    status_code=status.HTTP_201_CREATED,
    summary="Create an entry",
    description=(
        "Send `Idempotency-Key` and retries are safe: a replay returns the original 201 body, "
        "never a second row and never a 409. The server computes and stores "
        "`child_age_months` from `occurred_at` minus the birthdate, and flips a pending "
        "assignment to done in the same transaction."
    ),
)
async def create_entry(
    payload: EntryCreate,
    session: SessionDep,
    response: Response,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    access: ChildAccess = Depends(child_access_from_body("parent")),
) -> EntryOut:
    if idempotency_key:
        previous = await replay(session, access.user.id, idempotency_key, CREATE_ENDPOINT)
        if previous is not None:
            stored_status, body = previous
            response.status_code = stored_status
            return EntryOut.model_validate(body)

    entry = await service.create_entry(
        session,
        access.child,
        access.user,
        entry_id=payload.id,
        occurred_at=payload.occurred_at,
        assignment_id=payload.assignment_id,
        title=payload.title,
        body=payload.body,
        unlock_at_age=payload.unlock_at_age,
        tags=payload.tags,
    )
    result = service.to_entry_out(entry)

    if idempotency_key:
        await remember(
            session,
            access.user.id,
            idempotency_key,
            CREATE_ENDPOINT,
            status.HTTP_201_CREATED,
            jsonable_encoder(result),
        )
    return result


@router.get(
    "/entries",
    response_model=EntryPage,
    summary="The timeline, newest first by occurred_at — or search results, best match first",
    description=(
        "Keyset-paginated on `(occurred_at, id)`, never OFFSET — backdating inserts rows "
        "into the middle of the order and offset paging would skip them. Media summaries "
        "come inline so the timeline renders without N+1 calls. Soft-deleted entries are "
        "excluded here; use `GET /sync` to see them.\n\n"
        "Passing `q` switches this to full-text search over titles, bodies, and the "
        "transcripts the phone wrote back — ordered by relevance, then newest first, and "
        "keyset-paginated on `(rank, occurred_at, id)`. A cursor from one mode is not valid "
        "in the other. Every other filter still applies."
    ),
)
async def list_entries(
    session: SessionDep,
    before: dt.datetime | None = Query(default=None, description="occurred_at strictly before"),
    after: dt.datetime | None = Query(default=None, description="occurred_at strictly after"),
    type: EntryType | None = Query(default=None, description="Filter by entry_type"),
    tag: str | None = Query(default=None),
    q: str | None = Query(
        default=None,
        description=(
            "Full-text search over title, body, caption, and transcript. Words are stemmed, "
            'so "running" finds "ran". Supports "exact phrase" and -excluded.'
        ),
    ),
    limit: int = Query(default=service.DEFAULT_PAGE_SIZE, ge=1, le=service.MAX_PAGE_SIZE),
    cursor: str | None = Query(default=None, description="Opaque; from a previous next_cursor"),
    access: ChildAccess = Depends(child_access_from_query("viewer")),
) -> EntryPage:
    rows, next_cursor = await service.list_entries(
        session,
        access.child_id,
        before=before,
        after=after,
        entry_type=type,
        tag=tag,
        query=q,
        limit=limit,
        cursor=cursor,
    )
    return EntryPage(
        entries=[service.to_entry_out(entry) for entry in rows], next_cursor=next_cursor
    )


@router.get(
    "/entries/{entry_id}",
    response_model=EntryDetail,
    summary="One entry, with media, transcripts, tags, and the originating prompt",
)
async def get_entry(
    entry_id: uuid.UUID,
    session: SessionDep,
    access: ChildAccess = Depends(entry_access("viewer")),
) -> EntryDetail:
    entry = await service.load_entry(session, entry_id)
    prompt = None
    if entry.assignment_id is not None:
        from rascal.models import Assignment

        assignment = await session.get(Assignment, entry.assignment_id)
        if assignment is not None and assignment.prompt_id is not None:
            prompt = await session.get(Prompt, assignment.prompt_id)
    return service.to_entry_detail(entry, prompt)


@router.patch(
    "/entries/{entry_id}",
    response_model=EntryOut,
    summary="Edit title, body, occurred_at, unlock_at_age, or tags",
)
async def update_entry(
    entry_id: uuid.UUID,
    payload: EntryUpdate,
    session: SessionDep,
    access: ChildAccess = Depends(entry_access("parent")),
) -> EntryOut:
    entry = await service.load_entry(session, entry_id)
    updated = await service.update_entry(
        session, entry, access.child, fields=payload.model_dump(exclude_unset=True)
    )
    return service.to_entry_out(updated)


@router.delete(
    "/entries/{entry_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Soft delete",
    description=(
        "Sets `deleted_at` and keeps the row. Nothing is ever hard-deleted — the archive is "
        "supposed to outlive the app, and the deletion syncs as a row so clients propagate it."
    ),
)
async def delete_entry(
    entry_id: uuid.UUID,
    session: SessionDep,
    access: ChildAccess = Depends(entry_access("parent")),
) -> None:
    entry = await service.load_entry(session, entry_id)
    await service.soft_delete_entry(session, entry)
