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

**Nothing sends until `MARKETING_EMAIL_ENABLED=true`.** ~~Open item 12 repeats in every line that
touches this work: no marketing email before the P0 behavioural gate.~~ — **the owner lifted that
gate on Aug 22, 2026; the flag is set on `rascal-api` and this job has been sending daily since
Aug 19.** The flag itself is unchanged and still defaults to off, because setting a mail credential
must not also start mailing a list. Everything below runs in full without it — the send is the one
withheld step.
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass
from typing import Final

import httpx
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.models.email_broadcast import EmailBroadcast
from rascal.models.prompt import Prompt
from rascal.services import prompt_tokens
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

#: **The prompt card, in the one tint the pool can honestly wear.**
#:
#: `design-system.md` resolves tint by kind — periwinkle for questions, voice and written
#: entries; terracotta for anything that asks you to go make something. **All thirty pool
#: prompts are questions answered by writing**, so the card is periwinkle and the completion
#: reads *"Wrote it"*, and neither is a guess. If the pool ever gains a mission, this constant
#: becomes a lookup and `email-sequence.md` has to carry the kind — the pool is thirty bare
#: strings today and carries no metadata at all.
#:
#: The site renders the identical card from `seeds/prompts.yaml`, so the two agree by sharing
#: a palette rather than by one copying the other. **None of the thirty is in that library** —
#: checked, zero of thirty match a body — which is why there is no prompt number here: the
#: site's `#31` is a per-kind index into the library and this pool has no position in it.
#: **Kind → tint, and it is the app's rule rather than a third opinion.** `design-system.md`:
#: periwinkle for questions, voice and written entries; terracotta for anything that asks you to
#: go make something; sage for measurement, because what it produces is a completed fact rather
#: than media. `Rascal-Marketing/scripts/prompts.mjs` renders the identical card from the same
#: seed with the same table — three surfaces agreeing by sharing a palette, not by copying.
TERRACOTTA_SOFT = "#FBEDE2"
TERRACOTTA_DEEP = "#9A431E"
SAGE_SOFT = "#DCE8DA"
SAGE_INK = "#4B7A4F"
SAGE_BORDER = "#D8E4D5"
PERIWINKLE_SOFT = "#E9EBFB"
PERIWINKLE_BORDER = "#DADDF7"
PERIWINKLE_DEEP = "#3F4FB0"
#: The site's chip is `rgba(85, 102, 214, 0.12)` over the card. **Email cannot composite a
#: translucent fill reliably**, so it is flattened against `PERIWINKLE_SOFT` here — the same
#: colour arrived at by arithmetic rather than by eye.
CHIP_BG = "#D7DBF7"
CHIP_BG_TERRA = "#F3DFD1"
CHIP_BG_SAGE = "#CFE0CC"
RULE = "#E8E0D2"

#: A terracotta fill keeps the cream hairline — `design-system.md` is explicit that there is no
#: terracotta hairline token to reach for, and that the pairing is deliberate.
BORDER_CREAM = "#E8E0D2"

#: label, card fill, hairline, chip fill, chip ink.
KIND_STYLE: Final[dict[str, tuple[str, str, str, str, str]]] = {
    "question": ("Question", PERIWINKLE_SOFT, PERIWINKLE_BORDER, CHIP_BG, PERIWINKLE_DEEP),
    "audio": ("Voice", PERIWINKLE_SOFT, PERIWINKLE_BORDER, CHIP_BG, PERIWINKLE_DEEP),
    "photo": ("Photo", TERRACOTTA_SOFT, BORDER_CREAM, CHIP_BG_TERRA, TERRACOTTA_DEEP),
    "video": ("Video", TERRACOTTA_SOFT, BORDER_CREAM, CHIP_BG_TERRA, TERRACOTTA_DEEP),
    "activity": ("Activity", TERRACOTTA_SOFT, BORDER_CREAM, CHIP_BG_TERRA, TERRACOTTA_DEEP),
    "letter": ("Letter", TERRACOTTA_SOFT, BORDER_CREAM, CHIP_BG_TERRA, TERRACOTTA_DEEP),
    "measurement": ("Measurement", SAGE_SOFT, SAGE_BORDER, CHIP_BG_SAGE, SAGE_INK),
}

#: What finishing it looks like. The same three words the site prints and the app uses.
SHAPE_LABEL: Final[dict[str, str]] = {
    "media": "Captured it",
    "text": "Wrote it",
    "did_it": "Did it",
}

#: **The subscriber has no child**, so there is no name and no pronouns to render with. The
#: marketing site solved this first and this matches it exactly: the they/them column, which is
#: grammatical for every child and is not a guess at an answer nobody gave, and a neutral
#: stand-in for `{name}`. `prompt_tokens.render` returns the they/them column for a null
#: pronoun by design, so the null is passed rather than the string.
NAME_STANDIN = "your kid"


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


