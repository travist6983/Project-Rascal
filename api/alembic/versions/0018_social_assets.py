"""Phase 97. What the social studio produced.

Marketing output rather than user data, so it follows `email_broadcasts`: `updated_at` and the
trigger, no `deleted_at`. Discarding a draft is `status = 'discarded'`, which carries more
information than a tombstone — and the D7 counter below depends on being able to tell a
discarded concept from a published one.

`ix_social_assets_featured_prompt_id` is partial on purpose. `docs/decisions.md` D7 keeps the
mission library out of anything public *"whole or in generated slices"*, and a studio that can
put a prompt on a card produces exactly those slices. Every featured body is counted against
the size of the library — but a concept that was thrown away never went anywhere, so the
predicate excludes it in the schema rather than in whichever query remembers to.

Revision ID: 0018_social_assets
Revises: 0017_prompt_library_overrides
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0018_social_assets"
down_revision = "0017_prompt_library_overrides"
branch_labels = None
depends_on = None

PLATFORMS = (
    "instagram",
    "instagram_story",
    "x",
    "threads",
    "facebook",
    "linkedin",
    "generic",
)
STATUSES = ("draft", "approved", "exported", "published", "discarded")
FORMATS = ("card", "photo", "video")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN (" + ", ".join(f"'{value}'" for value in values) + ")"


def upgrade() -> None:
    op.create_table(
        "social_assets",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False, server_default="generic"),
        sa.Column("status", sa.Text(), nullable=False, server_default="draft"),
        sa.Column("format", sa.Text(), nullable=False, server_default="card"),
        sa.Column("angle", sa.Text(), nullable=True),
        sa.Column("template", sa.Text(), nullable=True),
        sa.Column("palette", sa.Text(), nullable=True),
        sa.Column("headline", sa.Text(), nullable=True),
        sa.Column("subhead", sa.Text(), nullable=True),
        sa.Column("caption", sa.Text(), nullable=True),
        sa.Column("alt_text", sa.Text(), nullable=True),
        sa.Column(
            "hashtags",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
        sa.Column("image_prompt", sa.Text(), nullable=True),
        sa.Column("shot_list", postgresql.JSONB(), nullable=True),
        sa.Column("caption_track", sa.Text(), nullable=True),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("render_provider", sa.Text(), nullable=True),
        sa.Column("render_key", sa.Text(), nullable=True),
        sa.Column("featured_prompt_id", sa.UUID(), nullable=True),
        sa.Column("featured_body", sa.Text(), nullable=True),
        sa.Column("model", sa.Text(), nullable=True),
        sa.Column("created_by_user_id", sa.UUID(), nullable=True),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.CheckConstraint(_in("platform", PLATFORMS), name="ck_social_assets_platform"),
        sa.CheckConstraint(_in("status", STATUSES), name="ck_social_assets_status"),
        sa.CheckConstraint(_in("format", FORMATS), name="ck_social_assets_format"),
        # SET NULL, not CASCADE. A prompt can be forked and retired by the library editor, and
        # a post that already went out must not vanish from the ledger because the row it
        # pointed at was superseded — `featured_body` is the snapshot that survives that.
        sa.ForeignKeyConstraint(
            ["featured_prompt_id"],
            ["prompts.id"],
            name=op.f("fk_social_assets_featured_prompt_id"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_user_id"],
            ["users.id"],
            name=op.f("fk_social_assets_created_by_user_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_social_assets")),
    )
    op.create_index(
        "ix_social_assets_status_created_at",
        "social_assets",
        ["status", sa.text("created_at DESC")],
    )
    op.create_index(
        "ix_social_assets_featured_prompt_id",
        "social_assets",
        ["featured_prompt_id"],
        postgresql_where=sa.text("featured_prompt_id IS NOT NULL AND status <> 'discarded'"),
    )
    op.execute(
        "CREATE TRIGGER trg_social_assets_set_updated_at "
        "BEFORE UPDATE ON social_assets "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_social_assets_set_updated_at ON social_assets")
    op.drop_index("ix_social_assets_featured_prompt_id", table_name="social_assets")
    op.drop_index("ix_social_assets_status_created_at", table_name="social_assets")
    op.drop_table("social_assets")
