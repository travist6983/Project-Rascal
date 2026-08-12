"""Registering a phone for the one daily notification."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import DevicePlatform, PushEnvironment
from rascal.schemas.common import ApiModel


class DeviceRegistration(ApiModel):
    """What the client sends on every launch it holds a token.

    `environment` has **no default**, deliberately. A sandbox token and a production token
    are different tokens addressed to different APNs hosts, and sending to the wrong one
    fails silently — this is the single most common way push works in development and not in
    TestFlight. A default here would be a guess about which build is calling, and the client
    is the only thing that knows.
    """

    token: str = Field(description="The APNs device token, as hex.")
    platform: DevicePlatform = Field(
        description="`ios`. APNs is the only transport that exists; a browser would need "
        "WebPush, which is a different protocol and a different credential."
    )
    environment: PushEnvironment = Field(
        description="Which APNs host addresses this token, and it follows the "
        "`aps-environment` entitlement in the embedded provisioning profile rather than the "
        "distribution channel. `sandbox` for a build signed with a development profile — an "
        "Xcode-installed build. `production` for anything signed with a distribution "
        "profile, which is **TestFlight and the App Store alike**: TestFlight ships through "
        "App Store infrastructure and is not a separate APNs environment. Required — there "
        "is no safe default."
    )


class DeviceOut(ApiModel):
    id: uuid.UUID
    token: str
    platform: DevicePlatform
    environment: PushEnvironment
    last_seen_at: dt.datetime
    created_at: dt.datetime
    updated_at: dt.datetime
    # Soft delete, like every other user-data table. A revoked device syncs as a row with
    # this set, never as an absence.
    revoked_at: dt.datetime | None = None
