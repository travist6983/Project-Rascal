"""`POST /v1/subscribe` — the marketing signup, and the first browser client this API has had.

**Unauthenticated, and Turnstile is the entire protection.** There is no rate limit on this
route, by the owner's call of Aug 16, 2026 (`decisions.md` open item 12(1)) — so
`services/turnstile.verify` failing closed is not one defence among several, it is the defence.

**Nothing is stored here.** The list is Resend's, per open item 12(4); there is no `subscribers`
table and this router creates no rows.
"""

from __future__ import annotations

import logging
from urllib.parse import urlencode

from fastapi import APIRouter, BackgroundTasks, Query, Request, status
from fastapi.responses import RedirectResponse
from pydantic import Field, field_validator

from rascal.config import Settings
from rascal.deps import SettingsDep
from rascal.schemas.common import ApiModel
from rascal.services import marketing, subscribe_token, turnstile
from rascal.services.mail import send

log = logging.getLogger("rascal.subscribe")

router = APIRouter(tags=["marketing"])


class SubscribeRequest(ApiModel):
    #: A shape check and not a validation. **No `EmailStr`** — that pulls in `email-validator`,
    #: and rule 4 of the stack is settled. The server cannot tell a real inbox from a
    #: well-formed one anyway; Resend's double opt-in is what actually decides, and a
    #: confirmation nobody clicks is the check that matters.
    email: str = Field(min_length=3, max_length=320)
    #: Cloudflare's widget response. Absent is a rejection, never a skip.
    turnstile_token: str | None = Field(default=None, max_length=4096)
    #: Which page or campaign. Cheap to record now and impossible to reconstruct later — but it
    #: goes no further than a log line, because the contact belongs to Resend.
    source: str | None = Field(default=None, max_length=100)

    @field_validator("email")
    @classmethod
    def _looks_like_an_address(cls, value: str) -> str:
        trimmed = value.strip()
        local, _, domain = trimmed.partition("@")
        if not local or not domain or "." not in domain or " " in trimmed:
            raise ValueError("That does not look like an email address.")
        return trimmed


class SubscribeResponse(ApiModel):
    """**Identical for every outcome that is not an outage.**

    New address, already subscribed, already unsubscribed — all `202` with this body. Anything
    else turns the route into an oracle that tells any caller whether a given address is on the
    list, and anyone with a browser is a caller.
    """

    status: str = "ok"


@router.post(
    "/subscribe",
    response_model=SubscribeResponse,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Join the mailing list",
)
async def subscribe(
    payload: SubscribeRequest,
    request: Request,
    settings: SettingsDep,
    background: BackgroundTasks,
) -> SubscribeResponse:
    """Verify the human, add an unsubscribed contact, then mail them a link to confirm.

    `202` rather than `201`: nothing was created *here*, and the subscription is not real until
    they click. Saying `created` would be a claim this service cannot make.

    **The mail goes out after the response**, the same shape `POST /auth/email/start` uses and
    for the same reason — a provider being slow must not become a browser waiting on a form,
    and delivery must not be able to change the answer.
    """
    await turnstile.verify(payload.turnstile_token, settings, remote_ip=_client_ip(request))
    address = marketing.normalise(payload.email)
    await marketing.add_contact(address, settings)
    background.add_task(_deliver_confirmation, settings, address)
    return SubscribeResponse()


async def _deliver_confirmation(settings: Settings, address: str) -> None:
    """Send one confirmation link, after the response has gone out.

    **Swallows its failure deliberately**, exactly as `_deliver_sign_in_link` does: there is no
    caller left to tell, and letting it escape would put a traceback in the logs for ordinary
    provider flakiness. The contact is already on the list as unsubscribed, so a failure here
    costs a confirmation rather than the signup — they can submit the form again.
    """
    token = subscribe_token.create(address, settings)
    link = f"{settings.subscribe_confirm_link_base}?{urlencode({'token': token})}"
    try:
        await send(
            settings,
            # **Transactional, not marketing** — D3a. This is the message that *establishes*
            # consent, so gating it on consent would be circular: nobody could ever opt in.
            stream="transactional",
            to=address,
            subject="Confirm your Vellum subscription",
            text=(
                "Tap to confirm you want the daily question from Vellum.\n\n"
                f"{link}\n\n"
                f"The link works for {settings.subscribe_confirm_ttl_days} days. If you did "
                "not ask for this, ignore it — nothing will be sent to you."
            ),
        )
    except Exception:
        # No address in the log line — an address in a log is the address leaving the system by
        # a path nobody audited.
        log.warning("confirmation link could not be delivered", exc_info=True)


@router.get(
    "/subscribe/confirm",
    status_code=status.HTTP_307_TEMPORARY_REDIRECT,
    summary="Confirm a subscription from an emailed link",
    response_class=RedirectResponse,
)
async def confirm(
    settings: SettingsDep, token: str | None = Query(default=None, max_length=4096)
) -> RedirectResponse:
    """Apply a confirmation and send the browser back to the site.

    **Always a redirect, never JSON, including on failure.** A person opening this has clicked a
    link in their mail client; showing them `{"error": …}` would be showing an API response to
    somebody who has no idea they are talking to an API. The outcome travels as a query
    parameter so the page can say the right sentence.

    **Unauthenticated by necessity** — the token is the credential, and holding it is the proof
    that the address receives mail. That is the whole of what double opt-in asks.

    **`token` is optional so that a missing one is a redirect too.** Required, FastAPI's own
    validation answers `422 application/json` before this function runs — the exact raw-JSON
    page the paragraph above exists to prevent, and reachable in practice: link scanners and
    some mail clients truncate a URL at the `?`, and so does a half-copied paste. Found against
    the deployed route by the marketing lane, which tested the endpoint rather than the
    description of it. Absent and invalid get the same answer for the same reason the other four
    cases were collapsed into one.
    """
    site = settings.marketing_site_url.rstrip("/")
    if token is None:
        return RedirectResponse(f"{site}/?confirmed=0", status_code=status.HTTP_303_SEE_OTHER)

    try:
        address = subscribe_token.read(token, settings)
        await marketing.confirm_contact(address, settings)
    except subscribe_token.ConfirmTokenInvalid:
        return RedirectResponse(f"{site}/?confirmed=0", status_code=status.HTTP_303_SEE_OTHER)
    except marketing.MarketingUnavailable:
        # Resend is down or unconfigured. **Distinct from a bad token**, because this one is
        # ours and is worth retrying — the link is still good.
        log.warning("a confirmation could not be applied")
        return RedirectResponse(f"{site}/?confirmed=retry", status_code=status.HTTP_303_SEE_OTHER)

    return RedirectResponse(f"{site}/?confirmed=1", status_code=status.HTTP_303_SEE_OTHER)


def _client_ip(request: Request) -> str | None:
    """The caller's address, for Turnstile's optional `remoteip`.

    **`X-Forwarded-For`'s *last* hop, not its first.** Fly appends the real peer, and anything
    earlier in that header is whatever the client chose to send — trusting the first entry hands
    the caller control of the value. Absent is fine: `remoteip` is optional to Cloudflare, and a
    wrong one is worse than none.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        hops = [hop.strip() for hop in forwarded.split(",") if hop.strip()]
        if hops:
            return hops[-1]
    return request.client.host if request.client else None
