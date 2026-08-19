"""The marketing list, which lives at Resend and not here.

**There is no `subscribers` table and this file creates no rows.** Settled Aug 16, 2026 by the
owner, per `decisions.md` open item 12(4) and D8: Resend owns suppression, unsubscribe and
sending reputation, and `POST /v1/subscribe` is a thin forward that stores nothing. A subscriber
is not a `users` row and has no row anywhere in this schema.

**Resend does *not* own double opt-in, and this file said it did until Aug 18, 2026.** Its
contacts API creates a contact live, sends nothing, and offers no confirmation step — observed
against the real API, after the first genuine signup arrived already `Subscribed` while the
marketing page was promising a link to click. Phase 87 moved the confirmation here: the contact
is created unsubscribed and a signed link flips it. **Still no rows** — see
`services/subscribe_token.py` for how a confirmation is remembered without remembering anything.

**The named trigger for bringing it in-house is the first moment a subscriber can also be a
user**, which is post-launch. Migrating a list is a CSV export; migrating a half-built consent
system is not, which is the whole reason for starting on the provider's side.

The dedup problem that returns on that day is untouched and still real: Sign in with Apple
private relay means `users.email` may never match the address given to the marketing site, so
the two populations cannot be joined on an address. `data-model.md` records what will need
specifying.
"""

from __future__ import annotations

import logging
from urllib.parse import quote

import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.marketing")

CONTACTS_ENDPOINT = "https://api.resend.com/audiences/{audience_id}/contacts"


class MarketingUnavailable(RascalError):
    """The list could not be reached, or is not configured. `503`, never a silent success.

    **Accepting an address we cannot store is the failure to avoid.** A `202` that quietly
    dropped the signup would make the marketing page look like it worked, and nobody would
    find out until somebody asked why the list was empty.
    """

    def __init__(self, message: str) -> None:
        super().__init__(ErrorCode.INTERNAL_ERROR, message, status_code=503)


def normalise(email: str) -> str:
    """Lowercased and trimmed. Two rows differing only in case would be two contacts."""
    return email.strip().lower()


async def add_contact(email: str, settings: Settings) -> None:
    """Put an address on the list. Idempotent as far as this caller is concerned.

    **Resend answers the same way for an address already on the list**, which is exactly the
    behaviour the endpoint needs: `POST /v1/subscribe` must not become an oracle that tells any
    caller whether a given address is subscribed. There is no branch here on "already exists"
    because there is no answer this function is allowed to give differently.

    **Created unsubscribed, which is what makes this a double opt-in.** Resend's contacts API
    does not run a confirmation of its own — a contact posted with `unsubscribed: false` is
    live immediately, and this docstring used to say the opposite. That was written from the
    documentation and was wrong in the way this repository keeps warning about: the first real
    signup, on Aug 18 2026, landed as `Subscribed` with no confirmation mail anywhere, while
    the marketing page promised a link to click.

    So the contact starts unsubscribed and `confirm` is the only thing that flips it. A
    broadcast expands to subscribed contacts only, so an address nobody confirmed is never
    mailed — the gate enforces itself at Resend rather than needing to be remembered here.
    """
    if not settings.mail_api_key:
        log.error("resend api key is unset, so signups cannot be stored")
        raise MarketingUnavailable("Signups are not being accepted right now.")
    if not settings.resend_audience_id:
        log.error("resend audience id is unset, so signups cannot be stored")
        raise MarketingUnavailable("Signups are not being accepted right now.")

    url = CONTACTS_ENDPOINT.format(audience_id=settings.resend_audience_id)
    headers = {
        "Authorization": f"Bearer {settings.mail_api_key}",
        "Accept": "application/json",
    }
    # **`true` is the create state**, and it is the whole of the opt-in gate. See the docstring.
    payload = {"email": email, "unsubscribed": True}

    try:
        async with httpx.AsyncClient(timeout=settings.mail_timeout_seconds) as client:
            response = await client.post(url, json=payload, headers=headers)
    except httpx.HTTPError as exc:
        # **No retry.** A cron may retry; a request handler must not sit on a socket, and the
        # caller is a browser waiting on a form submit.
        log.warning("resend unreachable", extra={"reason": str(exc)})
        raise MarketingUnavailable("Could not save that just now. Try again shortly.") from exc

    if response.status_code >= 300:
        # The address is never logged. An address in a log line is the address leaving the
        # system by a path nobody audited.
        log.warning("resend refused a contact", extra={"status": response.status_code})
        raise MarketingUnavailable("Could not save that just now. Try again shortly.")

    log.info("marketing contact added")


async def confirm_contact(email: str, settings: Settings) -> None:
    """Flip a contact from unsubscribed to subscribed. The click, applied.

    **Idempotent, and it has to be.** Mail clients prefetch links, people double-click, and the
    token stays valid for its whole life. Resend answers a `PATCH` the same way whether the
    contact was already subscribed or not, so there is no branch here and no second answer to
    leak.

    **Keyed by address rather than by contact id**, which is what keeps this module stateless:
    holding an id would mean storing one, and storing one is the subscriber table this design
    exists to avoid. Verified against the live API on Aug 18, 2026 —
    `PATCH /audiences/{id}/contacts/{email}` returns `200` and the following `GET` reads
    `"unsubscribed": false`.
    """
    if not settings.mail_api_key:
        log.error("resend api key is unset, so a confirmation cannot be applied")
        raise MarketingUnavailable("Signups are not being accepted right now.")
    if not settings.resend_audience_id:
        log.error("resend audience id is unset, so a confirmation cannot be applied")
        raise MarketingUnavailable("Signups are not being accepted right now.")

    url = f"{CONTACTS_ENDPOINT.format(audience_id=settings.resend_audience_id)}/{quote(email)}"
    headers = {
        "Authorization": f"Bearer {settings.mail_api_key}",
        "Accept": "application/json",
    }

    try:
        async with httpx.AsyncClient(timeout=settings.mail_timeout_seconds) as client:
            response = await client.patch(url, json={"unsubscribed": False}, headers=headers)
    except httpx.HTTPError as exc:
        log.warning("resend unreachable for a confirmation", extra={"reason": str(exc)})
        raise MarketingUnavailable("Could not confirm that just now. Try again shortly.") from exc

    if response.status_code >= 300:
        # No address in the log line, the same rule `add_contact` follows.
        log.warning("resend refused a confirmation", extra={"status": response.status_code})
        raise MarketingUnavailable("Could not confirm that just now. Try again shortly.")

    log.info("marketing contact confirmed")
