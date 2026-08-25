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

from sqlalchemy import CheckConstraint, ForeignKey, Index, Text
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
    no admin route that writes `tier`, and there is deliberately not going to be one.** The
    device still never decides whether a household is subscribed, for the same reason it never
    decides what day it is: a StoreKit transaction on the phone is a receipt, and the webhook is
    what turns one into an entitlement.

    **That sentence is about `tier` and only `tier`, which matters now that a neighbouring
    column does have one.** Phase 107 added `PUT /v1/admin/families/{id}/trial`, which writes
    `trial_ends_at` below. It reaches both the entitled and the free state without touching
    `tier` — which is exactly why the trial is the lever rather than a tier switch, and why
    adding one for `tier` is still forbidden rather than newly precedented.

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
    trial_ends_at: Mapped[optional_moment] = mapped_column(default=_default_trial_ends_at)
    updated_at: Mapped[updated]

    # **`is_subscribed` was here and phase 121 removed it rather than leaving it unused.** It
    # answered *"is somebody paying"* and its one caller was the guardian-invite paywall, which
    # now asks `services.guardians.Access.is_member` — *paying **or** granted*. A property that
    # still answered the old question, documented as the paywall's question, is the second
    # authority this file spends its docstring warning about: the next caller to reach for it
    # would give a complimentary household a 402.


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


class EntitlementGrant(Base):
    """A household entitled by somebody's decision rather than by a payment. **A ledger.**

    **Rows are additive and nothing is edited in place except a revocation.** Extending
    somebody is a new row, not an edit to the old one, which is what makes the grant history
    readable as history: *who was given what, when, why, and by whom*. There is deliberately
    **no unique constraint on `family_id`** — more than one grant per household is the intended
    shape rather than a state to prevent.

    **This table cannot make a household `subscribed` and does not try to.** `entitlements.tier`
    keeps exactly one writer — `POST /v1/webhooks/app-store`, per D5 — and a test asserts it.
    A grant is a *second, additive source of entitlement* that sits beside `tier` the way
    `trial_ends_at` does, and the union is computed in `services.guardians.access_for`. Nothing
    here is a reversal of D5: `tier` still means *what Apple said*, and a client reading it is
    still reading Apple.

    A grant is **active** when::

        revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())

    and the server's clock is what `now` means, for the same reason the server decides what day
    it is. The predicate lives in exactly one place — `services.grants.active_grants` — and is
    evaluated in SQL rather than in Python, so there is no second ordering comparison anywhere
    under `src/` for a reader to find and wonder about.

    **`expires_at` is nullable and null means perpetual**, not "a sentinel date far enough
    away". A founding tester is not entitled until 2099; they are entitled until somebody
    revokes it, and those are different rows to reason about.

    **`granted_by` and `revoked_by` are nullable, and that is a deliberate departure from the
    obvious shape.** They want to be NOT NULL — a grant that cannot say who issued it is not
    much of an audit record — but account deletion **hard-deletes** `users` rows (the one
    exception to the soft-delete rule, phase 66), so a NOT NULL column here needs an
    `ON DELETE` action and none of the three works: `CASCADE` destroys the ledger row, which is
    the opposite of an audit trail; `RESTRICT` makes an erasure request fail with an integrity
    error the deletion path has no branch for, which is a 500 in the one flow that must not have
    one; and `SET NULL` is what we want but cannot coexist with NOT NULL. So the column is
    nullable, `ON DELETE SET NULL`, and a null reads as *"the account that issued this has since
    been deleted"* — which is a true sentence rather than a missing value. The route always
    writes it, from the bearer token's subject and never from the request body, so null is only
    ever reachable by erasure. `prompt_library_overrides.created_by_user_id` made the same
    trade for the same reason.

    **No `deleted_at`, and this is not a second exception to the soft-delete rule.** That rule
    governs user data that syncs to a phone; nothing here syncs and no client can read this
    table. Withdrawing a grant is `revoked_at`, which *is* the soft delete — there is no
    `DELETE` on this table and no route that could issue one, because the record of who you
    gave something to and why is the part worth keeping.
    """

    __tablename__ = "entitlement_grants"
    __table_args__ = (
        # Free text, but not *empty* text. "Why does this household have this" is the whole
        # reason a ledger beats a boolean, and a blank reason is a row that answers nothing.
        CheckConstraint("length(btrim(reason)) > 0", name="reason"),
        Index("ix_entitlement_grants_family_id", "family_id"),
    )

    id: Mapped[uuid_pk]
    #: `CASCADE`, unlike `app_store_transactions.family_id`. A receipt outlives the household it
    #: paid for — Apple will still send a `REFUND` about it — but a grant is *about* a household
    #: and means nothing without one, so it goes when the household does.
    family_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("families.id", ondelete="CASCADE"))
    granted_at: Mapped[created]
    #: **Null means perpetual.** See the class docstring.
    expires_at: Mapped[optional_moment]
    #: Free text, non-empty by CHECK. `founding tester`, `refund goodwill`, `press`.
    reason: Mapped[str] = mapped_column(Text)
    #: The bearer token's subject at the moment of issue, never a field from the body.
    granted_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    revoked_at: Mapped[optional_moment]
    revoked_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    def status(self, now: dt.datetime) -> str:
        """`active` | `revoked` | `expired`, for the console.

        **Display only, and it must never become the gate.** The gate is one SQL predicate in
        `services.grants.active_grants`, evaluated against the database's own rows; this is that
        answer rendered for a person, computed from a row already in hand. They agree because
        this is the simpler half of the same rule, and the console reads what the API computed
        rather than deciding for itself.

        `revoked` outranks `expired` because it is the thing somebody *did* — a grant that was
        revoked in March and would have run out in June is a revocation, and reading it as an
        expiry loses the only part of that sentence with a person in it.
        """
        if self.revoked_at is not None:
            return "revoked"
        if self.expires_at is not None and self.expires_at <= now:
            return "expired"
        return "active"
