"""Pull-since-cursor and the offline push drain.

Sync filters on `updated_at`, never `occurred_at`. Soft-deleted rows are included — a client
cannot infer a delete from a missing record, so deletions have to arrive as rows.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.errors import RascalError
from rascal.models import Assignment, Child, Entry, EntryTag, Media, Tag, User
from rascal.schemas.media import MediaOut
from rascal.schemas.sync import (
    PushEntry,
    PushMedia,
    PushResult,
    SyncAssignment,
    SyncResponse,
    SyncTag,
)
from rascal.services.dates import age_at_instant
from rascal.services.entries import (
    apply_tags,
    create_entry,
    loaded,
    refresh_entry_type,
    to_entry_out,
)
from rascal.services.idempotency import remember, replay
from rascal.services.today import to_assignment_out

PUSH_ENDPOINT = "POST /v1/sync/push"

# set_updated_at() uses now(), which is transaction-*start* time, so a row can commit with an
# updated_at already behind a cursor another device advanced past — and then never sync
# again. The cursor is handed back lagged by this much, so any row written by a transaction
# shorter than the window is re-delivered rather than lost. Clients upsert by id, and
# re-delivery is free: entries are last-write-wins on a client-generated UUID.
#
# The window bounds the longest write transaction. A POST /sync/push batch must stay well
# under it; if batch push ever grows past 30s, this grows with it.
CURSOR_OVERLAP_SECONDS = 30


def _now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


async def pull(session: AsyncSession, child: Child, since: dt.datetime | None) -> SyncResponse:
    """Everything about this child that changed after `since`, deletions included."""

    def _after(column):
        return column > since if since is not None else column.is_not(None)

    entries = list(
        (
            await session.execute(
                # `loaded` rather than a hand-written options list. This used to restate the
                # eager loads, which meant every field `to_entry_out` learned to read had to
                # be remembered in two places — and `prompt_body` was the one that proved it,
                # because the miss is a lazy-load raise on the sync path only.
                loaded(select(Entry))
                .where(Entry.child_id == child.id, _after(Entry.updated_at))
                .order_by(Entry.updated_at.asc())
            )
        )
        .scalars()
        .all()
    )

    media = list(
        (
            await session.execute(
                select(Media)
                .join(Entry, Entry.id == Media.entry_id)
                .where(Entry.child_id == child.id, _after(Media.updated_at))
                .order_by(Media.updated_at.asc())
            )
        )
        .scalars()
        .all()
    )

    assignments = list(
        (
            await session.execute(
                select(Assignment)
                .where(Assignment.child_id == child.id, _after(Assignment.updated_at))
                .options(selectinload(Assignment.prompt))
                .order_by(Assignment.updated_at.asc())
            )
        )
        .scalars()
        .all()
    )

    tag_rows = list(
        (
            await session.execute(
                select(EntryTag, Tag.name)
                .join(Tag, Tag.id == EntryTag.tag_id)
                .join(Entry, Entry.id == EntryTag.entry_id)
                .where(Entry.child_id == child.id, _after(EntryTag.updated_at))
                .order_by(EntryTag.updated_at.asc())
            )
        ).all()
    )

    stamps = [
        *(row.updated_at for row in entries),
        *(row.updated_at for row in media),
        *(row.updated_at for row in assignments),
        *(link.updated_at for link, _ in tag_rows),
    ]
    # Lagged deliberately — see CURSOR_OVERLAP_SECONDS.
    newest = max(stamps) if stamps else _now()
    cursor = newest - dt.timedelta(seconds=CURSOR_OVERLAP_SECONDS)

    return SyncResponse(
        entries=[to_entry_out(entry) for entry in entries],
        media=[MediaOut.model_validate(item) for item in media],
        assignments=[
            SyncAssignment(
                **to_assignment_out(assignment).model_dump(),
                child_id=assignment.child_id,
                updated_at=assignment.updated_at,
                completed_by=assignment.completed_by,
            )
            for assignment in assignments
        ],
        tags=[
            SyncTag(
                entry_id=link.entry_id,
                tag_id=link.tag_id,
                name=name,
                source=link.source,
                updated_at=link.updated_at,
                deleted_at=link.deleted_at,
            )
            for link, name in tag_rows
        ],
        cursor=cursor,
    )


async def _apply_entry(
    session: AsyncSession, child: Child, author: User, incoming: PushEntry
) -> PushResult:
    """Last write wins. The client's copy is the newer one by definition — it just left."""
    existing = await session.get(Entry, incoming.id)

    if existing is None:
        entry = await create_entry(
            session,
            child,
            author,
            entry_id=incoming.id,
            occurred_at=incoming.occurred_at,
            assignment_id=incoming.assignment_id,
            title=incoming.title,
            body=incoming.body,
            unlock_at_age=incoming.unlock_at_age,
            # Same setness rule as POST /entries. A letter written on a plane with sealing
            # deliberately off arrives here hours later, and it must not be sealed on the way
            # in — the parent is not present to notice, which makes this the worse of the two
            # routes to get wrong.
            unlock_at_age_provided="unlock_at_age" in incoming.model_fields_set,
            tags=incoming.tags or [],
        )
        if incoming.deleted_at is not None:
            entry.deleted_at = incoming.deleted_at
            await session.flush()
        return PushResult(id=incoming.id, status="accepted")

    if existing.child_id != child.id:
        return PushResult(
            id=incoming.id,
            status="conflict",
            reason="This entry belongs to a different child.",
        )

    existing.occurred_at = incoming.occurred_at
    existing.title = incoming.title
    existing.body = incoming.body
    existing.unlock_at_age = incoming.unlock_at_age
    existing.deleted_at = incoming.deleted_at
    existing.child_age_months = age_at_instant(
        child.birthdate, incoming.occurred_at, child.family_timezone
    )
    await session.flush()
    # entry_type describes the artifact, so it follows the body the client just pushed.
    await refresh_entry_type(session, existing)

    if incoming.tags is not None:
        await apply_tags(session, existing, incoming.tags, "user")
    return PushResult(id=incoming.id, status="accepted")


