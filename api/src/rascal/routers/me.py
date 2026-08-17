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
import logging
import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, status

from rascal.config import Settings
from rascal.deps import (
    CurrentUser,
    SessionDep,
    SettingsDep,
    get_apple_verifier,
    get_google_verifier,
)
from rascal.errors import ErrorCode, RascalError, validation_failed
from rascal.models import Credential
from rascal.schemas.auth import EmailCredentialCreate
from rascal.schemas.common import ApiModel, UserOut
from rascal.schemas.credential import CredentialCreate, CredentialOut
from rascal.schemas.user import MeUpdate
from rascal.services import deletion
from rascal.services.apple import AppleVerifier
from rascal.services.auth import (
    attach_credential,
    credentials_for_user,
    revoke_credential,
    subject_hint,
)
from rascal.services.email_sign_in import attach_email_credential
from rascal.services.google import GoogleVerifier
from rascal.services.mail import send
from rascal.services.rate_limit import check_and_record

log = logging.getLogger("rascal.me")

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


# --- The sign-in methods on this account (phase 52) ---------------------------------------
#
# Linking is explicit and nothing here matches on email. Two people can share an address, one
# person's Apple relay address is not their Google address, and an archive of somebody's
# childhood is not a thing to hand over on a string comparison. A credential joins an account
# because somebody signed in to that account and asked for it.


def _rendered(credential: Credential) -> CredentialOut:
    return CredentialOut(
        id=credential.id,
        provider=credential.provider,
        subject_hint=subject_hint(credential.provider, credential.subject_id),
        created_at=credential.created_at,
        revoked_at=credential.revoked_at,
    )


@router.get(
    "/credentials",
    response_model=list[CredentialOut],
    summary="The sign-in methods on the caller's account",
    description=(
        "Every credential on the account behind the bearer token, oldest first, **including "
        "revoked ones** — a parent who turned one off and wants it back needs to see that it "
        "is off rather than find it missing. `revoked_at` is null for a live credential.\n\n"
        "`subject_id` is never returned. `subject_hint` is a masked form carrying just enough "
        "to tell two credentials of the same provider apart."
    ),
)
async def list_my_credentials(session: SessionDep, user: CurrentUser) -> list[CredentialOut]:
    rows = await credentials_for_user(session, user.id)
    return [_rendered(row) for row in rows]


@router.post(
    "/credentials",
    response_model=CredentialOut,
    status_code=status.HTTP_200_OK,
    summary="Add a sign-in method to the caller's account",
    description=(
        "Verifies the provider token exactly as that provider's sign-in route does, then "
        "attaches it to the **current** account — the one behind the bearer token, never one "
        "resolved from an email address.\n\n"
        "Attaching a subject already bound to this account is an idempotent `200`. Attaching "
        "one bound to a *different* account is `409 credential_in_use`, and nothing is "
        "written: credentials are never reassigned and accounts are never merged. Several "
        "credentials per provider are allowed.\n\n"
        "`200` rather than `201` on both paths, because the caller cannot tell them apart and "
        "should not have to."
    ),
)
async def add_my_credential(
    payload: CredentialCreate,
    session: SessionDep,
    user: CurrentUser,
    apple: AppleVerifier = Depends(get_apple_verifier),
    google: GoogleVerifier = Depends(get_google_verifier),
) -> CredentialOut:
    # The literal on `CredentialCreate.provider` is what rejects anything else, so this is an
    # exhaustive match rather than a branch with a hole in it. Both verifiers are injected
    # because FastAPI resolves dependencies before the handler runs — building one lazily
    # inside a branch would mean two ways to construct a verifier.
    verifier = apple if payload.provider == "apple" else google
    identity = await verifier.verify(payload.identity_token)
    credential = await attach_credential(
        session,
        user,
        payload.provider,
        identity.subject_id,
        email=identity.email,
        display_name=payload.display_name,
    )
    await session.flush()
    return _rendered(credential)


