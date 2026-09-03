"""Phase 142. Four indexes the admin console's reads were paying for, and the card line it dropped.

`GET /admin/snapshot` charts sixty days of entries and media by `created_at`, and its
newest-accounts table counts entries per author for twelve accounts; `GET /admin/library` counts
served and done assignments per prompt for one page. None of those columns had an index, so each
read scanned its whole table — work that grew with the archive's total size rather than with the
window or the page being asked for. The scans were found by reading the queries against the
schema rather than by a slow page: at one household they are invisible, and at hundreds they are
the console's whole load time on a replica that also cold-starts.

**Plain B-tree indexes, all named, all reversible.** No data moves, no constraint is added.
`ix_entries_child_id_occurred_at` is the timeline's index and is untouched — it leads with
`child_id`, so it cannot serve a range over `created_at` across every child, which is what a
chart of the whole service asks for.

**One nullable text column on `social_assets`: `eyebrow`.** The Studio composer has drawn an
eyebrow on every card since it shipped — it is in the JPEG that gets published — and stored it
nowhere, so reopening a saved post rendered a card without it. Nothing is backfilled because
nothing was ever kept; posts saved before this revision reopen without the line they went out
with, which is the state they were already in.

`.github/scripts/verify_schema.py` and `tests/test_migrations.py` both gain the four index
names, so a provider that quietly drops one is caught.

Revision ID: 0026_console_indexes
Revises: 0025_apple_refresh_token
Create Date: 2026-09-03
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0026_console_indexes"
down_revision = "0025_apple_refresh_token"
branch_labels = None
depends_on = None

INDEXES = (
    ("ix_entries_created_at", "entries", ["created_at"]),
    ("ix_entries_author_id", "entries", ["author_id"]),
    ("ix_media_created_at", "media", ["created_at"]),
    ("ix_assignments_prompt_id", "assignments", ["prompt_id"]),
)


def upgrade() -> None:
    for name, table, columns in INDEXES:
        op.create_index(name, table, columns)
    op.add_column("social_assets", sa.Column("eyebrow", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("social_assets", "eyebrow")
    for name, table, _ in reversed(INDEXES):
        op.drop_index(name, table_name=table)
