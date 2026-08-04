"""The child, and who is allowed to see them."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import Date, ForeignKey, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import GUARDIAN_ROLES, GuardianRole
from rascal.models.base import Base, created, one_of, optional_moment, updated, uuid_pk


class Child(Base):
    __tablename__ = "children"

    id: Mapped[uuid_pk]
    name: Mapped[str] = mapped_column(Text)
    birthdate: Mapped[dt.date] = mapped_column(Date)
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
    __table_args__ = (one_of("role", GUARDIAN_ROLES, name="role"),)

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
