"""Actions spend, from the one billing endpoint GitHub still answers.

**This card exists because this repository has been halted twice by Actions billing** —
`docs/blocked.md` §0 and §0a, both of which cost a day. Neither halt was visible anywhere
until CI simply stopped running. A dollar figure on a screen somebody looks at is the cheapest
instrument against a third one.

Two things about this API are easy to get wrong:

**The endpoints the obvious search finds are gone.** `GET /users/{u}/settings/billing/actions`,
`/shared-storage` and `/packages` were removed, not deprecated — every field they returned
(`total_minutes_used`, `included_minutes`, `minutes_used_breakdown`, `UBUNTU`/`MACOS`/
`WINDOWS`) has zero occurrences in GitHub's current OpenAPI description. Code written against
a memory of that shape compiles, ships, and 404s forever.

**`netAmount` is dollars, as a JSON number.** Anthropic's cost report is the exact inverse —
cents, as a decimal string. Getting these two backwards in the same package is a hundredfold
error in either direction, so both go through `format.cents_from_dollars` /
`format.cents_from_decimal` rather than doing their own arithmetic.
"""

from __future__ import annotations

import datetime as dt
from decimal import Decimal
from typing import Any

import httpx

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport, SeriesPoint, unconfigured
from rascal.services.billing.format import (
    GITHUB_CONSOLE,
    LABELS,
    cents_from_decimal,
    cents_from_dollars,
    money,
)

_SETUP = (
    "Set GITHUB_BILLING_TOKEN to a fine-grained personal access token whose only permission "
    "is Account permissions → Plan → Read-only, and GITHUB_ACCOUNT to the username that owns "
    "the bill. A classic token will not work here, and neither will the repo-scoped token CI "
    "already uses — this endpoint reads the account's plan, not a repository."
)

#: What the card says instead of a minutes-remaining gauge, permanently and in `warn` tone.
#:
#: **The billing API exposes no budget, no quota and no remaining balance.** A $0 budget with
#: "stop usage" enabled rejects every workflow run before its first step, which is exactly what
#: happened twice, and nothing in this response would have moved beforehand. A gauge reading
#: "0 of 2,000 minutes used" would have been showing green through both halts. So the card
#: says the instrument does not exist and links at the page that does.
_BUDGET_BLIND_SPOT = (
    "GitHub's billing API exposes no budget, quota or remaining balance. A $0 budget with "
    "'stop usage' on rejects every run before its first step and nothing here would move — "
    "check the budgets page, not this card."
)


