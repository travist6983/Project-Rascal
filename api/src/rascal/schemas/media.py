"""Media request and response bodies. The server holds keys and metadata, never bytes."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import MediaKind
from rascal.schemas.common import ApiModel
from rascal.schemas.entry import MediaDetail, TagOut


class UploadUrlRequest(ApiModel):
    entry_id: uuid.UUID
    kind: MediaKind
    filename: str = Field(min_length=1, max_length=512)
    bytes: int = Field(gt=0, description="Size of the object in bytes.")
    content_type: str = Field(min_length=1, max_length=255)
    # Optional so an offline client can mint the id alongside the entry it belongs to.
    media_id: uuid.UUID | None = None


class UploadPart(ApiModel):
    part_number: int
    upload_url: str


class UploadUrlResponse(ApiModel):
    media_id: uuid.UUID
    s3_key: str
    # Exactly one of these is set: a single PUT under the multipart threshold, otherwise parts.
    upload_url: str | None = None
    parts: list[UploadPart] | None = None
    multipart: bool
    # Split the file at exactly this size. The presigned part count was computed from it, so
    # a client that guesses a different chunk size ends up with the wrong number of parts.
    # Null for a single PUT, where there is nothing to split.
    chunk_bytes: int | None = None
    expires_in: int


class CompletedPart(ApiModel):
    part_number: int
    etag: str


class MediaCompleteRequest(ApiModel):
    # Required for a multipart upload, ignored for a single PUT.
    etags: list[CompletedPart] | None = None
    captured_at: dt.datetime | None = None
    duration_seconds: int | None = Field(default=None, ge=0)


class MediaDownloadResponse(ApiModel):
    """A short-lived read URL. Minted per request rather than stored: a persisted URL
    outlives its signature and then fails in a way that looks like the bytes are gone."""

    media_id: uuid.UUID
    url: str
    expires_in: int


class MediaDerivedRequest(ApiModel):
    """The on-device AI write-back. Idempotent: the same transcript twice changes nothing."""

    transcript: str | None = None
    caption: str | None = None
    tags: list[str] | None = None


class MediaOut(MediaDetail):
    entry_id: uuid.UUID
    deleted_at: dt.datetime | None = None


class MediaDerivedResponse(ApiModel):
    media: MediaOut
    # Every tag on the entry afterwards, with its source, so a client can see that a tag it
    # typed survived the write-back.
    tags: list[TagOut]
