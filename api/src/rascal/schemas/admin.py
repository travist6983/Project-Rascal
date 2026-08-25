"""Wire models for the admin console.

The metric payloads are deliberately loose (`dict[str, Any]`) rather than mirrored field by
field into Pydantic. They are a private surface with exactly one consumer — the console
shipped in this repo — and every number on them is derived, so a typed mirror would be a
second place to update every time a query changes and would buy no caller anything. The
*write* models below are strict, because those are the ones a human types into.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Any, Literal

from pydantic import Field, field_validator, model_validator

from rascal.constants import (
    AccessState,
    Cadence,
    CompletionMode,
    EntitlementSource,
    GrantStatus,
    PromptKind,
    Tier,
)
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


class AdminTrialIn(ApiModel):
    """The console's one entitlement lever: move a household's trial, or clear it.

    **There is deliberately no `tier` field and there is not going to be one.** See
    `services/guardians.set_trial_ends_at`.
    """

    #: When the trial should end. `null` clears it — a household with no trial, which is a
    #: real state and the way to drop somebody to the free tier immediately. A date in the
    #: past does the same thing while recording when it happened.
    #:
    #: **Must carry a timezone offset.** See the validator below.
    trial_ends_at: dt.datetime | None = None

    @field_validator("trial_ends_at")
    @classmethod
    def _must_be_aware(cls, value: dt.datetime | None) -> dt.datetime | None:
        """Refuse an offset-less timestamp, the same guard `SocialPublishIn` already carries.

        **Without it an offset-less body is a 500 rather than a 422**, and the path is short:
        Pydantic parses `"2026-09-01T00:00:00"` into a naive `datetime`, the flush does not
        expire the attribute, and `services/guardians.access_for` then compares that naive
        value against an aware `now` — `TypeError: can't compare offset-naive and offset-aware
        datetimes`, rendered by the catch-all as `internal_error` with no field to point at.

        **Rejecting rather than assuming UTC is the deliberate half.** `models/base.py` is
        explicit that a naive timestamp in an archive spanning eighteen years and two zones is
        a bug that surfaces years later; silently stamping one with UTC here would be this
        service inventing a timezone for a value a person typed. The column is `timestamptz`,
        so a value read back from the database is always aware — this route is the only way a
        naive one can reach the comparison at all, which is why the guard belongs here and not
        inside the one authority.

        The console cannot trigger it (`endOfDayIso` sends `toISOString()`), so the reachable
        caller is a person with `curl` — which is exactly what
        `docs/runbook-admin-console.md` §4 tells them to be.
        """
        if value is not None and value.tzinfo is None:
            raise ValueError(
                "trial_ends_at must carry a timezone offset, e.g. 2026-09-01T00:00:00Z."
            )
        return value


class AdminTrialOut(ApiModel):
    """What the household reads after the lever moved, computed the same way every other
    surface computes it — `services/guardians.access_for`, the one authority."""

    family_id: uuid.UUID
    #: Untouched by this route. Present so the console can show that it did not move.
    tier: Tier
    access: AccessState
    trial_ends_at: dt.datetime | None = None
    #: **Why the household reads what it reads**, added by phase 121 because there are now two
    #: ways for this lever to appear to do nothing. A household that stays `subscribed` after a
    #: trial is set is either a subscriber or a granted household, and the console's message has
    #: to say which — sending somebody to `runbook-deploy.md` §7a to fix a tier that was never
    #: the reason is a worse outcome than no message.
    entitlement_source: EntitlementSource = "none"


class AdminGrantIn(ApiModel):
    """Issue one complimentary grant.

    **There is deliberately no `granted_by` field and there is not going to be one.** The issuer
    is the bearer token's subject, taken in the route. An audit column a caller can set is an
    audit column that says whatever the caller wanted it to, and a test asserts a body carrying
    one is ignored rather than honoured.

    **There is no `tier` field either**, for the reason `AdminTrialIn` gives: `entitlements.tier`
    has exactly one writer by D5 and nothing in this console can be the second.
    """

    family_id: uuid.UUID
    #: Free text and the only required prose. `founding tester`, `refund goodwill`, `press`.
    #: A ledger whose rows do not say why is a ledger nobody can read six months later, so this
    #: is `min_length=1` here and a named CHECK in the schema besides.
    reason: str = Field(min_length=1, max_length=500)
    #: When the grant runs out. **`null` is perpetual** — not a missing value and not a sentinel
    #: date. A founding tester is entitled until somebody revokes it.
    #:
    #: **Must carry a timezone offset**, and an expiry already in the past is `422` rather than a
    #: row that entitles nobody. See the validator below.
    expires_at: dt.datetime | None = None

    @field_validator("expires_at")
    @classmethod
    def _must_be_aware(cls, value: dt.datetime | None) -> dt.datetime | None:
        """Refuse an offset-less timestamp, the same guard `AdminTrialIn` already carries.

        **Without it an offset-less body is a 500 rather than a 422.** Pydantic parses
        `"2026-09-01T00:00:00"` into a naive `datetime`, and the first thing
        `services/grants.issue_grant` does with it is compare it against an aware `now` —
        `TypeError: can't compare offset-naive and offset-aware datetimes`, rendered by the
        catch-all as `internal_error` with no field to point at. It never reaches the INSERT,
        which is the only reason the column's own `timestamptz` coercion never gets a say.

        **Rejecting rather than assuming UTC is the deliberate half**, and it matters more here
        than it does for a trial. `models/base.py` is explicit that a naive timestamp in an
        archive spanning eighteen years and two zones is a bug that surfaces years later;
        stamping one with UTC here would be this service inventing a timezone for a date a
        person typed, and the value it invents decides which *day* somebody's entitlement ends.
        The column is `timestamptz`, so a value read back is always aware — this route is the
        only way a naive one reaches the comparison at all.
        """
        if value is not None and value.tzinfo is None:
            raise ValueError("expires_at must carry a timezone offset, e.g. 2026-09-01T00:00:00Z.")
        return value


class AdminGrantOut(ApiModel):
    """One row of the grant ledger, as the console reads it."""

    id: uuid.UUID
    family_id: uuid.UUID
    #: Enough to recognise the household without opening it — the display name and email of its
    #: members, and nothing else. **No child's name, no entry, no count of anybody's archive.**
    #: `tests/test_admin.py` plants distinctive strings in an archive and greps every admin
    #: response for them, this one included.
    household: str
    reason: str
    granted_at: dt.datetime
    #: `null` is perpetual.
    expires_at: dt.datetime | None = None
    revoked_at: dt.datetime | None = None
    #: `active` | `expired` | `revoked`, computed from the row and the server's clock.
    #: `revoked` outranks `expired`: it is the thing somebody *did*. **Display only** — the gate
    #: is `services.grants.unexpired`, in SQL.
    status: GrantStatus
    #: Who issued it, as a display name or email — **`null` when that account has since been
    #: deleted**, which is a true sentence rather than a missing value. Account deletion
    #: hard-deletes `users` and this column is `ON DELETE SET NULL`; `models/family.py` carries
    #: why none of the other three `ON DELETE` actions works.
    granted_by: str | None = None
    revoked_by: str | None = None


class AdminGrantList(ApiModel):
    grants: list[AdminGrantOut]


class AdminHousehold(ApiModel):
    """One household in the console's picker. **Account metadata only.**"""

    family_id: uuid.UUID
    #: Display names and emails of the household's members, joined. The one thing a person
    #: searching for a household actually has.
    label: str
    tier: Tier
    access: AccessState
    entitlement_source: EntitlementSource
    #: How many grants this household holds in total, active or not — so the picker can say
    #: "this one already has three" before somebody writes a fourth.
    grants: int = 0


