"""Auth endpoints.

Apple and Google both land in the same `credentials` table with no schema change, which is the
point of the credential row — adding Google was a route and a verifier, not a migration.

**No sign-in route here ever links to an existing account.** Each one finds or creates the user
behind its own `(provider, subject_id)`, and nothing matches on email. Joining two credentials
is `POST /me/credentials`, which requires being signed in to the account you are joining them
to — see `docs/decisions-log.md`, phase 52.
"""

from __future__ import annotations

import datetime as dt
import logging

from fastapi import APIRouter, BackgroundTasks, Depends, Request, status

from rascal.config import Settings
from rascal.deps import SessionDep, SettingsDep, get_apple_verifier, get_google_verifier
from rascal.errors import validation_failed
from rascal.schemas.auth import (
    AppleSignInRequest,
    DevLoginRequest,
    EmailSignInCompleteRequest,
    EmailSignInStartRequest,
    GoogleSignInRequest,
    LogoutRequest,
    RefreshRequest,
    SessionResponse,
    TokenPairResponse,
)
from rascal.schemas.common import UserOut
from rascal.services.apple import AppleVerifier
from rascal.services.auth import touch_last_sign_in, user_for_credential
from rascal.services.email_sign_in import complete_sign_in, start_sign_in
from rascal.services.google import GoogleVerifier
from rascal.services.mail import send
from rascal.services.rate_limit import (
    check_and_record,
    client_address,
    email_bucket,
    ip_bucket,
)
from rascal.services.tokens import (
    issue_token_pair,
    revoke_refresh_token,
    rotate_refresh_token,
)

log = logging.getLogger("rascal.auth")

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post(
    "/apple",
    response_model=SessionResponse,
    status_code=status.HTTP_200_OK,
    summary="Exchange a Sign in with Apple credential for a session",
)
async def sign_in_with_apple(
    payload: AppleSignInRequest,
    session: SessionDep,
    settings: SettingsDep,
    verifier: AppleVerifier = Depends(get_apple_verifier),
) -> SessionResponse:
    identity = await verifier.verify(payload.identity_token)
    user = await user_for_credential(
        session,
        "apple",
        identity.subject_id,
        email=identity.email,
        # Apple sends the display name exactly once, at first authorization.
        display_name=payload.display_name,
    )
    tokens = await issue_token_pair(session, user.id, settings)
    await touch_last_sign_in(session, user.id)
    return SessionResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=UserOut.model_validate(user),
    )


@router.post(
    "/google",
    response_model=SessionResponse,
    status_code=status.HTTP_200_OK,
    summary="Exchange a Google credential for a session",
    description=(
        "The same shape as `POST /auth/apple`, against a `google` row in the same "
        "`credentials` table — which is the point of the credential row, and why this needed "
        "no schema change.\n\n"
        "`aud` is checked against `GOOGLE_CLIENT_IDS`, never Apple's audiences: they are "
        "different namespaces that share a claim name. `iss` may be either "
        "`accounts.google.com` or `https://accounts.google.com`, both of which Google "
        "publishes as correct. **`email_verified` must be true** — an unverified address is a "
        "claim about an inbox nobody has proved they can read.\n\n"
        "**This never links to an existing account.** A parent who already signed in with "
        "Apple and then signs in with Google gets a second, separate account. Joining them is "
        "`POST /me/credentials`, from inside the session they already have — linking is "
        "explicit and nothing anywhere matches on email address."
    ),
)
async def sign_in_with_google(
    payload: GoogleSignInRequest,
    session: SessionDep,
    settings: SettingsDep,
    verifier: GoogleVerifier = Depends(get_google_verifier),
) -> SessionResponse:
    identity = await verifier.verify(payload.identity_token)
    user = await user_for_credential(
        session,
        "google",
        identity.subject_id,
        email=identity.email,
        # Google returns the name on every token rather than once, but gap-fill is still
        # first-non-null-wins: `PATCH /me` is the only thing that changes a name once set.
        display_name=payload.display_name,
    )
    tokens = await issue_token_pair(session, user.id, settings)
    await touch_last_sign_in(session, user.id)
    return SessionResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=UserOut.model_validate(user),
    )


@router.post(
    "/email/start",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Send a sign-in link to an address that already has a credential",
    description=(
        "**Always `202`, whether or not the address matched anything.** Any other answer would "
        "make this an account-enumeration oracle, and the whole point of the restriction below "
        "is that there is nothing to enumerate.\n\n"
        "**This never creates a user.** It matches an existing, *verified* `email` credential "
        "or it does nothing. Email is a second key to a door you already own, added "
        "deliberately from Settings while signed in — there is no public signup on this path. "
        "Without that rule, an Apple parent who typed their address here would be handed a "
        "second, empty archive with no way to tell that was what happened.\n\n"
        "Rate limited per-email and per-IP, independently. Per-email is the one that matters: "
        "the abuse is spamming links at one address, and an edge limiter cannot see the "
        "address because it is inside this body."
    ),
)
async def start_email_sign_in(
    payload: EmailSignInStartRequest,
    request: Request,
    background: BackgroundTasks,
    session: SessionDep,
    settings: SettingsDep,
) -> dict[str, str]:
    window = dt.timedelta(seconds=settings.email_sign_in_window_seconds)
    # Both limiters, independently, and per-email first: it is the one protecting a person
    # rather than the service.
    await check_and_record(
        session,
        email_bucket(payload.email),
        limit=settings.email_sign_in_per_email_limit,
        window=window,
    )
    # Behind Fly's proxy the socket peer is the *proxy*, identical for every request on
    # the planet — see `client_address`, where the whole argument lives.
    client_host = client_address(request)
    await check_and_record(
        session,
        ip_bucket(client_host),
        limit=settings.email_sign_in_per_ip_limit,
        window=window,
    )

    match = await start_sign_in(session, payload.email)
    if match is not None:
        address, raw = match
        # **Queued, not awaited, and that is a security property rather than a performance
        # one.** Sending inline made the always-202 response a *timing* oracle: a registered
        # address paid a round trip to the mail provider and an unknown one returned
        # immediately, so the difference — hundreds of milliseconds — answered the exact
        # question the identical status code refuses to. It also meant a mail outage turned
        # this into a 500 for known addresses and a 202 for unknown ones, which is a far
        # louder oracle than the timing one.
        #
        # Running it after the response means every caller waits the same amount of time for
        # the same body, whatever the address, and a provider failure is a logged failure to
        # deliver rather than a signal.
        background.add_task(_deliver_sign_in_link, settings, address, raw)
    # The same body either way. A client cannot tell, and neither can anybody else.
    return {"status": "accepted"}


