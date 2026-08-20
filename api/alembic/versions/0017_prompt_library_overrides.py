"""Phase 96. Admin decisions about the seeded library that survive a re-seed.

One table, keyed on the seed loader's own idempotency key rather than on a prompt id. It
exists because `seed_prompts` runs on `fly.toml`'s `release_command` and reconciles the
`prompts` table against `api/seeds/prompts.yaml` *totally* — including the `active` column —
so any decision made outside the file is undone by the next deploy. `models/library_override.py`
carries the long form.

No `deleted_at`: the mission library is content, not user data, `prompts` itself has no soft
delete, and withdrawing an override is a real DELETE — which is exactly what hands the
decision back to the file.

Revision ID: 0017_prompt_library_overrides
Revises: 0016_email_broadcasts
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0017_prompt_library_overrides"
down_revision = "0016_email_broadcasts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "prompt_library_overrides",
        sa.Column("content_hash", sa.Text(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_by_user_id", sa.UUID(), nullable=True),
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
        # SET NULL rather than CASCADE: the decision is about the library, not about the
        # person who made it, and it has to outlive their account.
        sa.ForeignKeyConstraint(
            ["created_by_user_id"],
            ["users.id"],
            name=op.f("fk_prompt_library_overrides_created_by_user_id"),
            ondelete="SET NULL",
        ),
        # `content_hash` is the primary key on purpose. There is no shape of this table that
        # should be able to hold two opinions about one prompt.
        sa.PrimaryKeyConstraint("content_hash", name=op.f("pk_prompt_library_overrides")),
    )
    op.execute(
        "CREATE TRIGGER trg_prompt_library_overrides_set_updated_at "
        "BEFORE UPDATE ON prompt_library_overrides "
        "FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    )


def downgrade() -> None:
    op.execute(
        "DROP TRIGGER IF EXISTS trg_prompt_library_overrides_set_updated_at "
        "ON prompt_library_overrides"
    )
    op.drop_table("prompt_library_overrides")