class AdminHouseholdList(ApiModel):
    households: list[AdminHousehold]


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
        description="Summed across providers that publish a figure — either from the vendor "
        "(Anthropic, GitHub) or from a price named in the environment (Tigris, Apple). "
        "Deliberately not a guess at the rest: Fly, Neon and Resend expose no spend API, so "
        "a grand total here would be a number nobody can reconcile against an invoice."
    )
    providers_without_pricing: list[str]


# --- Prompt candidates (phase 103) ---------------------------------------------------------
#
# The console's generate-and-pick flow. Bounds are copied from `schemas/prompt.PromptCreate`
# rather than re-chosen, so the two authoring paths into `prompts` agree about what a legal
# row is.


class PromptGenerateIn(ApiModel):
    """One brief. Everything except `kind` is optional, which is the point.

    **`theme` is nullable and that is the "or" in "a theme or an age range".** Omit it and the
    model chooses a theme per candidate; the age band is then the whole brief. `prompts.theme`
    is NOT NULL, so something has to fill that column, and a model naming it is the only
    source that is not an invented constant.
    """

    kind: PromptKind
    theme: str | None = Field(default=None, min_length=1, max_length=100)
    count: Literal[1, 5, 10, 25] = 5
    # Bounded to the library's own band rather than the column's. `judge` rejects any candidate
    # outside 24-216 months, so a brief asking for 0-300 spends a real model call to produce a
    # batch in which every row is rejected for its age band — a 200 that reads like a bug.
    min_age_months: int = Field(default=24, ge=24, le=216)
    max_age_months: int = Field(default=216, ge=24, le=216)
    month_tags: list[int] = Field(
        default_factory=list,
        description="Months 1-12. A non-empty list makes the batch seasonal, which both "
        "stamps the months on every candidate and stops the occasion filter rejecting the "
        "occasions the batch was asked for.",
    )
    default_unlock_age: int | None = Field(default=None, ge=0, le=120)
    guidance: str | None = Field(
        default=None,
        max_length=2000,
        description="Free text folded into the brief. Narrows the instruction; relaxes no "
        "hard rule — the filters run over the result either way.",
    )

    @model_validator(mode="after")
    def _bands_and_months(self) -> PromptGenerateIn:
        if self.min_age_months >= self.max_age_months:
            raise ValueError("min_age_months must be less than max_age_months")
        if any(month < 1 or month > 12 for month in self.month_tags):
            raise ValueError("month_tags must be months, 1 through 12")
        return self


