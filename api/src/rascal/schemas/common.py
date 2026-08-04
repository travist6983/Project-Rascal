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
    created_at: dt.datetime


class ErrorDetail(ApiModel):
    code: str
    message: str
    field: str | None = None


class ErrorResponse(ApiModel):
    """The one error shape. Documented here so it shows up in the OpenAPI schema."""

    error: ErrorDetail
