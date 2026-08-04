"""Entries: creation, idempotency, the three completion shapes, the timeline, soft delete."""

from __future__ import annotations

import datetime as dt
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Entry, EntryTag, Media, Tag


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    await session.commit()
    return user, child


def _entry_body(child, **overrides) -> dict:
    body = {
        "id": str(uuid.uuid4()),
        "child_id": str(child.id),
        "occurred_at": "2026-08-14T18:22:00Z",
        "body": "He called it a 'hangaburger' again.",
        "entry_type": "text",
        "tags": ["his-words"],
    }
    body.update(overrides)
    return body


# --- Creation ----------------------------------------------------------------------------


async def test_creating_an_entry_stores_the_age_the_server_computed(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    response = await client.post("/v1/entries", json=_entry_body(child), headers=auth_headers(user))

    assert response.status_code == 201
    body = response.json()
    # 2022-06-14 to 2026-08-14 is 50 completed months. The client never sends this.
    assert body["child_age_months"] == 50
    assert body["author_id"] == str(user.id)
    assert [tag["name"] for tag in body["tags"]] == ["his-words"]
    assert body["media"] == []
    assert body["media_count"] == 0


async def test_occurred_at_and_created_at_are_not_conflated(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A photo from 2023 added tonight has occurred_at in 2023 and created_at today."""
    user, child = await _world(session)

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, occurred_at="2023-11-02T15:00:00Z", entry_type="photo"),
        headers=auth_headers(user),
    )

    body = response.json()
    assert body["occurred_at"].startswith("2023-11-02")
    assert not body["created_at"].startswith("2023-11-02")
    # And the stored age follows occurred_at, not today.
    assert body["child_age_months"] == 16


async def test_a_did_it_entry_needs_no_media(client: AsyncClient, session: AsyncSession) -> None:
    """ "Get on the floor for ten minutes" is a complete, legitimate entry with no artifact."""
    user, child = await _world(session)
    prompt = await make_prompt(
        session,
        kind="activity",
        completion_mode="did_it",
        body="Get on the floor for ten minutes. That's the whole mission.",
    )
    assignment = await make_assignment(session, child, prompt, slot="mission")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(
            child,
            assignment_id=str(assignment.id),
            body=None,
            entry_type=None,
            tags=[],
        ),
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    body = response.json()
    assert body["media"] == []
    assert body["body"] is None
    # entry_type is denormalized from the prompt when the client omits it.
    assert body["entry_type"] == "activity"


async def test_completing_a_pending_assignment_flips_it_to_done(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt)
    await session.commit()

    await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )

    await session.refresh(assignment)
    assert assignment.status == "done"
    assert assignment.completed_by == user.id


async def test_an_already_dismissed_assignment_still_accepts_an_entry(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The archive matters more than the bookkeeping."""
    user, child = await _world(session)
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt, status="dismissed")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    await session.refresh(assignment)
    assert assignment.status == "dismissed"  # left alone


async def test_a_letter_prompt_seals_the_entry_by_default(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(
        session,
        kind="letter",
        cadence="monthly",
        completion_mode="text",
        default_unlock_age=18,
        body="Write him something about money.",
    )
    assignment = await make_assignment(session, child, prompt, slot="monthly")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id), entry_type=None),
        headers=auth_headers(user),
    )
    assert response.json()["unlock_at_age"] == 18


async def test_an_assignment_for_another_child_is_rejected(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    other = await make_child(session, name="Someone else")
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, other, prompt)
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )
    assert response.status_code == 422
    assert response.json()["error"]["field"] == "assignment_id"


# --- Idempotency -------------------------------------------------------------------------


