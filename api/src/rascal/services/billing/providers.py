"""The five vendors, each read the only way it can be read.

One module rather than five, because four of them are one HTTP call and a shape conversion,
and splitting that across files would hide how little each one does. What differs between
them is worth reading side by side:

| Vendor    | Exposes spend? | Credential                        | What the card carries |
|-----------|----------------|-----------------------------------|-----------------------|
| Anthropic | **Yes**        | `ANTHROPIC_ADMIN_KEY`             | Daily cost, by model  |
| Resend    | No             | `MAIL_API_KEY` (already set)      | Audience, domains     |
| Tigris    | No             | The S3 keys media already uses    | Objects, bytes        |
| Fly       | No             | `FLY_API_TOKEN`                   | Machines and schedules|
| Neon      | No             | `NEON_API_KEY` + `NEON_PROJECT_ID`| Storage, compute      |

**Only Anthropic publishes a cost API**, so it is the only card with a dollar figure on it.
The other four report the thing that actually drives their bill — bytes, machine-hours,
contacts — and link to the invoice. That asymmetry is the honest shape of this screen and is
not a gap to be filled in later with estimates.
"""

from __future__ import annotations

import datetime as dt
from decimal import Decimal
from typing import Any

import httpx
from anyio import to_thread

from rascal.config import Settings
from rascal.services.billing.base import (
    Metric,
    ProviderReport,
    SeriesPoint,
    unconfigured,
)
from rascal.services.s3 import get_s3_client

ANTHROPIC_CONSOLE = "https://console.anthropic.com/settings/usage"
RESEND_CONSOLE = "https://resend.com/audiences"
FLY_CONSOLE = "https://fly.io/dashboard"
NEON_CONSOLE = "https://console.neon.tech"
TIGRIS_CONSOLE = "https://console.tigris.dev"

LABELS = {
    "anthropic": "Anthropic",
    "fly": "Fly.io",
    "neon": "Neon",
    "tigris": "Tigris (storage)",
    "resend": "Resend",
}


def _money(cents: int) -> str:
    return f"${cents / 100:,.2f}"


def _bytes(count: int) -> str:
    size = float(count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:,.1f} {unit}" if unit != "B" else f"{int(size):,} B"
        size /= 1024
    return f"{size:,.1f} TB"


# --- Anthropic ------------------------------------------------------------------------------


async def anthropic_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    """`GET /v1/organizations/cost_report`, the one endpoint here that returns money.

    Two things about this API are easy to get wrong and are handled explicitly:

    **It needs an *admin* key.** `sk-ant-admin…`, minted under Settings → Admin keys. An
    ordinary `sk-ant-api…` key — the kind every other integration uses — is rejected, and the
    rejection reads like a permissions bug rather than a wrong-kind-of-key bug.

    **`amount` is cents, as a decimal string.** The docs are explicit: `"123.45"` in USD is
    $1.23. Reading it as dollars overstates the bill a hundredfold, which is exactly the kind of
    error a dashboard is trusted about and never re-checked.
    """
    if not settings.anthropic_admin_key:
        return unconfigured(
            "anthropic",
            LABELS["anthropic"],
            "Set ANTHROPIC_ADMIN_KEY to an admin key (sk-ant-admin…) from "
            "console.anthropic.com → Settings → Admin keys. A normal sk-ant-api… key is "
            "refused — the Admin API takes an admin key or an org:admin OAuth token, and "
            "nothing else. Admin keys do not exist on individual accounts: if Settings has "
            "no Admin keys section, this card cannot work until the account becomes an "
            "organization (Console → Settings → Organization). Everything else in the console "
            "is unaffected.",
            ANTHROPIC_CONSOLE,
        )

    days = 30
    start = dt.datetime.now(tz=dt.UTC).date() - dt.timedelta(days=days - 1)
    response = await client.get(
        "https://api.anthropic.com/v1/organizations/cost_report",
        params={
            "starting_at": f"{start.isoformat()}T00:00:00Z",
            "bucket_width": "1d",
            "limit": days,
            "group_by[]": "description",
        },
        headers={
            "x-api-key": settings.anthropic_admin_key,
            "anthropic-version": "2023-06-01",
        },
    )
    if response.status_code == 401:
        return ProviderReport(
            key="anthropic",
            label=LABELS["anthropic"],
            status="error",
            detail="401 from the cost report. This endpoint needs an admin key "
            "(sk-ant-admin…), not a normal API key.",
            console_url=ANTHROPIC_CONSOLE,
        )
    response.raise_for_status()
    payload = response.json()

    # Decimal all the way down, rounded once at the end. See `cents_from_decimal_string`.
    total = Decimal(0)
    per_day: list[SeriesPoint] = []
    per_model: dict[str, Decimal] = {}
    for bucket in payload.get("data", []):
        day_total = Decimal(0)
        for row in bucket.get("results", []):
            amount = Decimal(str(row.get("amount", "0")))
            day_total += amount
            model = row.get("model") or row.get("cost_type") or "other"
            per_model[model] = per_model.get(model, Decimal(0)) + amount
        total += day_total
        starting = bucket.get("starting_at", "")[:10]
        if starting:
            per_day.append(SeriesPoint(day=dt.date.fromisoformat(starting), cents=int(day_total)))

    top = sorted(per_model.items(), key=lambda item: item[1], reverse=True)[:4]
    metrics = [Metric(label=name, value=_money(int(amount))) for name, amount in top]
    if per_day:
        busiest = max(per_day, key=lambda p: p.cents)
        metrics.append(
            Metric(
                label="Busiest day",
                value=_money(busiest.cents),
                detail=busiest.day.strftime("%b %-d"),
            )
        )

    return ProviderReport(
        key="anthropic",
        label=LABELS["anthropic"],
        status="ok",
        amount_cents=int(total),
        period_label=f"last {days} days",
        metrics=tuple(metrics),
        series=tuple(per_day),
        console_url=ANTHROPIC_CONSOLE,
    )


