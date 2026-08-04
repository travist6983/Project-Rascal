"""Authorization: one dependency, applied everywhere.

`parent` reads and writes, `viewer` reads only, and a stranger gets 403 — never 404, because
leaking existence is fine here and a wrong 404 sends you debugging the wrong thing.
"""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.deps import require_child_access
from rascal.errors import RascalError
from rascal.services.tokens import create_access_token


async def test_a_parent_passes_a_read_and_a_write_check(session: AsyncSession) -> None:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")

    read = await require_child_access(session, user, child.id, "viewer")
    write = await require_child_access(session, user, child.id, "parent")
    assert read.role == "parent"
    assert write.can_write is True


async def test_a_viewer_can_read_but_not_write(session: AsyncSession) -> None:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "viewer")

    access = await require_child_access(session, user, child.id, "viewer")
    assert access.can_write is False

    with pytest.raises(RascalError) as caught:
        await require_child_access(session, user, child.id, "parent")
    assert caught.value.status_code == 403
    assert caught.value.code == "not_authorized"


async def test_a_stranger_is_refused(session: AsyncSession) -> None:
    stranger = await make_user(session, display_name="Nobody")
    child = await make_child(session)

    with pytest.raises(RascalError) as caught:
        await require_child_access(session, stranger, child.id, "viewer")
    assert caught.value.status_code == 403


async def test_a_revoked_guardian_is_refused(session: AsyncSession) -> None:
    """Revoking access has to actually revoke it, not just record an intention."""
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent", revoked=True)

    with pytest.raises(RascalError) as caught:
        await require_child_access(session, user, child.id, "viewer")
    assert caught.value.status_code == 403


async def test_an_unknown_child_is_refused_not_disclosed(session: AsyncSession) -> None:
    user = await make_user(session)
    with pytest.raises(RascalError) as caught:
        await require_child_access(session, user, uuid.uuid4(), "viewer")
    # 403, not 404 — the caller learns nothing about whether the id exists.
    assert caught.value.status_code == 403


# --- Over HTTP ---------------------------------------------------------------------------


async def test_list_children_only_returns_children_the_caller_can_see(
    client: AsyncClient, session: AsyncSession
) -> None:
    mine = await make_user(session)
    theirs = await make_user(session, display_name="Someone else")
    my_child = await make_child(session, name="Miles")
    their_child = await make_child(session, name="Not mine")
    await grant(session, mine, my_child, "parent")
    await grant(session, theirs, their_child, "parent")
    await session.commit()

    response = await client.get("/v1/children", headers=auth_headers(mine))
    assert response.status_code == 200
    names = [row["name"] for row in response.json()]
    assert names == ["Miles"]


async def test_a_viewer_cannot_patch_a_child(client: AsyncClient, session: AsyncSession) -> None:
    grandparent = await make_user(session, display_name="Grandma")
    child = await make_child(session)
    await grant(session, grandparent, child, "viewer")
    await session.commit()

    response = await client.patch(
        f"/v1/children/{child.id}",
        json={"name": "Renamed"},
        headers=auth_headers(grandparent),
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "not_authorized"


async def test_a_stranger_gets_403_on_a_child_route(
    client: AsyncClient, session: AsyncSession
) -> None:
    stranger = await make_user(session, display_name="Nobody")
    child = await make_child(session)
    await session.commit()

    response = await client.patch(
        f"/v1/children/{child.id}", json={"name": "Mine now"}, headers=auth_headers(stranger)
    )
    assert response.status_code == 403


async def test_creating_a_child_makes_the_caller_its_parent(client: AsyncClient) -> None:
    session_body = (await client.post("/v1/auth/dev-login", json={})).json()
    headers = {"Authorization": f"Bearer {session_body['access_token']}"}

    created = await client.post(
        "/v1/children",
        json={"name": "Miles", "birthdate": "2022-06-14", "family_timezone": "America/Detroit"},
        headers=headers,
    )
    assert created.status_code == 201
    assert created.json()["role"] == "parent"

    listed = await client.get("/v1/children", headers=headers)
    assert [row["id"] for row in listed.json()] == [created.json()["id"]]


async def test_an_unknown_timezone_is_a_validation_error(client: AsyncClient) -> None:
    session_body = (await client.post("/v1/auth/dev-login", json={})).json()
    response = await client.post(
        "/v1/children",
        json={"name": "Miles", "birthdate": "2022-06-14", "family_timezone": "Mars/Olympus"},
        headers={"Authorization": f"Bearer {session_body['access_token']}"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_failed"


def test_an_access_token_is_short_lived() -> None:
    """15 minutes, per docs/api-contract.md."""
    _, expires_in = create_access_token(uuid.uuid4(), get_settings())
    assert expires_in == 15 * 60
