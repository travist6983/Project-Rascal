"""The household, its guardians, and the invite that adds one."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import GuardianRole, Tier
from rascal.schemas.common import ApiModel


class GuardianOut(ApiModel):
    user_id: uuid.UUID
    # Nullable everywhere it comes from: a parent who signed in with Apple's private relay
    # and skipped onboarding has never told us a name.
    display_name: str | None = None
    role: GuardianRole
    #: **Nullable.** A household member with no guardian row — a household whose only child
    #: was deleted, or a member mid-accept — has no grant date, and a fabricated one would be
    #: a confident wrong timestamp on a screen.
    granted_at: dt.datetime | None = None
    #: True for the caller, so a client can render "you" without comparing ids itself.
    is_you: bool = False


class FamilyOut(ApiModel):
    family_id: uuid.UUID
    tier: Tier
    guardians: list[GuardianOut]
    #: Outstanding invites, so the client can show "waiting for them to accept" and offer to
    #: withdraw it. Accepted, revoked and expired invites are not listed — they are history,
    #: and this is a screen about the household as it is now.
    pending_invites: list[InviteOut] = Field(default_factory=list)


class EntitlementOut(ApiModel):
    """What a household is entitled to, and when its media stops being kept.

    Separate from `FamilyOut` rather than folded into it, and both read the same
    `entitlements` row through `services/guardians.entitlement_for` — so there is one
    authority over "is this household subscribed" and two shapes of it, not two answers.
    `FamilyOut` is the household screen (who is here, who has been asked); this is the
    subscription screen.
    """

    family_id: uuid.UUID
    tier: Tier
    #: When the subscription lapsed. Null on a household that has never subscribed as well as
    #: on one that currently is — `tier` is what tells those apart.
    lapsed_at: dt.datetime | None = None
    #: **A date, computed per request, never stored.** `max(lapsed_at + 24 months,
    #: last_sign_in_at + 12 months)` per D3, where `last_sign_in_at` is a MAX across the
    #: household's guardians. Both clocks move, so a client may display this and **must not
    #: cache it**. Null while `tier` is `subscribed`.
    eligible_at: dt.date | None = None
    #: Where original media is stored. **A constant `hot` today**: D3's move to the Tigris
    #: Archive tier at 90 days lapsed is phase 38, `media` has no `storage_tier` column yet,
    #: and reporting the field now means the client that will show it does not need a second
    #: shape later. It is not a read.
    media_storage_tier: str = "hot"


class InviteCreate(ApiModel):
    #: Optional. An invite may be a bare link handed over in person; when present it is only
    #: recorded, because nothing in this phase sends the email.
    email: str | None = Field(default=None, max_length=320)
    #: Only `parent` is issuable. `viewer` is phase 30 and iceboxed.
    role: GuardianRole = "parent"


class InviteOut(ApiModel):
    id: uuid.UUID
    email: str | None = None
    role: GuardianRole
    expires_at: dt.datetime
    created_at: dt.datetime


class InviteCreated(InviteOut):
    """The one response that carries the raw token, and the only time it exists.

    Only the SHA-256 is stored, so this value is not recoverable afterwards. A lost link is
    re-issued rather than looked up.
    """

    token: str


class InvitePreview(ApiModel):
    """What an unauthenticated caller may learn from a link before signing in.

    Enough to know the link is real and who it is from — and nothing more. No user ids, no
    birthdates, no counts, no email addresses.
    """

    invited_by: str | None = None
    role: GuardianRole
    expires_at: dt.datetime
    #: First names only. A stranger holding a mistyped link learns two first names, which is
    #: the least that still lets the right person recognise the household as theirs.
    children: list[str]


class InviteAccepted(ApiModel):
    family_id: uuid.UUID
    children: list[uuid.UUID]
