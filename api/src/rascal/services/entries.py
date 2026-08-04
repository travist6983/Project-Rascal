"""Entries: creation, the timeline query, tags, and soft deletion.

The timeline sorts by `occurred_at` because backdating drops a 2023 photo into the middle of
the order, not at the end. Sync filters on `updated_at`. The two are never conflated.
"""

from __future__ import annotations

import base64
import binascii
import datetime as dt
import json
import uuid
from dataclasses import dataclass

from sqlalchemy import Select, and_, func, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.constants import EntryType, TagSource
from rascal.errors import ErrorCode, RascalError, not_found, validation_failed
from rascal.models import Assignment, Child, Entry, EntryTag, Media, Prompt, Tag, User
from rascal.schemas.entry import (
    EntryDetail,
    EntryOut,
    MediaDetail,
    MediaSummary,
    PromptRef,
    TagOut,
)
from rascal.services.dates import age_at_instant

MAX_PAGE_SIZE = 200
DEFAULT_PAGE_SIZE = 50


def _now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


# --- Cursor ------------------------------------------------------------------------------


@dataclass(frozen=True)
class Cursor:
    """Keyset position, never an OFFSET.

    Backdating inserts rows into the middle of the order; offset paging would silently skip
    whatever shifted past the page boundary.
    """

    occurred_at: dt.datetime
    entry_id: uuid.UUID

    def encode(self) -> str:
        payload = json.dumps({"o": self.occurred_at.isoformat(), "i": str(self.entry_id)})
        return base64.urlsafe_b64encode(payload.encode("utf-8")).decode("ascii")

    @classmethod
    def decode(cls, raw: str) -> Cursor:
        try:
            payload = json.loads(base64.urlsafe_b64decode(raw.encode("ascii")))
            return cls(
                occurred_at=dt.datetime.fromisoformat(payload["o"]),
                entry_id=uuid.UUID(payload["i"]),
            )
        except (ValueError, KeyError, binascii.Error, TypeError) as exc:
            raise validation_failed("cursor is not a valid pagination cursor.", "cursor") from exc


# --- Serialization -----------------------------------------------------------------------


def _tags_of(entry: Entry) -> list[TagOut]:
    return [
        TagOut(id=link.tag_id, name=link.tag.name, source=link.source)
        for link in entry.entry_tags
        if link.deleted_at is None
    ]


def _live_media(entry: Entry) -> list[Media]:
    return [item for item in entry.media if item.deleted_at is None]


def to_entry_out(entry: Entry) -> EntryOut:
    """Requires `media` and `entry_tags`→`tag` to be eagerly loaded."""
    media = _live_media(entry)
    return EntryOut(
        id=entry.id,
        child_id=entry.child_id,
        assignment_id=entry.assignment_id,
        author_id=entry.author_id,
        occurred_at=entry.occurred_at,
        created_at=entry.created_at,
        updated_at=entry.updated_at,
        child_age_months=entry.child_age_months,
        title=entry.title,
        body=entry.body,
        entry_type=entry.entry_type,
        unlock_at_age=entry.unlock_at_age,
        deleted_at=entry.deleted_at,
        tags=_tags_of(entry),
        media=[MediaSummary.model_validate(item) for item in media],
        media_count=len(media),
    )


def to_entry_detail(entry: Entry, prompt: Prompt | None) -> EntryDetail:
    base = to_entry_out(entry).model_dump()
    base["media"] = [MediaDetail.model_validate(item) for item in _live_media(entry)]
    base["prompt"] = PromptRef.model_validate(prompt) if prompt is not None else None
    return EntryDetail(**base)


def _loaded(statement: Select) -> Select:
    """One query, everything the timeline renders. No N+1.

    `populate_existing` because a handler that just wrote tags or media would otherwise get
    the collection SQLAlchemy loaded earlier in the same session, not the one it just built.
    Every writer here flushes before reading, so there is nothing pending to clobber.
    """
    return statement.options(
        selectinload(Entry.media),
        selectinload(Entry.entry_tags).selectinload(EntryTag.tag),
    ).execution_options(populate_existing=True)


async def load_entry(
    session: AsyncSession, entry_id: uuid.UUID, *, include_deleted: bool = False
) -> Entry:
    statement = _loaded(select(Entry).where(Entry.id == entry_id))
    if not include_deleted:
        statement = statement.where(Entry.deleted_at.is_(None))
    entry = await session.scalar(statement)
    if entry is None:
        raise not_found("Entry")
    return entry


# --- Tags --------------------------------------------------------------------------------


async def resolve_tags(
    session: AsyncSession, child_id: uuid.UUID, names: list[str]
) -> dict[str, uuid.UUID]:
    """Find or create a tag per name, scoped to the child. Returns {normalized name: id}."""
    normalized = {name.strip().lower() for name in names if name and name.strip()}
    if not normalized:
        return {}

    await session.execute(
        insert(Tag)
        .values([{"child_id": child_id, "name": name} for name in sorted(normalized)])
        .on_conflict_do_nothing(index_elements=[Tag.child_id, Tag.name])
    )
    rows = await session.execute(
        select(Tag.name, Tag.id).where(Tag.child_id == child_id, Tag.name.in_(normalized))
    )
    return dict(rows.all())


