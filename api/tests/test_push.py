"""The APNs seam.

**No real APNs call has ever been made from this repository**, and none is made here. The
key comes from the same Apple Developer enrollment as Sign in with Apple, which is still
open — see `docs/blocked.md` §1.

What these tests do cover is everything about `ApnsClient` that does not need a socket: the
provider token's header and claims, the host chosen per environment, the request headers,
the mapping from an APNs response onto a `PushResult`, and the retry policy. What they
cannot cover is that Apple accepts any of it.
"""

from __future__ import annotations

import datetime as dt
import uuid

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from rascal.config import Settings, get_settings
from rascal.services.push import (
    ApnsClient,
    PushMessage,
    PushResult,
    StubPushClient,
    UnconfiguredPushClient,
    build_push_client,
    send_with_retry,
)

ASSIGNMENT = uuid.UUID("11111111-2222-3333-4444-555555555555")


@pytest.fixture(scope="module")
def private_key() -> str:
    """A local P-256 key, standing in for the `.p8` Apple would issue. Never leaves this test."""
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


def _client(private_key: str, **kwargs) -> ApnsClient:
    return ApnsClient(
        key_id="KEY123456",
        team_id="TEAM123456",
        private_key=private_key,
        topic="com.travisterry.childarchive",
        **kwargs,
    )


def _message(environment: str = "production") -> PushMessage:
    return PushMessage(
        token="a1b2c3",
        environment=environment,  # type: ignore[arg-type]
        body="Get on the floor for ten minutes.",
        assignment_id=ASSIGNMENT,
        title="Miles",
        collapse_id="rascal-2026-08-14",
    )


# --- The payload -------------------------------------------------------------------------


def test_the_payload_is_the_body_the_name_and_an_id_and_nothing_else() -> None:
    """The type is the enforcement: there is no field on a PushMessage that could hold an
    entry, a transcript, a media key, or a count of anything."""
    payload = _message().payload()

    assert payload == {
        "aps": {
            "alert": {
                "body": "Get on the floor for ten minutes.",
                "title": "Miles",
            },
            "sound": "default",
        },
        "assignment_id": str(ASSIGNMENT),
    }


def test_a_message_with_no_title_carries_only_a_body() -> None:
    message = PushMessage(
        token="t", environment="production", body="Do the thing.", assignment_id=ASSIGNMENT
    )

    assert message.payload()["aps"]["alert"] == {"body": "Do the thing."}


# --- The provider token ------------------------------------------------------------------


def test_the_provider_token_is_es256_and_carries_the_key_id(private_key: str) -> None:
    token = _client(private_key).provider_token()

    header = jwt.get_unverified_header(token)
    assert header["alg"] == "ES256"
    assert header["kid"] == "KEY123456"
    claims = jwt.decode(token, options={"verify_signature": False})
    assert claims["iss"] == "TEAM123456"
    assert "iat" in claims


def test_the_provider_token_is_reused_until_it_is_nearly_expired(private_key: str) -> None:
    """Apple rejects a token older than an hour and rate-limits minting them."""
    now = dt.datetime(2026, 8, 14, 12, 0, tzinfo=dt.UTC)
    clock = {"now": now}
    client = _client(private_key, now=lambda: clock["now"])

    first = client.provider_token()
    clock["now"] = now + dt.timedelta(minutes=10)
    assert client.provider_token() == first

    clock["now"] = now + dt.timedelta(minutes=50)
    assert client.provider_token() != first


# --- Host and headers --------------------------------------------------------------------


def test_sandbox_and_production_address_different_hosts(private_key: str) -> None:
    """Getting this wrong fails silently, which is why it is a test and not a comment."""
    client = _client(private_key)

    assert client.url_for(_message("production")).startswith("https://api.push.apple.com/")
    assert client.url_for(_message("sandbox")).startswith("https://api.sandbox.push.apple.com/")
    assert client.url_for(_message()).endswith("/3/device/a1b2c3")


