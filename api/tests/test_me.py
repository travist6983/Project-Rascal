"""`PATCH /v1/me` — the one thing a user can change about themselves.

Apple's relay addresses are unreliable and `users.email` is nullable because of it, so
`display_name` is the only human-readable identity in the product. A Settings screen that
cannot fix it leaves an account labelled with whatever Apple sent once, forever.
"""

from __future__ import annotations

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_user
from helpers import auth_headers
from rascal.models import User


async def _stored(session: AsyncSession, user: User) -> sa.Row:
    """Read the row back from the database rather than from the arranging session."""
    return (
        await session.execute(
            sa.select(User.display_name, User.email, User.updated_at).where(User.id == user.id)
        )
    ).one()


async def test_a_user_can_change_their_own_display_name(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session, display_name="Travsi")
    await session.commit()
    before = (await _stored(session, user)).updated_at

    response = await client.patch(
        "/v1/me", json={"display_name": "Travis"}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    body = response.json()
    assert body["display_name"] == "Travis"
    assert body["id"] == str(user.id)
    # The same user object /auth/apple returns, not a parallel shape.
    assert set(body) == {"id", "email", "display_name", "is_admin", "created_at"}

    after = await _stored(session, user)
    assert after.display_name == "Travis"
    # Written by the set_updated_at() trigger, so a client's next sync sees the change.
    assert after.updated_at > before


async def test_the_name_is_trimmed(client: AsyncClient, session: AsyncSession) -> None:
    """A trailing space from an iOS text field is not part of anybody's name."""
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "  Travis  "}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    assert response.json()["display_name"] == "Travis"
    assert (await _stored(session, user)).display_name == "Travis"


async def test_an_empty_display_name_is_refused(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session, display_name="Travis")
    await session.commit()

    response = await client.patch("/v1/me", json={"display_name": ""}, headers=auth_headers(user))

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_display_name"
    assert response.json()["error"]["field"] == "display_name"
    assert (await _stored(session, user)).display_name == "Travis"


async def test_a_whitespace_only_display_name_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Blank after strip is blank. Otherwise the account is labelled with three spaces."""
    user = await make_user(session, display_name="Travis")
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "   \t\n "}, headers=auth_headers(user)
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_display_name"
    assert (await _stored(session, user)).display_name == "Travis"


async def test_an_over_long_display_name_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session, display_name="Travis")
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "T" * 101}, headers=auth_headers(user)
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_display_name"
    assert (await _stored(session, user)).display_name == "Travis"


async def test_exactly_the_limit_is_accepted(client: AsyncClient, session: AsyncSession) -> None:
    """100 is the limit, not the first value over it."""
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "T" * 100}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    assert response.json()["display_name"] == "T" * 100


async def test_it_requires_a_token(client: AsyncClient) -> None:
    response = await client.patch("/v1/me", json={"display_name": "Travis"})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_email_is_not_writable(client: AsyncClient, session: AsyncSession) -> None:
    """Email comes from the credential provider. Sending one changes nothing."""
    user = await make_user(session)
    original = user.email
    await session.commit()

    response = await client.patch(
        "/v1/me",
        json={"display_name": "Travis", "email": "someone-else@example.com"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert response.json()["email"] == original
    assert (await _stored(session, user)).email == original


async def test_it_updates_only_the_caller(client: AsyncClient, session: AsyncSession) -> None:
    """There is no path parameter, so there is no way to name somebody else's row."""
    caller = await make_user(session, display_name="Travis")
    other = await make_user(session, display_name="Somebody Else")
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "Renamed"}, headers=auth_headers(caller)
    )

    assert response.status_code == 200
    assert (await _stored(session, caller)).display_name == "Renamed"
    assert (await _stored(session, other)).display_name == "Somebody Else"
