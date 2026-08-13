"""the `his-words` theme becomes `their-words`

The theme slug was the last gendered string the seeded library carried. Phase 24 tokenised
all 113 bodies and left this behind, because a theme is not copy — it renders nowhere in the
app and reaches nobody's screen. It is still a value in a permanent archive that says `his`
about a child who may not be one, which is the whole of the argument for changing it.

**Most of this rename does not need a migration, and that is worth stating so the next
reader does not go looking for the missing half.** `theme` is in `seeding.MUTABLE_FIELDS`
but is *not* part of `sha256(kind, cadence, body)`, so editing the theme in
`docs/mission-library.md` and re-seeding updates the live rows in place — same prompt, same
id, new theme. What re-seeding cannot reach is every seeded row the file no longer contains:
the 99 literal-bodied prompts phase 24 retired. They keep serving nothing, and they keep
`his-words` forever, because the loader will never see them again.

So this migration exists for the rows nothing else can touch. It updates **every** row
holding the old value rather than only the retired ones, which makes it independent of
whether `make seed` runs before or after it — an ordering constraint between a migration and
a seed job is exactly the kind of thing that is true on the day it is written and false the
next time somebody deploys.

**Those retired rows are not inert, which is why this is not a tidying migration.**
`scheduler.py`'s `recent_themes` joins assignments to prompts with **no `active` filter**, so
an assignment that points at a retired prompt still contributes that prompt's theme to the
two-day rotation guard. Rename the library and skip this, and those assignments keep feeding
`his-words` into a set that is compared against themes no active prompt has any more — the
guard quietly stops excluding anything for the affected picks. It never errors and never
shows up anywhere. It is a lost preference, which is the kind of bug that survives for years.

**Tags are deliberately not migrated.** `tags.name` shares vocabulary with `prompts.theme`
by convention and by nothing else — no code path copies one to the other (`entries.py` builds
tags only from client-supplied names). A tag is a word a parent or the on-device model chose
about one particular entry, and rewriting it would be rewriting the parent's own record of
their child. If a household typed `his-words` on an entry, that is their sentence and it
stays. Recorded in `docs/decisions-log.md`.

Revision ID: 0009_neutral_theme_slug
Revises: 0008_mission_b_slot
Create Date: 2026-08-13
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0009_neutral_theme_slug"
down_revision: str | None = "0008_mission_b_slot"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Frozen literals rather than an import of `rascal.constants.THEMES`, per the rule 0001 states
# and 0008 repeats: a migration is pinned to the schema at its own point in history, and one
# that reads a live constant silently changes meaning the next time that constant does.
OLD_THEME = "his-words"
NEW_THEME = "their-words"


def upgrade() -> None:
    # `theme` has no CHECK constraint — deliberately, per `constants.py`, so the library can
    # grow themes without a migration. That is why this is a bare UPDATE and not a
    # drop-and-recreate around one: there is no constraint to widen, and nothing to fail if a
    # row somewhere holds a theme this chain has never heard of.
    op.execute(f"UPDATE prompts SET theme = '{NEW_THEME}' WHERE theme = '{OLD_THEME}'")


def downgrade() -> None:
    # Exactly reversible, and losslessly so: the two values are in one-to-one correspondence
    # and no row can legitimately hold the new value for any other reason at this revision.
    op.execute(f"UPDATE prompts SET theme = '{OLD_THEME}' WHERE theme = '{NEW_THEME}'")
