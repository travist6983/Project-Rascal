"""Rate limiting for unauthenticated endpoints. Postgres-backed, fixed window.

**This is the one place `CLAUDE.md`'s "rate limiting is out of scope" no longer holds**, and
the exception is narrow and written down: unauthenticated endpoints, where it is required.
Everything behind a bearer token is still out of scope — a signed-in parent hammering their own
archive is a support conversation, not an attack.

**Postgres rather than in-memory, because there is more than one Fly machine.** An in-process
counter would be a limit N times looser than it reads, resetting on every deploy, and it would
look like it worked in every test. **Per-email is the limit that matters**: the abuse is
spamming links at one address, and an edge limiter cannot see the address because it is inside
the request body — which is exactly why this lives in the app rather than at Cloudflare.

A fixed window rather than a sliding one or a token bucket. The failure a fixed window permits
is a burst across a boundary — up to twice the limit in one instant — and against "how many emails
can one address be sent in an hour" that is a rounding error, not a hole.
"""

from __future__ import annotations

import datetime as dt
import logging

from fastapi import Request
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.errors import ErrorCode, RascalError
from rascal.models import RateLimitEvent

log = logging.getLogger("rascal.rate_limit")

#: Fly's proxy sets this to the real client address and **strips any client-supplied copy**,
#: which is what makes it trustworthy where a raw `X-Forwarded-For` is not.
FLY_CLIENT_IP_HEADER = "Fly-Client-IP"


def client_address(request: Request) -> str:
    """The address to rate-limit on, as seen from behind a proxy.

    **`request.client.host` is the wrong answer in production and dangerously so.** Behind
    Fly's proxy it is the *proxy's* address, identical for every request on the planet — so a
    per-IP limit built on it is one shared bucket, and twenty requests an hour from anywhere
    would lock every parent out of magic-link sign-in. That is a denial of service against the
    people this is supposed to protect, delivered by the protection itself.

    `Fly-Client-IP` is used because Fly sets it and strips a client-supplied copy. A raw
    `X-Forwarded-For` is deliberately **not** trusted: a caller can send whatever they like in
    it, which would mint a fresh bucket per request and remove the limit entirely — the exact
    opposite failure, and the quieter one.

    Falling back to the socket peer keeps local development and the test suite working, where
    there is no proxy and the peer really is the client.
    """
    forwarded = request.headers.get(FLY_CLIENT_IP_HEADER)
    if forwarded:
        return forwarded.strip()
    return request.client.host if request.client else "unknown"


def email_bucket(email: str) -> str:
    return f"email:{email.strip().lower()}"


def ip_bucket(address: str) -> str:
    return f"ip:{address}"


async def check_and_record(
    session: AsyncSession,
    bucket: str,
    *,
    limit: int,
    window: dt.timedelta,
    now: dt.datetime | None = None,
) -> None:
    """Count this bucket's recent attempts, refuse if over, otherwise record one.

    Raises `RascalError(RATE_LIMITED)` — 429 — when the window is full. Nothing is recorded on
    a refusal, so a caller being refused cannot extend their own lockout by retrying.
    """
    moment = now or dt.datetime.now(tz=dt.UTC)
    since = moment - window

    # Prune this bucket's expired rows while we are here. It keeps the table proportional to
    # live traffic without a scheduled job, and the index makes it the same scan as the count.
    await session.execute(
        delete(RateLimitEvent).where(
            RateLimitEvent.bucket == bucket, RateLimitEvent.created_at < since
        )
    )

    # **Record first, then count — the order is the whole correctness argument.**
    #
    # Counting first and inserting after is a check-then-act: N concurrent requests all read
    # the same count, all see room, and all proceed, so the limit is only enforced against
    # traffic that happens to be serialised. Under exactly the burst a limiter exists to stop,
    # it stops nothing.
    #
    # Inserting first makes this request visible to its own count, so concurrent callers each
    # see at least their own row. Losing a race now costs one caller a refusal they could have
    # been allowed — the safe direction for an endpoint that sends mail to a stranger.
    session.add(RateLimitEvent(bucket=bucket, created_at=moment))
    await session.flush()

    used = await session.scalar(
        select(func.count())
        .select_from(RateLimitEvent)
        .where(RateLimitEvent.bucket == bucket, RateLimitEvent.created_at >= since)
    )
    if (used or 0) > limit:
        log.warning("rate limit hit", extra={"bucket": bucket.split(":", 1)[0]})
        raise RascalError(
            ErrorCode.RATE_LIMITED,
            "Too many requests. Try again in a little while.",
        )
