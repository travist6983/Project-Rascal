"""The signed-in user's own record.

Separate from `/auth` on purpose: `/auth` is about sessions, this is about the person. There
is no path parameter and no way to name another user — the route updates the row behind the
bearer token and nothing else.

`display_name` is the only human-readable identity in the product. Apple's relay addresses
are unreliable and `email` is nullable for exactly that reason, so a user who cannot fix
their own name has no way to be recognised in the app at all.
"""

from __future__ import annotations

from fastapi import APIRouter

from rascal.deps import CurrentUser, SessionDep
from rascal.errors import ErrorCode, RascalError
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


@router.patch(
    "",
    response_model=UserOut,
    summary="Update the caller's display name",
    description=(
        "Updates the caller's own row and returns the same user object as `POST "
        "/auth/apple`. `display_name` is trimmed; blank or over-length is `400` "
        "`invalid_display_name`. Email is not writable here — it comes from the credential "
        "provider."
    ),
)
async def update_me(payload: MeUpdate, session: SessionDep, user: CurrentUser) -> UserOut:
    name = payload.display_name.strip()
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

    user.display_name = name
    await session.flush()
    # updated_at is written by the set_updated_at() trigger, so the in-memory row is behind
    # the database until it is read back.
    await session.refresh(user)
    return UserOut.model_validate(user)
