"""Phase 69. The daily prompt broadcast ledger.

One table, no foreign keys, and no personal data in it. What it is *not* is the point:
story 4 specifies `email_sends` with a `subscriber_id` FK, and there is no `subscribers`
table to point at — the list is Resend's, per `decisions.md` open item 12(4). A per-recipient
ledger here would be a copy of the mailing list under another name, which the published privacy
page says does not exist.

The unique index on `send_date` is the whole idempotency story: two machines on the same
schedule, a retried scheduled machine, or a hand-run `--date` for a day already sent all
collide on it rather than mailing everyone twice.

Revision ID: 0016_email_broadcasts
Revises: 0015_deletion_requests
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0016_email_broadcasts"
down_revision = "0015_deletion_requests"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "email_broadcasts",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("send_date", sa.Date(), nullable=False),
        sa.Column("pool_index", sa.Integer(), nullable=False),
        sa.Column("subject", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("resend_id", sa.Text(), nullable=True),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("sent_at", sa.DateTime(timezone=True), nullable=True),
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
        sa.CheckConstraint(
            "status IN ('sent', 'skipped', 'failed')", name="ck_email_broadcasts_status"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_email_broadcasts")),
    )
    # `skipped` rows are inside the constraint, not outside it. A dry run consumes the day on
    # purpose: otherwise a day that dry-ran at 08:00 would send for real at 09:00 the moment
    # somebody flipped the flag, against a row that already claimed the day was handled.
    op.create_index("uq_email_broadcasts_send_date", "email_broadcasts", ["send_date"], unique=True)
    op.execute(
        "CREATE TRIGGER trg_email_broadcasts_set_updated_at "
        "BEFORE UPDATE ON email_broadcasts "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_email_broadcasts_set_updated_at ON email_broadcasts")
    op.drop_index("uq_email_broadcasts_send_date", table_name="email_broadcasts")
    op.drop_table("email_broadcasts")