# --- Resend ---------------------------------------------------------------------------------


async def resend_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    """Contacts and sending domains. Resend publishes no spend endpoint.

    **The key this reads is `MAIL_API_KEY`** — the one the mailer already holds — rather than
    a second copy under a console-specific name. One credential, one rotation.

    The contact count is the number this project actually wants: `decisions.md` open item
    12(4) puts the marketing list at Resend and creates no `subscribers` table, so this API
    is the *only* place the size of the list exists. Confirmed and unconfirmed are reported
    separately because phase 88 established that a contact is created unsubscribed and a
    signed link flips it — a single total would hide how many people never clicked.
    """
    if not settings.mail_api_key:
        return unconfigured(
            "resend",
            LABELS["resend"],
            "Set MAIL_API_KEY to a Resend API key. The same key the mailer uses — this card "
            "deliberately does not introduce a second one.",
            RESEND_CONSOLE,
        )

    headers = {"Authorization": f"Bearer {settings.mail_api_key}"}
    metrics: list[Metric] = []

    domains = await client.get("https://api.resend.com/domains", headers=headers)
    if domains.status_code == 401:
        return ProviderReport(
            key="resend",
            label=LABELS["resend"],
            status="error",
            detail="401 from Resend. MAIL_API_KEY is set but not accepted.",
            console_url=RESEND_CONSOLE,
        )
    domains.raise_for_status()
    for domain in (domains.json().get("data") or [])[:3]:
        status = str(domain.get("status", "unknown"))
        metrics.append(
            Metric(
                label=str(domain.get("name", "domain")),
                value=status,
                detail=str(domain.get("region") or ""),
                tone="ok" if status == "verified" else "warn",
            )
        )

    if settings.resend_audience_id:
        contacts = await client.get(
            f"https://api.resend.com/audiences/{settings.resend_audience_id}/contacts",
            headers=headers,
        )
        if contacts.is_success:
            rows = contacts.json().get("data") or []
            confirmed = sum(1 for row in rows if not row.get("unsubscribed"))
            metrics.insert(
                0,
                Metric(
                    label="Confirmed subscribers",
                    value=f"{confirmed:,}",
                    detail=f"{len(rows) - confirmed:,} not confirmed or unsubscribed",
                    tone="ok" if confirmed else "plain",
                ),
            )
        else:
            metrics.insert(
                0,
                Metric(
                    label="Audience",
                    value="unreadable",
                    detail=f"HTTP {contacts.status_code} for RESEND_AUDIENCE_ID",
                    tone="bad",
                ),
            )
    else:
        metrics.insert(
            0,
            Metric(
                label="Audience",
                value="not set",
                detail="RESEND_AUDIENCE_ID is unset, so POST /v1/subscribe refuses",
                tone="warn",
            ),
        )

    return ProviderReport(
        key="resend",
        label=LABELS["resend"],
        status="ok",
        detail="Resend publishes no billing API. Sending volume drives the bill.",
        metrics=tuple(metrics),
        console_url=RESEND_CONSOLE,
    )


