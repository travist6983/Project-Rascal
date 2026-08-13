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
from collections.abc import Sequence
from dataclasses import dataclass

from sqlalchemy import Select, and_, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.constants import CompletionMode, EntryType, TagSource
from rascal.errors import ErrorCode, RascalError, not_found, validation_failed
from rascal.models import Assignment, Child, Entry, EntryTag, Media, Prompt, Tag, User
from rascal.schemas.entry import (
    EntryDetail,
    EntryOut,
    MediaDetail,
    MediaSummary,
    PromptRef,
    TagOut,
    TagWrite,
)
from rascal.services import search
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


@dataclass(frozen=True)
class SearchCursor:
    """Keyset position for a *ranked* page: `(rank, occurred_at, id)`.

    Search is ordered by relevance, so the timeline's `(occurred_at, id)` position means
    nothing here — a cursor from one mode decodes as invalid in the other, which is the
    correct answer rather than a quietly wrong page.
    """

    rank: float
    occurred_at: dt.datetime
    entry_id: uuid.UUID

    def encode(self) -> str:
        payload = json.dumps(
            {
                # json round-trips a float through repr, so this is exact — and it has to be,
                # because the next page's WHERE compares against it for equality.
                "r": self.rank,
                "o": self.occurred_at.isoformat(),
                "i": str(self.entry_id),
            }
        )
        return base64.urlsafe_b64encode(payload.encode("utf-8")).decode("ascii")

    @classmethod
    def decode(cls, raw: str) -> SearchCursor:
        try:
            payload = json.loads(base64.urlsafe_b64decode(raw.encode("ascii")))
            return cls(
                rank=float(payload["r"]),
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
        prompt_body=entry.assignment.resolved_body if entry.assignment is not None else None,
        tags=_tags_of(entry),
        media=[MediaSummary.model_validate(item) for item in media],
        media_count=len(media),
    )


def to_entry_detail(entry: Entry, prompt: Prompt | None) -> EntryDetail:
    base = to_entry_out(entry).model_dump()
    base["media"] = [MediaDetail.model_validate(item) for item in _live_media(entry)]
    base["prompt"] = PromptRef.model_validate(prompt) if prompt is not None else None
    return EntryDetail(**base)


def loaded(statement: Select) -> Select:
    """One query, everything `to_entry_out` reads. No N+1.

    Public because `services/sync.py` selects entries too and serializes them with the same
    function, so the two have to agree about what is eagerly loaded. They did not, once.

    `populate_existing` because a handler that just wrote tags or media would otherwise get
    the collection SQLAlchemy loaded earlier in the same session, not the one it just built.
    Every writer here flushes before reading, so there is nothing pending to clobber.
    """
    return statement.options(
        selectinload(Entry.media),
        selectinload(Entry.entry_tags).selectinload(EntryTag.tag),
        # For `prompt_body`. Two more statements per page, not two more per row — and the
        # prompt leg is needed because `resolved_body` falls through to it whenever the
        # assignment has no parent-authored `custom_body`, which is the common case.
        selectinload(Entry.assignment).selectinload(Assignment.prompt),
    ).execution_options(populate_existing=True)


async def load_entry(
    session: AsyncSession, entry_id: uuid.UUID, *, include_deleted: bool = False
) -> Entry:
    statement = loaded(select(Entry).where(Entry.id == entry_id))
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


async def apply_tag_writes(
    session: AsyncSession,
    entry: Entry,
    tags: list[object],
) -> None:
    """Write a mixed list of tags, grouping by source.

    **The order is load-bearing, and it is `user` first.** :func:`apply_tags` sets the tags for
    *one* source and removes the ones it was not given, and its only protection runs one way — a
    `device_ai` write never eats a `user` row, but a `user` write happily removes a `device_ai`
    one. Applying `device_ai` first would therefore have the `user` pass delete everything the
    model just wrote.

    **A source absent from the payload is left alone**, which is what makes this backwards
    compatible in both directions:

    * A list of bare strings is `user`-only and behaves exactly as it did before this existed.
    * An extraction write is `device_ai`-only, and the parent's own tags are untouched.
    """
    grouped: dict[TagSource, list[str]] = {}
    for tag in tags:
        if isinstance(tag, str):
            grouped.setdefault("user", []).append(tag)
            continue
        # `PATCH /entries/{id}` reaches here through `payload.model_dump(exclude_unset=True)`,
        # which turns a `TagWrite` back into a plain dict, while `POST /entries` passes the
        # model itself. Validating covers both and refuses a source the enum does not know
        # rather than letting it reach a CHECK constraint as a 500.
        written = tag if isinstance(tag, TagWrite) else TagWrite.model_validate(tag)
        grouped.setdefault(written.source, []).append(written.name)

    # `user` before `device_ai`. See above — reversing these is silent data loss.
    for source in ("user", "device_ai"):
        if source in grouped:
            await apply_tags(session, entry, grouped[source], source)


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


