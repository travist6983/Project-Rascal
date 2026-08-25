"""Phase 120. The scene graph replaces the shot list, and there are no clips.

**Three changes, and all three are renames or removals of names that stopped being true.**

`social_assets.shot_list` → `treatment`. The column held prose direction for a camera —
`visual`, `on_screen_text`, `voiceover` — because a vendor generated footage from it. It now
holds `{"scenes": [...]}`, an ordered list of brand cards the browser draws. A column called
`shot_list` holding a scene graph is exactly the kind of name that survives a rewrite and
misleads everybody who reads it afterwards, so it moves with the thing it names.

`social_renders.shots_total` → `scene_count`, same argument one table over.

`social_renders.clip_keys` is **dropped**. Seven shots were seven separate generations, so the
honest unit of progress was clips landed and this array was the progress bar. The browser now
records one continuous capture; there is nothing to land one at a time and nothing to
concatenate. **Any object those keys pointed at stays in the bucket** — this drops the pointer,
not the bytes — and that is recorded rather than discovered: at the time of writing production
holds zero `social_renders` rows and the only affected objects are seven clips from local
development runs.

**Reversible, and the reverse is honest about what it cannot do.** `downgrade` restores
`clip_keys` as an empty array on every row, because the keys are gone and inventing them is
worse than an empty column that says so. The two renames reverse exactly.

**A rename rather than add-copy-drop**, deliberately. `ALTER TABLE ... RENAME COLUMN` keeps
the data, keeps the type, and is instant; the three-step dance would be the right call only if
something had to read both names at once, and nothing does — this API has one client, the
console, and it ships in the same image.

Revision ID: 0023_canvas_video
Revises: 0022_entitlement_trial
Create Date: 2026-08-25
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0023_canvas_video"
down_revision = "0022_entitlement_trial"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("social_assets", "shot_list", new_column_name="treatment")
    op.alter_column("social_renders", "shots_total", new_column_name="scene_count")
    op.drop_column("social_renders", "clip_keys")


def downgrade() -> None:
    op.alter_column("social_assets", "treatment", new_column_name="shot_list")
    op.alter_column("social_renders", "scene_count", new_column_name="shots_total")
    # `server_default` and `nullable=False` together, so an existing row gets `'{}'` rather
    # than a NULL the original column could never hold. The keys themselves are not
    # recoverable — see the docstring — and an empty array is the only honest answer.
    op.add_column(
        "social_renders",
        sa.Column(
            "clip_keys",
            sa.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )
