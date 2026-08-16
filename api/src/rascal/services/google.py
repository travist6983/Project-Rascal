"""Google sign-in identity token verification.

The same protocol as Apple, on `oidc.JwksVerifier`, with three differences that are Google's
rather than ours:

- **Two valid issuers.** `accounts.google.com` and `https://accounts.google.com` are both
  published as correct and both are seen, so `iss` is an allowlist.
- **A separate audience list.** `GOOGLE_CLIENT_IDS`, never Apple's. They are different
  namespaces that happen to share a claim name, and pooling them would let an Apple token for
  a Google client id verify.
- **`email_verified` is load-bearing here.** Google will issue a token for an unverified
  address on some account types, and an unverified address is a claim about an inbox nobody
  has proved they can read. Phase 57 turns an `email` credential into a way to sign in, so
  accepting one here would make an unverified address a key.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.services.oidc import JwksFetcher, JwksVerifier

log = logging.getLogger("rascal.google")


@dataclass(frozen=True)
class GoogleIdentity:
    """What Google tells us about a person. `subject_id` is the only stable part.

    `sub` is stable per Google account per project and is never reused. The email can change;
    it is a gap-fill hint and never an identifier — nothing in this service looks a user up by
    email, which is the rule that makes linking explicit.
    """

    subject_id: str
    email: str | None
    email_verified: bool


class GoogleVerifier(JwksVerifier):
    """Verifies Google identity tokens, caching the JWKS for `google_jwks_cache_seconds`."""

    provider = "Google identity"

    def __init__(self, settings: Settings, fetch: JwksFetcher | None = None) -> None:
        self._configured = settings.google_configured
        super().__init__(
            jwks_url=settings.google_jwks_url,
            issuers=settings.google_issuers,
            audiences=settings.google_client_ids,
            cache_seconds=settings.google_jwks_cache_seconds,
            fetch=fetch,
        )

    async def verify(self, identity_token: str) -> GoogleIdentity:
        if not self._configured:
            # Without this, an unconfigured deployment answers every Google sign-in with
            # "could not be verified" — true, and useless. `audience=[]` rejects everything,
            # so the failure would look like a bad token rather than a missing setting.
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                "Google sign-in is not configured on this server (GOOGLE_CLIENT_IDS is unset).",
                field="identity_token",
            )

        claims = await self.decode(identity_token, require=["exp", "iss", "aud", "sub"])

        # Google sends this as a bool, and as the string "true" through some paths. Anything
        # that is not affirmatively verified is refused — the default has to be no.
        if claims.get("email_verified") not in (True, "true"):
            log.warning("google token rejected", extra={"reason": "email_not_verified"})
            raise RascalError(
                ErrorCode.UNAUTHENTICATED,
                "This Google account's email address is not verified.",
            )

        return GoogleIdentity(
            subject_id=str(claims["sub"]),
            email=claims.get("email"),
            email_verified=True,
        )
