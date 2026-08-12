"""The full export.

One route, and the reason it exists is not a feature request: an archive you cannot get out
of the app is not an archive. `docs/memory-app-roadmap.md` puts this in P1 next to the
backups for that reason.

Parent-only. A viewer can read the timeline; walking off with a copy of the whole childhood
is the account owner's to do.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from rascal.deps import ChildAccess, SessionDep, SettingsDep, child_access
from rascal.services import export as service

router = APIRouter(prefix="/children", tags=["children"])


@router.get(
    "/{child_id}/export",
    summary="Download the whole archive as a zip",
    description=(
        "`manifest.json`, `entries.json`, and every media object under `media/YYYY/MM/`. "
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
) -> StreamingResponse:
    child = access.child
    path = service.staging_path(child.id)
    try:
        stats = await service.build_export(session, child, settings, path)
    except BaseException:
        # Never leave a half-written zip in the machine's temp space. The success path hands
        # the file to stream_and_delete, which unlinks it once the client has it.
        path.unlink(missing_ok=True)
        raise

    return StreamingResponse(
        service.stream_and_delete(path),
        media_type="application/zip",
        headers={
            "content-disposition": f'attachment; filename="{service.filename_for(child)}"',
            # Known up front because the zip is already on disk, so a phone can show a real
            # progress bar instead of a spinner.
            "content-length": str(path.stat().st_size),
            "x-rascal-export-entries": str(stats.entries),
            "x-rascal-export-media": str(stats.media),
            "x-rascal-export-missing-media": str(len(stats.missing_media)),
        },
    )
