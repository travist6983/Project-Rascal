"""Auth request and response bodies."""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from rascal.schemas.common import ApiModel, UserOut


class AppleSignInRequest(ApiModel):
    identity_token: str = Field(min_length=1)
    # Carried for parity with the Sign in with Apple payload. RASCAL verifies the identity
    # token directly and never calls Apple's token endpoint, so this is accepted and ignored.
    authorization_code: str | None = None
    display_name: str | None = None


class AppleNotificationRequest(ApiModel):
    """Apple's server-to-server notification body: one field, holding a signed JWT.

    The field really is named `payload` — the outer object is `{"payload": "<jwt>"}` — so the
    attribute reads as `payload.payload` at the one call site. Renaming it would break the
    wire format for a small gain in how one line reads.
    """

    payload: str = Field(min_length=1)


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


class GoogleSignInRequest(ApiModel):
    """The same shape as `AppleSignInRequest`, minus Apple's vestigial fields.

    No `authorization_code`: Apple's is carried for parity with its own payload and ignored,
    and copying a field we already do not use into a second provider would be inventing debt.
    """

    identity_token: str = Field(min_length=1)
    display_name: str | None = None


class EmailSignInStartRequest(ApiModel):
    """One field. Always answered `202`, whether or not it matched anything."""

    email: str = Field(min_length=1, max_length=320)


class EmailSignInCompleteRequest(ApiModel):
    token: str = Field(min_length=1)


class EmailCredentialCreate(ApiModel):
    """Adding an email address as a sign-in method, from inside a session.

    Separate from `CredentialCreate` because there is no token to verify: an address is proved
    by the click, not by the field it was typed into. **It must never be defaulted from
    `users.email`** — the production account is on a `privaterelay.appleid.com` address, and a
    link to a relay that has stopped forwarding is a dead key that looks alive.
    """

    provider: Literal["email"] = "email"
    email: str = Field(min_length=3, max_length=320)
