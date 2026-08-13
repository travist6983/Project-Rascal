"""The APNs seam.

Every notification this service sends leaves through :class:`PushClient`. There are three
implementations and the choice is made once, by :func:`build_push_client`, from settings:

* :class:`ApnsClient` — the real one. HTTP/2 to Apple, authenticated with an ES256 provider
  token minted from the `.p8` key.
* :class:`UnconfiguredPushClient` — what a deployment with no APNs key gets. It sends
  nothing and returns a failure that names itself. It does **not** pretend to succeed:
  a push service that silently no-ops is indistinguishable from one that works until
  somebody notices their phone has been quiet for a month.
* :class:`StubPushClient` — for tests. Records what it was asked to send and returns
  whatever the test scripted.

**The first real APNs call was made on Aug 12, 2026.** `api.push.apple.com` answered
`HTTP/2 200` to a production token, the notification arrived on a locked phone, and tapping
it deep-linked to the assignment. So the topic, the payload shape, the token format and the
provider-token signature are all confirmed against Apple rather than assumed.

**The socket is still not in the test suite**, and that has not changed. `ApnsClient`'s pure
parts are tested (the provider token, the host and header construction, the response
mapping); everything past `self._client.post` is covered by production runs and by
`docs/device-verification-push.md`, not by pytest.

:class:`PushMessage` is deliberately narrow. It carries a title, a body and an assignment
id, and there is no field on it that could hold an entry, a transcript, a media key or a
count of anything. A notification renders on a lock screen other people can see, so the
type is the enforcement: you cannot leak what you cannot express.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Protocol

import httpx
import jwt

from rascal.config import Settings
from rascal.constants import PushEnvironment

log = logging.getLogger("rascal.push")

APNS_HOSTS: dict[PushEnvironment, str] = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}

# Apple rejects a provider token older than an hour and rate-limits minting them, so one
# token is reused until it is nearly expired rather than signed per request.
PROVIDER_TOKEN_TTL = dt.timedelta(minutes=45)

# Bounded, and small on purpose. A notification that has not gone out in a few seconds has
# missed the moment it was for; the staleness rule, not a longer retry, is what covers a
# window the job could not serve at all.
RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = (0.5, 1.0)

# Statuses worth trying again. 429 is Apple asking us to slow down; 5xx is Apple being down.
# Everything else is a statement about the request, and repeating it changes nothing.
RETRYABLE_STATUSES = frozenset({429, 500, 502, 503, 504})

# Reasons that mean this token will never work again, whatever we do.
DEAD_TOKEN_REASONS = frozenset({"BadDeviceToken", "Unregistered"})


@dataclass(frozen=True)
class PushMessage:
    """One notification, to one token.

    Every field is here because the notification cannot be delivered without it. There is
    deliberately nowhere to put entry content, a media reference, a sealed body, or a count
    of waiting items — see the module docstring.
    """

    token: str
    environment: PushEnvironment
    body: str
    assignment_id: uuid.UUID
    # The child's first name, or nothing. Optional because a title is a nicety and the
    # mission body is the message.
    title: str | None = None
    # APNs replaces an undelivered notification carrying the same collapse id rather than
    # stacking it. Two devices and a retry should never become three rows on a lock screen.
    collapse_id: str | None = None

    def payload(self) -> dict[str, object]:
        """The APNs JSON body. Plain JSON, like every other wire format here."""
        alert: dict[str, str] = {"body": self.body}
        if self.title:
            alert["title"] = self.title
        return {
            "aps": {"alert": alert, "sound": "default"},
            # What the client deep-links to. An id, not content.
            "assignment_id": str(self.assignment_id),
        }


@dataclass(frozen=True)
class PushResult:
    ok: bool
    status: int | None = None
    reason: str | None = None

    @property
    def token_is_dead(self) -> bool:
        """Whether APNs has told us to stop using this token, permanently.

        `410 Gone` is the documented one. `BadDeviceToken` arrives as a `400`, and
        `Unregistered` is what accompanies the `410`. Without acting on these, dead tokens
        accumulate forever and the delivery-failure rate climbs invisibly.
        """
        return self.status == 410 or (self.reason in DEAD_TOKEN_REASONS)

    @property
    def is_retryable(self) -> bool:
        return self.status in RETRYABLE_STATUSES


class PushClient(Protocol):
    """The seam. Nothing outside this module talks to APNs."""

    async def send(self, message: PushMessage) -> PushResult: ...

    async def aclose(self) -> None: ...


# --- The implementations -----------------------------------------------------------------


@dataclass
class StubPushClient:
    """Records what it was asked to send. For tests, and for a local build with no key.

    `results` scripts a response per token, so a test can make one device fail with a `410`
    while its sibling succeeds. Anything not named there succeeds.
    """

    sent: list[PushMessage] = field(default_factory=list)
    results: dict[str, PushResult] = field(default_factory=dict)
    closed: bool = False

    async def send(self, message: PushMessage) -> PushResult:
        self.sent.append(message)
        return self.results.get(message.token, PushResult(ok=True, status=200))

    async def aclose(self) -> None:
        self.closed = True


@dataclass
class UnconfiguredPushClient:
    """What a deployment with no APNs credentials gets.

    It fails, visibly, every time. The alternative — quietly succeeding — would make "push
    is not set up" and "push works" produce identical logs, identical `notification_sends`
    rows, and identical silence on the phone.
    """

    async def send(self, message: PushMessage) -> PushResult:
        log.warning(
            "push not configured, nothing sent",
            extra={
                "assignment_id": str(message.assignment_id),
                "push_environment": message.environment,
            },
        )
        return PushResult(ok=False, status=None, reason="apns_not_configured")

    async def aclose(self) -> None:
        return None


class ApnsClient:
    """The real client. HTTP/2 to Apple, ES256 provider-token authentication.

    Exercised against Apple for the first time on Aug 12, 2026 — see the module docstring —
    but not by the test suite, which still stops at the socket. What the suite *does* cover
    is everything that does not need one: the provider token's header and claims, the host
    chosen for each environment, the request headers, and the mapping from an APNs response
    onto :class:`PushResult`.
    """

    def __init__(
        self,
        *,
        key_id: str,
        team_id: str,
        private_key: str,
        topic: str,
        client: httpx.AsyncClient | None = None,
        now: Callable[[], dt.datetime] | None = None,
    ) -> None:
        self._key_id = key_id
        self._team_id = team_id
        self._private_key = private_key
        self._topic = topic
        self._now = now or (lambda: dt.datetime.now(tz=dt.UTC))
        # http2 is not optional: APNs speaks HTTP/2 and nothing else.
        self._client = client or httpx.AsyncClient(http2=True, timeout=10.0)
        self._owns_client = client is None
        self._token: str | None = None
        self._token_minted_at: dt.datetime | None = None

    # -- authentication --

    def provider_token(self) -> str:
        """A cached ES256 JWT signed with the `.p8` key.

        Apple rejects a token older than an hour and rate-limits minting, so this is reused
        until `PROVIDER_TOKEN_TTL` has passed rather than signed per notification.
        """
        now = self._now()
        if (
            self._token is not None
            and self._token_minted_at is not None
            and now - self._token_minted_at < PROVIDER_TOKEN_TTL
        ):
            return self._token

        self._token = jwt.encode(
            {"iss": self._team_id, "iat": int(now.timestamp())},
            self._private_key,
            algorithm="ES256",
            headers={"kid": self._key_id, "alg": "ES256"},
        )
        self._token_minted_at = now
        return self._token

    # -- request construction --

    def url_for(self, message: PushMessage) -> str:
        return f"{APNS_HOSTS[message.environment]}/3/device/{message.token}"

    def headers_for(self, message: PushMessage) -> dict[str, str]:
        headers = {
            "authorization": f"bearer {self.provider_token()}",
            "apns-topic": self._topic,
            # `alert` rather than `background`: this wakes a person, not the app.
            "apns-push-type": "alert",
            "apns-priority": "10",
            # Today's mission is worthless tomorrow. If Apple cannot deliver it within the
            # staleness window, it should be dropped rather than stored and delivered late.
            "apns-expiration": str(int((self._now() + dt.timedelta(hours=2)).timestamp())),
        }
        if message.collapse_id:
            headers["apns-collapse-id"] = message.collapse_id
        return headers

    @staticmethod
    def result_from(status: int, body: str) -> PushResult:
        """Map an APNs response onto a :class:`PushResult`.

        APNs answers `200` with an empty body on success, and everything else with a JSON
        object carrying a `reason`. A body that is not JSON is not a reason to crash the run,
        so the status alone still decides success.
        """
        if status == 200:
            return PushResult(ok=True, status=200)
        reason: str | None = None
        if body:
            try:
                parsed = json.loads(body)
            except ValueError:
                reason = body[:200]
            else:
                if isinstance(parsed, dict):
                    raw = parsed.get("reason")
                    reason = str(raw) if raw is not None else None
        return PushResult(ok=False, status=status, reason=reason)

    # -- the call --

    async def send(self, message: PushMessage) -> PushResult:
        try:
            headers = self.headers_for(message)
        except Exception as exc:
            # Signing the provider token failed, which in practice means `APNS_PRIVATE_KEY`
            # is not a readable PEM — the usual cause being a multi-line `.p8` that lost its
            # newlines on the way into a secret. `build_push_client` checks for this at
            # startup so it should be unreachable; it is caught anyway because the
            # alternative is an exception escaping mid-run, *after* the day has been claimed,
            # which costs that user their notification permanently rather than for one run.
            # Deliberately broad: cryptography and PyJWT raise several unrelated types here
            # and none of them should be able to take down a run.
            log.error("apns provider token could not be signed", extra={"error": str(exc)})
            return PushResult(ok=False, status=None, reason="bad_apns_key")

        try:
            response = await self._client.post(
                self.url_for(message), headers=headers, json=message.payload()
            )
        except httpx.HTTPError as exc:
            # A transport failure is retryable, and `send_with_retry` decides that from the
            # status. 503 is the honest stand-in: Apple was unreachable.
            log.warning("apns transport error", extra={"error": str(exc)})
            return PushResult(ok=False, status=503, reason="transport_error")
        return self.result_from(response.status_code, response.text)

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()


# --- Retry -------------------------------------------------------------------------------


async def send_with_retry(
    client: PushClient,
    message: PushMessage,
    *,
    attempts: int = RETRY_ATTEMPTS,
    sleep: Callable[[float], Awaitable[None]] | None = None,
) -> PushResult:
    """Send, retrying only what is worth retrying, a bounded number of times.

    Lives outside the client so it applies to every implementation and can be tested against
    a scripted stub without waiting on a real clock — `sleep` is injectable for exactly that.

    A failure that survives the last attempt is returned, logged by the caller, and dropped.
    It is never queued into tomorrow: tomorrow has its own mission, and a notification about
    a day that has ended is noise.
    """
    pause = sleep or asyncio.sleep
    result = await client.send(message)
    for index in range(1, attempts):
        if result.ok or not result.is_retryable:
            return result
        await pause(RETRY_BACKOFF_SECONDS[min(index - 1, len(RETRY_BACKOFF_SECONDS) - 1)])
        result = await client.send(message)
    return result


# --- Choosing one ------------------------------------------------------------------------


def build_push_client(settings: Settings) -> PushClient:
    """The one place the implementation is chosen.

    Unset credentials give :class:`UnconfiguredPushClient`, which fails loudly rather than
    silently. There is no configuration that yields a stub outside the test suite.
    """
    if not settings.apns_configured:
        log.warning(
            "APNS_KEY_ID / APNS_TEAM_ID / APNS_PRIVATE_KEY are not all set; "
            "no notification can be delivered. See docs/runbook-deploy.md."
        )
        return UnconfiguredPushClient()

    # Narrowed by `apns_configured`, which is `all(...)` over exactly these three.
    assert settings.apns_key_id and settings.apns_team_id and settings.apns_private_key
    client = ApnsClient(
        key_id=settings.apns_key_id,
        team_id=settings.apns_team_id,
        private_key=settings.apns_private_key,
        topic=settings.resolved_apns_topic,
    )

    # Sign one token now, before a single user is looked at, so an unreadable key is a loud
    # startup failure rather than a per-send one.
    #
    # This matters more than it looks. The send job claims a user's day *before* it pushes,
    # and commits that claim, so a key that only fails at send time means the user is marked
    # notified and never hears anything — today and, once the window goes stale, for good.
    # Failing here claims nobody, so fixing the secret and re-running still reaches everyone.
    #
    # The likely cause by far is a `.p8` whose newlines did not survive being pasted into a
    # secret; `docs/runbook-deploy.md` §4a has the check for that.
    try:
        client.provider_token()
    except Exception as exc:
        raise RuntimeError(
            "APNS_PRIVATE_KEY is set but could not be used to sign a provider token: "
            f"{exc}. It must be the full contents of the .p8, newlines and BEGIN/END lines "
            "intact. See docs/runbook-deploy.md section 4a."
        ) from exc
    return client
