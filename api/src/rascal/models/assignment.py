"""What the scheduler served on a given day."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import CheckConstraint, Date, ForeignKey, Index, Text, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import (
    ASSIGNMENT_STATUSES,
    DAILY_SLOTS,
    SHARED_SLOTS,
    SLOTS,
    AssignmentStatus,
    Slot,
)
from rascal.models.base import Base, created, one_of, updated, uuid_fk, uuid_pk
from rascal.models.prompt import Prompt

_DAILY_PREDICATE = "slot IN (" + ", ".join(f"'{s}'" for s in DAILY_SLOTS) + ")"
_SHARED_PREDICATE = "slot IN (" + ", ".join(f"'{s}'" for s in SHARED_SLOTS) + ")"


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (
        # The scheduler's idempotency guarantee, in two halves since phase 36.
        #
        # **Daily slots are per-guardian**, so the key carries `user_id`. **Shared slots stay
        # one per child**, so their key does not mention `user_id` at all — and that is the
        # whole reason there are two partial indexes rather than one wide one. Postgres
        # treats NULLs as distinct in a unique index, so a single
        # `UNIQUE (child_id, user_id, assigned_on, slot)` would let the scheduler write
        # unlimited weekly rows for one child and day: every one has a NULL `user_id`, and
        # NULL never equals NULL. Idempotency would fail silently on exactly the slots
        # nobody checks daily.
        #
        # Anything reaching for ON CONFLICT against either of these must pass the matching
        # `index_where`; Postgres will not infer a partial index without it.
        Index(
            "uq_assignments_daily",
            "child_id",
            "user_id",
            "assigned_on",
            "slot",
            unique=True,
            postgresql_where=text(_DAILY_PREDICATE),
        ),
        Index(
            "uq_assignments_shared",
            "child_id",
            "assigned_on",
            "slot",
            unique=True,
            postgresql_where=text(_SHARED_PREDICATE),
        ),
        # A nullable column with no constraint is an invitation to write the wrong shape.
        CheckConstraint(
            f"({_DAILY_PREDICATE} AND user_id IS NOT NULL)"
            f" OR ({_SHARED_PREDICATE} AND user_id IS NULL)",
            name="user_id_by_slot",
        ),
        one_of("slot", SLOTS, name="slot"),
        one_of("status", ASSIGNMENT_STATUSES, name="status"),
        # Every assignment is either a library prompt or a parent-authored one-off.
        CheckConstraint(
            "(prompt_id IS NOT NULL) OR (custom_body IS NOT NULL)",
            name="prompt_or_custom_body",
        ),
        Index("ix_assignments_child_id_status_assigned_on", "child_id", "status", "assigned_on"),
    )

    id: Mapped[uuid_pk]
    child_id: Mapped[uuid_fk] = mapped_column(ForeignKey("children.id", ondelete="CASCADE"))
    # **Which guardian was served this.** NOT NULL for the three daily slots and NULL for the
    # three shared ones, enforced by `ck_assignments_user_id_by_slot` above. Two parents get
    # their own question, mission and mission_b; the weekly, monthly and letter belong to the
    # child and either parent completing one clears it for both.
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    prompt_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("prompts.id", ondelete="RESTRICT"), nullable=True
    )
    custom_body: Mapped[str | None] = mapped_column(Text, nullable=True)
    slot: Mapped[Slot] = mapped_column(Text)
    # Both dates are in the child's family_timezone, not UTC.
    assigned_on: Mapped[dt.date] = mapped_column(Date)
    expires_on: Mapped[dt.date] = mapped_column(Date)
    status: Mapped[AssignmentStatus] = mapped_column(Text, server_default="pending")
    completed_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    prompt: Mapped[Prompt | None] = relationship(lazy="raise")

    @property
    def resolved_body(self) -> str:
        """A parent-authored `custom_body` wins over the library prompt it replaced."""
        if self.custom_body is not None:
            return self.custom_body
        return self.prompt.body if self.prompt is not None else ""
