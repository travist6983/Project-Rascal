"""Webhooks: unauthenticated in the bearer sense, authenticated by signature.

Designed beside `POST /webhooks/app-store` (`docs/api-contract.md:934`), which is specified and
unbuilt. They may ship apart; they must not be designed apart, because they share the property
that makes both dangerous — **no bearer token, so the signature is the only thing standing
between a stranger and a write.** Every route here verifies before it does anything, and an
unverifiable payload is refused rather than logged and accepted.

Both are also retried by their sender until they get a 2xx, which decides how they answer:
anything correctly received is a 2xx even when the answer is "nothing to do". A 4xx is a
promise to handle something later, and a 5xx is a request to be told again.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, status

from rascal.deps import SessionDep, get_apple_verifier
from rascal.schemas.auth import AppleNotificationRequest
from rascal.services.apple import AppleVerifier
from rascal.services.apple_events import apply_notification

router = APIRouter(prefix="/webhooks", tags=["webhooks"])


@router.post(
    "/apple-signin",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Apple Sign in with Apple server-to-server notification",
    description=(
        "Unauthenticated in the bearer sense and authenticated by signature: the body carries "
        "a JWT signed by Apple, verified against Apple's JWKS with the same cached fetcher the "
        "sign-in route uses.\n\n"
        "Four events. `consent-revoked` and `account-delete` are **identical** — both revoke "
        "the credential and every refresh token on the account, and neither touches the "
        "archive: Apple is telling us an Apple ID is gone, not that a childhood is. Signing in "
        "again with the same Apple ID clears the revocation and lands on the same account. "
        "`email-disabled` and `email-enabled` set `users.email_deliverable`.\n\n"
        "Always `202` once the signature verifies, including for an event type or a subject "
        "this service does not know — Apple retries anything that is not a 2xx, and answering "
        "404 for an unknown subject would tell an unauthenticated caller which Apple IDs have "
        "accounts here. An unverifiable payload is `401`."
    ),
)
async def apple_signin_notification(
    payload: AppleNotificationRequest,
    session: SessionDep,
    verifier: AppleVerifier = Depends(get_apple_verifier),
) -> dict[str, str]:
    event = await verifier.verify_notification(payload.payload)
    outcome = await apply_notification(session, event)
    # The outcome is named in the body because the only other way to find out what a webhook
    # did is to read the logs of a machine you may not be able to reach.
    return {"status": outcome}
