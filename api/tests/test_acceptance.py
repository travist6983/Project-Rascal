"""The acceptance test.

The exact sequence from the task's definition of done, through the API, with dev-login auth
and nothing else:

    dev-login -> create a child -> run the scheduler for an arbitrary date -> GET /today
    -> complete one assignment with a text entry -> complete another with a did_it entry
    -> see both in GET /entries

If this passes, the daily loop works end to end.
"""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.services.seeding import seed_prompts

# A Saturday *and* the 15th, so the weekly and letter slots both fire and the run is the
# fullest day the scheduler can produce rather than the simplest.
RUN_DATE = "2026-08-15"


async def test_the_whole_daily_loop_through_the_api(
    client: AsyncClient, session: AsyncSession
) -> None:
    # The real mission library, loaded the way `make seed` loads it.
    await seed_prompts(session)

    # 1. Auth, with no Apple Developer enrollment in sight.
    signed_in = await client.post(
        "/v1/auth/dev-login", json={"email": "travis@example.com", "display_name": "Travis"}
    )
    assert signed_in.status_code == 200
    headers = {"Authorization": f"Bearer {signed_in.json()['access_token']}"}

    # 2. Create a child.
    created = await client.post(
        "/v1/children",
        json={
            "name": "Miles",
            "birthdate": "2022-06-14",
            "family_timezone": "America/Detroit",
        },
        headers=headers,
    )
    assert created.status_code == 201
    child_id = created.json()["id"]
    assert created.json()["role"] == "parent"
    assert created.json()["age_months"] >= 48

    # 3. Run the scheduler for an arbitrary date.
    scheduled = await client.post(
        "/v1/debug/scheduler/run",
        json={"date": RUN_DATE, "child_id": child_id, "seed": 20260815},
        headers=headers,
    )
    assert scheduled.status_code == 200
    # question + mission + mission_b + weekly (Saturday) + letter (the 15th).
    #
    # 2026-08-15 is both, which makes this the five-item day: the three daily slots now fire
    # underneath the two occasional ones, and none of them is suppressed to keep the count
    # down. This is the worst case the calendar can produce and it is deliberate — see
    # docs/decisions.md.
    assert scheduled.json()["created"] == 5
    assert scheduled.json()["exhausted"] == []

    # Rerunning is free — that is what the unique index is for.
    again = await client.post(
        "/v1/debug/scheduler/run",
        json={"date": RUN_DATE, "child_id": child_id},
        headers=headers,
    )
    assert again.json()["created"] == 0

    # 4. Fetch /today.
    today = await client.get(
        f"/v1/children/{child_id}/today", params={"date": RUN_DATE}, headers=headers
    )
    assert today.status_code == 200
    screen = today.json()
    assert screen["date"] == RUN_DATE
    assert screen["child"]["name"] == "Miles"
    assert screen["child"]["age_months"] == 50
    assert {item["slot"] for item in screen["today"]} == {
        "question",
        "mission",
        "mission_b",
        "weekly",
        "letter",
    }
    assert screen["waiting"] == []
    assert screen["done_today"] == []

    by_slot = {item["slot"]: item for item in screen["today"]}
    for item in screen["today"]:
        assert item["status"] == "pending"
        assert item["body"]  # custom_body resolved over prompt.body
        assert item["expires_on"] == "2026-08-29"  # assigned_on + 14

    # 5. Complete the question with a text entry.
    question = by_slot["question"]
    text_entry_id = str(uuid.uuid4())
    text_entry = await client.post(
        "/v1/entries",
        json={
            "id": text_entry_id,
            "child_id": child_id,
            "assignment_id": question["id"],
            "occurred_at": "2026-08-15T19:04:00Z",
            "body": "He called it a 'hangaburger' again, and corrected me when I said it right.",
            "tags": ["his-words"],
        },
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
    )
    assert text_entry.status_code == 201
    assert text_entry.json()["child_age_months"] == 50  # server-computed, not sent
    assert text_entry.json()["media"] == []

    # 6. Complete the mission with a did_it entry — no artifact, and still a complete entry.
    mission = by_slot["mission"]
    did_it_entry_id = str(uuid.uuid4())
    did_it_entry = await client.post(
        "/v1/entries",
        json={
            "id": did_it_entry_id,
            "child_id": child_id,
            "assignment_id": mission["id"],
            "occurred_at": "2026-08-15T20:30:00Z",
        },
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
    )
    assert did_it_entry.status_code == 201
    assert did_it_entry.json()["body"] is None
    assert did_it_entry.json()["media"] == []
    assert did_it_entry.json()["media_count"] == 0
    # No artifact and no words, so the type says exactly that — whatever was asked.
    assert did_it_entry.json()["entry_type"] == "did_it"

    # 7. Both show up in the timeline, newest first by occurred_at.
    timeline = await client.get("/v1/entries", params={"child_id": child_id}, headers=headers)
    assert timeline.status_code == 200
    ids = [entry["id"] for entry in timeline.json()["entries"]]
    assert ids == [did_it_entry_id, text_entry_id]

    # And the Today screen has moved them across.
    after = (
        await client.get(
            f"/v1/children/{child_id}/today", params={"date": RUN_DATE}, headers=headers
        )
    ).json()
    # `mission_b` is deliberately left uncompleted: two of the day's five are done, and the
    # third daily slot stays pending exactly like the weekly and the letter do. A day is not
    # all-or-nothing, and the third mission does not get special treatment for being new.
    assert {item["slot"] for item in after["today"]} == {"mission_b", "weekly", "letter"}
    assert {item["slot"] for item in after["done_today"]} == {"question", "mission"}


async def test_the_openapi_document_covers_every_endpoint_in_the_contract() -> None:
    """`make dev` serves /docs, and it has to describe the whole contract."""
    from rascal.config import get_settings
    from rascal.main import create_app

    paths = set(create_app(get_settings()).openapi()["paths"])

    assert paths >= {
        "/health",
        "/v1/auth/apple",
        "/v1/auth/refresh",
        "/v1/auth/logout",
        "/v1/auth/dev-login",
        "/v1/children",
        "/v1/children/{child_id}",
        "/v1/children/{child_id}/today",
        "/v1/children/{child_id}/moments",
        "/v1/assignments/{assignment_id}/dismiss",
        "/v1/assignments/{assignment_id}/custom",
        "/v1/entries",
        "/v1/entries/{entry_id}",
        "/v1/media/upload-url",
        "/v1/media/{media_id}/complete",
        "/v1/media/{media_id}/derived",
        "/v1/sync",
        "/v1/sync/push",
        "/v1/prompts",
        "/v1/debug/scheduler/run",
        "/v1/debug/reset-today",
    }
