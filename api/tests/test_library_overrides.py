"""Editing the library from the console, and surviving the deploy that follows.

**The tests that matter here all re-run the seed loader after the edit.** That is the whole
risk: `seed_prompts` is `fly.toml`'s release command, so every write the admin console makes
is followed within minutes by a total reconciliation against `api/seeds/prompts.yaml`. An
edit that looks correct in the response body and is gone an hour later is the defect this
feature exists to avoid, and only a test that runs the reconciler can see it.

Each test therefore has the same shape: write through the API, run `seed_prompts` against the
same YAML that produced the row, then assert on the database.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_user
from helpers import auth_headers
from rascal.models import Prompt, PromptLibraryOverride
from rascal.services.seeding import content_hash, seed_prompts

SEEDED_BODY = "What did {they} say today that nobody else would understand?"
OTHER_BODY = "Take a photo of {their} hands."


def _seed_file(tmp_path: Path, bodies: list[str]) -> Path:
    path = tmp_path / "prompts.yaml"
    path.write_text(
        yaml.safe_dump(
            [
                {
                    "kind": "question",
                    "cadence": "daily",
                    "completion_mode": "text",
                    "body": body,
                    "theme": "their-words",
                    "min_age_months": 24,
                    "max_age_months": 216,
                    "source": "seeded",
                }
                for body in bodies
            ]
        ),
        encoding="utf-8",
    )
    return path


@pytest.fixture
async def admin(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture
async def seeded(session: AsyncSession, tmp_path: Path):
    """One seeded prompt in the table and the file that produced it."""
    path = _seed_file(tmp_path, [SEEDED_BODY, OTHER_BODY])
    await seed_prompts(session, path)
    prompt = await session.scalar(select(Prompt).where(Prompt.body == SEEDED_BODY))
    assert prompt is not None
    return prompt, path


async def test_editing_a_seeded_body_forks_it(
    client: AsyncClient, session: AsyncSession, admin, seeded
) -> None:
    prompt, _ = seeded
    response = await client.patch(
        f"/v1/prompts/{prompt.id}",
        json={"body": "What did {they} say today that only you would catch?"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["action"] == "superseded"
    assert payload["superseded_prompt_id"] == str(prompt.id)
    # The fork is a `user` prompt: that is the only source `seed_prompts` promises not to
    # retire, so it is what makes the new words durable.
    assert payload["prompt"]["source"] == "user"
    assert payload["prompt"]["active"] is True

    await session.refresh(prompt)
    assert prompt.active is False
    # The original row still exists. Assignments and entries point at it and must keep
    # resolving — the fork replaces the prompt, never the history.
    assert await session.get(Prompt, prompt.id) is not None


async def test_the_fork_survives_a_re_seed(
    client: AsyncClient, session: AsyncSession, admin, seeded
) -> None:
    """The test this whole table exists for.

    Without the override, re-running the seed does two wrong things at once: it retires the
    fork (a `source="user"` row is safe, so actually only the second happens) and it revives
    the original, because the file still lists it and `MUTABLE_FIELDS` includes `active`. Both
    the old and the new copy would then be served.
    """
    prompt, path = seeded
    new_body = "What did {they} say today that only you would catch?"
    await client.patch(
        f"/v1/prompts/{prompt.id}", json={"body": new_body}, headers=auth_headers(admin)
    )
    await session.commit()

    result = await seed_prompts(session, path)
    assert result.overridden >= 1, "the override did not fire"

    await session.refresh(prompt)
    assert prompt.active is False, "the re-seed revived the superseded body"

    fork = await session.scalar(select(Prompt).where(Prompt.body == new_body))
    assert fork is not None and fork.active is True, "the re-seed retired the fork"

    active = (
        (
            await session.execute(
                select(Prompt.body).where(Prompt.active.is_(True), Prompt.theme == "their-words")
            )
        )
        .scalars()
        .all()
    )
    assert new_body in active
    assert SEEDED_BODY not in active, "both copies of the prompt are being served"


async def test_retiring_a_seeded_prompt_survives_a_re_seed(
    client: AsyncClient, session: AsyncSession, admin, seeded
) -> None:
    prompt, path = seeded
    response = await client.put(
        f"/v1/prompts/{prompt.id}/active",
        json={"active": False, "note": "Too sad for this household."},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    await session.commit()

    override = await session.get(PromptLibraryOverride, prompt.content_hash)
    assert override is not None and override.active is False
    assert override.created_by_user_id == admin.id

    await seed_prompts(session, path)
    await session.refresh(prompt)
    assert prompt.active is False, "the re-seed put a retired prompt back into the pool"


async def test_clearing_the_override_hands_the_prompt_back_to_the_file(
    client: AsyncClient, session: AsyncSession, admin, seeded
) -> None:
    prompt, path = seeded
    await client.put(
        f"/v1/prompts/{prompt.id}/active", json={"active": False}, headers=auth_headers(admin)
    )
    await session.commit()

    response = await client.delete(f"/v1/prompts/{prompt.id}/override", headers=auth_headers(admin))
    assert response.status_code == 200, response.text
    assert await session.get(PromptLibraryOverride, prompt.content_hash) is None

    # The column is still False until the file is consulted — that is the documented state.
    await session.refresh(prompt)
    assert prompt.active is False
    await seed_prompts(session, path)
    await session.refresh(prompt)
    assert prompt.active is True, "the file did not get its opinion back"


async def test_a_no_op_re_seed_reports_no_overrides(session: AsyncSession, admin, seeded) -> None:
    """An override matching the file must not churn `updated_at` on every deploy."""
    prompt, path = seeded
    session.add(
        PromptLibraryOverride(
            content_hash=prompt.content_hash, active=True, created_by_user_id=admin.id
        )
    )
    await session.commit()
    result = await seed_prompts(session, path)
    assert result.overridden == 0


async def test_an_override_for_a_prompt_that_is_gone_is_not_an_error(
    session: AsyncSession, admin, tmp_path: Path
) -> None:
    """A decision outlives the row. Deleting the body from the file must not break the seed."""
    session.add(
        PromptLibraryOverride(
            content_hash=content_hash("question", "daily", "a body nobody ever wrote"),
            active=False,
            created_by_user_id=admin.id,
        )
    )
    await session.commit()
    result = await seed_prompts(session, _seed_file(tmp_path, [OTHER_BODY]))
    assert result.overridden == 0


async def test_editing_a_user_prompt_is_an_update_not_a_fork(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    created = await client.post(
        "/v1/prompts",
        json={
            "kind": "question",
            "cadence": "daily",
            "completion_mode": "text",
            "body": "What made {them} laugh?",
            "theme": "humor",
        },
        headers=auth_headers(admin),
    )
    assert created.status_code == 201, created.text
    prompt_id = created.json()["id"]

    response = await client.patch(
        f"/v1/prompts/{prompt_id}",
        json={"body": "What made {them} laugh hardest?"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    assert response.json()["action"] == "updated"
    assert response.json()["prompt"]["id"] == prompt_id

    prompt = await session.get(Prompt, response.json()["prompt"]["id"])
    await session.refresh(prompt)
    # The hash moved with the body, or the next re-seed would insert a duplicate.
    assert prompt.content_hash == content_hash(
        "question", "daily", "What made {them} laugh hardest?"
    )


async def test_metadata_only_edits_never_fork(
    client: AsyncClient, session: AsyncSession, admin, seeded
) -> None:
    prompt, _ = seeded
    response = await client.patch(
        f"/v1/prompts/{prompt.id}",
        json={"theme": "everyday-ordinary", "min_age_months": 36},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    assert response.json()["action"] == "updated"
    assert response.json()["prompt"]["id"] == str(prompt.id)


async def test_a_body_with_an_unknown_token_is_refused(client: AsyncClient, admin, seeded) -> None:
    """The same guard the seed loader runs, at the other door into the library.

    A misspelled token renders as literal braces on a card, in an export, and in a printed
    book, for as long as the archive exists — the authoring pipeline is the last place it is
    still cheap.
    """
    prompt, _ = seeded
    response = await client.patch(
        f"/v1/prompts/{prompt.id}",
        json={"body": "What did {thier} day look like?"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "body"


async def test_a_duplicate_body_is_a_conflict(client: AsyncClient, admin, seeded) -> None:
    prompt, _ = seeded
    response = await client.patch(
        f"/v1/prompts/{prompt.id}", json={"body": OTHER_BODY}, headers=auth_headers(admin)
    )
    assert response.status_code == 409, response.text


async def test_the_preview_renders_all_three_columns(client: AsyncClient, admin) -> None:
    response = await client.post(
        "/v1/prompts/preview",
        json={"body": "Ask {them} what {they_have} been building.", "name": "Miles"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["he_him"] == "Ask him what he has been building."
    assert payload["she_her"] == "Ask her what she has been building."
    assert payload["they_them"] == "Ask them what they have been building."
    # An unset pronoun renders the they/them column — grammatical for every child, and not a
    # guess at an answer nobody gave.
    assert payload["unset"] == payload["they_them"]
    assert payload["unknown_tokens"] == []


async def test_the_preview_names_a_bad_token(client: AsyncClient, admin) -> None:
    response = await client.post(
        "/v1/prompts/preview",
        json={"body": "Ask {thier} parent.", "name": "Miles"},
        headers=auth_headers(admin),
    )
    assert response.json()["unknown_tokens"] == ["thier"]


@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        ("PATCH", "/v1/prompts/{id}", {"theme": "humor"}),
        ("PUT", "/v1/prompts/{id}/active", {"active": False}),
        ("DELETE", "/v1/prompts/{id}/override", None),
        ("POST", "/v1/prompts/preview", {"body": "hello"}),
    ],
)
async def test_every_library_write_needs_an_admin(
    client: AsyncClient, session: AsyncSession, seeded, method: str, path: str, payload
) -> None:
    prompt, _ = seeded
    stranger = await make_user(session, display_name="Not an admin")
    await session.commit()
    response = await client.request(
        method,
        path.replace("{id}", str(prompt.id)),
        json=payload,
        headers=auth_headers(stranger),
    )
    assert response.status_code == 403, response.text