# --- Tigris ---------------------------------------------------------------------------------

#: Stop walking the bucket after this many objects. A `ListObjectsV2` paginator will happily
#: enumerate a million keys one 1000-key page at a time, and a costs panel is not worth an
#: eight-second stall. Past the cap the card says the figure is a floor rather than a total,
#: because a silently truncated number that reads as exact is the worse failure.
_MAX_OBJECTS = 20_000


def _walk_bucket(bucket: str) -> tuple[int, int, dict[str, int], bool]:
    """Sum object count and bytes by top-level prefix. Runs in a thread — boto3 is sync."""
    paginator = get_s3_client().get_paginator("list_objects_v2")
    count = 0
    total = 0
    by_prefix: dict[str, int] = {}
    truncated = False
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            count += 1
            size = int(obj.get("Size", 0))
            total += size
            prefix = str(obj.get("Key", "")).split("/", 1)[0] or "(root)"
            by_prefix[prefix] = by_prefix.get(prefix, 0) + size
            if count >= _MAX_OBJECTS:
                truncated = True
                break
        if truncated:
            break
    return count, total, by_prefix, truncated


async def tigris_report(settings: Settings) -> ProviderReport:
    """What the archive actually weighs, read from the bucket the phone uploads to.

    No credential of its own: this is the same S3 client `services/s3.py` presigns with, so
    the card works the moment media uploads do and breaks in the same way if they are broken
    — which makes it a storage-health check as much as a cost one.

    **boto3 is synchronous**, so the walk runs in a worker thread. Listing a bucket inline on
    the event loop would stall every other request on the machine for as long as the walk
    takes, which on a growing archive is exactly the wrong direction.
    """
    count, total, by_prefix, truncated = await to_thread.run_sync(_walk_bucket, settings.s3_bucket)

    metrics = [
        Metric(
            label="Objects",
            value=f"{count:,}{'+' if truncated else ''}",
            detail="stopped counting at the cap" if truncated else None,
            tone="warn" if truncated else "plain",
        )
    ]
    for prefix, size in sorted(by_prefix.items(), key=lambda item: item[1], reverse=True)[:3]:
        metrics.append(Metric(label=f"{prefix}/", value=_bytes(size)))

    amount_cents: int | None = None
    detail = "Tigris publishes no billing API. Stored bytes are what the bill is computed from."
    if settings.storage_price_cents_per_gb_month is not None:
        gigabytes = total / (1024**3)
        amount_cents = round(gigabytes * settings.storage_price_cents_per_gb_month)
        detail = (
            f"Estimated from STORAGE_PRICE_CENTS_PER_GB_MONTH="
            f"{settings.storage_price_cents_per_gb_month}. Not a figure from Tigris."
        )

    return ProviderReport(
        key="tigris",
        label=LABELS["tigris"],
        status="ok",
        detail=detail,
        amount_cents=amount_cents,
        period_label="per month, estimated" if amount_cents is not None else None,
        metrics=(Metric(label="Stored", value=_bytes(total), tone="ok"), *metrics),
        console_url=TIGRIS_CONSOLE,
    )


# --- Fly ------------------------------------------------------------------------------------