async def test_a_replay_returns_the_original_body_and_creates_no_second_row(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    payload = _entry_body(child)
    headers = {**auth_headers(user), "Idempotency-Key": str(uuid.uuid4())}

    first = await client.post("/v1/entries", json=payload, headers=headers)
    second = await client.post("/v1/entries", json=payload, headers=headers)

    assert first.status_code == 201
    assert second.status_code == 201  # never a 409
    assert second.json() == first.json()  # byte-for-byte
    assert await session.scalar(sa.select(sa.func.count()).select_from(Entry)) == 1


async def test_an_idempotency_key_is_scoped_to_the_user(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    other = await make_user(session, display_name="Second parent")
    await grant(session, other, child, "parent")
    await session.commit()

    key = str(uuid.uuid4())
    await client.post(
        "/v1/entries",
        json=_entry_body(child),
        headers={**auth_headers(user), "Idempotency-Key": key},
    )
    second = await client.post(
        "/v1/entries",
        json=_entry_body(child),
        headers={**auth_headers(other), "Idempotency-Key": key},
    )

    assert second.status_code == 201
    assert await session.scalar(sa.select(sa.func.count()).select_from(Entry)) == 2


async def test_reusing_an_entry_id_without_a_key_is_a_conflict(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    payload = _entry_body(child)

    await client.post("/v1/entries", json=payload, headers=auth_headers(user))
    again = await client.post("/v1/entries", json=payload, headers=auth_headers(user))

    assert again.status_code == 409
    assert again.json()["error"]["code"] == "conflict"


# --- Timeline ----------------------------------------------------------------------------


async def _seed_timeline(client: AsyncClient, user, child, count: int) -> list[str]:
    ids = []
    for index in range(count):
        occurred = dt.datetime(2026, 1, 1, tzinfo=dt.UTC) + dt.timedelta(days=index)
        response = await client.post(
            "/v1/entries",
            json=_entry_body(
                child,
                occurred_at=occurred.isoformat().replace("+00:00", "Z"),
                body=f"entry {index}",
                tags=[],
            ),
            headers=auth_headers(user),
        )
        ids.append(response.json()["id"])
    return ids


async def test_the_timeline_is_newest_first_by_occurred_at(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _seed_timeline(client, user, child, 3)

    response = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )
    bodies = [entry["body"] for entry in response.json()["entries"]]
    assert bodies == ["entry 2", "entry 1", "entry 0"]


async def test_a_backdated_entry_lands_in_the_middle_of_the_order(
    client: AsyncClient, session: AsyncSession
) -> None:
    """This is why the cursor is keyset on (occurred_at, id) and never an OFFSET."""
    user, child = await _world(session)
    await _seed_timeline(client, user, child, 3)
    await client.post(
        "/v1/entries",
        json=_entry_body(child, occurred_at="2026-01-02T12:00:00Z", body="backdated", tags=[]),
        headers=auth_headers(user),
    )

    response = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )
    bodies = [entry["body"] for entry in response.json()["entries"]]
    assert bodies == ["entry 2", "backdated", "entry 1", "entry 0"]


async def test_paging_walks_every_entry_exactly_once(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _seed_timeline(client, user, child, 7)

    seen: list[str] = []
    cursor = None
    for _ in range(10):
        params = {"child_id": str(child.id), "limit": 3}
        if cursor:
            params["cursor"] = cursor
        page = (await client.get("/v1/entries", params=params, headers=auth_headers(user))).json()
        seen.extend(entry["id"] for entry in page["entries"])
        cursor = page["next_cursor"]
        if not cursor:
            break

    assert len(seen) == 7
    assert len(set(seen)) == 7


async def test_media_summaries_come_inline_with_no_extra_call(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    [entry_id] = await _seed_timeline(client, user, child, 1)
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=uuid.UUID(entry_id),
            s3_key="children/x/y.jpg",
            kind="photo",
            bytes=2048,
            duration_seconds=None,
            upload_status="complete",
        )
    )
    await session.commit()

    page = (
        await client.get(
            "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
        )
    ).json()
    [entry] = page["entries"]
    assert entry["media_count"] == 1
    assert entry["media"][0]["s3_key"] == "children/x/y.jpg"
    assert entry["media"][0]["thumb_key"] is None  # generation is out of P0 scope


async def test_filters_narrow_the_timeline(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="a photo day", entry_type="photo", tags=["outdoors"]),
        headers=auth_headers(user),
    )
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="a written day", entry_type="text", tags=[]),
        headers=auth_headers(user),
    )
    headers = auth_headers(user)

    by_type = await client.get(
        "/v1/entries", params={"child_id": str(child.id), "type": "photo"}, headers=headers
    )
    assert [e["body"] for e in by_type.json()["entries"]] == ["a photo day"]

    by_tag = await client.get(
        "/v1/entries", params={"child_id": str(child.id), "tag": "outdoors"}, headers=headers
    )
    assert [e["body"] for e in by_tag.json()["entries"]] == ["a photo day"]

    by_query = await client.get(
        "/v1/entries", params={"child_id": str(child.id), "q": "written"}, headers=headers
    )
    assert [e["body"] for e in by_query.json()["entries"]] == ["a written day"]


