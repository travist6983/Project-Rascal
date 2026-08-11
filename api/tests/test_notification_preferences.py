"""The notification preference on `GET /me` and `PATCH /v1/me`.

It lives on the user rather than the child, and on the existing routes rather than a
preferences endpoint of its own: one human decides when their own phone buzzes, and a client
that already reads `/me` on launch should not need a second call to learn whether it did.
"""

from __future__ import annotations

import datetime as dt

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_user
from helpers import auth_headers
from rascal.constants import DEFAULT_NOTIFY_LOCAL_TIME
from rascal.models import User


async def _stored(session: AsyncSession, user: User) -> sa.Row:
    return (
        await session.execute(
            sa.select(User.display_name, User.notify_enabled, User.notify_local_time).where(
                User.id == user.id
            )
        )
    ).one()


async def test_notifications_are_off_by_default(client: AsyncClient, session: AsyncSession) -> None:
    """The client turns this on *after* the parent grants OS permission, never before. A
    server that assumed consent it was never told about is how an app gets deleted."""
    user = await make_user(session)
    await session.commit()

    body = (await client.get("/v1/me", headers=auth_headers(user))).json()

    assert body["notify_enabled"] is False
    assert body["notify_local_time"] == DEFAULT_NOTIFY_LOCAL_TIME.isoformat()


async def test_a_user_can_turn_notifications_on(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_enabled": True}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    assert response.json()["notify_enabled"] is True
    assert (await _stored(session, user)).notify_enabled is True


async def test_a_user_can_choose_the_time(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_local_time": "08:30"}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    assert response.json()["notify_local_time"] == "08:30:00"
    assert (await _stored(session, user)).notify_local_time == dt.time(8, 30)


async def test_the_preference_can_be_set_without_resending_the_display_name(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A Settings screen toggling notifications must not have to know the user's name, and
    must not blank it by not sending one."""
    user = await make_user(session, display_name="Travis")
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_enabled": True}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    stored = await _stored(session, user)
    assert stored.display_name == "Travis"
    assert stored.notify_enabled is True


async def test_the_display_name_can_still_be_set_without_touching_the_preference(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The reverse, which is the case every existing client already does."""
    user = await make_user(session, notify_enabled=True, notify_local_time=dt.time(8, 30))
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"display_name": "Travis"}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    stored = await _stored(session, user)
    assert stored.display_name == "Travis"
    assert stored.notify_enabled is True
    assert stored.notify_local_time == dt.time(8, 30)


async def test_an_empty_patch_changes_nothing(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session, display_name="Travis")
    await session.commit()

    response = await client.patch("/v1/me", json={}, headers=auth_headers(user))

    assert response.status_code == 200
    assert (await _stored(session, user)).display_name == "Travis"


async def test_a_time_carrying_a_utc_offset_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`19:00-04:00` is not a more precise way of saying 19:00. The value is read in the
    child's timezone, so an offset is a different and unanswerable request — and silently
    dropping it would set a time the parent did not choose."""
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_local_time": "19:00:00-04:00"}, headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "notify_local_time"
    assert (await _stored(session, user)).notify_local_time == DEFAULT_NOTIFY_LOCAL_TIME


async def test_seconds_are_dropped(client: AsyncClient, session: AsyncSession) -> None:
    """Nobody picks a second, and the column would faithfully keep whatever was sent."""
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_local_time": "19:00:45"}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    assert (await _stored(session, user)).notify_local_time == dt.time(19, 0)


async def test_an_explicit_null_preference_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Neither column is nullable, so "clear it" is not a request that can be honoured."""
    user = await make_user(session, notify_enabled=True)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_enabled": None}, headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert (await _stored(session, user)).notify_enabled is True


async def test_a_nonsense_time_is_refused(client: AsyncClient, session: AsyncSession) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.patch(
        "/v1/me", json={"notify_local_time": "half past seven"}, headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert (await _stored(session, user)).notify_local_time == DEFAULT_NOTIFY_LOCAL_TIME


async def test_there_is_no_separate_preferences_endpoint() -> None:
    """The preference is part of the user object, on the routes that already carry it."""
    from rascal.config import get_settings
    from rascal.main import create_app

    paths = set(create_app(get_settings()).openapi()["paths"])

    assert "/v1/me" in paths
    assert "/v1/devices" in paths
    assert not any("preferences" in path for path in paths)
