"""A parent asking to be forgotten."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import ForeignKey, Index, text
from sqlalchemy.orm import Mapped, mapped_column

from rascal.models.base import Base, created, moment, optional_moment, updated, uuid_pk


class DeletionRequest(Base):
    """A pending, cancelled or completed request to delete an account.

    **A state, not a queue.** The grace period has to be visible — to the parent, who may change
    their mind, and to anybody wondering on day six why an archive is still here.

    The row is `ON DELETE CASCADE` from `users`, so it goes when the person does. That is the
    point of the feature rather than an oversight: a record keyed to somebody who asked to be
    forgotten is the thing an erasure request is about. What survives is a log line that
    identifies nobody.
    """

    __tablename__ = "deletion_requests"
    __table_args__ = (
        # At most one *pending* request per user. Cancelled and completed rows are history and
        # sit outside the constraint, because "ask, change your mind, ask again a year later"
        # is a state a parent can genuinely reach.
        Index(
            "uq_deletion_requests_pending",
            "user_id",
            unique=True,
            postgresql_where=text("cancelled_at IS NULL"),
        ),
        Index(
            "ix_deletion_requests_due",
            "execute_after",
            postgresql_where=text("cancelled_at IS NULL"),
        ),
    )

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    requested_at: Mapped[created]
    #: Stored rather than computed: a request made under a seven-day policy must run on the
    #: terms it was made under, however the constant moves later.
    execute_after: Mapped[moment]
    cancelled_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    #: **There is no `completed_at`.** A completed deletion has no row — it cascades away with
    #: the user — so pending is simply "not cancelled", and completion is the row's absence.
    @property
    def is_pending(self) -> bool:
        return self.cancelled_at is None

    def is_due(self, now: dt.datetime) -> bool:
        return self.is_pending and self.execute_after <= now
