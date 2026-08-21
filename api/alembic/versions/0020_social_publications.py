"""Phase 104. One row per attempt to put a social asset on a platform.

**Why a table rather than four columns on `social_assets`.** A media id and a permalink would
have fitted on the asset, and for a single immediate post to a single platform that would have
been enough. Three things it would not have carried:

- *Scheduling.* A post can be queued for later, and something has to hold the time and be
  scanned for what is due. That is a queue, and a queue is rows.
- *Failure.* A publish that fails is not the absence of a publish — it has a reason, a count,
  and sometimes a container Meta already built. Columns on the asset would either lose that on
  the next attempt or turn the asset into an attempt log.
- *A second platform.* `social_assets.platform` names where a concept is *aimed*; this names
  where it actually *went*. Only Instagram has a publisher here and the owner asked for exactly
  that, but the day a second one arrives it is a row rather than a migration reshaping columns.

**`container_id` is written before the publish call, not after.** Meta's flow is two requests:
build a container from a public image URL, then publish that container. The dangerous gap is
between them — a crash after `media_publish` returns leaves a post on a public feed that no
row here knows about, and the next attempt would post it a second time. A duplicate on a
public feed is the one failure in this pipeline that strangers see and that nothing on our side
can undo. Recording the container first turns that from a mystery into evidence.

**`caption`, `alt_text` and `image_key` are snapshots, not references.** The asset stays
editable after a post goes out. What went out did not change, and a ledger that reads the
current draft to tell you what was published is a ledger that quietly rewrites history.

Revision ID: 0020_social_publications
Revises: 0019_app_store_transactions
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0020_social_publications"
down_revision = "0019_app_store_transactions"
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

#: `scheduled` is waiting for its time. `publishing` is a claim held by one worker for the
#: length of one attempt — it exists so a second worker walking the queue does not pick up a
#: row that is mid-flight at Meta. `failed` is terminal for the attempt and not for the asset:
#: a person can queue another one.
STATUSES = ("scheduled", "publishing", "published", "failed", "cancelled")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN (" + ", ".join(f"'{value}'" for value in values) + ")"


def upgrade() -> None:
    op.create_table(
        "social_publications",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("asset_id", sa.UUID(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False, server_default="scheduled"),
        # NULL means "as soon as the queue looks", which is what an immediate publish sets.
        # A time here is UTC and the job compares it against now() — the child-timezone rule
        # is about a child's day and there is no child in a marketing post.
        sa.Column("scheduled_for", sa.DateTime(timezone=True), nullable=True),
        # What actually went out, snapshotted. See the module docstring.
        sa.Column("image_key", sa.Text(), nullable=True),
        sa.Column("caption", sa.Text(), nullable=True),
        sa.Column("alt_text", sa.Text(), nullable=True),
        sa.Column("container_id", sa.Text(), nullable=True),
        sa.Column("media_id", sa.Text(), nullable=True),
        sa.Column("permalink", sa.Text(), nullable=True),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by_user_id", sa.UUID(), nullable=True),
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
        sa.CheckConstraint(_in("platform", PLATFORMS), name="ck_social_publications_platform"),
        sa.CheckConstraint(_in("status", STATUSES), name="ck_social_publications_status"),
        # CASCADE is safe because nothing deletes a `social_assets` row — throwing a concept
        # away is `status = 'discarded'`, which is why that table has no `deleted_at`.
        sa.ForeignKeyConstraint(
            ["asset_id"],
            ["social_assets.id"],
            name=op.f("fk_social_publications_asset_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["created_by_user_id"],
            ["users.id"],
            name=op.f("fk_social_publications_created_by_user_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_social_publications")),
    )
    # The queue's own read: what is due, oldest first.
    op.create_index(
        "ix_social_publications_status_scheduled_for",
        "social_publications",
        ["status", "scheduled_for"],
    )
    op.create_index(
        "ix_social_publications_asset_id",
        "social_publications",
        ["asset_id"],
    )
    # **Two rows must never claim the same post.** The application checks Instagram before it
    # publishes and refuses on an asset that already went out, but both of those are decisions
    # made in Python by one process; this is the one that survives two.
    op.create_index(
        "uq_social_publications_media_id",
        "social_publications",
        ["media_id"],
        unique=True,
        postgresql_where=sa.text("media_id IS NOT NULL"),
    )
    # One live attempt per asset. Without this, pressing publish twice — or scheduling a post
    # that is already queued — produces two rows that both come due and both post.
    op.create_index(
        "uq_social_publications_live_per_asset",
        "social_publications",
        ["asset_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('scheduled', 'publishing')"),
    )
    op.execute(
        "CREATE TRIGGER trg_social_publications_set_updated_at "
        "BEFORE UPDATE ON social_publications "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute(
        "DROP TRIGGER IF EXISTS trg_social_publications_set_updated_at ON social_publications"
    )
    op.drop_index("uq_social_publications_live_per_asset", table_name="social_publications")
    op.drop_index("uq_social_publications_media_id", table_name="social_publications")
    op.drop_index("ix_social_publications_asset_id", table_name="social_publications")
    op.drop_index("ix_social_publications_status_scheduled_for", table_name="social_publications")
    op.drop_table("social_publications")
