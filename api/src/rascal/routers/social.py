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

**Since phase 120 that sentence covers video too, and nothing here buys a frame.**
`POST /social/treatment` returns a typed scene graph; the browser animates it with the same
`cards.js` that draws a still, records the canvas, and posts the recording back here to be
re-encoded. The caption track is derived from the scene copy server-side rather than authored
beside it, so the cues cannot disagree with what is on screen — which they could, silently,
until this phase.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Query, Request, status
from fastapi.responses import StreamingResponse
from pydantic import ValidationError

from rascal.deps import AdminReadSession, AdminUser, LocalWrites, SessionDep, SettingsDep
from rascal.errors import ErrorCode, RascalError
from rascal.schemas.social import (
    ChatIn,
    ConceptsIn,
    PublishIn,
    RenderIn,
    SocialAssetIn,
    SocialAssetUpdate,
    TreatmentIn,
    VideoTreatment,
)
from rascal.services import s3
from rascal.services.social import (
    brand,
    director,
    instagram,
    publishing,
    renderers,
    renders,
    scenes,
    studio,
    transcode,
)

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
        # **Exactly the two facts the console cannot work out for itself, and no more.**
        #
        # This block was written with eight keys — the transitions, the scene and treatment
        # bounds, the copy maxima and the byte cap — on the reasoning that the composer would
        # build its controls from them. It has no scene editor, so six of those were served by
        # the API and read by nothing: the phase 101 defect, committed by the phase that cites
        # it. They are gone. `brand.py` remains the authority; the day a scene editor exists,
        # it can ask for what it needs then.
        "video": {
            # Which platform sizes may be recorded at all. The console gates the Record button
            # on this rather than keeping its own copy of `VIDEO_PLATFORMS`.
            "platforms": list(brand.VIDEO_PLATFORMS),
            # False means the machine cannot finish a recording, so the console disables the
            # Record button and puts the reason beside it rather than offering one that refuses.
            # **It is a `which ffmpeg`, not a codec probe** — a build without `libx264` reports
            # true here and fails at the encode, with a sentence naming ffmpeg.
            "ffmpeg": transcode.available(),
        },
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
    "/treatment",
    summary="A typed scene graph for a short video",
    description=(
        "**Claude writes cards, not film direction.** A treatment is an ordered list of "
        "scenes, each naming a template, a palette, its copy, how long it holds and how it "
        "enters — every value from a closed set the browser can actually draw. The pixels come "
        "from the same renderer that draws a still card; no vendor generates video.\n\n"
        "**The WebVTT track is derived from the scenes.** One cue per scene, cue boundaries "
        "exactly equal to the scene boundaries. It was derived before phase 120 too — but it "
        "was then stored in a column a `PATCH` could overwrite, and editing the shots did not "
        "re-derive it, so an edited post carried captions describing the previous video. It is "
        "now recomputed on every write and cannot be set by a caller at all. **Most social "
        "video is watched with the sound off**, and this one has no sound at all, so the cues "
        "carry the whole burden."
    ),
)
async def treatment(payload: TreatmentIn, user: AdminUser, settings: SettingsDep) -> dict[str, Any]:
    result = await director.structured(
        settings,
        director.treatment_instruction(payload.brief, payload.seconds),
        director.TREATMENT_SCHEMA,
    )
    # **Validated here, before the console ever sees it.** The JSON schema cannot carry every
    # bound — Anthropic's structured outputs reject a `minItems` above 1, and no JSON schema
    # can express "the durations sum to something watchable" at all — so a graph that would be
    # refused on save can come back from the model. Handing it to the console anyway would put
    # the refusal three clicks later, on a screen that had already drawn it.
    try:
        graph = VideoTreatment.model_validate({"scenes": result.get("scenes", [])})
    except ValidationError as error:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "The model wrote a treatment outside the bounds a video has to sit in "
            f"({error.error_count()} problems). Ask again — nothing was saved.",
            field="scenes",
        ) from error

    scene_list = [scene.model_dump() for scene in graph.scenes]
    return {
        "title": result.get("title"),
        "premise": result.get("premise"),
        "scenes": scene_list,
        "caption_track": scenes.caption_track(scene_list),
        "duration_ms": scenes.total_ms(scene_list),
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
        "never come through here. A provider with no credential answers **422** carrying the "
        "environment variable to set — this said 503 for three phases and the handler has "
        "always raised `VALIDATION_FAILED`."
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
        "This is **one of two** routes that take bytes through the API rather than handing "
        "back a presigned PUT — `POST /social/assets/{id}/video` is the other, added by phase "
        "120 on the identical argument. A browser cannot PUT to the bucket without a CORS "
        "policy on the bucket itself, and the bucket holds the archive — see "
        "`services/social/publishing.py`."
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
    await studio.update_asset(session, asset_id, {})  # 404s if it is not there

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

    # **Let the connection go before the two slow parts.** The existence check above autobegins
    # the request transaction and checks a connection out, and `get_session` holds it until the
    # handler returns — so without this it stays pinned across the browser upload *and* the PUT
    # to Tigris. The browser half is the worse one: it runs at the client's speed, so a phone on
    # a train holds a Neon connection for as long as that takes, and connections are the scarce
    # thing. Same discipline `publishing.run` uses, for the same reason.
    await session.commit()

    data = await request.body()
    key = await publishing.store_card(settings, asset_id, data)

    # Re-fetched because the row above belongs to a transaction that has ended. In principle the
    # asset could have gone in the meantime and this would 404 after the bytes were stored; in
    # practice nothing deletes a `social_assets` row — discarding a concept is a status, which is
    # why that table has no `deleted_at` — so the orphaned-object window is theoretical.
    asset = await studio.update_asset(session, asset_id, {})
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
        "scheduled runner. Refuses if the asset has already gone out, if one is already queued "
        "for it, or if `SOCIAL_PUBLISH_ENABLED` is false.\n\n"
        "**The too-soon 409 is a deferral, not a refusal.** If the account was posted to too "
        "recently — by this service or by the marketing repository, which shares the account "
        "— the attempt stays queued and the scheduled runner publishes it when the gap has "
        "passed. A caller that reads that 409 as *nothing happened* is wrong; re-read "
        "`GET /social/publications` after it."
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


@router.post(
    "/assets/{asset_id}/video",
    summary="Store the video the browser just recorded",
    description=(
        "Send the WebM as the raw request body. **The browser is the renderer**: it animates "
        "the post's scene graph with `cards.js`, captures the canvas with `MediaRecorder`, and "
        "posts the recording here. The server re-encodes it to H.264 MP4 — which is what a "
        "platform will accept and a WebM is not — and stores it.\n\n"
        "**Synchronous, and that is the change.** This used to answer 202 with a render id to "
        "poll, because it was seven paid generations and a concatenation. It is now a few "
        "seconds of ffmpeg, so the response is the finished `social_renders` row and there is "
        "nothing to poll.\n\n"
        "`Content-Type: video/webm`, capped at 64MB, and the EBML magic number is checked — "
        "the same reasoning as the JPEG check on `/image`: a wrong format otherwise surfaces "
        "as a downstream error naming neither the format nor the file.\n\n"
        "This is the **second** route in this API that takes bytes through the service rather "
        "than handing back a presigned PUT, and it is the same trade the first one made: a "
        "browser cannot PUT to the bucket without a CORS policy on the bucket, and that "
        "bucket holds the archive."
    ),
)
async def store_recording(
    asset_id: uuid.UUID,
    request: Request,
    session: SessionDep,
    user: AdminUser,
    settings: SettingsDep,
    _: LocalWrites,
) -> dict[str, Any]:
    asset = await studio.get_asset(session, asset_id)
    # Both refusals before a byte is read: no scene graph to have recorded, and no ffmpeg to
    # convert what was recorded. The second is the one that would otherwise be discovered
    # after the operator sat through a recording.
    renders.preflight(asset)

    # **Refuse on the header before reading, not on `len(data)` after.** `request.body()`
    # buffers the whole upload in memory first, so checking the size afterwards means the
    # oversized request has already cost what it was going to cost.
    declared = request.headers.get("content-length")
    cap = transcode.MAX_RECORDING_BYTES
    if declared is not None and declared.isdigit() and int(declared) > cap:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"That recording is {int(declared) // (1024 * 1024)}MB and the limit is "
            f"{cap // (1024 * 1024)}MB. A minute of cards is a few "
            "megabytes; something is wrong with the capture.",
        )

    # **Let the connection go before the two slow parts.** The read above autobegins the
    # request transaction and checks a connection out, and `get_session` holds it until the
    # handler returns — so without this it stays pinned across the browser upload *and* the
    # encode *and* the PUT to Tigris. Same discipline the card upload keeps, for the same
    # reason: connections are the scarce thing.
    await session.commit()

    data = await request.body()
    # **The backstop, and the header check above is not a substitute for it.** `Content-Length`
    # is absent entirely on a chunked request — which is what `fetch()` sends when the body is a
    # `ReadableStream` rather than a `Blob` — so the header branch is skipped and the body is
    # buffered whole. `publishing.store_card` has always had this second check; the video route
    # was written with only the first.
    if len(data) > cap:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"That recording is {len(data) // (1024 * 1024)}MB and the limit is "
            f"{cap // (1024 * 1024)}MB. A minute of cards is a few megabytes; something is "
            "wrong with the capture.",
        )

    asset = await studio.get_asset(session, asset_id)
    render = await renders.record(session, settings, asset, data)
    return renders.as_dict(render)