@router.post(
    "/credentials/email",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Add an email address as a sign-in method",
    description=(
        "**The address is typed by the parent and proved by the click, never by this field.** "
        "The credential is created *inactive* — `revoked_at` set — and a link is sent; opening "
        "it through `POST /auth/email/complete` is what turns it into a way in. A typo "
        "therefore costs nothing, because the inbox that receives the link is the only one "
        "that can activate it.\n\n"
        "**It must never be defaulted from `users.email` by a client.** The production account "
        "is on a `privaterelay.appleid.com` address, and Apple can stop forwarding a relay at "
        "any time without telling anybody — a magic link to a dead relay is a key that looks "
        "alive.\n\n"
        "**Always `202`, and the body says nothing about the address.** An address already on "
        "a *different* account is answered identically to a fresh one, with nothing written "
        "and nothing sent — anything else would tell any caller, and anyone who can create a "
        "free account is a caller, whether a given address signs in to Dogear. "
        "`POST /auth/email/start` already refuses that question unconditionally, so answering "
        "it here would be an inconsistency as much as a leak.\n\n"
        "An address already on *this* account gets a fresh link, so an expired verification is "
        "retryable without a second row. Read `GET /me/credentials` afterwards for the result."
    ),
)
async def add_my_email_credential(
    payload: EmailCredentialCreate,
    background: BackgroundTasks,
    session: SessionDep,
    settings: SettingsDep,
    user: CurrentUser,
) -> dict[str, str]:
    # **Rate limited even though it is authenticated, which is the exception to the rule this
    # service otherwise follows.** Everything behind a bearer token is normally the account's
    # own business — but this route sends mail to an address the account does not own and has
    # not proved anything about. Without a limit, anyone who can create a free account can use
    # this to mail an arbitrary stranger repeatedly, with our sending reputation.
    #
    # Keyed on the *user* rather than the address: the address is the attacker's choice and a
    # per-address bucket would be trivially sidestepped by varying it.
    window = dt.timedelta(seconds=settings.email_sign_in_window_seconds)
    await check_and_record(
        session,
        f"credential-add:{user.id}",
        limit=settings.email_sign_in_per_email_limit,
        window=window,
    )

    attached = await attach_email_credential(session, user, payload.email)
    if attached is not None:
        credential, raw = attached
        # Queued rather than awaited, for the same reason `POST /auth/email/start` queues: the
        # response must not carry the mail provider's latency, and a provider outage must not
        # become this route's status code — which would reintroduce the oracle by another door.
        background.add_task(_deliver_verification_link, settings, credential.subject_id, raw)
    await session.flush()
    # The same body either way, exactly as `POST /auth/email/start` answers.
    return {"status": "accepted"}


async def _deliver_verification_link(settings: Settings, address: str, raw_token: str) -> None:
    link = f"{settings.email_sign_in_link_base}?token={raw_token}"
    try:
        await send(
            settings,
            # Transactional for the same reason the sign-in link is: the account
            # asked for it, and it reads no consent column — D3a.
            stream="transactional",
            to=address,
            subject="Confirm this address for Dogear",
            text=(
                "Open this link to add this address as a way to sign in to Dogear.\n\n"
                f"{link}\n\n"
                "It works once, and for fifteen minutes. Until you open it, this address cannot "
                "be used to sign in. If you did not ask for this, you can ignore it."
            ),
        )
    except Exception:
        log.warning("verification link could not be delivered", exc_info=True)


@router.delete(
    "/credentials/{credential_id}",
    response_model=CredentialOut,
    summary="Remove a sign-in method from the caller's account",
    description=(
        "A soft revocation: the row stays, `revoked_at` is set, and the credential keeps its "
        "claim on its provider subject — so signing in with it again reactivates it and lands "
        "on the same account.\n\n"
        "**Refuses to revoke the last live credential**, with `409 last_credential`. Removing "
        "the only way into an account would lock a parent out of the archive permanently, and "
        "that must not be reachable through an API call. Revoking an already-revoked "
        "credential is a no-op `200`."
    ),
)
async def remove_my_credential(
    credential_id: uuid.UUID, session: SessionDep, user: CurrentUser
) -> CredentialOut:
    credential = await revoke_credential(session, user, credential_id)
    await session.flush()
    return _rendered(credential)


# --- Deleting the account ---------------------------------------------------------------------
#
# Apple has required in-app account deletion for apps offering account creation since June 2022,
# and `docs/investigations/account-deletion.md` found this app had none. These two routes are
# what makes the requirement satisfiable from a Settings screen rather than by emailing support.


class DeletionOut(ApiModel):
    """A pending request. `execute_after` is what the client counts down to."""

    requested_at: dt.datetime
    execute_after: dt.datetime


@router.post("/deletion", response_model=DeletionOut, status_code=status.HTTP_202_ACCEPTED)
async def request_account_deletion(session: SessionDep, user: CurrentUser) -> DeletionOut:
    """Ask for the account to be deleted, seven days from now.

    **`202`, not `204`:** nothing has been deleted yet, and saying otherwise would be the one
    lie this endpoint cannot afford. The body carries the date so the client can say exactly
    when, rather than paraphrasing a policy it would then have to keep in step.

    **Idempotent.** Asking twice returns the first request rather than restarting the clock — a
    second tap must not quietly buy another seven days.

    Every refresh token is revoked, so this signs them out of every device immediately. Signing
    back in cancels the request outright, per D3's precedent.
    """
    request = await deletion.request_deletion(session, user)
    return DeletionOut(requested_at=request.requested_at, execute_after=request.execute_after)


@router.delete("/deletion", status_code=status.HTTP_204_NO_CONTENT)
async def cancel_account_deletion(session: SessionDep, user: CurrentUser) -> None:
    """Change your mind. Idempotent — cancelling nothing is a success.

    `204` whether or not there was one to cancel. A `404` here would tell somebody who has
    already been reassured that something is wrong, and there is nothing they could do about it.
    """
    await deletion.cancel_deletion(session, user.id)
