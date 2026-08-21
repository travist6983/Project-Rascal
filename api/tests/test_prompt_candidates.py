"""Generating prompt candidates, and the queue they wait in.

**The queue is the point, and `active=False` is the whole safety story.** A candidate is a
`prompts` row with `source='llm'` and `active=false`. `services/scheduler.py` filters
`Prompt.active.is_(True)` and does not look at `source`, so an active candidate is served to
every child in its age band — which makes `active=False` on insert the single line between a
review queue and model-written copy in a real archive. `Prompt.active` has a `server_default`
of `true` and **no Python-side default**, so omitting it writes the opposite of what is meant
and nothing raises. That is asserted here twice, from both directions.

**Nothing in this file reaches Anthropic.** `ANTHROPIC_API_KEY` is deleted by an autouse
fixture and `director.structured` is monkeypatched wherever a reply is needed, so the batch a
test judges is a batch the test wrote.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_prompt, make_user
from helpers import auth_headers
from rascal.models import Prompt
from rascal.services import prompt_generation
from rascal.services.seeding import content_hash, seed_prompts

GENERATE = "/v1/prompts/generate"
CANDIDATES = "/v1/prompts/candidates"

ROUTES = [
    ("POST", GENERATE, {"kind": "question"}),
    (
        "POST",
        CANDIDATES,
        {"candidates": [{"kind": "question", "body": "What did {they} say?", "theme": "humor"}]},
    ),
]


@pytest.fixture
async def admin(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture(autouse=True)
def _no_key(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """The suite must never be able to reach Anthropic, even if a developer exports a key."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    yield


def _reply(monkeypatch: pytest.MonkeyPatch, candidates: list[dict[str, Any]]) -> dict[str, Any]:
    """Stand in for the model. Returns the captured call so a test can assert on the request."""
    captured: dict[str, Any] = {}

    async def fake_structured(settings, instruction, schema, **kwargs):
        captured["instruction"] = instruction
        captured["schema"] = schema
        captured["kwargs"] = kwargs
        return {"candidates": candidates}

    monkeypatch.setattr(prompt_generation.director, "structured", fake_structured)
    return captured


# --- Authorization --------------------------------------------------------------------------


@pytest.mark.parametrize(("method", "path", "payload"), ROUTES)
async def test_no_token_is_refused(client: AsyncClient, method: str, path: str, payload) -> None:
    assert (await client.request(method, path, json=payload)).status_code == 401, path


@pytest.mark.parametrize(("method", "path", "payload"), ROUTES)
async def test_a_non_admin_is_refused(
    client: AsyncClient, session: AsyncSession, method: str, path: str, payload
) -> None:
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()
    response = await client.request(method, path, json=payload, headers=auth_headers(stranger))
    assert response.status_code == 403, f"{path} is reachable by a non-admin"


async def test_generating_without_a_key_names_the_variable(client: AsyncClient, admin) -> None:
    """No socket is opened. The message has to name the setting, not say "unauthorized"."""
    response = await client.post(GENERATE, json={"kind": "question"}, headers=auth_headers(admin))
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["field"] == "anthropic_api_key"
    assert "ANTHROPIC_API_KEY" in error["message"]


# --- What a picked candidate becomes ---------------------------------------------------------


