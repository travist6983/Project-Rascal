"""Sign in with Apple, token rotation, and the local-only dev login.

Apple's JWKS is stubbed with a locally generated RSA keypair — `apple_stub`, wrapped by the
fixtures in `conftest.py`. No test touches the network.

`/me/credentials` and the revocation state live in `test_credentials.py`.
"""

from __future__ import annotations

import datetime as dt
import uuid

import jwt
import pytest
import sqlalchemy as sa
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import KEY_ID, apple_token
from rascal.config import Settings, get_settings
from rascal.deps import get_apple_verifier
from rascal.main import create_app
from rascal.models import Credential, RefreshToken, User
from rascal.services.apple import AppleVerifier
from rascal.services.tokens import hash_refresh_token

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
            "aud": get_settings().apple_bundle_id[0],
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
        # Wrong, but long enough not to trip PyJWT's InsecureKeyLengthWarning — the point
        # of the test is the wrong key, not a short one.
        "not-the-real-secret-but-long-enough-to-be-a-real-one",
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


# --- dev-login's second lock, and its new credential shape (phase 52) ---------------------
#
# The route being absent from a production build is the first lock and it is unchanged. The
# hole it does not close is a *local* API pointed at a *real* database — a restore drill, a
# production debugging session — where typing your own address would hand back an `is_admin`
# session for the live account. `ENVIRONMENT` can be right while the database is not.


