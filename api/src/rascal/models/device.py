"""Where a notification goes, and the record that it went.

Two tables with opposite jobs. `devices` is mutable state — a token that re-registers every
launch, moves between accounts, and eventually dies. `notification_sends` is an append-only
ledger whose *unique index is the product guarantee*: one notification per user per day, and
a job that runs twice sends once.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import Date, ForeignKey, Index, Integer, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from rascal.constants import (
    DEVICE_PLATFORMS,
    PUSH_ENVIRONMENTS,
    DevicePlatform,
    PushEnvironment,
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


class Device(Base):
    """One row per APNs token. One user, many devices — phone today, iPad later.

    Unique on `(token, environment)` rather than on `token` alone, deliberately. The same
    64 hex characters can legitimately exist as both a sandbox and a production token, and
    they address different hosts; collapsing them onto one row would mean a TestFlight build
    silently overwrote the registration a development build made, or the reverse.

    `revoked_at` is the soft delete. Sign-out sets it, and so does APNs telling us a token is
    dead. Nothing is ever hard-deleted here, so a token that comes back — the same phone
    signing in again — updates the row it already had rather than growing a second one.
    """

    __tablename__ = "devices"
    __table_args__ = (
        UniqueConstraint("token", "environment", name="uq_devices_token_environment"),
        one_of("platform", DEVICE_PLATFORMS, name="platform"),
        one_of("environment", PUSH_ENVIRONMENTS, name="environment"),
        # The send job's only lookup: every live token for one user.
        Index("ix_devices_user_id", "user_id"),
    )

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    token: Mapped[str] = mapped_column(Text)
    platform: Mapped[DevicePlatform] = mapped_column(Text)
    environment: Mapped[PushEnvironment] = mapped_column(Text)
    # Written by the registration call, not by the trigger: it records when the *client* last
    # said this token is live, which is a different fact from when the row last changed.
    last_seen_at: Mapped[moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]
    revoked_at: Mapped[optional_moment]

    @property
    def is_live(self) -> bool:
        return self.revoked_at is None


class NotificationSend(Base):
    """One row per notification actually attempted. The unique index is the guarantee.

    `(user_id, notification_date)` is unique and the row is written with `ON CONFLICT DO
    NOTHING` *before* anything is sent, exactly the way assignments are written. That is what
    makes the job safe to run hourly, to re-run by hand, and to run twice concurrently: the
    second writer loses the insert and sends nothing, rather than reading "not sent yet" and
    racing the first one to the phone.

    `notification_date` is the date in the **child's `family_timezone`**, not UTC. A parent
    in Auckland whose 19:00 window is 07:00 UTC tomorrow gets one notification on their own
    Tuesday, not two straddling a UTC midnight.

    No `updated_at` and no soft delete: this is a system ledger, not user data. It never syncs
    to a client and there is nothing here to restore, which is the same reasoning that leaves
    `refresh_tokens` and `idempotency_keys` without them.
    """

    __tablename__ = "notification_sends"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "notification_date",
            name="uq_notification_sends_user_id_notification_date",
        ),
    )

    id: Mapped[uuid_pk]
    user_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    child_id: Mapped[uuid_fk] = mapped_column(ForeignKey("children.id", ondelete="CASCADE"))
    # The assignment the notification carried, for the client's deep link. Nullable and
    # SET NULL because the local-only debug routes hard-delete assignments, and losing the
    # link is not a reason to lose the record that a notification went out.
    assignment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("assignments.id", ondelete="SET NULL"), nullable=True
    )
    notification_date: Mapped[dt.date] = mapped_column(Date)
    # How many live tokens it was addressed to, and how many APNs accepted. A delivered count
    # that drifts below the device count is how a fleet of dead tokens becomes visible before
    # it becomes total.
    device_count: Mapped[int] = mapped_column(Integer, server_default="0")
    delivered_count: Mapped[int] = mapped_column(Integer, server_default="0")
    created_at: Mapped[created]
