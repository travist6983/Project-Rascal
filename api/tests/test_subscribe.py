"""`POST /v1/subscribe` — the marketing signup, and the gate that is its only protection.

**`test_an_unset_turnstile_key_refuses_rather_than_skipping` is the test that matters here.**
There is no rate limit on this route, by the owner's call of Aug 16, 2026, so Turnstile is the
whole of the defence. `roadmap-status.md` names skipping verification when the key is missing as
*the* defect to design against — it is the one that leaves the health check green while a public
write endpoint stands wide open.
"""

from __future__ import annotations

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from rascal.config import get_settings
from rascal.main import create_app
from rascal.services import marketing, turnstile

BODY = {"email": "parent@example.com", "turnstile_token": "tok", "source": "home"}


def _settings(**overrides):
    return get_settings().model_copy(
        update={
            "turnstile_secret_key": "secret",
            "mail_api_key": "resend-key",
            "resend_audience_id": "aud-1",
            **overrides,
        }
    )


@pytest.fixture
def stub_turnstile(monkeypatch):
    """Turnstile says yes, so a test about the list is not also a test about Cloudflare."""
    seen: dict = {}

    async def _verify(token, settings, *, remote_ip=None):
        seen["token"] = token
        seen["remote_ip"] = remote_ip

    monkeypatch.setattr(turnstile, "verify", _verify)
    return seen


@pytest.fixture
def stub_contacts(monkeypatch):
    added: list[str] = []

    async def _add(email, settings):
        added.append(email)

    monkeypatch.setattr(marketing, "add_contact", _add)
    return added


async def _post(settings, body=BODY, headers=None):
    """Build the app *and* override `get_settings`.

    Both are needed and they do different jobs: `create_app(settings)` decides the CORS
    allowlist, which is read once at construction, while the route reads its settings through
    `SettingsDep` — a `Depends(get_settings)` that ignores whatever the app was built with.
    Overriding only one of them tests half of what the call does.
    """
    app = create_app(settings)
    app.dependency_overrides[get_settings] = lambda: settings
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        return await client.post("/v1/subscribe", json=body, headers=headers or {})


# --- The gate ------------------------------------------------------------------------------


async def test_an_unset_turnstile_key_refuses_rather_than_skipping(stub_contacts) -> None:
    """**The defect this phase was written to design against.**

    A missing key must not mean "skip the check". It answers `503`, which is visible, rather
    than accepting the submission, which is not.
    """
    response = await _post(_settings(turnstile_secret_key=None))

    assert response.status_code == 503
    # And nothing reached the list.
    assert stub_contacts == []


async def test_a_missing_token_is_rejected(stub_contacts) -> None:
    """Absent is a rejection, never a skip. A form that omits the field is not a pass."""
    body = {"email": "parent@example.com"}
    response = await _post(_settings(), body=body)

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "turnstile_token"
    assert stub_contacts == []


async def test_a_rejected_token_never_reaches_the_list(monkeypatch, stub_contacts) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"success": False, "error-codes": ["invalid-input-response"]}
        )

    _install(monkeypatch, handler)
    response = await _post(_settings())

    assert response.status_code == 422
    assert stub_contacts == []


async def test_cloudflare_being_unreachable_is_not_a_pass(monkeypatch, stub_contacts) -> None:
    """Failing open here would mean an outage at their end silently opens ours."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("dropped")

    _install(monkeypatch, handler)
    response = await _post(_settings())

    assert response.status_code == 503
    assert stub_contacts == []


async def test_our_own_bad_secret_is_not_reported_as_the_callers_mistake(
    monkeypatch, stub_contacts
) -> None:
    """`invalid-input-secret` is an operator problem wearing a caller's status code."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"success": False, "error-codes": ["invalid-input-secret"]})

    _install(monkeypatch, handler)
    response = await _post(_settings())

    assert response.status_code == 503
    assert stub_contacts == []


# --- The forward ---------------------------------------------------------------------------


async def test_a_good_signup_is_accepted_and_forwarded(stub_turnstile, stub_contacts) -> None:
    response = await _post(_settings())

    assert response.status_code == 202
    assert response.json() == {"status": "ok"}
    assert stub_contacts == ["parent@example.com"]


async def test_the_address_is_normalised_before_it_leaves(stub_turnstile, stub_contacts) -> None:
    """Two contacts differing only in case would be two contacts."""
    await _post(_settings(), body={**BODY, "email": "  Parent@Example.COM "})

    assert stub_contacts == ["parent@example.com"]


async def test_a_malformed_address_is_refused_before_the_gate(stub_contacts) -> None:
    response = await _post(_settings(), body={**BODY, "email": "not-an-address"})

    assert response.status_code == 422
    assert stub_contacts == []


async def test_nothing_is_stored_in_this_database(stub_turnstile, stub_contacts) -> None:
    """**There is no `subscribers` table**, per open item 12(4) — the list is Resend's.

    A grep rather than a comment, so it stays true: the day somebody adds one, this fails and
    they have to argue with the decision rather than around it.
    """
    from rascal.models import Base

    assert "subscribers" not in Base.metadata.tables


async def test_the_list_being_unconfigured_is_not_a_silent_success(stub_turnstile) -> None:
    """Accepting an address we cannot store would make the page look like it worked."""
    response = await _post(_settings(resend_audience_id=None))

    assert response.status_code == 503


# --- The browser -----------------------------------------------------------------------------


async def test_an_allowed_origin_gets_cors_headers(stub_turnstile, stub_contacts) -> None:
    response = await _post(_settings(), headers={"Origin": "https://travist6983.github.io"})

    assert response.headers.get("access-control-allow-origin") == "https://travist6983.github.io"


async def test_a_disallowed_origin_gets_no_cors_headers(stub_turnstile, stub_contacts) -> None:
    """The request still runs — CORS is enforced by the browser, not the server — but without
    the header, the browser refuses to hand the response to the page."""
    response = await _post(_settings(), headers={"Origin": "https://evil.example.com"})

    assert "access-control-allow-origin" not in response.headers


async def test_the_allowlist_is_never_a_wildcard() -> None:
    """A half-filled `.env` must not become an API any page on the internet may call."""
    settings = _settings()

    assert "*" not in settings.marketing_origins
    assert all(origin.startswith("https://") for origin in settings.marketing_origins)


# --- helpers ---------------------------------------------------------------------------------


def _install(monkeypatch, handler) -> None:
    """Point Turnstile's `httpx.AsyncClient` at a mock transport."""
    original = httpx.AsyncClient

    def _factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        return original(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", _factory)
