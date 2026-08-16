"""Sign in with Apple: identity tokens, and the server-to-server notifications beside them.

Verification is real: fetch Apple's JWKS, verify the signature against the key the token
names, then check `iss`, `aud` against the configured audiences, and `exp`. The JWKS caching,
the key lookup and the decode all live in `oidc.py`, shared with Google — a hand-maintained
second copy of a signature check drifts, and the copy that misses a fix keeps returning 200s.

**`aud` is an allowlist, not an equality.** `settings.apple_bundle_id` is a list, and a token
passes if it matches any entry — the iOS app and a browser client signing in through a Services
ID are two audiences for one credential. A token for an audience nobody configured is still
rejected exactly as before.

The fetch is injected so tests can hand in a local keypair and never touch the network.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
from dataclasses import dataclass
from typing import Final

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.services.oidc import JwksFetcher, JwksVerifier, fetch_jwks

log = logging.getLogger("rascal.apple")


async def fetch_apple_jwks(url: str) -> dict:
    return await fetch_jwks(url)


@dataclass(frozen=True)
class AppleIdentity:
    """What Apple tells us about a person. `subject_id` is the only stable part."""

    subject_id: str
    email: str | None
    email_verified: bool


#: The four server-to-server notifications Apple sends. Anything else is acknowledged and
#: ignored — Apple may add types, and a 400 would make it retry something we will never handle.
APPLE_EVENT_TYPES: Final = (
    "consent-revoked",
    "account-delete",
    "email-disabled",
    "email-enabled",
)


@dataclass(frozen=True)
class AppleServerNotification:
    """One decoded server-to-server event.

    `subject_id` is already `credentials.subject_id` — the same `sub` the identity token
    carries — so acting on one of these is a single indexed lookup.
    """

    event_type: str
    subject_id: str
    email: str | None
    event_time: dt.datetime | None


class AppleVerifier(JwksVerifier):
    """Verifies Apple identity tokens and notifications, caching the JWKS between them."""

    provider = "Apple identity"

    def __init__(self, settings: Settings, fetch: JwksFetcher | None = None) -> None:
        super().__init__(
            jwks_url=settings.apple_jwks_url,
            issuers=(settings.apple_issuer,),
            audiences=settings.apple_bundle_id,
            cache_seconds=settings.apple_jwks_cache_seconds,
            fetch=fetch,
        )

    async def verify(self, identity_token: str) -> AppleIdentity:
        claims = await self.decode(identity_token, require=["exp", "iss", "aud", "sub"])
        email_verified = claims.get("email_verified")
        return AppleIdentity(
            subject_id=str(claims["sub"]),
            email=claims.get("email"),
            # Apple sends this as either a bool or the strings "true"/"false".
            email_verified=email_verified in (True, "true"),
        )

    async def verify_notification(self, payload: str) -> AppleServerNotification:
        """Verify a server-to-server notification and pull the one event out of it.

        Same signature check as an identity token and against the same cached JWKS, because it
        is the same Apple and the same keys. The differences are all in the claim set:

        - **`sub` is not a top-level claim.** It lives inside `events`, so requiring it here
          would reject every real notification.
        - **There is no `exp`.** Requiring one would do the same. `decode` still validates one
          if Apple ever starts sending it, which is the behaviour we want either way.
        - **`events` is a JSON *string*, not an object.** This looks like an error in Apple's
          documentation and is not — decoding it twice is mandatory.
        """
        claims = await self.decode(payload, require=["iss", "aud", "events"])

        raw = claims["events"]
        try:
            event = json.loads(raw) if isinstance(raw, str) else raw
        except json.JSONDecodeError as exc:
            raise RascalError(
                ErrorCode.UNAUTHENTICATED, "Apple notification carries no readable event."
            ) from exc
        if not isinstance(event, dict) or not event.get("sub") or not event.get("type"):
            raise RascalError(
                ErrorCode.UNAUTHENTICATED, "Apple notification carries no readable event."
            )

        return AppleServerNotification(
            event_type=str(event["type"]),
            subject_id=str(event["sub"]),
            email=event.get("email"),
            event_time=_event_time(event.get("event_time")),
        )


def _event_time(raw: object) -> dt.datetime | None:
    """Apple sends `event_time` in **milliseconds**, which is the trap in this field.

    Read as seconds it lands in the year 56000 and any comparison against it is nonsense.
    An unreadable value is `None` rather than an error: the event is still worth acting on,
    and the timestamp is not what any of the four behaviours turns on.
    """
    if raw is None:
        return None
    try:
        return dt.datetime.fromtimestamp(int(raw) / 1000, tz=dt.UTC)
    except (TypeError, ValueError, OSError, OverflowError):
        return None