class PromptCandidateIn(ApiModel):
    """One kept candidate, on its way to the queue.

    **`cadence` and `completion_mode` are deliberately absent.** They are derived server-side
    from the kind, which is what the CHECK constraints admit and what the generator told the
    model, so a client cannot send a pair that disagrees with its own kind. `rationale` is
    absent for a duller reason: `prompts` has no column for it.
    """

    kind: PromptKind
    body: str = Field(min_length=1, max_length=2000)
    theme: str = Field(min_length=1, max_length=100)
    min_age_months: int = Field(default=24, ge=0, le=300)
    max_age_months: int = Field(default=216, ge=0, le=300)
    month_tags: list[int] = Field(default_factory=list)
    default_unlock_age: int | None = Field(default=None, ge=0, le=120)

    @model_validator(mode="after")
    def _bands_and_months(self) -> PromptCandidateIn:
        # `>` rather than `>=`, matching `routers/prompts.create_prompt`, `services/library`
        # and `services/seeding`. A one-month band is legal in all three, so it is legal here:
        # the section header above claims these paths agree about what a legal row is, and a
        # strict `>=` would have made that claim false for exactly one row shape.
        if self.min_age_months > self.max_age_months:
            raise ValueError("min_age_months cannot exceed max_age_months")
        if any(month < 1 or month > 12 for month in self.month_tags):
            raise ValueError("month_tags must be months, 1 through 12")
        return self


class PromptCandidatesIn(ApiModel):
    candidates: list[PromptCandidateIn] = Field(min_length=1, max_length=25)


class SkippedCandidate(ApiModel):
    body: str
    reason: str
    prompt_id: uuid.UUID | None = Field(
        default=None,
        description="The row this body collided with, when it collided with one. The reviewer "
        "wants to look at it, and a reason without an id makes them go and search for it.",
    )


class PromptCandidatesOut(ApiModel):
    inserted: list[PromptOut]
    skipped: list[SkippedCandidate]
    queued_total: int = Field(
        description="Candidates waiting after this write — `source='llm'` and not active. "
        "The same count `scripts/review_candidates.py` reports."
    )
