"""The household invite, as an email.

**Phase 136 exists because the invite never left the phone.** `POST /families/me/invites` has
accepted an `email` since phase 36 and has only ever *recorded* it — `api-contract.md` said so
in as many words, the client's own doc comment said *"nothing sends it"*, and the Settings row
told a parent they would "get a link to send". So the address a parent typed went into a column
and nowhere else, and the only delivery mechanism was the share sheet.

This module is the missing half: it renders that invite and hands it to `services.mail`, which
is where Resend already lives. **Nothing new talks to Resend.** `MAIL_PROVIDER` picks the
provider for every message this service sends, `console` is still the default, and an invite is
one more `Message` through the same port — which is the whole reason that port was built as its
own phase.

**Rendering is separated from sending** so the copy can be tested without a provider, the same
split `services.broadcast` uses. The palette is inlined from `docs/design-system.md` for the
reason stated there: an email has no stylesheet to share.
"""

from __future__ import annotations

import html
import logging

from rascal.config import Settings
from rascal.constants import INVITE_EXPIRY_DAYS
from rascal.services.mail import MailDeliveryError, send

log = logging.getLogger("rascal.invite_email")

#: Palette from `docs/design-system.md`, inlined for the same reason `broadcast.py` inlines it.
CANVAS = "#FDFAF4"
INK = "#23253C"
INK_MUTED = "#6E6A63"
TERRACOTTA = "#C05A2B"
RULE = "#E8E0D2"


def invite_link(settings: Settings, raw_token: str) -> str:
    """The URL that goes in the email. **The token is the whole secret**, so it rides in the
    path of a URL the app claims and nowhere else — no query string, no tracking parameter.
    """
    return f"{settings.invite_link_base.rstrip('/')}/{raw_token}"


def _household(children: list[str]) -> str:
    """ "Miles", "Miles and Nora", "Miles, Nora and Sam" — or "" when there are none yet.

    A household with no children is reachable: a parent can subscribe and invite before adding
    anybody, and phrasing that assumes a name would read as a bug to the one person who hits it.
    """
    names = [name.strip() for name in children if name.strip()]
    if not names:
        return ""
    if len(names) == 1:
        return names[0]
    return f"{', '.join(names[:-1])} and {names[-1]}"


def render(
    *, inviter: str | None, children: list[str], link: str, site_url: str
) -> tuple[str, str, str]:
    """Subject, plain text and HTML for one invite.

    **The subject never names a child and the body does.** An address typed by hand can be
    mistyped, and a subject line is the part that shows up on a lock screen — while the body is
    behind an inbox and discloses no more than `GET /invites/{token}` already discloses to
    whoever holds this link. That is the same trade the landing page makes.

    **Both parts, always.** A text alternative is a deliverability signal before it is a
    courtesy; an HTML-only message reads as bulk to the filters that decide whether an invite
    a parent is waiting for arrives at all.

    Tone is the app's, per `docs/design-system.md`: nothing counts down, nothing is red, and
    "you can ignore this" is a real option rather than a formality.
    """
    who = (inviter or "").strip() or "Someone"
    subject = f"{who} shared a child's archive with you"

    household = _household(children)
    opening = (
        f"{who} keeps a record of {household}'s childhood in Pocket Chronicle — one small "
        "thing a day, kept in one place."
        if household
        else f"{who} keeps a record of a childhood in Pocket Chronicle — one small thing a "
        "day, kept in one place."
    )
    # Not "expires in 7 days" as a countdown. It is a fact about the link, said once.
    terms = (
        f"The link works once, and for {INVITE_EXPIRY_DAYS} days. It opens in the Pocket "
        "Chronicle app on iPhone — if you do not have it yet, the page will say where to get it."
    )
    closing = (
        "If you were not expecting this, nothing has happened and you can ignore it. Nothing "
        "is shared until you open the link."
    )

    text = "\n\n".join(
        [
            opening,
            "This link adds you to the household, so you both keep the same archive:",
            link,
            terms,
            closing,
            f"Pocket Chronicle — {site_url}",
        ]
    )

    # **Escaped on the way into the HTML part, not on the way into the column.** A display name
    # and a child's first name are typed by a parent and go into a document; an apostrophe in
    # "Nora's" is the common case and an angle bracket is the one that would matter. The text
    # part takes them raw, because there is no markup there to break out of.
    e_opening = html.escape(opening)
    e_link = html.escape(link, quote=True)
    e_terms = html.escape(terms)
    e_closing = html.escape(closing)
    e_site = html.escape(site_url, quote=True)

    markup = f"""<!doctype html>
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
          <td style="font-family:Georgia,'Times New Roman',serif;font-size:22px;
                     line-height:1.4;color:{INK};padding-bottom:16px;">
            {e_opening}
          </td>
        </tr>
        <tr>
          <td style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                     font-size:15px;line-height:1.6;color:{INK};padding-bottom:20px;">
            This link adds you to the household, so you both keep the same archive.
          </td>
        </tr>
        <tr>
          <td style="padding-bottom:20px;">
            <a href="{e_link}"
               style="display:inline-block;background:{TERRACOTTA};color:{CANVAS};
                      font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                      font-size:15px;font-weight:600;text-decoration:none;
                      padding:12px 20px;border-radius:999px;">Open the invitation</a>
          </td>
        </tr>
        <tr>
          <td style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                     font-size:13px;line-height:1.55;color:{INK_MUTED};padding-bottom:20px;
                     word-break:break-all;">
            Or paste this into a browser: {e_link}
          </td>
        </tr>
        <tr>
          <td style="border-top:1px solid {RULE};padding-top:16px;
                     font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                     font-size:13px;line-height:1.55;color:{INK_MUTED};">
            {e_terms}<br><br>{e_closing}<br><br>
            <a href="{e_site}" style="color:{INK_MUTED};">Pocket Chronicle</a>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>"""

    return subject, text, markup


async def deliver(
    settings: Settings,
    *,
    to: str,
    inviter: str | None,
    children: list[str],
    raw_token: str,
) -> None:
    """Send one invite. **Runs after the response, and swallows its own failure.**

    Queued rather than awaited for the reason `POST /auth/email/start` queues: a request handler
    that waits on a mail provider holds its database transaction across somebody else's network
    call, and hands the caller that provider's latency. There is no caller left to tell by the
    time this runs — which is survivable here in a way it is not elsewhere, because the invite's
    raw token went back in the `201` and the parent can always share the link themselves.

    The failure is logged **without the address**: an address in a log line is the address
    leaving the system by a path nobody audited.
    """
    subject, text, markup = render(
        inviter=inviter,
        children=children,
        link=invite_link(settings, raw_token),
        site_url=settings.marketing_site_url,
    )
    try:
        await send(
            settings,
            # Transactional, per D3a: it is a one-off message a person asked us to send to a
            # named address, it reads no consent column, and it is not the marketing list.
            stream="transactional",
            to=to,
            subject=subject,
            text=text,
            html=markup,
        )
    except MailDeliveryError:
        log.warning("household invite could not be delivered", exc_info=True)
    except Exception:  # pragma: no cover — a provider bug, not a delivery failure
        log.warning("household invite raised while sending", exc_info=True)


__all__ = ["deliver", "invite_link", "render"]
