"""The constrained value sets.

Every one of these is a `text` column plus a named CHECK constraint — never a Postgres
enum, so adding a value later is a one-line ALTER rather than a migration dance. They live
here so the models, the migration, and the Pydantic schemas cannot drift apart.
"""

from __future__ import annotations

import datetime as dt
from typing import Final, Literal

# `password` is kept permitted and is dead as of phase 52: the dev fixture moved to `email`
# and its rows were migrated. It stays in the CHECK because removing a value from a CHECK is
# a migration that can only fail — on any row somebody has not migrated — for no benefit, and
# because rule 2 means the set is meant to grow rather than be curated.
CredentialProvider = Literal["apple", "google", "password", "email"]
CREDENTIAL_PROVIDERS: Final = ("apple", "google", "password", "email")

#: Providers a client may attach through `POST /me/credentials`.
#:
#: Narrower than the CHECK on purpose. The column permits a value the moment the schema does;
#: a route may only accept one once something can *verify* it. `google` arrives with phase 54
#: and `email` with phase 57, each widening this tuple beside the verifier that earns it.
ATTACHABLE_PROVIDERS: Final = ("apple", "google")

#: What a magic-link token is for. Only `verify` may activate a credential — see
#: `services/email_sign_in.py`.
SignInTokenPurpose = Literal["verify", "sign_in"]
SIGN_IN_TOKEN_PURPOSES: Final = ("verify", "sign_in")

GuardianRole = Literal["parent", "viewer"]
GUARDIAN_ROLES: Final = ("parent", "viewer")

#: The roles an invite may actually issue today. `viewer` is phase 30 and iceboxed, so the
#: column and the CHECK can hold it but nothing may create one — the narrower tuple is what
#: the route validates against, so un-icing 30 is a one-line change here rather than a hunt.
ISSUABLE_INVITE_ROLES: Final = ("parent",)

#: Entitlement tiers, per D4. Family-level, never per-user and never per-child.
Tier = Literal["free", "subscribed"]
TIERS: Final = ("free", "subscribed")

#: Two adults is the household. A third is not a pricing question, it is a different product
#: — see `docs/decisions.md` D4 — so the invite route refuses rather than upselling.
MAX_PARENTS_PER_FAMILY: Final = 2

#: How long an invite link is good for.
INVITE_EXPIRY_DAYS: Final = 7

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

# `mission` is photo-only as of 0008; `mission_b` takes the video, audio and activity kinds
# it used to share. The name did not change with the meaning — deliberately, and
# docs/decisions.md says why. Assignment rows written before 0008 hold non-photo prompts in
# `mission` and are correct for the day they were served.
Slot = Literal["question", "mission", "mission_b", "weekly", "monthly", "letter"]
SLOTS: Final = ("question", "mission", "mission_b", "weekly", "monthly", "letter")

AssignmentStatus = Literal["pending", "done", "dismissed", "expired"]
ASSIGNMENT_STATUSES: Final = ("pending", "done", "dismissed", "expired")

# What the entry actually *contains*, not what was asked — so the Voice filter never
# surfaces an entry with no audio in it. Derived server-side from the body and the attached
# media; the prompt that caused the entry is still recoverable through
# assignment_id -> prompt.kind.
EntryType = Literal["photo", "video", "audio", "text", "did_it"]
ENTRY_TYPES: Final = ("photo", "video", "audio", "text", "did_it")

MediaKind = Literal["photo", "video", "audio"]
MEDIA_KINDS: Final = ("photo", "video", "audio")

UploadStatus = Literal["pending", "complete", "failed"]
UPLOAD_STATUSES: Final = ("pending", "complete", "failed")

TagSource = Literal["user", "device_ai"]
TAG_SOURCES: Final = ("user", "device_ai")

# How the child is referred to. Nullable on `children`: a parent who skips the question in
# onboarding has not said "they/them", they have said nothing, and rendering has to be able to
# tell those apart — `docs/decisions.md` open item 10 is about prompts reading correctly, and
# a guess dressed up as an answer is the failure it is trying to avoid.
#
# A closed set with a CHECK, per the constrained-value convention, rather than free text: the
# consumer is pronoun substitution in prompt bodies, which has to enumerate the forms it
# writes. Widening it later is a one-line migration; storing text nothing can render is not
# recoverable by one.
Pronouns = Literal["he/him", "she/her", "they/them"]
PRONOUNS: Final = ("he/him", "she/her", "they/them")

