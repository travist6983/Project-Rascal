"""Suppression: "stop asking me this", and the rules that make it mean it.

The failure this exists to prevent is not a repeat. It is the app asking a family something they
have already told it to stop asking — a question about a mother in a household where that is
painful, a mission assuming an ability this child does not have — coming back on a loop for
eighteen years.
"""

from __future__ import annotations

import datetime as dt
import random

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.services.scheduler import ensure_day_filled, select_prompt

TODAY = dt.date(2026, 8, 14)


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    return user, child


async def test_a_suppressed_prompt_is_never_served_even_when_it_is_the_only_one(
    session: AsyncSession,
) -> None:
    """**The assertion that passes vacuously if suppression is checked in the wrong place.**

    Exactly one eligible question exists and it is suppressed. Every relaxation rung —
    the 90-day cooldown, the dropped theme rotation, no cooldown at all, the dropped age
    window, and the final "anything in the pool" — has this prompt as its only option. If
    suppression were a filter inside the ladder rather than an exclusion before it, the last
    rung would serve it anyway.
    """
    _user, child = await _world(session)
    only = await make_prompt(session, kind="question", body="The only question there is.")

    await _suppress(session, child, only)

    chosen = await select_prompt(child, "question", TODAY, session, rng=random.Random(0))
    assert chosen is None


async def test_suppression_survives_every_relaxation_step(session: AsyncSession) -> None:
    """Served yesterday *and* suppressed. Cooldown relaxation cannot bring it back."""
    _user, child = await _world(session)
    suppressed = await make_prompt(session, kind="question", body="Suppressed and recent.")
    await make_assignment(
        session, child, suppressed, slot="question", assigned_on=TODAY - dt.timedelta(days=1)
    )
    await _suppress(session, child, suppressed)

    for days in (1, 89, 91, 181):
        as_of = TODAY + dt.timedelta(days=days)
        assert await select_prompt(child, "question", as_of, session, rng=random.Random(1)) is None


async def test_unsuppressing_restores_eligibility(session: AsyncSession) -> None:
    _user, child = await _world(session)
    only = await make_prompt(session, kind="question", body="Come back.")
    suppression = await _suppress(session, child, only)

    assert await select_prompt(child, "question", TODAY, session, rng=random.Random(0)) is None

    suppression.revoked_at = dt.datetime.now(tz=dt.UTC)
    await session.flush()

    chosen = await select_prompt(child, "question", TODAY, session, rng=random.Random(0))
    assert chosen is not None
    assert chosen.id == only.id


async def test_suppression_is_per_child_not_global(session: AsyncSession) -> None:
    user = await make_user(session)
    one = await make_child(session, birthdate=dt.date(2022, 6, 14), name="One")
    two = await make_child(session, birthdate=dt.date(2022, 6, 14), name="Two")
    await grant(session, user, one, "parent")
    await grant(session, user, two, "parent")
    only = await make_prompt(session, kind="question", body="Shared library entry.")

    await _suppress(session, one, only)

    assert await select_prompt(one, "question", TODAY, session, rng=random.Random(0)) is None
    served = await select_prompt(two, "question", TODAY, session, rng=random.Random(0))
    assert served is not None and served.id == only.id


async def test_the_scheduler_and_the_read_path_exclude_identically(
    session: AsyncSession,
) -> None:
    """Both callers funnel through `select_prompt`, asserted against one fixture.

    A divergence here would be nearly undetectable and would corrupt variety over years.
    """
    _user, child = await _world(session)
    only = await make_prompt(session, kind="question", body="The only question there is.")
    await _suppress(session, child, only)

    # The scheduler's own entry point.
    assert await select_prompt(child, "question", TODAY, session, rng=random.Random(0)) is None

    # The Phase 12 idempotent-on-read path.
    run = await ensure_day_filled(session, child, TODAY, seed=0)
    assert "question" in " ".join(run.exhausted)
    assert run.created == 0


# --- The routes -------------------------------------------------------------------------------


async def test_suppress_is_idempotent(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="question")
    await session.commit()
    headers = auth_headers(user)
    body = {"prompt_id": str(prompt.id), "reason": "Not this one."}

    path = f"/v1/children/{child.id}/prompt-suppressions"
    first = await client.post(path, json=body, headers=headers)
    second = await client.post(path, json=body, headers=headers)

    assert first.status_code == 201
    assert second.status_code == 201
    listing = await client.get(f"/v1/children/{child.id}/prompt-suppressions", headers=headers)
    assert len(listing.json()) == 1


async def test_delete_is_a_soft_delete_and_the_row_survives(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="question")
    await session.commit()
    headers = auth_headers(user)
    await client.post(
        f"/v1/children/{child.id}/prompt-suppressions",
        json={"prompt_id": str(prompt.id)},
        headers=headers,
    )

    deleted = await client.delete(
        f"/v1/children/{child.id}/prompt-suppressions/{prompt.id}", headers=headers
    )
    assert deleted.status_code == 204

    live = await client.get(f"/v1/children/{child.id}/prompt-suppressions", headers=headers)
    assert live.json() == []

    # The row is still there, carrying its revocation — a decision withdrawn, not erased.
    including = await client.get(
        f"/v1/children/{child.id}/prompt-suppressions?include_revoked=true", headers=headers
    )
    assert len(including.json()) == 1
    assert including.json()[0]["revoked_at"] is not None


async def test_listing_carries_the_prompt_so_a_client_can_offer_to_restore_it(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="question", body="What made him laugh today?")
    await session.commit()
    headers = auth_headers(user)
    await client.post(
        f"/v1/children/{child.id}/prompt-suppressions",
        json={"prompt_id": str(prompt.id)},
        headers=headers,
    )

    listing = await client.get(f"/v1/children/{child.id}/prompt-suppressions", headers=headers)
    assert listing.json()[0]["prompt"]["body"] == "What made him laugh today?"


async def test_suppressing_an_unknown_prompt_is_a_404(
    client: AsyncClient, session: AsyncSession
) -> None:
    import uuid as _uuid

    user, child = await _world(session)
    await session.commit()

    response = await client.post(
        f"/v1/children/{child.id}/prompt-suppressions",
        json={"prompt_id": str(_uuid.uuid4())},
        headers=auth_headers(user),
    )
    assert response.status_code == 404


async def _suppress(session: AsyncSession, child, prompt, reason: str | None = None):
    from rascal.models import PromptSuppression

    row = PromptSuppression(child_id=child.id, prompt_id=prompt.id, reason=reason)
    session.add(row)
    await session.flush()
    return row
