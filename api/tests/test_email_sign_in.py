"""Magic-link email sign-in (phase 57).

**The restriction this whole phase rests on: `POST /auth/email/start` never creates a user.**
`test_start_never_creates_a_user` is the break-test target named in the plan, and the reason it
matters is not abuse — it is the orphan-account trap. Without the guard, a parent who signed in
with Apple and later typed their address into the email field would be handed a second, empty
archive, with a working session and no signal at all that their real one still exists somewhere
they can no longer reach.

The second thing worth naming is that `start` always answers `202`. Every test here that
asserts on a status code is also asserting there is no enumeration oracle.
"""

from __future__ import annotations

import datetime as dt

import pytest
import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import apple_token
from rascal.models import Credential, EmailSignInToken, RateLimitEvent, User
from rascal.services.email_sign_in import TOKEN_TTL, hash_token

ADDRESS = "parent@example.com"


async def _apple_session(client: AsyncClient, keypair, subject: str = "001.email-phase") -> dict:
    response = await client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(keypair, subject=subject)}
    )
    assert response.status_code == 200, response.text
    return response.json()


def _auth(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['access_token']}"}


def _link_token(printed: str) -> str:
    """Pull the raw token out of what the console provider printed.

    The raw value is never stored, so the only place a test can get one is the message — which
    is exactly the property being relied on.
    """
    marker = "?token="
    start = printed.index(marker) + len(marker)
    return printed[start:].split()[0]


async def _add_email(client: AsyncClient, headers: dict, capsys, address: str = ADDRESS):
    response = await client.post(
        "/v1/me/credentials/email", headers=headers, json={"provider": "email", "email": address}
    )
    printed = capsys.readouterr().out
    return response, printed


# --- The restriction that makes this small ------------------------------------------------


async def test_start_never_creates_a_user(client: AsyncClient, session: AsyncSession) -> None:
    """**The guard the whole design rests on.** No user, no credential, and nothing sent."""
    response = await client.post("/v1/auth/email/start", json={"email": "nobody@example.com"})

    assert response.status_code == 202
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 0
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 0
    assert await session.scalar(sa.select(sa.func.count()).select_from(EmailSignInToken)) == 0


async def test_start_for_an_unknown_address_sends_nothing(client: AsyncClient, capsys) -> None:
    capsys.readouterr()
    await client.post("/v1/auth/email/start", json={"email": "nobody@example.com"})
    assert "?token=" not in capsys.readouterr().out


async def test_start_answers_the_same_for_a_known_and_an_unknown_address(
    apple_client: AsyncClient, apple_keypair, capsys
) -> None:
    """No enumeration oracle: identical status and identical body."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    await _add_email(apple_client, _auth(signed_in), capsys)

    known = await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})
    unknown = await apple_client.post("/v1/auth/email/start", json={"email": "no@example.com"})

    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()


# --- Adding an address, which is where a credential comes from ----------------------------


async def test_adding_an_address_creates_an_inactive_credential_and_sends_a_link(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """**Inactive until the click.** A typo must not hand a stranger's inbox a key."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    response, printed = await _add_email(apple_client, _auth(signed_in), capsys)

    assert response.status_code == 202
    assert response.json()["revoked_at"] is not None, "not a way in until it is verified"
    assert "?token=" in printed

    credential = await session.scalar(sa.select(Credential).where(Credential.provider == "email"))
    assert credential.subject_id == ADDRESS
    assert credential.revoked_at is not None


