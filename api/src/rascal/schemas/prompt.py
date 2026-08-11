"""The mission library, as seen by the admin routes."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import Cadence, CompletionMode, PromptKind, PromptSource
from rascal.schemas.common import ApiModel


class PromptOut(ApiModel):
    id: uuid.UUID
    kind: PromptKind
    cadence: Cadence
    completion_mode: CompletionMode
    body: str
    theme: str
    min_age_months: int
    max_age_months: int
    month_tags: list[int]
    source: PromptSource
    default_unlock_age: int | None
    active: bool
    created_at: dt.datetime
    updated_at: dt.datetime


class PromptCreate(ApiModel):
    """Hand-authored additions. The library is content, authored server-side."""

    kind: PromptKind
    cadence: Cadence
    completion_mode: CompletionMode
    body: str = Field(min_length=1, max_length=2000)
    theme: str = Field(min_length=1, max_length=100)
    min_age_months: int = Field(default=24, ge=0, le=300)
    max_age_months: int = Field(default=216, ge=0, le=300)
    month_tags: list[int] = Field(default_factory=list)
    default_unlock_age: int | None = Field(default=None, ge=0, le=120)
    active: bool = True


class PromptPage(ApiModel):
    prompts: list[PromptOut]
    total: int


# --- Suppression ---------------------------------------------------------------------------


class PromptSuppressionCreate(ApiModel):
    """"Stop asking me this." `reason` is free text and optional."""

    prompt_id: uuid.UUID
    reason: str | None = Field(
        default=None,
        max_length=500,
        description="Why, in the parent's words. Never shown as a required choice, and "
        "deliberately not a constrained set — the useful reasons are the ones nobody "
        "thought to enumerate.",
    )


class PromptSuppressionOut(ApiModel):
    child_id: uuid.UUID
    prompt_id: uuid.UUID
    reason: str | None
    created_at: dt.datetime
    updated_at: dt.datetime
    revoked_at: dt.datetime | None = None
    # Inlined so a client can render "you asked us to stop showing this" with the prompt's
    # words in it, rather than fanning out to `GET /prompts` per row.
    prompt: PromptOut | None = None


# --- Pool health ---------------------------------------------------------------------------


class SlotHealthOut(ApiModel):
    slot: str
    kind: str
    eligible: int = Field(description="Active prompts inside this child's age window and season.")
    suppressed: int = Field(description="Of those, permanently suppressed for this child.")
    served_within_cooldown: int = Field(
        description="Of the unsuppressed remainder, served in the last 180 days."
    )
    available_now: int = Field(
        description="What the scheduler could pick today without relaxing anything."
    )
    estimated_days_until_first_repeat: int | None = Field(
        description="**An estimate, not a fact.** `available_now` divided by how often this "
        "slot is served. Assumes nothing more is suppressed and the age window does not "
        "widen, both of which will happen. Null when the pool is already dry — a projection "
        "of zero would read as a countdown to something that has already occurred."
    )
    relaxation_active: bool
    relaxation_step: str = Field(
        description="Which rung of the selection ladder the next pick would land on: "
        "`none`, `cooldown_relaxed_to_90_days`, `cooldown_dropped`, or `age_window_dropped`."
    )


class PoolHealthOut(ApiModel):
    child_id: uuid.UUID
    as_of: dt.date
    age_months: int
    slots: list[SlotHealthOut]
