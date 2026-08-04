"""Auth request and response bodies."""

from __future__ import annotations

from pydantic import Field

from rascal.schemas.common import ApiModel, UserOut


class AppleSignInRequest(ApiModel):
    identity_token: str = Field(min_length=1)
    # Carried for parity with the Sign in with Apple payload. RASCAL verifies the identity
    # token directly and never calls Apple's token endpoint, so this is accepted and ignored.
    authorization_code: str | None = None
    display_name: str | None = None


class RefreshRequest(ApiModel):
    refresh_token: str = Field(min_length=1)


class LogoutRequest(ApiModel):
    refresh_token: str = Field(min_length=1)


class DevLoginRequest(ApiModel):
    """Local only. A fixture account so curl and the iOS client can work before enrollment."""

    email: str = "dev@rascal.local"
    display_name: str = "Dev Parent"


class TokenPairResponse(ApiModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class SessionResponse(TokenPairResponse):
    user: UserOut
