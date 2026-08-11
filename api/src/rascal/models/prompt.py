"""The mission library. Content, not user data."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import ARRAY, Boolean, DateTime, ForeignKey, Index, Integer, Text, text
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from rascal.constants import (
    CADENCES,
    COMPLETION_MODES,
    PROMPT_KINDS,
    PROMPT_SOURCES,
    Cadence,
    CompletionMode,
    PromptKind,
    PromptSource,
)
from rascal.models.base import Base, created, one_of, updated, uuid_pk


class Prompt(Base):
    __tablename__ = "prompts"
    __table_args__ = (
        one_of("kind", PROMPT_KINDS, name="kind"),
        one_of("cadence", CADENCES, name="cadence"),
        one_of("completion_mode", COMPLETION_MODES, name="completion_mode"),
        one_of("source", PROMPT_SOURCES, name="source"),
        # The scheduler's candidate-pool query, in column order.
        Index(
            "ix_prompts_kind_cadence_active_age",
            "kind",
            "cadence",
            "active",
            "min_age_months",
            "max_age_months",
        ),
        # The seed loader's idempotency key: a stable hash of (kind, cadence, body).
        Index("ix_prompts_content_hash", "content_hash", unique=True),
    )

    id: Mapped[uuid_pk]
    kind: Mapped[PromptKind] = mapped_column(Text)
    cadence: Mapped[Cadence] = mapped_column(Text)
    completion_mode: Mapped[CompletionMode] = mapped_column(Text)
    body: Mapped[str] = mapped_column(Text)
    theme: Mapped[str] = mapped_column(Text)
    min_age_months: Mapped[int] = mapped_column(Integer)
    max_age_months: Mapped[int] = mapped_column(Integer)
    # Seasonal restriction, e.g. {10,11,12}. Empty means any month.
    month_tags: Mapped[list[int]] = mapped_column(
        ARRAY(Integer), nullable=False, server_default=text("'{}'::int[]")
    )
    source: Mapped[PromptSource] = mapped_column(Text)
    # Letters default to sealed; everything else leaves this null.
    default_unlock_age: Mapped[int | None] = mapped_column(Integer, nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, server_default=text("true"))
    # Not in docs/data-model.md: the seed loader keys on it so re-seeding updates in place
    # instead of duplicating. See docs/decisions-log.md.
    content_hash: Mapped[str] = mapped_column(Text)
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    def covers_age(self, age_months: int) -> bool:
        """Both bounds inclusive, per docs/data-model.md."""
        return self.min_age_months <= age_months <= self.max_age_months

    def covers_month(self, month: int) -> bool:
        return not self.month_tags or month in self.month_tags


class PromptSuppression(Base):
    """A prompt this family never wants to see again.

    **The reason this outranks every relaxation rule.** A dismissed prompt is otherwise excluded
    only by the same 180-day cooldown as any other, so a question about a mother in a household
    where that is painful, or a mission assuming an ability this child does not have, comes back
    — forever, on a loop, for eighteen years. Being asked something you have already told the app
    to stop asking is a different kind of failure from seeing a repeat.

    So suppression is not a cooldown and not a weight. It removes the prompt from the candidate
    pool before selection begins, which is why `services/scheduler._candidates` is where it is
    enforced: a suppressed prompt cannot be resurrected by an empty pool, by the relaxed
    cooldown, by dropping theme rotation, or by the final "anything in the pool" fallback,
    because it was never in the pool those fall back to.

    Soft-deleted like every other user-data table — `revoked_at` rather than a row disappearing —
    so a parent can undo a permanent decision, and so the change syncs as a row.
    """

    __tablename__ = "prompt_suppressions"
    __table_args__ = (
        # The scheduler's exclusion subquery: child first, then prompt, then the liveness
        # filter it always carries.
        Index(
            "ix_prompt_suppressions_child_id_prompt_id_revoked_at",
            "child_id",
            "prompt_id",
            "revoked_at",
        ),
    )

    # Composite primary key, per the spec. One row per (child, prompt) ever — an un-suppress
    # followed by a re-suppress revives this row rather than growing a second.
    child_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("children.id", ondelete="CASCADE"), primary_key=True
    )
    prompt_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("prompts.id", ondelete="CASCADE"), primary_key=True
    )
    # Free text and nullable. Deliberately not a constrained set: the useful reasons are the
    # ones nobody thought to enumerate, and a parent is never shown this field as a required
    # choice.
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[created]
    updated_at: Mapped[updated]
    # The soft delete. Named `revoked_at` rather than `deleted_at` because the row is not
    # deleted data — it is a decision the parent withdrew, and `/sync` treats the two the same
    # way regardless.
    revoked_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
