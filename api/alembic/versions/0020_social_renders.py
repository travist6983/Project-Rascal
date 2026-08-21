"""Phase 103. One row per attempt to turn a shot list into a video.

**Why a table rather than columns on `social_assets`.** A render is not a property of a post,
it is an *attempt* at one: it takes minutes, it can fail halfway, it can be retried, and the
second attempt must not erase the evidence of the first. `social_assets.render_key` holds the
one artifact a post currently shows; this holds the job that produced it, including the six
clips that came back before the seventh timed out.

**`clip_keys` is an array, and its length is the progress bar.** Seven shots are seven separate
generations — no video API stitches them — so the honest unit of progress is clips landed, not
a percentage somebody computed. A resumed attempt can skip what is already in the array.

**`cost_cents` is written even on failure**, because the money is spent when the clip is
generated and not when the job succeeds. A ledger that only records successful spend is how a
bill becomes a surprise, which is the same argument as the cost panel it feeds.

**No `deleted_at`, and this is not a second exception to the soft-delete rule.** That rule
governs user data that syncs to a phone. Nothing here syncs, no client can read it, and a
tombstone would have nowhere to go — the identical reasoning `social_assets` and
`app_store_transactions` already record.

Reversible: the downgrade drops the trigger, both indexes and the table — verified by
running it. The check constraint goes with the table.

Revision ID: 0020_social_renders
Revises: 0019_app_store_transactions
Create Date: 2026-08-20
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0020_social_renders"
down_revision = "0019_app_store_transactions"
branch_labels = None
depends_on = None

# Frozen at this revision on purpose. A migration that reads a live constant describes whatever
# the models look like today rather than the schema it was written for.
STATUSES = ("queued", "running", "succeeded", "failed", "cancelled")


def upgrade() -> None:
    op.create_table(
        "social_renders",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("asset_id", sa.UUID(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False, server_default="queued"),
        #: Which vendor and which model id, recorded per attempt rather than read from config
        #: at display time: every video model on the Gemini API is preview, the ids move, and a
        #: render from last month should still say what actually made it.
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("model", sa.Text(), nullable=False),
        sa.Column("shots_total", sa.Integer(), nullable=False, server_default="0"),
        #: Object keys, in shot order. Never URLs — a signed URL in a column outlives its
        #: signature and then looks like data loss.
        sa.Column(
            "clip_keys",
            sa.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
        sa.Column("render_key", sa.Text(), nullable=True),
        #: One sentence, never a stack trace and never a URL carrying a key.
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("cost_cents", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
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
            ["asset_id"],
            ["social_assets.id"],
            name=op.f("fk_social_renders_asset_id"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_social_renders")),
    )
    op.create_check_constraint(
        "status",
        "social_renders",
        "status IN (" + ", ".join(f"'{value}'" for value in STATUSES) + ")",
    )
    # The console's poll: the newest attempt for one post.
    op.create_index(
        "ix_social_renders_asset_id_created_at",
        "social_renders",
        ["asset_id", sa.text("created_at DESC")],
    )
    # "Is anything still running?" — asked on every load of the studio, and by the guard that
    # refuses to start a second render for a post that is already rendering.
    op.create_index(
        "ix_social_renders_status",
        "social_renders",
        ["status"],
        postgresql_where=sa.text("status IN ('queued', 'running')"),
    )
    op.execute(
        "CREATE TRIGGER trg_social_renders_set_updated_at "
        "BEFORE UPDATE ON social_renders "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_social_renders_set_updated_at ON social_renders")
    op.drop_index("ix_social_renders_status", table_name="social_renders")
    op.drop_index("ix_social_renders_asset_id_created_at", table_name="social_renders")
    # The check constraint is not dropped explicitly: `DROP TABLE` takes its constraints with
    # it, and naming it here re-applies the metadata naming convention to an already-conventional
    # name — `ck_social_renders_ck_social_renders_status`, which does not exist.
    op.drop_table("social_renders")
