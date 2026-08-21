"""The household: who shares an archive, who pays for it, and who has been asked to join.

**The family is the unit of entitlement and nothing else.** It does not own children —
`guardians` already says who may reach a child, and that is still the only authorization
input. A family exists so that "one price for the whole household" has something to hang on,
per D4, and so a second parent can be invited into a group rather than onto a list of
children one at a time.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import ForeignKey, Index, Text
from sqlalchemy.orm import Mapped, mapped_column

from rascal.constants import GUARDIAN_ROLES, TIERS, GuardianRole, Tier
from rascal.models.base import (
    Base,
    created,
    moment,
    one_of,
    optional_moment,
    updated,
    uuid_pk,
)


class Family(Base):
    """A household. Deliberately almost empty — it is an identity, not a record."""

    __tablename__ = "families"

    id: Mapped[uuid_pk]
    created_at: Mapped[created]
    updated_at: Mapped[updated]


class Entitlement(Base):
    """What a household is entitled to. **One row per family, keyed on the family.**

    Per D4 entitlement is a family-level attribute, never per-user and never per-child, so
    `family_id` is the primary key rather than a foreign key beside a surrogate id. There is
    no shape of this table that can hold two opinions about one household.

    **`tier` has exactly one writer: `services/app_store_events.py`**, reached only from
    `POST /v1/webhooks/app-store`. D5 reserves the column for App Store Server Notifications V2
    and phase 37a built that; a test asserts there is exactly one assignment to `.tier` anywhere
    under `src/`, so a second writer fails the suite rather than quietly appearing.

    `docs/runbook-deploy.md` §7a — a hand-run SQL statement — is the manual override, and the
    owner's own household is `subscribed` by one with no Apple transaction behind it. **There is
    no admin route and there is deliberately not going to be one.** The device still never
    decides whether a household is subscribed, for the same reason it never decides what day it
    is: a StoreKit transaction on the phone is a receipt, and the webhook is what turns one into
    an entitlement.

    `last_sign_in_at` is deliberately **not** here. `data-model.md` describes it as a
    denormalisation of `users.last_sign_in_at` that must never be written independently, and
    a column whose only correct value is a MAX over another table — before anything computes
    that MAX — is a column that drifts.
    """

    __tablename__ = "entitlements"
    __table_args__ = (one_of("tier", TIERS, name="tier"),)

    family_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("families.id", ondelete="CASCADE"), primary_key=True
    )
    tier: Mapped[Tier] = mapped_column(Text, server_default="free")
    # Nullable: a family can be `free` with nobody paying. A lapsed family keeps the payer
    # who lapsed, so a win-back knows who to talk to.
    payer_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    lapsed_at: Mapped[optional_moment]
    updated_at: Mapped[updated]

    @property
    def is_subscribed(self) -> bool:
        return self.tier == "subscribed"


class GuardianInvite(Base):
    """An offer to join a household, good for seven days.

    **Only the SHA-256 is stored**, the rule `refresh_tokens` and `email_sign_in_tokens`
    already follow: the raw token exists in one link and never again, so a database dump
    cannot hand somebody a working key to an archive.

    `accepted_at` and `revoked_at` are timestamps rather than booleans for the same reason
    `consumed_at` is on the sign-in token — a replay can be told apart from a link that was
    never used, and *when* somebody joined a household is the sort of thing you want back.
    """

    __tablename__ = "guardian_invites"
    __table_args__ = (
        one_of("role", GUARDIAN_ROLES, name="role"),
        Index("ix_guardian_invites_token_hash", "token_hash", unique=True),
        Index("ix_guardian_invites_family_id", "family_id"),
    )

    id: Mapped[uuid_pk]
    family_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("families.id", ondelete="CASCADE"))
    invited_by_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    token_hash: Mapped[str] = mapped_column(Text)
    # Nullable — an invite may be a bare link handed over in person rather than addressed.
    email: Mapped[str | None] = mapped_column(Text, nullable=True)
    role: Mapped[GuardianRole] = mapped_column(Text, server_default="parent")
    expires_at: Mapped[moment]
    accepted_at: Mapped[optional_moment]
    accepted_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    revoked_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    # **No `inviter` relationship on purpose.** There are three FKs to `users` on this table,
    # so any relationship here needs an explicit `foreign_keys=`, and the one caller that
    # wants the inviter's name (`GET /invites/{token}`) is unauthenticated and reads exactly
    # one field. A `session.get(User, ...)` there is one query either way and cannot surprise
    # anybody with a lazy load on an async session.

    def is_open(self, now: dt.datetime) -> bool:
        """Still acceptable: not revoked, not already accepted, not past its expiry."""
        return self.revoked_at is None and self.accepted_at is None and self.expires_at > now