async def apply_tags(
    session: AsyncSession,
    entry: Entry,
    names: list[str],
    source: TagSource,
) -> None:
    """Set the tags an entry carries for one source.

    `device_ai` writes never touch a row with `source = 'user'` — re-running extraction must
    be free, and it must never eat a tag someone typed. Removing a tag soft-deletes the link
    so the change syncs as a row rather than as an absence.
    """
    wanted = await resolve_tags(session, entry.child_id, names)

    existing = (
        (await session.execute(select(EntryTag).where(EntryTag.entry_id == entry.id)))
        .scalars()
        .all()
    )
    by_tag = {link.tag_id: link for link in existing}

    for tag_id in wanted.values():
        link = by_tag.get(tag_id)
        if link is None:
            session.add(EntryTag(entry_id=entry.id, tag_id=tag_id, source=source, deleted_at=None))
        elif link.deleted_at is not None:
            link.deleted_at = None
            link.source = source
        elif source == "user":
            # A human retyping a tag the model found promotes it; the reverse never happens.
            link.source = "user"

    for link in existing:
        if link.tag_id in wanted.values() or link.deleted_at is not None:
            continue
        if source == "device_ai" and link.source == "user":
            continue  # never eat a tag a human chose
        link.deleted_at = _now()

    await session.flush()


# --- Creation ----------------------------------------------------------------------------


async def _resolve_assignment(
    session: AsyncSession, assignment_id: uuid.UUID | None, child: Child
) -> tuple[Assignment | None, Prompt | None]:
    if assignment_id is None:
        return None, None
    assignment = await session.get(Assignment, assignment_id)
    if assignment is None:
        raise not_found("Assignment")
    if assignment.child_id != child.id:
        raise validation_failed(
            "That assignment belongs to a different child.", field="assignment_id"
        )
    prompt = await session.get(Prompt, assignment.prompt_id) if assignment.prompt_id else None
    return assignment, prompt


def _entry_type_for(explicit: EntryType | None, prompt: Prompt | None) -> EntryType:
    if explicit is not None:
        return explicit
    # Denormalized from the prompt so the timeline can filter without a join. A freeform
    # entry has no prompt to copy, and `text` is what carries it.
    return prompt.kind if prompt is not None else "text"


async def create_entry(
    session: AsyncSession,
    child: Child,
    author: User,
    *,
    entry_id: uuid.UUID,
    occurred_at: dt.datetime,
    assignment_id: uuid.UUID | None = None,
    title: str | None = None,
    body: str | None = None,
    entry_type: EntryType | None = None,
    unlock_at_age: int | None = None,
    tags: list[str] | None = None,
) -> Entry:
    """Create an entry and, if it completes a pending assignment, close that out too.

    Nothing here assumes the entry has media. "Get on the floor for ten minutes" is a
    complete, legitimate entry with no artifact.
    """
    if await session.get(Entry, entry_id) is not None:
        raise RascalError(
            ErrorCode.CONFLICT,
            "An entry with this id already exists. Retry with an Idempotency-Key to replay "
            "the original response.",
            field="id",
        )

    assignment, prompt = await _resolve_assignment(session, assignment_id, child)

    if unlock_at_age is None and prompt is not None:
        # Letters are sealed by default. The server owns this, not the client.
        unlock_at_age = prompt.default_unlock_age

    entry = Entry(
        id=entry_id,
        child_id=child.id,
        assignment_id=assignment.id if assignment else None,
        author_id=author.id,
        occurred_at=occurred_at,
        # Computed at write and stored, so correcting a birthdate typo does not shift the
        # whole archive.
        child_age_months=age_at_instant(child.birthdate, occurred_at, child.family_timezone),
        title=title,
        body=body,
        entry_type=_entry_type_for(entry_type, prompt),
        unlock_at_age=unlock_at_age,
    )
    session.add(entry)
    await session.flush()

    if assignment is not None and assignment.status == "pending":
        # Same transaction as the entry. A mission completed by either parent completes for
        # both.
        assignment.status = "done"
        assignment.completed_by = author.id
    # If the assignment is already done, dismissed, or expired the entry still saves and the
    # assignment is left alone — the archive matters more than the bookkeeping.

    if tags:
        await apply_tags(session, entry, tags, "user")

    await session.flush()
    return await load_entry(session, entry.id)


# --- Timeline ----------------------------------------------------------------------------


