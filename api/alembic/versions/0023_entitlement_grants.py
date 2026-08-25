"""Phase 121. Complimentary entitlement, as a ledger beside `tier` rather than a value inside it.

**One new table and nothing else.** No existing column is dropped, altered or rewritten, no row
on any other table is touched, and there is no backfill — a household with no grant row is a
household nobody granted anything to, which is every household on the day this runs.

**Why not a column on `entitlements`.** The same argument `0022` made for the trial, one step
further on. `tier` has exactly one writer by D5 and `tests/test_app_store.py::
test_tier_has_exactly_one_writer` asserts it, so a grant that wrote `tier` would be the second
writer of the one column that decision exists to protect — and a writer that is a person clicking
a button, disagreeing with Apple. A `granted_until` column on `entitlements` would avoid that but
lose the part worth keeping: *who* granted it, *why*, and every extension before this one. A
household that has been extended three times is three rows here and one sentence in a support
conversation.

**No unique constraint on `family_id`, deliberately.** Multiple grants per household is the shape,
not a state to prevent. Extending somebody is a new row and the history is the point.

**`expires_at` is nullable and NULL means perpetual** — not a sentinel date. `reason` carries a
named CHECK that it is non-empty after trimming, because a blank reason is a ledger row that
answers the only question the ledger exists to answer.

**Both user references are `ON DELETE SET NULL` and therefore nullable, which is the one place
this table departs from the obvious shape.** Account deletion hard-deletes `users` rows — the
single exception to the soft-delete rule, phase 66 — so a NOT NULL `granted_by` would need an
`ON DELETE` action and none of the three works. `CASCADE` destroys the audit row, which is the
opposite of an audit trail. `RESTRICT` makes an erasure request fail with an integrity error the
deletion path has no branch for, in the one flow that must not raise. `SET NULL` is right and
cannot coexist with NOT NULL. `prompt_library_overrides.created_by_user_id` made the same trade in
`0017` for the same reason. The route always writes the column, from the bearer token's subject,
so NULL is only ever reachable by erasure and reads as *"the account that issued this is gone"*.

**`family_id` is `ON DELETE CASCADE`, unlike `app_store_transactions.family_id`.** A receipt
outlives the household it paid for and Apple will still send a `REFUND` about it; a grant is
*about* a household and means nothing without one.

`updated_at` gets the `set_updated_at()` trigger, like every other table carrying the column — a
revocation is an update in place and is the only one this table ever takes.

Reversible: the downgrade drops the trigger and the table. That loses the grants, which is what
dropping a table added by this migration means; nothing outside it is touched in either direction.

Revision ID: 0023_entitlement_grants
Revises: 0022_entitlement_trial
Create Date: 2026-08-24
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0023_entitlement_grants"
down_revision = "0022_entitlement_trial"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "entitlement_grants",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("family_id", sa.UUID(), nullable=False),
        sa.Column(
            "granted_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        # NULL is perpetual. Deliberately no default and deliberately not a sentinel date.
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("granted_by", sa.UUID(), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_by", sa.UUID(), nullable=True),
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
        sa.CheckConstraint("length(btrim(reason)) > 0", name=op.f("ck_entitlement_grants_reason")),
        sa.ForeignKeyConstraint(
            ["family_id"],
            ["families.id"],
            name=op.f("fk_entitlement_grants_family_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["granted_by"],
            ["users.id"],
            name=op.f("fk_entitlement_grants_granted_by"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["revoked_by"],
            ["users.id"],
            name=op.f("fk_entitlement_grants_revoked_by"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_entitlement_grants")),
    )
    # Every read of this table is "what does this household hold", so one index and it is on
    # `family_id`. Not on `(family_id, revoked_at)`: the active predicate also reads
    # `expires_at`, a partial index on `now()` is not immutable and therefore not indexable,
    # and one household holds a handful of rows rather than a page of them.
    op.create_index(
        "ix_entitlement_grants_family_id", "entitlement_grants", ["family_id"], unique=False
    )
    op.execute(
        "CREATE TRIGGER trg_entitlement_grants_set_updated_at "
        "BEFORE UPDATE ON entitlement_grants "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_entitlement_grants_set_updated_at ON entitlement_grants")
    op.drop_index("ix_entitlement_grants_family_id", table_name="entitlement_grants")
    op.drop_table("entitlement_grants")
