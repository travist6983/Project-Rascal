"""The full export — the archive-outlives-the-app insurance.

A zip containing every entry as JSON, every media object pulled down from S3, and a
manifest. Soft-deleted rows are included and marked, because an export that quietly drops
them is not a copy of the archive.

    manifest.json              what this is, when it was made, what is in it
    entries.json               every entry, with tags, media references, and deleted_at
    media/YYYY/MM/<file>       the objects themselves, foldered by when they happened

**Staged on disk, streamed to the client.** A zip of eighteen years of video will not fit in
a 512MB machine's memory, so it is assembled into a temporary file and then read back in
chunks. Nothing is ever held whole in RAM. The file is deleted once the response finishes.

The database read is async; the zip build is not. Everything the zip needs is flattened to
plain dicts first, so the blocking half runs in a worker thread and never touches the ORM —
a lazy load from inside a thread is exactly the bug that makes an export hang.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import os
import tempfile
import uuid
import zipfile
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from botocore.exceptions import ClientError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.config import Settings
from rascal.models import Assignment, Child, Entry, EntryTag, Media, Prompt
from rascal.services import s3

log = logging.getLogger("rascal.export")

# Read the staged zip back in chunks this size. Big enough to be efficient, small enough
# that the machine never notices.
STREAM_CHUNK_BYTES = 1024 * 1024

EXPORT_FORMAT_VERSION = 1


@dataclass
class ExportStats:
    entries: int = 0
    deleted_entries: int = 0
    media: int = 0
    media_bytes: int = 0
    # Objects the database knows about but S3 does not — an upload that never finished, or
    # a key that was removed underneath us. Named rather than fatal: a missing photo must
    # not cost you the other seventeen years.
    missing_media: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class _MediaFetch:
    """One object to pull down, and where it lands inside the zip."""

    media_id: uuid.UUID
    s3_key: str
    path: str


@dataclass(frozen=True)
class _Plan:
    """Everything the zip needs, as plain data. No ORM objects cross into the thread."""

    child: dict
    entries: list[dict]
    fetches: list[_MediaFetch]
    deleted_entries: int


def _iso(value: dt.datetime | dt.date | None) -> str | None:
    return value.isoformat() if value is not None else None


def _media_path(entry: Entry, media: Media) -> str:
    """`media/YYYY/MM/<media_id><ext>`, foldered by when the moment happened."""
    suffix = PurePosixPath(media.s3_key).suffix.lower()[:16]
    return f"media/{entry.occurred_at:%Y/%m}/{media.id}{suffix}"


def _entry_json(entry: Entry, prompt: Prompt | None) -> dict:
    return {
        "id": str(entry.id),
        "child_id": str(entry.child_id),
        "assignment_id": str(entry.assignment_id) if entry.assignment_id else None,
        "author_id": str(entry.author_id),
        "occurred_at": _iso(entry.occurred_at),
        "created_at": _iso(entry.created_at),
        "updated_at": _iso(entry.updated_at),
        "child_age_months": entry.child_age_months,
        "title": entry.title,
        "body": entry.body,
        "entry_type": entry.entry_type,
        # Sealed letters carry this. Exported in the clear — this is your copy of your own
        # archive, and an export you cannot read is not a backup.
        "unlock_at_age": entry.unlock_at_age,
        "deleted_at": _iso(entry.deleted_at),
        "is_deleted": entry.deleted_at is not None,
        "prompt": (
            {
                "id": str(prompt.id),
                "kind": prompt.kind,
                "cadence": prompt.cadence,
                "completion_mode": prompt.completion_mode,
                "body": prompt.body,
                "theme": prompt.theme,
            }
            if prompt is not None
            else None
        ),
        "tags": [
            {
                "id": str(link.tag_id),
                "name": link.tag.name,
                "source": link.source,
                "deleted_at": _iso(link.deleted_at),
            }
            for link in entry.entry_tags
        ],
        "media": [
            {
                "id": str(item.id),
                "kind": item.kind,
                # Filled in by the writer, once the object is actually in the zip. Null here
                # means "the row exists but the bytes did not arrive".
                "path": _media_path(entry, item),
                "s3_key": item.s3_key,
                "bytes": item.bytes,
                "duration_seconds": item.duration_seconds,
                "captured_at": _iso(item.captured_at),
                "transcript": item.transcript,
                "caption": item.caption,
                "upload_status": item.upload_status,
                "deleted_at": _iso(item.deleted_at),
                "is_deleted": item.deleted_at is not None,
            }
            for item in entry.media
        ],
    }


async def _load_everything(session: AsyncSession, child: Child) -> list[Entry]:
    """Every entry this child has, deleted ones included, oldest first."""
    rows = await session.execute(
        select(Entry)
        .where(Entry.child_id == child.id)
        .options(
            selectinload(Entry.media),
            selectinload(Entry.entry_tags).selectinload(EntryTag.tag),
        )
        .order_by(Entry.occurred_at.asc(), Entry.id.asc())
    )
    return list(rows.scalars().all())


async def _prompts_for(session: AsyncSession, entries: Sequence[Entry]) -> dict[uuid.UUID, Prompt]:
    """The originating prompt per entry, so the export says what was asked, not just answered."""
    assignment_ids = {entry.assignment_id for entry in entries if entry.assignment_id}
    if not assignment_ids:
        return {}
    rows = await session.execute(
        select(Assignment.id, Prompt)
        .join(Prompt, Prompt.id == Assignment.prompt_id)
        .where(Assignment.id.in_(assignment_ids))
    )
    return dict(rows.all())


async def plan_export(session: AsyncSession, child: Child) -> _Plan:
    """Read the whole archive out of Postgres and flatten it to plain data."""
    entries = await _load_everything(session, child)
    prompts = await _prompts_for(session, entries)

    records = [_entry_json(entry, prompts.get(entry.assignment_id)) for entry in entries]
    fetches = [
        _MediaFetch(media_id=item.id, s3_key=item.s3_key, path=_media_path(entry, item))
        for entry in entries
        for item in entry.media
    ]
    return _Plan(
        child={
            "id": str(child.id),
            "name": child.name,
            "birthdate": _iso(child.birthdate),
            "family_timezone": child.family_timezone,
        },
        entries=records,
        fetches=fetches,
        deleted_entries=sum(1 for entry in entries if entry.deleted_at is not None),
    )


def write_export(plan: _Plan, settings: Settings, destination: Path) -> ExportStats:
    """Assemble the zip at `destination`. Blocking: S3 reads and deflate. Runs in a thread."""
    stats = ExportStats(entries=len(plan.entries), deleted_entries=plan.deleted_entries)
    client = s3.get_s3_client()
    written: set[uuid.UUID] = set()

    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for fetch in plan.fetches:
            try:
                obj = client.get_object(Bucket=settings.s3_bucket, Key=fetch.s3_key)
            except ClientError:
                # An upload that never completed has a row and no object. Record it and
                # keep going — one missing photo must not cost you the other seventeen years.
                log.warning(
                    "export could not fetch media",
                    extra={"media_id": str(fetch.media_id), "s3_key": fetch.s3_key},
                )
                stats.missing_media.append(fetch.s3_key)
                continue

            # Stream S3 -> zip. The body is never read whole.
            with archive.open(fetch.path, "w") as target:
                for chunk in obj["Body"].iter_chunks(STREAM_CHUNK_BYTES):
                    target.write(chunk)
                    stats.media_bytes += len(chunk)

            written.add(fetch.media_id)
            stats.media += 1

        # A media row whose bytes never arrived keeps its metadata but loses its path, so
        # nothing in the manifest points at a file that is not in the archive.
        for record in plan.entries:
            for item in record["media"]:
                if uuid.UUID(item["id"]) not in written:
                    item["path"] = None

        archive.writestr(
            "entries.json",
            json.dumps(plan.entries, indent=2, ensure_ascii=False),
        )

        archive.writestr(
            "manifest.json",
            json.dumps(
                {
                    "format": "rascal-export",
                    "format_version": EXPORT_FORMAT_VERSION,
                    "generated_at": dt.datetime.now(tz=dt.UTC).isoformat(),
                    "child": plan.child,
                    "counts": {
                        "entries": stats.entries,
                        "deleted_entries": stats.deleted_entries,
                        "media": stats.media,
                        "media_bytes": stats.media_bytes,
                    },
                    "missing_media": stats.missing_media,
                    "notes": [
                        "entries.json contains every entry, including soft-deleted ones.",
                        "A soft-deleted entry has is_deleted true and a deleted_at timestamp.",
                        "Sealed letters are exported in the clear; unlock_at_age is retained.",
                        "media paths are relative to the root of this archive.",
                        "A media row with a null path is one whose bytes were not in S3.",
                    ],
                },
                indent=2,
                ensure_ascii=False,
            ),
        )

    return stats


async def build_export(
    session: AsyncSession, child: Child, settings: Settings, destination: Path
) -> ExportStats:
    """Read the archive, then write the zip off the event loop. Returns what went into it."""
    plan = await plan_export(session, child)
    stats = await asyncio.to_thread(write_export, plan, settings, destination)
    log.info(
        "built export",
        extra={
            "child_id": str(child.id),
            "exported_entries": stats.entries,
            "exported_media": stats.media,
            "absent_media": len(stats.missing_media),
        },
    )
    return stats


def stream_and_delete(path: Path) -> Iterator[bytes]:
    """Read the staged zip back in chunks, then remove it. Memory stays bounded."""
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(STREAM_CHUNK_BYTES):
                yield chunk
    finally:
        path.unlink(missing_ok=True)


def staging_path(child_id: uuid.UUID) -> Path:
    """Reserve a private temp file. The caller owns deleting it — see `stream_and_delete`."""
    fd, name = tempfile.mkstemp(prefix=f"rascal-export-{child_id}-", suffix=".zip")
    os.close(fd)
    return Path(name)


def filename_for(child: Child, now: dt.datetime | None = None) -> str:
    """`rascal-<child>-20260804.zip` — recognisable a decade from now in a Downloads folder.

    ASCII only, and not because ASCII is enough for a name. A `Content-Disposition` header is
    encoded latin-1 on the way out, so a name written in Arabic or Japanese would raise while
    the response was being sent — after the zip had already been built. The name is decoration
    here; the archive is not. A child whose name transliterates to nothing gets `child`, and
    the real name is in `manifest.json` in full.
    """
    stamp = (now or dt.datetime.now(tz=dt.UTC)).strftime("%Y%m%d")
    slug = "".join(
        ch if ch.isascii() and ch.isalnum() else "-" for ch in child.name.lower()
    ).strip("-")
    return f"rascal-{slug or 'child'}-{stamp}.zip"
