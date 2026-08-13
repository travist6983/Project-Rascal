"""Children request and response bodies."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field, ValidationInfo, field_validator

from rascal.constants import GuardianRole, Pronouns
from rascal.errors import validation_failed
from rascal.schemas.common import ApiModel
from rascal.services.dates import zone


class ChildCreate(ApiModel):
    name: str = Field(min_length=1, max_length=200)
    birthdate: dt.date
    # Optional, and absent is not "they/them" — it is unanswered. Onboarding is allowed to
    # skip the question, and prompt rendering has to be able to tell the two apart.
    pronouns: Pronouns | None = None
    family_timezone: str = Field(
        description="IANA timezone, e.g. America/Detroit. The scheduler's definition of today."
    )

    @field_validator("family_timezone")
    @classmethod
    def _known_timezone(cls, value: str) -> str:
        zone(value)  # raises validation_failed on an unknown zone
        return value


class ChildUpdate(ApiModel):
    """Every field is optional, and an omitted field is left alone.

    Optional is not the same as nullable. `name`, `birthdate` and `family_timezone` are
    typed `| None` only so they can be *absent*; the columns behind them are NOT NULL, so an
    explicit `null` is a rejection rather than a clear — the convention `docs/api-contract.md`
    states for `PATCH /me` and the reason `PATCH /me` reads `model_fields_set`. `pronouns` and
    `avatar_key` are the two documented exceptions: null clears them.
    """

    name: str | None = Field(default=None, min_length=1, max_length=200)
    birthdate: dt.date | None = None
    # An explicit null clears it, because the router dumps with exclude_unset — a parent who
    # answered and then changed their mind can get back to unanswered.
    pronouns: Pronouns | None = None
    family_timezone: str | None = None
    avatar_key: str | None = None

    @field_validator("name", "birthdate", "family_timezone", mode="before")
    @classmethod
    def _no_explicit_null(cls, value: object, info: ValidationInfo) -> object:
        """Refuse a null aimed at a NOT NULL column, instead of letting the flush 500.

        `mode="before"` for two reasons: it runs ahead of `_known_timezone` however the two
        are ordered, and — like every validator — it does not run for an omitted field,
        because pydantic never validates a default. So absence still means "leave it alone".
        """
        if value is None:
            raise validation_failed(f"{info.field_name} cannot be null.", field=info.field_name)
        return value

    @field_validator("family_timezone")
    @classmethod
    def _known_timezone(cls, value: str) -> str:
        # Runs on any value the client actually sent — null is already refused above, so an
        # unknown zone can no longer slip through as "not None, therefore unchecked".
        zone(value)  # raises validation_failed on an unknown zone
        return value


class ChildOut(ApiModel):
    id: uuid.UUID
    name: str
    birthdate: dt.date
    pronouns: Pronouns | None
    avatar_key: str | None
    family_timezone: str
    created_at: dt.datetime
    updated_at: dt.datetime


class ChildWithRole(ChildOut):
    """What `GET /children` returns: the child plus the caller's role on it."""

    role: GuardianRole
    age_months: int


class RecomputeAgesResult(ApiModel):
    """What `POST /children/{id}/recompute-ages` reports back.

    `birthdate` is echoed because the whole point of the call is that the caller has just
    corrected it, and a client showing "412 entries updated" wants to say what they were
    corrected *to*.
    """

    child_id: uuid.UUID
    entries_updated: int
    birthdate: dt.date


class AvatarUploadUrlRequest(ApiModel):
    content_type: str = Field(min_length=1, max_length=255)
    bytes: int = Field(gt=0, description="Size of the image in bytes.")


class AvatarUploadUrlResponse(ApiModel):
    """No `multipart` and no `parts`, unlike the media equivalent — an avatar is one PUT.

    `avatar_key` is returned but **not** stored. The client `PATCH`es it onto the child once
    the PUT succeeds, so a presign the phone abandons leaves an orphaned object rather than a
    child pointing at bytes that never arrived.
    """

    upload_url: str
    avatar_key: str
    expires_in: int


class AvatarUrlResponse(ApiModel):
    """A short-lived read URL. Minted per request, never stored — a persisted URL outlives
    its signature and then fails in a way that looks like the image is gone."""

    url: str
    expires_in: int


class ChildSummary(ApiModel):
    """The compact form embedded in `/today` and `/moments`."""

    id: uuid.UUID
    name: str
    age_months: int
