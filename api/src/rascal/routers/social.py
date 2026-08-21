"""The social studio's API. Admin only, and since phase 104 it can publish to Instagram.

**Superseded Aug 20, 2026.** What stood here was: *"Every route generates or stores; none of
them posts. There is no social-network integration here, no scheduler, and no `publish` that
reaches the internet."* That was true of this file until phase 104 and is kept as history
rather than deleted. The owner asked for direct publishing, and when shown the sentence did not
recognise it — it was an agent's stance, never a row in `docs/decisions.md`.

**What the old paragraph got right is kept as the design.** An automation that posts on its own
is one bad generation away from doing so under the product's name, so nothing here posts on its
own: `SOCIAL_PUBLISH_ENABLED` defaults false and credentials alone do not switch it on, every
publish is a person pressing a button or a time that person chose, and the scheduled runner
publishes only rows a person queued. `status = "published"` is still what the owner sets by
hand for a post made somewhere this service cannot reach.

**The account is shared with the marketing repository**, by the owner's decision — one feed,
two publishers, no shared database. Spacing and the daily count are therefore read from
Instagram rather than from our own rows. See `services/social/instagram.py`.

**Claude writes words; it does not make pictures.** There is no image or video endpoint on any
Anthropic model. `POST /social/concepts` returns copy plus a template choice, and the pixels
come either from the brand-card renderer in the browser — no vendor, no key — or from a
third-party provider in `services/social/renderers.py`, which is unconfigured by default and
says so.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Query, Request, status
from fastapi.responses import StreamingResponse

from rascal.deps import AdminReadSession, AdminUser, LocalWrites, SessionDep, SettingsDep
from rascal.errors import ErrorCode, RascalError
from rascal.schemas.social import (
    ChatIn,
    ConceptsIn,
    PublishIn,
    RenderIn,
    ShotListIn,
    SocialAssetIn,
    SocialAssetUpdate,
)
from rascal.services.social import brand, director, instagram, publishing, renderers, studio

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


# --- Publishing ---------------------------------------------------------------------------
#
# Everything below reaches, or can reach, a public feed. `LocalWrites` is on every write for
# the usual reason and one extra: publishing while the console reads production and writes
# locally would put a post on the internet and record it in a database nobody will look at.


@router.get(
    "/account",
    summary="Which Instagram account the credentials point at, and whether now is a good time",
    description=(
        "Two different claims — *the call worked* and *there is a post on the account you are "
        "looking at* — so the handle is shown next to the button rather than assumed. "
        "`spacing` is read from Instagram, not from our own rows, because the marketing "
        "repository posts to this same account and cannot see our database."
    ),
)
async def account(user: AdminUser, settings: SettingsDep) -> dict[str, Any]:
    if not instagram.configured(settings):
        return {
            "configured": False,
            "publish_enabled": settings.social_publish_enabled,
            "setup": (
                "Set IG_USER_ID and IG_ACCESS_TOKEN. Both come from the Meta app that owns "
                "the Instagram professional account — see docs/blocked.md."
            ),
        }
    who = await instagram.account(settings)
    space = await instagram.spacing(settings)
    return {
        "configured": True,
        "publish_enabled": settings.social_publish_enabled,
        "username": who.username,
        "account_type": who.account_type,
        "media_count": who.media_count,
        "last_post_at": space.last_post_at.isoformat() if space.last_post_at else None,
        "posts_in_last_24h": space.posts_in_last_24h,
        "blocked_reason": space.blocked_reason,
    }


@router.post(
    "/assets/{asset_id}/image",
    summary="Store the card the browser just drew",
    description=(
        "Send the JPEG as the raw request body. **JPEG only** — Instagram publishes no other "
        "format and reports a PNG as a container in `ERROR` rather than as a readable "
        "message, so the magic number is checked here. Capped at 4MB.\n\n"
        "This is the one route that takes bytes through the API rather than handing back a "
        "presigned PUT. A browser cannot PUT to the bucket without a CORS policy on the "
        "bucket itself, and the bucket holds the archive — see `services/social/publishing.py`."
    ),
)
async def card_upload(
    asset_id: uuid.UUID,
    request: Request,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, str]:
    asset = await studio.update_asset(session, asset_id, {})  # 404s if it is not there

    # Refuse on the header before reading, not on `len(data)` after. `request.body()` buffers
    # the whole upload in memory first, so checking the size afterwards means the oversized
    # request has already cost what it was going to cost.
    declared = request.headers.get("content-length")
    if declared is not None and declared.isdigit() and int(declared) > publishing.MAX_CARD_BYTES:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"That image is {int(declared) // 1024}KB and the limit is "
            f"{publishing.MAX_CARD_BYTES // 1024}KB.",
        )
    data = await request.body()
    key = await publishing.store_card(settings, asset_id, data)
    # Set on the row directly, **not** through `update_asset`, whose `EDITABLE` tuple
    # deliberately excludes these two: a storage key is written by the code that stored the
    # bytes and must never be settable by a caller. Routing it through the editor instead
    # dropped it silently and cost a debugging session — the publish then refused for a
    # different reason and the missing key never surfaced.
    asset.render_key = key
    asset.render_provider = "card"
    await session.flush()
    return {"key": key, "bytes": str(len(data))}


@router.post(
    "/assets/{asset_id}/publish",
    summary="Put this on Instagram, now or at a time",
    description=(
        "Omit `scheduled_for` to publish in this request. Supply it to queue the post for the "
        "scheduled runner. Refuses if the asset has already gone out, if one is already "
        "queued for it, if the account was posted to too recently **by anyone**, or if "
        "`SOCIAL_PUBLISH_ENABLED` is false."
    ),
)
async def publish_asset(
    asset_id: uuid.UUID,
    payload: PublishIn,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, Any]:
    publication = await publishing.queue(
        session, settings, asset_id, user, scheduled_for=payload.scheduled_for
    )
    if payload.scheduled_for is not None:
        return publishing.as_dict(publication)
    published = await publishing.run(session, settings, publication)
    return publishing.as_dict(published)


@router.get("/publications", summary="The publish queue and what became of it")
async def list_publications(
    session: AdminReadSession,
    user: AdminUser,
    asset_id: Annotated[uuid.UUID | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 60,
) -> dict[str, Any]:
    rows = await publishing.list_publications(session, asset_id=asset_id, limit=limit)
    return {"publications": [publishing.as_dict(row) for row in rows]}


@router.post(
    "/publications/{publication_id}/cancel",
    summary="Take a scheduled post out of the queue",
    description=(
        "Legal only before it has gone out. A published post cannot be unpublished from here "
        "— that is the Instagram app's job, and pretending otherwise would be a lie in a "
        "button."
    ),
)
async def cancel_publication(
    publication_id: uuid.UUID,
    session: SessionDep,
    user: AdminUser,
    _: LocalWrites,
) -> dict[str, Any]:
    return publishing.as_dict(await publishing.cancel(session, publication_id))