def _filters(
    child_id: uuid.UUID,
    before: dt.datetime | None,
    after: dt.datetime | None,
    entry_type: str | None,
    tag: str | None,
    query: str | None,
) -> list:
    clauses = [Entry.child_id == child_id, Entry.deleted_at.is_(None)]
    if before is not None:
        clauses.append(Entry.occurred_at < before)
    if after is not None:
        clauses.append(Entry.occurred_at > after)
    if entry_type:
        clauses.append(Entry.entry_type == entry_type)
    if tag:
        clauses.append(
            Entry.id.in_(
                select(EntryTag.entry_id)
                .join(Tag, Tag.id == EntryTag.tag_id)
                .where(
                    Tag.child_id == child_id,
                    Tag.name == tag.strip().lower(),
                    EntryTag.deleted_at.is_(None),
                )
            )
        )
    if query:
        # A substring filter, not full-text search — Postgres tsvector search is P1 and
        # explicitly out of scope here.
        pattern = f"%{query.strip()}%"
        clauses.append(or_(Entry.title.ilike(pattern), Entry.body.ilike(pattern)))
    return clauses


async def list_entries(
    session: AsyncSession,
    child_id: uuid.UUID,
    *,
    before: dt.datetime | None = None,
    after: dt.datetime | None = None,
    entry_type: str | None = None,
    tag: str | None = None,
    query: str | None = None,
    limit: int = DEFAULT_PAGE_SIZE,
    cursor: str | None = None,
) -> tuple[list[Entry], str | None]:
    """Newest first by `occurred_at`, keyset-paginated on `(occurred_at, id)`."""
    limit = max(1, min(limit, MAX_PAGE_SIZE))
    clauses = _filters(child_id, before, after, entry_type, tag, query)

    if cursor:
        position = Cursor.decode(cursor)
        clauses.append(
            or_(
                Entry.occurred_at < position.occurred_at,
                and_(
                    Entry.occurred_at == position.occurred_at,
                    Entry.id < position.entry_id,
                ),
            )
        )

    statement = (
        _loaded(select(Entry))
        .where(*clauses)
        .order_by(Entry.occurred_at.desc(), Entry.id.desc())
        # One extra row tells us whether there is a next page without a second count query.
        .limit(limit + 1)
    )
    rows = list((await session.execute(statement)).scalars().all())

    next_cursor = None
    if len(rows) > limit:
        rows = rows[:limit]
        last = rows[-1]
        next_cursor = Cursor(occurred_at=last.occurred_at, entry_id=last.id).encode()
    return rows, next_cursor


# --- Update and delete -------------------------------------------------------------------


async def update_entry(
    session: AsyncSession,
    entry: Entry,
    child: Child,
    *,
    fields: dict,
) -> Entry:
    tags = fields.pop("tags", None)
    for name, value in fields.items():
        setattr(entry, name, value)

    if "occurred_at" in fields:
        # The stored age follows the corrected date, because that is what it means.
        entry.child_age_months = age_at_instant(
            child.birthdate, entry.occurred_at, child.family_timezone
        )

    if tags is not None:
        await apply_tags(session, entry, tags, "user")

    await session.flush()
    return await load_entry(session, entry.id)


async def soft_delete_entry(session: AsyncSession, entry: Entry) -> None:
    """Nothing is ever hard-deleted. The row stays and syncs with `deleted_at` set."""
    now = _now()
    if entry.deleted_at is None:
        entry.deleted_at = now
    for item in entry.media:
        # The media has to carry its own deleted_at, or a client that synced the media row
        # earlier would keep showing it.
        if item.deleted_at is None:
            item.deleted_at = now
    await session.flush()


# --- On This Day -------------------------------------------------------------------------


async def moments_for(
    session: AsyncSession, child: Child, on: dt.date
) -> tuple[list[tuple[int, list[Entry]]], list[Entry]]:
    """Same month and day in prior years, grouped by years-ago; a random handful if empty.

    The month/day extraction is pinned to UTC to match `ix_entries_child_month_day`, which
    Postgres will only build over an IMMUTABLE expression.
    """
    utc_occurred = func.timezone("UTC", Entry.occurred_at)
    statement = (
        _loaded(select(Entry))
        .where(
            Entry.child_id == child.id,
            Entry.deleted_at.is_(None),
            func.extract("month", utc_occurred) == on.month,
            func.extract("day", utc_occurred) == on.day,
            func.extract("year", utc_occurred) < on.year,
        )
        .order_by(Entry.occurred_at.desc())
    )
    rows = list((await session.execute(statement)).scalars().all())

    grouped: dict[int, list[Entry]] = {}
    for entry in rows:
        years_ago = on.year - entry.occurred_at.astimezone(dt.UTC).year
        grouped.setdefault(years_ago, []).append(entry)
    if grouped:
        return sorted(grouped.items()), []

    # The warm redirect, so the screen is never a void.
    fallback = (
        (
            await session.execute(
                _loaded(select(Entry))
                .where(Entry.child_id == child.id, Entry.deleted_at.is_(None))
                .order_by(func.random())
                .limit(5)
            )
        )
        .scalars()
        .all()
    )
    return [], list(fallback)
