"""Sync request and response bodies.

Every entity carries `updated_at` and `deleted_at`. Deletions arrive as rows, never as
absences — a client cannot infer a delete from a missing record.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Literal

from pydantic import Field

from rascal.constants import TagSource
from rascal.schemas.common import ApiModel
from rascal.schemas.entry import EntryOut
from rascal.schemas.media import MediaOut
from rascal.schemas.today import AssignmentOut

# One drain is one transaction, and each record inside it costs several sequential round
# trips. The batch therefore has to finish well inside `CURSOR_OVERLAP_SECONDS`, because a
# transaction that outlives the window commits rows whose `updated_at` is already behind the
# cursor another device advanced past — and those rows never sync again. Refusing an
# oversized batch outright is the cheap half of that: a 422 costs one round trip and the
# client re-sends in pages, where a batch that runs long costs the records themselves.
MAX_PUSH_BATCH = 200


class SyncAssignment(AssignmentOut):
    child_id: uuid.UUID
    updated_at: dt.datetime
    completed_by: uuid.UUID | None = None


class SyncTag(ApiModel):
    """An entry-tag link, with the tag's name inlined.

    The link is the thing that changes — a bare tag list would not tell a client which entry
    lost which tag.
    """

    entry_id: uuid.UUID
    tag_id: uuid.UUID
    name: str
    source: TagSource
    updated_at: dt.datetime
    deleted_at: dt.datetime | None


class SyncResponse(ApiModel):
    entries: list[EntryOut]
    media: list[MediaOut]
    assignments: list[SyncAssignment]
    tags: list[SyncTag]
    # Feed this back as `since` on the next call.
    cursor: dt.datetime
    # True while any collection was cut at the page bound. The response is a page, not the
    # whole change stream, so a client that stops before this is false has an archive with a
    # hole in it.
    has_more: bool


class PushEntry(ApiModel):
    id: uuid.UUID
    child_id: uuid.UUID
    assignment_id: uuid.UUID | None = None
    occurred_at: dt.datetime
    title: str | None = None
    body: str | None = None
    # Ignored, same as on POST /entries: the server derives it from the artifact.
    entry_type: str | None = None
    unlock_at_age: int | None = None
    tags: list[str] | None = None
    deleted_at: dt.datetime | None = None


class PushMedia(ApiModel):
    id: uuid.UUID
    entry_id: uuid.UUID
    captured_at: dt.datetime | None = None
    duration_seconds: int | None = None
    transcript: str | None = None
    caption: str | None = None
    deleted_at: dt.datetime | None = None


class SyncPushRequest(ApiModel):
    # Bounded — see MAX_PUSH_BATCH. A client with more than this queued drains in pages.
    entries: list[PushEntry] = Field(default_factory=list, max_length=MAX_PUSH_BATCH)
    media: list[PushMedia] = Field(default_factory=list, max_length=MAX_PUSH_BATCH)
    # {record_id: idempotency_key}. A retried batch applies nothing twice.
    idempotency_keys: dict[str, str] = Field(default_factory=dict)


class PushResult(ApiModel):
    id: uuid.UUID
    status: Literal["accepted", "conflict"]
    # Present only on a conflict, so the client knows what to reconcile.
    reason: str | None = None


class SyncPushResponse(ApiModel):
    """Per-record outcomes, and deliberately **no cursor**.

    A sync cursor is the newest `updated_at` actually returned, never a clock read — a push
    reads no rows, so it has no position in the change stream to hand back. The field used to
    be `now()`, which was unsafe twice over: it is ahead of `GET /sync`'s deliberately lagged
    cursor, so feeding it to `?since=` skipped everything committed inside the overlap window,
    including the `entry_type` and `child_age_months` corrections the push itself had just
    made; and being a wall clock rather than a read position, it also skipped every older row
    the client had never pulled. The client keeps its pull cursor and pulls after draining.
    """

    entries: list[PushResult]
    media: list[PushResult]
