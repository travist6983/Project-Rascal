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

#: `exported` means a file left the console. `published` used to mean only that the owner had
#: posted it somewhere by hand.
#:
#: **Superseded Aug 20, 2026 by phase 104: this service now posts to Instagram**, at the
#: owner's direct request, and sets `published` itself when it does. The sentence that stood
#: here — *"nothing in this service posts anything"* — was an agent's design stance rather than
#: a decision in `docs/decisions.md`, and the owner did not recognise it when asked. It is kept
#: as history rather than deleted because a claim about what the code did on a date is a true
#: statement about that date. `published` still means "this went out", and it is still set by
#: hand when the owner posts somewhere this service cannot reach.
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

    #: Video. **The scene graph, `{"scenes": [...]}`** — an ordered list of cards, each naming
    #: a template, a palette, its copy, how long it holds and how it enters, every value from a
    #: closed set. Renamed from `shot_list` by phase 120: what it held was prose direction for a
    #: camera that does not exist, and a column called `shot_list` holding a scene graph would
    #: be the kind of name that survives a rewrite and misleads everybody after it.
    #:
    #: `caption_track` is **derived** from the scenes by `services/social/scenes.py` and never
    #: authored beside them. Two artifacts describing one video, written in one pass with
    #: nothing checking that they agreed, is the defect that rename is really about.
    treatment: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
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
    #: When this went out. Set by hand for a post the owner made somewhere this service cannot
    #: reach, and set by `services/social/instagram.py` for one it published itself — phase 104,
    #: which is why the sentence that used to end this comment is in the note above `published`
    #: rather than here.
    #:
    #: The authoritative record of a publish this service performed is the `social_publications`
    #: row, which carries the media id, the permalink and the caption that actually went out.
    #: This column is the answer to "has it gone out at all", cheap to read on the list screen.
    published_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]


#: Where one attempt got to. `publishing` is a claim held for the length of one attempt, so a
#: second worker walking the queue steps over a row that is currently mid-flight at Meta.
PUBLICATION_STATUSES: tuple[str, ...] = (
    "scheduled",
    "publishing",
    "published",
    "failed",
    "cancelled",
)


class SocialPublication(Base):
    """One attempt to put an asset on a platform — scheduled, in flight, done, or failed.

    **The asset says what was written. This says what happened to it.** They are separate rows
    because an asset stays editable after a post goes out, and a ledger that reads the current
    draft to tell you what was published is a ledger that rewrites history. `caption`,
    `alt_text` and `image_key` are therefore snapshots taken at publish time and never read
    back from the asset.

    **`container_id` is written before the publish call.** Meta's flow is two requests — build
    a container from a public image URL, then publish it — and the gap between them is the only
    place in this pipeline where a failure is unrecoverable: a post lands on a public feed and
    nothing here knows, so the next attempt sends it again. A duplicate on a public feed is the
    one outcome strangers see and nothing on our side can undo. Recording the container first
    does not prevent it; it makes it diagnosable, and it lets the next attempt ask Meta about a
    specific container rather than guessing.
    """

    __tablename__ = "social_publications"
    __table_args__ = (
        one_of("platform", SOCIAL_PLATFORMS, name="platform"),
        one_of("status", PUBLICATION_STATUSES, name="status"),
        Index("ix_social_publications_status_scheduled_for", "status", "scheduled_for"),
        Index("ix_social_publications_asset_id", "asset_id"),
        # Two rows must never claim one post. The service checks Instagram before publishing
        # and refuses on an asset that has already gone out — but both of those are decisions
        # made in Python by one process, and this is the one that survives two.
        Index(
            "uq_social_publications_media_id",
            "media_id",
            unique=True,
            postgresql_where=text("media_id IS NOT NULL"),
        ),
        # One live attempt per asset, so pressing publish twice cannot queue two posts.
        Index(
            "uq_social_publications_live_per_asset",
            "asset_id",
            unique=True,
            postgresql_where=text("status IN ('scheduled', 'publishing')"),
        ),
    )

    id: Mapped[uuid_pk]
    asset_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("social_assets.id", ondelete="CASCADE"), nullable=False
    )
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(Text, server_default="scheduled")

    #: NULL means "the next time the queue looks", which is what an immediate publish sets.
    #: UTC, and compared against `now()` — the child-timezone rule is about a child's day and
    #: there is no child in a marketing post.
    scheduled_for: Mapped[optional_moment]

    image_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    caption: Mapped[str | None] = mapped_column(Text, nullable=True)
    alt_text: Mapped[str | None] = mapped_column(Text, nullable=True)

    container_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    media_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    permalink: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Why the last attempt failed, in the words Meta used. Kept on the row rather than only in
    #: the log, because the person who needs it is looking at the console rather than at Fly.
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))

    published_at: Mapped[optional_moment]
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[created]
    updated_at: Mapped[updated]


