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
    entries: list[PushEntry] = Field(default_factory=list)
    media: list[PushMedia] = Field(default_factory=list)
    # {record_id: idempotency_key}. A retried batch applies nothing twice.
    idempotency_keys: dict[str, str] = Field(default_factory=dict)


class PushResult(ApiModel):
    id: uuid.UUID
    status: Literal["accepted", "conflict"]
    # Present only on a conflict, so the client knows what to reconcile.
    reason: str | None = None


class SyncPushResponse(ApiModel):
    entries: list[PushResult]
    media: list[PushResult]
    cursor: dt.datetime