async def _apply_media(session: AsyncSession, child: Child, incoming: PushMedia) -> PushResult:
    """Media metadata only. Bytes never travel through this endpoint."""
    media = await session.get(Media, incoming.id)
    if media is None:
        return PushResult(
            id=incoming.id,
            status="conflict",
            reason="Unknown media. Call POST /v1/media/upload-url before pushing metadata.",
        )

    owning_child = await session.scalar(select(Entry.child_id).where(Entry.id == media.entry_id))
    if owning_child != child.id:
        return PushResult(
            id=incoming.id, status="conflict", reason="This media belongs to a different child."
        )

    if incoming.captured_at is not None:
        media.captured_at = incoming.captured_at
    if incoming.duration_seconds is not None:
        media.duration_seconds = incoming.duration_seconds
    # On-device AI output is durable data; a push carrying it is the write-back path.
    if incoming.transcript is not None:
        media.transcript = incoming.transcript
    if incoming.caption is not None:
        media.caption = incoming.caption
    media.deleted_at = incoming.deleted_at
    await session.flush()
    return PushResult(id=incoming.id, status="accepted")


async def push(
    session: AsyncSession,
    child: Child,
    author: User,
    *,
    entries: list[PushEntry],
    media: list[PushMedia],
    idempotency_keys: dict[str, str],
) -> tuple[list[PushResult], list[PushResult], dt.datetime]:
    """Drain a batched offline queue, one record at a time, and report on each.

    A record that fails does not fail the batch: the client gets per-record accept/conflict
    and reconciles without a full refetch.
    """
    entry_results: list[PushResult] = []
    media_results: list[PushResult] = []

    async def _once(record_id: uuid.UUID, apply) -> PushResult:
        key = idempotency_keys.get(str(record_id))
        if key:
            previous = await replay(session, author.id, key, PUSH_ENDPOINT)
            if previous is not None:
                return PushResult.model_validate(previous[1])
        result = await apply()
        if key and result.status == "accepted":
            await remember(
                session, author.id, key, PUSH_ENDPOINT, 200, result.model_dump(mode="json")
            )
        return result

    for incoming in entries:
        try:
            entry_results.append(
                await _once(incoming.id, lambda i=incoming: _apply_entry(session, child, author, i))
            )
        except RascalError as exc:
            entry_results.append(PushResult(id=incoming.id, status="conflict", reason=exc.message))

    for incoming in media:
        try:
            media_results.append(
                await _once(incoming.id, lambda i=incoming: _apply_media(session, child, i))
            )
        except RascalError as exc:
            media_results.append(PushResult(id=incoming.id, status="conflict", reason=exc.message))

    return entry_results, media_results, _now()
