"""Getting a card from the console onto a platform, and keeping a record that it happened.

`instagram.py` knows how to talk to Meta. This module decides *whether* to, in what order, and
what to write down — the part that has to be right even when the network is not.

**The order of operations is the design.** Every step before the publish call is reversible and
every step after it is not, so the irreversible one happens as late as possible and with as
much known as possible:

1. refuse if publishing is switched off, if the asset has no alt text, if it has no image
2. ask Instagram whether this caption is already on the account — *before* anything is built
3. ask Instagram whether the account was posted to too recently, by anyone
4. build a container from a presigned URL and **write its id to the row**
5. publish the container
6. write the media id, permalink and time

Steps 2 and 3 are reads against Meta and cost a second. They are worth it: a duplicate on a
public feed is the only failure here that strangers see and that nothing on our side can undo,
and the account is shared with a second publisher that cannot see our database.

**The image is snapshotted, not referenced.** The console uploads the exact JPEG it drew, and
the publication row keeps the key, the caption and the alt text as they were at that moment. An
asset stays editable afterwards; what went out did not change.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from typing import Any

from anyio import to_thread
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError, not_found
from rascal.models import SocialAsset, SocialPublication, User
from rascal.services.s3 import get_s3_client, presign_get
from rascal.services.social import instagram

log = logging.getLogger("rascal.social.publishing")

#: Platforms this service can actually reach. `SOCIAL_PLATFORMS` is longer because it says
#: where a *concept* is aimed; this says where there is a publisher. The owner's instruction on
#: Aug 20, 2026 was "all socials eventually, start with ONLY instagram", so the gap between
#: these two tuples is deliberate and the error message below names it rather than 500ing.
PUBLISHABLE: tuple[str, ...] = ("instagram", "instagram_story")

#: Instagram wants JPEG and nothing else. The console encodes the canvas accordingly; this is
#: the server refusing to be the place that finds out.
_CONTENT_TYPE = "image/jpeg"


class PublishingDisabled(RascalError):
    """`SOCIAL_PUBLISH_ENABLED` is false.

    A type rather than a message anybody has to match on. It is a deliberate state, not a
    fault: the console shows it as a sentence beside a disabled button, and the hourly runner
    reports it and exits 0 — a queued row plus a false flag must not paint that machine red
    every hour until somebody stops reading it.
    """

    def __init__(self) -> None:
        super().__init__(
            ErrorCode.PUBLISH_FAILED,
            "Publishing is switched off. Set SOCIAL_PUBLISH_ENABLED=true when you want this "
            "service to post — credentials alone deliberately do not switch it on.",
        )


class TooSoon(RascalError):
    """The account was posted to too recently — by us, or by the marketing repository.

    A subclass rather than a new error code. To the console this is a 409 like any other and
    the message is the whole point; to the scheduled runner it is *come back next hour* rather
    than a failure, and a job that had to match on the wording of a sentence to tell those
    apart would break the first time somebody improved the sentence.
    """

    def __init__(self, message: str) -> None:
        super().__init__(ErrorCode.CONFLICT, message)


def _key_for(asset_id: uuid.UUID, now: dt.datetime) -> str:
    """`social/` rather than `children/`, the same split `renderers.py` makes and for the same
    reason: marketing output must never be mistaken for somebody's archive by a lifecycle rule,
    a deletion sweep, or a person reading a bucket listing."""
    return f"social/{now:%Y/%m}/{asset_id.hex}-{uuid.uuid4().hex[:8]}.jpg"


#: A brand card is flat colour and type at 1080px. Anything an order of magnitude past this is
#: not a card, and the cap is what stops this route being a way to put arbitrary bytes in the
#: bucket that holds the archive.
MAX_CARD_BYTES = 4 * 1024 * 1024

#: JPEG's magic number. Checked rather than trusted: `Content-Type` is whatever the caller
#: typed, and Meta's failure for a non-JPEG is a container in `ERROR` with no useful message.
_JPEG_MAGIC = b"\xff\xd8\xff"


async def store_card(settings: Settings, asset_id: uuid.UUID, data: bytes) -> str:
    """Put the JPEG the browser drew into the bucket, and return its key.

    **This is the one place in this service where bytes go through the API**, and `s3.py` opens
    by saying they never do. The exception is deliberate and narrow, and the reasoning is worth
    keeping because the obvious alternative looks cheaper than it is.

    A presigned PUT is what every other upload here uses and it was the first implementation.
    It does not work from a browser: the console is served from this origin and the bucket is
    another, so the PUT is cross-origin and dies in preflight unless the **bucket** carries a
    CORS policy naming the console's origins. Verified in Chrome, not assumed — `TypeError:
    Failed to fetch`, with no request reaching Tigris at all.

    So the choice was a CORS policy on the media bucket, or relaying the file. **The bucket
    holds the archive** — every photo and video anybody has ever put in this product — and
    widening what a browser origin may do against it in order to publish a marketing card is
    the wrong side of a trade that is not close. The rule it bends exists for the archive's own
    byte path, where files are multi-gigabyte video and proxying would be absurd. A social card
    is a few hundred kilobytes of flat colour, capped here at four megabytes, checked to be a
    JPEG before it is stored.
    """
    if len(data) > MAX_CARD_BYTES:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"That image is {len(data) // 1024}KB and the limit is "
            f"{MAX_CARD_BYTES // 1024}KB. A brand card should be a fraction of it.",
        )
    if not data.startswith(_JPEG_MAGIC):
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "That is not a JPEG. Instagram publishes no other format, and it reports a PNG as "
            "a container in ERROR rather than as a readable message.",
        )

    key = _key_for(asset_id, dt.datetime.now(tz=dt.UTC))
    await to_thread.run_sync(lambda: _put(settings, key, data))
    return key


def _put(settings: Settings, key: str, data: bytes) -> None:
    get_s3_client().put_object(
        Bucket=settings.s3_bucket, Key=key, Body=data, ContentType=_CONTENT_TYPE
    )


async def _load_asset(session: AsyncSession, asset_id: uuid.UUID) -> SocialAsset:
    asset = await session.get(SocialAsset, asset_id)
    if asset is None:
        raise not_found("Social asset")
    return asset


def _full_caption(asset: SocialAsset) -> str:
    """Caption then hashtags, one blank line between them — the way a feed reads it.

    **The console composes this a second time** to show the confirmation, so the two have to
    agree exactly: a confirmation that does not match what goes out is worse than no
    confirmation. The rule, in both places, is *strip whitespace, then strip any leading
    hashes, then add exactly one*. This trimmed neither, so `" vellum "` went out as
    `"# vellum "` while the console showed `#vellum`.
    """
    tags = " ".join(
        f"#{cleaned}"
        for cleaned in ((tag or "").strip().lstrip("#").strip() for tag in (asset.hashtags or []))
        if cleaned
    )
    caption = (asset.caption or "").strip()
    return f"{caption}\n\n{tags}".strip() if tags else caption


def _check_publishable(asset: SocialAsset, settings: Settings) -> None:
    """Everything that must be true before anything reaches Meta.

    Ordered so the cheapest and most likely refusal comes first, and worded so each one names
    the thing to do about it. A publish refusal that says only "invalid" sends somebody to read
    this file.
    """
    if not settings.social_publish_enabled:
        raise PublishingDisabled()
    if asset.platform not in PUBLISHABLE:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"There is no publisher for {asset.platform!r} yet — Instagram is the only "
            "platform this service can post to. Download the file and post it by hand.",
            field="platform",
        )
    if not instagram.configured(settings):
        raise RascalError(
            ErrorCode.PUBLISH_FAILED,
            "Instagram is not configured — IG_USER_ID and IG_ACCESS_TOKEN are not set.",
        )
    if not asset.render_key:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "There is no image on this post yet. The console uploads the card it drew before "
            "publishing; if you are seeing this, that upload did not finish.",
            field="render_key",
        )
    # The same rule `update_asset` applies at export, applied at the moment it matters most.
    if not (asset.alt_text or "").strip() and asset.platform != "instagram_story":
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "This post has no alt text. An image posted without it is a post a blind reader "
            "gets nothing from — write one sentence describing what is visibly in it.",
            field="alt_text",
        )
    if not _full_caption(asset) and asset.platform != "instagram_story":
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "This post has no caption.",
            field="caption",
        )


async def _live_publication(session: AsyncSession, asset_id: uuid.UUID) -> SocialPublication | None:
    rows = await session.execute(
        select(SocialPublication).where(
            SocialPublication.asset_id == asset_id,
            SocialPublication.status.in_(("scheduled", "publishing")),
        )
    )
    return rows.scalars().first()


async def queue(
    session: AsyncSession,
    settings: Settings,
    asset_id: uuid.UUID,
    user: User,
    *,
    scheduled_for: dt.datetime | None,
) -> SocialPublication:
    """Write the intention down before acting on it.

    Both the immediate publish and the scheduled one come through here, and the row exists
    before any network call does. `scheduled_for = None` means "the next time anything looks",
    which for an immediate publish is the same request.
    """
    asset = await _load_asset(session, asset_id)
    _check_publishable(asset, settings)

    if asset.published_at is not None:
        raise RascalError(
            ErrorCode.CONFLICT,
            f"This post already went out at {asset.published_at.isoformat()}. "
            "Duplicate it if you meant to post it again.",
        )
    existing = await _live_publication(session, asset_id)
    if existing is not None:
        when = existing.scheduled_for.isoformat() if existing.scheduled_for else "the next check"
        raise RascalError(
            ErrorCode.CONFLICT,
            f"This post is already queued for {when}. Cancel that before queueing another.",
        )

    publication = SocialPublication(
        asset_id=asset.id,
        platform=asset.platform,
        status="scheduled",
        scheduled_for=scheduled_for,
        image_key=asset.render_key,
        caption=_full_caption(asset),
        alt_text=asset.alt_text,
        created_by_user_id=user.id,
    )
    session.add(publication)
    try:
        await session.flush()
    except IntegrityError as exc:
        # `uq_social_publications_live_per_asset`. The check above is the readable answer and
        # this is the one that holds when two requests — or the web machine and the scheduled
        # one — look in the same instant. Without it a double-click is `internal_error`.
        await session.rollback()
        raise RascalError(
            ErrorCode.CONFLICT,
            "This post was queued a moment ago by something else. Reload the queue.",
        ) from exc
    return publication


async def run(
    session: AsyncSession,
    settings: Settings,
    publication: SocialPublication,
) -> SocialPublication:
    """Actually put it on Instagram. **The only irreversible function in this service.**

    **This function commits, and that is the whole point of it.** `db.get_session` gives one
    transaction per request and rolls it back on any exception, so a `failed` row written with
    `flush` alone — and, worse, the `container_id` written just before the irreversible call —
    would be erased by the very failure they exist to record. The first version of this did
    exactly that and the durability argument in the module docstring was void over HTTP.
    `services/broadcast.py` had already solved the same problem the same way: *"Committed
    before the call, so the day is claimed even if the process dies mid-request."*

    The cost of committing the claim is a row that can be left in `publishing` by a process
    that dies mid-flight — which the partial unique index then makes permanent, since nothing
    else may be queued for that asset. `reclaim()` below is the way out, and it is why the
    container id is worth writing down.

    Raises rather than returning a failed row: the console shows the message, and the queue
    keeps the reason either way.
    """
    # Idempotent on a row that already went out. Cheap, and it is the difference between a
    # double-clicked scheduler run and a second post.
    if publication.status == "published":
        return publication
    if publication.status != "scheduled":
        # `publishing` belongs to another attempt and is `reclaim()`'s to settle; `cancelled`
        # and `failed` are decisions somebody made, and a stale reference must not undo them.
        raise RascalError(
            ErrorCode.CONFLICT,
            f"This attempt is {publication.status} and cannot be run. Queue a new one.",
        )

    asset = await _load_asset(session, publication.asset_id)
    try:
        _check_publishable(asset, settings)
    except PublishingDisabled:
        # Deliberate and reversible. The row waits.
        raise
    except RascalError as exc:
        # Anything else here will still be true next hour — the alt text was deleted, the
        # platform was changed to one with no publisher. Failing the row stops an hourly alarm
        # nobody can act on from the log, and puts the reason in the console where they can.
        await _record_failure(session, publication, exc.message, from_scheduled=True)
        raise

    # Checked here as well as in `queue()`, because a scheduled row sits for hours and the
    # owner can mark the asset published by hand in the meantime.
    if asset.published_at is not None:
        publication.status = "cancelled"
        went_out = asset.published_at.isoformat()
        publication.error = f"The asset was already marked published at {went_out}."
        await session.commit()
        raise RascalError(
            ErrorCode.CONFLICT,
            f"This post already went out at {went_out}, so the queued attempt was cancelled "
            "rather than posting it a second time.",
        )

    story = publication.platform == "instagram_story"
    caption = publication.caption or ""

    if not await _claim(session, publication):
        raise RascalError(
            ErrorCode.CONFLICT,
            "Something else is already publishing this. Nothing was sent twice.",
        )

    try:
        # 1. Is it already up? Asked of Instagram, not of us — see `instagram.find_published`.
        #    Skipped for stories, which carry no caption to match on.
        if not story and instagram.searchable(caption):
            already = await instagram.find_published(settings, caption)
            if already is not None:
                log.warning("asset was already on the account", extra={"asset_id": str(asset.id)})
                return await _record_success(
                    session,
                    asset,
                    publication,
                    media_id=already.id,
                    permalink=already.permalink,
                    published_at=already.timestamp,
                )

        # 2. Has the account been posted to too recently — by us or by the marketing queue?
        space = await instagram.spacing(settings)
        if not space.clear:
            # Back to `scheduled` and committed, so the row really is queued and the hourly
            # runner really will take it. Rolling this back would have made the console's
            # "posting resumes in about N minutes" a sentence with nothing behind it.
            publication.status = "scheduled"
            await session.commit()
            raise TooSoon(space.blocked_reason or "The account was posted to too recently.")

        # 3. Build the container from a URL Meta can fetch, and write its id down first.
        image_url = await to_thread.run_sync(
            lambda: presign_get(publication.image_key or "", settings)
        )
        container_id = await instagram.create_container(
            settings,
            image_url=image_url,
            caption=caption,
            alt_text=publication.alt_text,
            story=story,
        )
        publication.container_id = container_id
        await session.commit()

        await instagram.wait_for_container(settings, container_id)

        # 4. The irreversible one.
        media_id = await instagram.publish_container(settings, container_id)
        permalink = await instagram.permalink_for(settings, media_id)
    except TooSoon:
        raise
    except RascalError as exc:
        await _record_failure(session, publication, exc.message)
        raise

    return await _record_success(
        session, asset, publication, media_id=media_id, permalink=permalink, published_at=None
    )


async def _claim(session: AsyncSession, publication: SocialPublication) -> bool:
    """Take the row, atomically, or find out somebody else already has it.

    **Reading `scheduled` and then writing `publishing` is not the same thing**, and the gap
    between them is a double post. Two runners — the hourly machine and a hand-run, which the
    runbook actively encourages — can both `SELECT` a due row before either has written
    anything, and then both build a container and both publish. Nothing downstream catches it:
    the partial unique index guards two *rows* for one asset, and this is one row published
    twice. `find_published` does not catch it either, because both processes ask Instagram
    before either has posted.

    So the transition is one statement with the old state in its `WHERE`, and the loser is told
    plainly rather than left to discover it on the feed. `rowcount` is the whole mechanism.

    The commit is what makes the claim visible to the other runner *and* what ends the
    transaction: everything after this point is a network call to Meta, and none of them is
    made with a database transaction open.
    """
    result = await session.execute(
        update(SocialPublication)
        .where(
            SocialPublication.id == publication.id,
            SocialPublication.status == "scheduled",
        )
        .values(
            status="publishing",
            attempts=SocialPublication.attempts + 1,
            error=None,
        )
    )
    await session.commit()
    if result.rowcount != 1:
        return False
    # The UPDATE went round the ORM, so the instance in memory still says `scheduled`.
    await session.refresh(publication)
    # **And that refresh opens a transaction which would then stay open for the whole exchange
    # with Meta** — SQLAlchemy begins one on the next statement after a commit, so the careful
    # commits above would have ended the transaction only for a read to start another one and
    # hold it across `create_container`, a poll loop of up to thirty seconds, and the publish.
    # Found by the test that asserts it, not by reading this function.
    await session.commit()
    return True


async def _record_failure(
    session: AsyncSession,
    publication: SocialPublication,
    message: str,
    *,
    from_scheduled: bool = False,
) -> None:
    """Keep the reason where the console can read it, whatever the caller does next.

    Only a row this call actually claimed may be failed — `from_scheduled` is the one exception,
    for a queued attempt whose problem is permanent and which would otherwise be retried hourly
    forever.
    """
    allowed = ("publishing", "scheduled") if from_scheduled else ("publishing",)
    if publication.status not in allowed:
        return
    publication.status = "failed"
    publication.error = message
    await session.commit()


async def _record_success(
    session: AsyncSession,
    asset: SocialAsset,
    publication: SocialPublication,
    *,
    media_id: str,
    permalink: str | None,
    published_at: dt.datetime | None,
) -> SocialPublication:
    """Write down that it went out, and refuse to claim a post another row already owns.

    The clash is not hypothetical on a shared account: `find_published` matches a caption's
    first line against the whole feed, so two assets opening the same way could both resolve to
    one post. `uq_social_publications_media_id` would then raise an `IntegrityError` and the
    console would show `internal_error` for something with a perfectly good explanation.
    """
    owner = await session.scalar(
        select(SocialPublication.id).where(
            SocialPublication.media_id == media_id,
            SocialPublication.id != publication.id,
        )
    )
    if owner is not None:
        message = (
            f"Instagram post {media_id} is already recorded against another attempt "
            f"({owner}). Nothing was posted twice; this attempt matched an existing post by "
            "its caption and the match was wrong."
        )
        await _record_failure(session, publication, message)
        raise RascalError(ErrorCode.CONFLICT, message)

    now = published_at or dt.datetime.now(tz=dt.UTC)
    publication.status = "published"
    publication.media_id = media_id
    publication.permalink = permalink
    publication.published_at = now
    publication.error = None
    asset.status = "published"
    if asset.published_at is None:
        asset.published_at = now
    try:
        await session.commit()
    except IntegrityError as exc:
        # `uq_social_publications_media_id`, lost between the check above and this write —
        # two runners resolving the same abandoned claim in the same second. The post is fine
        # and already recorded by the winner; only this row's account of it is wrong.
        await session.rollback()
        raise RascalError(
            ErrorCode.CONFLICT,
            f"Instagram post {media_id} was recorded by another attempt while this one was "
            "writing. Nothing was posted twice.",
        ) from exc
    return publication


#: How long a row may sit in `publishing` before it is treated as abandoned. Generous, because
#: `wait_for_container` alone can legitimately take half a minute and a slow publish longer.
STALE_AFTER = dt.timedelta(minutes=15)

#: What the console shows on a claim that cannot be settled from here. Written once and then
#: left alone: rewriting it every run would keep bumping `updated_at`, and `updated_at` is how
#: staleness is measured.
UNRESOLVABLE = (
    "This attempt was abandoned part-way through and cannot be checked automatically — there is "
    "no caption distinctive enough to find it by. Look at the account. If the post is there, "
    "mark this asset published; if it is not, cancel this attempt and queue another."
)


async def _mark_unresolvable(session: AsyncSession, publication: SocialPublication) -> None:
    if publication.error == UNRESOLVABLE:
        return
    publication.error = UNRESOLVABLE
    await session.commit()


async def reclaim(
    session: AsyncSession, settings: Settings, *, now: dt.datetime | None = None
) -> list[SocialPublication]:
    """Resolve rows abandoned mid-publish, by asking Instagram what actually happened.

    **This is the price of committing the claim, and the reason `container_id` is stored.** A
    process that dies between the claim and the answer leaves `publishing` behind; the partial
    unique index then refuses to queue anything else for that asset, forever, and `cancel()`
    rightly will not touch a row that might be mid-flight at Meta.

    So the ambiguity is resolved against the account rather than guessed. Found there → it went
    out, and the row records it. Not found → it did not, and the row fails and frees the asset
    for another attempt. **Never republishes**: a container that was built but never published
    is not a post, and re-sending it here is exactly the duplicate this service is built to
    avoid. A person queues the next attempt.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    rows = await session.execute(
        select(SocialPublication).where(
            SocialPublication.status == "publishing",
            SocialPublication.updated_at < now - STALE_AFTER,
        )
    )
    stalled = list(rows.scalars().all())
    resolved: list[SocialPublication] = []

    for publication in stalled:
        caption = publication.caption or ""

        # **A claim nobody can check is left standing.** A story carries no caption, and a
        # caption whose first line is short cannot identify one post in a feed — so for these
        # there is no question to ask Instagram, and the not-published branch below would be a
        # guess. Failing the row on a guess prints *"queue it again"* under a post that may be
        # live, which is the duplicate this whole service exists to avoid, arriving as advice.
        if not instagram.searchable(caption):
            await _mark_unresolvable(session, publication)
            continue

        try:
            already = await instagram.find_published(settings, caption)
        except RascalError:
            # Instagram is unreachable. Leave the row alone rather than failing a post that
            # may be live — the next run asks again.
            log.warning("could not reclaim", extra={"publication_id": str(publication.id)})
            continue

        if already is not None:
            asset = await _load_asset(session, publication.asset_id)
            resolved.append(
                await _record_success(
                    session,
                    asset,
                    publication,
                    media_id=already.id,
                    permalink=already.permalink,
                    published_at=already.timestamp,
                )
            )
            continue

        container = publication.container_id
        where = f" Its container was {container}." if container else ""
        await _record_failure(
            session,
            publication,
            "This attempt was abandoned part-way through, and the account's most recent posts "
            "do not carry this caption." + where + " Queue it again when you are ready.",
        )
        resolved.append(publication)

    return resolved


