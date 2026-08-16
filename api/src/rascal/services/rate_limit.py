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

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.errors import ErrorCode, RascalError
from rascal.models import RateLimitEvent

log = logging.getLogger("rascal.rate_limit")


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

    used = await session.scalar(
        select(func.count())
        .select_from(RateLimitEvent)
        .where(RateLimitEvent.bucket == bucket, RateLimitEvent.created_at >= since)
    )
    if (used or 0) >= limit:
        log.warning("rate limit hit", extra={"bucket": bucket.split(":", 1)[0]})
        raise RascalError(
            ErrorCode.RATE_LIMITED,
            "Too many requests. Try again in a little while.",
        )

    session.add(RateLimitEvent(bucket=bucket, created_at=moment))
    await session.flush()
