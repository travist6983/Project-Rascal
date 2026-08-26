"""Auth request and response bodies."""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from rascal.schemas.common import ApiModel, UserOut


class AppleSignInRequest(ApiModel):
    identity_token: str = Field(min_length=1)
    # **Read since phase 127; accepted and ignored before it.** The identity token is still what
    # proves who this is — the code is not an authentication input and nothing here trusts it.
    # It is exchanged with Apple for a refresh token so that deleting the account seven days
    # later can revoke the Sign in with Apple link, which Guideline 5.1.1(v) requires and which
    # nothing in this schema could previously carry. Optional because a client that omits it
    # must still be able to sign in, and because every client did until phase 127.
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
    """The same shape as `AppleSignInRequest`, minus the field only Apple needs.

    No `authorization_code`. Apple's is read (phase 127) to obtain the refresh token its
    revocation endpoint demands; Google requires no equivalent to delete an account, so adding
    one here would be carrying a field for a call this service does not make.
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
