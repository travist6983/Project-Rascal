"""A parent asking to be forgotten, and the seven days before it happens

Phase 66, per `decisions.md` open item 14, settled Aug 17, 2026. Apple has required in-app
account deletion since June 2022 and this app has never been submitted; the investigation in
`docs/investigations/account-deletion.md` found no deletion machinery at all.

**This table is a state, not a queue.** The grace period has to be visible — to the parent, who
may change their mind, and to anybody debugging why an archive is still here on day six. A job
with no row behind it would be a deletion nobody can see coming.

**One pending request per user, enforced by a partial unique index** on `(user_id)` where the
row is not cancelled. A plain unique on `user_id` would forbid a second request after a cancelled
one, which is a state a parent can genuinely reach: ask, change your mind, ask again a year
later. The partial index permits the history and forbids the ambiguity.

**There is no `completed_at`, and its absence is the design.** A completed deletion has no row,
because the row cascades away with the user — so a column recording completion could never hold
a value, and a state this table cannot represent should not be a column pretending it can.
**Completion is the row being gone**, which is also the only record consistent with having been
asked to forget somebody.

**`ON DELETE CASCADE`, so the row goes when the user does.** That is deliberate and it is the
whole point of the feature: keeping a record keyed to somebody who asked to be forgotten is the
thing an erasure request is about. What survives is a log line saying a deletion ran, which
identifies nobody. If an audit trail with user ids is ever required, it is a new decision and
a different table, not a quiet relaxation of this one.

**`execute_after` is stored rather than computed.** Seven days is a policy that may change, and
a request made under the old policy must run on the terms it was made under — a computed
`requested_at + INTERVAL` would silently re-date every outstanding request the day somebody
edits a constant.

**`entries.author_id` becomes nullable, and this migration is where the spec met the schema.**
Item 14(a) settles that a departing parent's entries survive when another guardian remains, and
item 13 settles that the attribution is kept. **Both cannot hold once the user row is erased** —
`author_id` was `NOT NULL` with `ON DELETE RESTRICT`, so deleting the account would simply fail
on the first surviving entry. Something had to give and there was only one candidate: the entry
must survive (it is the child's, not the parent's), the person must actually be erased (that is
the feature), so **the foreign key gives.**

`SET NULL` rather than reassigning to the remaining guardian. Null means *"written by somebody
who is no longer here"*, which is true; reassigning would be a false claim about who wrote a
sentence, in an archive whose whole worth is that it is accurate. Every read of `author_id` must
now handle null — there is exactly one today, and it is `GET /entries`.

Reversible **in shape but not in content**: the downgrade restores `NOT NULL`, which cannot
succeed while any orphaned entry exists, so it deletes those rows first and says so. That is
real data loss on a downgrade, and it is the honest direction — an entry whose author was erased
cannot be given one back.

Reversible. The downgrade drops the table, which loses outstanding requests — correct, since a
dropped request is a deletion that does not happen, and that is the safe direction.

Revision ID: 0015_deletion_requests
Revises: 0014_families_and_invites
Create Date: 2026-08-17
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0015_deletion_requests"
down_revision = "0014_families_and_invites"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "deletion_requests",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column(
            "requested_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        # Stored, not computed. See the header.
        sa.Column("execute_after", sa.DateTime(timezone=True), nullable=False),
        # Null while pending. A timestamp rather than a boolean, for the same reason
        # `consumed_at` is one on the sign-in token: *when* somebody changed their mind is the
        # part worth having.
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
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
            ["user_id"],
            ["users.id"],
            name=op.f("fk_deletion_requests_user_id"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_deletion_requests")),
    )

    # At most one *pending* request per user. Cancelled and completed rows are history and are
    # deliberately outside the constraint.
    op.create_index(
        "uq_deletion_requests_pending",
        "deletion_requests",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("cancelled_at IS NULL"),
    )
    # The job's only query: what is due. Partial for the same reason — a completed request is
    # never due again, and the index should not carry years of them.
    op.create_index(
        "ix_deletion_requests_due",
        "deletion_requests",
        ["execute_after"],
        postgresql_where=sa.text("cancelled_at IS NULL"),
    )

    # See the header: erasure and surviving entries cannot both hold while this is NOT NULL.
    op.alter_column("entries", "author_id", existing_type=sa.UUID(), nullable=True)
    op.drop_constraint(op.f("fk_entries_author_id"), "entries", type_="foreignkey")
    op.create_foreign_key(
        op.f("fk_entries_author_id"),
        "entries",
        "users",
        ["author_id"],
        ["id"],
        ondelete="SET NULL",
    )

    op.execute(
        "CREATE TRIGGER trg_deletion_requests_set_updated_at "
        "BEFORE UPDATE ON deletion_requests "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    # An entry whose author was erased cannot be given one back, so restoring NOT NULL means
    # removing them. Stated loudly because it is the one downgrade in this chain that destroys
    # archive content rather than scheduler output.
    op.execute("DELETE FROM entries WHERE author_id IS NULL")
    op.drop_constraint(op.f("fk_entries_author_id"), "entries", type_="foreignkey")
    op.create_foreign_key(
        op.f("fk_entries_author_id"),
        "entries",
        "users",
        ["author_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.alter_column("entries", "author_id", existing_type=sa.UUID(), nullable=False)

    op.drop_index("ix_deletion_requests_due", table_name="deletion_requests")
    op.drop_index("uq_deletion_requests_pending", table_name="deletion_requests")
    op.drop_table("deletion_requests")
