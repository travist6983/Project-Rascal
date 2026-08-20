"""Consumption for the billing period, plus a daily history — and no dollars anywhere.

Neon reports usage, not money. Its entire v2 API description contains one monetary field,
`spending_limit_cents`, and that is a cap the account owner configured rather than anything
spent. So this card carries no `amount_cents`, and the daily chart it now draws is a chart of
**compute unit hours**, not of spending.

**That is a deliberate refusal, not a missing feature.** Rule 2 permits an estimate derived
from a configured price, which is how the Tigris card carries a figure — but Tigris is one rate
against one quantity and this is not that shape. Neon's compute rate differs by more than two
times between the Launch and Scale plans and the card cannot know which without reading a
subscription field and trusting it; storage is the larger line for a project this size and
accrues as byte-*months* rather than as a per-day quantity; and egress is netted org-wide
against an allowance, so the honest egress line is zero and a naive multiplication overcharges.
Three assumptions to display one number is how a dashboard stops matching an invoice. See
`decisions-log.md`.

Two calls, and **the history one is never allowed to fail the card**. Consumption is this
card's job; the chart is a nice-to-have that needs a plan the account may not be on.
"""

from __future__ import annotations

import asyncio
import datetime as dt
from typing import Any

import httpx

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport, SeriesPoint, unconfigured
from rascal.services.billing.format import LABELS, NEON_CONSOLE, bytes_decimal

_DAYS = 30

_SETUP = (
    "Set NEON_API_KEY (console.neon.tech → Account settings → API keys) and NEON_PROJECT_ID "
    "(the project's Settings page). NEON_ORG_ID is optional and adds the daily compute chart."
)

_DETAIL = "Neon's API reports consumption rather than dollars."


async def neon_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    if not (settings.neon_api_key and settings.neon_project_id):
        return unconfigured("neon", LABELS["neon"], _SETUP, NEON_CONSOLE)

    headers = {
        "Authorization": f"Bearer {settings.neon_api_key}",
        "Accept": "application/json",
    }
    snapshot, history = await asyncio.gather(
        _snapshot(client, settings, headers),
        _history(client, settings, headers),
        return_exceptions=True,
    )

    if isinstance(snapshot, BaseException):
        raise snapshot
    if isinstance(snapshot, int):
        return _error(snapshot)

    project: dict[str, Any] = snapshot
    metrics = _snapshot_metrics(project)
    detail = _DETAIL

    series: tuple[SeriesPoint, ...] = ()
    if isinstance(history, str):
        # A sentence rather than a broken chart. The account may simply be on a plan without
        # consumption history, which is a fact about the plan and not a fault here.
        detail = f"{_DETAIL} {history}"
    elif isinstance(history, list) and history:
        series = tuple(history)
        total_cu = sum(point.value or 0 for point in history)
        busiest = max(history, key=lambda p: p.value or 0)
        metrics.extend(
            [
                Metric(
                    label=f"Compute, {_DAYS} days",
                    value=f"{total_cu:,.1f} CU-hours",
                    detail="summed from the daily consumption history",
                ),
                Metric(
                    label="Busiest day",
                    value=f"{busiest.value or 0:,.1f} CU-hours",
                    detail=busiest.day.strftime("%b %-d"),
                ),
            ]
        )

    period = str(project.get("consumption_period_start") or "")[:10]
    return ProviderReport(
        key="neon",
        label=LABELS["neon"],
        status="ok",
        detail=detail,
        period_label=f"since {period}" if period else "this billing period",
        metrics=tuple(metrics),
        series=series,
        series_label="Neon, compute CU-hours per day" if series else None,
        series_unit="CU-hours" if series else None,
        console_url=NEON_CONSOLE,
    )


async def _snapshot(
    client: httpx.AsyncClient, settings: Settings, headers: dict[str, str]
) -> dict[str, Any] | int:
    """The project object. Still the right call for a point-in-time consumption snapshot.

    `cpu_used_sec` and `quota_reset_at` are deprecated in favour of `compute_time_seconds` and
    `consumption_period_end`. Neither deprecated field is read here — noted so the next reader
    does not add them.
    """
    response = await client.get(
        f"https://console.neon.tech/api/v2/projects/{settings.neon_project_id}",
        headers=headers,
    )
    if response.status_code != 200:
        return response.status_code
    return response.json().get("project") or {}


