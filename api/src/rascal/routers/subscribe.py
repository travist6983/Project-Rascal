"""`POST /v1/subscribe` — the marketing signup, and the first browser client this API has had.

**Unauthenticated, and Turnstile is the entire protection.** There is no rate limit on this
route, by the owner's call of Aug 16, 2026 (`decisions.md` open item 12(1)) — so
`services/turnstile.verify` failing closed is not one defence among several, it is the defence.

**Nothing is stored here.** The list is Resend's, per open item 12(4); there is no `subscribers`
table and this router creates no rows.
"""

from __future__ import annotations

from fastapi import APIRouter, Request, status
from pydantic import Field, field_validator

from rascal.deps import SettingsDep
from rascal.schemas.common import ApiModel
from rascal.services import marketing, turnstile

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
    payload: SubscribeRequest, request: Request, settings: SettingsDep
) -> SubscribeResponse:
    """Verify the human, then hand the address to Resend. Store nothing.

    `202` rather than `201`: nothing was created here, and the subscription is not real until
    they click Resend's confirmation. Saying `created` would be a claim this service cannot make.
    """
    await turnstile.verify(payload.turnstile_token, settings, remote_ip=_client_ip(request))
    await marketing.add_contact(marketing.normalise(payload.email), settings)
    return SubscribeResponse()


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
