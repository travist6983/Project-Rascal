"""entry_type describes the artifact

`entry_type` used to be denormalized from the originating prompt, so a `did_it` completion
of an audio mission was stored as an audio entry and the Voice filter surfaced entries with
no audio in them. It now describes what the entry actually contains, which means the value
set narrows to what the derivation can produce — and gains `did_it`, which it could not
express before.

The prompt that caused the entry is still recoverable through `assignment_id` ->
`prompt.kind`, so nothing is lost.

Revision ID: 0002_entry_type_artifact
Revises: 0001_initial
Create Date: 2026-08-04
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0002_entry_type_artifact"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# What the derivation can produce: the media kind, or text, or did_it.
NEW_VALUES = "'photo', 'video', 'audio', 'text', 'did_it'"

# What it produced when it was copied from prompt.kind.
OLD_VALUES = "'question', 'photo', 'video', 'audio', 'activity', 'measurement', 'letter', 'text'"


def upgrade() -> None:
    # Rewriting rather than backfilling: this ships while the database is empty, which is the
    # whole reason it ships now.
    op.drop_constraint("entry_type", "entries", type_="check")
    op.create_check_constraint("entry_type", "entries", f"entry_type IN ({NEW_VALUES})")


def downgrade() -> None:
    op.drop_constraint("entry_type", "entries", type_="check")
    op.create_check_constraint("entry_type", "entries", f"entry_type IN ({OLD_VALUES})")
