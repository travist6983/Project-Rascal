"""The household, the invite, and per-parent daily assignment

Phase 36. Three new tables and one change to `assignments` that is the only part of this
revision that can damage an existing archive.

**`families` is the household and `entitlements` hangs off it, per D4** — one price, all
guardians, unlimited children. The entitlement is keyed on `family_id` and on nothing else:
never per-user, never per-child.

**`entitlements` arrives here rather than in phase 37, and nothing writes `tier` yet.** The
invite gate has to read a tier before phase 37 exists to write one, so the table comes
forward and the writer does not. **There is no automated writer of `tier` in this codebase.**
D5 reserves that for App Store Server Notifications V2, and until 37 ships the only way a
family becomes `subscribed` is the hand-run statement documented in
`docs/runbook-deploy.md`. Do not read this table's existence as evidence that billing works.

**`users.family_id` is backfilled one family per existing user**, which is correct only
because no two users currently share a child. That was checked against production before this
was written, not assumed — see `docs/sprint-aug16/story-3a-report.md` for the query and its
output.

**`assignments.user_id` is the dangerous column.** Daily slots become per-guardian; weekly,
monthly and letter stay one per child. The backfill attributes every existing daily row to
the sole guardian of its child, which is trivially right while there is one guardian and
unrecoverably wrong the moment there are two — it would silently attribute one parent's
history to the other. The same production check is what proves this ran inside that window.

**Two partial unique indexes replace one plain one, and the reason is NULL semantics.**
Postgres treats NULLs as distinct in a unique index, so a single
`UNIQUE (child_id, user_id, assigned_on, slot)` would let the scheduler write an unlimited
number of shared-slot rows for one child and day — every one of them has a NULL `user_id`,
and NULL never equals NULL. Idempotency would fail silently, on exactly the slots nobody
checks daily. The shared-slot index therefore does not mention `user_id` at all, which keeps
`uq_assignments_child_id_assigned_on_slot`'s guarantee intact for the rows that kept the old
shape.

**Order matters and is not cosmetic:** add the column, backfill it, *then* add the CHECK.
Adding the constraint first fails on every existing row.

Reversible. The downgrade restores the single unique index, drops `user_id` with it, and
drops the three tables.

Revision ID: 0014_families_and_invites
Revises: 0013_email_sign_in
Create Date: 2026-08-17
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0014_families_and_invites"
down_revision = "0013_email_sign_in"
branch_labels = None
depends_on = None

# Frozen at this revision on purpose. A migration that reads a live constant describes
# whatever the models look like today rather than the schema it was written for.
DAILY_SLOTS = ("question", "mission", "mission_b")
SHARED_SLOTS = ("weekly", "monthly", "letter")

_DAILY_SQL = ", ".join(f"'{slot}'" for slot in DAILY_SLOTS)
_SHARED_SQL = ", ".join(f"'{slot}'" for slot in SHARED_SLOTS)


def upgrade() -> None:
    # --- The household -------------------------------------------------------------------
    op.create_table(
        "families",
        sa.Column("id", sa.UUID(), nullable=False),
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
        sa.PrimaryKeyConstraint("id", name=op.f("pk_families")),
    )

    # Nullable first, backfilled, then NOT NULL — in one revision, so no deploy ever sees a
    # half-migrated column.
    op.add_column("users", sa.Column("family_id", sa.UUID(), nullable=True))
    op.execute(
        """
        WITH new_families AS (
            INSERT INTO families (id)
            SELECT gen_random_uuid() FROM users WHERE family_id IS NULL
            RETURNING id
        ), numbered_families AS (
            SELECT id, row_number() OVER () AS rn FROM new_families
        ), numbered_users AS (
            SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn
            FROM users WHERE family_id IS NULL
        )
        UPDATE users SET family_id = numbered_families.id
        FROM numbered_users, numbered_families
        WHERE users.id = numbered_users.id AND numbered_users.rn = numbered_families.rn
        """
    )
    op.alter_column("users", "family_id", nullable=False)
    op.create_foreign_key(
        op.f("fk_users_family_id"),
        "users",
        "families",
        ["family_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_index("ix_users_family_id", "users", ["family_id"])

    # --- The entitlement, one row per family ---------------------------------------------
    op.create_table(
        "entitlements",
        sa.Column("family_id", sa.UUID(), nullable=False),
        sa.Column("tier", sa.Text(), nullable=False, server_default=sa.text("'free'")),
        # Nullable: a family can be `free` with nobody paying, and a lapsed family keeps the
        # payer that lapsed so a win-back knows who to talk to.
        sa.Column("payer_user_id", sa.UUID(), nullable=True),
        sa.Column("lapsed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["family_id"],
            ["families.id"],
            name=op.f("fk_entitlements_family_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["payer_user_id"],
            ["users.id"],
            name=op.f("fk_entitlements_payer_user_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("family_id", name=op.f("pk_entitlements")),
    )
    op.create_check_constraint("tier", "entitlements", "tier IN ('free', 'subscribed')")
    # Every family that exists right now gets the free row, so a read never has to cope with
    # a missing entitlement.
    op.execute("INSERT INTO entitlements (family_id) SELECT id FROM families")

    # --- The invite ----------------------------------------------------------------------
    op.create_table(
        "guardian_invites",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("family_id", sa.UUID(), nullable=False),
        sa.Column("invited_by_user_id", sa.UUID(), nullable=False),
        # SHA-256 only, the rule `refresh_tokens` and `email_sign_in_tokens` already follow:
        # the raw token exists in one link and never again.
        sa.Column("token_hash", sa.Text(), nullable=False),
        # Nullable — an invite may be a bare link rather than addressed to somebody.
        sa.Column("email", sa.Text(), nullable=True),
        sa.Column("role", sa.Text(), nullable=False, server_default=sa.text("'parent'")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("accepted_by_user_id", sa.UUID(), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
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
            name=op.f("fk_guardian_invites_family_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["invited_by_user_id"],
            ["users.id"],
            name=op.f("fk_guardian_invites_invited_by_user_id"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["accepted_by_user_id"],
            ["users.id"],
            name=op.f("fk_guardian_invites_accepted_by_user_id"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_guardian_invites")),
    )
    # `viewer` is in the constraint because the column has to be able to hold it before
    # phase 30 can ever issue one. Nothing issues it today and the route refuses it.
    op.create_check_constraint(
        "role", "guardian_invites", "role IN ('parent', 'viewer')"
    )
    op.create_index(
        "ix_guardian_invites_token_hash", "guardian_invites", ["token_hash"], unique=True
    )
    op.create_index("ix_guardian_invites_family_id", "guardian_invites", ["family_id"])

    # --- The dangerous part --------------------------------------------------------------
    op.add_column("assignments", sa.Column("user_id", sa.UUID(), nullable=True))
    op.create_foreign_key(
        op.f("fk_assignments_user_id"),
        "assignments",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # Daily rows go to the sole active guardian of their child. `LIMIT 1` with an ORDER BY is
    # deterministic rather than arbitrary, but it is only ever choosing from one row — the
    # production check that proved that is in the story report, and the guard below is what
    # refuses to proceed if it was ever false.
    op.execute(
        f"""
        UPDATE assignments SET user_id = (
            SELECT g.user_id FROM guardians g
            WHERE g.child_id = assignments.child_id
              AND g.revoked_at IS NULL
              AND g.role = 'parent'
            ORDER BY g.granted_at, g.user_id
            LIMIT 1
        )
        WHERE slot IN ({_DAILY_SQL})
        """
    )

    # A daily assignment whose child has no active parent is unreachable data — nobody can
    # see it, and nothing can honestly attribute it. **Fail loudly rather than deleting it**:
    # a migration that quietly removes rows adjacent to an archive is the failure this
    # project is most afraid of. If this fires, decide what those rows are and say so
    # explicitly; do not widen the CHECK to let them through.
    op.execute(
        f"""
        DO $$
        DECLARE orphaned integer;
        BEGIN
            SELECT count(*) INTO orphaned FROM assignments
            WHERE slot IN ({_DAILY_SQL}) AND user_id IS NULL;
            IF orphaned > 0 THEN
                RAISE EXCEPTION
                    '0014: % daily assignment(s) belong to a child with no active parent '
                    'guardian and cannot be attributed. Resolve them by hand before '
                    'migrating; this revision will not guess and will not delete them.',
                    orphaned;
            END IF;
        END $$
        """
    )

    op.create_check_constraint(
        "user_id_by_slot",
        "assignments",
        f"(slot IN ({_DAILY_SQL}) AND user_id IS NOT NULL)"
        f" OR (slot IN ({_SHARED_SQL}) AND user_id IS NULL)",
    )

    # Swap the guarantee. The old constraint cannot coexist with per-guardian daily rows: a
    # second guardian's `question` for the same child and day would violate it.
    op.drop_constraint(
        "uq_assignments_child_id_assigned_on_slot", "assignments", type_="unique"
    )
    op.create_index(
        "uq_assignments_daily",
        "assignments",
        ["child_id", "user_id", "assigned_on", "slot"],
        unique=True,
        postgresql_where=sa.text(f"slot IN ({_DAILY_SQL})"),
    )
    op.create_index(
        "uq_assignments_shared",
        "assignments",
        ["child_id", "assigned_on", "slot"],
        unique=True,
        postgresql_where=sa.text(f"slot IN ({_SHARED_SQL})"),
    )

    for table in ("families", "entitlements", "guardian_invites"):
        op.execute(
            f"CREATE TRIGGER trg_{table}_set_updated_at "
            f"BEFORE UPDATE ON {table} "
            f"FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
        )


def downgrade() -> None:
    # Restoring the single unique index is only safe once the per-guardian rows are gone,
    # which is why `user_id` is dropped in the same breath. Any second guardian's daily rows
    # would collide with the first's on the old key, so they are removed first — and that is
    # a real data loss, which is what makes this a downgrade rather than a rollback.
    op.drop_index("uq_assignments_shared", table_name="assignments")
    op.drop_index("uq_assignments_daily", table_name="assignments")
    # The bare name: the metadata naming convention expands it to
    # `ck_assignments_user_id_by_slot`, and passing the expanded name gets it expanded twice.
    op.drop_constraint("user_id_by_slot", "assignments", type_="check")
    op.execute(
        f"""
        DELETE FROM assignments a
        WHERE a.slot IN ({_DAILY_SQL})
          AND a.user_id IS DISTINCT FROM (
              SELECT g.user_id FROM guardians g
              WHERE g.child_id = a.child_id AND g.revoked_at IS NULL AND g.role = 'parent'
              ORDER BY g.granted_at, g.user_id
              LIMIT 1
          )
        """
    )
    op.create_unique_constraint(
        "uq_assignments_child_id_assigned_on_slot",
        "assignments",
        ["child_id", "assigned_on", "slot"],
    )
    op.drop_constraint(op.f("fk_assignments_user_id"), "assignments", type_="foreignkey")
    op.drop_column("assignments", "user_id")

    # Dropping a table drops its triggers; set_updated_at() itself belongs to 0001.
    op.drop_index("ix_guardian_invites_family_id", table_name="guardian_invites")
    op.drop_index("ix_guardian_invites_token_hash", table_name="guardian_invites")
    op.drop_table("guardian_invites")
    op.drop_table("entitlements")
    op.drop_index("ix_users_family_id", table_name="users")
    op.drop_constraint(op.f("fk_users_family_id"), "users", type_="foreignkey")
    op.drop_column("users", "family_id")
    op.drop_table("families")