async def test_an_unverified_address_cannot_start_a_sign_in(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """Only the verification link works until the address is proved."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    await _add_email(apple_client, _auth(signed_in), capsys)
    capsys.readouterr()

    response = await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})

    assert response.status_code == 202
    assert "?token=" not in capsys.readouterr().out


async def test_the_address_is_lowercased(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    await _add_email(apple_client, _auth(signed_in), capsys, address="  Parent@Example.COM ")

    credential = await session.scalar(sa.select(Credential).where(Credential.provider == "email"))
    assert credential.subject_id == ADDRESS


async def test_an_address_on_another_account_is_a_409(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    first = await _apple_session(apple_client, apple_keypair, subject="001.first")
    await _add_email(apple_client, _auth(first), capsys)
    second = await _apple_session(apple_client, apple_keypair, subject="001.second")

    response, _ = await _add_email(apple_client, _auth(second), capsys)

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "credential_in_use"
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 3


async def test_adding_requires_a_bearer_token(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/me/credentials/email", json={"provider": "email", "email": ADDRESS}
    )
    assert response.status_code == 401


@pytest.mark.parametrize("bad", ["not-an-address", "@example.com", "parent@"])
async def test_a_malformed_address_is_refused(
    apple_client: AsyncClient, apple_keypair, bad: str, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    response, _ = await _add_email(apple_client, _auth(signed_in), capsys, address=bad)
    assert response.status_code == 422


# --- The click ----------------------------------------------------------------------------


async def test_the_link_verifies_the_address_and_returns_a_session(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    raw = _link_token(printed)

    response = await apple_client.post("/v1/auth/email/complete", json={"token": raw})

    assert response.status_code == 200
    # The same account, not a second one. This is the orphan trap staying shut.
    assert response.json()["user"]["id"] == signed_in["user"]["id"]

    credential = await session.scalar(sa.select(Credential).where(Credential.provider == "email"))
    await session.refresh(credential)
    assert credential.revoked_at is None, "the click is what verifies the address"


async def test_a_verified_address_can_then_start_a_sign_in_and_use_it(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """The whole loop: add, verify, later sign in with nothing but the address."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    await apple_client.post("/v1/auth/email/complete", json={"token": _link_token(printed)})

    capsys.readouterr()
    await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})
    raw = _link_token(capsys.readouterr().out)
    returned = await apple_client.post("/v1/auth/email/complete", json={"token": raw})

    assert returned.status_code == 200
    assert returned.json()["user"]["id"] == signed_in["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


async def test_a_token_works_exactly_once(apple_client: AsyncClient, apple_keypair, capsys) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    raw = _link_token(printed)

    first = await apple_client.post("/v1/auth/email/complete", json={"token": raw})
    second = await apple_client.post("/v1/auth/email/complete", json={"token": raw})

    assert first.status_code == 200
    assert second.status_code == 401
    assert second.json()["error"]["code"] == "sign_in_link_invalid"


async def test_an_expired_token_is_refused(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    raw = _link_token(printed)

    # Age the token past its window rather than sleeping through it.
    stored = await session.scalar(
        sa.select(EmailSignInToken).where(EmailSignInToken.token_hash == hash_token(raw))
    )
    stored.expires_at = dt.datetime.now(tz=dt.UTC) - TOKEN_TTL
    await session.commit()

    response = await apple_client.post("/v1/auth/email/complete", json={"token": raw})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "sign_in_link_invalid"


async def test_an_unknown_token_is_refused(apple_client: AsyncClient) -> None:
    response = await apple_client.post(
        "/v1/auth/email/complete", json={"token": "not-a-real-token"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "sign_in_link_invalid"


async def test_a_token_for_a_revoked_credential_is_refused(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """A removed sign-in method must not be quietly reusable through an old link."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    _, printed = await _add_email(apple_client, headers, capsys)
    raw = _link_token(printed)
    await apple_client.post("/v1/auth/email/complete", json={"token": raw})

    # A second link, then remove the address before it is opened.
    capsys.readouterr()
    await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})
    pending = _link_token(capsys.readouterr().out)
    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    email_id = next(row["id"] for row in listed if row["provider"] == "email")
    removed = await apple_client.delete(f"/v1/me/credentials/{email_id}", headers=headers)
    assert removed.status_code == 200

    response = await apple_client.post("/v1/auth/email/complete", json={"token": pending})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "sign_in_link_invalid"

    # And the credential stays revoked. **A link that could put the key back would make
    # Remove a suggestion rather than an action**, which is why a `sign_in` token may not
    # clear `revoked_at` and only a `verify` token from a deliberate re-add may.
    credential = await session.scalar(sa.select(Credential).where(Credential.provider == "email"))
    await session.refresh(credential)
    assert credential.revoked_at is not None


async def test_a_removed_address_can_be_added_back_deliberately(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """Refusing the stale link is not a dead end — re-adding sends a `verify` link that works."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    _, printed = await _add_email(apple_client, headers, capsys)
    await apple_client.post("/v1/auth/email/complete", json={"token": _link_token(printed)})

    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    email_id = next(row["id"] for row in listed if row["provider"] == "email")
    await apple_client.delete(f"/v1/me/credentials/{email_id}", headers=headers)

    _, again = await _add_email(apple_client, headers, capsys)
    response = await apple_client.post(
        "/v1/auth/email/complete", json={"token": _link_token(again)}
    )

    assert response.status_code == 200
    assert response.json()["user"]["id"] == signed_in["user"]["id"]
    # Re-added, not duplicated.
    assert (
        await session.scalar(
            sa.select(sa.func.count()).select_from(Credential).where(Credential.provider == "email")
        )
        == 1
    )


async def test_the_raw_token_is_never_stored(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """Same rule as `refresh_tokens`: a database dump is not a set of working keys."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    raw = _link_token(printed)

    stored = await session.scalar(sa.select(EmailSignInToken))
    assert stored.token_hash != raw
    assert stored.token_hash == hash_token(raw)
    assert (
        await session.scalar(
            sa.select(sa.func.count())
            .select_from(EmailSignInToken)
            .where(EmailSignInToken.token_hash == raw)
        )
        == 0
    )


async def test_completing_stamps_the_activity_clock(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    _, printed = await _add_email(apple_client, _auth(signed_in), capsys)
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    user.last_sign_in_at = None
    await session.commit()

    await apple_client.post("/v1/auth/email/complete", json={"token": _link_token(printed)})

    await session.refresh(user)
    assert user.last_sign_in_at is not None


# --- Rate limiting ------------------------------------------------------------------------


async def test_the_per_email_limit_trips(
    client: AsyncClient, session: AsyncSession, settings_limit=5
) -> None:
    """Per-email is the limit that matters: the abuse is spamming links at one address."""
    for _ in range(5):
        assert (
            await client.post("/v1/auth/email/start", json={"email": ADDRESS})
        ).status_code == 202

    sixth = await client.post("/v1/auth/email/start", json={"email": ADDRESS})
    assert sixth.status_code == 429
    assert sixth.json()["error"]["code"] == "rate_limited"


async def test_the_per_email_limit_does_not_bleed_between_addresses(
    client: AsyncClient,
) -> None:
    for _ in range(5):
        await client.post("/v1/auth/email/start", json={"email": ADDRESS})

    other = await client.post("/v1/auth/email/start", json={"email": "someone@example.com"})
    assert other.status_code == 202


async def test_the_per_ip_limit_trips_independently(client: AsyncClient) -> None:
    """Twenty per IP, across any number of addresses — so a spray is caught even though no
    single address reaches its own limit."""
    codes = []
    for index in range(22):
        response = await client.post(
            "/v1/auth/email/start", json={"email": f"person{index}@example.com"}
        )
        codes.append(response.status_code)

    assert codes[:20] == [202] * 20
    assert codes[20] == 429, "the 21st request from one IP is refused"


async def test_a_refusal_does_not_record_an_attempt(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Being refused must not extend your own lockout by retrying."""
    for _ in range(5):
        await client.post("/v1/auth/email/start", json={"email": ADDRESS})
    before = await session.scalar(
        sa.select(sa.func.count())
        .select_from(RateLimitEvent)
        .where(RateLimitEvent.bucket == f"email:{ADDRESS}")
    )

    await client.post("/v1/auth/email/start", json={"email": ADDRESS})
    after = await session.scalar(
        sa.select(sa.func.count())
        .select_from(RateLimitEvent)
        .where(RateLimitEvent.bucket == f"email:{ADDRESS}")
    )

    assert after == before == 5


async def test_the_limit_is_in_postgres_not_in_memory(
    client: AsyncClient, session: AsyncSession
) -> None:
    """There is more than one Fly machine, so an in-process counter is per-process theatre.

    Asserting the rows exist is what pins the storage: an in-memory implementation passes every
    other test in this section and none of this one.
    """
    await client.post("/v1/auth/email/start", json={"email": ADDRESS})

    rows = list(await session.scalars(sa.select(RateLimitEvent)))
    buckets = {row.bucket for row in rows}
    assert f"email:{ADDRESS}" in buckets
    assert any(bucket.startswith("ip:") for bucket in buckets)