@router.get(
    "/assets/{asset_id}/video",
    summary="The newest recording of this post, if there is one",
    description=(
        "The newest attempt for this post, or `null` if it has never been recorded. There is "
        "no estimate beside it any more: a canvas render costs nothing, which is why "
        "`cost_cents` on the row is zero rather than absent."
    ),
)
async def render_status(
    asset_id: uuid.UUID, session: AdminReadSession, user: AdminUser
) -> dict[str, Any]:
    await studio.get_asset(session, asset_id)
    render = await renders.latest_for(session, asset_id)
    return {"render": renders.as_dict(render) if render else None}


@router.get(
    "/renders/{render_id}/file",
    summary="A short-lived URL for the file a render produced",
    description=(
        "Presigned, minted on demand and never stored — a URL in a column outlives its "
        "signature and then looks like data loss, which is why every other read path here "
        "does the same. A render that produced no file is a 404 rather than a URL that will "
        "not resolve: those are different answers and only one of them is actionable."
    ),
)
async def render_file(
    render_id: uuid.UUID, session: AdminReadSession, user: AdminUser, settings: SettingsDep
) -> dict[str, Any]:
    render = await renders.get(session, render_id)
    if not render.render_key:
        raise RascalError(
            ErrorCode.NOT_FOUND,
            "That render produced no file."
            + (f" It failed: {render.error}" if render.error else ""),
        )
    return {
        "url": s3.presign_get(render.render_key, settings),
        "expires_in": settings.presign_ttl_seconds,
    }
