"""What the business is spending, gathered from five vendors that agree on nothing.

`GET /v1/admin/costs` is the one caller. Everything here is read-only, cached briefly, and
runs concurrently: five sequential HTTP calls to five vendors is a page that takes six
seconds to paint, and one slow vendor should not be able to do that to the other four.
"""

from __future__ import annotations

import httpx

from rascal.config import Settings
from rascal.services.billing.base import (
    Metric,
    ProviderReport,
    SeriesPoint,
    cached,
    clear_cache,
    gather_reports,
    unconfigured,
)
from rascal.services.billing.providers import (
    LABELS,
    anthropic_report,
    fly_report,
    neon_report,
    resend_report,
    tigris_report,
)


async def collect(settings: Settings) -> list[ProviderReport]:
    """Every provider, concurrently, each behind its own cache entry.

    One `AsyncClient` for the whole fan-out rather than one per provider: a client is a
    connection pool, and building five of them per request is the "per-request client
    construction" cost this codebase avoids everywhere else. It is built per *call* rather
    than per process because this route is rare — a handful of requests a day from one
    browser — and a module-level client would hold sockets open against five vendors for the
    life of the machine to serve it.

    The cache key includes nothing user-specific because none of this is user-specific: it is
    the same organisation's bill however many admins look at it.
    """
    ttl = settings.billing_cache_seconds
    timeout = httpx.Timeout(settings.billing_timeout_seconds)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
        return await gather_reports(
            {
                "anthropic": lambda: cached(
                    "anthropic", ttl, lambda: anthropic_report(client, settings)
                ),
                "fly": lambda: cached("fly", ttl, lambda: fly_report(client, settings)),
                "neon": lambda: cached("neon", ttl, lambda: neon_report(client, settings)),
                "tigris": lambda: cached("tigris", ttl, lambda: tigris_report(settings)),
                "resend": lambda: cached("resend", ttl, lambda: resend_report(client, settings)),
            },
            LABELS,
        )


__all__ = [
    "LABELS",
    "Metric",
    "ProviderReport",
    "SeriesPoint",
    "clear_cache",
    "collect",
    "unconfigured",
]
