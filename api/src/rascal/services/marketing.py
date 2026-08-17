"""The marketing list, which lives at Resend and not here.

**There is no `subscribers` table and this file creates no rows.** Settled Aug 16, 2026 by the
owner, per `decisions.md` open item 12(4) and D8: Resend owns double opt-in, suppression,
unsubscribe and sending reputation, and `POST /v1/subscribe` is a thin forward that stores
nothing. A subscriber is not a `users` row and has no row anywhere in this schema.

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

    Double opt-in is Resend's — a contact created here is unconfirmed until they click, and
    this service never sees that transition. That is the point of the list being provider-held.
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
    # `unsubscribed: false` is the create state. Resend runs the confirmation itself.
    payload = {"email": email, "unsubscribed": False}

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
