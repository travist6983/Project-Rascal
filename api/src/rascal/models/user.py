"""Identity: the user, the credentials that authenticate them, and their refresh tokens."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import Boolean, ForeignKey, Index, Text, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import CREDENTIAL_PROVIDERS, CredentialProvider
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
    # Nullable on purpose: Apple relay addresses are unreliable and may never arrive.
    email: Mapped[str | None] = mapped_column(Text, nullable=True)
    display_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The mission library is content, authored server-side. Without this, any future `viewer`
    # login could write to it.
    is_admin: Mapped[bool] = mapped_column(Boolean, server_default=text("false"))
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    credentials: Mapped[list[Credential]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class Credential(Base):
    """One row per identity provider. Adding password or Google auth adds rows, not columns."""

    __tablename__ = "credentials"
    __table_args__ = (
        UniqueConstraint("provider", "subject_id", name="uq_credentials_provider_subject_id"),
        one_of("provider", CREDENTIAL_PROVIDERS, name="provider"),
    )

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[CredentialProvider] = mapped_column(Text)
    subject_id: Mapped[str] = mapped_column(Text)
    created_at: Mapped[created]

    user: Mapped[User] = relationship(back_populates="credentials")


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
