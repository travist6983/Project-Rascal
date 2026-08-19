"""The daily prompt broadcast: pick one prompt, render it, send it to the audience once.

**What this is not.** Story 4 specifies two mechanisms — this broadcast and a five-email
welcome sequence dripped off each subscriber's `confirmed_at`. Only the broadcast is built, and
the reason is structural rather than a shortcut: the sequence needs to know who confirmed and
when, and that fact lives at Resend. We hold no subscriber rows (open item 12(4)), and building
the per-recipient state the drip needs would recreate the mailing list in our database — which
the published privacy page says does not exist. `docs/sprint-aug16/story-4-report.md` records
the three ways forward; picking one is the owner's call, not this module's.

A broadcast needs none of that. It goes to an audience id, Resend expands it, and nothing about
any individual passes through this process.

**Nothing sends until `MARKETING_EMAIL_ENABLED=true`.** Open item 12 repeats in every line that
touches this work: no marketing email before the P0 behavioural gate. Everything below runs in
full without it — the send is the one withheld step.
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass

import httpx
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.models.email_broadcast import EmailBroadcast
from rascal.services.email_copy import EmailCopy, load

log = logging.getLogger("rascal.broadcast")

BROADCASTS_ENDPOINT = "https://api.resend.com/broadcasts"

#: Resend's own unsubscribe token. **For a broadcast, Resend owns the unsubscribe** — that is
#: the consequence of the list being provider-held, and it is why no link of ours appears in the
#: footer. Two unsubscribe links with different semantics in one email is worse than either.
UNSUBSCRIBE_TOKEN = "{{{RESEND_UNSUBSCRIBE_URL}}}"

#: Where `[site]` in the footer points.
#: **Was a hardcoded `https://travist6983.github.io` until phase 87.** It went stale the day the
#: custom domain landed, and nothing failed: every prompt email's footer would simply have linked
#: to a URL that now only redirects. It reads from `settings.marketing_site_url` now, so the site
#: has one address in this service rather than two that can disagree.

#: Palette from `docs/design-system.md`. Inlined rather than imported because an email is not
#: the app, and a stylesheet cannot be shared with a medium that has no stylesheets.
CANVAS = "#FDFAF4"
INK = "#23253C"
INK_MUTED = "#6E6A63"
TERRACOTTA = "#C05A2B"


@dataclass(frozen=True)
class BroadcastResult:
    """What a run did, for the job to print and the tests to assert on."""

    send_date: dt.date
    pool_index: int
    subject: str
    status: str
    resend_id: str | None = None
    error: str | None = None

    @property
    def was_sent(self) -> bool:
        return self.status == "sent"


class AlreadySent(Exception):
    """This day already has a row. Not an error — the unique index doing its job."""


def render(prompt: str, footer: str, site_url: str) -> tuple[str, str]:
    """The prompt as HTML and as plain text.

    **Both parts, always.** A `text/plain` alternative is a deliverability signal rather than a
    courtesy, and a mail that is HTML-only reads as bulk to the filters that decide whether any
    of this arrives at all.

    Table-based layout with inline styles, because email clients are what they are: no external
    stylesheet, no web font, no image, and nothing that could be a tracking pixel. Comfortably
    under Gmail's 102KB clipping threshold, which matters because what gets clipped is the
    bottom — and the bottom is the unsubscribe.
    """
    footer_html = (
        footer.replace("[site]", f'<a href="{site_url}" style="color:{INK_MUTED}">Vellum</a>')
        .replace(
            "[unsubscribe]",
            f'<a href="{UNSUBSCRIBE_TOKEN}" style="color:{INK_MUTED}">unsubscribe</a>',
        )
        .replace("\n\n", "<br><br>")
    )

    html = f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;padding:0;background:{CANVAS};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
       style="background:{CANVAS};">
  <tr>
    <td align="center" style="padding:32px 16px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
             style="max-width:520px;">
        <tr>
          <td style="font-family:Georgia,'Times New Roman',serif;font-size:22px;line-height:1.4;
                     color:{INK};padding-bottom:28px;">
            {prompt}
          </td>
        </tr>
        <tr>
          <td style="border-top:1px solid #E8E0D2;padding-top:16px;
                     font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                     font-size:13px;line-height:1.55;color:{INK_MUTED};">
            {footer_html}
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>"""

    text_footer = footer.replace("[site]", site_url).replace("[unsubscribe]", UNSUBSCRIBE_TOKEN)
    text = f"{prompt}\n\n---\n\n{text_footer}\n"
    return html, text


