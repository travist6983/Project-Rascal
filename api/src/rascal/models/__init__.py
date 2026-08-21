"""SQLAlchemy models. Importing this package registers every table on ``Base.metadata``."""

from __future__ import annotations

from rascal.models.app_store import AppStoreTransaction
from rascal.models.assignment import Assignment
from rascal.models.base import TABLES_WITH_UPDATED_AT, Base
from rascal.models.child import Child, Guardian
from rascal.models.deletion import DeletionRequest
from rascal.models.device import Device, NotificationSend
from rascal.models.email_broadcast import EmailBroadcast
from rascal.models.entry import Entry, EntryTag, Media, Tag
from rascal.models.family import Entitlement, Family, GuardianInvite
from rascal.models.library_override import PromptLibraryOverride
from rascal.models.prompt import Prompt, PromptSuppression
from rascal.models.social import SocialAsset, SocialPublication
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
    "AppStoreTransaction",
    "Assignment",
    "Base",
    "Child",
    "Credential",
    "DeletionRequest",
    "Device",
    "EmailBroadcast",
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
    "PromptLibraryOverride",
    "PromptSuppression",
    "RateLimitEvent",
    "RefreshToken",
    "SocialAsset",
    "SocialPublication",
    "Tag",
    "User",
]
