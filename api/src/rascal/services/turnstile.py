"""Cloudflare Turnstile, verified server-side.

**This is the entire protection on a public write endpoint.** There is no rate limit on
`POST /v1/subscribe` — the owner's call of Aug 16, 2026, per `decisions.md` open item 12(1), on
the grounds that no volume is expected that Turnstile would not already stop. That makes every
way past this function a way into the endpoint.

**Unset means refuse, and that is the whole design.** `roadmap-status.md` names the opposite —
skipping verification when the key is missing — as *the* defect to design against, because it is
the one that leaves the health check green while the endpoint stands wide open. A service that
quietly stops checking is worse than one that stops working: the second gets fixed.

There is deliberately **no bypass for `ENVIRONMENT == "local"`**. Cloudflare publishes test keys
that always pass, which is what a local run uses; a second way through the gate is always the one
that survives into production by accident.
"""

from __future__ import annotations

import logging

import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

log = logging.getLogger("rascal.turnstile")


class TurnstileUnavailable(RascalError):
    """The check could not be performed. **Never confused with a token that failed.**

    A missing key and a Cloudflare outage are operator problems and answer `503`; a bad token
    is a caller problem and answers `422`. Collapsing them would make an outage look like a
    wave of bad submissions, and a missing key look like a spam attack.
    """

    def __init__(self, message: str) -> None:
        super().__init__(ErrorCode.INTERNAL_ERROR, message, status_code=503)


class TurnstileRejected(RascalError):
    """The token was absent, malformed, expired, or already spent."""

    def __init__(self) -> None:
        super().__init__(
            ErrorCode.VALIDATION_FAILED,
            "That didn't verify. Reload the page and try once more.",
            field="turnstile_token",
        )


async def verify(token: str | None, settings: Settings, *, remote_ip: str | None = None) -> None:
    """Raise unless Cloudflare says this token is good. Returns None on success.

    Raising rather than returning a bool is deliberate: a caller that forgets to check a
    returned bool has silently disabled the only protection on the endpoint, and that is a
    single missing `if` away. There is no value here to ignore.
    """
    if not settings.turnstile_secret_key:
        # Loud, and on every request. A single startup warning is a line nobody reads in a log
        # nobody opens; a refusal is a thing somebody reports within the hour.
        log.error("turnstile is unconfigured, so the subscribe endpoint is refusing")
        raise TurnstileUnavailable("Signups are not accepting submissions right now.")

    if not token:
        raise TurnstileRejected()

    form = {"secret": settings.turnstile_secret_key, "response": token}
    if remote_ip:
        form["remoteip"] = remote_ip

    try:
        async with httpx.AsyncClient(timeout=settings.turnstile_timeout_seconds) as client:
            response = await client.post(settings.turnstile_verify_url, data=form)
    except httpx.HTTPError as exc:
        # **Cloudflare being unreachable is not a pass.** Failing open here would mean an
        # outage at their end silently opens ours, which is the same defect as the missing key
        # wearing different clothes.
        log.warning("turnstile unreachable", extra={"reason": str(exc)})
        raise TurnstileUnavailable("Could not check that just now. Try again shortly.") from exc

    if response.status_code >= 500:
        log.warning("turnstile error", extra={"status": response.status_code})
        raise TurnstileUnavailable("Could not check that just now. Try again shortly.")

    # A non-2xx below 500 means we sent something wrong — a malformed secret, usually. That is
    # an operator problem wearing a caller's status code, so it is a 503 rather than a 422.
    if response.status_code >= 300:
        log.error("turnstile refused our request", extra={"status": response.status_code})
        raise TurnstileUnavailable("Signups are not accepting submissions right now.")

    body = response.json()
    if not body.get("success"):
        # `error-codes` is Cloudflare's, and it distinguishes "bad token" from "bad secret".
        # The second is ours and must not be reported to the caller as their mistake.
        codes = body.get("error-codes") or []
        if any(code in {"invalid-input-secret", "missing-input-secret"} for code in codes):
            log.error("turnstile secret is wrong", extra={"codes": codes})
            raise TurnstileUnavailable("Signups are not accepting submissions right now.")
        log.info("turnstile rejected a token", extra={"codes": codes})
        raise TurnstileRejected()
