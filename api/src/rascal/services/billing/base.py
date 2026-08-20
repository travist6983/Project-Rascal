"""What every cost provider returns, and the rules they all follow.

The panel talks to seven services that agree on nothing — different auth, different units,
different ideas of what a "period" is, and in three cases no dollar figure at all. This module
is the one shape they are flattened into, and the four rules that keep the screen honest:

1. **A provider that is not configured is a first-class state, not an error.** It reports
   `unconfigured` with the name of the environment variable and where the key comes from, so
   the card is a to-do rather than a blank.
2. **A provider that has no billing API says so.** Five of the seven do not expose spend, and
   their cards show what they *do* expose — machines, bytes, contacts — rather than a
   plausible number nobody can reconcile against an invoice. A costs page that quietly invents
   figures is worse than one that admits a gap. The one escape hatch is an estimate derived
   from a price somebody typed into the environment on purpose, and such a card names the
   setting it came from in its `detail`.
3. **Money is integer cents.** Every provider is converted at its own edge, because that is
   where the unit is known, and the two vendors that report money report it in opposite
   units: Anthropic's cost report speaks cents as a *decimal string* (`"123.45"` is $1.23),
   and GitHub's speaks dollars as a JSON number. Both go through `format.cents_from_decimal`,
   which is the one place rounding happens — a float would round early, and rounding money in
   the layer that displays it is how a dashboard drifts from an invoice.
4. **A series is not always money.** `SeriesPoint` carries `cents` or a raw `value`, and
   `ProviderReport.series_unit` says which. Neon has a daily history and no dollars; pricing
   it into cents to fit the old shape would have broken rule 2 to satisfy a dataclass.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Literal

log = logging.getLogger("rascal.billing")

ProviderStatus = Literal["ok", "unconfigured", "error"]


@dataclass(frozen=True)
class Metric:
    """One labelled number on a provider card.

    `value` is a string because these are already formatted for a human — "4.2 GB",
    "3 machines", "1,204 contacts". Formatting at the edge keeps unit knowledge where the
    unit is known, and keeps the browser from having to learn seven vendors' conventions.
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
    """One day on a provider's chart, which is not always a day of spending.

    `cents` was the only field while Anthropic was the only vendor with a series. Neon has a
    daily consumption history and no dollars anywhere in its API, so the choice was to price
    CU-hours into cents from a configured rate or to let a point carry its own unit. The rate
    would have been plan-dependent, compute-only, and wrong by a factor of two on the wrong
    plan — see `decisions-log.md`. So a point carries money when the vendor reports money and
    a raw quantity when it does not, and `ProviderReport.series_unit` says which.
    """

    day: dt.date
    #: Money, when the vendor reports money. `None` when it does not, which is the majority.
    cents: int | None = None
    #: The raw quantity, in `ProviderReport.series_unit`. Filled when `cents` is `None`.
    value: float | None = None


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
    #: What the chart is a chart *of*. `None` with an empty series, and required with a
    #: non-empty one: an unlabelled axis on a costs page reads as dollars by default, which is
    #: exactly the misreading a CU-hour series would invite.
    series_label: str | None = None
    #: `"cents"` when the points carry money, otherwise the vendor's own unit — `"CU-hours"`.
    #: The browser formats from this rather than guessing, for the same reason `Metric.value`
    #: arrives pre-formatted: the unit is known at the edge and nowhere else.
    series_unit: str | None = None
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
            "series_label": self.series_label,
            "series_unit": self.series_unit,
            "metrics": [
                {"label": m.label, "value": m.value, "detail": m.detail, "tone": m.tone}
                for m in self.metrics
            ],
            "series": [
                {"day": p.day.isoformat(), "cents": p.cents, "value": p.value} for p in self.series
            ],
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
    other six cards.
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
    "clear_cache",
    "gather_reports",
    "unconfigured",
]
