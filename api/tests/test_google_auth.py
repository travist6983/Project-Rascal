"""Google sign-in (phase 54).

Mirrors `test_auth.py`'s Apple coverage, including the case that catches decorative
verification — **a token signed by the wrong key under the right `kid`**. That one matters
more than it looks: a verifier that fetches a JWKS, finds the named key and then does not
actually check the signature against it passes every other test in this file.

Two tests here are about the boundary between the providers rather than about Google:
`test_an_apple_token_is_not_a_google_token` and its mirror. `aud` is a claim name both
providers use for values from entirely different namespaces, and pooling the two lists would
be a hole that no single-provider test could see.
"""

from __future__ import annotations

import pytest
import sqlalchemy as sa
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import apple_token
from google_stub import CLIENT_ID, SECOND_CLIENT_ID, google_token
from rascal.config import get_settings
from rascal.deps import get_google_verifier
from rascal.models import Credential, User
from rascal.services.google import GoogleVerifier

SUBJECT = "104729000000000000001"


async def _sign_in(client: AsyncClient, keypair, **kwargs):
    return await client.post(
        "/v1/auth/google", json={"identity_token": google_token(keypair, **kwargs)}
    )


# --- The happy path, and what it writes ---------------------------------------------------


async def test_first_sign_in_creates_a_user_and_a_google_credential(
    google_client: AsyncClient, google_keypair, session: AsyncSession
) -> None:
    response = await google_client.post(
        "/v1/auth/google",
        json={"identity_token": google_token(google_keypair), "display_name": "Travis"},
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["user"]["display_name"] == "Travis"

    credential = await session.scalar(sa.select(Credential))
    # The CHECK has permitted `google` since 0001. This needed no migration, which is the
    # whole point of the credential row.
    assert credential.provider == "google"
    assert credential.subject_id == SUBJECT


async def test_second_sign_in_reuses_the_same_user(
    google_client: AsyncClient, google_keypair, session: AsyncSession
) -> None:
    first = await _sign_in(google_client, google_keypair)
    second = await _sign_in(google_client, google_keypair)

    assert first.json()["user"]["id"] == second.json()["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


async def test_signing_in_records_the_activity_clock(
    google_client: AsyncClient, google_keypair, session: AsyncSession
) -> None:
    """The same throttle as Apple's, feeding the same twelve-month deletion clock."""
    await _sign_in(google_client, google_keypair)
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.last_sign_in_at is not None


@pytest.mark.parametrize("issuer", ["accounts.google.com", "https://accounts.google.com"])
async def test_both_published_issuers_are_accepted(
    google_client: AsyncClient, google_keypair, issuer: str
) -> None:
    """Google publishes both spellings as correct and both are seen."""
    response = await _sign_in(google_client, google_keypair, issuer=issuer)
    assert response.status_code == 200, response.text


@pytest.mark.parametrize("audience", [CLIENT_ID, SECOND_CLIENT_ID])
async def test_every_configured_client_id_is_accepted(
    google_client: AsyncClient, google_keypair, audience: str
) -> None:
    response = await _sign_in(google_client, google_keypair, audience=audience)
    assert response.status_code == 200, response.text


# --- Verification that actually verifies --------------------------------------------------


async def test_a_token_signed_by_the_wrong_key_is_rejected(
    google_client: AsyncClient, google_keypair, session: AsyncSession
) -> None:
    """**Right `kid`, wrong key.** A verifier that looks the key up and never checks the
    signature against it passes every other test in this file."""
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    response = await _sign_in(google_client, google_keypair, key=impostor)

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 0


async def test_a_token_for_an_unconfigured_client_id_is_rejected(
    google_client: AsyncClient, google_keypair
) -> None:
    response = await _sign_in(google_client, google_keypair, audience="someone-else.apps.google")
    assert response.status_code == 401


async def test_a_token_from_another_issuer_is_rejected(
    google_client: AsyncClient, google_keypair
) -> None:
    response = await _sign_in(google_client, google_keypair, issuer="https://evil.example")
    assert response.status_code == 401


async def test_an_expired_token_is_rejected(google_client: AsyncClient, google_keypair) -> None:
    response = await _sign_in(google_client, google_keypair, expires_in=-60)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


async def test_an_unknown_key_id_is_rejected(google_client: AsyncClient, google_keypair) -> None:
    response = await _sign_in(google_client, google_keypair, kid="not-a-real-kid")
    assert response.status_code == 401


async def test_a_malformed_token_is_rejected(google_client: AsyncClient) -> None:
    response = await google_client.post("/v1/auth/google", json={"identity_token": "nope"})
    assert response.status_code == 401


@pytest.mark.parametrize("value", [False, "false", None, "", "yes"])
async def test_an_unverified_email_is_rejected(
    google_client: AsyncClient, google_keypair, session: AsyncSession, value: object
) -> None:
    """**Anything not affirmatively verified is refused.** Phase 57 turns an `email` credential
    into a way to sign in, so accepting an unproved address here would make one a key."""
    response = await _sign_in(google_client, google_keypair, email_verified=value)

    assert response.status_code == 401
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 0


async def test_the_jwks_is_cached_between_logins(
    app: FastAPI, google_keypair, google_settings
) -> None:
    _, jwks = google_keypair
    calls = 0

    async def _fetch() -> dict:
        nonlocal calls
        calls += 1
        return jwks

    # One verifier, reused — the cache lives on the instance, so building a fresh one per
    # request would measure nothing and pass only if the cache did not work.
    verifier = GoogleVerifier(google_settings, fetch=_fetch)
    app.dependency_overrides[get_google_verifier] = lambda: verifier
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        for _ in range(3):
            await client.post(
                "/v1/auth/google", json={"identity_token": google_token(google_keypair)}
            )
    assert calls == 1


# --- The two providers are two namespaces -------------------------------------------------


async def test_an_apple_token_is_not_a_google_token(
    google_client: AsyncClient, apple_keypair
) -> None:
    """A whole Apple token offered to Google. Rejected on the signature before anything else.

    **This one is not sufficient on its own** — see the test below, which is the one that
    actually pins the audience namespaces apart.
    """
    response = await google_client.post(
        "/v1/auth/google", json={"identity_token": apple_token(apple_keypair)}
    )
    assert response.status_code == 401


async def test_apples_audience_is_not_accepted_by_google_even_with_a_valid_signature(
    google_client: AsyncClient, google_keypair
) -> None:
    """**The test that actually pins the two namespaces apart.**

    `test_an_apple_token_is_not_a_google_token` above looks like it covers this and does not:
    the stubs use different keys, so that token dies on the signature and the audience check is
    never reached. It would pass just as happily against a verifier that pooled both providers'
    audience lists — which was caught by deliberately introducing exactly that bug and watching
    every test still pass.

    So this signs with **Google's** key, so the signature is genuinely valid, and puts
    **Apple's** audience in `aud`. The only thing that can reject it is the audience check.
    """
    apple_audience = get_settings().apple_bundle_id[0]

    response = await _sign_in(google_client, google_keypair, audience=apple_audience)

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_a_google_token_is_not_an_apple_token(
    apple_client: AsyncClient, google_keypair
) -> None:
    response = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": google_token(google_keypair)}
    )
    assert response.status_code == 401


async def test_the_same_person_on_both_providers_gets_two_accounts(
    app: FastAPI, apple_keypair, google_keypair, google_settings, session: AsyncSession
) -> None:
    """**Not a defect — the decision.** Nothing matches on email, so signing in with Google
    after Apple is a second account until somebody explicitly links them from inside a session.
    Both stubs use the same address here, which is exactly the case email matching would have
    silently merged."""
    _, apple_jwks = apple_keypair
    _, google_jwks = google_keypair

    async def _apple_fetch() -> dict:
        return apple_jwks

    async def _google_fetch() -> dict:
        return google_jwks

    from rascal.deps import get_apple_verifier
    from rascal.services.apple import AppleVerifier

    app.dependency_overrides[get_apple_verifier] = lambda: AppleVerifier(
        get_settings(), fetch=_apple_fetch
    )
    app.dependency_overrides[get_google_verifier] = lambda: GoogleVerifier(
        google_settings, fetch=_google_fetch
    )
    shared = "parent@gmail.com"
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        first = await client.post(
            "/v1/auth/apple",
            json={"identity_token": apple_token(apple_keypair, email=shared)},
        )
        second = await client.post(
            "/v1/auth/google",
            json={"identity_token": google_token(google_keypair, email=shared)},
        )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["user"]["id"] != second.json()["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 2


# --- An unconfigured server ---------------------------------------------------------------


async def test_an_unconfigured_server_names_the_missing_setting(
    app: FastAPI, google_keypair
) -> None:
    """An unconfigured server must name the setting rather than blame the token.

    Without the guard the answer is `audience=[]` rejecting everything as "could not be
    verified" — true, and useless: it reads as a bad token rather than a missing secret.

    **The empty list is constructed explicitly rather than taken from ambient settings.** This
    test used to lean on `GOOGLE_CLIENT_IDS` being absent from `.env`, which made it a test
    that passed for a reason outside itself — and it broke the moment a real client id was
    configured locally, which is a normal thing to do rather than a mistake.
    """
    _, jwks = google_keypair

    async def _fetch() -> dict:
        return jwks

    unconfigured = get_settings().model_copy(update={"google_client_ids": []})
    assert not unconfigured.google_configured
    app.dependency_overrides[get_google_verifier] = lambda: GoogleVerifier(
        unconfigured, fetch=_fetch
    )
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post(
            "/v1/auth/google", json={"identity_token": google_token(google_keypair)}
        )

    assert response.status_code == 422
    assert "GOOGLE_CLIENT_IDS" in response.json()["error"]["message"]


# --- Linking, which is the reason 52 came first -------------------------------------------


async def test_a_google_credential_can_be_attached_to_an_apple_account(
    app: FastAPI, apple_keypair, google_keypair, google_settings, session: AsyncSession
) -> None:
    """The whole reason credential linking shipped before Google did."""
    _, apple_jwks = apple_keypair
    _, google_jwks = google_keypair

    async def _apple_fetch() -> dict:
        return apple_jwks

    async def _google_fetch() -> dict:
        return google_jwks

    from rascal.deps import get_apple_verifier
    from rascal.services.apple import AppleVerifier

    app.dependency_overrides[get_apple_verifier] = lambda: AppleVerifier(
        get_settings(), fetch=_apple_fetch
    )
    app.dependency_overrides[get_google_verifier] = lambda: GoogleVerifier(
        google_settings, fetch=_google_fetch
    )
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        signed_in = await client.post(
            "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
        )
        headers = {"Authorization": f"Bearer {signed_in.json()['access_token']}"}
        attached = await client.post(
            "/v1/me/credentials",
            headers=headers,
            json={"provider": "google", "identity_token": google_token(google_keypair)},
        )
        listed = await client.get("/v1/me/credentials", headers=headers)

    assert attached.status_code == 200, attached.text
    assert attached.json()["provider"] == "google"
    assert {row["provider"] for row in listed.json()} == {"apple", "google"}
    # One account, two keys. This is the shape the whole bundle exists to make possible.
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1