async def _history(
    client: httpx.AsyncClient, settings: Settings, headers: dict[str, str]
) -> list[SeriesPoint] | str:
    """Daily compute, or a sentence explaining why there is none.

    `org_id` and `metrics` are both required on the v2 consumption endpoint, which is why this
    needs a setting the snapshot does not. The org id is deliberately not bootstrapped from
    `GET /users/me/organizations` at runtime: that would be a request per render spent parsing
    a response shape to guess at, in place of one environment variable.
    """
    if not settings.neon_org_id:
        return (
            "Set NEON_ORG_ID for the daily compute chart — everything else on this card works "
            "without it."
        )

    now = dt.datetime.now(tz=dt.UTC)
    response = await client.get(
        "https://console.neon.tech/api/v2/consumption_history/v2/projects",
        params={
            "from": (now - dt.timedelta(days=_DAYS)).strftime("%Y-%m-%dT%H:00:00Z"),
            "to": now.strftime("%Y-%m-%dT%H:00:00Z"),
            "granularity": "daily",
            "org_id": settings.neon_org_id,
            "project_ids": settings.neon_project_id,
            # Repeated params rather than a comma-joined string — httpx expands a list.
            "metrics": ["compute_unit_seconds"],
            "limit": 1,
        },
        headers=headers,
    )
    if response.status_code != 200:
        return {
            403: "The daily chart needs a Neon plan that retains consumption history; this "
            "account is on one that does not.",
            404: "NEON_ORG_ID names an organisation this API key is not a member of, so "
            "there is no daily chart.",
            406: "Neon refused the date range for daily granularity, so there is no chart.",
        }.get(response.status_code, "")

    projects = response.json().get("projects") or []
    if not projects:
        return ""

    points: list[SeriesPoint] = []
    for period in projects[0].get("periods") or []:
        for entry in period.get("consumption") or []:
            day = str(entry.get("timeframe_start") or "")[:10]
            seconds = _metric(entry.get("metrics") or [], "compute_unit_seconds")
            if not day or seconds is None:
                continue
            try:
                points.append(SeriesPoint(day=dt.date.fromisoformat(day), value=seconds / 3600))
            except ValueError:
                continue
    return sorted(points, key=lambda p: p.day)


def _metric(entries: list[dict[str, Any]], name: str) -> float | None:
    """`metrics` is an array of `{metric_name, value}` objects, not a flat dictionary."""
    for entry in entries:
        if entry.get("metric_name") == name:
            return float(entry.get("value") or 0)
    return None


def _snapshot_metrics(project: dict[str, Any]) -> list[Metric]:
    """The four consumption figures, in decimal gigabytes because that is how Neon bills.

    `bytes_decimal`, never `bytes_binary`: Neon's GB-month is 10⁹ bytes and Tigris's GB-month
    is 2³⁰. Sharing one divisor between the two cards would understate one of them by seven
    percent, silently, on the screen that exists to be trusted about this.
    """
    raw_storage = project.get("synthetic_storage_size")
    storage = (
        Metric(label="Storage", value=bytes_decimal(int(raw_storage)))
        if raw_storage is not None
        # `or 0` here used to render "0.0 B", which is a lie shaped exactly like a measurement.
        # The field is optional on Neon's project object and absent from its own example.
        else Metric(
            label="Storage",
            value="not reported",
            detail="synthetic_storage_size is optional on Neon's project object and absent here",
            tone="warn",
        )
    )
    compute_seconds = int(project.get("compute_time_seconds") or 0)
    return [
        storage,
        Metric(label="Compute", value=f"{compute_seconds / 3600:,.1f} h", detail="this period"),
        Metric(label="Written", value=bytes_decimal(int(project.get("written_data_bytes") or 0))),
        Metric(label="Egress", value=bytes_decimal(int(project.get("data_transfer_bytes") or 0))),
    ]


def _error(status: int) -> ProviderReport:
    return ProviderReport(
        key="neon",
        label=LABELS["neon"],
        status="error",
        detail=f"HTTP {status} from Neon. Check NEON_API_KEY and NEON_PROJECT_ID — a 404 here "
        "usually means the project id is wrong.",
        console_url=NEON_CONSOLE,
    )


__all__ = ["neon_report"]
