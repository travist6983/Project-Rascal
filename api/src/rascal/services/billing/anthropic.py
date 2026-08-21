"""Cost and usage, from the Admin API — the only vendor here that reports both.

Two calls, run concurrently, and the second one is not allowed to take down the first: the
dollar figure is this card's job and the token counts are decoration on it.

Three things about this API are easy to get wrong and are handled explicitly:

**It needs an *admin* key.** `sk-ant-admin…`, minted under Settings → Admin keys. An ordinary
`sk-ant-api…` key — the kind every other integration uses — is refused, and the refusal reads
like a permissions bug rather than a wrong-kind-of-key bug. **Admin keys do not exist on
individual accounts at all**, which is a wall rather than a setting, so the unconfigured copy
says so instead of sending somebody to look for a Console section that is not there.

**`amount` is cents, as a decimal string.** `"123.45"` in USD is $1.23, not $123.45. Reading
it as dollars overstates the bill a hundredfold — exactly the kind of error a dashboard is
trusted about and never re-checked. GitHub's card is the mirror image (dollars, as a number),
which is why neither module does its own arithmetic.

**The rows are fractions of a cent.** `"0.4"` is a real and common line item. `int()` on a
`Decimal` truncates, so summing thirty of those with a per-bucket `int()` produced zero. All
addition is `Decimal`; rounding happens once, in `format.cents_from_decimal`.
"""

from __future__ import annotations

import asyncio
import datetime as dt
from decimal import Decimal
from typing import Any

import httpx

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport, SeriesPoint, unconfigured
from rascal.services.billing.format import (
    ANTHROPIC_CONSOLE,
    LABELS,
    cents_from_decimal,
    money,
    tokens,
)

_DAYS = 30

#: Stop after this many pages whatever the vendor says. A 30-bucket daily window cannot
#: legitimately need more, and `has_more` that never goes false is somebody else's bug
#: becoming an unbounded loop inside a request handler.
_MAX_PAGES = 5

_SETUP = (
    "Set ANTHROPIC_ADMIN_KEY to an admin key (sk-ant-admin…) from platform.claude.com → "
    "Settings → Admin keys. A normal sk-ant-api… key is refused — the Admin API takes an "
    "admin key or an org:admin OAuth token, and nothing else. Admin keys do not exist on "
    "individual accounts: if Settings has no Admin keys section, this card cannot work until "
    "the account becomes an organization (Settings → Organization). Everything else in the "
    "console is unaffected."
)

#: Said on every render, because both are true on every render and neither is visible in the
#: number: one documented exclusion and one documented lag. A figure that quietly omits a
#: billing mode is the kind a dashboard is believed about right up until it is reconciled.
_CAVEAT = (
    "Priority Tier spend uses a different billing model and is not in this figure. Usage "
    "typically appears within five minutes of a request."
)


async def anthropic_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    if not settings.anthropic_admin_key:
        return unconfigured("anthropic", LABELS["anthropic"], _SETUP, ANTHROPIC_CONSOLE)

    headers = {
        "x-api-key": settings.anthropic_admin_key,
        "anthropic-version": "2023-06-01",
    }
    start = dt.datetime.now(tz=dt.UTC).date() - dt.timedelta(days=_DAYS - 1)
    starting_at = f"{start.isoformat()}T00:00:00Z"

    # Concurrent rather than sequential: `collect()` hands every provider one `AsyncClient`,
    # which is a connection pool, so the second request reuses the open socket and wall time
    # is the slower of the two rather than their sum.
    #
    # `return_exceptions=True` is what makes the sentence above true. `_fetch` turns an HTTP
    # failure into a status code, but a read timeout, a connection error or a non-JSON 200
    # *raises* — and a bare `gather` propagates that immediately, discarding the sibling's
    # result. Without this, a timeout on the decorative usage call would throw away a cost
    # report that had already arrived and blank the only vendor-computed dollar figure on the
    # panel. `fly.py` and `neon.py` have the same shape for the same reason.
    cost, usage = await asyncio.gather(
        _fetch(client, "cost_report", starting_at, "description", headers),
        _fetch(client, "usage_report/messages", starting_at, "model", headers),
        return_exceptions=True,
    )

    if isinstance(cost, BaseException):
        raise cost
    if isinstance(cost, int):
        return _error(cost)
    if cost is None:
        return ProviderReport(
            key="anthropic",
            label=LABELS["anthropic"],
            status="error",
            detail="The cost report did not answer in a usable shape.",
            console_url=ANTHROPIC_CONSOLE,
        )

    total, per_day, per_model = _read_cost(cost)
    metrics = [
        Metric(label=name, value=money(cents_from_decimal(amount)))
        for name, amount in sorted(per_model.items(), key=lambda i: i[1], reverse=True)[:4]
    ]
    if per_day:
        busiest = max(per_day.items(), key=lambda i: i[1])
        metrics.append(
            Metric(
                label="Busiest day",
                value=money(cents_from_decimal(busiest[1])),
                detail=busiest[0].strftime("%b %-d"),
            )
        )
    # The usage call failing costs the token rows and nothing else. It is the softer of the
    # two facts, and a dollar total is worth showing without them.
    if isinstance(usage, list):
        metrics.extend(_usage_metrics(usage))

    return ProviderReport(
        key="anthropic",
        label=LABELS["anthropic"],
        status="ok",
        amount_cents=cents_from_decimal(total),
        period_label=f"last {_DAYS} days",
        detail=_CAVEAT,
        metrics=tuple(metrics),
        series=tuple(
            SeriesPoint(day=day, cents=cents_from_decimal(amount))
            for day, amount in sorted(per_day.items())
        ),
        series_label="Anthropic, daily",
        series_unit="cents",
        console_url=ANTHROPIC_CONSOLE,
    )