def derive_entry_type(
    body: str | None,
    title: str | None,
    media: Sequence[Media],
    *,
    completion_mode: CompletionMode | None,
) -> EntryType:
    """What the entry actually is — never what was asked, but not blind to it either.

    In order:

    1. Media attached -> the media kind. A `did_it` completion of an audio mission is not
       an audio entry, and a Voice filter that surfaces it is lying.
    2. Otherwise, if it completes a `did_it` mission -> `did_it`. "Get on the floor for ten
       minutes" is a did-it whether or not you wrote a note about it, and the optional note
       must not tip it out of the Did it filter. This is the same bug as (1), pointing the
       other way.
    3. Otherwise, any written content -> `text`. A title is written content.
    4. Otherwise -> `did_it`.

    `completion_mode` comes from the prompt behind the entry's assignment; a freeform entry
    has none and falls through to (3)/(4).
    """
    attached = sorted(
        (item for item in media if item.deleted_at is None),
        # Deterministic: the relationship's order is not, and "the first attached kind" has
        # to mean the same thing on every recompute.
        key=lambda item: (item.created_at, str(item.id)),
    )
    if attached:
        return attached[0].kind  # mixed media takes the first attached kind
    if completion_mode == "did_it":
        return "did_it"
    if body or title:
        return "text"
    return "did_it"


async def completion_mode_for(
    session: AsyncSession, assignment_id: uuid.UUID | None
) -> CompletionMode | None:
    """The `completion_mode` of the prompt behind an assignment, if there is one.

    None for a freeform entry, and None for a parent-authored `custom_body` assignment —
    neither has a prompt saying what shape the answer takes.
    """
    if assignment_id is None:
        return None
    return await session.scalar(
        select(Prompt.completion_mode)
        .join(Assignment, Assignment.prompt_id == Prompt.id)
        .where(Assignment.id == assignment_id)
    )


async def refresh_entry_type(session: AsyncSession, entry: Entry) -> bool:
    """Recompute after media lands or the text changes. True if the value moved.

    Media arrives after the entry exists, so the type assigned at creation is provisional.
    When this writes, the `set_updated_at()` trigger moves the sync cursor for free.
    """
    attached = (
        (
            await session.execute(
                select(Media).where(Media.entry_id == entry.id, Media.deleted_at.is_(None))
            )
        )
        .scalars()
        .all()
    )
    derived = derive_entry_type(
        entry.body,
        entry.title,
        list(attached),
        completion_mode=await completion_mode_for(session, entry.assignment_id),
    )
    if derived == entry.entry_type:
        return False
    entry.entry_type = derived
    await session.flush()
    return True


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
    unlock_at_age: int | None = None,
    unlock_at_age_provided: bool = False,
    tags: list[str] | None = None,
    reload: bool = True,
) -> Entry:
    """Create an entry and, if it completes a pending assignment, close that out too.

    Nothing here assumes the entry has media. "Get on the floor for ten minutes" is a
    complete, legitimate entry with no artifact.

    `reload` re-selects the finished row through :func:`loaded`, which is what a caller
    serialising with `to_entry_out` needs and what `POST /entries` does. `/sync/push` answers
    with an id and a status and never reads the graph, so it passes False and saves the three
    `selectinload` legs — per record, in a loop, over a whole offline drain. It defaults to
    True because the reload is the safe half of that trade: a caller that skips it and then
    touches `entry.media` gets a lazy-load raise, not a wrong answer.

    `unlock_at_age_provided` is the difference between "I have no opinion about sealing" and
    "the parent turned sealing off", which `unlock_at_age` alone cannot express — Pydantic
    produces `None` for an omitted key and for an explicit `null` alike. Callers pass
    `"unlock_at_age" in payload.model_fields_set`. It defaults to False so a caller that has
    genuinely not thought about sealing still gets the prompt's default, which is the safe
    direction: a letter sealed by accident can be unsealed, and one published by accident
    cannot be unpublished.
    """
    if await session.get(Entry, entry_id) is not None:
        raise RascalError(
            ErrorCode.CONFLICT,
            "An entry with this id already exists. Retry with an Idempotency-Key to replay "
            "the original response.",
            field="id",
        )

    assignment, prompt = await _resolve_assignment(session, assignment_id, child)

    if unlock_at_age is None and not unlock_at_age_provided and prompt is not None:
        # Letters are sealed by default. The server owns this, not the client — a client that
        # has never heard of sealing still writes a sealed letter. An *explicit* null is the
        # one thing that overrides it, and only because the parent said so on a screen.
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
        # No media exists yet — it is uploaded against the entry afterwards — so this is
        # `text` or `did_it`, and POST /media/{id}/complete recomputes it.
        entry_type=derive_entry_type(
            body,
            title,
            [],
            completion_mode=prompt.completion_mode if prompt is not None else None,
        ),
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
        await apply_tag_writes(session, entry, tags)

    await session.flush()
    return await load_entry(session, entry.id) if reload else entry


