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
