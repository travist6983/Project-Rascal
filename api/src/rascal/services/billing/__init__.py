"""Seven vendors, each read the only way it can be read.

`GET /v1/admin/costs` is the one caller. Everything here is read-only, cached briefly, and runs
concurrently: seven sequential calls to seven vendors is a page that takes eight seconds to
paint, and one slow vendor should not be able to do that to the other six.

| Vendor    | Exposes spend?    | Credential                          | What the card carries      |
|-----------|-------------------|-------------------------------------|----------------------------|
| Anthropic | **Yes**           | `ANTHROPIC_ADMIN_KEY`               | Daily cost, tokens, models |
| GitHub    | **Yes**           | `GITHUB_BILLING_TOKEN` (Plan: read) | Actions spend and minutes  |
| Tigris    | Estimate only     | The S3 keys media already uses      | Objects, bytes, lifecycle  |
| Apple     | Static price only | none — `APPLE_MEMBERSHIP_CENTS…`    | The membership, amortised  |
| Neon      | No                | `NEON_API_KEY` + project + org      | Storage, compute, CU-hours |
| Fly       | No                | `FLY_API_TOKEN`                     | Machines, guests, volumes  |
| Resend    | No                | `MAIL_API_KEY` (already set)        | Audience, domains          |

**Two of the seven publish a real cost API and five do not**, and that split is the honest
shape of this screen rather than a gap to be filled in later with estimates. Anthropic and
GitHub return money the vendor itself computed. Tigris and Apple carry a figure only because a
price was typed into the environment on purpose, and both cards name the setting it came from.
Neon, Fly and Resend carry no figure at all, because inventing one is how a dashboard stops
matching an invoice.

**One module per vendor, since phase 100.** This was one file while four of the five were a
single HTTP call and a shape conversion, and that argument stopped being true when Anthropic
became two concurrent calls plus pagination, Fly and Neon became two calls each, Tigris became
three, and Apple became a provider that makes none at all. `config.py` had already been
pointing readers at a `services/billing/fly.py` that did not exist.
"""

from __future__ import annotations

import httpx

from rascal.config import Settings
from rascal.services.billing.anthropic import anthropic_report
from rascal.services.billing.apple import apple_report
from rascal.services.billing.base import (
    Metric,
    ProviderReport,
    SeriesPoint,
    cached,
    clear_cache,
    gather_reports,
    unconfigured,
)
from rascal.services.billing.fly import fly_report
from rascal.services.billing.format import LABELS
from rascal.services.billing.github import github_report
from rascal.services.billing.neon import neon_report
from rascal.services.billing.resend import resend_report
from rascal.services.billing.tigris import tigris_report


async def collect(
    settings: Settings, client: httpx.AsyncClient | None = None
) -> list[ProviderReport]:
    """Every provider, concurrently, each behind its own cache entry.

    One `AsyncClient` for the whole fan-out rather than one per provider: a client is a
    connection pool, and building seven of them per request is the "per-request client
    construction" cost this codebase avoids everywhere else. It is built per *call* rather than
    per process because this route is rare — a handful of requests a day from one browser — and
    a module-level client would hold sockets open against six vendors for the life of the
    machine to serve it.

    `client` is injectable so tests can drive the whole seven-card contract through a
    `MockTransport` with real vendor payloads. The route does not pass one.

    The cache key includes nothing user-specific because none of this is user-specific: it is
    the same organisation's bill however many admins look at it.
    """
    ttl = settings.billing_cache_seconds
    timeout = httpx.Timeout(settings.billing_timeout_seconds)
    if client is not None:
        return await _gather(client, settings, ttl)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as owned:
        return await _gather(owned, settings, ttl)


async def _gather(client: httpx.AsyncClient, settings: Settings, ttl: int) -> list[ProviderReport]:
    return await gather_reports(
        {
            "anthropic": lambda: cached(
                "anthropic", ttl, lambda: anthropic_report(client, settings)
            ),
            "github": lambda: cached("github", ttl, lambda: github_report(client, settings)),
            "fly": lambda: cached("fly", ttl, lambda: fly_report(client, settings)),
            "neon": lambda: cached("neon", ttl, lambda: neon_report(client, settings)),
            "tigris": lambda: cached("tigris", ttl, lambda: tigris_report(settings)),
            "resend": lambda: cached("resend", ttl, lambda: resend_report(client, settings)),
            "apple": lambda: cached("apple", ttl, lambda: apple_report(settings)),
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
