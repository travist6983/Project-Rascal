"""Where a notification goes.

Both routes act on the account behind the bearer token. There is no path parameter naming a
user and no way to register a token against somebody else, which is the same shape as `/me`
and for the same reason.

Not child-scoped: the preference and the phone belong to a person, not to a child, so
`deps.child_access` has nothing to resolve here. `current_user` is the whole check.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Path, Response

from rascal.deps import CurrentUser, SessionDep
from rascal.errors import not_found
from rascal.schemas.device import DeviceOut, DeviceRegistration
from rascal.services.devices import register_device, revoke_device, user_owns_token

router = APIRouter(prefix="/devices", tags=["devices"])


@router.post(
    "",
    response_model=DeviceOut,
    summary="Register this phone for the daily notification",
    description=(
        "Idempotent. Call it on every launch that holds a token — the same `(token, "
        "environment)` pair updates the existing row and refreshes `last_seen_at` rather "
        "than creating a second one, and a token that was revoked at sign-out comes back "
        "live.\n\n"
        "`environment` is required and has no default: a `sandbox` token sent to the "
        "production APNs host fails silently, which is the usual reason push works in "
        "development and not in TestFlight. The same token string may exist as both a "
        "sandbox and a production row.\n\n"
        "Registering does not turn notifications on. That is `notify_enabled` on "
        "`PATCH /v1/me`, and the client sets it only after the parent grants OS permission."
    ),
)
async def register(
    payload: DeviceRegistration, session: SessionDep, user: CurrentUser
) -> DeviceOut:
    device = await register_device(
        session,
        user,
        token=payload.token,
        platform=payload.platform,
        environment=payload.environment,
    )
    return DeviceOut.model_validate(device)


@router.delete(
    "/{token}",
    status_code=204,
    summary="Stop sending to this phone",
    description=(
        "Called on sign-out. A soft delete — `revoked_at` is set and the row stays, so the "
        "same phone signing back in updates it rather than growing a duplicate.\n\n"
        "Revokes the token across both environments, because sign-out means this phone "
        "stops receiving on this account and a phone that has run both a development and a "
        "TestFlight build holds a row for each. Idempotent: revoking twice is still `204`. "
        "A token this account never registered is `404`."
    ),
)
async def revoke(
    token: Annotated[str, Path(description="The APNs device token to stop sending to.")],
    session: SessionDep,
    user: CurrentUser,
) -> Response:
    # Ownership is the `user_id` filter inside both calls, so another account's token reads
    # as absent rather than as forbidden — answering "it exists, but not for you" would make
    # this route a way to probe tokens.
    if not await user_owns_token(session, user, token):
        raise not_found("Device")
    await revoke_device(session, user, token=token)
    return Response(status_code=204)
