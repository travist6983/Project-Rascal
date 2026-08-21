"""The App Store Server Notifications V2 request body."""

from __future__ import annotations

from pydantic import Field

from rascal.schemas.common import ApiModel


class AppStoreNotificationRequest(ApiModel):
    """Apple's V2 notification body: one field, holding a JWS.

    **The wire name is `signedPayload`, camelCase, and it is Apple's to choose.** The alias is
    what makes that true regardless of anything this repository does about naming; the
    attribute stays snake_case so it reads like the rest of the codebase.
    """

    signed_payload: str = Field(min_length=1, alias="signedPayload")
