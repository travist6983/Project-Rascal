"""`POST /v1/subscribe` — the marketing signup, and the gate that is its only protection.

**`test_an_unset_turnstile_key_refuses_rather_than_skipping` is the test that matters here.**
There is no rate limit on this route, by the owner's call of Aug 16, 2026, so Turnstile is the
whole of the defence. `roadmap-status.md` names skipping verification when the key is missing as
*the* defect to design against — it is the one that leaves the health check green while a public
write endpoint stands wide open.
"""

from __future__ import annotations

import json
import uuid

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from rascal.config import get_settings
from rascal.main import create_app
from rascal.services import marketing, subscribe_token, tokens, turnstile

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


async def _get(settings, path):
    """Same double override as `_post`, for the confirmation link a browser opens."""
    app = create_app(settings)
    app.dependency_overrides[get_settings] = lambda: settings
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        return await client.get(path, follow_redirects=False)


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


# --- Double opt-in, phase 88 -----------------------------------------------------------------
#
# **The bug these cover is a belief, not a line of code.** `services/marketing.py` documented
# Resend as running double opt-in; it does not. The first real signup, Aug 18 2026, landed as
# `Subscribed` with no confirmation mail anywhere, while the marketing page promised a link to
# click. Every test below asserts the half that was missing rather than the half that worked.


@pytest.mark.asyncio
async def test_a_new_contact_starts_unsubscribed_because_that_is_the_whole_gate(
    monkeypatch, stub_turnstile
) -> None:
    """**The single most important assertion in this file.**

    If this flips back to `False`, signups go live without confirming and nothing else in the
    suite notices — the route still answers `202` and the contact still appears at Resend.
    """
    sent: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        sent["payload"] = json.loads(request.content)
        return httpx.Response(201, json={"object": "contact", "id": "c-1"})

    _install(monkeypatch, handler)
    await marketing.add_contact("parent@example.com", _settings())

    assert sent["payload"]["unsubscribed"] is True


@pytest.mark.asyncio
async def test_confirming_flips_the_contact_and_addresses_it_by_email(monkeypatch) -> None:
    """Keyed by address, because holding a contact id would mean storing one."""
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["method"] = request.method
        seen["url"] = str(request.url)
        seen["payload"] = json.loads(request.content)
        return httpx.Response(200, json={"object": "contact", "id": "c-1"})

    _install(monkeypatch, handler)
    await marketing.confirm_contact("parent@example.com", _settings())

    assert seen["method"] == "PATCH"
    assert seen["url"].endswith("/audiences/aud-1/contacts/parent%40example.com")
    assert seen["payload"] == {"unsubscribed": False}


@pytest.mark.asyncio
async def test_a_confirmed_address_survives_the_round_trip() -> None:
    settings = _settings()
    token = subscribe_token.create("parent@example.com", settings)

    assert subscribe_token.read(token, settings) == "parent@example.com"


@pytest.mark.asyncio
async def test_a_token_signed_with_another_secret_is_refused() -> None:
    """The signature is the only thing standing between a link and a forged subscription."""
    forged = subscribe_token.create("victim@example.com", _settings(jwt_secret="not-ours"))

    with pytest.raises(subscribe_token.ConfirmTokenInvalid):
        subscribe_token.read(forged, _settings())


@pytest.mark.asyncio
async def test_an_access_token_cannot_open_a_confirmation_link() -> None:
    """Same secret, different purpose. **The `typ` claim is what keeps them apart** — without
    it, one key's signatures are interchangeable across every use the service has for them."""
    settings = _settings()
    access, _ = tokens.create_access_token(uuid.uuid4(), settings)

    with pytest.raises(subscribe_token.ConfirmTokenInvalid):
        subscribe_token.read(access, settings)


@pytest.mark.asyncio
async def test_an_expired_link_is_refused_like_any_other_bad_one() -> None:
    """Expiry and forgery give the same answer, so neither says whether a link ever existed."""
    settings = _settings(subscribe_confirm_ttl_days=-1)
    stale = subscribe_token.create("parent@example.com", settings)

    with pytest.raises(subscribe_token.ConfirmTokenInvalid):
        subscribe_token.read(stale, _settings())


@pytest.mark.asyncio
async def test_a_good_click_confirms_and_redirects_to_the_site(monkeypatch) -> None:
    confirmed: list[str] = []

    async def _confirm(email, settings):
        confirmed.append(email)

    monkeypatch.setattr(marketing, "confirm_contact", _confirm)
    settings = _settings()
    token = subscribe_token.create("parent@example.com", settings)

    response = await _get(settings, f"/v1/subscribe/confirm?token={token}")

    assert response.status_code == 303
    assert response.headers["location"] == "https://getvellumapp.com/?confirmed=1"
    assert confirmed == ["parent@example.com"]


@pytest.mark.asyncio
async def test_a_bad_link_redirects_rather_than_showing_a_browser_json(monkeypatch) -> None:
    """**A person opening this has clicked a link in their mail client.** Handing them
    `{"error": ...}` shows an API response to somebody who does not know they are talking to
    one, so every outcome here is a redirect."""
    called: list[str] = []

    async def _confirm(email, settings):
        called.append(email)

    monkeypatch.setattr(marketing, "confirm_contact", _confirm)

    response = await _get(_settings(), "/v1/subscribe/confirm?token=not-a-token")

    assert response.status_code == 303
    assert response.headers["location"] == "https://getvellumapp.com/?confirmed=0"
    assert called == [], "a bad token must never reach the list"


@pytest.mark.asyncio
async def test_a_missing_token_redirects_instead_of_showing_fastapis_422(monkeypatch) -> None:
    """**A required query parameter answers `422 application/json` before the handler runs** —
    the raw-JSON page this route exists to avoid. Reachable: link scanners and some mail clients
    truncate at the `?`, as does a half-copied paste. Found against the deployed endpoint."""
    called: list[str] = []

    async def _confirm(email, settings):
        called.append(email)

    monkeypatch.setattr(marketing, "confirm_contact", _confirm)

    response = await _get(_settings(), "/v1/subscribe/confirm")

    assert response.status_code == 303, "a missing token must not reach FastAPI's validator"
    assert response.headers["location"] == "https://getvellumapp.com/?confirmed=0"
    assert called == []


@pytest.mark.asyncio
async def test_resend_being_down_is_told_apart_from_a_bad_link(monkeypatch) -> None:
    """The link is still good; ours is the thing that broke. A retry is worth offering."""

    async def _confirm(email, settings):
        raise marketing.MarketingUnavailable("nope")

    monkeypatch.setattr(marketing, "confirm_contact", _confirm)
    settings = _settings()
    token = subscribe_token.create("parent@example.com", settings)

    response = await _get(settings, f"/v1/subscribe/confirm?token={token}")

    assert response.headers["location"] == "https://getvellumapp.com/?confirmed=retry"


# --- helpers -----------------------------------------------------------------------------


def _install(monkeypatch, handler) -> None:
    """Point Turnstile's `httpx.AsyncClient` at a mock transport."""
    original = httpx.AsyncClient

    def _factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        return original(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", _factory)
