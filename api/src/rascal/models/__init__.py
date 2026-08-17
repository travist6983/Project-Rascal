"""SQLAlchemy models. Importing this package registers every table on ``Base.metadata``."""

from __future__ import annotations

from rascal.models.assignment import Assignment
from rascal.models.base import TABLES_WITH_UPDATED_AT, Base
from rascal.models.child import Child, Guardian
from rascal.models.deletion import DeletionRequest
from rascal.models.device import Device, NotificationSend
from rascal.models.entry import Entry, EntryTag, Media, Tag
from rascal.models.family import Entitlement, Family, GuardianInvite
from rascal.models.prompt import Prompt, PromptSuppression
from rascal.models.user import (
    Credential,
    EmailSignInToken,
    IdempotencyKey,
    RateLimitEvent,
    RefreshToken,
    User,
)

__all__ = [
    "TABLES_WITH_UPDATED_AT",
    "Assignment",
    "Base",
    "Child",
    "Credential",
    "DeletionRequest",
    "Device",
    "EmailSignInToken",
    "Entitlement",
    "Entry",
    "EntryTag",
    "Family",
    "Guardian",
    "GuardianInvite",
    "IdempotencyKey",
    "Media",
    "NotificationSend",
    "Prompt",
    "PromptSuppression",
    "RateLimitEvent",
    "RefreshToken",
    "Tag",
    "User",
]
