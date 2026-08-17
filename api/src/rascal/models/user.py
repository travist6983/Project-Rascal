"""Identity: the user, the credentials that authenticate them, and their refresh tokens."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Text, Time, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import (
    CREDENTIAL_PROVIDERS,
    DEFAULT_NOTIFY_LOCAL_TIME,
    CredentialProvider,
    SignInTokenPurpose,
)
from rascal.models.base import (
    Base,
    created,
    moment,
    one_of,
    optional_moment,
    updated,
    uuid_fk,
    uuid_pk,
)


class User(Base):
    """A stable UUID. Sign in with Apple is a row in `credentials`, never this."""

    __tablename__ = "users"

    id: Mapped[uuid_pk]
    # **The household this user belongs to.** NOT NULL since phase 36 — every user has a
    # family, even a household of one, because a nullable owner means every read of an
    # entitlement has to answer "and what if there isn't one" and one of those reads will
    # eventually answer it wrong. Created with the user; see `services/guardians.py`.
    #
    # `ON DELETE RESTRICT`: deleting a family out from under a user is not a thing that
    # should be possible by accident, and D3's deletion flow removes users first.
    family_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("families.id", ondelete="RESTRICT"), index=True
    )
    # Nullable on purpose: Apple relay addresses are unreliable and may never arrive.
    email: Mapped[str | None] = mapped_column(Text, nullable=True)
    display_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The mission library is content, authored server-side. Without this, any future `viewer`
    # login could write to it.
    is_admin: Mapped[bool] = mapped_column(Boolean, server_default=text("false"))

    # The notification preference lives on the user, not on the child: one human decides when
    # their own phone buzzes, and a second guardian on the same child is a second phone with a
    # second opinion. Per-child preferences would be a matrix nobody asked for.
    #
    # Defaults to off. The client turns it on *after* the parent grants notification
    # permission at the OS level, never before — a server that assumes consent it was never
    # told about is how an app gets deleted.
    notify_enabled: Mapped[bool] = mapped_column(Boolean, server_default=text("false"))
    # A wall-clock time with no zone, read in the **child's** `family_timezone` — not the
    # user's device timezone and not UTC. `time without time zone` is exactly right for that:
    # storing an offset here would pin the preference to wherever the parent stood when they
    # set it, and it would drift an hour against DST twice a year.
    notify_local_time: Mapped[dt.time] = mapped_column(
        Time(timezone=False),
        server_default=text(f"'{DEFAULT_NOTIFY_LOCAL_TIME.isoformat()}'"),
    )

    # **The activity clock, and it is here rather than on the entitlement because it cannot be
    # backfilled.** D3 computes deletion eligibility as
    # `max(lapsed_at + 24 months, last_sign_in_at + 12 months)`, and `data-model.md` specifies
    # the family-level value as "most recent sign-in by **any** guardian" — which is a `MAX`
    # over exactly this column. Recording it per user is therefore strictly more information
    # than the entitlement row needs, and the entitlement's copy is a denormalisation of it.
    #
    # **A lapse date can be derived later; this cannot.** Nobody can reconstruct when a parent
    # last opened the app from any other row, so every day this column does not exist is a day
    # of the record that is gone. That is why it lands before the table it was specified on —
    # the household entity belongs to phase 37 and is blocked on an account action.
    #
    # Null means "never observed", which is not the same as "long ago": a user created before
    # this column existed has no history, and treating null as ancient would make the oldest
    # accounts the first deleted. Every read must handle it explicitly.
    last_sign_in_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    # **Two lanes, never one flag** — per D3a, and the reason is a request nobody has made yet.
    # Untangling a single "emails" boolean into consent-for-marketing and consent-for-required-
    # notices, under a GDPR or CCPA request, after both meanings have been written into it, is
    # the failure this shape exists to avoid. It costs one extra column now.
    #
    # Win-back only, and it must have a working unsubscribe. Defaults on, which is the soft
    # opt-in D3a describes — at most three emails in six months, to a household that already
    # had an account.
    marketing_consent: Mapped[bool] = mapped_column(Boolean, server_default=text("true"))
    # Deletion warnings, and **deliberately not settable through the API.** D3's hard stop is
    # that deletion may not fire unless a notice was confirmed delivered; a user who could
    # switch this off would silence the warning and leave the timer running, which converts a
    # safety interlock into a way to lose an archive quietly. It is a column so the two lanes
    # are separable in the record, not so it can be toggled.
    transactional_consent: Mapped[bool] = mapped_column(Boolean, server_default=text("true"))

    # **Not a third consent lane — the two above are what the parent chose, this is whether
    # the channel physically works.** A Sign in with Apple private relay can be switched off
    # from Settings at any time, and when it is, mail is simply never forwarded again: no
    # bounce, no error, nothing. D3's hard stop is that deletion may not fire without a notice
    # confirmed delivered, and without this column that silence is indistinguishable from
    # success. Written only by Apple's `email-disabled`/`email-enabled` notifications; read by
    # phase 38, which is what turns it into a refusal to delete.
    email_deliverable: Mapped[bool] = mapped_column(Boolean, server_default=text("true"))

    created_at: Mapped[created]
    updated_at: Mapped[updated]

    credentials: Mapped[list[Credential]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class Credential(Base):
    """One row per identity provider. Adding password or Google auth adds rows, not columns.

    **The unique constraint deliberately ignores `revoked_at`.** A revoked credential keeps
    holding its `(provider, subject_id)` namespace, so signing in again with the same subject
    matches *this* row and therefore this user. Freeing the namespace on revocation would let
    a later sign-in mint a second user and orphan the archive behind the first — which is the
    one failure in this table that cannot be undone by the person it happens to.
    """

    __tablename__ = "credentials"
    __table_args__ = (
        UniqueConstraint("provider", "subject_id", name="uq_credentials_provider_subject_id"),
        one_of("provider", CREDENTIAL_PROVIDERS, name="provider"),
    )

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[CredentialProvider] = mapped_column(Text)
    subject_id: Mapped[str] = mapped_column(Text)
    # A soft revocation, and never a delete. Set by `DELETE /me/credentials/{id}` and by
    # Apple's `consent-revoked` notification; cleared by signing in with the same subject
    # again, which is what makes revocation recoverable rather than terminal.
    revoked_at: Mapped[optional_moment]
    created_at: Mapped[created]
    # Added in phase 52 with `revoked_at`, because a revocation that does not move a cursor is
    # a change no client can learn about. Written by the `set_updated_at()` trigger.
    updated_at: Mapped[updated]

    user: Mapped[User] = relationship(back_populates="credentials")

    @property
    def is_active(self) -> bool:
        return self.revoked_at is None


class RefreshToken(Base):
    """Server-side refresh tokens so a lost phone can be cut off.

    Only the SHA-256 of the opaque token is stored; the raw value exists in exactly one
    response body and never again. Presenting a token revokes it and issues a new pair.
    """

    __tablename__ = "refresh_tokens"
    __table_args__ = (Index("ix_refresh_tokens_token_hash", "token_hash"),)

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    token_hash: Mapped[str] = mapped_column(Text)
    expires_at: Mapped[moment]
    revoked_at: Mapped[optional_moment]
    created_at: Mapped[created]

    def is_live(self, now: dt.datetime) -> bool:
        return self.revoked_at is None and self.expires_at > now


class EmailSignInToken(Base):
    """One magic link. Single use, fifteen minutes, and only its hash is stored.

    **Keyed on the credential rather than the user**, because the link belongs to the address
    it was sent to. Revoking that credential invalidates every outstanding link to it with no
    second statement, and a link for a revoked address is refused by a join that already
    exists — which is what stops a removed sign-in method from being quietly reusable.
    """

    __tablename__ = "email_sign_in_tokens"
    __table_args__ = (Index("ix_email_sign_in_tokens_token_hash", "token_hash", unique=True),)

    id: Mapped[uuid_pk]
    credential_id: Mapped[uuid_fk] = mapped_column(ForeignKey("credentials.id", ondelete="CASCADE"))
    # SHA-256. The raw value exists in one email and never again — same rule as
    # `refresh_tokens`, so a database dump is not a set of working keys.
    token_hash: Mapped[str] = mapped_column(Text)
    # **Only a `verify` token may clear `revoked_at`.** A `sign_in` link that could reactivate
    # a credential the parent removed would make Remove a suggestion rather than an action.
    purpose: Mapped[SignInTokenPurpose] = mapped_column(Text, server_default=text("'sign_in'"))
    expires_at: Mapped[moment]
    # A timestamp rather than a boolean, so a replay can be told apart from an unused link.
    consumed_at: Mapped[optional_moment]
    created_at: Mapped[created]

    def is_live(self, now: dt.datetime) -> bool:
        return self.consumed_at is None and self.expires_at > now


class RateLimitEvent(Base):
    """One recorded attempt, for the per-email and per-IP limits on `/auth/email/start`.

    **In Postgres rather than in memory, and that is not a preference.** There is more than
    one Fly machine, so an in-process counter is per-process theatre — the real limit would be
    N times looser than it reads and would reset on every deploy.

    `bucket` is `email:<address>` or `ip:<addr>`. Generic on purpose: a third limiter later is
    a new prefix rather than a new table.
    """

    __tablename__ = "rate_limit_events"
    __table_args__ = (Index("ix_rate_limit_events_bucket_created_at", "bucket", "created_at"),)

    id: Mapped[uuid_pk]
    bucket: Mapped[str] = mapped_column(Text)
    created_at: Mapped[created]


class IdempotencyKey(Base):
    """Replay protection for `POST /entries` and `POST /sync/push`.

    A retry has to return the original 201 body, not a second row and not a 409, so the
    original response is stored verbatim and replayed. Keys are scoped to the user.
    """

    __tablename__ = "idempotency_keys"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    key: Mapped[str] = mapped_column(Text, primary_key=True)
    endpoint: Mapped[str] = mapped_column(Text)
    response_status: Mapped[int]
    response_body: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[created]
