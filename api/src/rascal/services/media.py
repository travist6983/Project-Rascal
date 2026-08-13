"""Media: presigned upload, completion, and the on-device AI write-back.

Bytes go device → S3 on a background `URLSession`. This service only ever holds keys and
metadata, which is what lets the same endpoints serve a browser unchanged.
"""

from __future__ import annotations

import datetime as dt
import math
import uuid
from dataclasses import dataclass
from pathlib import PurePosixPath

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.config import Settings
from rascal.constants import MediaKind
from rascal.errors import ErrorCode, RascalError, not_found, validation_failed
from rascal.models import Entry, EntryTag, Media
from rascal.schemas.media import CompletedPart, UploadPart
from rascal.services import s3

# S3 refuses more than 10,000 parts in a single multipart upload.
MAX_PARTS = 10_000


@dataclass(frozen=True)
class UploadPlan:
    media: Media
    upload_url: str | None
    parts: list[UploadPart] | None
    multipart: bool
    # The size every part except the last must be, so the client does not have to guess the
    # split that the presigned part count was computed from. Null for a single PUT.
    chunk_bytes: int | None


def _now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


def build_key(child_id: uuid.UUID, entry_id: uuid.UUID, media_id: uuid.UUID, filename: str) -> str:
    """Keys are prefixed by child so a per-child export or lifecycle rule is a prefix scan."""
    suffix = PurePosixPath(filename).suffix.lower()[:16]
    return f"children/{child_id}/entries/{entry_id}/{media_id}{suffix}"


def wants_multipart(kind: MediaKind, size: int, settings: Settings) -> bool:
    """Video always assumes multipart; everything else crosses over at the threshold."""
    return kind == "video" or size > settings.multipart_threshold_bytes


async def plan_upload(
    session: AsyncSession,
    child_id: uuid.UUID,
    *,
    entry_id: uuid.UUID,
    kind: MediaKind,
    filename: str,
    size: int,
    content_type: str,
    media_id: uuid.UUID | None,
    settings: Settings,
) -> UploadPlan:
    entry = await session.get(Entry, entry_id)
    if entry is None or entry.deleted_at is not None:
        raise not_found("Entry")
    if entry.child_id != child_id:
        raise validation_failed("That entry belongs to a different child.", field="entry_id")

    media_id = media_id or uuid.uuid4()
    if await session.get(Media, media_id) is not None:
        raise RascalError(
            ErrorCode.CONFLICT, "Media with this id already exists.", field="media_id"
        )

    key = build_key(child_id, entry_id, media_id, filename)
    media = Media(
        id=media_id,
        entry_id=entry_id,
        s3_key=key,
        kind=kind,
        bytes=size,
        upload_status="pending",
        # Thumbnail and poster-frame generation is out of P0 scope, so this stays null.
        thumb_key=None,
    )

    if not wants_multipart(kind, size, settings):
        media.s3_upload_id = None
        session.add(media)
        await session.flush()
        return UploadPlan(
            media=media,
            upload_url=s3.presign_put(key, content_type, settings),
            parts=None,
            multipart=False,
            chunk_bytes=None,
        )

    chunk = settings.multipart_chunk_bytes
    part_count = max(1, math.ceil(size / chunk))
    if part_count > MAX_PARTS:
        raise validation_failed(
            f"{size} bytes needs more than {MAX_PARTS} parts at the configured chunk size.",
            field="bytes",
        )

    # Initiating a multipart upload is a round trip to the store, and the reads that got here
    # — the authorization check and the two lookups above — have already opened this request's
    # transaction. Nothing has been written yet, so committing costs nothing and hands the
    # Neon connection back to the pool instead of parking it idle for the length of the call.
    # The write below opens a fresh transaction, which the session dependency commits.
    await session.commit()

    upload_id = await s3.create_multipart_upload(key, content_type, settings)
    media.s3_upload_id = upload_id
    session.add(media)
    await session.flush()

    parts = [
        UploadPart(part_number=number, upload_url=s3.presign_part(key, upload_id, number, settings))
        for number in range(1, part_count + 1)
    ]
    return UploadPlan(media=media, upload_url=None, parts=parts, multipart=True, chunk_bytes=chunk)


