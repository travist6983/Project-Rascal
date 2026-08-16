"""Credential revocation state, and the `email` provider the dev fixture moves onto

Four changes to `credentials`, one of which is a data migration.

**`revoked_at`, and the unique constraint deliberately does not change.** Revoking is a soft
delete: the row stays, keeps its `(provider, subject_id)`, and therefore keeps its claim on
that subject. Signing in again with the same Apple ID matches the same row and lands on the
same `users.id`, which is what makes revocation recoverable. Freeing the namespace instead —
by deleting the row, or by putting `revoked_at` in the unique key — would let the next sign-in
mint a *second* user and leave the archive behind the first one unreachable. That is the only
failure in this table the person it happens to cannot undo, so the constraint stays as it is.

**`updated_at` and its trigger.** `credentials` is the first auth-infrastructure table to get
one; `refresh_tokens` and `idempotency_keys` still have neither. It earns one because a
revocation is a change to a row that is otherwise write-once, and `updated_at` is the cursor
every client already syncs on. A revocation nothing can observe is a revocation nobody can act
on. Backfilled to `created_at` rather than to `now()`, so an existing row does not claim it
was edited by this migration.

**The CHECK gains `email`, and keeps `password`.** `password` is dead after the data migration
below, and removing it from the CHECK would be a migration that can only fail — on any row
somebody had not migrated — in exchange for nothing. Rule 2 means this set is meant to grow.

**The data migration is `password` → `email`, and it was checked rather than assumed.** Read
from production on Aug 16, 2026 before writing this: one `users` row and one `credentials`
row, `provider = 'apple'`, zero `password` rows. The statement therefore touches the local dev
fixture only. It is written as an unconditional UPDATE anyway, because a migration that is
correct only on the database somebody happened to look at is not a migration.

Reversible in both directions. The downgrade moves `email` rows back to `password`, which is
lossy in exactly one way worth naming: a genuine `email` credential created after this
migration is indistinguishable from a migrated fixture row on the way back, and both become
`password`. Phase 57 is what creates those, so there are none while this is the head.

Revision ID: 0011_credential_linking
Revises: 0010_activity_and_consent
Create Date: 2026-08-16
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0011_credential_linking"
down_revision = "0010_activity_and_consent"
branch_labels = None
depends_on = None

# Frozen at this revision rather than read from `constants.CREDENTIAL_PROVIDERS`. A migration
# that reads a live constant describes whatever the models look like today instead of the
# schema it was written for, and stops being reversible the moment the constant moves.
PROVIDERS_AFTER = ("apple", "google", "password", "email")
PROVIDERS_BEFORE = ("apple", "google", "password")


def _check(values: tuple[str, ...]) -> str:
    rendered = ", ".join(f"'{value}'" for value in values)
    return f"provider IN ({rendered})"


def upgrade() -> None:
    op.add_column(
        "credentials",
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "credentials",
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    # An existing credential has not been edited, so it should not read as though this
    # migration edited it. `now()` would make every row look freshly changed to the first
    # client that syncs on this cursor.
    op.execute("UPDATE credentials SET updated_at = created_at")

    op.execute(
        "CREATE TRIGGER trg_credentials_set_updated_at "
        "BEFORE UPDATE ON credentials "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )

    # The bare constraint name, not the rendered one: the metadata's naming convention
    # expands `provider` to `ck_credentials_provider` on both create and drop, and passing the
    # expanded name gets it expanded a second time.
    op.drop_constraint("provider", "credentials", type_="check")
    op.create_check_constraint("provider", "credentials", _check(PROVIDERS_AFTER))

    # The dev fixture squatted beside the production credential shape instead of rehearsing
    # it. After this it is an ordinary `email` credential, which is the same row phase 57's
    # magic link writes — so the local path exercises the real one.
    op.execute("UPDATE credentials SET provider = 'email' WHERE provider = 'password'")


def downgrade() -> None:
    op.execute("UPDATE credentials SET provider = 'password' WHERE provider = 'email'")

    # The bare constraint name, not the rendered one: the metadata's naming convention
    # expands `provider` to `ck_credentials_provider` on both create and drop, and passing the
    # expanded name gets it expanded a second time.
    op.drop_constraint("provider", "credentials", type_="check")
    op.create_check_constraint("provider", "credentials", _check(PROVIDERS_BEFORE))

    op.execute("DROP TRIGGER IF EXISTS trg_credentials_set_updated_at ON credentials")

    op.drop_column("credentials", "updated_at")
    op.drop_column("credentials", "revoked_at")
