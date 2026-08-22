"""Publishing a card to Instagram. The only thing in this service that reaches the public.

**How Instagram publishing works, because the shape of this module follows from it.** The API
does not accept an image upload. You hand Meta a **public HTTPS URL**, Meta's own servers fetch
the image, and you then publish the container it built. So there are always two calls with a
gap between them, and everything careful in here is about that gap.

Verified against the live account on Aug 20, 2026: **a presigned S3 URL works**, query string
and all. That matters more than it sounds. The alternative was making a bucket prefix
world-readable, and this service's whole storage posture is that nothing is public and every
byte is reached through a signed URL with a TTL. Meta does not care about the `X-Amz-*`
parameters; the container went `IN_PROGRESS` then `FINISHED` in about three seconds.

**JPEG only.** Meta's content-publishing documentation is blunt about it, and a PNG does not
fail helpfully — it comes back as a container in `ERROR` rather than as a message naming the
format. The console encodes the canvas as JPEG for exactly this reason.

**The account is shared with the marketing repository.** One feed, two publishers, no shared
database — so spacing and the daily count are read from Instagram rather than from
`social_publications`. A limit computed from our own rows is a limit that cannot see half of
what is on the account. That is not a hypothetical: the marketing watcher posts hourly, and on
the night this was written four of the six posts on the account went out in four hours.

**Errors from Meta arrive as HTTP 400 with a JSON body far more useful than the status code**,
so the body is what gets read — and then reduced to one sentence before it leaves this module.
The console never sees a raw provider payload, and the token never appears in a message.

One inherited warning, from the session that runs the marketing poster: when Meta cannot fetch
the image URL it answers `OAuthException 9004: Only photo or video can be accepted as media
type`, which names neither the URL nor the real problem. If a publish fails with something
about media type, suspect the URL first.
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass
from typing import Any

import anyio
import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.social.instagram")

#: Meta answers within a second or two; this is the ceiling on a hung connection rather than an
#: expectation. Publishing is a foreground request in the console, so it cannot be generous.
_TIMEOUT = httpx.Timeout(30.0)

#: How long to wait for Meta to fetch the image and build a container. An image is usually
#: `FINISHED` on the first or second look; a story or a slow bucket can take longer.
_CONTAINER_ATTEMPTS = 12
_CONTAINER_DELAY_SECONDS = 2.5


class NotSearchable(RascalError):
    """The account cannot be asked whether this post is already up.

    A type rather than a `None`, because *"we looked and it is not there"* and *"we could not
    look"* lead to opposite actions and are indistinguishable as return values. Failing a row
    on the second one tells a person to queue a duplicate of something that may be live.
    """

    def __init__(self, message: str) -> None:
        super().__init__(ErrorCode.PUBLISH_FAILED, message)


@dataclass(frozen=True)
class Account:
    """Which account the credentials actually control."""

    id: str
    username: str
    media_count: int
    account_type: str


@dataclass(frozen=True)
class Media:
    """One post already on the account."""

    id: str
    timestamp: dt.datetime
    permalink: str | None
    caption: str


@dataclass(frozen=True)
class Spacing:
    """What the account itself says about whether now is a reasonable time to post.

    Read from Instagram rather than from our own table, because the marketing repository posts
    to this same account and its rows are not in our database. `blocked_reason` is a sentence
    for a person, not a code — the console shows it beside the button.
    """

    last_post_at: dt.datetime | None
    posts_in_last_24h: int
    blocked_reason: str | None

    @property
    def clear(self) -> bool:
        return self.blocked_reason is None


def configured(settings: Settings) -> bool:
    """Are there credentials at all? Separate from whether publishing is switched on."""
    return bool(settings.ig_user_id and settings.ig_access_token)


def _require(settings: Settings) -> tuple[str, str]:
    if not configured(settings):
        missing = " and ".join(
            name
            for name, value in (
                ("IG_USER_ID", settings.ig_user_id),
                ("IG_ACCESS_TOKEN", settings.ig_access_token),
            )
            if not value
        )
        raise RascalError(
            ErrorCode.PUBLISH_FAILED,
            f"Instagram is not configured — {missing} is not set.",
        )
    assert settings.ig_user_id and settings.ig_access_token  # narrowed by `configured`
    return settings.ig_user_id, settings.ig_access_token


def _detail(payload: Any, fallback: str, token: str) -> str:
    """Meta's error, as one sentence, with nothing in it we would not show a person.

    The token is redacted rather than assumed absent. It travels in a header now, so Meta has
    no obvious reason to echo it — but this string is rendered in a console, logged, and pasted
    into messages, and *"it should not be in there"* is not a property worth betting a
    credential on.
    """
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            code = error.get("code")
            message = str(error.get("message") or fallback)
            detail = f"{message} (Instagram error {code})" if code is not None else message
            return detail.replace(token, "<redacted>") if token else detail
    return fallback


async def _call(
    settings: Settings,
    path: str,
    params: dict[str, str],
    *,
    method: str = "POST",
    client: httpx.AsyncClient | None = None,
) -> dict[str, Any]:
    """One Graph call.

    **The token goes in an `Authorization: Bearer` header, never in the query string**, and
    that is not a style preference. Meta's own examples put `access_token=` in the URL and it
    works — but httpx logs the full request URL at INFO, so the first `--account` run written
    that way printed a live 185-character access token into the structured log three times.
    Logs go to Fly, to a terminal, into a paste, into a screenshot. A credential in a URL is a
    credential one careless log line from being public, and the header costs nothing.

    Verified against the live account on Aug 20, 2026: bearer auth answers 200 on this host.
    """
    _, token = _require(settings)
    url = f"{settings.ig_api_host.rstrip('/')}/{settings.ig_api_version}/{path}"
    headers = {"Authorization": f"Bearer {token}"}

    async def _send(http: httpx.AsyncClient) -> httpx.Response:
        if method == "POST":
            return await http.post(url, data=params, headers=headers)
        return await http.get(url, params=params, headers=headers)

    try:
        if client is not None:
            response = await _send(client)
        else:
            async with httpx.AsyncClient(timeout=_TIMEOUT) as owned:
                response = await _send(owned)
    except httpx.HTTPError as exc:
        # httpx reports a dead network and a wrong hostname identically unless you look at the
        # class, and "request failed" on its own has cost this project time before.
        raise RascalError(
            ErrorCode.PUBLISH_FAILED,
            f"Could not reach Instagram ({type(exc).__name__}).",
        ) from exc

    try:
        body = response.json()
    except ValueError:
        body = None

    if response.is_error:
        detail = _detail(body, f"Instagram returned HTTP {response.status_code}.", token)
        log.warning("instagram call failed", extra={"path": path, "status": response.status_code})
        raise RascalError(ErrorCode.PUBLISH_FAILED, detail)

    return body if isinstance(body, dict) else {}


def _parse_timestamp(value: str) -> dt.datetime:
    """Graph sends `2026-08-20T21:29:18+0000` — an offset with no colon, which nothing else in
    this codebase emits.

    Python 3.12's `fromisoformat` parses it perfectly well; an earlier version of this docstring
    claimed otherwise and was wrong. The explicit format is tried first because it is the shape
    Meta actually documents, and `fromisoformat` is the fallback for anything else they send.
    Either way exactly one shape leaves this module."""
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return dt.datetime.fromisoformat(value)


async def account(settings: Settings) -> Account:
    """Which account is this, and how much is on it?

    **"The call succeeded" and "there is a post on the account you are looking at" are
    different claims**, and for a while only the first was checkable in the marketing pipeline.
    A publish that returns a media id succeeded *somewhere*. This is how the console shows the
    handle next to the button, so nobody has to trust that the id in a secret is the account
    they think it is.
    """
    user_id, _ = _require(settings)
    body = await _call(
        settings, user_id, {"fields": "username,media_count,account_type"}, method="GET"
    )
    return Account(
        id=str(body.get("id", user_id)),
        username=str(body.get("username", "")),
        media_count=int(body.get("media_count", 0)),
        account_type=str(body.get("account_type", "")),
    )


async def recent_media(settings: Settings, limit: int = 25) -> list[Media]:
    """The account's most recent posts, newest first — whoever published them."""
    user_id, _ = _require(settings)
    body = await _call(
        settings,
        f"{user_id}/media",
        {"fields": "id,caption,timestamp,permalink", "limit": str(limit)},
        method="GET",
    )
    media: list[Media] = []
    for item in body.get("data") or []:
        try:
            timestamp = _parse_timestamp(str(item["timestamp"]))
        except (KeyError, ValueError):
            continue
        media.append(
            Media(
                id=str(item.get("id", "")),
                timestamp=timestamp,
                permalink=item.get("permalink"),
                caption=str(item.get("caption") or ""),
            )
        )
    return media


