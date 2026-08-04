"""The mission library. Content, not user data."""

from __future__ import annotations

from sqlalchemy import ARRAY, Boolean, Index, Integer, Text, text
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