#: A render attempt's life. **Only `succeeded` and `failed` are reachable since phase 120** —
#: the work happens inside the request, so nothing can leave a row live and nothing can cancel
#: one. The other three are kept unwritten rather than dropped, for the same reason `cost_cents`
#: is kept at zero: they are the shape an asynchronous path needs, and a narrowed CHECK would be
#: a decision to reverse rather than a tidy-up. Their original justification — that a job the
#: machine restarted out from under is not the same fact as one the vendor refused — applies to
#: that path if it returns, and to nothing today.
SOCIAL_RENDER_STATUSES: tuple[str, ...] = (
    "queued",
    "running",
    "succeeded",
    "failed",
    "cancelled",
)


class SocialRender(Base):
    """One attempt to record a scene graph into a video.

    **An attempt, not a property of the post.** A post stays editable after a file is made, so
    a table that read the current draft to tell you what was rendered would be rewriting
    history. `SocialAsset.render_key` holds the artifact a post currently shows; this holds the
    attempt that produced it, including the ones that failed.

    **Phase 120 writes only terminal statuses.** The work is a few seconds of ffmpeg inside the
    request, so no row is ever left live and there is nothing to poll, reap or refuse a second
    of. `queued`, `running`, `cancelled` and the partial unique index below are kept unwritten
    rather than dropped, for the same reason `cost_cents` is kept and set to zero: they are the
    shape an asynchronous path needs, and taking them out would be a decision to reverse rather
    than a tidy-up.
    """

    __tablename__ = "social_renders"
    __table_args__ = (
        one_of("status", SOCIAL_RENDER_STATUSES, name="status"),
        Index("ix_social_renders_asset_id_created_at", "asset_id", text("created_at DESC")),
        # **Unwritten since phase 120, and kept deliberately.** Nothing sets `queued` or
        # `running` any more — the work happens inside the request — so this index can no
        # longer fire. It stays because it is the guarantee an asynchronous path needs on the
        # day one exists, and re-deriving "two overlapping requests can both pass a read then
        # both insert" from scratch is how that path ships without it.
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

    #: Recorded per attempt rather than read at display time. `provider` is `canvas` — the
    #: pixels come from `admin/static/cards.js` in the operator's own browser and no vendor is
    #: involved — and `model` is the renderer's version string, bumped when the templates move
    #: enough that an old render no longer matches a new one. A render from last month should
    #: still be able to say what actually drew it.
    provider: Mapped[str] = mapped_column(Text, nullable=False)
    model: Mapped[str] = mapped_column(Text, nullable=False)

    #: How many cards were in the graph. Renamed from `shots_total` by phase 120, and `clip_keys`
    #: went with the clips: the browser records one continuous capture, so there is nothing to
    #: count landing and nothing to concatenate.
    scene_count: Mapped[int] = mapped_column(Integer, server_default="0")
    render_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: One sentence. Never a stack trace, and never a URL carrying a key.
    error: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: **Zero, and written down rather than dropped.** Nothing is bought to make one of these,
    #: and that is the finding phase 120 exists to produce — a ledger that stops recording when
    #: the number becomes zero is a ledger that cannot show you it went to zero. It is also the
    #: column a future generated-footage path would need back.
    cost_cents: Mapped[int] = mapped_column(Integer, server_default="0")

    started_at: Mapped[optional_moment]
    finished_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]
