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

from sqlalchemy import DateTime, ForeignKey, Index, Text
from sqlalchemy.orm import Mapped, mapped_column

from rascal.constants import GUARDIAN_ROLES, TIERS, TRIAL_DAYS, GuardianRole, Tier
from rascal.models.base import (
    Base,
    created,
    moment,
    one_of,
    optional_moment,
    updated,
    uuid_pk,
)


def _default_trial_ends_at() -> dt.datetime:
    """`now + 14 days`, evaluated at INSERT rather than at import.

    A module-level constant would freeze the trial at the moment the process started, which
    on a long-lived Fly machine means every household created that week gets the same expiry
    and the last of them gets no trial at all.
    """
    return dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=TRIAL_DAYS)


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

    **`trial_ends_at` is the trial, and there is no `trial` tier.** Phase 107 made entitlement
    a computed thing — `tier` and `trial_ends_at` together, through
    `services.guardians.access_for` — precisely so the trial did not have to become a second
    writer of the column above. Reading `tier` on its own still means exactly what it always
    meant, which is what keeps every existing client working.

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
    #: When this household's free trial runs out. **The trial is a column, not a tier** — see
    #: the note on `tier` above and `constants.Tier`.
    #:
    #: Defaulted here rather than in :func:`services.guardians.create_household` so that every
    #: construction of this row gets a trial: the household factory, the test factories, and
    #: anything written later. A default that lives in one caller is a default the second
    #: caller silently does without, and the failure mode is a real family landing on the free
    #: tier because of where their row happened to be created.
    #:
    #: **Nullable, and null is a real state rather than a missing value.** It means *no trial
    #: on this household* — which is what the admin console's one lever produces when it clears
    #: the date, and what a household reads forever after somebody uses it. It is not "the
    #: trial ended at a time nobody recorded".
    #:
    #: Nothing reads this column directly to decide entitlement. `services.guardians.access_for`
    #: is the only thing that turns it and `tier` into an answer.
    trial_ends_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, default=_default_trial_ends_at
    )
    updated_at: Mapped[updated]

    @property
    def is_subscribed(self) -> bool:
        """`tier` alone, and deliberately **not** the entitlement question.

        This answers *"is somebody paying"*, which is what the guardian-invite paywall asks
        (D4 sells the second parent on a subscription, and a trial does not add one). *"May
        this household reach today's missions"* is a different question with a different
        answer during a trial, and it is :func:`services.guardians.access_for`. Do not
        collapse the two — a caller that wants entitlement and reads this gets a free-tier
        answer for a household inside its trial.
        """
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
