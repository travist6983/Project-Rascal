"""full-text search over titles, bodies, and transcripts

Two stored generated `tsvector` columns and a GIN index on each. Generated rather than
trigger-maintained because a generated column cannot drift: there is no window in which the
row is written and the vector is not, and no backfill to remember after a bulk `UPDATE`.

`media.search_vector` is what makes rule 7 pay off. The phone transcribes on device and
`PATCH /media/{id}/derived` persists the text; the moment that lands, the words a four-year-
old said out loud are searchable from anything that speaks HTTP — including the browser in
2027 that will never have an on-device model.

Weights, highest first: title, then body and transcript, then caption. A word in the title
you gave the entry is a stronger signal than the same word two hundred words into it.

Revision ID: 0004_full_text_search
Revises: 0003_letter_slot_and_admin
Create Date: 2026-08-04
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0004_full_text_search"
down_revision: str | None = "0003_letter_slot_and_admin"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# 'english' is spelled out rather than left to default_text_search_config, because a
# generated column's expression must be IMMUTABLE and `to_tsvector(text)` is not — it reads
# a GUC. Naming the configuration is what makes this legal, and it also means the index does
# not silently change meaning if the server's default is ever retuned.
ENTRY_VECTOR = (
    "setweight(to_tsvector('english', coalesce(title, '')), 'A') || "
    "setweight(to_tsvector('english', coalesce(body, '')), 'B')"
)
MEDIA_VECTOR = (
    "setweight(to_tsvector('english', coalesce(transcript, '')), 'B') || "
    "setweight(to_tsvector('english', coalesce(caption, '')), 'C')"
)


def upgrade() -> None:
    op.execute(
        f"ALTER TABLE entries ADD COLUMN search_vector tsvector "
        f"GENERATED ALWAYS AS ({ENTRY_VECTOR}) STORED"
    )
    op.execute(
        f"ALTER TABLE media ADD COLUMN search_vector tsvector "
        f"GENERATED ALWAYS AS ({MEDIA_VECTOR}) STORED"
    )

    op.create_index(
        "ix_entries_search_vector",
        "entries",
        ["search_vector"],
        postgresql_using="gin",
    )
    op.create_index(
        "ix_media_search_vector",
        "media",
        ["search_vector"],
        postgresql_using="gin",
    )


def downgrade() -> None:
    op.drop_index("ix_media_search_vector", table_name="media")
    op.drop_index("ix_entries_search_vector", table_name="entries")
    # Dropping the column takes its generation expression with it; nothing to unwind.
    op.drop_column("media", "search_vector")
    op.drop_column("entries", "search_vector")