async def _deliver_sign_in_link(settings: Settings, address: str, raw_token: str) -> None:
    """Send one magic link, after the response has gone out.

    **Swallows its failure deliberately.** There is no caller left to tell, the parent has
    already been told to check their email, and the alternative — letting it escape — would
    put a traceback in the logs for something that is ordinary provider flakiness. What it must
    never do is reach back and change the answer, because the answer is the same either way.
    """
    link = f"{settings.email_sign_in_link_base}?token={raw_token}"
    try:
        await send(
            settings,
            to=address,
            subject="Your Dogear sign-in link",
            text=(
                "Here is your link to sign in to Dogear.\n\n"
                f"{link}\n\n"
                "It works once, and for fifteen minutes. If you did not ask for it, nothing "
                "has happened to your account and you can ignore this."
            ),
        )
    except Exception:
        # No address in the log line — an address in a log is the address leaving the system
        # by a path nobody audited.
        log.warning("sign-in link could not be delivered", exc_info=True)


@router.post(
    "/email/complete",
    response_model=SessionResponse,
    summary="Exchange a sign-in link token for a session",
    description=(
        "Single use and fifteen minutes. A token that is unknown, already consumed, expired, "
        "or belongs to a revoked credential is `401 sign_in_link_invalid` — **one answer for "
        "all four**, because telling them apart would say whether a link ever existed.\n\n"
        "A successful click also **verifies** the address: an `email` credential added through "
        "`POST /me/credentials` starts inactive and this is what activates it. Verifying a new "
        "address and signing in with an old one are the same act — proving you can read the "
        "inbox."
    ),
)
async def complete_email_sign_in(
    payload: EmailSignInCompleteRequest,
    session: SessionDep,
    settings: SettingsDep,
) -> SessionResponse:
    user = await complete_sign_in(session, payload.token)
    tokens = await issue_token_pair(session, user.id, settings)
    await touch_last_sign_in(session, user.id)
    return SessionResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=UserOut.model_validate(user),
    )


@router.post(
    "/refresh",
    response_model=TokenPairResponse,
    summary="Rotate a refresh token",
    description=(
        "The presented token is revoked and a new pair issued. Presenting a revoked token "
        "again returns 401 `refresh_token_reused` and revokes every other token in the chain."
    ),
)
async def refresh(
    payload: RefreshRequest,
    session: SessionDep,
    settings: SettingsDep,
) -> TokenPairResponse:
    user, tokens = await rotate_refresh_token(session, payload.refresh_token, settings)
    # **A refresh is activity, and counting only `/auth/apple` would delete active families.**
    # An app in daily use rotates its token and never performs a fresh sign-in again, so the
    # most engaged households would look dormant against D3's twelve-month inactivity clock.
    # See `touch_last_sign_in`.
    await touch_last_sign_in(session, user.id)
    return TokenPairResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
    )


@router.post(
    "/logout",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Revoke the presented refresh token",
)
async def logout(payload: LogoutRequest, session: SessionDep) -> None:
    await revoke_refresh_token(session, payload.refresh_token)


dev_router = APIRouter(prefix="/auth", tags=["auth"])


@dev_router.post(
    "/dev-login",
    response_model=SessionResponse,
    summary="Local-only fixture login",
    description=(
        "Registered only when ENVIRONMENT == 'local'. Creates or returns a fixture account "
        "so curl and the iOS client can work before Apple Developer enrollment clears."
    ),
)
async def dev_login(
    payload: DevLoginRequest,
    session: SessionDep,
    settings: SettingsDep,
) -> SessionResponse:
    email = payload.email.strip().lower()
    _, _, domain = email.rpartition("@")
    if domain not in settings.dev_login_email_domains:
        # **The second lock, and it closes a different hole from the first.** The route is
        # already absent from a production build. What this stops is a local API pointed at a
        # real database — a restore drill, a production debugging session — handing back an
        # `is_admin` session for somebody's actual account because a developer typed their own
        # address into it. `ENVIRONMENT` can be right while the database is not.
        raise validation_failed(
            "dev-login only issues sessions for the local fixture domains "
            f"({', '.join(settings.dev_login_email_domains)}).",
            field="email",
        )

    # `email` rather than `password`, as of phase 52. The fixture now rehearses the production
    # credential shape instead of squatting beside it: this is the same row phase 57's magic
    # link writes, so the local path exercises the real one rather than a lookalike.
    user = await user_for_credential(
        session,
        "email",
        email,
        email=email,
        display_name=payload.display_name,
    )
    # The fixture account owns the local library too, or seeding a prompt by hand while
    # building the client would need a second, privileged login that does not exist.
    if not user.is_admin:
        user.is_admin = True
        await session.flush()
    tokens = await issue_token_pair(session, user.id, settings)
    await touch_last_sign_in(session, user.id)
    return SessionResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=UserOut.model_validate(user),
    )
