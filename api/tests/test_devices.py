"""`POST /v1/devices` and `DELETE /v1/devices/{token}` — where a notification goes.

The registration is called on every launch, so being idempotent is not a nicety: a client
that grows a row per launch would, within a month, be sending one parent thirty copies of
the same notification.
"""

from __future__ import annotations

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_device, make_user
from helpers import auth_headers
from rascal.models import Device

TOKEN = "a1b2c3" * 10  # 60 hex characters. Real ones are 64; nothing depends on the length.


async def _rows(session: AsyncSession, token: str) -> list[Device]:
    result = await session.execute(
        sa.select(Device).where(Device.token == token).order_by(Device.environment)
    )
    return list(result.scalars().all())


def _body(token: str = TOKEN, environment: str = "production") -> dict:
    return {"token": token, "platform": "ios", "environment": environment}


# --- Registration --------------------------------------------------------------------------


async def test_registering_a_device_returns_the_row(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post("/v1/devices", json=_body(), headers=auth_headers(user))

    assert response.status_code == 200
    body = response.json()
    assert body["token"] == TOKEN
    assert body["platform"] == "ios"
    assert body["environment"] == "production"
    assert body["revoked_at"] is None
    assert body["last_seen_at"] is not None


async def test_registering_the_same_token_twice_is_one_row_with_a_fresh_last_seen_at(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The client calls this on every launch. Two launches must not be two notifications."""
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)

    first = await client.post("/v1/devices", json=_body(), headers=headers)
    second = await client.post("/v1/devices", json=_body(), headers=headers)

    assert first.status_code == 200
    assert second.status_code == 200
    # Same row, not a second one.
    assert first.json()["id"] == second.json()["id"]

    rows = await _rows(session, TOKEN)
    assert len(rows) == 1
    assert second.json()["last_seen_at"] >= first.json()["last_seen_at"]


async def test_a_sandbox_and_a_production_token_with_identical_values_are_separate_rows(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The single most common way push works in development and not in TestFlight.

    The same string is a different token per environment and addresses a different APNs
    host. Collapsing them onto one row would mean whichever build launched last silently
    won, and the other one would fail with no error anybody ever sees.
    """
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)

    sandbox = await client.post("/v1/devices", json=_body(environment="sandbox"), headers=headers)
    production = await client.post(
        "/v1/devices", json=_body(environment="production"), headers=headers
    )

    assert sandbox.status_code == 200
    assert production.status_code == 200
    assert sandbox.json()["id"] != production.json()["id"]

    rows = await _rows(session, TOKEN)
    assert [row.environment for row in rows] == ["production", "sandbox"]


async def test_environment_is_required(client: AsyncClient, session: AsyncSession) -> None:
    """There is no safe default: guessing wrong fails silently, forever."""
    user = await make_user(session)
    await session.commit()

    response = await client.post(
        "/v1/devices", json={"token": TOKEN, "platform": "ios"}, headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_failed"
    assert response.json()["error"]["field"] == "environment"


async def test_an_unknown_environment_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post(
        "/v1/devices", json=_body(environment="staging"), headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert await _rows(session, TOKEN) == []


async def test_a_blank_token_is_refused(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post("/v1/devices", json=_body(token="   "), headers=auth_headers(user))

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "token"


async def test_registering_requires_a_token(client: AsyncClient) -> None:
    response = await client.post("/v1/devices", json=_body())

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_a_token_moves_to_whoever_registered_it_last(
    client: AsyncClient, session: AsyncSession
) -> None:
    """One phone, two accounts. Signing in as somebody else must not keep delivering the
    first account's notifications to the second account's lock screen."""
    first = await make_user(session, display_name="First")
    second = await make_user(session, display_name="Second")
    await session.commit()

    await client.post("/v1/devices", json=_body(), headers=auth_headers(first))
    await client.post("/v1/devices", json=_body(), headers=auth_headers(second))

    rows = await _rows(session, TOKEN)
    assert len(rows) == 1
    assert rows[0].user_id == second.id


# --- Revocation ----------------------------------------------------------------------------


async def test_signing_out_soft_deletes_the_device(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)
    await client.post("/v1/devices", json=_body(), headers=headers)

    response = await client.delete(f"/v1/devices/{TOKEN}", headers=headers)

    assert response.status_code == 204
    rows = await _rows(session, TOKEN)
    # Soft delete: the row stays, carrying revoked_at. Deletions are never absences.
    assert len(rows) == 1
    assert rows[0].revoked_at is not None


async def test_signing_out_revokes_the_token_in_both_environments(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Sign-out means this phone stops receiving on this account, and a phone that has run
    both a development and a TestFlight build holds a row for each."""
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)
    await client.post("/v1/devices", json=_body(environment="sandbox"), headers=headers)
    await client.post("/v1/devices", json=_body(environment="production"), headers=headers)

    response = await client.delete(f"/v1/devices/{TOKEN}", headers=headers)

    assert response.status_code == 204
    rows = await _rows(session, TOKEN)
    assert len(rows) == 2
    assert all(row.revoked_at is not None for row in rows)


async def test_revoking_twice_is_still_success(client: AsyncClient, session: AsyncSession) -> None:
    """The caller's intent — this token is done — is already true the second time."""
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)
    await client.post("/v1/devices", json=_body(), headers=headers)

    first = await client.delete(f"/v1/devices/{TOKEN}", headers=headers)
    second = await client.delete(f"/v1/devices/{TOKEN}", headers=headers)

    assert first.status_code == 204
    assert second.status_code == 204


async def test_signing_back_in_revives_the_row_rather_than_duplicating_it(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()
    headers = auth_headers(user)
    registered = await client.post("/v1/devices", json=_body(), headers=headers)
    await client.delete(f"/v1/devices/{TOKEN}", headers=headers)

    again = await client.post("/v1/devices", json=_body(), headers=headers)

    assert again.status_code == 200
    assert again.json()["id"] == registered.json()["id"]
    assert again.json()["revoked_at"] is None
    assert len(await _rows(session, TOKEN)) == 1


async def test_revoking_a_token_this_account_never_registered_is_not_found(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.delete(f"/v1/devices/{TOKEN}", headers=auth_headers(user))

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


async def test_one_account_cannot_revoke_another_accounts_device(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Answering "that token exists, but not for you" would make this route a way to probe
    tokens. It reads as absent instead."""
    owner = await make_user(session, display_name="Owner")
    stranger = await make_user(session, display_name="Stranger")
    await make_device(session, owner, token=TOKEN)
    await session.commit()

    response = await client.delete(f"/v1/devices/{TOKEN}", headers=auth_headers(stranger))

    assert response.status_code == 404
    rows = await _rows(session, TOKEN)
    assert rows[0].revoked_at is None


async def test_revoking_requires_a_token(client: AsyncClient) -> None:
    response = await client.delete(f"/v1/devices/{TOKEN}")

    assert response.status_code == 401
