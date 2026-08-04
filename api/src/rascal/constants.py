"""The constrained value sets.

Every one of these is a `text` column plus a named CHECK constraint — never a Postgres
enum, so adding a value later is a one-line ALTER rather than a migration dance. They live
here so the models, the migration, and the Pydantic schemas cannot drift apart.
"""

from __future__ import annotations

from typing import Final, Literal

CredentialProvider = Literal["apple", "google", "password"]
CREDENTIAL_PROVIDERS: Final = ("apple", "google", "password")

GuardianRole = Literal["parent", "viewer"]
GUARDIAN_ROLES: Final = ("parent", "viewer")

PromptKind = Literal["question", "photo", "video", "audio", "activity", "measurement", "letter"]
PROMPT_KINDS: Final = (
    "question",
    "photo",
    "video",
    "audio",
    "activity",
    "measurement",
    "letter",
)

Cadence = Literal["daily", "weekly", "monthly"]
CADENCES: Final = ("daily", "weekly", "monthly")

CompletionMode = Literal["did_it", "media", "text"]
COMPLETION_MODES: Final = ("did_it", "media", "text")

PromptSource = Literal["seeded", "user", "llm"]
PROMPT_SOURCES: Final = ("seeded", "user", "llm")

Slot = Literal["question", "mission", "weekly", "monthly"]
SLOTS: Final = ("question", "mission", "weekly", "monthly")

AssignmentStatus = Literal["pending", "done", "dismissed", "expired"]
ASSIGNMENT_STATUSES: Final = ("pending", "done", "dismissed", "expired")

# Denormalized onto entries from the originating prompt so the timeline can filter without
# a join. Freeform entries have no prompt, so `text` is the value that carries them.
EntryType = Literal[
    "question", "photo", "video", "audio", "activity", "measurement", "letter", "text"
]
ENTRY_TYPES: Final = (*PROMPT_KINDS, "text")

MediaKind = Literal["photo", "video", "audio"]
MEDIA_KINDS: Final = ("photo", "video", "audio")

UploadStatus = Literal["pending", "complete", "failed"]
UPLOAD_STATUSES: Final = ("pending", "complete", "failed")

TagSource = Literal["user", "device_ai"]
TAG_SOURCES: Final = ("user", "device_ai")

# Not a CHECK constraint. The scheduler rotates on these, but the library will grow themes
# and a prompt with an unrecognised theme should be seedable without a migration.
THEMES: Final = (
    "voice",
    "physical-affection",
    "his-words",
    "everyday-ordinary",
    "skills-firsts",
    "relationships",
    "humor",
    "food",
    "sleep-routine",
    "outdoors",
    "making-building",
    "fears-comfort",
    "growth-measurement",
    "letters-forward",
    "seasons-holidays",
    "me-as-a-parent",
)

# docs/decisions.md: items stack and expire at 14 days.
DEFAULT_EXPIRY_DAYS: Final = 14

# The daily pair, plus the two that only fire on their day.
DAILY_SLOTS: Final = ("question", "mission")
