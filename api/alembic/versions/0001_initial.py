"""initial

The whole schema in one reversible migration.

Two things here cannot be expressed in SQLAlchemy metadata and so are written as raw SQL:
the ``set_updated_at()`` trigger that maintains every sync cursor, and the functional
On This Day index on ``(child_id, month(occurred_at), day(occurred_at))``.

Revision ID: 0001_initial
Revises:
Create Date: 2026-08-04
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

from rascal.models.base import TABLES_WITH_UPDATED_AT

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


# A bulk UPDATE run from psql at 11pm has to move the sync cursor too, or a client
# silently misses rows. That is why this is a trigger and not application code.
SET_UPDATED_AT = """
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
"""

# SQLAlchemy's Index() cannot express a functional index the way Postgres needs it.
#
# docs/data-model.md writes this as extract(... from occurred_at). Postgres rejects that on
# a timestamptz column — the result depends on the session TimeZone, so the expression is
# not IMMUTABLE and cannot be indexed. Pinning to UTC makes it immutable and indexable, and
# GET /children/{id}/moments extracts the same way, so index and query always agree.
ON_THIS_DAY_INDEX = """
CREATE INDEX ix_entries_child_month_day ON entries (
    child_id,
    (extract(month from occurred_at AT TIME ZONE 'UTC')),
    (extract(day from occurred_at AT TIME ZONE 'UTC'))
);
"""


def _attach_updated_at_triggers() -> None:
    for table in TABLES_WITH_UPDATED_AT:
        op.execute(
            f"CREATE TRIGGER trg_{table}_set_updated_at "
            f"BEFORE UPDATE ON {table} "
            f"FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
        )


def upgrade() -> None:
    op.execute(SET_UPDATED_AT)

    op.create_table(
        "children",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("birthdate", sa.Date(), nullable=False),
        sa.Column("avatar_key", sa.Text(), nullable=True),
        sa.Column("family_timezone", sa.Text(), nullable=False),
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
        sa.PrimaryKeyConstraint("id", name=op.f("pk_children")),
    )
    op.create_table(
        "prompts",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("cadence", sa.Text(), nullable=False),
        sa.Column("completion_mode", sa.Text(), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("theme", sa.Text(), nullable=False),
        sa.Column("min_age_months", sa.Integer(), nullable=False),
        sa.Column("max_age_months", sa.Integer(), nullable=False),
        sa.Column(
            "month_tags",
            sa.ARRAY(sa.Integer()),
            server_default=sa.text("'{}'::int[]"),
            nullable=False,
        ),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("default_unlock_age", sa.Integer(), nullable=True),
        sa.Column("active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("content_hash", sa.Text(), nullable=False),
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
        sa.CheckConstraint(
            "cadence IN ('daily', 'weekly', 'monthly')", name=op.f("ck_prompts_cadence")
        ),
        sa.CheckConstraint(
            "completion_mode IN ('did_it', 'media', 'text')",
            name=op.f("ck_prompts_completion_mode"),
        ),
        sa.CheckConstraint(
            "kind IN ('question', 'photo', 'video', 'audio', 'activity', 'measurement', 'letter')",
            name=op.f("ck_prompts_kind"),
        ),
        sa.CheckConstraint("source IN ('seeded', 'user', 'llm')", name=op.f("ck_prompts_source")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_prompts")),
    )
    op.create_index("ix_prompts_content_hash", "prompts", ["content_hash"], unique=True)
    op.create_index(
        "ix_prompts_kind_cadence_active_age",
        "prompts",
        ["kind", "cadence", "active", "min_age_months", "max_age_months"],
        unique=False,
    )
    op.create_table(
        "users",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("email", sa.Text(), nullable=True),
        sa.Column("display_name", sa.Text(), nullable=True),
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
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
    )
    op.create_table(
        "assignments",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("child_id", sa.UUID(), nullable=False),
        sa.Column("prompt_id", sa.UUID(), nullable=True),
        sa.Column("custom_body", sa.Text(), nullable=True),
        sa.Column("slot", sa.Text(), nullable=False),
        sa.Column("assigned_on", sa.Date(), nullable=False),
        sa.Column("expires_on", sa.Date(), nullable=False),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("completed_by", sa.UUID(), nullable=True),
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
        sa.CheckConstraint(
            "slot IN ('question', 'mission', 'weekly', 'monthly')", name=op.f("ck_assignments_slot")
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'done', 'dismissed', 'expired')",
            name=op.f("ck_assignments_status"),
        ),
        sa.CheckConstraint(
            "(prompt_id IS NOT NULL) OR (custom_body IS NOT NULL)",
            name=op.f("ck_assignments_prompt_or_custom_body"),
        ),
        sa.ForeignKeyConstraint(
            ["child_id"], ["children.id"], name=op.f("fk_assignments_child_id"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["completed_by"],
            ["users.id"],
            name=op.f("fk_assignments_completed_by"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["prompt_id"],
            ["prompts.id"],
            name=op.f("fk_assignments_prompt_id"),
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_assignments")),
        sa.UniqueConstraint(
            "child_id", "assigned_on", "slot", name="uq_assignments_child_id_assigned_on_slot"
        ),
    )
    op.create_index(
        "ix_assignments_child_id_status_assigned_on",
        "assignments",
        ["child_id", "status", "assigned_on"],
        unique=False,
    )
    op.create_table(
        "credentials",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "provider IN ('apple', 'google', 'password')", name=op.f("ck_credentials_provider")
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_credentials_user_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_credentials")),
        sa.UniqueConstraint("provider", "subject_id", name="uq_credentials_provider_subject_id"),
    )
    op.create_table(
        "guardians",
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("child_id", sa.UUID(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column(
            "granted_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("role IN ('parent', 'viewer')", name=op.f("ck_guardians_role")),
        sa.ForeignKeyConstraint(
            ["child_id"], ["children.id"], name=op.f("fk_guardians_child_id"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_guardians_user_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", "child_id", name=op.f("pk_guardians")),
    )
    op.create_table(
        "idempotency_keys",
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("endpoint", sa.Text(), nullable=False),
        sa.Column("response_status", sa.Integer(), nullable=False),
        sa.Column("response_body", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_idempotency_keys_user_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", "key", name=op.f("pk_idempotency_keys")),
    )
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_refresh_tokens_user_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_refresh_tokens")),
    )
    op.create_index("ix_refresh_tokens_token_hash", "refresh_tokens", ["token_hash"], unique=False)
    op.create_table(
        "tags",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("child_id", sa.UUID(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
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
        sa.ForeignKeyConstraint(
            ["child_id"], ["children.id"], name=op.f("fk_tags_child_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_tags")),
        sa.UniqueConstraint("child_id", "name", name="uq_tags_child_id_name"),
    )
    op.create_table(
        "entries",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("child_id", sa.UUID(), nullable=False),
        sa.Column("assignment_id", sa.UUID(), nullable=True),
        sa.Column("author_id", sa.UUID(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("child_age_months", sa.Integer(), nullable=False),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("body", sa.Text(), nullable=True),
        sa.Column("entry_type", sa.Text(), nullable=False),
        sa.Column("unlock_at_age", sa.Integer(), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "entry_type IN ('question', 'photo', 'video', 'audio', 'activity',"
            " 'measurement', 'letter', 'text')",
            name=op.f("ck_entries_entry_type"),
        ),
        sa.ForeignKeyConstraint(
            ["assignment_id"],
            ["assignments.id"],
            name=op.f("fk_entries_assignment_id"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["author_id"], ["users.id"], name=op.f("fk_entries_author_id"), ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["child_id"], ["children.id"], name=op.f("fk_entries_child_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_entries")),
    )
    op.create_index(
        "ix_entries_child_id_occurred_at",
        "entries",
        ["child_id", sa.literal_column("occurred_at DESC")],
        unique=False,
    )
    op.create_table(
        "entry_tags",
        sa.Column("entry_id", sa.UUID(), nullable=False),
        sa.Column("tag_id", sa.UUID(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
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
        sa.CheckConstraint("source IN ('user', 'device_ai')", name=op.f("ck_entry_tags_source")),
        sa.ForeignKeyConstraint(
            ["entry_id"], ["entries.id"], name=op.f("fk_entry_tags_entry_id"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["tag_id"], ["tags.id"], name=op.f("fk_entry_tags_tag_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("entry_id", "tag_id", name=op.f("pk_entry_tags")),
    )
    op.create_index("ix_entry_tags_tag_id", "entry_tags", ["tag_id"], unique=False)
    op.create_table(
        "media",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("entry_id", sa.UUID(), nullable=False),
        sa.Column("s3_key", sa.Text(), nullable=False),
        sa.Column("thumb_key", sa.Text(), nullable=True),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("captured_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("bytes", sa.BigInteger(), nullable=False),
        sa.Column("transcript", sa.Text(), nullable=True),
        sa.Column("caption", sa.Text(), nullable=True),
        sa.Column("upload_status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("s3_upload_id", sa.Text(), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
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
        sa.CheckConstraint("kind IN ('photo', 'video', 'audio')", name=op.f("ck_media_kind")),
        sa.CheckConstraint(
            "upload_status IN ('pending', 'complete', 'failed')",
            name=op.f("ck_media_upload_status"),
        ),
        sa.ForeignKeyConstraint(
            ["entry_id"], ["entries.id"], name=op.f("fk_media_entry_id"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_media")),
    )
    op.create_index("ix_media_entry_id", "media", ["entry_id"], unique=False)

    op.execute(ON_THIS_DAY_INDEX)
    _attach_updated_at_triggers()


def downgrade() -> None:
    # Dropping a table drops its triggers; the shared function has to go by hand.
    op.execute("DROP INDEX IF EXISTS ix_entries_child_month_day")

    op.drop_index("ix_media_entry_id", table_name="media")
    op.drop_table("media")
    op.drop_index("ix_entry_tags_tag_id", table_name="entry_tags")
    op.drop_table("entry_tags")
    op.drop_index("ix_entries_child_id_occurred_at", table_name="entries")
    op.drop_table("entries")
    op.drop_table("tags")
    op.drop_index("ix_refresh_tokens_token_hash", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")
    op.drop_table("idempotency_keys")
    op.drop_table("guardians")
    op.drop_table("credentials")
    op.drop_index("ix_assignments_child_id_status_assigned_on", table_name="assignments")
    op.drop_table("assignments")
    op.drop_table("users")
    op.drop_index("ix_prompts_kind_cadence_active_age", table_name="prompts")
    op.drop_index("ix_prompts_content_hash", table_name="prompts")
    op.drop_table("prompts")
    op.drop_table("children")

    op.execute("DROP FUNCTION IF EXISTS set_updated_at()")