def render(prompt: str, footer: str, site_url: str, kind: str, shape: str) -> tuple[str, str]:
    """The prompt as HTML and as plain text.

    **Both parts, always.** A `text/plain` alternative is a deliverability signal rather than a
    courtesy, and a mail that is HTML-only reads as bulk to the filters that decide whether any
    of this arrives at all.

    Table-based layout with inline styles, because email clients are what they are: no external
    stylesheet, no web font, no image, and nothing that could be a tracking pixel. Comfortably
    under Gmail's 102KB clipping threshold, which matters because what gets clipped is the
    bottom — and the bottom is the unsubscribe.

    **The prompt is drawn as the card it is everywhere else** — kind chip, body, completion
    line, tinted by kind with the hairline the palette names for that fill. It was a bare serif
    paragraph until phase 90, which read as a newsletter rather than as the product, and the card
    is the one piece of Vellum's design a subscriber meets before installing anything.

    **`kind` and `shape` come from the prompt, never from a constant.** An earlier draft of this
    phase hardcoded `Question`/`Wrote it`, which was true only while the send drew from the
    thirty-question pool. Sending the real library means five kinds a day, and a photo mission
    labelled *Question* would be a lie drawn in the product's own type.

    **Radius degrades rather than breaks.** Older Outlook ignores `border-radius` and renders
    square corners; every other property here is understood everywhere, and a square card is a
    card. Nothing is conditional on a client, and there is no VML fallback — one that renders
    slightly plainer in one client is not worth a second code path in a mail nobody can inspect.
    """
    label, fill, hairline, chip_bg, chip_ink = KIND_STYLE.get(kind, KIND_STYLE["question"])
    shape_label = SHAPE_LABEL.get(shape, "")

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
          <td style="padding-bottom:28px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
                   style="background:{fill};border:1px solid {hairline};
                          border-radius:20px;">
              <tr>
                <td style="padding:16px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                      <td style="background:{chip_bg};border-radius:999px;padding:4px 10px;
                                 font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                                 font-size:11px;font-weight:600;letter-spacing:0.6px;
                                 text-transform:uppercase;color:{chip_ink};">
                        {label}
                      </td>
                    </tr>
                  </table>
                  <div style="font-family:Georgia,'Times New Roman',serif;font-size:22px;
                              line-height:1.4;color:{INK};padding-top:14px;">
                    {prompt}
                  </div>
                  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                              font-size:13px;line-height:1.55;color:{INK_MUTED};padding-top:12px;">
                    {shape_label}
                  </div>
                </td>
              </tr>
            </table>
          </td>
        </tr>
        <tr>
          <td style="border-top:1px solid {RULE};padding-top:16px;
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
    # The plain part carries the same three pieces in the order the card shows them. It is a
    # deliverability signal before it is a courtesy, so it must not become a stub.
    text = f"{label.upper()}\n\n{prompt}\n\n{shape_label}\n\n---\n\n{text_footer}\n"
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
        return "MARKETING_EMAIL_ENABLED is false, so the send is withheld"
    if not settings.mail_api_key:
        return "MAIL_API_KEY is unset"
    if not settings.resend_audience_id:
        return "RESEND_AUDIENCE_ID is unset"
    return f"MAIL_FROM is still {settings.mail_from!r}, which is not a verified sending domain"


async def pick_prompt(session: AsyncSession, day_of_year: int) -> tuple[int, Prompt] | None:
    """Today's prompt, from the **seeded library** rather than from the copy file's pool.

    **This is the reversal of `decisions.md` open item 12(3), made by the owner on Aug 18, 2026.**
    That item chose a separate thirty-prompt pool precisely to avoid two problems the library has:
    bodies are pronoun-tokenised, and every one of the 133 carries an age band. It called them
    *"untouched and still real"*, returning *"the day a personalized daily send is wanted"*.

    Both are now answered rather than avoided:

    - **Pronouns.** `services/prompt_tokens.py` exists as of phase 83 and is a cell-for-cell port
      of the iOS table. A null pronoun renders the they/them column by design, so a subscriber
      with no child gets correct English rather than a placeholder.
    - **Age.** Not solved, and deliberately not pretended otherwise. Every prompt in the library
      carries a band and the narrowest still starts at 24 months, so a daily send to somebody
      with no child on file cannot be targeted. **Cadence is respected even though age is not**,
      because cadence is a property of the prompt rather than of the reader: a monthly letter and
      a yearly measurement are not daily prompts, and sending one daily would misrepresent the
      product rather than merely mistarget it.

    That leaves 111 daily prompts across five kinds — 30 question, 42 photo, 12 voice, 11 video,
    16 activity — where the pool was 30 questions and nothing else.

    **Ordered by `created_at, id` and picked modulo the count**, which keeps the two properties
    the pool version had: the same date always yields the same prompt, and nothing has to be
    remembered between runs for that to be true.
    """
    rows = (
        await session.scalars(
            select(Prompt)
            # `prompts` is seeded reference data and has no soft-delete column; `active` is how
            # `seed_prompts` retires a body the file no longer contains.
            .where(Prompt.active.is_(True), Prompt.cadence == "daily")
            .order_by(Prompt.created_at, Prompt.id)
        )
    ).all()
    if not rows:
        return None
    index = (day_of_year - 1) % len(rows)
    # The index travels with the prompt because it is what the ledger stores: the owner may edit
    # the library, and a row recording only the text could not later be told apart from a row
    # whose text has since changed.
    return index, rows[index]


async def daily_prompt_count(session: AsyncSession) -> int:
    """How many prompts the daily send draws from. For `--show`, which reports a position."""
    return int(
        await session.scalar(
            select(func.count())
            .select_from(Prompt)
            .where(Prompt.active.is_(True), Prompt.cadence == "daily")
        )
        or 0
    )


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

    picked = await pick_prompt(session, day.timetuple().tm_yday)
    if picked is None:
        raise AlreadySent(f"{day} has no daily prompt to send — the library is empty")
    index, chosen = picked

    # **Rendered here because the server is the last reader.** There is no client between this
    # and an inbox, which is the same exception `prompt_tokens` is scoped to for APNs.
    prompt = prompt_tokens.render(chosen.body, name=NAME_STANDIN, pronouns=None)
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

    html, plain = render(
        prompt,
        text.footer,
        settings.marketing_site_url,
        chosen.kind,
        chosen.completion_mode,
    )

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
