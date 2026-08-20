"""Wire models for the admin console.

The metric payloads are deliberately loose (`dict[str, Any]`) rather than mirrored field by
field into Pydantic. They are a private surface with exactly one consumer — the console
shipped in this repo — and every number on them is derived, so a typed mirror would be a
second place to update every time a query changes and would buy no caller anything. The
*write* models below are strict, because those are the ones a human types into.
"""

from __future__ import annotations

import uuid
from typing import Any, Literal

from pydantic import Field

from rascal.constants import Cadence, CompletionMode, PromptKind
from rascal.schemas.common import ApiModel
from rascal.schemas.prompt import PromptOut


class PromptUpdate(ApiModel):
    """A partial edit. Every field optional; anything omitted is left alone.

    **Changing `kind`, `cadence` or `body` moves the prompt's identity** — those three are
    what `content_hash` is computed from — so an edit touching one of them forks a seeded
    prompt rather than updating it. See `services/library.py`; the response says which
    happened.
    """

    kind: PromptKind | None = None
    cadence: Cadence | None = None
    completion_mode: CompletionMode | None = None
    body: str | None = Field(default=None, min_length=1, max_length=2000)
    theme: str | None = Field(default=None, min_length=1, max_length=100)
    min_age_months: int | None = Field(default=None, ge=0, le=300)
    max_age_months: int | None = Field(default=None, ge=0, le=300)
    month_tags: list[int] | None = None
    default_unlock_age: int | None = Field(default=None, ge=0, le=120)
    active: bool | None = None


class PromptEditOut(ApiModel):
    prompt: PromptOut
    action: Literal["updated", "superseded"]
    superseded_prompt_id: uuid.UUID | None = Field(
        default=None,
        description="Set when the edit forked a seeded prompt. The named row still exists, "
        "still owns every assignment and entry that ever pointed at it, and is now inactive "
        "— which is what keeps eighteen years of foreign keys resolving.",
    )


class PromptActiveIn(ApiModel):
    active: bool
    note: str | None = Field(
        default=None,
        max_length=500,
        description="Why. Stored on the override row for a seeded prompt, so the reason "
        "survives alongside the decision.",
    )


class PromptPreviewIn(ApiModel):
    body: str = Field(min_length=1, max_length=2000)
    name: str = Field(default="Miles", min_length=1, max_length=60)


class PromptPreviewOut(ApiModel):
    he_him: str
    she_her: str
    they_them: str
    unset: str = Field(
        description="What a child with no pronoun on file gets: the they/them column."
    )
    unknown_tokens: list[str] = Field(
        description="Tokens no client can render. Non-empty means the body would print "
        "literal braces on a card, in an export, and in a printed book."
    )


class AdminSnapshot(ApiModel):
    overview: dict[str, Any]
    growth: dict[str, Any]
    themes: list[dict[str, Any]]
    signups: list[dict[str, Any]]


class AdminOps(ApiModel):
    environment: str
    database: dict[str, Any]
    flags: list[dict[str, Any]]
    scheduler: dict[str, Any]
    jobs: dict[str, Any]


class AdminCosts(ApiModel):
    providers: list[dict[str, Any]]
    total_known_cents: int = Field(
        description="Summed across providers that publish a figure. Deliberately not a "
        "guess at the rest: Fly, Neon and Tigris expose no spend API, so a grand total "
        "here would be a number nobody can reconcile against an invoice."
    )
    providers_without_pricing: list[str]
