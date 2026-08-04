"""The single call the home screen makes, plus the assignment actions it can take."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import AssignmentStatus, Slot
from rascal.schemas.child import ChildSummary
from rascal.schemas.common import ApiModel


class AssignmentOut(ApiModel):
    id: uuid.UUID
    slot: Slot
    # A parent-authored custom_body wins over the library prompt it replaced.
    body: str
    kind: str
    completion_mode: str
    theme: str | None
    status: AssignmentStatus
    assigned_on: dt.date
    expires_on: dt.date
    prompt_id: uuid.UUID | None
    is_custom: bool
    unlock_at_age: int | None = None


class TodayResponse(ApiModel):
    date: dt.date
    child: ChildSummary
    today: list[AssignmentOut]
    # Pending assignments from previous days, oldest first. Backlog is fine; guilt is not.
    waiting: list[AssignmentOut] = Field(default_factory=list)
    done_today: list[AssignmentOut] = Field(default_factory=list)


class CustomAssignmentRequest(ApiModel):
    body: str = Field(min_length=1, max_length=2000)
