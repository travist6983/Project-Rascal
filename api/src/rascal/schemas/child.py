"""Children request and response bodies."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field, field_validator

from rascal.constants import GuardianRole
from rascal.schemas.common import ApiModel
from rascal.services.dates import zone


class ChildCreate(ApiModel):
    name: str = Field(min_length=1, max_length=200)
    birthdate: dt.date
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
    avatar_key: str | None
    family_timezone: str
    created_at: dt.datetime
    updated_at: dt.datetime


class ChildWithRole(ChildOut):
    """What `GET /children` returns: the child plus the caller's role on it."""

    role: GuardianRole
    age_months: int


class ChildSummary(ApiModel):
    """The compact form embedded in `/today` and `/moments`."""

    id: uuid.UUID
    name: str
    age_months: int
