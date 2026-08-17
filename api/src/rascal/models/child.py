"""The child, and who is allowed to see them."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import Date, ForeignKey, Index, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import GUARDIAN_ROLES, PRONOUNS, GuardianRole, Pronouns
from rascal.models.base import Base, created, one_of, optional_moment, updated, uuid_pk


class Child(Base):
    __tablename__ = "children"
    __table_args__ = (one_of("pronouns", PRONOUNS, name="pronouns"),)

    id: Mapped[uuid_pk]
    name: Mapped[str] = mapped_column(Text)
    birthdate: Mapped[dt.date] = mapped_column(Date)
    # Nullable, and null means unanswered rather than "they/them". Onboarding may skip the
    # question, and a renderer has to be able to fall back rather than assert something the
    # parent never said. See docs/decisions.md open item 10.
    pronouns: Mapped[Pronouns | None] = mapped_column(Text, nullable=True)
    avatar_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    # IANA, e.g. America/Detroit. The scheduler's definition of "today" — without it the 5am
    # job hands you tomorrow's mission at 9pm.
    family_timezone: Mapped[str] = mapped_column(Text)
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    guardians: Mapped[list[Guardian]] = relationship(
        back_populates="child", cascade="all, delete-orphan"
    )


class Guardian(Base):
    """`parent` reads and writes, `viewer` reads only. Revoked rows stay for the audit trail."""

    __tablename__ = "guardians"
    __table_args__ = (
        one_of("role", GUARDIAN_ROLES, name="role"),
        # `pk_guardians` leads with `user_id`, so it cannot serve "who guards this child".
        # Phase 36's scheduler asks exactly that, once per child per run.
        Index("ix_guardians_child_id", "child_id"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    child_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("children.id", ondelete="CASCADE"), primary_key=True
    )
    role: Mapped[GuardianRole] = mapped_column(Text)
    granted_at: Mapped[created]
    revoked_at: Mapped[optional_moment]

    child: Mapped[Child] = relationship(back_populates="guardians")
