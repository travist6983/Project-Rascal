"""Webhooks: unauthenticated in the bearer sense, authenticated by signature.

**Both routes here are now built** — `POST /webhooks/apple-signin` since phase 55, and
`POST /webhooks/app-store` as of phase 37a. They were designed together and not merely shipped
together, because they share the property that makes both dangerous — **no bearer token, so
the signature is the only thing standing between a stranger and a write.** Every route here
verifies before it does anything, and an unverifiable payload is refused rather than logged
and accepted.

The App Store hook is the more dangerous of the two: a forged Sign in with Apple notification
revokes a session, which a parent recovers from by signing in again, while a forged App Store
notification writes billing state.

Both are also retried by their sender until they get a 2xx, which decides how they answer:
anything correctly received is a 2xx even when the answer is "nothing to do". A 4xx is a
promise to handle something later, and a 5xx is a request to be told again.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, status

from rascal.deps import SessionDep, SettingsDep, get_app_store_verifier, get_apple_verifier
from rascal.errors import ErrorCode, RascalError
from rascal.schemas.app_store import AppStoreNotificationRequest
from rascal.schemas.auth import AppleNotificationRequest
from rascal.services.app_store import (
    AppStoreVerifier,
    NotificationUnverifiable,
)
from rascal.services.app_store_events import apply_notification as apply_app_store_notification
from rascal.services.apple import AppleVerifier
from rascal.services.apple_events import apply_notification

log = logging.getLogger("rascal.webhooks")

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


@router.post(
    "/app-store",
    status_code=status.HTTP_202_ACCEPTED,
    summary="App Store Server Notification V2",
    description=(
        "Unauthenticated in the bearer sense and authenticated by signature: the body carries "
        "`signedPayload`, a JWS whose `x5c` chain must terminate at the bundled **Apple Root "
        "CA - G3** and whose leaf must actually sign the payload. An unverifiable payload is "
        "`401`.\n\n"
        "**This is the only path that may set `entitlements.tier`.** A subscribe, a renewal, a "
        "cancellation, a billing failure and a refund all arrive here, which is what keeps one "
        "authority over the answer.\n\n"
        "Always `202` once the signature verifies — including for unknown notification types, "
        "unknown subtypes and families this server does not recognise. Apple retries anything "
        "that is not a 2xx, so a 4xx is a promise to handle something later, and for a real "
        "notification it is an entitlement that silently never lands."
    ),
)
async def app_store_notification(
    body: AppStoreNotificationRequest,
    session: SessionDep,
    settings: SettingsDep,
    verifier: AppStoreVerifier = Depends(get_app_store_verifier),
) -> dict[str, str]:
    """Verify, then record, then perhaps write a tier. **Never the other way round.**

    The two statements below are the whole security model of this endpoint: nothing reaches
    `apply_app_store_notification` except the return value of `verifier.verify`, and that
    method has no branch that returns on a failed signature.

    `NotificationUnverifiable` is caught here and nowhere else, and it is caught narrowly on
    purpose — a broad `except` around this body would turn a database error into a `202`,
    which tells Apple the notification landed when it did not.
    """
    try:
        note = verifier.verify(body.signed_payload)
    except NotificationUnverifiable as exc:
        # Deliberately terse to the caller. What failed is in the logs; telling an
        # unauthenticated stranger which check their forgery tripped is a tuning signal.
        log.warning("app store notification failed verification", extra={"reason": str(exc)})
        raise RascalError(
            ErrorCode.UNAUTHENTICATED, "This notification could not be verified."
        ) from exc

    outcome = await apply_app_store_notification(
        session, note, service_environment=settings.environment
    )
    # Named in the body for the same reason the Apple hook does it: the only other way to
    # find out what a webhook did is to read the logs of a machine you may not be able to
    # reach — **and logged here as well, since phase 140.** `recorded:no-tier-change` was the
    # one outcome no guard logged, so an evening of `202`s with the household still `free` left
    # nothing in the logs to read; the body Apple received is not something Fly shows.
    log.info(
        "app store notification applied",
        extra={
            "outcome": outcome,
            "type": note.notification_type,
            "subtype": note.subtype,
            "environment": note.environment,
            "original_transaction_id": note.original_transaction_id,
        },
    )
    return {"status": outcome}
