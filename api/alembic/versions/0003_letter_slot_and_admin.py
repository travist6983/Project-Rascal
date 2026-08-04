"""a letter slot, and an admin flag

Two changes that are trivial on an empty database and painful once there are entries and
accounts in it.

`letter` becomes a real slot. Letters are `cadence: monthly` and had no slot of their own,
so they competed with the measurement mission for `monthly` — meaning the money letter could
lose that coin flip every month for years. They now fire on the 15th, deliberately not the
1st: four items on one day breaks "two items is the most that survives a bad Tuesday".

`users.is_admin` gates writes to the mission library. `POST /prompts` was authenticated but
not authorized, so any future `viewer` login could have written to it.

Revision ID: 0003_letter_slot_and_admin
Revises: 0002_entry_type_artifact
Create Date: 2026-08-04
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003_letter_slot_and_admin"
down_revision: str | None = "0002_entry_type_artifact"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NEW_SLOTS = "'question', 'mission', 'weekly', 'monthly', 'letter'"
OLD_SLOTS = "'question', 'mission', 'weekly', 'monthly'"


def upgrade() -> None:
    op.drop_constraint("slot", "assignments", type_="check")
    op.create_check_constraint("slot", "assignments", f"slot IN ({NEW_SLOTS})")

    op.add_column(
        "users",
        sa.Column("is_admin", sa.Boolean(), server_default=sa.text("false"), nullable=False),
    )


def downgrade() -> None:
    op.drop_column("users", "is_admin")

    # Any letter assignments have to go first, or the narrower constraint cannot be created.
    op.execute("DELETE FROM assignments WHERE slot = 'letter'")
    op.drop_constraint("slot", "assignments", type_="check")
    op.create_check_constraint("slot", "assignments", f"slot IN ({OLD_SLOTS})")