# --- Timeline ----------------------------------------------------------------------------


def _filters(
    child_id: uuid.UUID,
    before: dt.datetime | None,
    after: dt.datetime | None,
    entry_type: str | None,
    tag: str | None,
    sealed: bool | None = None,
) -> list:
    clauses = [Entry.child_id == child_id, Entry.deleted_at.is_(None)]
    if before is not None:
        clauses.append(Entry.occurred_at < before)
    if after is not None:
        clauses.append(Entry.occurred_at > after)
    if entry_type:
        clauses.append(Entry.entry_type == entry_type)
    if sealed is not None:
        # Sealed is `unlock_at_age IS NOT NULL`, not an `entry_type` — a sealed letter is a
        # `text` entry and `?type=` cannot express the difference. Its own parameter rather
        # than a seventh entry_type, because the two are orthogonal: a sealed photo is
        # possible and would have to remain findable as a photo.
        clauses.append(
            Entry.unlock_at_age.is_not(None) if sealed else Entry.unlock_at_age.is_(None)
        )
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
    return clauses


async def list_entries(
    session: AsyncSession,
    child_id: uuid.UUID,
    *,
    before: dt.datetime | None = None,
    after: dt.datetime | None = None,
    entry_type: str | None = None,
    tag: str | None = None,
    sealed: bool | None = None,
    query: str | None = None,
    limit: int = DEFAULT_PAGE_SIZE,
    cursor: str | None = None,
) -> tuple[list[Entry], str | None]:
    """The timeline, or — when `query` is given — the search results.

    Without `query`: newest first by `occurred_at`, keyset-paginated on `(occurred_at, id)`.
    With it: best match first, keyset-paginated on `(rank, occurred_at, id)`. Both filter
    `deleted_at IS NULL`; `/sync` is the only read path that returns deleted rows.
    """
    limit = max(1, min(limit, MAX_PAGE_SIZE))
    if query and query.strip():
        return await _search_entries(
            session,
            child_id,
            query=query,
            before=before,
            after=after,
            entry_type=entry_type,
            tag=tag,
            sealed=sealed,
            limit=limit,
            cursor=cursor,
        )

    clauses = _filters(child_id, before, after, entry_type, tag, sealed)

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
        loaded(select(Entry))
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


def search_statement(
    child_id: uuid.UUID,
    *,
    query: str,
    before: dt.datetime | None = None,
    after: dt.datetime | None = None,
    entry_type: str | None = None,
    tag: str | None = None,
    sealed: bool | None = None,
    limit: int = DEFAULT_PAGE_SIZE,
    cursor: str | None = None,
) -> Select:
    """The ranked search query. Separate from its execution so its plan can be asserted on.

    `tests/test_search.py` runs EXPLAIN over exactly this statement and fails if either GIN
    index stops being reachable — the failure mode is a search that still returns the right
    rows, just slower every year.
    """
    tsq = search.tsquery(query)
    rank = search.rank_expression(tsq)

    clauses = [*_filters(child_id, before, after, entry_type, tag, sealed), search.matches(tsq)]

    if cursor:
        position = SearchCursor.decode(cursor)
        # The three-column keyset comparison, spelled out. Rank ties are the common case, not
        # the edge case — ts_rank_cd hands out the same score constantly — so occurred_at and
        # id are what actually make a page boundary stable.
        clauses.append(
            or_(
                rank < position.rank,
                and_(
                    rank == position.rank,
                    or_(
                        Entry.occurred_at < position.occurred_at,
                        and_(
                            Entry.occurred_at == position.occurred_at,
                            Entry.id < position.entry_id,
                        ),
                    ),
                ),
            )
        )

    return (
        loaded(select(Entry, rank.label("rank")))
        .where(*clauses)
        # Relevance first, then the timeline's own order, so equally-good matches still read
        # newest to oldest.
        .order_by(rank.desc(), Entry.occurred_at.desc(), Entry.id.desc())
        # One extra row tells us whether there is a next page without a second count query.
        .limit(limit + 1)
    )


