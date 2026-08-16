"""`users.last_sign_in_at`, and the two consent lanes

Three columns from D3 and D3a, landing well ahead of the phase that consumes them, for one
reason that applies to exactly one of them and one that applies to the other two.

**`last_sign_in_at` cannot be backfilled.** D3 computes deletion eligibility as
`max(lapsed_at + 24 months, last_sign_in_at + 12 months)`. A lapse date can be reconstructed
later from a subscription record, because the payment rail keeps its own history. *When a
parent last opened the app* exists nowhere else — not in `entries`, which only says when
somebody wrote, not when they looked; not in `refresh_tokens`, which are revoked and pruned.
Every day this column does not exist is a day of the record that is simply gone, and the
households generating that record are using the app now.

**`data-model.md` specifies it on the entitlement row, keyed by family, and this puts it on
`users`.** That is a refinement rather than a contradiction: the specified value is "most
recent sign-in by **any** guardian", which is a `MAX` over precisely this column. Per-user is
strictly more information than the family row needs, the family value is a denormalisation of
it, and the household entity itself belongs to phase 37 — which is blocked on an App Store
Connect action nobody here can take. Waiting for the table would mean waiting for an account
action to start recording history that cannot be recovered afterwards. `data-model.md` is
updated to say so.

**The consent lanes are here because splitting them later is the expensive move.** D3a settles
that marketing and transactional consent are two fields and never one flag. The cost of adding
the second column today is one migration on a table with a handful of rows. The cost of
splitting a single `emails` boolean after both meanings have been written into it — under a
GDPR or CCPA request, which is when anybody will ask — is reconstructing which of the two a
given `false` meant, from data that never distinguished them. `data-model.md` names these as
one of the two things settled early for exactly this reason.

**Nullable, and null is not zero.** `last_sign_in_at` is null for every user created before
this migration. Null means *never observed*, which is not *long ago*: treating it as ancient
would make the oldest accounts the first eligible for deletion, which is the precise opposite
of correct. Nothing reads it yet, and whatever eventually does must handle null explicitly.

**Both consents default `true`.** That is the soft opt-in D3a describes — at most three
win-back emails in six months to a household that already had an account — and it keeps
`transactional_consent` true for every existing user, which is what makes deletion warnings
sendable at all. Nothing sends email today, so neither default reaches anybody.

Reversible. The downgrade drops all three, which loses the recorded activity — that is
inherent to the column existing at all, and is why the upgrade is the interesting direction.

Revision ID: 0010_activity_and_consent
Revises: 0009_neutral_theme_slug
Create Date: 2026-08-16
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0010_activity_and_consent"
down_revision = "0009_neutral_theme_slug"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("last_sign_in_at", sa.DateTime(timezone=True), nullable=True),
    )
    # `server_default` rather than a Python default: existing rows need a value, and the
    # constrained-value conventions in this repo keep defaults in the database so a row
    # written by anything other than the ORM is still correct.
    op.add_column(
        "users",
        sa.Column(
            "marketing_consent",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
    )
    op.add_column(
        "users",
        sa.Column(
            "transactional_consent",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
    )


def downgrade() -> None:
    op.drop_column("users", "transactional_consent")
    op.drop_column("users", "marketing_consent")
    op.drop_column("users", "last_sign_in_at")
