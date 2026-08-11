"""prompt_suppressions

The table behind "stop asking me this".

A dismissed prompt is otherwise excluded only by the same 180-day cooldown as every other one,
so a question about a mother in a household where that is painful — or a mission that assumes an
ability this child does not have — comes back. Forever, on a loop, for eighteen years. That is a
different failure from a repeat: it is the app asking something the parent has already told it to
stop asking.

**Suppression outranks every relaxation rule**, including an empty candidate pool. It is enforced
in `services/scheduler._candidates`, the single query both the scheduler and the Phase 12 read
path load candidates through, so a suppressed prompt is absent from the pool that the relaxed
cooldown, the dropped theme rotation and the final "anything at all" fallback each fall back to.
There is no ladder rung that can resurrect one.

Soft delete via `revoked_at`, like every other user-data table, so a permanent decision is one a
parent can undo and the change syncs as a row rather than as an absence.

Revision ID: 0007_prompt_suppressions
Revises: 0006_devices_and_notifications
Create Date: 2026-08-10
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID as PGUUID

revision = "0007_prompt_suppressions"
down_revision = "0006_devices_and_notifications"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "prompt_suppressions",
        sa.Column("child_id", PGUUID(as_uuid=True), nullable=False),
        sa.Column("prompt_id", PGUUID(as_uuid=True), nullable=False),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        # One row per (child, prompt) ever. Re-suppressing after an undo revives this row
        # instead of growing a second, which is what makes `POST` idempotent for free.
        sa.PrimaryKeyConstraint("child_id", "prompt_id", name="pk_prompt_suppressions"),
        sa.ForeignKeyConstraint(
            ["child_id"],
            ["children.id"],
            name="fk_prompt_suppressions_child_id",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["prompt_id"],
            ["prompts.id"],
            name="fk_prompt_suppressions_prompt_id",
            ondelete="CASCADE",
        ),
    )
    # The scheduler's exclusion subquery, in column order.
    op.create_index(
        "ix_prompt_suppressions_child_id_prompt_id_revoked_at",
        "prompt_suppressions",
        ["child_id", "prompt_id", "revoked_at"],
    )
    # `updated_at` is the trigger's, never application code's. Attached here rather than in
    # 0001 because 0001 is a snapshot of the eight tables it creates — see the note there.
    op.execute(
        "CREATE TRIGGER trg_prompt_suppressions_set_updated_at "
        "BEFORE UPDATE ON prompt_suppressions "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute(
        "DROP TRIGGER IF EXISTS trg_prompt_suppressions_set_updated_at ON prompt_suppressions"
    )
    op.drop_index(
        "ix_prompt_suppressions_child_id_prompt_id_revoked_at", table_name="prompt_suppressions"
    )
    op.drop_table("prompt_suppressions")
