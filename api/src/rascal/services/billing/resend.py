"""Contacts and sending domains. Resend publishes no spend endpoint.

Moved out of `providers.py` unchanged when that module became seven files. It is still the
simplest card here — one HTTP call and a shape conversion — and it is the reason the old
one-module argument held for as long as it did.
"""

from __future__ import annotations

import httpx

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport, unconfigured
from rascal.services.billing.format import LABELS, RESEND_CONSOLE


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


__all__ = ["resend_report"]
