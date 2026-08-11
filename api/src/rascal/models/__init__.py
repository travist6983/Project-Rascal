"""SQLAlchemy models. Importing this package registers every table on ``Base.metadata``."""

from __future__ import annotations

from rascal.models.assignment import Assignment
from rascal.models.base import TABLES_WITH_UPDATED_AT, Base
from rascal.models.child import Child, Guardian
from rascal.models.device import Device, NotificationSend
from rascal.models.entry import Entry, EntryTag, Media, Tag
from rascal.models.prompt import Prompt
from rascal.models.user import Credential, IdempotencyKey, RefreshToken, User

__all__ = [
    "TABLES_WITH_UPDATED_AT",
    "Assignment",
    "Base",
    "Child",
    "Credential",
    "Device",
    "Entry",
    "EntryTag",
    "Guardian",
    "IdempotencyKey",
    "Media",
    "NotificationSend",
    "Prompt",
    "RefreshToken",
    "Tag",
    "User",
]
