"""Sign in with Apple, token rotation, and the local-only dev login.

Apple's JWKS is stubbed with a locally generated RSA keypair. No test touches the network.
"""

from __future__ import annotations

import base64
import datetime as dt
import uuid

import jwt
import pytest
import sqlalchemy as sa
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import get_settings
from rascal.deps import get_apple_verifier
from rascal.main import create_app
from rascal.models import Credential, RefreshToken, User
from rascal.services.apple import AppleVerifier
from rascal.services.tokens import hash_refresh_token

KEY_ID = "rascal-test-key"


def _b64(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


@pytest.fixture(scope="session")
def apple_keypair() -> tuple[rsa.RSAPrivateKey, dict]:
    """A local RSA key plus the JWKS document Apple would have served for it."""
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = private.public_key().public_numbers()
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": KEY_ID,
                "use": "sig",
                "alg": "RS256",
                "n": _b64(numbers.n),
                "e": _b64(numbers.e),
            }
        ]
    }
    return private, jwks


@pytest.fixture
def apple_app(app: FastAPI, apple_keypair) -> FastAPI:
    """The real app, with Apple's JWKS fetch replaced by the local document."""
    _, jwks = apple_keypair

    async def _fetch() -> dict:
        return jwks

    verifier = AppleVerifier(get_settings(), fetch=_fetch)
    app.dependency_overrides[get_apple_verifier] = lambda: verifier
    return app


@pytest.fixture
async def apple_client(apple_app: FastAPI) -> AsyncClient:
    transport = ASGITransport(app=apple_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


def apple_token(
    apple_keypair,
    *,
    subject: str = "001.abcdef",
    audience: str | None = None,
    issuer: str = "https://appleid.apple.com",
    email: str | None = "relay@privaterelay.appleid.com",
    expires_in: int = 600,
    kid: str = KEY_ID,
) -> str:
    private, _ = apple_keypair
    now = dt.datetime.now(tz=dt.UTC)
    claims = {
        "iss": issuer,
        "aud": audience or get_settings().apple_bundle_id,
        "sub": subject,
        "iat": int(now.timestamp()),
        "exp": int((now + dt.timedelta(seconds=expires_in)).timestamp()),
        "email": email,
        "email_verified": "true",
    }
    return jwt.encode(claims, private, algorithm="RS256", headers={"kid": kid})


# --- Sign in with Apple ------------------------------------------------------------------


async def test_first_sign_in_creates_a_user_and_a_credential_row(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair), "display_name": "Travis"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["user"]["display_name"] == "Travis"

    users = (await session.execute(sa.select(User))).scalars().all()
    assert len(users) == 1
    credential = await session.scalar(sa.select(Credential))
    # Apple is a row here, not the identity model.
    assert credential.provider == "apple"
    assert credential.subject_id == "001.abcdef"
    assert credential.user_id == users[0].id


async def test_second_sign_in_reuses_the_same_user(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    first = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )
    second = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )

    assert first.json()["user"]["id"] == second.json()["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


async def test_a_later_sign_in_does_not_blank_a_display_name_apple_only_sends_once(
    apple_client: AsyncClient, apple_keypair
) -> None:
    await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair), "display_name": "Travis"},
    )
    again = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )
    assert again.json()["user"]["display_name"] == "Travis"


async def test_a_token_for_another_bundle_id_is_rejected(
    apple_client: AsyncClient, apple_keypair
) -> None:
    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, audience="com.someone.else")},
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_a_token_from_another_issuer_is_rejected(
    apple_client: AsyncClient, apple_keypair
) -> None:
    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, issuer="https://evil.example")},
    )
    assert response.status_code == 401


async def test_an_expired_token_is_rejected(apple_client: AsyncClient, apple_keypair) -> None:
    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, expires_in=-60)},
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


async def test_a_token_signed_by_the_wrong_key_is_rejected(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """Same kid, different key — the signature check has to be real, not decorative."""
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = dt.datetime.now(tz=dt.UTC)
    forged = jwt.encode(
        {
            "iss": "https://appleid.apple.com",
            "aud": get_settings().apple_bundle_id,
            "sub": "001.forged",
            "exp": int((now + dt.timedelta(minutes=10)).timestamp()),
        },
        impostor,
        algorithm="RS256",
        headers={"kid": KEY_ID},
    )

    response = await apple_client.post("/v1/auth/apple", json={"identity_token": forged})
    assert response.status_code == 401


async def test_an_unknown_key_id_is_rejected(apple_client: AsyncClient, apple_keypair) -> None:
    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, kid="not-a-real-kid")},
    )
    assert response.status_code == 401


