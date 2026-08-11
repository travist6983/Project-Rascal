"""Children request and response bodies."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field, field_validator

from rascal.constants import GuardianRole, Pronouns
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
    name: str | None = Field(default=None, min_length=1, max_length=200)
    birthdate: dt.date | None = None
    # An explicit null clears it, because the router dumps with exclude_unset — a parent who
    # answered and then changed their mind can get back to unanswered.
    pronouns: Pronouns | None = None
    family_timezone: str | None = None
    avatar_key: str | None = None

    @field_validator("family_timezone")
    @classmethod
    def _known_timezone(cls, value: str | None) -> str | None:
        if value is not None:
            zone(value)
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
