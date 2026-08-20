"""An admin decision about a seeded prompt that has to survive the next re-seed.

**Why this table exists at all.** `api/seeds/prompts.yaml` is on `fly.toml`'s
`release_command`, so every deploy reconciles the `prompts` table against the file. The
reconciliation is total: `seed_prompts` upserts every row in the file — including its
`active` column — and deactivates every `source="seeded"` row the file no longer contains.

That is correct for a library authored in `docs/mission-library.md`, and it makes an edit
made anywhere else evaporate on the next deploy. Retire a seeded prompt from the admin
console and the upsert sets `active` back to the file's value within minutes. Edit a seeded
prompt's body and it is worse: the body is part of `content_hash`, so the edited row is a
row the file does not contain — it gets retired — *and* the original body is re-inserted,
which leaves the archive serving exactly the copy the edit was meant to replace.

So the console's writes need somewhere the reconciler will read rather than overwrite. One
row here says: **whatever `prompts.yaml` says about this prompt's `active`, the library says
this.** `seed_prompts` applies these last, after the upsert and after the retirement sweep,
so an override is the final word by construction rather than by ordering luck.

**Keyed on `content_hash`, not on `prompts.id`.** The hash is the identity the seed file and
the table already agree on; a prompt id is a row that a re-seed can legitimately replace. An
override written against an id would stop matching the moment the row it named was rebuilt.

**No `deleted_at`, and that is not an exception to rule 5.** The mission library is content,
not user data — `prompts` itself carries no soft delete and does not sync. Withdrawing an
override is a real `DELETE`, which is what restores the file's own opinion of the prompt on
the next seed. There is nothing for a client to learn about, because no client reads this.
"""

from __future__ import annotations

import uuid

from sqlalchemy import Boolean, ForeignKey, Text
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from rascal.models.base import Base, created, updated


class PromptLibraryOverride(Base):
    """One admin decision about one seeded prompt, keyed on the seed loader's own key."""

    __tablename__ = "prompt_library_overrides"

    #: `sha256(kind, cadence, body)` — `services.seeding.content_hash`. The primary key,
    #: because there is no shape of this table that should hold two opinions about one prompt.
    content_hash: Mapped[str] = mapped_column(Text, primary_key=True)

    #: The value the seed loader must write instead of the file's. `False` retires a prompt
    #: the file still lists; `True` revives one the file has dropped or shipped inactive.
    active: Mapped[bool] = mapped_column(Boolean)

    #: Why, in the admin's words. Free text and optional, for the same reason
    #: `prompt_suppressions.reason` is: the useful reasons are the ones nobody enumerated.
    #: The console writes "superseded by <id>" here when an edit forks a seeded body.
    note: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Who decided. `SET NULL` rather than `CASCADE`: an override outlives the account that
    #: wrote it, because the decision is about the library and not about the person.
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    created_at: Mapped[created]
    updated_at: Mapped[updated]