async def fly_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    """The machine inventory, which is the thing this project has actually been bitten by.

    Fly does not expose per-app spend over its public API, so there is no dollar figure here
    and none is invented. What is here is more useful anyway: **which machines exist, which
    image each is on, and which of them carry a schedule.**

    That is a direct answer to the failure class `roadmap-status.md` names — *"a deploy that
    is green everywhere and still does not reach the machine that does the work."* The
    scheduler machine sat outside the process group for weeks, every deploy was green, and
    nothing in CI could see it. A machine whose image tag differs from the majority is
    flagged here, on a screen somebody looks at.
    """
    if not settings.fly_api_token:
        return unconfigured(
            "fly",
            LABELS["fly"],
            "Set FLY_API_TOKEN (`fly tokens create readonly`) and FLY_APP_NAME. Read-only is "
            "enough — nothing here writes.",
            FLY_CONSOLE,
        )

    response = await client.get(
        f"https://api.machines.dev/v1/apps/{settings.fly_app_name}/machines",
        headers={"Authorization": f"Bearer {settings.fly_api_token}"},
    )
    if response.status_code in (401, 403):
        return ProviderReport(
            key="fly",
            label=LABELS["fly"],
            status="error",
            detail=f"HTTP {response.status_code} from the Machines API. "
            "FLY_API_TOKEN is set but not accepted for this app.",
            console_url=FLY_CONSOLE,
        )
    response.raise_for_status()
    machines: list[dict[str, Any]] = response.json()

    images = [str(m.get("config", {}).get("image", "")) for m in machines]
    tags = [image.split("@", 1)[0] for image in images if image]
    majority = max(set(tags), key=tags.count) if tags else ""

    metrics: list[Metric] = [
        Metric(
            label="Machines",
            value=str(len(machines)),
            detail=", ".join(sorted({str(m.get("region", "?")) for m in machines})) or None,
        )
    ]
    drifted = 0
    for machine in machines:
        config = machine.get("config") or {}
        schedule = config.get("schedule")
        image_tag = str(config.get("image", "")).split("@", 1)[0]
        stale = bool(majority) and image_tag != majority
        drifted += stale
        if schedule:
            metrics.append(
                Metric(
                    label=f"scheduled · {schedule}",
                    value=str(machine.get("state", "?")),
                    detail=f"{machine.get('id', '?')} — image {'STALE' if stale else 'current'}",
                    tone="bad" if stale else "ok",
                )
            )
    if drifted:
        metrics.insert(
            1,
            Metric(
                label="Image drift",
                value=f"{drifted} machine{'s' if drifted != 1 else ''} behind",
                detail="A green deploy does not reach a machine outside the process group.",
                tone="bad",
            ),
        )

    return ProviderReport(
        key="fly",
        label=LABELS["fly"],
        status="ok",
        detail="Fly exposes no per-app spend over the API. Machines and schedules are what "
        "this card is for — a scheduled machine on a stale image is invisible everywhere else.",
        metrics=tuple(metrics),
        console_url=FLY_CONSOLE,
    )


# --- Neon -----------------------------------------------------------------------------------


async def neon_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    """Consumption for the billing period. Neon reports usage, not dollars."""
    if not (settings.neon_api_key and settings.neon_project_id):
        return unconfigured(
            "neon",
            LABELS["neon"],
            "Set NEON_API_KEY (console.neon.tech → Account settings → API keys) and "
            "NEON_PROJECT_ID (the project's Settings page).",
            NEON_CONSOLE,
        )

    response = await client.get(
        f"https://console.neon.tech/api/v2/projects/{settings.neon_project_id}",
        headers={"Authorization": f"Bearer {settings.neon_api_key}", "Accept": "application/json"},
    )
    if response.status_code in (401, 403, 404):
        return ProviderReport(
            key="neon",
            label=LABELS["neon"],
            status="error",
            detail=f"HTTP {response.status_code} from Neon. Check NEON_API_KEY and "
            "NEON_PROJECT_ID — a 404 here usually means the project id is wrong.",
            console_url=NEON_CONSOLE,
        )
    response.raise_for_status()
    project = response.json().get("project") or {}

    compute_seconds = int(project.get("compute_time_seconds") or 0)
    metrics = (
        Metric(label="Storage", value=_bytes(int(project.get("synthetic_storage_size") or 0))),
        Metric(label="Compute", value=f"{compute_seconds / 3600:,.1f} h", detail="this period"),
        Metric(label="Written", value=_bytes(int(project.get("written_data_bytes") or 0))),
        Metric(label="Egress", value=_bytes(int(project.get("data_transfer_bytes") or 0))),
    )
    period = str(project.get("consumption_period_start") or "")[:10]

    return ProviderReport(
        key="neon",
        label=LABELS["neon"],
        status="ok",
        detail="Neon's API reports consumption rather than dollars.",
        period_label=f"since {period}" if period else "this billing period",
        metrics=metrics,
        console_url=NEON_CONSOLE,
    )