async def _search_entries(
    session: AsyncSession,
    child_id: uuid.UUID,
    *,
    query: str,
    before: dt.datetime | None,
    after: dt.datetime | None,
    entry_type: str | None,
    tag: str | None,
    sealed: bool | None,
    limit: int,
    cursor: str | None,
) -> tuple[list[Entry], str | None]:
    """Full-text search, best match first. See `rascal.services.search`."""
    statement = search_statement(
        child_id,
        query=query,
        before=before,
        after=after,
        entry_type=entry_type,
        tag=tag,
        sealed=sealed,
        limit=limit,
        cursor=cursor,
    )
    rows = list((await session.execute(statement)).all())

    next_cursor = None
    if len(rows) > limit:
        rows = rows[:limit]
        last_entry, last_rank = rows[-1]
        next_cursor = SearchCursor(
            rank=float(last_rank),
            occurred_at=last_entry.occurred_at,
            entry_id=last_entry.id,
        ).encode()
    return [entry for entry, _ in rows], next_cursor


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
        await apply_tag_writes(session, entry, tags)

    if "body" in fields or "title" in fields:
        # Written content can tip a freeform entry from did_it to text, so the type has to
        # follow an edit of the row. A did-it mission stays did_it either way.
        await refresh_entry_type(session, entry)

    await session.flush()
    return await load_entry(session, entry.id)


async def release_assignment(session: AsyncSession, assignment_id: uuid.UUID) -> bool:
    """Put a completed assignment back on the Today screen. True if it moved.

    Only when nothing else still completes it: two entries can answer one mission, and
    deleting the first must not unmark the second.
    """
    assignment = await session.get(Assignment, assignment_id)
    if assignment is None or assignment.status != "done":
        return False

    still_completed = await session.scalar(
        select(Entry.id)
        .where(Entry.assignment_id == assignment_id, Entry.deleted_at.is_(None))
        .limit(1)
    )
    if still_completed is not None:
        return False

    assignment.status = "pending"
    assignment.completed_by = None
    await session.flush()
    return True


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

    if entry.assignment_id is not None:
        # The wrong-photo-redo-it path. Without this the mission is stranded `done` with
        # nothing to show for it, and the slot is gone for the day.
        await release_assignment(session, entry.assignment_id)


# --- Age correction ----------------------------------------------------------------------


async def recompute_child_ages(session: AsyncSession, child: Child) -> int:
    """Rewrite every stored `child_age_months` for a child. Returns how many actually moved.

    `child_age_months` is computed at write and stored, so correcting a birthdate typo does
    not silently reshape an archive of 500 entries. The cost of that is that the typo is
    otherwise permanent, and this is the escape hatch: explicit, user-invoked, never a side
    effect of editing the birthdate.

    Soft-deleted entries are included. Nothing is ever really deleted here, and a restored
    entry must not come back carrying an age computed against the wrong birthdate.

    Only the rows whose value actually changes are written. `set_updated_at()` fires on
    every UPDATE, so touching an unchanged row would push the whole archive back through
    `GET /sync` on every invocation — the correction has to reach the other devices, the
    other eighteen years of entries do not.
    """
    rows = (
        await session.execute(
            select(Entry.id, Entry.occurred_at, Entry.child_age_months).where(
                Entry.child_id == child.id
            )
        )
    ).all()

    corrections = [
        {"id": entry_id, "child_age_months": corrected}
        for entry_id, occurred_at, stored in rows
        # The same function the write path uses, not a second implementation of the
        # arithmetic — two of those drift, and the drift shows up as an archive that
        # disagrees with itself.
        if (corrected := age_at_instant(child.birthdate, occurred_at, child.family_timezone))
        != stored
    ]
    if not corrections:
        return 0

    # One statement, in the caller's transaction. A partially recomputed archive is worse
    # than an uncorrected one.
    await session.execute(update(Entry), corrections)
    return len(corrections)


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
        loaded(select(Entry))
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
                loaded(select(Entry))
                .where(Entry.child_id == child.id, Entry.deleted_at.is_(None))
                .order_by(func.random())
                .limit(5)
            )
        )
        .scalars()
        .all()
    )
    return [], list(fallback)
