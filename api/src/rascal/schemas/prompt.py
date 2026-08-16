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
    """ "Stop asking me this." `reason` is free text and optional."""

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
        "slot is *observed* to be served, not by the cadence it is nominally on. Assumes "
        "nothing more is suppressed and the age window does not widen, both of which will "
        "happen. **Null has two meanings and `estimate_basis` says which** — the pool is dry, "
        "or the slot has not been served at all in the window and there is no rate to project "
        "from."
    )
    served_in_window: int = Field(
        description="How many times this slot was actually filled in the last "
        "`observation_window_days`. Every assignment counts, including dismissed and expired "
        "ones: they consumed a prompt for the day and put it inside the cooldown."
    )
    observation_window_days: int = Field(
        description="The window `served_in_window` was counted over, so the rate is "
        "reproducible from this response alone."
    )
    nominal_interval_days: int = Field(
        description="What this slot is *supposed* to be served at, in days. Reported beside "
        "`served_in_window` so the gap between intended and actual is visible. A daily slot "
        "reading `served_in_window: 0` is the shape of a scheduler defect."
    )
    estimate_basis: str = Field(
        description="Why the estimate is what it is: `observed_rate`, `pool_empty`, or "
        "`not_observed`. **`not_observed` is not good news** — the pool cannot run dry "
        "because nothing is drawing from it, which usually means something upstream stopped."
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