async def cancel(session: AsyncSession, publication_id: uuid.UUID) -> SocialPublication:
    """Take a scheduled post out of the queue. Only ever legal before it has gone out."""
    publication = await session.get(SocialPublication, publication_id)
    if publication is None:
        raise not_found("Publication")
    if publication.status == "published":
        raise RascalError(
            ErrorCode.CONFLICT,
            "This already went out — it cannot be cancelled from here. "
            "Delete it in the Instagram app if you need it gone.",
        )
    if publication.status == "publishing":
        # A fresh claim is genuinely mid-flight and cancelling it would be a guess. A stale one
        # is the opposite: nothing is running, `reclaim()` could not settle it, and the person
        # pressing this has the one thing no code here has — they can look at the account. This
        # is the only way out for a claim that cannot be checked automatically, and without it
        # the partial unique index blocks the asset permanently.
        age = dt.datetime.now(tz=dt.UTC) - publication.updated_at
        if age < STALE_AFTER:
            raise RascalError(
                ErrorCode.CONFLICT,
                "This is mid-publish. Wait for it to finish or fail before cancelling.",
            )
    publication.status = "cancelled"
    await session.flush()
    await session.refresh(publication)
    return publication


async def due(session: AsyncSession, *, now: dt.datetime | None = None) -> list[SocialPublication]:
    """Scheduled rows whose time has come, oldest first.

    A NULL `scheduled_for` is due immediately — that is what an immediate publish writes, and
    it means a request that died between queueing and publishing is picked up by the next run
    rather than sitting forever.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    rows = await session.execute(
        select(SocialPublication)
        .where(
            SocialPublication.status == "scheduled",
            (SocialPublication.scheduled_for.is_(None)) | (SocialPublication.scheduled_for <= now),
        )
        .order_by(SocialPublication.scheduled_for.asc().nullsfirst())
    )
    return list(rows.scalars().all())


async def list_publications(
    session: AsyncSession, *, asset_id: uuid.UUID | None = None, limit: int = 60
) -> list[SocialPublication]:
    clauses = [SocialPublication.asset_id == asset_id] if asset_id else []
    rows = await session.execute(
        select(SocialPublication)
        .where(*clauses)
        .order_by(SocialPublication.created_at.desc())
        .limit(limit)
    )
    return list(rows.scalars().all())


def as_dict(publication: SocialPublication) -> dict[str, Any]:
    return {
        "id": str(publication.id),
        "asset_id": str(publication.asset_id),
        "platform": publication.platform,
        "status": publication.status,
        "scheduled_for": (
            publication.scheduled_for.isoformat() if publication.scheduled_for else None
        ),
        "image_key": publication.image_key,
        "caption": publication.caption,
        "alt_text": publication.alt_text,
        "container_id": publication.container_id,
        "media_id": publication.media_id,
        "permalink": publication.permalink,
        "error": publication.error,
        "attempts": publication.attempts,
        "published_at": (
            publication.published_at.isoformat() if publication.published_at else None
        ),
        "created_at": publication.created_at.isoformat(),
        "updated_at": publication.updated_at.isoformat(),
    }
