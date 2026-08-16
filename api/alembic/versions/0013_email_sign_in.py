"""Magic-link sign-in: the single-use token, and the rate-limit ledger beside it

**`email_sign_in_tokens` stores only a SHA-256**, the same rule `refresh_tokens` follows and
for the same reason: the raw value exists in exactly one email and never again. A database
dump, a backup, a restore drill, a support session — none of them can hand somebody a working
key to an archive.

**Fifteen minutes, and single use.** `consumed_at` is what makes it single-use, and it is a
timestamp rather than a boolean so a replay can be told apart from a link that was never used.

**Two purposes, and only one of them may activate a credential.** A `verify` token is what
`POST /me/credentials/email` sends to prove a newly added address; a `sign_in` token is an
ordinary magic link. Only `verify` clears `revoked_at`. Without the distinction, an outstanding
link would reactivate a credential the parent had deliberately removed — which would make
Remove a suggestion rather than an action.

**`credential_id` rather than `user_id`.** The token belongs to the *address*, not the account.
Revoking the credential therefore invalidates every outstanding link to it without a second
statement, and a token for a revoked credential is refused by a join that already exists.
`ON DELETE CASCADE` for the same reason.

**`rate_limit_events` is in Postgres and not in memory, and that is not a preference.** There
is more than one Fly machine, so an in-process counter is per-process theatre: the limit would
be N times looser than it reads, and would reset on every deploy. **Per-email is the one that
matters** — the abuse is spamming links at one address, and an edge limiter cannot see the
address because it is inside the request body, which is why this lives in the app rather than
at Cloudflare.

The table is deliberately generic: `bucket` is `email:<address>` or `ip:<addr>`, so a third
limiter later is a new prefix rather than a new table. Rows are pruned as they are counted.

Reversible. The downgrade drops both tables, which loses outstanding links — correct, since a
link is only useful for fifteen minutes anyway.

Revision ID: 0013_email_sign_in
Revises: 0012_email_deliverable
Create Date: 2026-08-16
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0013_email_sign_in"
down_revision = "0012_email_deliverable"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "email_sign_in_tokens",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("credential_id", sa.UUID(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        # `verify` activates a newly added address; `sign_in` is an ordinary magic link.
        # Two purposes because only the first may clear `revoked_at`: a link that could
        # reactivate a credential the parent removed would make Remove a suggestion.
        sa.Column("purpose", sa.Text(), nullable=False, server_default=sa.text("'sign_in'")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["credential_id"],
            ["credentials.id"],
            name=op.f("fk_email_sign_in_tokens_credential_id"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_email_sign_in_tokens")),
    )
    # The lookup is by hash and only by hash — the raw token is never stored to look up.
    op.create_index(
        "ix_email_sign_in_tokens_token_hash",
        "email_sign_in_tokens",
        ["token_hash"],
        unique=True,
    )

    op.create_check_constraint(
        "purpose", "email_sign_in_tokens", "purpose IN ('verify', 'sign_in')"
    )

    op.create_table(
        "rate_limit_events",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("bucket", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rate_limit_events")),
    )
    # Counting is always "this bucket, since this instant", so the index carries both.
    op.create_index(
        "ix_rate_limit_events_bucket_created_at",
        "rate_limit_events",
        ["bucket", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_rate_limit_events_bucket_created_at", table_name="rate_limit_events")
    op.drop_table("rate_limit_events")
    op.drop_index("ix_email_sign_in_tokens_token_hash", table_name="email_sign_in_tokens")
    op.drop_table("email_sign_in_tokens")