async def _fetch(
    client: httpx.AsyncClient,
    path: str,
    starting_at: str,
    group_by: str,
    headers: dict[str, str],
) -> list[dict[str, Any]] | int | None:
    """Every page of one report. Returns the buckets, or the status code on an HTTP failure.

    **Pagination is followed rather than assumed away.** The cost report's maximum `limit` is
    not documented; if the server caps below the thirty days asked for, an unpaginated read
    shows a partial month with no error anywhere — a total that is simply too low and looks
    exactly like a quiet one.
    """
    buckets: list[dict[str, Any]] = []
    page: str | None = None
    for _ in range(_MAX_PAGES):
        params: dict[str, Any] = {
            "starting_at": starting_at,
            "bucket_width": "1d",
            "limit": _DAYS,
            "group_by[]": group_by,
        }
        if page:
            params["page"] = page
        response = await client.get(
            f"https://api.anthropic.com/v1/organizations/{path}",
            params=params,
            headers=headers,
        )
        if response.status_code != 200:
            return response.status_code
        payload = response.json()
        # Same rule as the GitHub card: a body with no `data` key at all is a shape change,
        # not a month with no spending. `None` is the caller's signal to say so instead of
        # rendering $0.00 — which is what the `cost is None` branch above exists for.
        if not isinstance(payload, dict) or "data" not in payload:
            return None
        buckets.extend(payload["data"] or [])
        if not payload.get("has_more"):
            return buckets
        page = payload.get("next_page")
        if not page:
            # `has_more` true with no cursor is a vendor bug. Stopping is right; looping
            # forever on the same page inside a request handler is not.
            return buckets
    return buckets


def _error(status: int) -> ProviderReport:
    """401 and 403 both mean the same thing here, and the message has to name it.

    The status a wrong *kind* of key produces is not documented for this endpoint, so both are
    handled rather than guessing which one it is.
    """
    if status in (401, 403):
        detail = (
            f"HTTP {status} from the cost report. This endpoint takes an admin key "
            "(sk-ant-admin…) or an org:admin OAuth token, and nothing else — an ordinary "
            "sk-ant-api… key is refused here, and individual accounts cannot mint an admin "
            "key at all."
        )
    else:
        detail = f"HTTP {status} from the Anthropic cost report."
    return ProviderReport(
        key="anthropic",
        label=LABELS["anthropic"],
        status="error",
        detail=detail,
        console_url=ANTHROPIC_CONSOLE,
    )


def _read_cost(
    buckets: list[dict[str, Any]],
) -> tuple[Decimal, dict[dt.date, Decimal], dict[str, Decimal]]:
    """Decimal all the way down. Nothing is rounded until it is about to be displayed."""
    total = Decimal(0)
    per_day: dict[dt.date, Decimal] = {}
    per_model: dict[str, Decimal] = {}
    for bucket in buckets:
        day_total = Decimal(0)
        for row in bucket.get("results") or []:
            amount = Decimal(str(row.get("amount", "0")))
            day_total += amount
            name = row.get("model") or row.get("description") or row.get("cost_type") or "other"
            per_model[str(name)] = per_model.get(str(name), Decimal(0)) + amount
        total += day_total
        starting = str(bucket.get("starting_at") or "")[:10]
        if starting:
            try:
                per_day[dt.date.fromisoformat(starting)] = day_total
            except ValueError:
                continue
    return total, per_day, per_model


def _usage_metrics(buckets: list[dict[str, Any]]) -> list[Metric]:
    """Tokens in, tokens out, and how much of the input was a cache read.

    The cache-creation figures live under a `cache_creation` object with the exact sub-keys
    `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` — not `ephemeral_5m`, which is
    the name the shape suggests and which would silently contribute nothing.
    """
    uncached = cached_read = cache_write = output = 0
    for bucket in buckets:
        for row in bucket.get("results") or []:
            uncached += int(row.get("uncached_input_tokens") or 0)
            cached_read += int(row.get("cache_read_input_tokens") or 0)
            output += int(row.get("output_tokens") or 0)
            creation = row.get("cache_creation") or {}
            cache_write += int(creation.get("ephemeral_5m_input_tokens") or 0)
            cache_write += int(creation.get("ephemeral_1h_input_tokens") or 0)

    total_input = uncached + cached_read + cache_write
    if not (total_input or output):
        return []

    metrics = [
        Metric(
            label="Tokens in",
            value=tokens(total_input),
            detail=f"{tokens(cached_read)} cached reads, {tokens(cache_write)} cache writes",
        ),
        Metric(label="Tokens out", value=tokens(output)),
    ]
    if total_input:
        rate = round(100 * cached_read / total_input)
        metrics.append(
            Metric(
                label="Cache hit rate",
                value=f"{rate}%",
                detail="cache reads ÷ all input tokens",
                tone="ok" if rate > 50 else "plain",
            )
        )
    return metrics


__all__ = ["anthropic_report"]
