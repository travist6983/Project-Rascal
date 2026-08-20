"""What every cost provider returns, and the rules they all follow.

The panel talks to five services that agree on nothing — different auth, different units,
different ideas of what a "period" is, and in two cases no dollar figure at all. This module
is the one shape they are flattened into, and the three rules that keep the screen honest:

1. **A provider that is not configured is a first-class state, not an error.** It reports
   `unconfigured` with the name of the environment variable and where the key comes from, so
   the card is a to-do rather than a blank.
2. **A provider that has no billing API says so.** Fly and Tigris do not expose spend, and
   the card shows what they *do* expose — machines, bytes — rather than a plausible number
   nobody can reconcile against an invoice. A costs page that quietly invents figures is
   worse than one that admits a gap.
3. **Money is integer cents.** Every provider is converted at its own edge, because that is
   where the unit is known. Anthropic's cost report already speaks cents, and it speaks them
   as a *decimal string* (`"123.45"` is $1.23, not $123.45) — a float would round that, and
   rounding money in the layer that displays it is how a dashboard drifts from an invoice.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

log = logging.getLogger("rascal.billing")

ProviderStatus = Literal["ok", "unconfigured", "error"]


@dataclass(frozen=True)
class Metric:
    """One labelled number on a provider card.

    `value` is a string because these are already formatted for a human — "4.2 GB",
    "3 machines", "1,204 contacts". Formatting at the edge keeps unit knowledge where the
    unit is known, and keeps the browser from having to learn five vendors' conventions.
    """

    label: str
    value: str
    #: Optional second line, for the thing a number does not say on its own — a region, a
    #: state, a warning that a machine is pinned to a stale image.
    detail: str | None = None
    #: `ok`, `warn`, or `bad`. Drives one dot on the card and nothing else.
    tone: Literal["ok", "warn", "bad", "plain"] = "plain"


@dataclass(frozen=True)
class SeriesPoint:
    day: dt.date
    cents: int


@dataclass(frozen=True)
class ProviderReport:
    key: str
    label: str
    status: ProviderStatus
    #: What the console tells the owner to do about an `unconfigured` or `error` card. On an
    #: error this is the provider's own message, trimmed; never a stack trace.
    detail: str | None = None
    #: The environment variable(s) to set and where the value comes from. Present on every
    #: `unconfigured` card, because "not configured" without that sentence is a dead end.
    setup: str | None = None
    #: Total spend over `period_label`, in integer cents. `None` means this provider does not
    #: expose spend — which is a fact about the vendor, not a failure, and the card says so.
    amount_cents: int | None = None
    currency: str = "USD"
    period_label: str | None = None
    metrics: tuple[Metric, ...] = ()
    series: tuple[SeriesPoint, ...] = ()
    #: Where to go and look at the real invoice.
    console_url: str | None = None

    def as_dict(self) -> dict[str, object]:
        return {
            "key": self.key,
            "label": self.label,
            "status": self.status,
            "detail": self.detail,
            "setup": self.setup,
            "amount_cents": self.amount_cents,
            "currency": self.currency,
            "period_label": self.period_label,
            "console_url": self.console_url,
            "metrics": [
                {"label": m.label, "value": m.value, "detail": m.detail, "tone": m.tone}
                for m in self.metrics
            ],
            "series": [{"day": p.day.isoformat(), "cents": p.cents} for p in self.series],
        }


def unconfigured(
    key: str, label: str, setup: str, console_url: str | None = None
) -> ProviderReport:
    return ProviderReport(
        key=key,
        label=label,
        status="unconfigured",
        detail="Not connected yet.",
        setup=setup,
        console_url=console_url,
    )


def cents_from_decimal_string(raw: str) -> int:
    """Anthropic's cost report speaks cents as a decimal string. Keep it exact.

    `"123.78912"` is 123.78912 cents — a shade over a dollar. Summing these as floats and
    rounding at the end is fine to the penny for one row and not fine across a month of them,
    so the addition happens in `Decimal` and the rounding happens once, at the top.
    """
    return int(Decimal(raw))


#: A tiny in-process TTL cache. Deliberately not Postgres-backed, unlike `services/rate_limit`:
#: that one is a correctness guarantee across machines, this one is politeness toward somebody
#: else's rate limiter. Two Fly machines holding two slightly different caches is invisible.
_CACHE: dict[str, tuple[float, ProviderReport]] = {}


async def cached(
    key: str,
    ttl_seconds: int,
    build: Callable[[], Awaitable[ProviderReport]],
) -> ProviderReport:
    now = time.monotonic()
    hit = _CACHE.get(key)
    if hit is not None and now - hit[0] < ttl_seconds:
        return hit[1]
    report = await build()
    # An error is cached too, and for a shorter time than a success would deserve — the point
    # is that a provider that is down must not be retried on every render of the page.
    _CACHE[key] = (now, report)
    return report


def clear_cache() -> None:
    """For the tests, and for the console's own refresh button."""
    _CACHE.clear()


async def gather_reports(
    builders: dict[str, Callable[[], Awaitable[ProviderReport]]],
    labels: dict[str, str],
) -> list[ProviderReport]:
    """Run every provider concurrently and let none of them take the page down.

    `return_exceptions=True` rather than a try/except inside each provider: the providers are
    written to return an `error` report for anything they can anticipate, and this is the net
    under the thing none of them thought of. A timeout in one vendor's API must not blank the
    other four cards.
    """
    keys = list(builders)
    results = await asyncio.gather(*(builders[k]() for k in keys), return_exceptions=True)
    reports: list[ProviderReport] = []
    for key, result in zip(keys, results, strict=True):
        if isinstance(result, ProviderReport):
            reports.append(result)
            continue
        log.warning("billing provider failed", extra={"provider": key, "error": repr(result)})
        reports.append(
            ProviderReport(
                key=key,
                label=labels.get(key, key),
                status="error",
                detail=_safe_message(result),
            )
        )
    return reports


def _safe_message(error: BaseException | object) -> str:
    """A sentence, never a stack trace and never a URL with a token in it.

    Provider errors are the one place a credential can leak into a response body: an httpx
    `RequestError` stringifies to the URL it was fetching, and several of these APIs take
    their key in the query string on some endpoints. Truncating to the exception type plus a
    short message keeps that out of the browser.
    """
    if isinstance(error, TimeoutError | asyncio.TimeoutError):
        return "The provider did not answer in time."
    text = str(error).strip() or type(error).__name__
    return text[:200]


__all__ = [
    "Metric",
    "ProviderReport",
    "ProviderStatus",
    "SeriesPoint",
    "cached",
    "cents_from_decimal_string",
    "clear_cache",
    "gather_reports",
    "unconfigured",
]
