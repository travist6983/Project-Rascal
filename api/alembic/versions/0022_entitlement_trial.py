"""Phase 107. The fourteen-day trial, as a column beside `tier` rather than a value inside it.

**One nullable `timestamptz` on `entitlements`, and nothing else.** No column is dropped,
altered or rewritten; no row is deleted. The only write is the backfill described below.

**Why not a `trial` value in `entitlements.tier`.** D5 reserves `tier` for App Store Server
Notifications V2, and `tests/test_app_store.py::test_tier_has_exactly_one_writer` asserts there
is exactly one assignment to it anywhere under `src/`. A trial that wrote `tier` would be the
second writer of the one column that decision exists to protect — and it would be a writer that
runs on a clock rather than on a receipt, so the column would start disagreeing with Apple.
Entitlement is computed instead, in `services/guardians.access_for`, from `tier` and this
column together. **`tier` keeps its existing meaning and values**, which is what keeps every
client that reads it working.

**The backfill gives every existing household fourteen days from the moment this runs.** There
is one real household and it must not land on the free tier because a migration ran — phase 107
reverses D2 and narrows D3, so on the day this deploys the free tier stops carrying missions,
and an unbackfilled row would take somebody's board away without anybody deciding to. Fourteen
days is the same trial a new sign-up gets, so the backfill says *"start everyone where a new
household starts"* rather than inventing a grandfather clause nobody has to reason about later.

**`now()` rather than a literal timestamp**, so the fourteen days run from the deploy rather
than from whenever this file was written. `now()` is the transaction's start time in Postgres,
so every row in the backfill gets the same value — which is the property you want when the
question later is *"when did the trial actually start"*.

**The default lives in the application, not in the schema, and that is deliberate.** SQLAlchemy
supplies `now + 14 days` at INSERT (`models/family.py::_default_trial_ends_at`). A
`server_default` of `now() + interval '14 days'` would work too and was rejected for one
reason: it would make the column impossible to insert as NULL without an explicit override, and
NULL is a *real* state here — it is what the admin console's one lever produces when it clears
the date. A schema default that a legitimate value has to fight is a schema default that
eventually wins an argument it should have lost.

Reversible: the downgrade drops the column. That loses the trial dates, which is what dropping
a column added by this migration means; nothing else on the table is touched, and every other
column, index, constraint and trigger survives untouched in both directions.

Revision ID: 0022_entitlement_trial
Revises: 0021_social_renders
Create Date: 2026-08-21
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0022_entitlement_trial"
down_revision = "0021_social_renders"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "entitlements",
        sa.Column("trial_ends_at", sa.DateTime(timezone=True), nullable=True),
    )
    # Every household that already exists starts its trial now. Deliberately unconditional
    # rather than `WHERE tier = 'free'`: a subscribed household reads `access = "subscribed"`
    # regardless of this column — `subscribed` beats `trial` in `access_for` — so writing it
    # for everyone costs nothing and means the column has no "some rows never got one" hole
    # for a later reader to trip over.
    #
    # This runs against a table with one row in production and a handful in any dev database.
    # A `WHERE trial_ends_at IS NULL` guard is unnecessary — the column did not exist a
    # statement ago — and would only obscure that.
    op.execute("UPDATE entitlements SET trial_ends_at = now() + interval '14 days'")


def downgrade() -> None:
    op.drop_column("entitlements", "trial_ends_at")
