"""Shared response pieces."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict


class ApiModel(BaseModel):
    """Base for every wire model. Plain JSON, no client-specific serialization."""

    model_config = ConfigDict(from_attributes=True, populate_by_name=True)


class UserOut(ApiModel):
    id: uuid.UUID
    email: str | None
    display_name: str | None
    # So a client can hide the library editor rather than offer it and take a 403.
    is_admin: bool = False
    # The notification preference, on the user rather than the child: one human decides when
    # their own phone buzzes. `notify_local_time` is a wall-clock time read in the child's
    # `family_timezone` — never the device's timezone and never UTC.
    notify_enabled: bool = False
    notify_local_time: dt.time
    created_at: dt.datetime


class ErrorDetail(ApiModel):
    code: str
    message: str
    field: str | None = None


class ErrorResponse(ApiModel):
    """The one error shape. Documented here so it shows up in the OpenAPI schema."""

    error: ErrorDetail