async def github_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    """`GET /users/{account}/settings/billing/usage`, which returns real money.

    `/usage` rather than `/usage/summary`: the summary is pre-aggregated and carries no
    per-item `date`, and a daily date is the whole reason to prefer this endpoint — it is what
    turns the card into a chart. The summary's one unique field is a gross/discount/net
    *quantity* split whose meaning is not documented as plan quota, so it would be a second
    call and a second failure mode for a number that might mean something else.
    """
    if not settings.github_billing_token:
        return unconfigured("github", LABELS["github"], _SETUP, GITHUB_CONSOLE)

    today = dt.datetime.now(tz=dt.UTC).date()
    response = await client.get(
        f"https://api.github.com/users/{settings.github_account}/settings/billing/usage",
        params={"year": today.year, "month": today.month},
        headers={
            "Authorization": f"Bearer {settings.github_billing_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    if response.status_code != 200:
        return _error(response.status_code, settings)

    items = response.json().get("usageItems") or []
    return _report(items, today)


def _error(status: int, settings: Settings) -> ProviderReport:
    """One sentence per status, because three of these send you somewhere different.

    **The 404 is the one worth the code.** GitHub answers a token that lacks the `Plan`
    permission with 404 rather than 403 — a bare "not found" reads as a mistyped username and
    sends you renaming the account, which is a long way from regenerating a token.
    """
    detail = {
        401: (
            "401 from GitHub. GITHUB_BILLING_TOKEN was rejected outright — it is missing, "
            "malformed, expired or revoked."
        ),
        403: (
            "403 from GitHub. This account is most likely not on the enhanced billing "
            "platform, which the usage endpoint requires. Check github.com/settings/billing."
        ),
        404: (
            f"404 from GitHub, which here means the token lacks the Plan (read) permission — "
            f"GitHub answers 404 rather than 403 for that. Regenerate GITHUB_BILLING_TOKEN as "
            f"a fine-grained token with Account permissions → Plan → Read-only. "
            f"GITHUB_ACCOUNT={settings.github_account!r} is very likely not the problem."
        ),
        410: (
            "410 — a legacy billing endpoint was called. /settings/billing/actions and "
            "/shared-storage were removed; nothing in this card should be reaching them."
        ),
        503: "GitHub's billing subsystem is unavailable. Nothing is wrong at this end.",
    }.get(status, f"HTTP {status} from GitHub's billing usage endpoint.")
    return ProviderReport(
        key="github",
        label=LABELS["github"],
        status="error",
        detail=detail,
        console_url=GITHUB_CONSOLE,
    )


def _report(items: list[dict[str, Any]], today: dt.date) -> ProviderReport:
    """Sum the Actions rows, group them by SKU, and build the daily series.

    Filtered on `product`, never on `sku`: GitHub's own documentation disagrees with itself
    about whether the SKU is `"Actions Linux"` or `"actions_linux"`, while `product` is
    `"Actions"` across every source. The SKU is still used verbatim for the breakdown, because
    a label that is merely inconsistent is fine and a filter that is inconsistent is a card
    that reports zero.
    """
    total = Decimal(0)
    per_day: dict[dt.date, Decimal] = {}
    per_sku: dict[str, Decimal] = {}
    minutes = 0
    line_items = 0

    for item in items:
        if str(item.get("product", "")).strip().lower() != "actions":
            continue
        line_items += 1
        cents = cents_from_dollars(item.get("netAmount", 0))
        total += cents
        sku = str(item.get("sku") or "Actions")
        per_sku[sku] = per_sku.get(sku, Decimal(0)) + cents
        # Only minute-denominated rows feed the minutes figure. Actions storage arrives in
        # this same report under a different `unitType`, and adding gigabytes to minutes
        # would produce a number with no unit at all.
        if str(item.get("unitType", "")).strip().lower() == "minutes":
            minutes += int(float(item.get("quantity") or 0))
        raw_day = str(item.get("date") or "")[:10]
        if raw_day:
            try:
                day = dt.date.fromisoformat(raw_day)
            except ValueError:
                continue
            per_day[day] = per_day.get(day, Decimal(0)) + cents

    metrics = [
        Metric(
            label="Actions minutes",
            value=f"{minutes:,} min",
            detail=f"across {line_items:,} billed line item{'s' if line_items != 1 else ''}",
        )
    ]
    for sku, cents in sorted(per_sku.items(), key=lambda item: item[1], reverse=True)[:3]:
        metrics.append(Metric(label=_pretty_sku(sku), value=money(cents_from_decimal(cents))))
    metrics.append(
        Metric(label="Budget", value="not visible here", detail=_BUDGET_BLIND_SPOT, tone="warn")
    )

    series = tuple(
        SeriesPoint(day=day, cents=cents_from_decimal(cents))
        for day, cents in sorted(per_day.items())
    )

    return ProviderReport(
        key="github",
        label=LABELS["github"],
        status="ok",
        amount_cents=cents_from_decimal(total),
        period_label=today.strftime("%B %Y"),
        detail=(
            "Actions usage for the current calendar month, billed. GitHub reports the amount "
            "itself, so nothing on this card is estimated."
        ),
        metrics=tuple(metrics),
        series=series,
        series_label="GitHub Actions, daily",
        series_unit="cents",
        console_url=GITHUB_CONSOLE,
    )


def _pretty_sku(sku: str) -> str:
    """`"actions_linux"` and `"Actions Linux"` are the same runner. Display them the same way."""
    return sku.replace("_", " ").title()


__all__ = ["github_report"]
