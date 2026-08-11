"""a second daily mission slot

The day goes from two daily assignments to three. `mission` narrows to photo prompts only
and a new `mission_b` takes video, audio and activity — the kinds `mission` used to share
with photo. Weekly, monthly and letter are untouched and still fire on top, so a Saturday is
now four items, the 15th is four, and a Saturday the 15th is five.

`mission` keeps its name while its meaning narrows. Renaming it to `photo` would mean
migrating every existing assignment row and touching the widget, the push ladder, the Today
board and the suite, for a cosmetic gain. **Historical `mission` rows holding activity, audio
and video prompts stay exactly as they are and are correct for the day they were served** —
see `docs/decisions.md`. A future reader finding an activity prompt in a `mission` slot is
looking at history, not a bug.

Revision ID: 0008_mission_b_slot
Revises: 0007_prompt_suppressions
Create Date: 2026-08-11
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0008_mission_b_slot"
down_revision: str | None = "0007_prompt_suppressions"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Frozen literals rather than an import of `rascal.constants.SLOTS`, for the reason 0001 now
# spells out: a migration is pinned to the schema at its own point in history, and one that
# reads a live constant silently changes meaning the next time that constant does.
NEW_SLOTS = "'question', 'mission', 'mission_b', 'weekly', 'monthly', 'letter'"
OLD_SLOTS = "'question', 'mission', 'weekly', 'monthly', 'letter'"


def upgrade() -> None:
    # The unique index on (child_id, assigned_on, slot) needs no change: `mission_b` is a new
    # value in an existing column, so one row per slot per day already covers it.
    op.drop_constraint("slot", "assignments", type_="check")
    op.create_check_constraint("slot", "assignments", f"slot IN ({NEW_SLOTS})")


def downgrade() -> None:
    # The rows go first. Postgres will not create a CHECK that existing rows violate, so a
    # downgrade that left them would fail outright — and a migration that cannot be reversed
    # in practice is the thing every migration in this chain promises not to be. `0002`'s
    # letter-slot downgrade is the pattern.
    #
    # This destroys data, which is correct here and worth stating: a `mission_b` assignment
    # has no representable slot at the previous revision. Entries and notification_sends
    # referencing these rows survive with their `assignment_id` nulled, because both foreign
    # keys are ON DELETE SET NULL — the archive keeps the entry and loses only the link to
    # what asked for it.
    op.execute("DELETE FROM assignments WHERE slot = 'mission_b'")
    op.drop_constraint("slot", "assignments", type_="check")
    op.create_check_constraint("slot", "assignments", f"slot IN ({OLD_SLOTS})")
