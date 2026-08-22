"""Pull-since-cursor and the offline push drain.

Sync filters on `updated_at`, never `occurred_at`. Soft-deleted rows are included — a client
cannot infer a delete from a missing record, so deletions have to arrive as rows.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import or_, select
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

# A page is this many rows *per collection*. A pull with `since` omitted — a fresh install, a
# reinstall, any client that lost its cursor — would otherwise materialise the entire archive,
# entries with their media, tags and prompts included, in one response on a 512MB machine.
# Eighteen years of one child is the product, so scoping the read to one child is not a bound.
DEFAULT_PAGE_SIZE = 500
MAX_PAGE_SIZE = 2000


def _now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


async def pull(
    session: AsyncSession,
    child: Child,
    since: dt.datetime | None,
    viewer_id: uuid.UUID,
    *,
    limit: int = DEFAULT_PAGE_SIZE,
) -> SyncResponse:
    """One page of everything about this child that changed after `since`, deletions included.

    Each collection is paged on its own, so `has_more` is true when *any* of them was cut, and
    the cursor is then the **earliest** of the cut collections' last `updated_at` — never the
    latest. The four move at different rates; a cursor taken from whichever collection reached
    furthest would step the client past rows another collection has not handed out yet, and
    nothing would ever offer them again.

    The overlap window is kept on every page, intermediate ones included, and that is what
    makes it safe for a page bound to land in the middle of a group of rows sharing an
    `updated_at` — every row a single transaction writes carries that transaction's start
    time, so a bulk write is one timestamp however many rows it touches. Re-reading the last
    30 seconds collects the rest of the group on the next call.

    The cost is the honest one: a collection holding more than `limit` rows inside a single
    30-second window cannot be paged past, because the lagged cursor lands back inside it and
    the same page comes again. `limit` is the escape hatch — a client whose cursor stops
    moving while `has_more` is true asks for a larger page. That failure stands still and says
    so, which is the direction to fail in; the alternative advances the cursor over rows it
    never delivered and loses them silently.
    """
    limit = max(1, min(limit, MAX_PAGE_SIZE))

    def _after(column):
        return column > since if since is not None else column.is_not(None)

    # One row past the page tells us the collection was cut, without a second count query.
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
                .limit(limit + 1)
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
                .limit(limit + 1)
            )
        )
        .scalars()
        .all()
    )

    # **`/sync` is deliberately NOT gated by entitlement, and phase 107 left it that way on
    # purpose rather than by omission.** A free household's device does pull the rows for
    # slots `GET /today` refuses to serve it, prompt bodies included. Three reasons, and the
    # second is the one that decides it:
    #
    # 1. This is a delta feed keyed on `updated_at` and a *mirror* of rows, not a decision
    #    about what to show. The client is told what it may reach by `access` and `locked[]`
    #    on `GET /today`; that is the surface that renders a board.
    # 2. **There is no tombstone for "no longer yours to see."** Absences never signal
    #    anything here — that is the whole reason deletions sync as rows with `deleted_at`
    #    set. So a filter would withhold nothing from a device that had already synced, and
    #    it would break the far more important direction: on re-subscribing, those rows'
    #    `updated_at` has not moved, so they would never be sent again and the cache would be
    #    permanently missing work the household is now entitled to.
    # 3. Suppressing the `body` while keeping the row corrupts the cache in the same way, and
    #    for the same reason.
    #
    # **What is left open, and it is an iOS-lane question rather than one this file can
    # answer:** a client rendering from its local cache while offline can show a cached
    # mission the server would not serve. Making that impossible needs sync to be able to say
    # *hidden but not deleted*, which is a schema decision and not a line change.
    assignments = list(
        (
            await session.execute(
                select(Assignment)
                .where(
                    Assignment.child_id == child.id,
                    # **This guardian's daily rows, plus every shared row.** Since phase 36
                    # a two-parent household has two daily boards, and a client that pulled
                    # both would cache the other parent's assignments and render them as its
                    # own — the same leak as `/today`, except it persists on the device.
                    or_(
                        Assignment.user_id == viewer_id,
                        Assignment.user_id.is_(None),
                    ),
                    _after(Assignment.updated_at),
                )
                .options(selectinload(Assignment.prompt))
                .order_by(Assignment.updated_at.asc())
                .limit(limit + 1)
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
                .limit(limit + 1)
            )
        ).all()
    )

    def _page(rows: list, stamp) -> tuple[list, dt.datetime | None]:
        """Cut to one page. Returns the page and, if it was cut, the watermark it ended on."""
        if len(rows) <= limit:
            return rows, None
        page = rows[:limit]
        return page, stamp(page[-1])

    entries, entries_tail = _page(entries, lambda row: row.updated_at)
    media, media_tail = _page(media, lambda row: row.updated_at)
    assignments, assignments_tail = _page(assignments, lambda row: row.updated_at)
    tag_rows, tags_tail = _page(tag_rows, lambda row: row[0].updated_at)

    tails = [
        tail for tail in (entries_tail, media_tail, assignments_tail, tags_tail) if tail is not None
    ]
    if tails:
        # The earliest cut watermark, not the latest — see the docstring. Anything later
        # abandons the rows the other collections have not reached yet.
        newest = min(tails)
    else:
        stamps = [
            *(row.updated_at for row in entries),
            *(row.updated_at for row in media),
            *(row.updated_at for row in assignments),
            *(link.updated_at for link, _ in tag_rows),
        ]
        newest = max(stamps) if stamps else _now()
    # Lagged deliberately — see CURSOR_OVERLAP_SECONDS.
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
        has_more=bool(tails),
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
            # The answer here is an id and a status, never the entry, so the eager reload
            # `POST /entries` needs would be three selectin legs per record over a whole
            # drain — for a row that has no media and no assignment prompt loaded anyway.
            reload=False,
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

    # **The only route that removes media, so the only route that can strand a type.** There is no
    # `DELETE /media`; a push carrying `deleted_at` is how a parent's deletion reaches the server.
    # Without this, deleting an entry's only photo left `entry_type` at `photo` — an entry with
    # nothing attached, still filed under Photos. `refresh_entry_type` already excludes
    # soft-deleted rows, so it gives the right answer here with no special case.
    from rascal.services.media import retype_owning_entry

    await retype_owning_entry(session, media)
    return PushResult(id=incoming.id, status="accepted")


async def push(
    session: AsyncSession,
    child: Child,
    author: User,
    *,
    entries: list[PushEntry],
    media: list[PushMedia],
    idempotency_keys: dict[str, str],
) -> tuple[list[PushResult], list[PushResult]]:
    """Drain a batched offline queue, one record at a time, and report on each.

    A record that fails does not fail the batch: the client gets per-record accept/conflict
    and reconciles without a full refetch.

    No cursor comes back — see :class:`SyncPushResponse`. The batch is bounded at the wire by
    `MAX_PUSH_BATCH`, which is what keeps this transaction inside `CURSOR_OVERLAP_SECONDS`:
    each record costs several sequential round trips, and a drain that outlives the window
    commits rows already behind another device's cursor.
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

    return entry_results, media_results