async def test_a_queued_candidate_is_inactive_and_llm(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """The load-bearing assertion of this whole feature."""
    response = await client.post(
        CANDIDATES,
        json={
            "candidates": [
                {
                    "kind": "photo",
                    "body": "Photograph the mess {they} made.",
                    "theme": "humor",
                    "min_age_months": 36,
                    "max_age_months": 120,
                }
            ]
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["queued_total"] == 1

    row = (await session.execute(select(Prompt).where(Prompt.source == "llm"))).scalar_one()
    assert row.active is False, "a queued candidate must not be servable"
    assert row.source == "llm"
    # Derived from the kind rather than accepted from the caller, so a client cannot send a
    # pair that disagrees with its own kind.
    assert (row.cadence, row.completion_mode) == ("daily", "media")
    assert row.content_hash == content_hash("photo", "daily", "Photograph the mess {they} made.")


async def test_the_wire_cannot_ask_for_an_active_candidate(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """`active` is not on the input model at all, so a caller cannot set it by sending one."""
    response = await client.post(
        CANDIDATES,
        json={
            "candidates": [
                {
                    "kind": "question",
                    "body": "What did {they} notice today?",
                    "theme": "humor",
                    "active": True,
                    "source": "seeded",
                }
            ]
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201
    row = (await session.execute(select(Prompt).where(Prompt.source == "llm"))).scalar_one()
    assert row.active is False
    assert row.source == "llm"


async def test_the_brief_reaches_the_row(client: AsyncClient, session: AsyncSession, admin) -> None:
    """`month_tags` and `default_unlock_age` are properties of the brief, and must survive it.

    They were accepted and silently dropped once. A seasonal batch that queues rows with no
    months is never served in the month it was written for, and nothing about it looks wrong.
    """
    response = await client.post(
        CANDIDATES,
        json={
            "candidates": [
                {
                    "kind": "photo",
                    "body": "Photograph {them} in the first snow.",
                    "theme": "seasonal",
                    "month_tags": [12, 1],
                    "default_unlock_age": 18,
                }
            ]
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text
    row = (await session.execute(select(Prompt).where(Prompt.source == "llm"))).scalar_one()
    assert row.month_tags == [12, 1]
    assert row.default_unlock_age == 18


# --- The two rules that are re-checked on the way in -----------------------------------------


@pytest.mark.parametrize(
    ("body", "needle"),
    [
        ("Photograph the mess he made.", "assumes a gender"),
        ("What did {thier} favourite toy do?", "unknown token"),
    ],
)
async def test_a_permanent_failure_is_refused_however_it_arrives(
    client: AsyncClient, session: AsyncSession, admin, body: str, needle: str
) -> None:
    """The console may keep a candidate the filters disliked. It may not keep these two.

    A bare pronoun misgenders a real child and an unknown token renders as literal braces in
    the app, in an export and in a printed book for as long as the archive exists. Both are
    permanent and neither is visible in review, so the wire refuses them whatever the console
    believed — `commit` is reachable without ever calling `generate`.
    """
    response = await client.post(
        CANDIDATES,
        json={"candidates": [{"kind": "photo", "body": body, "theme": "humor"}]},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert needle in response.json()["error"]["message"]
    assert (await session.scalar(select(Prompt).where(Prompt.source == "llm"))) is None


# --- Duplicates ------------------------------------------------------------------------------


async def test_a_duplicate_is_skipped_and_names_the_row_it_hit(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """One repeat must not cost the other twenty-four, and the reviewer wants the id."""
    existing = await make_prompt(
        session, kind="question", cadence="daily", body="What did {they} say today?"
    )
    # `make_prompt` stamps a random `content_hash`, which is fine for every other test and
    # fatal for this one: the duplicate check keys on that column, exactly as
    # `POST /prompts` and `seed_prompts` do, so a row with a random hash collides with
    # nothing. Give it the real one.
    existing.content_hash = content_hash("question", "daily", "What did {they} say today?")
    await session.commit()

    response = await client.post(
        CANDIDATES,
        json={
            "candidates": [
                {"kind": "question", "body": "What did {they} say today?", "theme": "humor"},
                {"kind": "question", "body": "What did {they} refuse today?", "theme": "humor"},
            ]
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert len(body["inserted"]) == 1
    assert len(body["skipped"]) == 1
    assert body["skipped"][0]["prompt_id"] == str(existing.id)
    assert "already has" in body["skipped"][0]["reason"]


async def test_the_same_body_twice_in_one_batch_is_skipped_once(client: AsyncClient, admin) -> None:
    """Both would pass the pre-check and the second would fail on the unique index."""
    one = {"kind": "question", "body": "What did {they} build today?", "theme": "humor"}
    response = await client.post(
        CANDIDATES, json={"candidates": [one, dict(one)]}, headers=auth_headers(admin)
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert len(body["inserted"]) == 1
    assert len(body["skipped"]) == 1


# --- Re-seed immunity -------------------------------------------------------------------------


async def test_a_re_seed_leaves_a_candidate_alone(session: AsyncSession, admin) -> None:
    """The reconciler's retirement sweep is filtered to `source='seeded'` and must stay so.

    `seed_prompts` runs as the release command, so anything it can reach it reaches within
    minutes of a deploy. A candidate it could retire — or worse, activate — would make the
    queue a place rows quietly leave.
    """
    result = await prompt_generation.commit(
        session,
        [
            {
                "kind": "question",
                "body": "What did {they} argue about today?",
                "theme": "humor",
                "min_age_months": 24,
                "max_age_months": 216,
                "month_tags": [],
                "default_unlock_age": None,
            }
        ],
    )
    await session.commit()
    candidate_id = result.inserted[0].id

    await seed_prompts(session)
    await session.commit()

    row = await session.get(Prompt, candidate_id)
    assert row is not None, "the re-seed deleted a candidate"
    assert row.source == "llm"
    assert row.active is False, "the re-seed activated an unapproved candidate"


# --- Generating -------------------------------------------------------------------------------


async def test_rejected_candidates_come_back_with_their_reasons(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A batch where half the rows trip one filter is a signal about the brief.

    Dropping the failures throws that signal away, and it is also what would make the filters
    an editor rather than a spam trap — the console lets a human keep any of these.
    """
    _reply(
        monkeypatch,
        [
            {
                "body": "What did {they} say today?",
                "min_age_months": 36,
                "max_age_months": 120,
                "rationale": "good",
            },
            {
                "body": "Photograph a precious moment where he feels safe.",
                "min_age_months": 24,
                "max_age_months": 216,
                "rationale": "bad",
            },
        ],
    )
    response = await client.post(
        GENERATE, json={"kind": "question", "theme": "humor"}, headers=auth_headers(admin)
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["accepted"] == 1
    assert body["rejected"] == 1
    assert len(body["candidates"]) == 2, "a rejected candidate was dropped"

    bad = next(row for row in body["candidates"] if not row["accepted"])
    joined = " ".join(bad["reasons"])
    assert "banned vocabulary" in joined
    assert "assumes a gender" in joined


async def test_no_theme_asks_the_model_for_one(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """ "A theme *or* an age range" — `prompts.theme` is NOT NULL, so something must fill it."""
    captured = _reply(
        monkeypatch,
        [
            {
                "body": "What did {they} negotiate for today?",
                "theme": "humor",
                "min_age_months": 36,
                "max_age_months": 84,
                "rationale": "good",
            }
        ],
    )
    response = await client.post(
        GENERATE,
        json={"kind": "question", "min_age_months": 36, "max_age_months": 84},
        headers=auth_headers(admin),
    )
    assert response.status_code == 200, response.text
    item = captured["schema"]["properties"]["candidates"]["items"]
    assert "theme" in item["required"], "with no theme given, the model must supply one"
    assert response.json()["candidates"][0]["theme"] == "humor"


async def test_a_theme_is_not_asked_for_when_it_was_given(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    captured = _reply(
        monkeypatch,
        [
            {
                "body": "What did {they} say today?",
                "min_age_months": 36,
                "max_age_months": 84,
                "rationale": "good",
            }
        ],
    )
    response = await client.post(
        GENERATE, json={"kind": "question", "theme": "their-words"}, headers=auth_headers(admin)
    )
    assert response.status_code == 200, response.text
    item = captured["schema"]["properties"]["candidates"]["items"]
    assert "theme" not in item["required"]
    assert response.json()["candidates"][0]["theme"] == "their-words"


async def test_the_generator_runs_on_its_own_model(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Separate from the studio's, so moving one does not move the other."""
    captured = _reply(
        monkeypatch,
        [
            {
                "body": "What did {they} say today?",
                "min_age_months": 36,
                "max_age_months": 84,
                "rationale": "good",
            }
        ],
    )
    response = await client.post(
        GENERATE, json={"kind": "question", "theme": "humor"}, headers=auth_headers(admin)
    )
    assert response.status_code == 200
    assert captured["kwargs"]["model"] == "claude-sonnet-5"
    assert response.json()["model"] == "claude-sonnet-5"


@pytest.mark.parametrize("count", [0, 2, 7, 26, 100])
async def test_only_the_offered_counts_are_accepted(client: AsyncClient, admin, count: int) -> None:
    """The console offers 1, 5, 10 and 25. The wire admits exactly those."""
    response = await client.post(
        GENERATE, json={"kind": "question", "count": count}, headers=auth_headers(admin)
    )
    assert response.status_code == 422, f"count={count} was accepted"


async def test_an_upside_down_age_band_is_refused(client: AsyncClient, admin) -> None:
    response = await client.post(
        GENERATE,
        json={"kind": "question", "min_age_months": 200, "max_age_months": 100},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422


async def test_a_month_outside_the_year_is_refused_on_the_brief(client: AsyncClient, admin) -> None:
    response = await client.post(
        GENERATE,
        json={"kind": "photo", "theme": "seasonal", "month_tags": [13]},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422


#: The same two guards, on the route that *writes*. `PromptCandidateIn` carries its own
#: validator, and `commit` is reachable without ever calling `generate` — so a brief validated
#: on the way out says nothing about what arrives on the way in.
@pytest.mark.parametrize(
    ("overrides", "field"),
    [
        ({"min_age_months": 200, "max_age_months": 100}, "min_age_months"),
        ({"month_tags": [13]}, "month_tags"),
        ({"month_tags": [0]}, "month_tags"),
    ],
)
async def test_a_candidate_with_an_impossible_band_or_month_is_refused(
    client: AsyncClient, session: AsyncSession, admin, overrides: dict, field: str
) -> None:
    candidate = {
        "kind": "question",
        "body": "What did {they} plant this month?",
        "theme": "seasonal",
        **overrides,
    }
    response = await client.post(
        CANDIDATES, json={"candidates": [candidate]}, headers=auth_headers(admin)
    )
    assert response.status_code == 422, response.text
    assert field in response.text
    assert (await session.scalar(select(Prompt).where(Prompt.source == "llm"))) is None


async def test_a_seasonal_batch_stops_the_occasion_filter(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The library's seasonal prompts are meant to be occasions, so the rule has to relax."""
    body = "Photograph {them} at {their} birthday party."
    _reply(
        monkeypatch,
        [
            {
                "body": body,
                "min_age_months": 24,
                "max_age_months": 216,
                "rationale": "seasonal",
            }
        ],
    )
    seasonal = await client.post(
        GENERATE,
        json={"kind": "photo", "theme": "seasonal", "month_tags": [6]},
        headers=auth_headers(admin),
    )
    ordinary = await client.post(
        GENERATE, json={"kind": "photo", "theme": "seasonal"}, headers=auth_headers(admin)
    )
    assert seasonal.json()["candidates"][0]["accepted"] is True
    reasons = " ".join(ordinary.json()["candidates"][0]["reasons"])
    assert "ordinary Tuesday" in reasons


async def test_a_generated_batch_never_writes_anything(
    client: AsyncClient, session: AsyncSession, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`POST /generate` is in `NON_PERSISTING` in the read-database sweep. This is why."""
    before = await session.scalar(select(Prompt.id).where(Prompt.source == "llm"))
    _reply(
        monkeypatch,
        [
            {
                "body": "What did {they} say today?",
                "min_age_months": 36,
                "max_age_months": 84,
                "rationale": "good",
            }
        ],
    )
    response = await client.post(
        GENERATE, json={"kind": "question", "theme": "humor"}, headers=auth_headers(admin)
    )
    assert response.status_code == 200
    after = await session.scalar(select(Prompt.id).where(Prompt.source == "llm"))
    assert before == after is None


# --- Who can see the queue ---------------------------------------------------------------


async def test_a_parent_cannot_read_an_unreviewed_candidate(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`GET /prompts` takes any authenticated caller, and this is the queue's only way out.

    The scheduler is not the only thing that reads `prompts`. Before phase 103 every
    `active=false` row was human-authored library copy somebody had chosen to retire, so a
    listing that showed them was fine. This phase puts *unreviewed model output* in that same
    state, and `active` is filtered on this route only when the caller asks for it — so
    `?source=llm&active=false` handed a parent copy that no person had read.
    """
    await make_prompt(
        session,
        source="llm",
        active=False,
        body="Model-written and nobody has read it yet.",
    )
    parent = await make_user(session, display_name="An ordinary parent")
    await session.commit()
    assert parent.is_admin is False

    page = (
        await client.get("/v1/prompts?source=llm&active=false", headers=auth_headers(parent))
    ).json()
    assert page["total"] == 0
    assert page["prompts"] == []

    # Unfiltered too — the hole was not the query string.
    everything = (await client.get("/v1/prompts?limit=500", headers=auth_headers(parent))).json()
    assert all(p["source"] != "llm" for p in everything["prompts"])


async def test_an_admin_still_sees_the_queue(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """The console reads this route. Hiding it from everyone would break the thing it is for."""
    await make_prompt(session, source="llm", active=False, body="Waiting to be read.")
    await session.commit()
    page = (
        await client.get("/v1/prompts?source=llm&active=false", headers=auth_headers(admin))
    ).json()
    assert page["total"] == 1
    assert page["prompts"][0]["body"] == "Waiting to be read."


async def test_an_approved_candidate_becomes_visible(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The rule is *pending*, not *llm*. Approving one is what puts it in the library."""
    await make_prompt(session, source="llm", active=True, body="Read, approved, serving.")
    parent = await make_user(session, display_name="A parent")
    await session.commit()
    page = (await client.get("/v1/prompts?source=llm", headers=auth_headers(parent))).json()
    assert [p["body"] for p in page["prompts"]] == ["Read, approved, serving."]


async def test_the_queue_count_is_what_the_review_cli_reads(session: AsyncSession, admin) -> None:
    """`pending_count` and `scripts/review_candidates.py` must not be able to disagree."""
    await make_prompt(session, source="llm", active=False, body="Waiting one.")
    await make_prompt(session, source="llm", active=False, body="Waiting two.")
    await make_prompt(session, source="llm", active=True, body="Approved, so not waiting.")
    await make_prompt(session, source="user", active=False, body="Hand-written and retired.")
    await session.commit()
    assert await prompt_generation.pending_count(session) == 2
