"""Phase 37a. The App Store receipt ledger.

One table. `entitlements` already records *what* a household is entitled to; this records
*why*, and it is what makes three guards in `services/app_store.py` possible at all —
idempotency across Apple's retries, ordering across out-of-order delivery, and the refusal to
demote a family this service has no transaction record for.

**`original_transaction_id` is the primary key.** Apple's stable identifier for one
subscription across every renewal and resubscribe is already the thing this table is
one-row-per, so a surrogate id beside it would only permit two rows about one subscription.

**`family_id` is nullable and `ON DELETE SET NULL`.** A notification whose `appAccountToken`
is missing or malformed is recorded unattributed rather than refused — Apple retries anything
that is not a 2xx, so refusing an orphan receipt means being told about it forever. And a
receipt outlives the household it paid for: a hard account deletion (phase 66) must not take
the billing record with it, because the money was real and Apple will still send a REFUND
about it.

**`raw_payload` holds the decoded notification, not the JWS.** A stored JWS is a
secret-shaped blob nobody will verify twice; a stored decode is readable during an incident,
which is the only time anybody opens this table.

**No `deleted_at`, and this is not a second exception to the soft-delete rule.** That rule
governs user data that syncs to a phone. Nothing here syncs, no client can read it, and a
tombstone would have nowhere to go.

Reversible: the downgrade drops the trigger, both indexes and the table.

Revision ID: 0019_app_store_transactions
Revises: 0018_social_assets
Create Date: 2026-08-20
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0019_app_store_transactions"
down_revision = "0018_social_assets"
branch_labels = None
depends_on = None

# Frozen at this revision on purpose. A migration that reads a live constant describes
# whatever the models look like today rather than the schema it was written for.
ENVIRONMENTS = ("Sandbox", "Production")


def upgrade() -> None:
    op.create_table(
        "app_store_transactions",
        sa.Column("original_transaction_id", sa.Text(), nullable=False),
        sa.Column("family_id", sa.UUID(), nullable=True),
        sa.Column("product_id", sa.Text(), nullable=True),
        sa.Column("environment", sa.Text(), nullable=False),
        sa.Column("latest_notification_type", sa.Text(), nullable=False),
        sa.Column("latest_notification_subtype", sa.Text(), nullable=True),
        # The ordering key. Apple's `signedDate` off the outer payload — when Apple decided,
        # not when we heard, which is what makes a late retry recognisable as late.
        sa.Column("latest_signed_date", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("raw_payload", postgresql.JSONB(), nullable=False),
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
            ["family_id"],
            ["families.id"],
            name=op.f("fk_app_store_transactions_family_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("original_transaction_id", name=op.f("pk_app_store_transactions")),
    )
    op.create_check_constraint(
        "environment",
        "app_store_transactions",
        "environment IN (" + ", ".join(f"'{value}'" for value in ENVIRONMENTS) + ")",
    )
    op.create_index(
        "ix_app_store_transactions_family_id",
        "app_store_transactions",
        ["family_id"],
    )
    op.create_index(
        "ix_app_store_transactions_environment_latest_signed_date",
        "app_store_transactions",
        ["environment", "latest_signed_date"],
    )
    op.execute(
        "CREATE TRIGGER trg_app_store_transactions_set_updated_at "
        "BEFORE UPDATE ON app_store_transactions "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute(
        "DROP TRIGGER IF EXISTS trg_app_store_transactions_set_updated_at ON app_store_transactions"
    )
    op.drop_index(
        "ix_app_store_transactions_environment_latest_signed_date",
        table_name="app_store_transactions",
    )
    op.drop_index("ix_app_store_transactions_family_id", table_name="app_store_transactions")
    op.drop_table("app_store_transactions")