async def complete_upload(
    session: AsyncSession,
    media: Media,
    *,
    etags: list[CompletedPart] | None,
    captured_at: dt.datetime | None,
    duration_seconds: int | None,
    settings: Settings,
) -> Media:
    """Mark the object uploaded. `thumb_key` stays null — that pipeline is out of P0 scope."""
    if media.s3_upload_id:
        if not etags:
            raise RascalError(
                ErrorCode.UPLOAD_INCOMPLETE,
                "This was a multipart upload; etags for every part are required.",
                field="etags",
            )
        parts = [
            {"PartNumber": part.part_number, "ETag": part.etag}
            for part in sorted(etags, key=lambda p: p.part_number)
        ]
        key, upload_id = media.s3_key, media.s3_upload_id
        # Assembling the parts can take seconds for a video, and the store needs nothing from
        # Postgres while it does. Commit so the connection goes back to the pool rather than
        # sitting idle-in-transaction: `media_access` already read, so the transaction is open
        # by the time this runs. The metadata write below opens a new one.
        await session.commit()
        await s3.complete_multipart_upload(key, upload_id, parts, settings)
        media.s3_upload_id = None

    media.upload_status = "complete"
    if captured_at is not None:
        media.captured_at = captured_at
    if duration_seconds is not None:
        media.duration_seconds = duration_seconds
    await session.flush()

    # The entry's type was provisional until now: media arrives after the entry exists, so a
    # `did_it` row becomes a photo row the moment the photo lands. The trigger moves the
    # entry's updated_at, so the change syncs.
    from rascal.services.entries import refresh_entry_type

    entry = await session.get(Entry, media.entry_id)
    if entry is not None:
        await refresh_entry_type(session, entry)

    # The set_updated_at() trigger wrote a new updated_at that this object has not seen.
    await session.refresh(media)
    return media


async def write_derived(
    session: AsyncSession,
    media: Media,
    *,
    transcript: str | None,
    caption: str | None,
    tags: list[str] | None,
) -> tuple[Media, list[EntryTag]]:
    """Persist what the phone's models produced.

    This is durable data, not a cache — the server never regenerates it, and a browser that
    will never have an on-device model reads the same rows. Idempotent: sending the same
    transcript twice changes nothing.
    """
    if transcript is not None:
        media.transcript = transcript
    if caption is not None:
        media.caption = caption

    if tags is not None:
        from rascal.services.entries import apply_tags

        entry = await session.scalar(
            select(Entry).where(Entry.id == media.entry_id).options(selectinload(Entry.entry_tags))
        )
        if entry is None:
            raise not_found("Entry")
        # source='device_ai'. apply_tags refuses to touch a row a human wrote.
        await apply_tags(session, entry, tags, "device_ai")

    await session.flush()
    # Same as complete_upload: the trigger owns updated_at, so re-read it before serializing.
    await session.refresh(media)

    links = (
        (
            await session.execute(
                select(EntryTag)
                .where(EntryTag.entry_id == media.entry_id, EntryTag.deleted_at.is_(None))
                .options(selectinload(EntryTag.tag))
            )
        )
        .scalars()
        .all()
    )
    return media, list(links)


def download_url(media: Media, settings: Settings) -> str:
    """Presign a read for a finished upload.

    Refuses anything not `complete`. A pending row has either no bytes at the key yet or a
    partial multipart that was never assembled, and a presigned URL for it would 404 from
    storage — which reads to a client like the archive lost the photo rather than like the
    upload never finished.
    """
    if media.upload_status != "complete":
        raise RascalError(
            ErrorCode.UPLOAD_INCOMPLETE,
            "This upload has not finished, so there is nothing to read yet.",
            field="media_id",
        )
    return s3.presign_get(media.s3_key, settings)


async def load_media(session: AsyncSession, media_id: uuid.UUID) -> Media:
    media = await session.get(Media, media_id)
    if media is None or media.deleted_at is not None:
        raise not_found("Media")
    return media
