"""The mailer (phase 56).

**The load-bearing test here is `test_the_console_provider_never_opens_a_socket`.** `console`
being the default is a safety property rather than a convenience: the addresses this will
eventually carry belong to parents, and the messages are about deleting their child's archive.
A local run that could reach a real SMTP relay is a mistake worth making impossible rather than
merely unlikely, so that test replaces the HTTP transport with one that fails on contact.

Everything else is the retry policy, which is the other thing worth pinning: one retry, never
on a 4xx.
"""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from rascal.config import get_settings
from rascal.services import mail
from rascal.services.mail import ConsoleProvider, MailDeliveryError, PostmarkProvider, send


def _settings(**overrides):
    return get_settings().model_copy(update=overrides)


def _transport(handler) -> httpx.MockTransport:
    return httpx.MockTransport(handler)


@pytest.fixture
def postmark_settings():
    return _settings(mail_provider="postmark", mail_api_key="test-token")


# --- The console provider -------------------------------------------------------------------


async def test_the_console_provider_returns_an_id_and_prints_the_whole_message(capsys) -> None:
    message_id = await send(
        _settings(), to="parent@rascal.local", subject="Your link", text="Tap this to sign in."
    )

    assert message_id.startswith("console-")
    printed = capsys.readouterr().out
    # The whole body, not a summary — the thing worth checking locally is the copy.
    assert "Tap this to sign in." in printed
    assert "parent@rascal.local" in printed
    assert "nothing was sent" in printed


async def test_the_console_provider_never_opens_a_socket(monkeypatch) -> None:
    """**A local run must not be able to send real mail.**

    Any attempt to construct an HTTP client here fails the test loudly, which is stronger than
    asserting on what was printed: it catches a future provider that reaches for the network
    while still writing something plausible to stdout.
    """

    def _explode(*args, **kwargs):
        raise AssertionError("the console provider must never open a connection")

    monkeypatch.setattr(httpx, "AsyncClient", _explode)

    message_id = await send(_settings(), to="parent@rascal.local", subject="s", text="t")
    assert message_id.startswith("console-")


async def test_console_is_the_default(monkeypatch) -> None:
    """Nothing has to be configured for a local run to be safe."""
    monkeypatch.delenv("MAIL_PROVIDER", raising=False)
    assert get_settings().mail_provider == "console"
    assert isinstance(mail.provider_for(get_settings()), ConsoleProvider)


async def test_an_html_alternative_is_carried(capsys) -> None:
    await send(_settings(), to="p@rascal.local", subject="s", text="plain", html="<p>rich</p>")
    printed = capsys.readouterr().out
    assert "plain" in printed
    assert "<p>rich</p>" in printed


# --- What `send` refuses --------------------------------------------------------------------


@pytest.mark.parametrize("recipient", ["", "not-an-address", "  "])
async def test_a_missing_or_malformed_recipient_raises(recipient: str) -> None:
    with pytest.raises(MailDeliveryError):
        await send(_settings(), to=recipient, subject="s", text="t")


async def test_failure_raises_rather_than_returning(postmark_settings, monkeypatch) -> None:
    """A caller must not be able to ignore a failed send by forgetting to check a return."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(422, json={"Message": "no"})

    _install(monkeypatch, handler)
    with pytest.raises(MailDeliveryError):
        await send(postmark_settings, to="p@example.com", subject="s", text="t")


async def test_postmark_without_a_key_says_which_setting_is_missing(monkeypatch) -> None:
    settings = _settings(mail_provider="postmark", mail_api_key=None)
    with pytest.raises(MailDeliveryError) as raised:
        await send(settings, to="p@example.com", subject="s", text="t")
    assert "MAIL_API_KEY" in str(raised.value)


# --- The retry policy -----------------------------------------------------------------------


def _install(monkeypatch, handler) -> None:
    """Point the provider's `httpx.AsyncClient` at a mock transport."""
    original = httpx.AsyncClient

    def _factory(*args, **kwargs):
        kwargs["transport"] = _transport(handler)
        return original(*args, **kwargs)

    monkeypatch.setattr(mail.httpx, "AsyncClient", _factory)


async def test_a_successful_send_returns_the_providers_id(postmark_settings, monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"MessageID": "pm-123"})

    _install(monkeypatch, handler)
    assert await send(postmark_settings, to="p@example.com", subject="s", text="t") == "pm-123"


async def test_a_5xx_is_retried_exactly_once_and_can_succeed(
    postmark_settings, monkeypatch
) -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(503, json={})
        return httpx.Response(200, json={"MessageID": "pm-after-retry"})

    _install(monkeypatch, handler)
    assert (
        await send(postmark_settings, to="p@example.com", subject="s", text="t") == "pm-after-retry"
    )
    assert calls == 2


async def test_a_second_5xx_gives_up(postmark_settings, monkeypatch) -> None:
    """One retry, not a ladder. A handler holding a connection through three sleeps is worse
    than a caller that learns quickly that the send failed."""
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(500, json={})

    _install(monkeypatch, handler)
    with pytest.raises(MailDeliveryError):
        await send(postmark_settings, to="p@example.com", subject="s", text="t")
    assert calls == 2, "exactly one retry"


async def test_a_4xx_is_never_retried(postmark_settings, monkeypatch) -> None:
    """The message is malformed. Sending it again produces the same answer more slowly."""
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(422, json={"Message": "bad address"})

    _install(monkeypatch, handler)
    with pytest.raises(MailDeliveryError):
        await send(postmark_settings, to="p@example.com", subject="s", text="t")
    assert calls == 1


async def test_a_transport_error_is_retried_once(postmark_settings, monkeypatch) -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        raise httpx.ConnectError("dropped")

    _install(monkeypatch, handler)
    with pytest.raises(MailDeliveryError):
        await send(postmark_settings, to="p@example.com", subject="s", text="t")
    assert calls == 2


async def test_the_from_and_reply_to_settings_reach_the_provider(monkeypatch) -> None:
    settings = _settings(
        mail_provider="postmark",
        mail_api_key="k",
        mail_from="Dogear <hello@dogear.test>",
        mail_reply_to="replies@dogear.test",
    )
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        seen.update(json.loads(request.content))
        return httpx.Response(200, json={"MessageID": "pm-1"})

    _install(monkeypatch, handler)
    await send(settings, to="p@example.com", subject="s", text="t")

    assert seen["From"] == "Dogear <hello@dogear.test>"
    assert seen["ReplyTo"] == "replies@dogear.test"


# --- What this file must not know about -----------------------------------------------------


def test_the_mailer_knows_nothing_about_its_callers() -> None:
    """**The reason this was its own phase.** Two unbuilt features need a mailer, and building
    it inside either one would have shaped it around that one — so the second consumer would
    find a lifecycle-notice sender rather than a mailer.

    A grep rather than a comment, so it stays true.
    """
    source = Path(mail.__file__).read_text()
    body = source.split('"""', 2)[-1]  # everything after the module docstring
    for forbidden in (
        "marketing_consent",
        "transactional_consent",
        "email_deliverable",
        "credential",
        "unsubscribe",
        "suppression",
    ):
        assert forbidden not in body, f"mail.py must not know about {forbidden}"


def test_the_provider_registry_covers_every_configured_value() -> None:
    """A `MAIL_PROVIDER` the registry does not hold would be a KeyError at the first send."""
    from typing import get_args

    from rascal.config import Settings

    configured = set(get_args(Settings.model_fields["mail_provider"].annotation))
    assert configured == set(mail._PROVIDERS)
    assert isinstance(mail._PROVIDERS["postmark"], PostmarkProvider)
