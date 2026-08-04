"""What the scheduler served on a given day."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import CheckConstraint, Date, ForeignKey, Index, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import ASSIGNMENT_STATUSES, SLOTS, AssignmentStatus, Slot
from rascal.models.base import Base, created, one_of, updated, uuid_fk, uuid_pk
from rascal.models.prompt import Prompt


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (
        # The scheduler's idempotency guarantee. Reruns must be free.
        UniqueConstraint(
            "child_id", "assigned_on", "slot", name="uq_assignments_child_id_assigned_on_slot"
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
