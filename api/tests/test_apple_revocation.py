"""Sign in with Apple revocation: the client secret, the exchange, and the call itself.

**Nothing here has ever run against Apple.** No Sign in with Apple key exists yet —
`docs/blocked.md` §24 is the errand — so every assertion below is against a local `MockTransport`
standing in for `appleid.apple.com`. What these tests prove is that the right request is built
and that no failure mode of it can take down a sign-in or stop an erasure. What they cannot
prove is that Apple accepts it. That is a device check, and it stays in the runbook.

**The failure tests are the point.** A revocation that works is one line; a revocation that fails
without abandoning the person who asked to be deleted is the whole feature.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

import httpx
import jwt
import pytest
import sqlalchemy as sa
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import apple_token
from factories import make_user
from rascal.config import Settings, get_settings
from rascal.models import Credential
from rascal.services import apple_revocation

CLIENT_ID = "com.travisterry.childarchive"


@pytest.fixture(scope="module")
def siwa_key() -> str:
    """A local P-256 key standing in for the `.p8`. Never leaves this test run."""
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


def _settings(siwa_key: str | None, **overrides) -> Settings:
    """Real settings with the Sign in with Apple trio filled in, or deliberately not."""
    base = get_settings().model_dump()
    base.update(
        apple_siwa_key_id="SIWAKEY123" if siwa_key else None,
        apple_siwa_private_key=siwa_key,
        apple_siwa_client_id=CLIENT_ID,
    )
    base.update(overrides)
    return Settings(**base)


class _Apple:
    """A local `appleid.apple.com`. Records every request so the tests can read them back."""

    def __init__(self, *, token_status=200, token_body=None, revoke_status=200):
        self.requests: list[httpx.Request] = []
        self.forms: list[dict[str, str]] = []
        self._token_status = token_status
        self._token_body = token_body if token_body is not None else {"refresh_token": "r3fresh"}
        self._revoke_status = revoke_status

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self._handle))

    async def _handle_async(self, url: str, form: dict) -> httpx.Response:
        """The `_post` seam, for tests that patch the whole function rather than inject a
        client — the route builds its own client and there is nowhere to hand one in."""
        self.forms.append({k: v for k, v in form.items() if v is not None})
        if url.endswith("/revoke"):
            return httpx.Response(self._revoke_status, json={})
        return httpx.Response(self._token_status, json=self._token_body)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        body = request.content.decode()
        self.forms.append(dict(pair.split("=", 1) for pair in body.split("&") if "=" in pair))
        if request.url.path.endswith("/revoke"):
            return httpx.Response(self._revoke_status, json={})
        return httpx.Response(self._token_status, json=self._token_body)


# --- The client secret ------------------------------------------------------------------------


def test_the_client_secret_is_what_apple_asks_for(siwa_key):
    """`sub` is the client id and `iss` is the team — the one pair that is easy to swap."""
    settings = _settings(siwa_key)

    secret = apple_revocation.client_secret(settings)

    claims = jwt.decode(secret, options={"verify_signature": False})
    assert claims["iss"] == settings.apple_team_id
    assert claims["sub"] == CLIENT_ID
    assert claims["aud"] == "https://appleid.apple.com"
    assert claims["exp"] > claims["iat"]
    header = jwt.get_unverified_header(secret)
    assert header["alg"] == "ES256"
    assert header["kid"] == "SIWAKEY123"


def test_the_client_secret_expires_within_apples_ceiling(siwa_key):
    """Apple refuses a secret good for more than six months. This one is good for minutes."""
    settings = _settings(siwa_key)
    # Firmly in the past, like `SIGNED_AT` in `test_app_store.py`: the assertion is arithmetic
    # on two claims in one token, so the clock it is anchored to only has to be fixed.
    now = dt.datetime(2026, 6, 1, 12, 0, tzinfo=dt.UTC)

    claims = jwt.decode(
        apple_revocation.client_secret(settings, now=now),
        options={"verify_signature": False},
    )

    assert claims["exp"] - claims["iat"] == int(apple_revocation.CLIENT_SECRET_TTL.total_seconds())
    assert claims["exp"] - claims["iat"] < 60 * 60 * 24 * 180


# --- Capturing the token at sign-in -------------------------------------------------------------


async def test_the_authorization_code_becomes_a_stored_refresh_token(
    session: AsyncSession, siwa_key
):
    user = await make_user(session)
    credential = Credential(user_id=user.id, provider="apple", subject_id="001.stored")
    session.add(credential)
    await session.flush()
    apple = _Apple()

    stored = await apple_revocation.capture_refresh_token(
        session, "001.stored", "the-code", _settings(siwa_key), client=apple.client()
    )

    assert stored is True
    assert credential.apple_refresh_token == "r3fresh"
    assert apple.forms[0]["grant_type"] == "authorization_code"
    assert apple.forms[0]["code"] == "the-code"


async def test_a_second_sign_in_replaces_the_token_rather_than_keeping_the_first(
    session: AsyncSession, siwa_key
):
    """Apple invalidates the old one when it issues a new one, so keeping it would mean
    holding a string that revokes nothing."""
    user = await make_user(session)
    credential = Credential(
        user_id=user.id, provider="apple", subject_id="001.again", apple_refresh_token="stale"
    )
    session.add(credential)
    await session.flush()

    await apple_revocation.capture_refresh_token(
        session, "001.again", "code", _settings(siwa_key), client=_Apple().client()
    )

    assert credential.apple_refresh_token == "r3fresh"


# **Built inside each test, never in the decorator.** A `_Apple` constructed in a `parametrize`
# list is created once at collection and shared by every run of that parameter, so it
# accumulates requests across reruns and across `-k` selections — a fixture that remembers is a
# test that passes for the wrong reason the second time.
@pytest.mark.parametrize(
    ("label", "code", "kwargs", "configured"),
    [
        ("no code from an older client", None, {}, True),
        ("apple refuses the code", "code", {"token_status": 400}, True),
        ("apple is down", "code", {"token_status": 503}, True),
        ("apple sends no refresh token", "code", {"token_body": {"access_token": "a"}}, True),
        ("no key is configured", "code", {}, False),
    ],
)
async def test_a_failed_exchange_stores_nothing_and_never_raises(
    session: AsyncSession, siwa_key, label, code, kwargs, configured
):
    """Every way the exchange can fail, and none of them raises or writes a partial value.

    **This tests `capture_refresh_token` and nothing else** — it does not go near the sign-in
    route, and it used to be named as though it did. The claim that a failed exchange leaves
    the sign-in working is made by `test_a_sign_in_survives_apple_refusing_the_code` below,
    which actually drives `POST /v1/auth/apple`."""
    apple = _Apple(**kwargs)
    user = await make_user(session)
    credential = Credential(
        user_id=user.id, provider="apple", subject_id=f"001.{uuid.uuid4().hex[:8]}"
    )
    session.add(credential)
    await session.flush()

    stored = await apple_revocation.capture_refresh_token(
        session,
        credential.subject_id,
        code,
        _settings(siwa_key if configured else None),
        client=apple.client(),
    )

    assert stored is False, label
    assert credential.apple_refresh_token is None, label


async def test_an_unreachable_apple_is_not_an_exception(session: AsyncSession, siwa_key):
    """`httpx.ConnectError` on the sign-in path would be a 500 on a route that works."""
    user = await make_user(session)
    session.add(Credential(user_id=user.id, provider="apple", subject_id="001.offline"))
    await session.flush()

    def _refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to apple", request=request)

    stored = await apple_revocation.capture_refresh_token(
        session,
        "001.offline",
        "code",
        _settings(siwa_key),
        client=httpx.AsyncClient(transport=httpx.MockTransport(_refuse)),
    )

    assert stored is False


# --- Revoking ------------------------------------------------------------------------------------


async def test_revoking_sends_the_token_apple_asks_for(siwa_key):
    apple = _Apple()

    assert await apple_revocation.revoke("r3fresh", _settings(siwa_key), client=apple.client())

    form = apple.forms[0]
    assert form["token"] == "r3fresh"
    assert form["token_type_hint"] == "refresh_token"
    assert form["client_id"] == CLIENT_ID
    assert apple.requests[0].url.path.endswith("/revoke")


async def test_the_token_never_travels_in_a_url(siwa_key):
    """`instagram.py` learned this the expensive way: httpx logs the full request URL at INFO,
    and a live credential in a query string is a credential in the structured log."""
    apple = _Apple()

    await apple_revocation.revoke("s3cret-token", _settings(siwa_key), client=apple.client())

    for request in apple.requests:
        assert "s3cret-token" not in str(request.url)
        assert request.url.query == b""


@pytest.mark.parametrize(
    ("label", "kwargs", "configured"),
    [
        ("apple returns 500", {"revoke_status": 500}, True),
        ("apple refuses the client", {"revoke_status": 400}, True),
        ("no key is configured", {}, False),
    ],
)
async def test_a_failed_revocation_reports_false_and_never_raises(
    siwa_key, label, kwargs, configured
):
    """**A user who asked to be deleted and was not, because Apple returned a 500, is a
    compliance failure.** So this returns a bool that the caller logs, and the deletion that
    called it carries on regardless — see `test_deletion.py`."""
    ok = await apple_revocation.revoke(
        "r3fresh",
        _settings(siwa_key if configured else None),
        client=_Apple(**kwargs).client(),
    )

    assert ok is False, label


async def test_an_unsignable_key_is_a_false_not_a_traceback():
    """The usual cause is a multi-line `.p8` that lost its newlines on the way into a secret.
    A traceback here would abort a deletion run mid-way."""
    settings = _settings("-----BEGIN PRIVATE KEY-----not a key-----END PRIVATE KEY-----")

    assert await apple_revocation.revoke("r3fresh", settings, client=_Apple().client()) is False


def test_an_ambiguous_bundle_id_leaves_the_client_id_unresolved():
    """With several audiences and no explicit client id there is nothing to default to, and
    guessing would address the revocation to the wrong app.

    `apns_topic` is set only because `Settings` refuses to construct without it once the
    allowlist names more than one audience — the APNs validator is stricter than this is, on
    purpose, and that difference is argued in `resolved_apple_siwa_client_id`.
    """
    settings = _settings(
        None,
        apple_bundle_id=["one.app", "two.app"],
        apns_topic="one.app",
        apple_siwa_client_id=None,
    )

    assert settings.resolved_apple_siwa_client_id is None
    assert settings.apple_siwa_configured is False


# --- Through the real route ---------------------------------------------------------------------
#
# Everything above drives the service directly. These two drive `POST /v1/auth/apple`, because
# the call is queued as a background task and a service test cannot see whether the route ever
# queues it — which is exactly the kind of gap that ships a feature nobody notices is inert.


@pytest.fixture
def siwa_app(apple_app, siwa_key, monkeypatch):
    """The real Apple sign-in app, with a Sign in with Apple key and a local Apple behind it."""
    apple = _Apple()

    async def _post(url, form, settings, *, client=None):
        return await apple._handle_async(url, form)

    monkeypatch.setattr(apple_revocation, "_post", _post)
    apple_app.dependency_overrides[get_settings] = lambda: _settings(siwa_key)
    yield apple_app, apple
    apple_app.dependency_overrides.pop(get_settings, None)


@pytest.fixture
async def siwa_client(siwa_app):
    app, apple = siwa_app
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c, apple


async def test_signing_in_with_apple_stores_the_refresh_token(
    siwa_client, apple_keypair, session: AsyncSession
):
    """**The end-to-end assertion.** The route queues the exchange as a background task, so
    nothing in the service tests above can tell whether it is wired up at all."""
    client, apple = siwa_client

    response = await client.post(
        "/v1/auth/apple",
        json={
            "identity_token": apple_token(apple_keypair, subject="001.endtoend"),
            "authorization_code": "the-code",
        },
    )

    assert response.status_code == 200, response.text
    assert apple.forms and apple.forms[0]["code"] == "the-code"
    stored = await session.scalar(
        sa.select(Credential.apple_refresh_token)
        .where(Credential.subject_id == "001.endtoend")
        .execution_options(populate_existing=True)
    )
    assert stored == "r3fresh"


async def test_a_sign_in_with_no_authorization_code_still_succeeds(
    siwa_client, apple_keypair, session: AsyncSession
):
    """Every client sent no code until phase 127, and an omitted one must not cost a sign-in."""
    client, apple = siwa_client

    response = await client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, subject="001.nocode")},
    )

    assert response.status_code == 200, response.text
    assert apple.forms == []


async def test_a_sign_in_survives_apple_refusing_the_code(
    siwa_app, apple_keypair, session: AsyncSession
):
    """**The asymmetry that matters, asserted where it is actually visible.** A parent getting
    into their own archive is not turned away because Apple's token endpoint had a bad minute.
    The cost is one credential that cannot be revoked until the next sign-in."""
    app, apple = siwa_app
    apple._token_status = 500

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post(
            "/v1/auth/apple",
            json={
                "identity_token": apple_token(apple_keypair, subject="001.refused"),
                "authorization_code": "the-code",
            },
        )

    assert response.status_code == 200, response.text
    assert response.json()["access_token"]
    stored = await session.scalar(
        sa.select(Credential.apple_refresh_token)
        .where(Credential.subject_id == "001.refused")
        .execution_options(populate_existing=True)
    )
    assert stored is None


async def test_a_sign_in_survives_the_background_task_exploding(
    siwa_app, apple_keypair, monkeypatch
):
    """The task swallows its own failure, and this is the only place that can prove it.

    Under `ASGITransport` a background task runs in-process, so an escaping exception would
    surface here as a failed request — which is exactly what it would do to a parent."""
    app, _apple = siwa_app

    async def _explodes(*args, **kwargs):
        raise RuntimeError("apple fell over")

    monkeypatch.setattr(apple_revocation, "capture_refresh_token", _explodes)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post(
            "/v1/auth/apple",
            json={
                "identity_token": apple_token(apple_keypair, subject="001.explode"),
                "authorization_code": "the-code",
            },
        )

    assert response.status_code == 200, response.text
    assert response.json()["access_token"]


# --- The two things round 2 found ---------------------------------------------------------------


async def test_a_real_database_failure_neither_prints_the_token_nor_escapes(
    session: AsyncSession, siwa_key, caplog
):
    """**The leak round 2 found, asserted against a real database failure.**

    A `DBAPIError` renders the failing statement *and its bound parameters* into `str(exc)`.
    The write below is the one statement in the service that binds a live Apple credential, so
    an unguarded failure there put the token into a structured log line — under a message
    saying it had not been stored.

    **The failure is a genuine constraint violation, not a monkeypatched `flush`.** The first
    version of this test patched out both `flush` and `rollback`, which meant the ORM object was
    never expired — and it therefore could not see that reading `credential.id` inside the
    handler was itself an implicit SELECT that raised `MissingGreenlet` and took the whole guard
    down with it. A fabricated exception proved the branch was entered and nothing about whether
    it worked.
    """
    user = await make_user(session)
    session.add(Credential(user_id=user.id, provider="apple", subject_id="001.flushfail"))
    # **Committed first, and that is the whole reason this test works.** A row added in the
    # same transaction is *expunged* by the rollback and keeps its loaded `__dict__`, so
    # reading its id afterwards emits no SQL and the bug hides. A committed row is
    # *expired* instead, and the id read becomes an implicit SELECT. Production always has
    # the second shape: the background task opens a fresh session and loads a row written by
    # the request before it.
    await session.commit()

    # Queued and not yet flushed: `capture_refresh_token`'s own flush is what will hit
    # `uq_credentials_provider_subject_id` and raise a real `IntegrityError`.
    session.add(Credential(user_id=user.id, provider="apple", subject_id="001.flushfail"))

    # **Deliberately unscoped**, unlike every other `caplog` call in this suite, because the
    # assertion below is "the token appears in NO log line" and scoping it to one logger would
    # narrow that to "not in ours". It is safe because SQLAlchemy pins its own logger to WARNING
    # at import, so raising root does not switch on statement echo — and if a future SQLAlchemy
    # stops doing that, this test starting to fail would be it doing its job against the test
    # engine, which is the one place `hide_parameters=True` is not set.
    with caplog.at_level(logging.DEBUG):
        stored = await apple_revocation.capture_refresh_token(
            session, "001.flushfail", "the-code", _settings(siwa_key), client=_Apple().client()
        )

    assert stored is False
    assert "r3fresh" not in caplog.text
    warned = [r for r in caplog.records if "could not be stored" in r.getMessage()]
    assert warned, (
        f"the guard never logged; records were {[r.getMessage() for r in caplog.records]}"
    )
    assert getattr(warned[0], "credential_id", None)


def test_the_engine_never_renders_bound_parameters_into_an_error():
    """The structural half. It protects every statement that binds the column, including ones
    nobody has written yet — the same reasoning `CredentialOut` uses for being an allowlist."""
    from rascal.db import get_engine

    # On the sync engine underneath: `AsyncEngine` is a facade and does not re-export it.
    assert get_engine().sync_engine.hide_parameters is True


async def test_apple_is_asked_before_the_database_is_touched(session: AsyncSession, siwa_key):
    """**No pooled connection may be held across the round trip to Apple.**

    Reading the credential first opens a transaction and checks out a connection that then sits
    idle for the whole call — the exact failure the caller moved this into a background task to
    avoid, carried along by the task rather than fixed. Asserted by order of operations, because
    the shape is the fix and a comment cannot fail."""
    user = await make_user(session)
    session.add(Credential(user_id=user.id, provider="apple", subject_id="001.ordering"))
    await session.flush()

    calls: list[str] = []
    apple = _Apple()

    real_find = apple_revocation.find_credential

    async def _watched_find(*args, **kwargs):
        calls.append("database")
        return await real_find(*args, **kwargs)

    async def _watched_post(url, form, settings, *, client=None):
        calls.append("apple")
        return await apple._handle_async(url, form)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(apple_revocation, "find_credential", _watched_find)
        mp.setattr(apple_revocation, "_post", _watched_post)
        await apple_revocation.capture_refresh_token(
            session, "001.ordering", "the-code", _settings(siwa_key)
        )

    assert calls == ["apple", "database"], (
        "the credential was read before Apple answered, so a pooled connection was held "
        "idle-in-transaction across the round trip"
    )
