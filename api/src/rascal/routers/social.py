"""The social studio's API. Admin only, and it publishes nothing.

**Every route generates or stores; none of them posts.** There is no social-network
integration here, no scheduler, and no `publish` that reaches the internet — an asset is
written, reviewed, downloaded, and put out by a human somewhere else. `status = "published"`
is the owner recording that they did it. That is partly the same gate open item 12 puts on
marketing email, and partly the plainer point that an automation which posts on its own is one
bad generation away from doing so under the product's name.

**Claude writes words; it does not make pictures.** There is no image or video endpoint on any
Anthropic model. `POST /social/concepts` returns copy plus a template choice, and the pixels
come either from the brand-card renderer in the browser — no vendor, no key — or from a
third-party provider in `services/social/renderers.py`, which is unconfigured by default and
says so.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Query, status
from fastapi.responses import StreamingResponse

from rascal.deps import AdminReadSession, AdminUser, LocalWrites, SessionDep, SettingsDep
from rascal.errors import ErrorCode, RascalError
from rascal.models import SocialRender
from rascal.schemas.social import (
    ChatIn,
    ConceptsIn,
    RenderIn,
    ShotListIn,
    SocialAssetIn,
    SocialAssetUpdate,
)
from rascal.services.s3 import presign_get
from rascal.services.social import brand, director, renderers, renders, studio

router = APIRouter(prefix="/social", tags=["social"])


@router.get(
    "/studio",
    summary="What the studio can do right now",
    description=(
        "Which renderers are configured, how much of the mission library has already been "
        "put into posts, and the templates and palettes a concept may name. The console reads "
        "this before it draws anything, so a missing key is a card explaining itself rather "
        "than a button that fails."
    ),
)
async def studio_state(
    session: AdminReadSession, user: AdminUser, settings: SettingsDep
) -> dict[str, Any]:
    ledger = await studio.featured_body_ledger(session, settings)
    return {
        "director": {
            "configured": bool(settings.anthropic_api_key),
            "model": settings.anthropic_model,
            "setup": "Set ANTHROPIC_API_KEY to an ordinary sk-ant-api… key from "
            "platform.claude.com → API keys. This is not the sk-ant-admin… key the cost "
            "panel uses: they are different kinds of key and neither works in the other's "
            "place.",
            "cannot": "Claude writes copy, picks the layout and writes the image brief. It "
            "does not generate images or video: there is no such endpoint on any Anthropic "
            "model. Pixels come from the brand cards below, or from a provider.",
        },
        "renderers": [item.as_dict() for item in renderers.statuses(settings)],
        "library_ledger": ledger.as_dict(),
        "templates": list(brand.TEMPLATES),
        "palettes": list(brand.PALETTES),
        "platforms": list(brand.PLATFORMS),
        "platform_sizes": {name: list(size) for name, size in brand.PLATFORM_SIZES.items()},
    }


@router.post(
    "/chat",
    summary="Talk to the art director",
    description=(
        "Streams `text/plain` deltas. Streamed rather than returned whole because a good "
        "answer to an open brief is twenty seconds of thinking followed by a paragraph, and a "
        "console that shows nothing for twenty seconds reads as broken."
    ),
)
async def chat(payload: ChatIn, user: AdminUser, settings: SettingsDep) -> StreamingResponse:
    # Before the response starts, so a missing key is a 422 naming the variable rather
    # than a 200 whose body stops early — the status code is spent once headers are sent.
    director.require_key(settings)
    messages = [message.model_dump() for message in payload.messages]
    return StreamingResponse(
        director.chat(settings, messages),
        media_type="text/plain; charset=utf-8",
        # The console reads this with `fetch` and a `ReadableStream` rather than `EventSource`,
        # because `EventSource` cannot set an Authorization header and this API takes bearer
        # tokens like every other route rather than growing a cookie for one screen.
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


@router.post(
    "/concepts",
    summary="A set of post concepts, schema-enforced",
    description=(
        "Each concept differs in angle rather than in wording. Returns copy, a template, a "
        "palette, alt text and an image brief — the brief is written even when no photographic "
        "provider is configured, because it costs nothing now and is the expensive half to "
        "reconstruct later. Nothing is saved; `POST /social/assets` is what keeps one."
    ),
)
async def concepts(
    payload: ConceptsIn, session: SessionDep, user: AdminUser, settings: SettingsDep
) -> dict[str, Any]:
    featured = await studio.resolve_featured(session, settings, payload.featured_prompt_id)
    result = await director.structured(
        settings,
        director.concept_instruction(
            payload.brief, payload.count, payload.platform, featured[1] if featured else None
        ),
        director.CONCEPT_SCHEMA,
    )
    return {
        "concepts": result.get("concepts", []),
        "model": settings.anthropic_model,
        "featured_prompt_id": str(featured[0]) if featured else None,
        "featured_body": featured[1] if featured else None,
    }


@router.post(
    "/shot-list",
    summary="A shot list and a caption track for a short video",
    description=(
        "The half of a video that can be made tonight with a phone. Claude writes the shots, "
        "the on-screen text and the voiceover; the WebVTT track is derived from them. **Most "
        "social video is watched with the sound off**, so the caption track is the reach "
        "feature as much as the accessibility one."
    ),
)
async def shot_list(payload: ShotListIn, user: AdminUser, settings: SettingsDep) -> dict[str, Any]:
    result = await director.structured(
        settings,
        director.shot_list_instruction(payload.brief, payload.seconds),
        director.SHOT_LIST_SCHEMA,
    )
    shots = result.get("shots", [])
    return {
        "title": result.get("title"),
        "premise": result.get("premise"),
        "shots": shots,
        "caption_track": renderers.caption_track(shots),
        "duration_seconds": sum(int(shot.get("seconds") or 0) for shot in shots),
        "model": settings.anthropic_model,
    }


@router.get("/assets", summary="Saved posts, newest first")
async def list_assets(
    session: AdminReadSession,
    user: AdminUser,
    status_filter: Annotated[str | None, Query(alias="status")] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 60,
) -> dict[str, Any]:
    rows = await studio.list_assets(session, status=status_filter, limit=limit)
    return {"assets": [studio.as_dict(asset) for asset in rows]}


@router.post(
    "/assets",
    status_code=status.HTTP_201_CREATED,
    summary="Keep a concept",
    description=(
        "`featured_prompt_id` is the only way a mission-library body reaches a post, the body "
        "is read server-side rather than accepted from the caller, and doing so consumes a "
        "unit of the D7 cap — see `GET /social/studio`."
    ),
)
async def create_asset(
    payload: SocialAssetIn,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, Any]:
    asset = await studio.create_asset(
        session, settings, payload.model_dump(exclude_unset=True), user
    )
    return studio.as_dict(asset)


@router.patch(
    "/assets/{asset_id}",
    summary="Edit a saved post, or move it along",
    description=(
        "Moving to `exported` or `published` requires alt text. The check is here rather than "
        "at creation because that is the moment the file is about to be used, and a rule "
        "enforced while somebody is still typing is a rule that gets switched off."
    ),
)
async def patch_asset(
    asset_id: uuid.UUID,
    payload: SocialAssetUpdate,
    session: SessionDep,
    user: AdminUser,
    _: LocalWrites,
) -> dict[str, Any]:
    asset = await studio.update_asset(session, asset_id, payload.model_dump(exclude_unset=True))
    return studio.as_dict(asset)


@router.post(
    "/assets/{asset_id}/render",
    summary="Hand this post's image brief to a pixel provider",
    description=(
        "Only for photographic images and video. Brand cards are drawn in the browser and "
        "never come through here. A provider with no credential answers 503 carrying the "
        "environment variable to set."
    ),
)
async def render_asset(
    asset_id: uuid.UUID,
    payload: RenderIn,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, Any]:
    asset = await studio.update_asset(session, asset_id, {})
    prompt = payload.prompt or asset.image_prompt
    if not prompt:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "There is no image brief on this post and none was supplied.",
            field="prompt",
        )
    try:
        if payload.kind == "video":
            rendered = await renderers.render_video(settings, prompt)
        else:
            rendered = await renderers.render_image(settings, payload.provider, prompt)
    except LookupError:
        hint = next(
            (item for item in renderers.statuses(settings) if item.key == payload.provider),
            None,
        )
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"{payload.provider} is not configured. "
            + (hint.setup if hint else "No such renderer."),
            field="provider",
        ) from None
    except Exception as exc:
        raise RascalError(ErrorCode.VALIDATION_FAILED, f"{payload.provider} failed: {exc}") from exc

    asset.render_provider = rendered.provider
    asset.render_key = rendered.s3_key
    asset.format = "video" if payload.kind == "video" else "photo"
    await session.flush()
    await session.refresh(asset)
    return studio.as_dict(asset)


@router.post(
    "/assets/{asset_id}/video",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Render the shot list into one video",
    description=(
        "Seven shots are seven generations and a concatenation, so this returns **202 with a "
        "render id to poll** rather than blocking for the minutes it takes. Every reason to "
        "refuse — no shot list, no key, no ffmpeg, a render already running — is checked "
        "before the first clip is generated, because the expensive failure is the one "
        "discovered after paying for six of them."
    ),
)
async def render_video(
    asset_id: uuid.UUID,
    background: BackgroundTasks,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, Any]:
    asset = await studio.get_asset(session, asset_id)
    shots = await renders.preflight(session, settings, asset)
    render = await renders.create(session, settings, asset, shots)
    # Detached from this request: it outlives the response by minutes. The row is already
    # committed, so a machine that dies before the task starts leaves a `queued` row rather
    # than a button that did nothing.
    background.add_task(renders.run, render.id)
    return renders.as_dict(render)


@router.get(
    "/assets/{asset_id}/video",
    summary="How the render is going",
    description=(
        "The newest attempt for this post, or `null` if it has never been rendered. "
        "`shots_done` counts clips that actually landed in the bucket, so it is progress "
        "rather than a percentage somebody computed."
    ),
)
async def render_status(
    asset_id: uuid.UUID, session: AdminReadSession, user: AdminUser, settings: SettingsDep
) -> dict[str, Any]:
    asset = await studio.get_asset(session, asset_id)
    render = await renders.latest_for(session, asset_id)
    return {
        "render": renders.as_dict(render) if render else None,
        # What it would cost to render this treatment, so the console can say so beside the
        # button rather than after the fact.
        "estimate_cents": renders.estimate_cents(settings, renders.shots_of(asset)),
    }


@router.get(
    "/renders/{render_id}/file",
    summary="A short-lived link to a finished render",
    description=(
        "A presigned URL, minted on request and never stored. The column holds an object key "
        "for exactly this reason: a signed URL written to the database outlives its signature "
        "and then reads as data loss."
    ),
)
async def render_file(
    render_id: uuid.UUID, session: AdminReadSession, user: AdminUser, settings: SettingsDep
) -> dict[str, Any]:
    render = await session.get(SocialRender, render_id)
    if render is None or not render.render_key:
        raise RascalError(
            ErrorCode.NOT_FOUND, "That render has produced no file.", field="render_id"
        )
    return {"url": presign_get(render.render_key, settings), "key": render.render_key}