async def test_a_bad_cursor_is_a_validation_error(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    response = await client.get(
        "/v1/entries",
        params={"child_id": str(child.id), "cursor": "not-a-cursor"},
        headers=auth_headers(user),
    )
    assert response.status_code == 422
    assert response.json()["error"]["field"] == "cursor"


# --- Detail, update, delete --------------------------------------------------------------


async def test_entry_detail_includes_the_originating_prompt(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, body="Describe his laugh.")
    assignment = await make_assignment(session, child, prompt)
    await session.commit()

    created = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )
    detail = await client.get(f"/v1/entries/{created.json()['id']}", headers=auth_headers(user))

    assert detail.status_code == 200
    assert detail.json()["prompt"]["body"] == "Describe his laugh."


async def test_editing_occurred_at_recomputes_the_stored_age(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    created = await client.post("/v1/entries", json=_entry_body(child), headers=auth_headers(user))
    entry_id = created.json()["id"]

    patched = await client.patch(
        f"/v1/entries/{entry_id}",
        json={"occurred_at": "2024-06-14T12:00:00Z"},
        headers=auth_headers(user),
    )
    assert patched.json()["child_age_months"] == 24


async def test_editing_tags_soft_deletes_the_link_it_removed(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Untagging has to sync as a row, not as an absence."""
    user, child = await _world(session)
    created = await client.post(
        "/v1/entries",
        json=_entry_body(child, tags=["his-words", "humor"]),
        headers=auth_headers(user),
    )
    entry_id = created.json()["id"]

    patched = await client.patch(
        f"/v1/entries/{entry_id}", json={"tags": ["humor"]}, headers=auth_headers(user)
    )
    assert [tag["name"] for tag in patched.json()["tags"]] == ["humor"]

    links = (
        (await session.execute(sa.select(EntryTag).where(EntryTag.entry_id == uuid.UUID(entry_id))))
        .scalars()
        .all()
    )
    assert len(links) == 2
    assert sum(1 for link in links if link.deleted_at is not None) == 1
    # The tag itself survives — it is vocabulary, not user content.
    assert await session.scalar(sa.select(sa.func.count()).select_from(Tag)) == 2


async def test_delete_is_soft_and_takes_the_media_with_it(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    created = await client.post("/v1/entries", json=_entry_body(child), headers=auth_headers(user))
    entry_id = uuid.UUID(created.json()["id"])
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry_id,
            s3_key="children/x/y.m4a",
            kind="audio",
            bytes=1024,
            upload_status="complete",
        )
    )
    await session.commit()

    assert (
        await client.delete(f"/v1/entries/{entry_id}", headers=auth_headers(user))
    ).status_code == 204

    entry = await session.get(Entry, entry_id)
    await session.refresh(entry)
    assert entry.deleted_at is not None  # the row stays

    media = (await session.execute(sa.select(Media))).scalars().all()
    assert all(item.deleted_at is not None for item in media)

    page = (
        await client.get(
            "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
        )
    ).json()
    assert page["entries"] == []


async def test_a_deleted_entry_is_a_404_on_read(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    created = await client.post("/v1/entries", json=_entry_body(child), headers=auth_headers(user))
    entry_id = created.json()["id"]
    await client.delete(f"/v1/entries/{entry_id}", headers=auth_headers(user))

    response = await client.get(f"/v1/entries/{entry_id}", headers=auth_headers(user))
    assert response.status_code == 404
