"""children.pronouns

The column `docs/decisions.md` open item 10 has been blocked on since onboarding shipped.
Onboarding was supposed to be the unlock for pronoun-correct prompts and could not be: there
was nowhere to put the answer, so it does not ask, and the seeded library stays he/him.

**Nullable, and null is not "they/them".** A parent who skips the question has said nothing,
and rendering has to be able to tell that from an answer — falling back to the library's
existing wording is honest, guessing is the failure item 10 is trying to avoid.

A named CHECK rather than free text, per the constrained-value convention. The consumer is
pronoun substitution in prompt bodies, which has to enumerate the forms it writes; widening
the set later is a migration like this one, whereas storing text nothing can render is not
something a migration can undo.

Revision ID: 0005_child_pronouns
Revises: 0004_full_text_search
Create Date: 2026-08-10
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005_child_pronouns"
down_revision: str | None = "0004_full_text_search"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

PRONOUNS = "'he/him', 'she/her', 'they/them'"


def upgrade() -> None:
    op.add_column("children", sa.Column("pronouns", sa.Text(), nullable=True))
    # NULL passes a CHECK — `NULL IN (...)` is NULL, and a CHECK only fails on FALSE — so the
    # constraint constrains answers without requiring one.
    op.create_check_constraint("pronouns", "children", f"pronouns IN ({PRONOUNS})")


def downgrade() -> None:
    op.drop_constraint("pronouns", "children", type_="check")
    op.drop_column("children", "pronouns")