# The prompt token contract, spelled out in `docs/api-contract.md`. Thirteen tokens, and the
# server renders none of them: bodies are stored and served with tokens intact, and each client
# substitutes at the last moment before a human reads the sentence.
#
# This tuple exists so the seed loader can refuse a body containing `{thier}`. That is not in
# tension with the rule that a renderer passes an unknown token through literally and never
# throws — the two are opposite ends of the same contract. A renderer is downstream of an
# archive that already exists and must never lose a word from it; the authoring pipeline is
# upstream of everything and is the last place a typo can still be cheap. A misspelled token
# that gets past here renders as literal braces on a card, in an export, and in a printed book,
# for as long as the archive exists.
PROMPT_TOKENS: Final = (
    "they",
    "them",
    "their",
    "theirs",
    "themself",
    "they_are",
    "they_were",
    "they_have",
    "they_do",
    "They",
    "Them",
    "Their",
    "name",
)

# Not a CHECK constraint. The scheduler rotates on these, but the library will grow themes
# and a prompt with an unrecognised theme should be seedable without a migration.
THEMES: Final = (
    "voice",
    "physical-affection",
    "their-words",
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

# The three that fire every day, plus the three that only fire on their own day.
DAILY_SLOTS: Final = ("question", "mission", "mission_b")

#: The other three. Since phase 36 this split is load-bearing rather than descriptive: daily
#: slots are served **per guardian** and shared slots are one per child, and the two partial
#: unique indexes on `assignments` are built from exactly these two tuples. Moving a slot
#: between them is a migration, not an edit.
SHARED_SLOTS: Final = ("weekly", "monthly", "letter")

# --- Push notifications ------------------------------------------------------------------

# Only iOS can be sent to, because APNs is the only transport that exists. A browser client
# would need WebPush, which is a different protocol and a different credential — so this is
# a `text` + CHECK column exactly so that day is an ALTER rather than a migration dance.
DevicePlatform = Literal["ios"]
DEVICE_PLATFORMS: Final = ("ios",)

# A sandbox token and a production token are different tokens, and sending one to the wrong
# host fails *silently*. This is the single most common way push works in development and
# not in TestFlight, which is why the column is NOT NULL and the API field has no default.
PushEnvironment = Literal["sandbox", "production"]
PUSH_ENVIRONMENTS: Final = ("sandbox", "production")

# The default hour the one daily notification goes out, on the wall clock in the child's
# family_timezone. Early evening: the parent is with the child, a question is answered in
# conversation over dinner, and a mission not done tonight stacks to tomorrow at no cost.
#
# This is a **default, not an answer**. docs/decisions.md open item 6 — what time actually
# works — is still open, and every user can change it through `PATCH /v1/me`.
DEFAULT_NOTIFY_LOCAL_TIME: Final = dt.time(19, 0)

# How late a missed window may still be fired. Past this, the notification is dropped.
#
# The send job runs on a Fly scheduled machine, and Fly's coarsest-grained schedule is
# hourly — so a window can be up to an hour old before any run even looks at it, and a run
# that fails outright puts it two hours old. Two hours absorbs exactly one missed run, and
# still cannot reach the middle of the night from any daytime window: 19:00 fires by 21:00
# or not at all. A notification at 2am about a mission for a day that is nearly over is
# worse than no notification, which is the whole reason there is a tolerance and not a
# best-effort catch-up.
NOTIFICATION_STALENESS: Final = dt.timedelta(hours=2)

# Which of the day's pending items the one notification carries, most-wanted first.
#
# The mission is the thing you go and *do*, so it is what a nudge is for. The question is
# answered in conversation and needs no reminder to be answerable. Anything not on this list
# falls back to the first pending item of the day.
#
# `mission_b` sits second, directly behind `mission`: both are things you go and do, and the
# photo mission stays ahead of them because it is the cheapest to act on in the moment. This
# is still one notification — the ladder picks which single item it carries, and a day now
# reaching five assignments does not make it two.
NOTIFICATION_SLOT_PRIORITY: Final = (
    "mission",
    "mission_b",
    "weekly",
    "monthly",
    "letter",
    "question",
)