async def test_dev_login_writes_an_email_credential_not_a_password_one(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The fixture rehearses the production credential shape instead of squatting beside it."""
    response = await client.post("/v1/auth/dev-login", json={})
    assert response.status_code == 200

    credential = await session.scalar(sa.select(Credential))
    assert credential.provider == "email"
    assert credential.subject_id == "dev@rascal.local"
    assert credential.revoked_at is None


@pytest.mark.parametrize(
    "email",
    [
        "travisjterry@gmail.com",
        "parent@example.com",
        "someone@privaterelay.appleid.com",
        # The nearest miss, and the one an allowlist has to actually catch.
        "someone@rascal.local.example.com",
    ],
)
async def test_dev_login_refuses_an_address_outside_the_local_domains(
    client: AsyncClient, session: AsyncSession, email: str
) -> None:
    response = await client.post("/v1/auth/dev-login", json={"email": email})
    assert response.status_code == 422
    assert response.json()["error"]["field"] == "email"

    # And it is a refusal rather than a half-completed sign-in.
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 0
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 0


async def test_dev_login_normalises_the_address_before_it_checks_the_domain(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A domain is case-insensitive, so a guard that is not would be a hole rather than a check."""
    response = await client.post("/v1/auth/dev-login", json={"email": "  Dev@Rascal.Local  "})
    assert response.status_code == 200
    assert response.json()["user"]["email"] == "dev@rascal.local"

    # The same fixture account as the default call, not a second one beside it.
    again = await client.post("/v1/auth/dev-login", json={})
    assert again.json()["user"]["id"] == response.json()["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


# --- The activity clock, and the two consent lanes (phase 49) -----------------------------
#
# `last_sign_in_at` feeds D3's second deletion clock, `last_sign_in_at + 12 months`. Nothing
# reads it yet. These tests exist because the column's whole value is the history it
# accumulates before anything reads it — a bug here is invisible until the day it deletes
# somebody's archive, and by then the record it got wrong cannot be reconstructed.


async def test_signing_in_records_the_activity_clock(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    before = dt.datetime.now(tz=dt.UTC)
    response = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )
    assert response.status_code == 200

    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.last_sign_in_at is not None
    assert user.last_sign_in_at >= before


async def test_a_refresh_counts_as_activity(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**The test that stops the clock deleting active families.**

    An app in daily use rotates its refresh token and never performs a fresh credential
    sign-in again. If only `/auth/apple` moved the clock, the most engaged households would
    look dormant for twelve months while writing entries the whole time, and the eligibility
    date would come due underneath them.
    """
    signed_in = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )
    refresh_token = signed_in.json()["refresh_token"]

    user = await session.scalar(sa.select(User))
    # Push the recorded activity back beyond the throttle, so a fresh write is expected rather
    # than suppressed. Without this the assertion would pass on a no-op.
    stale = dt.datetime.now(tz=dt.UTC) - dt.timedelta(days=400)
    await session.execute(sa.update(User).where(User.id == user.id).values(last_sign_in_at=stale))
    await session.commit()

    response = await apple_client.post("/v1/auth/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 200

    await session.refresh(user)
    assert user.last_sign_in_at > stale, "a refresh must count as activity"
    assert user.last_sign_in_at > dt.datetime.now(tz=dt.UTC) - dt.timedelta(minutes=5)


async def test_a_second_sign_in_within_the_day_does_not_rewrite_the_clock(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Throttled deliberately: an active app rotates four times an hour and this column feeds
    a twelve-month clock. A day's granularity is three orders of magnitude finer than it needs.
    """
    await apple_client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    first = user.last_sign_in_at

    await apple_client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    await session.refresh(user)
    assert user.last_sign_in_at == first


async def test_the_clock_moves_once_the_recorded_activity_is_stale(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    await apple_client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    user = await session.scalar(sa.select(User))
    stale = dt.datetime.now(tz=dt.UTC) - dt.timedelta(days=2)
    await session.execute(sa.update(User).where(User.id == user.id).values(last_sign_in_at=stale))
    await session.commit()

    await apple_client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    await session.refresh(user)
    assert user.last_sign_in_at > stale


async def test_a_new_user_starts_with_both_consent_lanes_and_they_are_separate_columns(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Two fields, never one flag — D3a. The assertion is that both exist independently, which
    is the whole point: one boolean cannot later be untangled into consent-for-marketing and
    consent-for-required-notices under a GDPR or CCPA request.
    """
    await apple_client.post("/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)})
    user = await session.scalar(sa.select(User))
    await session.refresh(user)

    assert user.marketing_consent is True
    assert user.transactional_consent is True

    # Independently settable, which a single flag could not be. Marketing off must leave the
    # deletion-warning lane untouched — that is the failure mode the two columns prevent.
    await session.execute(sa.update(User).where(User.id == user.id).values(marketing_consent=False))
    await session.commit()
    await session.refresh(user)
    assert user.marketing_consent is False
    assert user.transactional_consent is True


async def test_the_consent_lanes_are_not_settable_through_the_api(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """No route may switch off `transactional_consent`. D3's hard stop is that deletion cannot
    fire without a confirmed delivery; a user who could silence the warning would leave the
    timer running and lose the archive quietly. Nothing sends email yet, so neither lane has a
    consumer — and a field a client can set with no consumer is furniture.
    """
    signed_in = await apple_client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(apple_keypair)}
    )
    token = signed_in.json()["access_token"]
    assert "marketing_consent" not in signed_in.json()["user"]
    assert "transactional_consent" not in signed_in.json()["user"]
    assert "last_sign_in_at" not in signed_in.json()["user"]

    response = await apple_client.patch(
        "/v1/me",
        headers={"Authorization": f"Bearer {token}"},
        json={"transactional_consent": False, "marketing_consent": False},
    )
    # Whatever the route does with unknown keys, it must not have changed either lane.
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.transactional_consent is True
    assert user.marketing_consent is True
    assert response.status_code in {200, 422}


# --- The `aud` allowlist, and the APNs topic beside it (phase 51) -------------------------
#
# One Apple credential can be issued to more than one audience: the iOS app is one, and a
# browser client signing in through a Services ID is a second. `aud` is the only claim that
# distinguishes them, so the check is an allowlist rather than an equality.
#
# `resolved_apns_topic` used to fall back to the same field, which is the trap this phase
# exists to close: the moment `APPLE_BUNDLE_ID` holds two values, "the topic is the bundle id"
# stops being a sentence with one meaning.


def _settings_with(**overrides: object) -> Settings:
    """A `Settings` built through the validators, not around them.

    `model_copy` is the usual trick in this file and is wrong here: it assigns fields without
    revalidating, so it cannot observe a rule that only a constructor enforces.
    """
    return Settings(**{**get_settings().model_dump(), **overrides})  # type: ignore[arg-type]


def _apple_app_with(settings: Settings, apple_keypair) -> FastAPI:
    _, jwks = apple_keypair

    async def _fetch() -> dict:
        return jwks

    application = create_app(settings)
    application.dependency_overrides[get_apple_verifier] = lambda: AppleVerifier(
        settings, fetch=_fetch
    )
    return application


def _client_for(application: FastAPI) -> AsyncClient:
    return AsyncClient(transport=ASGITransport(app=application), base_url="http://test")


async def test_a_single_audience_still_verifies_a_token(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """The production path, pinned. One value behaves exactly as it did before the list."""
    settings = get_settings()
    assert settings.apple_bundle_id == ["com.travisterry.childarchive"]

    response = await apple_client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(apple_keypair, audience=settings.apple_bundle_id[0])},
    )
    assert response.status_code == 200


@pytest.mark.parametrize("audience", ["com.travisterry.childarchive", "com.travisterry.web"])
async def test_two_audiences_are_both_accepted(engine, apple_keypair, audience: str) -> None:
    settings = _settings_with(
        apple_bundle_id="com.travisterry.childarchive, com.travisterry.web",
        apns_topic="com.travisterry.childarchive",
    )
    assert settings.apple_bundle_id == ["com.travisterry.childarchive", "com.travisterry.web"]

    async with _client_for(_apple_app_with(settings, apple_keypair)) as client:
        response = await client.post(
            "/v1/auth/apple",
            json={"identity_token": apple_token(apple_keypair, audience=audience)},
        )
    assert response.status_code == 200


async def test_an_audience_on_neither_list_entry_is_rejected(engine, apple_keypair) -> None:
    """The allowlist is still a list of *allowed* values, not a list that lets anything in."""
    settings = _settings_with(
        apple_bundle_id="com.travisterry.childarchive, com.travisterry.web",
        apns_topic="com.travisterry.childarchive",
    )
    async with _client_for(_apple_app_with(settings, apple_keypair)) as client:
        response = await client.post(
            "/v1/auth/apple",
            json={"identity_token": apple_token(apple_keypair, audience="com.someone.else")},
        )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


def test_two_audiences_without_an_apns_topic_refuse_to_start() -> None:
    """A misconfiguration that would otherwise surface as every push silently rejected."""
    with pytest.raises(ValidationError) as raised:
        _settings_with(
            apple_bundle_id="com.travisterry.childarchive, com.travisterry.web",
            apns_topic=None,
        )
    assert "APNS_TOPIC" in str(raised.value)


def test_one_audience_without_an_apns_topic_still_falls_back_to_it() -> None:
    """The fallback is only ambiguous with more than one audience, so it stays for one."""
    settings = _settings_with(apple_bundle_id="com.travisterry.childarchive", apns_topic=None)
    assert settings.resolved_apns_topic == "com.travisterry.childarchive"


def test_the_audience_list_is_stripped_and_compacted() -> None:
    settings = _settings_with(
        apple_bundle_id=" com.travisterry.childarchive ,, com.travisterry.web , ",
        apns_topic="com.travisterry.childarchive",
    )
    assert settings.apple_bundle_id == ["com.travisterry.childarchive", "com.travisterry.web"]


@pytest.mark.parametrize("value", ["", "   ", ",", " , , "])
def test_an_empty_audience_list_refuses_to_start(value: str) -> None:
    """`audience=[]` would reject every token Apple has ever signed, at the first sign-in."""
    with pytest.raises(ValidationError) as raised:
        _settings_with(apple_bundle_id=value, apns_topic="com.travisterry.childarchive")
    assert "at least one audience" in str(raised.value)
