"""The Today screen, and the two actions it can take."""

from __future__ import annotations

import datetime as dt
import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers

# **A date in the past, and that is the whole point of it.**
#
# This was `2026-08-14`, which was comfortably in the future when it was written and arrived on
# 14 Aug 2026. `GET /today` self-heals: when the requested date *is* the child's current date,
# `ensure_day_filled` mints the day's missing slots before answering. So for the eleven days this
# constant was in the future these tests asserted a board nothing had filled — and on the one day
# it matched, the fill ran, minted the `mission_b` migration 0008 added, and the suite went red
# having never once exercised what it claimed to.
#
# A fixture date in the past cannot become today again, so the read path is all these tests see.
# Filling has its own file — `test_today_self_healing.py` — and that is where it belongs.
TODAY = dt.date(2026, 8, 4)


async def _world(session: AsyncSession, timezone: str = "America/Detroit"):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14), timezone=timezone)
    await grant(session, user, child, "parent")
    return user, child


async def test_today_returns_today_waiting_and_done_in_one_call(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    question = await make_prompt(session, kind="question", body="Describe his laugh.")
    mission = await make_prompt(
        session, kind="audio", completion_mode="media", body="Record him singing."
    )
    stale = await make_prompt(session, kind="photo", completion_mode="media", body="Old one.")

    await make_assignment(session, child, question, slot="question", assigned_on=TODAY)
    await make_assignment(session, child, mission, slot="mission", assigned_on=TODAY)
    await make_assignment(
        session, child, stale, slot="mission", assigned_on=TODAY - dt.timedelta(days=3)
    )
    await session.commit()

    response = await client.get(
        f"/v1/children/{child.id}/today",
        params={"date": TODAY.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["date"] == TODAY.isoformat()
    # 2022-06-14 to 2026-08-04 is 49 completed months.
    assert body["child"]["age_months"] == 49
    assert {item["slot"] for item in body["today"]} == {"question", "mission"}
    assert [item["body"] for item in body["waiting"]] == ["Old one."]
    assert body["done_today"] == []


async def test_waiting_is_oldest_first(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    older = await make_prompt(session, kind="photo", completion_mode="media", body="older")
    newer = await make_prompt(session, kind="photo", completion_mode="media", body="newer")
    await make_assignment(
        session, child, older, slot="mission", assigned_on=TODAY - dt.timedelta(days=5)
    )
    await make_assignment(
        session, child, newer, slot="mission", assigned_on=TODAY - dt.timedelta(days=1)
    )
    await session.commit()

    body = (
        await client.get(
            f"/v1/children/{child.id}/today",
            params={"date": TODAY.isoformat()},
            headers=auth_headers(user),
        )
    ).json()
    assert [item["body"] for item in body["waiting"]] == ["older", "newer"]


async def test_a_custom_body_wins_over_the_prompt_it_replaced(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, body="The library version.")
    assignment = await make_assignment(session, child, prompt, assigned_on=TODAY)
    await session.commit()

    await client.post(
        f"/v1/assignments/{assignment.id}/custom",
        json={"body": "Ask him about the fish he saw."},
        headers=auth_headers(user),
    )

    body = (
        await client.get(
            f"/v1/children/{child.id}/today",
            params={"date": TODAY.isoformat()},
            headers=auth_headers(user),
        )
    ).json()
    [item] = body["today"]
    assert item["body"] == "Ask him about the fish he saw."
    assert item["is_custom"] is True


async def test_a_dismissed_item_leaves_the_screen(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt, assigned_on=TODAY)
    await session.commit()

    dismissed = await client.post(
        f"/v1/assignments/{assignment.id}/dismiss", headers=auth_headers(user)
    )
    assert dismissed.json()["status"] == "dismissed"

    body = (
        await client.get(
            f"/v1/children/{child.id}/today",
            params={"date": TODAY.isoformat()},
            headers=auth_headers(user),
        )
    ).json()
    assert body["today"] == []
    assert body["waiting"] == []


async def test_completing_an_assignment_moves_it_into_done_today(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, body="Describe his laugh.")
    assignment = await make_assignment(session, child, prompt, assigned_on=TODAY)
    await session.commit()

    await client.post(
        "/v1/entries",
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(assignment.id),
            "occurred_at": "2026-08-04T18:22:00Z",
            "body": "Like a hiccup with a cough on the end.",
        },
        headers=auth_headers(user),
    )

    body = (
        await client.get(
            f"/v1/children/{child.id}/today",
            params={"date": TODAY.isoformat()},
            headers=auth_headers(user),
        )
    ).json()
    assert body["today"] == []
    assert [item["body"] for item in body["done_today"]] == ["Describe his laugh."]


async def test_an_entry_from_another_day_is_not_done_today(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session)
    assignment = await make_assignment(
        session, child, prompt, assigned_on=TODAY - dt.timedelta(days=2)
    )
    await session.commit()

    await client.post(
        "/v1/entries",
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "assignment_id": str(assignment.id),
            "occurred_at": "2026-08-12T18:22:00Z",
            "body": "two days ago",
        },
        headers=auth_headers(user),
    )

    body = (
        await client.get(
            f"/v1/children/{child.id}/today",
            params={"date": TODAY.isoformat()},
            headers=auth_headers(user),
        )
    ).json()
    assert body["done_today"] == []
    assert body["waiting"] == []  # it is done, so it is not waiting either


async def test_today_is_computed_in_the_family_timezone(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Without the date override, the server picks the child's local date, not UTC's."""
    user, child = await _world(session, timezone="Pacific/Auckland")
    await session.commit()

    body = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()

    from rascal.services.dates import today_in

    assert body["date"] == today_in("Pacific/Auckland").isoformat()


async def test_a_viewer_cannot_dismiss(client: AsyncClient, session: AsyncSession) -> None:
    _, child = await _world(session)
    grandparent = await make_user(session, display_name="Grandma")
    await grant(session, grandparent, child, "viewer")
    prompt = await make_prompt(session)
    assignment = await make_assignment(session, child, prompt, assigned_on=TODAY)
    await session.commit()

    refused = await client.post(
        f"/v1/assignments/{assignment.id}/dismiss", headers=auth_headers(grandparent)
    )
    assert refused.status_code == 403

    # But they can still read the screen.
    allowed = await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(grandparent))
    assert allowed.status_code == 200


async def test_an_unknown_assignment_is_a_404(client: AsyncClient, session: AsyncSession) -> None:
    user, _ = await _world(session)
    await session.commit()
    response = await client.post(
        f"/v1/assignments/{uuid.uuid4()}/dismiss", headers=auth_headers(user)
    )
    assert response.status_code == 404
