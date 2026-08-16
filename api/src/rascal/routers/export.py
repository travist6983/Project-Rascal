"""The full export.

One route, and the reason it exists is not a feature request: an archive you cannot get out
of the app is not an archive. `docs/memory-app-roadmap.md` puts this in P1 next to the
backups for that reason.

Parent-only. A viewer can read the timeline; walking off with a copy of the whole childhood
is the account owner's to do.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query
from fastapi.responses import StreamingResponse

from rascal.deps import ChildAccess, SessionDep, SettingsDep, child_access
from rascal.errors import validation_failed
from rascal.services import export as service

router = APIRouter(prefix="/children", tags=["children"])


@router.get(
    "/{child_id}/export",
    summary="Download the archive as a zip",
    description=(
        "`manifest.json`, `entries.json`, and every media object under `media/YYYY/MM/`. "
        "Defaults to the whole archive; `from` and `to` narrow it to an inclusive range of "
        "calendar days, and either may be sent alone. **The dates are days in the child's "
        "`family_timezone`, not UTC** — an entry logged at 8pm on Dec 31 in Detroit is stored "
        "as Jan 1 UTC and belongs to December, so the server resolves the boundary rather "
        "than the client. Entries are selected by `occurred_at`, never `created_at`: a photo "
        "taken in December and uploaded in January is December's. A scoped export records "
        "its range in `manifest.scope` and says so in `manifest.notes` — a partial archive "
        "must never be mistakable for a whole one.\n\n"
        "Soft-deleted entries are included and marked `is_deleted`; an export that quietly "
        "drops them is not a copy of the archive. Sealed letters are exported in the clear. "
        "The zip is assembled on disk and streamed back, so memory stays bounded no matter "
        "how many years are in it.\n\n"
        "The same zip also carries a readable layer: `index.html` plus `assets/app.css` and "
        "`assets/app.js`, which open the archive by double-clicking, with no server, no "
        "build step and no internet. They read `entries.js` and `manifest.js` — the same "
        "bytes as the `.json` files with a variable assignment wrapped around them, because "
        "a page opened from a `file://` path may not `fetch()` a file beside it but may "
        "load one with a `<script>` tag. There is one export and one source of truth."
    ),
    response_class=StreamingResponse,
    responses={
        200: {
            "content": {"application/zip": {}},
            "description": "The archive.",
        }
    },
)
async def export_child(
    session: SessionDep,
    settings: SettingsDep,
    access: ChildAccess = Depends(child_access("parent")),
    date_from: dt.date | None = Query(
        None,
        alias="from",
        description=(
            "Earliest day to include, inclusive, as a calendar date in the child's "
            "`family_timezone`. Omit for no lower bound."
        ),
    ),
    date_to: dt.date | None = Query(
        None,
        alias="to",
        description=(
            "Latest day to include, inclusive, as a calendar date in the child's "
            "`family_timezone`. Omit for no upper bound."
        ),
    ),
) -> StreamingResponse:
    child = access.child
    if date_from is not None and date_to is not None and date_from > date_to:
        raise validation_failed("`from` must not be after `to`.", field="from")

    scope = service.ExportScope(date_from=date_from, date_to=date_to)
    path = service.staging_path(child.id)
    try:
        stats = await service.build_export(session, child, settings, path, scope)
    except BaseException:
        # Never leave a half-written zip in the machine's temp space. The success path hands
        # the file to stream_and_delete, which unlinks it once the client has it.
        path.unlink(missing_ok=True)
        raise

    return StreamingResponse(
        service.stream_and_delete(path),
        media_type="application/zip",
        headers={
            "content-disposition": (
                f'attachment; filename="{service.filename_for(child, scope=scope)}"'
            ),
            # Known up front because the zip is already on disk, so a phone can show a real
            # progress bar instead of a spinner.
            "content-length": str(path.stat().st_size),
            "x-rascal-export-entries": str(stats.entries),
            "x-rascal-export-media": str(stats.media),
            "x-rascal-export-missing-media": str(len(stats.missing_media)),
        },
    )
