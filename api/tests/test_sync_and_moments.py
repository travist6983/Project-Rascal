"""Sync, On This Day, the prompts admin routes, and the error shape."""

from __future__ import annotations

import datetime as dt
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Entry


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    await session.commit()
    return user, child


async def _entry(client: AsyncClient, user, child, **overrides) -> dict:
    payload = {
        "id": str(uuid.uuid4()),
        "child_id": str(child.id),
        "occurred_at": "2026-08-14T18:22:00Z",
        "body": "something",
        "entry_type": "text",
        "tags": [],
    }
    payload.update(overrides)
    return (await client.post("/v1/entries", json=payload, headers=auth_headers(user))).json()


# --- Sync pull ---------------------------------------------------------------------------


async def test_a_full_pull_returns_every_entity(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt)
    await session.commit()
    await _entry(client, user, child, assignment_id=str(assignment.id), tags=["his-words"])

    response = await client.get(
        "/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    assert response.status_code == 200
    body = response.json()
    assert len(body["entries"]) == 1
    assert len(body["assignments"]) == 1
    assert [tag["name"] for tag in body["tags"]] == ["his-words"]
    assert body["cursor"] is not None


async def test_a_pull_since_a_cursor_returns_only_what_changed(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _entry(client, user, child, body="first")

    first = (
        await client.get("/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user))
    ).json()

    await _entry(client, user, child, body="second")
    second = (
        await client.get(
            "/v1/sync",
            params={"child_id": str(child.id), "since": first["cursor"]},
            headers=auth_headers(user),
        )
    ).json()

    assert [entry["body"] for entry in second["entries"]] == ["second"]


async def test_a_deleted_entry_arrives_as_a_row_not_an_absence(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A client cannot infer a delete from a missing record."""
    user, child = await _world(session)
    created = await _entry(client, user, child)
    checkpoint = (
        await client.get("/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user))
    ).json()["cursor"]

    await client.delete(f"/v1/entries/{created['id']}", headers=auth_headers(user))

    body = (
        await client.get(
            "/v1/sync",
            params={"child_id": str(child.id), "since": checkpoint},
            headers=auth_headers(user),
        )
    ).json()

    assert [entry["id"] for entry in body["entries"]] == [created["id"]]
    assert body["entries"][0]["deleted_at"] is not None


async def test_an_untagged_link_syncs_with_deleted_at_set(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    created = await _entry(client, user, child, tags=["humor", "food"])
    await client.patch(
        f"/v1/entries/{created['id']}", json={"tags": ["humor"]}, headers=auth_headers(user)
    )

    body = (
        await client.get("/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user))
    ).json()

    by_name = {tag["name"]: tag for tag in body["tags"]}
    assert by_name["food"]["deleted_at"] is not None
    assert by_name["humor"]["deleted_at"] is None


async def test_sync_is_scoped_to_one_child(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    other = await make_child(session, name="Sibling")
    await grant(session, user, other, "parent")
    await session.commit()

    await _entry(client, user, child, body="mine")
    await _entry(client, user, other, body="theirs")

    body = (
        await client.get("/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user))
    ).json()
    assert [entry["body"] for entry in body["entries"]] == ["mine"]


# --- Sync push ---------------------------------------------------------------------------


async def test_push_creates_entries_the_server_has_never_seen(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    record_id = str(uuid.uuid4())

    response = await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [
                {
                    "id": record_id,
                    "child_id": str(child.id),
                    "occurred_at": "2026-08-14T18:22:00Z",
                    "body": "logged on the subway",
                    "entry_type": "text",
                }
            ],
            "media": [],
            "idempotency_keys": {record_id: str(uuid.uuid4())},
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert response.json()["entries"] == [{"id": record_id, "status": "accepted", "reason": None}]
    stored = await session.get(Entry, uuid.UUID(record_id))
    assert stored.body == "logged on the subway"
    # The server computed the age, even for a record it never saw created.
    assert stored.child_age_months == 50


async def test_push_is_last_write_wins_on_an_existing_entry(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    created = await _entry(client, user, child, body="the old text")

    await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [
                {
                    "id": created["id"],
                    "child_id": str(child.id),
                    "occurred_at": created["occurred_at"],
                    "body": "the edit made on the phone",
                    "entry_type": "text",
                }
            ],
        },
        headers=auth_headers(user),
    )

    stored = await session.get(Entry, uuid.UUID(created["id"]))
    await session.refresh(stored)
    assert stored.body == "the edit made on the phone"


async def test_a_replayed_push_batch_applies_nothing_twice(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    record_id = str(uuid.uuid4())
    payload = {
        "child_id": str(child.id),
        "entries": [
            {
                "id": record_id,
                "child_id": str(child.id),
                "occurred_at": "2026-08-14T18:22:00Z",
                "body": "once",
                "entry_type": "text",
            }
        ],
        "idempotency_keys": {record_id: str(uuid.uuid4())},
    }

    first = await client.post("/v1/sync/push", json=payload, headers=auth_headers(user))
    second = await client.post("/v1/sync/push", json=payload, headers=auth_headers(user))

    assert first.json()["entries"] == second.json()["entries"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(Entry)) == 1


async def test_push_reports_a_conflict_per_record_without_failing_the_batch(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    good = str(uuid.uuid4())

    response = await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [
                {
                    "id": good,
                    "child_id": str(child.id),
                    "occurred_at": "2026-08-14T18:22:00Z",
                    "body": "fine",
                    "entry_type": "text",
                }
            ],
            "media": [
                {"id": str(uuid.uuid4()), "entry_id": str(uuid.uuid4())},
            ],
        },
        headers=auth_headers(user),
    )

    body = response.json()
    assert body["entries"][0]["status"] == "accepted"
    assert body["media"][0]["status"] == "conflict"
    assert body["media"][0]["reason"]


async def test_push_to_a_child_you_cannot_write_is_403(
    client: AsyncClient, session: AsyncSession
) -> None:
    _, child = await _world(session)
    grandparent = await make_user(session, display_name="Grandma")
    await grant(session, grandparent, child, "viewer")
    await session.commit()

    response = await client.post(
        "/v1/sync/push",
        json={"child_id": str(child.id), "entries": [], "media": []},
        headers=auth_headers(grandparent),
    )
    assert response.status_code == 403


# --- On This Day -------------------------------------------------------------------------


async def test_moments_groups_prior_years_by_years_ago(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _entry(client, user, child, occurred_at="2025-08-14T12:00:00Z", body="last year")
    await _entry(client, user, child, occurred_at="2024-08-14T12:00:00Z", body="two years ago")
    await _entry(client, user, child, occurred_at="2024-08-15T12:00:00Z", body="wrong day")

    body = (
        await client.get(
            f"/v1/children/{child.id}/moments",
            params={"date": "2026-08-14"},
            headers=auth_headers(user),
        )
    ).json()

    assert body["fallback"] is None
    assert [group["years_ago"] for group in body["groups"]] == [1, 2]
    assert [e["body"] for e in body["groups"][0]["entries"]] == ["last year"]
    assert [e["body"] for e in body["groups"][1]["entries"]] == ["two years ago"]


async def test_moments_falls_back_to_random_when_there_is_nothing(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The warm redirect, so the screen is never a void."""
    user, child = await _world(session)
    await _entry(client, user, child, occurred_at="2025-03-02T12:00:00Z", body="unrelated")

    body = (
        await client.get(
            f"/v1/children/{child.id}/moments",
            params={"date": "2026-08-14"},
            headers=auth_headers(user),
        )
    ).json()

    assert body["fallback"] == "random"
    assert body["groups"] == []
    assert [e["body"] for e in body["entries"]] == ["unrelated"]


async def test_moments_excludes_soft_deleted_entries(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    created = await _entry(client, user, child, occurred_at="2025-08-14T12:00:00Z")
    await client.delete(f"/v1/entries/{created['id']}", headers=auth_headers(user))

    body = (
        await client.get(
            f"/v1/children/{child.id}/moments",
            params={"date": "2026-08-14"},
            headers=auth_headers(user),
        )
    ).json()
    assert body["fallback"] == "random"
    assert body["entries"] == []


# --- Prompts -----------------------------------------------------------------------------


async def test_prompts_can_be_browsed_and_filtered(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _world(session)
    await make_prompt(session, kind="question", body="A question.")
    await make_prompt(
        session, kind="photo", completion_mode="media", body="A photo.", min_age_months=60
    )
    await session.commit()

    everything = await client.get("/v1/prompts", headers=auth_headers(user))
    assert everything.json()["total"] == 2

    by_kind = await client.get("/v1/prompts", params={"kind": "photo"}, headers=auth_headers(user))
    assert [p["body"] for p in by_kind.json()["prompts"]] == ["A photo."]

    by_age = await client.get("/v1/prompts", params={"age_months": 48}, headers=auth_headers(user))
    assert [p["body"] for p in by_age.json()["prompts"]] == ["A question."]


async def test_a_hand_authored_prompt_is_marked_as_user_sourced(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _world(session)

    response = await client.post(
        "/v1/prompts",
        json={
            "kind": "activity",
            "cadence": "daily",
            "completion_mode": "did_it",
            "body": "Let him pick the music the whole way there.",
            "theme": "humor",
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    assert response.json()["source"] == "user"


async def test_prompts_require_a_token(client: AsyncClient) -> None:
    assert (await client.get("/v1/prompts")).status_code == 401


# --- Error shape -------------------------------------------------------------------------


async def test_every_failure_uses_the_same_error_shape(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _world(session)

    for response in (
        await client.get("/v1/prompts"),
        await client.get(f"/v1/entries/{uuid.uuid4()}", headers=auth_headers(user)),
        await client.post("/v1/entries", json={"child_id": "nope"}, headers=auth_headers(user)),
    ):
        body = response.json()
        assert set(body) == {"error"}
        assert set(body["error"]) == {"code", "message", "field"}
        assert isinstance(body["error"]["code"], str)
        # No stack trace, no psycopg message.
        assert "Traceback" not in body["error"]["message"]


async def test_error_codes_are_the_documented_ones() -> None:
    """The table in docs/api-contract.md is the contract."""
    from rascal.errors import ErrorCode

    assert {str(code) for code in ErrorCode} == {
        "unauthenticated",
        "token_expired",
        "refresh_token_reused",
        "not_authorized",
        "not_found",
        "validation_failed",
        "assignment_expired",
        "upload_incomplete",
        "conflict",
        "internal_error",
    }
