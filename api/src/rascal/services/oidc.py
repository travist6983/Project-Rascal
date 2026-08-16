"""The JWKS machinery Apple and Google share.

Both providers are the same protocol with different URLs: fetch a key set, cache it, verify a
token's signature against the key it names, then check `iss`, `aud` and `exp`. Everything in
this file is that; everything provider-specific stays in `apple.py` and `google.py`.

**It is shared rather than copied because a verifier is the wrong place for a near-duplicate.**
Two hand-maintained copies of a signature check drift, and the drift is silent: the copy that
did not get the fix keeps returning 200s. The one-refetch-on-unknown-`kid` rule below is
exactly the kind of subtlety that would have been fixed in one of two files.

**`aud` and `iss` are both allowlists here.** Apple needs multiple audiences (the app and,
later, a browser client through a Services ID); Google publishes two spellings of its own
issuer and both are seen in the wild.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Awaitable, Callable, Sequence
from typing import Any

import httpx
import jwt

from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.oidc")

JwksFetcher = Callable[[], Awaitable[dict[str, Any]]]


async def fetch_jwks(url: str) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.json()


class JwksVerifier:
    """A cached JWKS and a real signature check against it.

    Subclasses supply the URLs and the claim rules; this owns the cache, the key lookup and
    the decode. `provider` is only used to name the provider in error messages, so a client
    reading a 401 can tell which sign-in failed.
    """

    provider = "provider"

    def __init__(
        self,
        *,
        jwks_url: str,
        issuers: Sequence[str],
        audiences: Sequence[str],
        cache_seconds: int,
        fetch: JwksFetcher | None = None,
    ) -> None:
        self._jwks_url = jwks_url
        self._issuers = tuple(issuers)
        self._audiences = list(audiences)
        self._cache_seconds = cache_seconds
        self._fetch = fetch or (lambda: fetch_jwks(jwks_url))
        self._jwks: dict[str, Any] | None = None
        self._fetched_at = 0.0

    def _unauthenticated(self, message: str) -> RascalError:
        return RascalError(ErrorCode.UNAUTHENTICATED, message)

    async def _keys(self, *, force: bool = False) -> dict[str, Any]:
        stale = time.monotonic() - self._fetched_at > self._cache_seconds
        if force or self._jwks is None or stale:
            self._jwks = await self._fetch()
            self._fetched_at = time.monotonic()
        return self._jwks

    async def _key_for(self, kid: str) -> Any:
        """Both providers rotate keys without warning, so an unknown kid earns one refetch.

        Exactly one. A token naming a key that does not exist is otherwise a way to make this
        service hammer someone else's endpoint once per request.
        """
        for attempt in (False, True):
            jwks = await self._keys(force=attempt)
            for key in jwks.get("keys", []):
                if key.get("kid") == kid:
                    return jwt.PyJWK(key, algorithm=key.get("alg", "RS256")).key
        raise self._unauthenticated(f"{self.provider} token has an unknown key.")

    async def decode(self, token: str, *, require: Sequence[str]) -> dict[str, Any]:
        """Verify signature, audience, issuer and expiry, and hand back the claims."""
        try:
            header = jwt.get_unverified_header(token)
        except jwt.InvalidTokenError as exc:
            raise self._unauthenticated(f"{self.provider} token is malformed.") from exc

        kid = header.get("kid")
        if not kid:
            raise self._unauthenticated(f"{self.provider} token has no key id.")

        key = await self._key_for(kid)
        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=self._audiences,
                # Checked below rather than here, because PyJWT's `issuer=` takes one string
                # and Google publishes two spellings of its own. Same rejection either way.
                options={"require": list(require)},
            )
        except jwt.ExpiredSignatureError as exc:
            raise RascalError(
                ErrorCode.TOKEN_EXPIRED, f"{self.provider} token has expired."
            ) from exc
        except jwt.InvalidTokenError as exc:
            # Wrong audience, bad signature, missing claim — all the same answer to a client.
            log.warning("token rejected", extra={"provider": self.provider, "reason": str(exc)})
            raise self._unauthenticated(f"{self.provider} token could not be verified.") from exc

        if claims.get("iss") not in self._issuers:
            log.warning("token rejected", extra={"provider": self.provider, "reason": "issuer"})
            raise self._unauthenticated(f"{self.provider} token could not be verified.")
        return claims
