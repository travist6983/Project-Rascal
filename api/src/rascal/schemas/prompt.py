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