def test_the_headers_name_the_topic_and_collapse_the_day(private_key: str) -> None:
    headers = _client(private_key).headers_for(_message())

    assert headers["apns-topic"] == "com.travisterry.childarchive"
    # `alert`, not `background`: this wakes a person.
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
    assert headers["apns-collapse-id"] == "rascal-2026-08-14"
    assert headers["authorization"].startswith("bearer ")


def test_a_message_with_no_collapse_id_sends_no_collapse_header(private_key: str) -> None:
    message = PushMessage(token="t", environment="production", body="x", assignment_id=ASSIGNMENT)

    assert "apns-collapse-id" not in _client(private_key).headers_for(message)


def test_the_notification_expires_rather_than_being_stored_and_delivered_late(
    private_key: str,
) -> None:
    """Today's mission is worthless tomorrow. Apple should drop it, not hold it."""
    now = dt.datetime(2026, 8, 14, 19, 0, tzinfo=dt.UTC)
    headers = _client(private_key, now=lambda: now).headers_for(_message())

    expiry = int(headers["apns-expiration"])
    assert expiry == int((now + dt.timedelta(hours=2)).timestamp())


# --- Reading Apple's answer --------------------------------------------------------------


def test_a_200_is_success() -> None:
    result = ApnsClient.result_from(200, "")

    assert result.ok
    assert not result.token_is_dead


def test_a_410_marks_the_token_dead() -> None:
    result = ApnsClient.result_from(410, '{"reason": "Unregistered"}')

    assert not result.ok
    assert result.reason == "Unregistered"
    assert result.token_is_dead


def test_bad_device_token_marks_the_token_dead_despite_the_400() -> None:
    result = ApnsClient.result_from(400, '{"reason": "BadDeviceToken"}')

    assert result.token_is_dead


def test_an_ordinary_rejection_does_not_kill_the_token() -> None:
    result = ApnsClient.result_from(403, '{"reason": "ExpiredProviderToken"}')

    assert not result.ok
    assert not result.token_is_dead


def test_a_body_that_is_not_json_still_yields_a_result() -> None:
    """A gateway between us and Apple returning HTML is not a reason to crash the run."""
    result = ApnsClient.result_from(502, "<html>bad gateway</html>")

    assert not result.ok
    assert result.status == 502
    assert result.is_retryable


# --- Retry -------------------------------------------------------------------------------


class _Scripted:
    """Returns each scripted result in turn, then repeats the last one."""

    def __init__(self, *results: PushResult) -> None:
        self.results = list(results)
        self.calls = 0
        self.slept: list[float] = []

    async def send(self, message: PushMessage) -> PushResult:
        result = self.results[min(self.calls, len(self.results) - 1)]
        self.calls += 1
        return result

    async def aclose(self) -> None:
        return None


async def test_a_transient_failure_is_retried_and_can_succeed() -> None:
    client = _Scripted(PushResult(ok=False, status=503), PushResult(ok=True, status=200))
    slept: list[float] = []

    result = await send_with_retry(client, _message(), sleep=lambda s: _record(slept, s))

    assert result.ok
    assert client.calls == 2
    assert slept == [0.5]


async def test_retries_are_bounded() -> None:
    """A notification that has not gone out in a few seconds has missed the moment it was
    for. The staleness rule, not a longer retry, covers a window we could not serve."""
    client = _Scripted(PushResult(ok=False, status=503))
    slept: list[float] = []

    result = await send_with_retry(client, _message(), sleep=lambda s: _record(slept, s))

    assert not result.ok
    assert client.calls == 3
    assert slept == [0.5, 1.0]


async def test_a_permanent_failure_is_not_retried() -> None:
    """Repeating a request Apple has already judged changes nothing."""
    client = _Scripted(PushResult(ok=False, status=410, reason="Unregistered"))

    result = await send_with_retry(client, _message(), sleep=lambda s: _record([], s))

    assert client.calls == 1
    assert result.token_is_dead


