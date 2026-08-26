"""Phase 127. Apple's refresh token, kept so an erasure can revoke the sign-in that outlives it.

One nullable text column on `credentials`. Guideline 5.1.1(v) requires an app offering Sign in
with Apple to call Apple's REST token-revocation endpoint as part of deleting an account, and
that endpoint takes a refresh token — there was nothing in this schema it would accept.

**A column on `credentials` rather than a table of its own.** The token belongs to exactly one
credential, dies with it, and is read by exactly one caller. A second table would add a join and
a lifetime to manage for a one-to-one that `ON DELETE CASCADE` already handles.

**Nullable, and nothing is backfilled, because nothing can be.** The authorization code Apple
sends at sign-in was accepted and discarded from the first day of Sign in with Apple support
(`schemas/auth.py` said so in a comment), and it is single-use and short-lived, so no historical
value exists anywhere to recover. **Every Apple credential written before this revision stays
unrevocable until its next sign-in**, at which point the exchange fills the column in. That is a
real gap rather than an oversight, and it is written here so a reader does not go looking for the
backfill that was forgotten.

**No index and no CHECK.** It is never a search key — the only read is by the credential row that
already had to be found — and there is no constrained vocabulary to check. That is also why
neither `.github/scripts/verify_schema.py` nor `tests/test_migrations.py` gains an entry: both
enumerate named objects, and this adds none.

**Reversibility is total.** The downgrade drops the column, which loses every stored token and no
other information; the next sign-in on each credential writes a fresh one.

Revision ID: 0025_apple_refresh_token
Revises: 0024_canvas_video
Create Date: 2026-08-25
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0025_apple_refresh_token"
down_revision = "0024_canvas_video"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Nullable with no server default: a NULL here means "we have no token for this
    # credential", which is the true state for every row that exists when this runs and for
    # every non-Apple credential forever. An empty-string default would make those two cases
    # indistinguishable from a token we failed to store.
    op.add_column(
        "credentials",
        sa.Column("apple_refresh_token", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("credentials", "apple_refresh_token")