async def test_the_jwks_is_cached_between_logins(apple_keypair, app: FastAPI) -> None:
    """Apple's keys are stable for hours; a fetch per login is a self-inflicted outage."""
    _, jwks = apple_keypair
    calls = 0

    async def _fetch() -> dict:
        nonlocal calls
        calls += 1
        return jwks

    verifier = AppleVerifier(get_settings(), fetch=_fetch)
    app.dependency_overrides[get_apple_verifier] = lambda: verifier
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        for _ in range(3):
            await client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    assert calls == 1


# --- Refresh rotation --------------------------------------------------------------------


async def test_refreshing_rotates_the_token_and_revokes_the_old_one(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    signed_in = (
        await apple_client.post(
            "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
        )
    ).json()
    original = signed_in["refresh_token"]

    refreshed = await apple_client.post("/v1/auth/refresh", json={"refresh_token": original})
    assert refreshed.status_code == 200
    assert refreshed.json()["refresh_token"] != original

    stored = await session.scalar(
        sa.select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(original))
    )
    assert stored.revoked_at is not None


async def test_reusing_a_revoked_refresh_token_kills_the_whole_chain(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """A replayed token is a race or a theft. Either way, revoke everything."""
    signed_in = (
        await apple_client.post(
            "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
        )
    ).json()
    first = signed_in["refresh_token"]
    second = (await apple_client.post("/v1/auth/refresh", json={"refresh_token": first})).json()[
        "refresh_token"
    ]

    replayed = await apple_client.post("/v1/auth/refresh", json={"refresh_token": first})
    assert replayed.status_code == 401
    assert replayed.json()["error"]["code"] == "refresh_token_reused"

    # The token issued by the legitimate rotation is dead too.
    followup = await apple_client.post("/v1/auth/refresh", json={"refresh_token": second})
    assert followup.status_code == 401

    live = await session.scalar(
        sa.select(sa.func.count())
        .select_from(RefreshToken)
        .where(RefreshToken.revoked_at.is_(None))
    )
    assert live == 0


async def test_an_unknown_refresh_token_is_a_401(apple_client: AsyncClient) -> None:
    response = await apple_client.post("/v1/auth/refresh", json={"refresh_token": "nope"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_logout_revokes_the_presented_token(apple_client: AsyncClient, apple_keypair) -> None:
    signed_in = (
        await apple_client.post(
            "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
        )
    ).json()

    assert (
        await apple_client.post(
            "/v1/auth/logout", json={"refresh_token": signed_in["refresh_token"]}
        )
    ).status_code == 204

    after = await apple_client.post(
        "/v1/auth/refresh", json={"refresh_token": signed_in["refresh_token"]}
    )
    assert after.status_code == 401


# --- Access tokens -----------------------------------------------------------------------


async def test_a_request_with_no_bearer_token_is_a_401(client: AsyncClient) -> None:
    response = await client.get("/v1/children")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_an_expired_access_token_says_so(client: AsyncClient) -> None:
    settings = get_settings()
    expired = jwt.encode(
        {
            "sub": str(uuid.uuid4()),
            "typ": "access",
            "exp": int((dt.datetime.now(tz=dt.UTC) - dt.timedelta(minutes=1)).timestamp()),
        },
        settings.jwt_secret,
        algorithm="HS256",
    )
    response = await client.get("/v1/children", headers={"Authorization": f"Bearer {expired}"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


async def test_a_token_signed_with_the_wrong_secret_is_rejected(client: AsyncClient) -> None:
    forged = jwt.encode(
        {
            "sub": str(uuid.uuid4()),
            "typ": "access",
            "exp": int((dt.datetime.now(tz=dt.UTC) + dt.timedelta(minutes=5)).timestamp()),
        },
        "not-the-real-secret",
        algorithm="HS256",
    )
    response = await client.get("/v1/children", headers={"Authorization": f"Bearer {forged}"})
    assert response.status_code == 401


# --- dev-login gating --------------------------------------------------------------------


async def test_dev_login_returns_a_usable_session(client: AsyncClient) -> None:
    response = await client.post("/v1/auth/dev-login", json={})
    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "dev@rascal.local"

    # Calling it again returns the same fixture user rather than a second account.
    again = await client.post("/v1/auth/dev-login", json={})
    assert again.json()["user"]["id"] == body["user"]["id"]

    authed = await client.get(
        "/v1/children", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert authed.status_code == 200


async def test_dev_login_is_not_registered_outside_local(engine) -> None:
    """This route must not exist in a production build."""
    settings = get_settings().model_copy(update={"environment": "prod"})
    prod_app = create_app(settings)

    paths = prod_app.openapi()["paths"]
    assert "/v1/auth/dev-login" not in paths
    assert "/v1/auth/apple" in paths

    assert not any(path.startswith("/v1/debug") for path in paths), (
        "debug routes must be gated the same way as dev-login"
    )
