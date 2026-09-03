"""The App Store Server Notifications V2 request body, and the client-submitted transaction."""

from __future__ import annotations

from pydantic import Field

from rascal.schemas.common import ApiModel
from rascal.schemas.family import FamilyOut


class AppStoreNotificationRequest(ApiModel):
    """Apple's V2 notification body: one field, holding a JWS.

    **The wire name is `signedPayload`, camelCase, and it is Apple's to choose.** The alias is
    what makes that true regardless of anything this repository does about naming; the
    attribute stays snake_case so it reads like the rest of the codebase.
    """

    signed_payload: str = Field(min_length=1, alias="signedPayload")


class SubmittedTransactionRequest(ApiModel):
    """`POST /families/me/transactions` — the JWS StoreKit 2 hands the app for a transaction.

    Snake case on the wire, unlike Apple's body above, because this is our field rather than
    Apple's: the client puts `Transaction.jwsRepresentation` into it verbatim.
    """

    signed_transaction: str = Field(min_length=1)


class SubmittedTransactionOut(ApiModel):
    """What the submission did, and the household as it stands afterwards.

    `status` uses the webhook's vocabulary (`tier:subscribed`, `ignored:not-active`, …) so a
    log line from either door reads the same. `family` is the exact `GET /families/me` shape,
    carried here so a client that has just been told `subscribed` does not need a second
    request to render it — and cannot be told `subscribed` by anything but that document.
    """

    status: str
    family: FamilyOut