async def spacing(settings: Settings, *, now: dt.datetime | None = None) -> Spacing:
    """Is the account ready for another post, according to the account?

    Two limits, both measured from Instagram. The gap keeps the feed reading as something
    written rather than as a queue being drained — and it is the only thing standing between
    two publishers that cannot see each other and two posts a minute apart. The daily count is
    Meta's own ceiling; hitting it is an API error rather than a silent failure, but arriving
    at it having published 99 things nobody meant to is the part worth preventing.
    """
    now = now or dt.datetime.now(dt.UTC)
    # **Ask for as many as the limit we are checking against.** This asked for 50 while
    # comparing the answer to a limit of 100, so the daily guard could not fire however many
    # posts went out — a check that is arithmetically incapable of failing is worse than none,
    # because it reads like cover. 100 is Meta's page ceiling; this deliberately does not
    # paginate, so with a limit above that the guard becomes best-effort and Instagram's own
    # 429 is the real backstop.
    media = await recent_media(settings, limit=min(settings.social_daily_post_limit, 100))
    day_ago = now - dt.timedelta(hours=24)
    in_last_day = sum(1 for item in media if item.timestamp >= day_ago)
    last_post_at = media[0].timestamp if media else None

    reason: str | None = None
    if in_last_day >= settings.social_daily_post_limit:
        reason = (
            f"{in_last_day} posts have gone out in the last 24 hours, which is Instagram's "
            f"limit of {settings.social_daily_post_limit}."
        )
    elif last_post_at is not None:
        gap = dt.timedelta(minutes=settings.social_min_gap_minutes)
        elapsed = now - last_post_at
        if elapsed < gap:
            wait = int((gap - elapsed).total_seconds() // 60) + 1
            reason = (
                f"The last post on the account went out "
                f"{int(elapsed.total_seconds() // 60)} minutes ago — it may not have been "
                f"ours. Posting again in about {wait} minutes keeps them roughly an hour apart."
            )
    return Spacing(last_post_at=last_post_at, posts_in_last_24h=in_last_day, blocked_reason=reason)


#: A caption's first line has to be long enough to identify one post among a feed. Below this
#: it is not distinctive prose, it is a coincidence waiting to happen.
MIN_MATCHABLE_CAPTION = 25


def searchable(caption: str) -> bool:
    """Can this caption be matched against a feed at all?

    **Callers must ask before trusting a negative answer from `find_published`.** A caption
    with a short first line — a one-word hook, a headline under twenty-five characters — cannot
    be matched, and "cannot be matched" is not "is not there". Conflating them is how a
    not-published conclusion gets drawn about a post that is live.
    """
    return len(first_line(caption)) >= MIN_MATCHABLE_CAPTION


def first_line(caption: str) -> str:
    return (caption or "").strip().split("\n")[0].strip()


async def find_published(settings: Settings, caption: str) -> Media | None:
    """Is this already on the account, whatever our own table believes?

    **The publish-then-record gap is the only unrecoverable failure here.** Meta returns a media
    id, the row does not get written, and the next attempt posts the same card again — a
    duplicate on a public feed, which strangers see and nothing on our side can undo. So the
    question gets asked of Instagram rather than of the database.

    Matched on the caption's first line, which is distinctive prose rather than a template.
    **This is the only guard there is**, and an earlier version of this docstring said otherwise
    — that it was *"the second line of defence, not the first: the first is that a publish and
    its row are written in one transaction"*. That was false when it was written.
    `publish_container` is a network call and the row is committed after it returns; there is no
    transaction around
    the pair and there cannot be. The false claim mattered because it made the short-caption
    case below look harmless, as a gap behind a guarantee, when it is a gap behind nothing.

    `None` means **searched and absent**. A caption that cannot be searched raises rather than
    returning `None`, because those two answers lead to opposite actions and the type does not
    distinguish them.
    """
    if not searchable(caption):
        raise NotSearchable(
            "This caption's first line is too short to identify a post in a feed, so whether "
            "it is already on the account cannot be answered from here."
        )
    line = first_line(caption)
    for item in await recent_media(settings, limit=25):
        if item.caption.strip().startswith(line):
            return item
    return None


async def create_container(
    settings: Settings,
    *,
    image_url: str,
    caption: str,
    alt_text: str | None,
    story: bool = False,
) -> str:
    """Ask Meta to fetch the image and hold it. **This does not publish anything.**

    A container is a staged post. It expires on its own in 24 hours if it is never published,
    which is what makes it safe to build one in order to find out whether an image URL is
    reachable.

    Stories take no caption and no alt text — there is nowhere on a story for either to appear,
    and sending them is how you end up believing a caption went out when it did not.
    """
    user_id, _ = _require(settings)
    params: dict[str, str] = {"image_url": image_url}
    if story:
        params["media_type"] = "STORIES"
    else:
        params["caption"] = caption
        if alt_text:
            params["alt_text"] = alt_text

    body = await _call(settings, f"{user_id}/media", params)
    container_id = body.get("id")
    if not container_id:
        raise RascalError(
            ErrorCode.PUBLISH_FAILED, "Instagram accepted the image but returned no container."
        )
    return str(container_id)


async def wait_for_container(settings: Settings, container_id: str) -> None:
    """Block until Meta has fetched the image, or say why it could not.

    Publishing an `IN_PROGRESS` container is an error, and `ERROR` carries the reason the fetch
    failed — which is the single most likely thing to go wrong on any given run, because it
    covers every way a URL can stop being reachable.
    """
    # One client for the whole loop. Every other call here is a one-shot and opens its own, the
    # way `renderers.py` does; this is the only place that would otherwise pay for twelve TLS
    # handshakes to say one thing.
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        for _ in range(_CONTAINER_ATTEMPTS):
            body = await _call(
                settings,
                container_id,
                {"fields": "status_code,status"},
                method="GET",
                client=client,
            )
            code = body.get("status_code")
            if code == "FINISHED":
                return
            if code in ("ERROR", "EXPIRED"):
                raise RascalError(
                    ErrorCode.PUBLISH_FAILED,
                    f"Instagram could not use the image — {body.get('status') or code}. "
                    "The usual cause is an image URL it could not fetch.",
                )
            await anyio.sleep(_CONTAINER_DELAY_SECONDS)

    raise RascalError(
        ErrorCode.PUBLISH_FAILED,
        "Instagram was still preparing the image after "
        f"{int(_CONTAINER_ATTEMPTS * _CONTAINER_DELAY_SECONDS)} seconds. "
        "Nothing was published; the post can be tried again.",
    )


async def publish_container(settings: Settings, container_id: str) -> str:
    """**The irreversible call.** Returns the media id of a post that is now public."""
    user_id, _ = _require(settings)
    body = await _call(settings, f"{user_id}/media_publish", {"creation_id": container_id})
    media_id = body.get("id")
    if not media_id:
        # Meta answered 200 without an id. Whether a post exists is now genuinely unknown, and
        # saying so is more useful than either optimistic answer.
        raise RascalError(
            ErrorCode.PUBLISH_FAILED,
            "Instagram accepted the publish but returned no media id. "
            "Check the account before trying again — the post may have gone out.",
        )
    return str(media_id)


async def permalink_for(settings: Settings, media_id: str) -> str | None:
    """The public URL of a post. Best-effort: a missing permalink is not a failed publish."""
    try:
        body = await _call(settings, media_id, {"fields": "permalink"}, method="GET")
    except RascalError:
        log.warning("could not read permalink", extra={"media_id": media_id})
        return None
    permalink = body.get("permalink")
    return str(permalink) if permalink else None
