"""Media. Three-step upload, and the on-device AI write-back."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends

from rascal.deps import (
    ChildAccess,
    SessionDep,
    SettingsDep,
    entry_access_from_body,
    media_access,
)
from rascal.schemas.entry import TagOut
from rascal.schemas.media import (
    MediaCompleteRequest,
    MediaDerivedRequest,
    MediaDerivedResponse,
    MediaOut,
    UploadUrlRequest,
    UploadUrlResponse,
)
from rascal.services import media as service

router = APIRouter(prefix="/media", tags=["media"])


@router.post(
    "/upload-url",
    response_model=UploadUrlResponse,
    summary="Presign an upload",
    description=(
        "A single presigned PUT under the multipart threshold, presigned multipart above it. "
        "Video always assumes multipart. The client uploads directly to S3 on a background "
        "URLSession; the server never proxies bytes."
    ),
)
async def upload_url(
    payload: UploadUrlRequest,
    session: SessionDep,
    settings: SettingsDep,
    # The child is reached through the entry named in the body; same check as everywhere else.
    access: ChildAccess = Depends(entry_access_from_body("parent")),
) -> UploadUrlResponse:
    plan = await service.plan_upload(
        session,
        access.child_id,
        entry_id=payload.entry_id,
        kind=payload.kind,
        filename=payload.filename,
        size=payload.bytes,
        content_type=payload.content_type,
        media_id=payload.media_id,
        settings=settings,
    )
    return UploadUrlResponse(
        media_id=plan.media.id,
        s3_key=plan.media.s3_key,
        upload_url=plan.upload_url,
        parts=plan.parts,
        multipart=plan.multipart,
        chunk_bytes=plan.chunk_bytes,
        expires_in=settings.presign_ttl_seconds,
    )


@router.post(
    "/{media_id}/complete",
    response_model=MediaOut,
    summary="Mark an upload finished",
    description=(
        "Completes the multipart upload if there was one and sets `upload_status`. "
        "`thumb_key` stays null: thumbnail and poster-frame generation is out of P0 scope."
    ),
)
async def complete(
    media_id: uuid.UUID,
    payload: MediaCompleteRequest,
    session: SessionDep,
    settings: SettingsDep,
    access: ChildAccess = Depends(media_access("parent")),
) -> MediaOut:
    media = await service.load_media(session, media_id)
    updated = await service.complete_upload(
        session,
        media,
        etags=payload.etags,
        captured_at=payload.captured_at,
        duration_seconds=payload.duration_seconds,
        settings=settings,
    )
    return MediaOut.model_validate(updated)


@router.patch(
    "/{media_id}/derived",
    response_model=MediaDerivedResponse,
    summary="Persist on-device transcripts, captions, and tags",
    description=(
        "The phone transcribes locally, then persists the text here so search works "
        "everywhere — including from a browser that will never have an on-device model. "
        "Tags written here get `entry_tags.source = 'device_ai'` and never overwrite or "
        "delete a row with `source = 'user'`. Idempotent."
    ),
)
async def derived(
    media_id: uuid.UUID,
    payload: MediaDerivedRequest,
    session: SessionDep,
    access: ChildAccess = Depends(media_access("parent")),
) -> MediaDerivedResponse:
    media = await service.load_media(session, media_id)
    updated, links = await service.write_derived(
        session,
        media,
        transcript=payload.transcript,
        caption=payload.caption,
        tags=payload.tags,
    )
    return MediaDerivedResponse(
        media=MediaOut.model_validate(updated),
        tags=[TagOut(id=link.tag_id, name=link.tag.name, source=link.source) for link in links],
    )
