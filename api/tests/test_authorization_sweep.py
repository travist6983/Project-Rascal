"""A second user with no `guardians` row gets 403 on every child-scoped endpoint.

Including the ones that reach the child indirectly — through an entry id, a media id, or an
assignment id. This is the test that catches a route someone forgot to wire to `deps.py`.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Entry, Media


async def _populated(session: AsyncSession) -> dict:
    """A child with an assignment, an entry, and a media row, all owned by one parent."""
    owner = await make_user(session, display_name="The parent")
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, owner, child, "parent")

    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt, assigned_on=dt.date(2026, 8, 4))

    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=owner.id,
        occurred_at=dt.datetime(2026, 8, 4, tzinfo=dt.UTC),
        child_age_months=50,
        entry_type="text",
        body="private",
    )
    session.add(entry)
    await session.flush()

    media = Media(
        id=uuid.uuid4(),
        entry_id=entry.id,
        s3_key="children/x/y.m4a",
        kind="audio",
        bytes=1024,
        upload_status="complete",
    )
    session.add(media)

    stranger = await make_user(session, display_name="Nobody")
    await session.commit()
    return {
        "owner": owner,
        "child": child,
        "prompt": prompt,
        "assignment": assignment,
        "entry": entry,
        "media": media,
        "stranger": stranger,
    }


def _requests(world: dict) -> list[tuple[str, str, dict | None]]:
    """Every child-scoped route, keyed by how it reaches the child."""
    child_id = world["child"].id
    entry_id = world["entry"].id
    media_id = world["media"].id
    assignment_id = world["assignment"].id
    prompt_id = world["prompt"].id
    return [
        # Reached by a child id in the path.
        ("PATCH", f"/v1/children/{child_id}", {"name": "Mine now"}),
        ("GET", f"/v1/children/{child_id}/today", None),
        ("GET", f"/v1/children/{child_id}/moments", None),
        ("POST", f"/v1/children/{child_id}/recompute-ages", None),
        # The child's face. Bodies here are valid on purpose — a payload that 422s before the
        # dependency runs would make this row assert nothing about authorization.
        (
            "POST",
            f"/v1/children/{child_id}/avatar-upload-url",
            {"content_type": "image/jpeg", "bytes": 1024},
        ),
        ("GET", f"/v1/children/{child_id}/avatar-url", None),
        # "Stop asking me this" — a write, its undo, and the list of both.
        (
            "POST",
            f"/v1/children/{child_id}/prompt-suppressions",
            {"prompt_id": str(prompt_id), "reason": "mine now"},
        ),
        ("DELETE", f"/v1/children/{child_id}/prompt-suppressions/{prompt_id}", None),
        ("GET", f"/v1/children/{child_id}/prompt-suppressions", None),
        ("GET", f"/v1/children/{child_id}/pool-health", None),
        # Reached by a child id in the query string.
        ("GET", f"/v1/entries?child_id={child_id}", None),
        ("GET", f"/v1/sync?child_id={child_id}", None),
        # Reached by a child id in the body.
        (
            "POST",
            "/v1/entries",
            {
                "id": str(uuid.uuid4()),
                "child_id": str(child_id),
                "occurred_at": "2026-08-14T18:22:00Z",
                "body": "mine now",
            },
        ),
        ("POST", "/v1/sync/push", {"child_id": str(child_id), "entries": [], "media": []}),
        # Reached indirectly, through an entry id.
        ("GET", f"/v1/entries/{entry_id}", None),
        ("PATCH", f"/v1/entries/{entry_id}", {"title": "mine now"}),
        ("DELETE", f"/v1/entries/{entry_id}", None),
        (
            "POST",
            "/v1/media/upload-url",
            {
                "entry_id": str(entry_id),
                "kind": "photo",
                "filename": "x.jpg",
                "bytes": 100,
                "content_type": "image/jpeg",
            },
        ),
        # Reached indirectly, through a media id.
        ("POST", f"/v1/media/{media_id}/complete", {}),
        ("PATCH", f"/v1/media/{media_id}/derived", {"transcript": "mine now"}),
        # Reached indirectly, through an assignment id.
        ("POST", f"/v1/assignments/{assignment_id}/dismiss", None),
        ("POST", f"/v1/assignments/{assignment_id}/custom", {"body": "mine now"}),
    ]


async def _call(client: AsyncClient, method: str, url: str, body: dict | None, headers: dict):
    if body is None:
        return await client.request(method, url, headers=headers)
    return await client.request(method, url, json=body, headers=headers)


async def test_a_stranger_gets_403_on_every_child_scoped_endpoint(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _populated(session)
    headers = auth_headers(world["stranger"])

    failures = []
    for method, url, body in _requests(world):
        response = await _call(client, method, url, body, headers)
        if response.status_code != 403:
            failures.append(f"{method} {url} -> {response.status_code} {response.text[:120]}")

    assert not failures, "these routes did not refuse a stranger:\n" + "\n".join(failures)


async def test_every_child_scoped_endpoint_also_refuses_an_anonymous_caller(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _populated(session)

    failures = []
    for method, url, body in _requests(world):
        response = await _call(client, method, url, body, {})
        if response.status_code != 401:
            failures.append(f"{method} {url} -> {response.status_code}")

    assert not failures, "these routes did not require a token:\n" + "\n".join(failures)


@pytest.mark.parametrize(
    ("method", "url_key", "body"),
    [
        ("PATCH", "child", {"name": "Renamed"}),
        ("POST", "entry", None),
    ],
)
async def test_a_viewer_reads_but_never_writes(
    client: AsyncClient, session: AsyncSession, method: str, url_key: str, body: dict | None
) -> None:
    world = await _populated(session)
    viewer = await make_user(session, display_name="Grandma")
    await grant(session, viewer, world["child"], "viewer")
    await session.commit()
    headers = auth_headers(viewer)

    # Reads are fine.
    assert (
        await client.get(f"/v1/children/{world['child'].id}/today", headers=headers)
    ).status_code == 200
    assert (
        await client.get(f"/v1/entries/{world['entry'].id}", headers=headers)
    ).status_code == 200

    # Writes are not.
    if url_key == "child":
        refused = await client.patch(
            f"/v1/children/{world['child'].id}", json=body, headers=headers
        )
    else:
        refused = await client.post(
            "/v1/entries",
            json={
                "id": str(uuid.uuid4()),
                "child_id": str(world["child"].id),
                "occurred_at": "2026-08-14T18:22:00Z",
                "body": "not allowed",
            },
            headers=headers,
        )
    assert refused.status_code == 403
    assert refused.json()["error"]["code"] == "not_authorized"


async def test_a_revoked_guardian_loses_access_to_everything(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _populated(session)
    former = await make_user(session, display_name="Was a parent")
    await grant(session, former, world["child"], "parent", revoked=True)
    await session.commit()
    headers = auth_headers(former)

    for method, url, body in _requests(world):
        response = await _call(client, method, url, body, headers)
        assert response.status_code == 403, f"{method} {url}"


# --- The route must not answer "does this exist?" -------------------------------------------


async def test_an_id_that_exists_is_indistinguishable_from_one_that_does_not(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A stranger must not be able to tell a real child from an invented one.

    Every row above proves a stranger is refused. None of them proves the *refusal* says
    nothing — and a route that answers 403 for a real child and 404 for a made-up one is an
    enumeration oracle: walk it and you learn which ids are real, which is a membership fact
    about somebody else's household.

    **The code already behaves correctly and `docs/api-contract.md` used to say it did not.**
    The contract justified always-403 on the grounds that *"leaking existence is fine here"* —
    describing a weaker property than the code has. That sentence is the risk this test exists
    to close: it reads as licence, and the plausible ticket ("a 404 for an unknown id would
    make debugging clearer") arrives with the contract already agreeing. Nothing else in the
    suite would have failed.
    """
    world = await _populated(session)
    stranger = world["stranger"]
    await session.commit()
    headers = auth_headers(stranger)

    real = uuid.UUID(str(world["child"].id))
    invented = uuid.uuid4()

    for template in (
        "/v1/children/{id}/stats",
        "/v1/children/{id}/moments",
        "/v1/children/{id}/pool-health",
        "/v1/children/{id}/prompt-suppressions",
    ):
        exists = await client.get(template.format(id=real), headers=headers)
        does_not = await client.get(template.format(id=invented), headers=headers)
        assert exists.status_code == does_not.status_code == 403, template
        assert (
            exists.json()["error"]["code"] == does_not.json()["error"]["code"] == "not_authorized"
        ), template


async def test_an_invented_household_is_indistinguishable_from_somebody_elses(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The same property on the newest forgeable-id route, which returns billing state.

    `GET /families/{id}/entitlement` takes a household id from the caller and answers with the
    tier and the computed deletion-eligibility date. `test_app_store.py` pins that another
    household's id is 403; nothing pinned that an id belonging to *nobody* is the same 403,
    which is the half that makes it not an oracle.
    """
    mine = await make_user(session, display_name="Mine")
    theirs = await make_user(session, display_name="Theirs")
    await session.commit()
    headers = auth_headers(mine)

    somebody_elses = await client.get(
        f"/v1/families/{theirs.family_id}/entitlement", headers=headers
    )
    nobodys = await client.get(f"/v1/families/{uuid.uuid4()}/entitlement", headers=headers)

    assert somebody_elses.status_code == nobodys.status_code == 403
    assert (
        somebody_elses.json()["error"]["code"]
        == nobodys.json()["error"]["code"]
        == "not_authorized"
    )
