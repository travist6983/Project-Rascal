"""Auth endpoints.

`POST /auth/password` and `POST /auth/google` slot in here later against the same
`credentials` table with no schema change. That is the point of the credential row.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, status

from rascal.deps import SessionDep, SettingsDep, get_apple_verifier
from rascal.schemas.auth import (
    AppleSignInRequest,
    DevLoginRequest,
    LogoutRequest,
    RefreshRequest,
    SessionResponse,
    TokenPairResponse,
)
from rascal.schemas.common import UserOut
from rascal.services.apple import AppleVerifier
from rascal.services.auth import user_for_credential
from rascal.services.tokens import (
    issue_token_pair,
    revoke_refresh_token,
    rotate_refresh_token,
)

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
    _, tokens = await rotate_refresh_token(session, payload.refresh_token, settings)
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
    user = await user_for_credential(
        session,
        "password",
        payload.email,
        email=payload.email,
        display_name=payload.display_name,
    )
    # The fixture account owns the local library too, or seeding a prompt by hand while
    # building the client would need a second, privileged login that does not exist.
    if not user.is_admin:
        user.is_admin = True
        await session.flush()
    tokens = await issue_token_pair(session, user.id, settings)
    return SessionResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=UserOut.model_validate(user),
    )
