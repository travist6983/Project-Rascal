"""The signed-in user's own record.

Separate from `/auth` on purpose: `/auth` is about sessions, this is about the person. There
is no path parameter and no way to name another user — the route updates the row behind the
bearer token and nothing else.

`display_name` is the only human-readable identity in the product. Apple's relay addresses
are unreliable and `email` is nullable for exactly that reason, so a user who cannot fix
their own name has no way to be recognised in the app at all.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter

from rascal.deps import CurrentUser, SessionDep
from rascal.errors import ErrorCode, RascalError, validation_failed
from rascal.schemas.common import UserOut
from rascal.schemas.user import MeUpdate

router = APIRouter(prefix="/me", tags=["users"])

# Long enough for any real name, short enough that the column is not a text field for notes.
MAX_DISPLAY_NAME_LENGTH = 100


@router.get(
    "",
    response_model=UserOut,
    summary="The caller's own record",
    description=(
        "Returns the same user object as `POST /auth/apple` and `PATCH /me`, for the account "
        "behind the bearer token. There is no path parameter and no way to name another user.\n\n"
        "It exists because the user record otherwise arrives exactly once, with the sign-in "
        "response — so a client that force-quits and relaunches on a stored token has a valid "
        "session and no idea whose it is."
    ),
)
async def read_me(user: CurrentUser) -> UserOut:
    # No `SessionDep`: `current_user` has already loaded the row this returns, and taking the
    # session again only to re-read it would be a second query for the same object.
    return UserOut.model_validate(user)


def _validated_name(raw: str | None) -> str:
    if raw is None:
        raise RascalError(
            ErrorCode.INVALID_DISPLAY_NAME,
            "A display name cannot be null.",
            field="display_name",
        )
    name = raw.strip()
    if not name:
        raise RascalError(
            ErrorCode.INVALID_DISPLAY_NAME,
            "A display name cannot be blank.",
            field="display_name",
        )
    if len(name) > MAX_DISPLAY_NAME_LENGTH:
        raise RascalError(
            ErrorCode.INVALID_DISPLAY_NAME,
            f"A display name is at most {MAX_DISPLAY_NAME_LENGTH} characters.",
            field="display_name",
        )
    return name


def _validated_notify_time(raw: dt.time | None) -> dt.time:
    """A wall-clock time, to the minute, with no zone attached.

    An offset is refused rather than converted. The value is read in the *child's*
    `family_timezone`, so `19:00-04:00` is not a more precise way of saying 19:00 — it is a
    different and unanswerable request, and silently dropping the offset would set a time the
    parent did not choose.
    """
    if raw is None:
        raise validation_failed("A notification time cannot be null.", field="notify_local_time")
    if raw.tzinfo is not None:
        raise validation_failed(
            "A notification time is a wall clock time in the child's timezone, so it must "
            "not carry a UTC offset.",
            field="notify_local_time",
        )
    # Nobody picks a second, and the column would faithfully keep whatever a client sent.
    return raw.replace(second=0, microsecond=0)


@router.patch(
    "",
    response_model=UserOut,
    summary="Update the caller's display name and notification preference",
    description=(
        "Updates the caller's own row and returns the same user object as `POST "
        "/auth/apple`. Every field is optional; an omitted field is left alone, so a "
        "Settings screen can toggle notifications without resending a name.\n\n"
        "`display_name` is trimmed; blank or over-length is `400` `invalid_display_name`. "
        "`notify_local_time` is a wall-clock time read in the child's `family_timezone` — "
        "one carrying a UTC offset is `422`. Email is not writable here — it comes from the "
        "credential provider."
    ),
)
async def update_me(payload: MeUpdate, session: SessionDep, user: CurrentUser) -> UserOut:
    # `model_fields_set` rather than a None check, so "I am not changing this" and "set this
    # to null" are different requests. Nothing here is nullable, so the second is refused.
    changed = payload.model_fields_set

    if "display_name" in changed:
        user.display_name = _validated_name(payload.display_name)
    if "notify_enabled" in changed:
        if payload.notify_enabled is None:
            raise validation_failed("notify_enabled cannot be null.", field="notify_enabled")
        user.notify_enabled = payload.notify_enabled
    if "notify_local_time" in changed:
        user.notify_local_time = _validated_notify_time(payload.notify_local_time)

    await session.flush()
    # updated_at is written by the set_updated_at() trigger, so the in-memory row is behind
    # the database until it is read back.
    await session.refresh(user)
    return UserOut.model_validate(user)
