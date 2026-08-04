"""Sign in with Apple identity token verification.

Verification is real: fetch Apple's JWKS, verify the signature against the key the token
names, then check `iss`, `aud` against the bundle id, and `exp`. The JWKS is cached with a
TTL because Apple's keys are stable for hours and a fetch per login is a self-inflicted
outage.

The fetch is injected so tests can hand in a local keypair and never touch the network.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.apple")

JwksFetcher = Callable[[], Awaitable[dict[str, Any]]]


@dataclass(frozen=True)
class AppleIdentity:
    """What Apple tells us about a person. `subject_id` is the only stable part."""

    subject_id: str
    email: str | None
    email_verified: bool


async def fetch_apple_jwks(url: str) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.json()


class AppleVerifier:
    """Verifies Apple identity tokens, caching the JWKS for `apple_jwks_cache_seconds`."""

    def __init__(self, settings: Settings, fetch: JwksFetcher | None = None) -> None:
        self._settings = settings
        self._fetch = fetch or (lambda: fetch_apple_jwks(settings.apple_jwks_url))
        self._jwks: dict[str, Any] | None = None
        self._fetched_at = 0.0

    async def _keys(self, *, force: bool = False) -> dict[str, Any]:
        stale = time.monotonic() - self._fetched_at > self._settings.apple_jwks_cache_seconds
        if force or self._jwks is None or stale:
            self._jwks = await self._fetch()
            self._fetched_at = time.monotonic()
        return self._jwks

    async def _key_for(self, kid: str) -> Any:
        """Apple rotates keys without warning, so an unknown kid earns exactly one refetch."""
        for attempt in (False, True):
            jwks = await self._keys(force=attempt)
            for key in jwks.get("keys", []):
                if key.get("kid") == kid:
                    return jwt.PyJWK(key, algorithm=key.get("alg", "RS256")).key
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Apple identity token has an unknown key.")

    async def verify(self, identity_token: str) -> AppleIdentity:
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.InvalidTokenError as exc:
            raise RascalError(
                ErrorCode.UNAUTHENTICATED, "Apple identity token is malformed."
            ) from exc

        kid = header.get("kid")
        if not kid:
            raise RascalError(ErrorCode.UNAUTHENTICATED, "Apple identity token has no key id.")

        key = await self._key_for(kid)
        try:
            claims = jwt.decode(
                identity_token,
                key,
                algorithms=["RS256"],
                audience=self._settings.apple_bundle_id,
                issuer=self._settings.apple_issuer,
                options={"require": ["exp", "iss", "aud", "sub"]},
            )
        except jwt.ExpiredSignatureError as exc:
            raise RascalError(ErrorCode.TOKEN_EXPIRED, "Apple identity token has expired.") from exc
        except jwt.InvalidTokenError as exc:
            # Wrong audience, wrong issuer, bad signature — all the same answer to a client.
            log.warning("apple identity token rejected", extra={"reason": str(exc)})
            raise RascalError(
                ErrorCode.UNAUTHENTICATED, "Apple identity token could not be verified."
            ) from exc

        email_verified = claims.get("email_verified")
        return AppleIdentity(
            subject_id=str(claims["sub"]),
            email=claims.get("email"),
            # Apple sends this as either a bool or the strings "true"/"false".
            email_verified=email_verified in (True, "true"),
        )