def is_live(settings: Settings) -> bool:
    """Whether this run may actually send.

    Four conditions, and the flag is deliberately separate from the credentials. Setting
    `MAIL_API_KEY` is something the owner will do to make the *subscribe* route work; it must
    not also start mailing the list.
    """
    return bool(
        settings.marketing_email_enabled
        and settings.mail_api_key
        and settings.resend_audience_id
        and "resend.dev" not in settings.mail_from
        and "rascal.local" not in settings.mail_from
    )


def why_not_live(settings: Settings) -> str:
    """The specific missing piece, so a dry run says which one rather than just 'dry run'."""
    if not settings.marketing_email_enabled:
        return "MARKETING_EMAIL_ENABLED is false (the P0 behavioural gate has not passed)"
    if not settings.mail_api_key:
        return "MAIL_API_KEY is unset"
    if not settings.resend_audience_id:
        return "RESEND_AUDIENCE_ID is unset"
    return f"MAIL_FROM is still {settings.mail_from!r}, which is not a verified sending domain"


async def run_broadcast(
    session: AsyncSession,
    settings: Settings,
    *,
    as_of: dt.date | None = None,
    copy: EmailCopy | None = None,
) -> BroadcastResult:
    """Send at most one broadcast for `as_of`, or record why it did not.

    **The ledger row is written and committed before the network call**, so a crash between the
    two leaves a row claiming `failed` rather than no row at all. A day that wrongly looks sent
    costs one missed prompt; a day that wrongly looks unsent mails the whole list twice.
    """
    day = as_of or dt.datetime.now(dt.UTC).date()
    text = copy or load()

    existing = await session.scalar(select(EmailBroadcast).where(EmailBroadcast.send_date == day))
    if existing is not None:
        raise AlreadySent(f"{day} already has a {existing.status} broadcast")

    index, prompt = text.prompt_for(day.timetuple().tm_yday)
    live = is_live(settings)

    row = EmailBroadcast(
        send_date=day,
        pool_index=index,
        subject=prompt,
        status="sent" if live else "skipped",
    )
    session.add(row)
    try:
        await session.flush()
    except IntegrityError as exc:
        # Two machines woke together and the other one won. That is the index working.
        await session.rollback()
        raise AlreadySent(f"{day} was claimed concurrently") from exc

    html, plain = render(prompt, text.footer, settings.marketing_site_url)

    if not live:
        reason = why_not_live(settings)
        log.info(
            "broadcast dry run",
            extra={"send_date": str(day), "pool_index": index, "reason": reason},
        )
        # The whole rendered mail at INFO, because the point of a dry run is that somebody can
        # read exactly what would have gone out.
        log.info("broadcast subject: %s", prompt)
        log.info("broadcast text body:\n%s", plain)
        await session.commit()
        return BroadcastResult(day, index, prompt, "skipped", error=reason)

    # Committed before the call, so the day is claimed even if the process dies mid-request.
    await session.commit()

    try:
        resend_id = await _send(prompt, html, plain, settings)
    except Exception as exc:
        row.status = "failed"
        row.error = str(exc)[:500]
        await session.commit()
        log.warning("broadcast failed", extra={"send_date": str(day)})
        return BroadcastResult(day, index, prompt, "failed", error=str(exc))

    row.resend_id = resend_id
    row.sent_at = dt.datetime.now(dt.UTC)
    await session.commit()
    log.info("broadcast sent", extra={"send_date": str(day), "resend_id": resend_id})
    return BroadcastResult(day, index, prompt, "sent", resend_id=resend_id)


async def _send(subject: str, html: str, plain: str, settings: Settings) -> str:
    """Create the broadcast, then send it. Two calls, because that is Resend's shape.

    **No retry.** A scheduled machine runs again tomorrow, and a retry loop around a bulk send
    is how a list receives the same prompt three times.
    """
    headers = {
        "Authorization": f"Bearer {settings.mail_api_key}",
        "Accept": "application/json",
    }
    async with httpx.AsyncClient(timeout=settings.mail_timeout_seconds) as client:
        created = await client.post(
            BROADCASTS_ENDPOINT,
            headers=headers,
            json={
                "audience_id": settings.resend_audience_id,
                "from": settings.mail_from,
                "subject": subject,
                "html": html,
                "text": plain,
            },
        )
        if created.status_code >= 300:
            raise RuntimeError(f"resend refused the broadcast: HTTP {created.status_code}")
        broadcast_id = created.json().get("id")
        if not broadcast_id:
            raise RuntimeError("resend returned no broadcast id")

        sent = await client.post(f"{BROADCASTS_ENDPOINT}/{broadcast_id}/send", headers=headers)
        if sent.status_code >= 300:
            raise RuntimeError(f"resend refused to send {broadcast_id}: HTTP {sent.status_code}")

    return str(broadcast_id)
