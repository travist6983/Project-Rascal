"""The full export — the archive-outlives-the-app insurance.

A zip containing every entry as JSON, every media object pulled down from S3, and a
manifest. Soft-deleted rows are included and marked, because an export that quietly drops
them is not a copy of the archive.

    manifest.json              what this is, when it was made, what is in it
    entries.json               every entry, with tags, media references, and deleted_at
    media/YYYY/MM/<file>       the objects themselves, foldered by when they happened

    index.html                 the same archive, readable by double-clicking it
    assets/app.css             constant for every export and every child — these three live
    assets/app.js              in export_viewer/ and are copied into the zip verbatim
    entries.js                 entries.json's bytes, wrapped in a variable assignment
    manifest.js                manifest.json's bytes, wrapped in a variable assignment

The JSON half is for machines and migration; the HTML half is for the person it belongs to.
There is one export path and one source of truth — the viewer reads the same bytes the
backup already contains, so it can never disagree with it, and if it is ever wrong you
regenerate it from a zip you already have.

`entries.js` exists because **a double-clicked `index.html` cannot `fetch()` a file next to
it** — browsers treat `file://` origins as opaque and block the request. A `<script>` tag is
not blocked. That constraint decides the layout, not a preference: the payload is duplicated
into a second file, which costs nearly nothing in the zip because the two are nearly
identical and deflate together.

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
from rascal.services.dates import local_day_window

log = logging.getLogger("rascal.export")

# Read the staged zip back in chunks this size. Big enough to be efficient, small enough
# that the machine never notices.
STREAM_CHUNK_BYTES = 1024 * 1024

EXPORT_FORMAT_VERSION = 1

# The readable layer. Constant bytes, shipped in the repository, copied in verbatim — the
# viewer is never generated, so there is nothing about it that can differ per child.
VIEWER_ROOT = Path(__file__).resolve().parent.parent / "export_viewer"


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
class ExportScope:
    """Which calendar days to export, as an inclusive range in the child's `family_timezone`.

    Both bounds are optional and either may stand alone: `from` with no `to` is "everything
    since", `to` with no `from` is "everything up to". Neither is the whole archive, which is
    what every caller before this got and still gets by sending nothing.

    **Days, not instants, and resolved in the family's zone** — the client names a date and the
    server decides which moment that is, the same rule that governs what "today" means. An
    entry logged at 8pm on Dec 31 in Detroit is stored as Jan 1 UTC; a range built from naive
    UTC dates would file it in the wrong year, which for a book printed once a year is a
    mistake nobody catches until it is on paper.
    """

    date_from: dt.date | None = None
    date_to: dt.date | None = None

    @property
    def is_complete(self) -> bool:
        return self.date_from is None and self.date_to is None

    def as_json(self, timezone: str) -> dict:
        """What `manifest.json` records, so a partial archive can never claim to be whole."""
        return {
            "complete": self.is_complete,
            "from": _iso(self.date_from),
            "to": _iso(self.date_to),
            "timezone": timezone,
        }


COMPLETE = ExportScope()


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
    scope: dict


def _iso(value: dt.datetime | dt.date | None) -> str | None:
    return value.isoformat() if value is not None else None


def _scope_notes(scope: dict) -> list[str]:
    """The first line of `manifest.notes`, which has to tell the truth about what is here.

    The complete export says it holds every entry, and that sentence has been in every archive
    since the format existed. **A scoped export may not say it** — someone opening this zip in
    2040 has only the manifest to tell them whether the gap before March is a gap in the child's
    life or a gap in the download, and getting that wrong is the one failure this file exists to
    prevent. The dates are spelled out with their zone for the same reason.
    """
    if scope["complete"]:
        return ["entries.json contains every entry, including soft-deleted ones."]

    if scope["from"] and scope["to"]:
        span = f"from {scope['from']} to {scope['to']} inclusive"
    elif scope["from"]:
        span = f"from {scope['from']} onward"
    else:
        span = f"up to and including {scope['to']}"
    return [
        f"THIS IS A PARTIAL ARCHIVE. It contains entries {span}, "
        f"by the date each one happened in {scope['timezone']}.",
        "Entries outside that range exist and are not in this file. Export without a date "
        "range to get the complete archive.",
        "Within the range, entries.json contains every entry, including soft-deleted ones.",
    ]


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


async def _load_everything(
    session: AsyncSession, child: Child, scope: ExportScope = COMPLETE
) -> list[Entry]:
    """Every entry this child has in `scope`, deleted ones included, oldest first.

    **Soft-deleted rows stay in, exactly as they do for the whole archive.** Scoping answers
    *which days*, never *which rows on those days* — an export that dropped deletions would
    stop being a copy, and doing that silently on the scoped path only would be worse than
    doing it everywhere.

    The bounds are half-open UTC instants derived from local days, so the predicate stays
    sargable on `(child_id, occurred_at desc)`. Filtering on `occurred_at` rather than
    `created_at` is the whole point: a photo taken in December and uploaded in January belongs
    to December's book. Backdating is a first-class flow here and this is where it shows.
    """
    statement = (
        select(Entry)
        .where(Entry.child_id == child.id)
        .options(
            selectinload(Entry.media),
            selectinload(Entry.entry_tags).selectinload(EntryTag.tag),
        )
        .order_by(Entry.occurred_at.asc(), Entry.id.asc())
    )
    # Each bound is derived from its own date, so an absent one is simply not applied. A
    # single-day window supplies both edges: the lower is that day's local midnight, the upper
    # is the next day's, which is the exclusive end this needs.
    if scope.date_from is not None:
        begins, _ = local_day_window(scope.date_from, scope.date_from, child.family_timezone)
        statement = statement.where(Entry.occurred_at >= begins)
    if scope.date_to is not None:
        _, ends = local_day_window(scope.date_to, scope.date_to, child.family_timezone)
        statement = statement.where(Entry.occurred_at < ends)

    rows = await session.execute(statement)
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


async def plan_export(session: AsyncSession, child: Child, scope: ExportScope = COMPLETE) -> _Plan:
    """Read the archive out of Postgres and flatten it to plain data.

    `scope` narrows which days are read; it defaults to the whole archive, so every caller
    that predates scoping behaves exactly as it did.
    """
    entries = await _load_everything(session, child, scope)
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
            # The viewer renders prompt bodies, and since phase 24 every seeded body carries
            # pronoun tokens. Without this key the archive prints a literal `{their}` — the
            # server still never renders (`decisions.md`), it just has to ship the answer the
            # renderer needs. `None` is a real value here and means the they/them column.
            "pronouns": child.pronouns,
        },
        entries=records,
        fetches=fetches,
        deleted_entries=sum(1 for entry in entries if entry.deleted_at is not None),
        scope=scope.as_json(child.family_timezone),
    )


def viewer_files() -> list[tuple[str, Path]]:
    """Every constant viewer file, as `(path inside the zip, path on disk)`.

    Raises if the directory is not there. That is deliberate and it is the less obvious of
    the two choices: the alternative is an export that quietly ships an `index.html` whose
    stylesheet and script are 404s, and nobody discovers that until they open the zip in
    2040. A packaging mistake should cost one loud export, not the readable half of the
    archive — and `test_export_viewer.py` fails long before an export does.
    """
    if not VIEWER_ROOT.is_dir():
        raise FileNotFoundError(f"export viewer assets are missing from the build: {VIEWER_ROOT}")
    files = sorted(path for path in VIEWER_ROOT.rglob("*") if path.is_file())
    if not files:
        raise FileNotFoundError(f"export viewer directory is empty: {VIEWER_ROOT}")
    return [(path.relative_to(VIEWER_ROOT).as_posix(), path) for path in files]


def _as_script(payload: bytes, variable: str) -> bytes:
    """Wrap already-serialized JSON in an assignment a `<script src>` tag can load.

    Three substitutions, and all three produce a JSON value identical to the input:

    - `</` becomes `<\\/`, because a `</script>` anywhere inside a body would close the tag
      early and truncate the archive. `\\/` is a valid JSON escape for `/`, and `<` can only
      appear inside a JSON string, so this is safe to do on the raw bytes.
    - U+2028 and U+2029 become their `\\u` escapes. They are legal inside a JSON string but
      were line terminators in JavaScript before ES2019, and a stray one turns the whole
      file into a syntax error on an older engine.

    The bytes are otherwise untouched: strip `window.<variable> = ` and the trailing `;` and
    you have the sibling `.json` file back, byte for byte. That is the point — one payload,
    serialized once, in two containers.
    """
    escaped = (
        payload.replace(b"</", b"<\\/")
        .replace(b"\xe2\x80\xa8", b"\\u2028")
        .replace(b"\xe2\x80\xa9", b"\\u2029")
    )
    return b"window." + variable.encode("ascii") + b" = " + escaped + b";\n"


def write_export(plan: _Plan, settings: Settings, destination: Path) -> ExportStats:
    """Assemble the zip at `destination`. Blocking: S3 reads and deflate. Runs in a thread."""
    stats = ExportStats(entries=len(plan.entries), deleted_entries=plan.deleted_entries)
    client = s3.get_s3_client()
    written: set[uuid.UUID] = set()

    # Resolved before a single byte is pulled from S3. If the build is missing the viewer,
    # the export should fail immediately rather than after downloading eighteen years of
    # video and then discovering it.
    viewer = viewer_files()

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

        # Serialized once and encoded once, then written into two containers. Building the
        # string twice would double the peak memory of the one part of this endpoint that
        # is not already streamed, on the archive that needs it least — an eighteen-year one.
        entries_bytes = json.dumps(plan.entries, indent=2, ensure_ascii=False).encode("utf-8")
        archive.writestr("entries.json", entries_bytes)
        archive.writestr("entries.js", _as_script(entries_bytes, "RASCAL_ENTRIES"))
        del entries_bytes

        manifest_bytes = json.dumps(
            {
                "format": "rascal-export",
                "format_version": EXPORT_FORMAT_VERSION,
                "generated_at": dt.datetime.now(tz=dt.UTC).isoformat(),
                "child": plan.child,
                # What this archive is a copy *of*. Without it a one-year export and a whole
                # archive are byte-indistinguishable in shape, and the smaller one reads as an
                # archive with years missing rather than as the slice somebody asked for.
                "scope": plan.scope,
                "counts": {
                    "entries": stats.entries,
                    "deleted_entries": stats.deleted_entries,
                    "media": stats.media,
                    "media_bytes": stats.media_bytes,
                },
                "missing_media": stats.missing_media,
                "notes": [
                    *_scope_notes(plan.scope),
                    "A soft-deleted entry has is_deleted true and a deleted_at timestamp.",
                    "Sealed letters are exported in the clear; unlock_at_age is retained.",
                    "media paths are relative to the root of this archive.",
                    "A media row with a null path is one whose bytes were not in S3.",
                    "Open index.html in a browser to read this archive. It needs no internet.",
                    "entries.js and manifest.js are the same bytes as the .json files, wrapped "
                    "in a variable assignment, because a page opened from a file path may not "
                    "fetch a file beside it but may load one with a script tag.",
                ],
            },
            indent=2,
            ensure_ascii=False,
        ).encode("utf-8")
        archive.writestr("manifest.json", manifest_bytes)
        archive.writestr("manifest.js", _as_script(manifest_bytes, "RASCAL_MANIFEST"))
        del manifest_bytes

        # The readable layer, verbatim.
        for name, source in viewer:
            archive.write(source, name)

    return stats


async def build_export(
    session: AsyncSession,
    child: Child,
    settings: Settings,
    destination: Path,
    scope: ExportScope = COMPLETE,
) -> ExportStats:
    """Read the archive, then write the zip off the event loop. Returns what went into it."""
    plan = await plan_export(session, child, scope)
    # The read is done and the plan is plain data by construction — no ORM object crosses into
    # the thread — so end the transaction before the S3 work starts. Pulling a gigabyte archive
    # object by object takes minutes, and holding the request's transaction across it parks one
    # of a small pool of Neon connections doing nothing; worse, a pooler that drops the stalled
    # connection turns a finished zip into a 500 when the session dependency commits.
    await session.commit()
    stats = await asyncio.to_thread(write_export, plan, settings, destination)
    log.info(
        "built export",
        extra={
            "child_id": str(child.id),
            "exported_entries": stats.entries,
            "exported_media": stats.media,
            "absent_media": len(stats.missing_media),
            "scope_from": _iso(scope.date_from),
            "scope_to": _iso(scope.date_to),
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


def filename_for(
    child: Child, now: dt.datetime | None = None, scope: ExportScope = COMPLETE
) -> str:
    """`pocket-chronicle-<child>-20260804.zip` — recognisable a decade from now in a
    Downloads folder.

    A scoped export is named for its range instead of the day it was made —
    `pocket-chronicle-mia-20260101-20261231.zip` — because two downloads taken the same
    afternoon would
    otherwise collide on the same name and the second would land as `(1)`. An open-ended
    bound reads `start` or `end` rather than being left blank, so the range is never ambiguous
    about which side is missing. The complete export's name is unchanged.

    Renamed with the product every time it has moved: `rascal-` → `dogear-` on Aug 12, 2026,
    → `vellum-` on Aug 17, and → `pocket-chronicle-` on Aug 27. **Nothing reads this string** —
    it is a `Content-Disposition` suggestion, not an identifier — so archives downloaded under
    any older prefix are unaffected and need no migration. The identifier that *must not* move is
    `manifest.format`, which is still `rascal-export`: the viewer checks it, and changing it would
    make every previously exported archive fail to open in a newer viewer.

    ASCII only, and not because ASCII is enough for a name. A `Content-Disposition` header is
    encoded latin-1 on the way out, so a name written in Arabic or Japanese would raise while
    the response was being sent — after the zip had already been built. The name is decoration
    here; the archive is not. A child whose name transliterates to nothing gets `child`, and
    the real name is in `manifest.json` in full.
    """
    if scope.is_complete:
        stamp = (now or dt.datetime.now(tz=dt.UTC)).strftime("%Y%m%d")
    else:
        first = scope.date_from.strftime("%Y%m%d") if scope.date_from else "start"
        last = scope.date_to.strftime("%Y%m%d") if scope.date_to else "end"
        stamp = f"{first}-{last}"
    ascii_only = (ch if ch.isascii() and ch.isalnum() else "-" for ch in child.name.lower())
    slug = "".join(ascii_only).strip("-")
    return f"pocket-chronicle-{slug or 'child'}-{stamp}.zip"
