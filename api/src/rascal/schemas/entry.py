"""Entry request and response bodies."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import EntryType, MediaKind, TagSource
from rascal.schemas.common import ApiModel


class EntryCreate(ApiModel):
    """`id` is minted on the phone so the record exists offline before the server sees it."""

    id: uuid.UUID
    child_id: uuid.UUID
    assignment_id: uuid.UUID | None = None
    occurred_at: dt.datetime = Field(description="When it happened. Not when it was logged.")
    title: str | None = None
    body: str | None = None
    # Accepted for wire compatibility and ignored. entry_type describes what the entry
    # actually contains, and the server derives it — see docs/decisions.md.
    entry_type: EntryType | None = Field(
        default=None, deprecated=True, description="Ignored. Derived server-side."
    )
    unlock_at_age: int | None = Field(default=None, ge=0, le=120)
    tags: list[str] = Field(default_factory=list)


class EntryUpdate(ApiModel):
    title: str | None = None
    body: str | None = None
    occurred_at: dt.datetime | None = None
    unlock_at_age: int | None = Field(default=None, ge=0, le=120)
    tags: list[str] | None = None


class TagOut(ApiModel):
    id: uuid.UUID
    name: str
    source: TagSource


class MediaSummary(ApiModel):
    """Inlined into the timeline so a list render never fans out into N+1 calls."""

    id: uuid.UUID
    kind: MediaKind
    s3_key: str
    thumb_key: str | None
    duration_seconds: int | None
    bytes: int
    upload_status: str
    captured_at: dt.datetime | None


class MediaDetail(MediaSummary):
    transcript: str | None
    caption: str | None
    created_at: dt.datetime
    updated_at: dt.datetime


class PromptRef(ApiModel):
    """The prompt an entry came from, so the timeline can show what was asked."""

    id: uuid.UUID
    kind: str
    cadence: str
    completion_mode: str
    body: str
    theme: str


class EntryOut(ApiModel):
    id: uuid.UUID
    child_id: uuid.UUID
    assignment_id: uuid.UUID | None
    author_id: uuid.UUID
    occurred_at: dt.datetime
    created_at: dt.datetime
    updated_at: dt.datetime
    child_age_months: int
    title: str | None
    body: str | None
    entry_type: EntryType
    unlock_at_age: int | None
    deleted_at: dt.datetime | None
    tags: list[TagOut] = Field(default_factory=list)
    media: list[MediaSummary] = Field(default_factory=list)
    media_count: int = 0


class EntryDetail(EntryOut):
    """`GET /entries/{id}` — everything, including transcripts and the originating prompt."""

    media: list[MediaDetail] = Field(default_factory=list)
    prompt: PromptRef | None = None


class EntryPage(ApiModel):
    entries: list[EntryOut]
    # Opaque, encodes (occurred_at, id). Null when there is nothing after this page.
    next_cursor: str | None = None
