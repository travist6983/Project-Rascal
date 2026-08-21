"""Social posts the studio produced. Marketing output, not user data.

**Why there is no `deleted_at`, and why that is not a second exception to rule 5.** The rule
covers user-data tables — the ones `/sync` carries and a client has to learn deletions from.
This is marketing content the owner authors about the product, and it follows the table it
most resembles: `email_broadcasts`, which is also marketing output, also carries `updated_at`,
and also has no soft delete. Throwing a draft away sets `status = 'discarded'`, which says
more than a tombstone would — it is a decision about a concept rather than the disappearance
of a record, and the counter in `featured_body` depends on being able to tell those apart.

**`featured_body` is the one column here that is load-bearing rather than convenient.**
`docs/decisions.md` D7 says the mission library never leaves this repo *"whole or in generated
slices"* and calls it the one asset a competitor would actually want. A social studio that can
put a prompt on a card is a machine for producing exactly those slices, publicly and
permanently, one post at a time. So every body that reaches a post is snapshotted here and
counted, and the Studio shows the running total against the size of the library. A snapshot
rather than the foreign key alone, because a prompt can be forked by the library editor and
the row `featured_prompt_id` points at may no longer hold the words that went out.
"""

from __future__ import annotations

import uuid

from sqlalchemy import ARRAY, ForeignKey, Index, Integer, Text, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from rascal.models.base import Base, created, one_of, optional_moment, updated, uuid_pk

#: Where a post is going. `generic` exists so a concept can be written before the platform is
#: decided rather than forcing a guess that then drives the aspect ratio.
SOCIAL_PLATFORMS: tuple[str, ...] = (
    "instagram",
    "instagram_story",
    "x",
    "threads",
    "facebook",
    "linkedin",
    "generic",
)

#: `exported` means a file left the console. `published` is set by hand by the owner after
#: they actually post it — **nothing in this service posts anything**, so `published` is a
#: record of something that happened elsewhere and never a thing the code causes.
SOCIAL_STATUSES: tuple[str, ...] = ("draft", "approved", "exported", "published", "discarded")

#: `card` is drawn in the browser from a template. `photo` and `video` need a third-party
#: renderer — see `services/social/renderers.py`.
SOCIAL_FORMATS: tuple[str, ...] = ("card", "photo", "video")


class SocialAsset(Base):
    """One post concept, its words, and whatever was rendered from it."""

    __tablename__ = "social_assets"
    __table_args__ = (
        one_of("platform", SOCIAL_PLATFORMS, name="platform"),
        one_of("status", SOCIAL_STATUSES, name="status"),
        one_of("format", SOCIAL_FORMATS, name="format"),
        # The studio's own list: newest first, and the status filter it always carries.
        Index("ix_social_assets_status_created_at", "status", text("created_at DESC")),
        # The D7 counter. Partial, because a discarded draft never went anywhere and must not
        # count against the library — and a partial index is what keeps that distinction in
        # the schema rather than in whichever query remembers to filter.
        Index(
            "ix_social_assets_featured_prompt_id",
            "featured_prompt_id",
            postgresql_where=text("featured_prompt_id IS NOT NULL AND status <> 'discarded'"),
        ),
    )

    id: Mapped[uuid_pk]
    platform: Mapped[str] = mapped_column(Text, server_default="generic")
    status: Mapped[str] = mapped_column(Text, server_default="draft")
    format: Mapped[str] = mapped_column(Text, server_default="card")

    #: What this post is arguing, in a clause. Kept because two concepts with the same angle
    #: are one concept, and the angle is the only field that makes that checkable.
    angle: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: Card copy. `template` and `palette` are validated against `services/social/brand.py`
    #: rather than a CHECK: the renderer is the thing that has to know them, it lives in
    #: JavaScript, and a constraint here would be a second list to keep in step.
    template: Mapped[str | None] = mapped_column(Text, nullable=True)
    palette: Mapped[str | None] = mapped_column(Text, nullable=True)
    headline: Mapped[str | None] = mapped_column(Text, nullable=True)
    subhead: Mapped[str | None] = mapped_column(Text, nullable=True)

    caption: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: **Not the caption.** What is visibly in the image, for somebody who cannot see it.
    #: Nullable in the column and required by the console before an asset may be exported,
    #: because the moment to insist is when the file is about to leave rather than while
    #: somebody is still typing.
    alt_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    hashtags: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, server_default=text("'{}'::text[]")
    )

    #: Written even when no photographic provider is configured. It costs nothing now and is
    #: the expensive half to reconstruct the day one is connected.
    image_prompt: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Video. The shot list as the model wrote it, and the caption track derived from it.
    shot_list: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    caption_track: Mapped[str | None] = mapped_column(Text, nullable=True)
    duration_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)

    #: Where the bytes went, when a provider produced any. A key and never a URL — a signed
    #: URL in a column outlives its signature and then looks like data loss, which is the same
    #: reason `media` stores keys and mints URLs on demand.
    render_provider: Mapped[str | None] = mapped_column(Text, nullable=True)
    render_key: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: The D7 ledger. See the module docstring.
    featured_prompt_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("prompts.id", ondelete="SET NULL"), nullable=True
    )
    featured_body: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Which model wrote it. Recorded rather than assumed: `ANTHROPIC_MODEL` is overridable,
    #: and "why did the voice change in March" is a question only this column can answer.
    model: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    #: Set by hand when the owner posts it somewhere. Nothing in this service writes it as a
    #: side effect of sending, because nothing in this service sends.
    published_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]