async def _record(sink: list[float], seconds: float) -> None:
    sink.append(seconds)


# --- Choosing a client -------------------------------------------------------------------


def _settings(**overrides) -> Settings:
    base = get_settings().model_dump()
    base.update(overrides)
    return Settings(**base)


def test_no_credentials_gives_a_client_that_fails_loudly_rather_than_silently() -> None:
    """A push service that silently no-ops is indistinguishable from one that works, until
    somebody notices their phone has been quiet for a month."""
    client = build_push_client(_settings())

    assert isinstance(client, UnconfiguredPushClient)


async def test_the_unconfigured_client_reports_why_it_sent_nothing() -> None:
    result = await UnconfiguredPushClient().send(_message())

    assert not result.ok
    assert result.reason == "apns_not_configured"
    # Not a dead token: the phone is fine, the deployment is not configured.
    assert not result.token_is_dead


def test_a_partial_credential_set_is_treated_as_unconfigured() -> None:
    """All three or none. "Nearly working" hides which piece is missing."""
    client = build_push_client(_settings(apns_key_id="KEY123456", apns_team_id="TEAM123456"))

    assert isinstance(client, UnconfiguredPushClient)


def test_a_full_credential_set_builds_the_real_client(private_key: str) -> None:
    client = build_push_client(
        _settings(
            apns_key_id="KEY123456",
            apns_team_id="TEAM123456",
            apns_private_key=private_key,
        )
    )

    assert isinstance(client, ApnsClient)


def test_the_topic_defaults_to_the_bundle_id() -> None:
    """The APNs topic *is* the bundle id. A second place to set it is a second place to get
    it wrong, and the failure is every token rejected with `DeviceTokenNotForTopic`."""
    settings = _settings(apple_bundle_id="com.travisterry.childarchive")

    assert settings.resolved_apns_topic == "com.travisterry.childarchive"
    assert _settings(apns_topic="com.example.other").resolved_apns_topic == "com.example.other"


# --- The stub ----------------------------------------------------------------------------


async def test_the_stub_records_what_it_was_asked_to_send() -> None:
    stub = StubPushClient()

    result = await stub.send(_message())

    assert result.ok
    assert [message.token for message in stub.sent] == ["a1b2c3"]


# --- A key that cannot be read ----------------------------------------------------------------


BAD_KEY = "-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----"


def test_an_unreadable_private_key_fails_at_build_time_not_at_send_time() -> None:
    """The most likely first-deploy mistake, caught before anyone is claimed.

    A `.p8` pasted into a secret without its newlines is unreadable. If that only surfaced on
    the first `send`, the job would already have claimed and committed the user's day — so
    they would be recorded as notified, hear nothing, and be skipped tomorrow as "already
    sent". Failing here claims nobody, so fixing the secret and re-running still reaches
    everyone whose window has not gone stale.
    """
    with pytest.raises(RuntimeError) as caught:
        build_push_client(
            _settings(
                apns_key_id="KEY123456",
                apns_team_id="TEAM123456",
                apns_private_key=BAD_KEY,
            )
        )
    message = str(caught.value)
    assert "APNS_PRIVATE_KEY" in message
    assert "runbook-deploy.md" in message


async def test_a_key_that_fails_at_send_time_is_a_result_not_an_exception() -> None:
    """Defence in depth behind the build-time check.

    Nothing may escape `send` as an exception: the run is mid-flight by then, days have been
    claimed, and an unhandled error costs every remaining user their notification too.
    """
    client = ApnsClient(key_id="KEY123456", team_id="TEAM123456", private_key=BAD_KEY, topic="t")
    result = await client.send(
        PushMessage(
            token="a" * 64,
            environment="sandbox",
            body="Get on the floor for ten minutes.",
            assignment_id=uuid.uuid4(),
        )
    )
    assert result.ok is False
    assert result.reason == "bad_apns_key"
    # Not retryable: signing will fail identically three times in a row.
    assert result.is_retryable is False
