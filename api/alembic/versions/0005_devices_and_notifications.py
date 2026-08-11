"""devices, notification sends, and the notification preference on the user

Everything the one-per-day notification needs, and nothing it does not.

`devices` is unique on `(token, environment)` rather than on `token`, because a sandbox
token and a production token are different tokens addressed to different hosts, and the
same 64 characters can legitimately be both. Collapsing them would mean a TestFlight build
silently overwriting a development build's registration.

`notification_sends` exists for its unique index and almost nothing else. One row per user
per local day, written with `ON CONFLICT DO NOTHING` before anything is sent, exactly the
way `assignments` guarantees the scheduler is free to re-run.

`users.notify_local_time` is `time without time zone` deliberately: it is a wall-clock time
read in the *child's* `family_timezone`, so an offset stored alongside it would pin the
preference to wherever the parent happened to be standing and would drift an hour against
DST twice a year.

Revision ID: 0005_devices_and_notifications
Revises: 0004_full_text_search
Create Date: 2026-08-11
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005_devices_and_notifications"
down_revision: str | None = "0004_full_text_search"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Kept as a literal rather than read from `rascal.models.base`, for the reason 0001 now
# spells out: a migration is pinned to the schema at its own point in history.
TABLES_WITH_UPDATED_AT_ADDED_HERE = ("devices",)


def upgrade() -> None:
    # Off by default. The client turns notifications on after the parent grants OS
    # permission, never before.
    op.add_column(
        "users",
        sa.Column("notify_enabled", sa.Boolean(), server_default=sa.text("false"), nullable=False),
    )
    op.add_column(
        "users",
        sa.Column(
            "notify_local_time",
            sa.Time(timezone=False),
            server_default=sa.text("'19:00:00'"),
            nullable=False,
        ),
    )

    op.create_table(
        "devices",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("environment", sa.Text(), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("platform IN ('ios')", name=op.f("ck_devices_platform")),
        sa.CheckConstraint(
            "environment IN ('sandbox', 'production')", name=op.f("ck_devices_environment")
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_devices_user_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_devices")),
        sa.UniqueConstraint("token", "environment", name="uq_devices_token_environment"),
    )
    # The send job's only lookup: every live token for one user.
    op.create_index("ix_devices_user_id", "devices", ["user_id"], unique=False)

    op.create_table(
        "notification_sends",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("child_id", sa.UUID(), nullable=False),
        sa.Column("assignment_id", sa.UUID(), nullable=True),
        sa.Column("notification_date", sa.Date(), nullable=False),
        sa.Column("device_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("delivered_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_notification_sends_user_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["child_id"],
            ["children.id"],
            name=op.f("fk_notification_sends_child_id"),
            ondelete="CASCADE",
        ),
        # SET NULL rather than CASCADE: the local-only debug routes hard-delete assignments,
        # and losing a deep link is not a reason to lose the record that a send happened —
        # which is the row the once-per-day guarantee rests on.
        sa.ForeignKeyConstraint(
            ["assignment_id"],
            ["assignments.id"],
            name=op.f("fk_notification_sends_assignment_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_notification_sends")),
        # The whole point of the table.
        sa.UniqueConstraint(
            "user_id",
            "notification_date",
            name="uq_notification_sends_user_id_notification_date",
        ),
    )

    for table in TABLES_WITH_UPDATED_AT_ADDED_HERE:
        op.execute(
            f"CREATE TRIGGER trg_{table}_set_updated_at "
            f"BEFORE UPDATE ON {table} "
            f"FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
        )


def downgrade() -> None:
    # Dropping a table drops its triggers; set_updated_at() itself belongs to 0001.
    op.drop_table("notification_sends")
    op.drop_index("ix_devices_user_id", table_name="devices")
    op.drop_table("devices")
    op.drop_column("users", "notify_local_time")
    op.drop_column("users", "notify_enabled")