#: A render attempt's life. `cancelled` exists because a job that the machine restarted out
#: from under is not the same fact as one the vendor refused, and a status that cannot tell
#: them apart is a status somebody has to go and check the logs about.
SOCIAL_RENDER_STATUSES: tuple[str, ...] = (
    "queued",
    "running",
    "succeeded",
    "failed",
    "cancelled",
)


class SocialRender(Base):
    """One attempt to turn a shot list into a video.

    **An attempt, not a property of the post.** It takes minutes, it can fail on the seventh
    of seven clips, and the retry must not erase what the first attempt already paid for.
    `SocialAsset.render_key` holds the artifact a post currently shows; this holds the job.
    """

    __tablename__ = "social_renders"
    __table_args__ = (
        one_of("status", SOCIAL_RENDER_STATUSES, name="status"),
        Index("ix_social_renders_asset_id_created_at", "asset_id", text("created_at DESC")),
        # **Unique, not merely indexed.** `preflight` reads for a live render and then inserts,
        # and two overlapping requests can both pass that read — which pays for the same seven
        # clips twice. The index makes it impossible rather than unlikely, and doubles as the
        # "is anything still running" lookup.
        Index(
            "uq_social_renders_one_live_per_asset",
            "asset_id",
            unique=True,
            postgresql_where=text("status IN ('queued', 'running')"),
        ),
    )

    id: Mapped[uuid_pk]
    asset_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("social_assets.id", ondelete="CASCADE"), nullable=False
    )
    status: Mapped[str] = mapped_column(Text, server_default="queued")

    #: Recorded per attempt rather than read from config when displayed. Every video model on
    #: the Gemini API is preview and the ids move; a render from last month should still be
    #: able to say what actually made it.
    provider: Mapped[str] = mapped_column(Text, nullable=False)
    model: Mapped[str] = mapped_column(Text, nullable=False)

    shots_total: Mapped[int] = mapped_column(Integer, server_default="0")
    #: Object keys in shot order, and the length of this is the progress. Seven shots are seven
    #: generations — nothing stitches them for us — so clips landed is the honest unit.
    clip_keys: Mapped[list[str]] = mapped_column(
        ARRAY(Text), nullable=False, server_default=text("'{}'::text[]")
    )
    render_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: One sentence. Never a stack trace, and never a URL carrying a key.
    error: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Written as clips land, including on a job that later fails. The money is spent when the
    #: clip is generated, not when the job succeeds, and a ledger that records only successful
    #: spend is how a bill becomes a surprise.
    cost_cents: Mapped[int] = mapped_column(Integer, server_default="0")

    started_at: Mapped[optional_moment]
    finished_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]
