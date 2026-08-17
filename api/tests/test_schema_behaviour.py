"""The parts of the schema that are behaviour, not shape."""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
import sqlalchemy as sa
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.models import Assignment, Child, Entitlement, Family, Prompt, User


async def _user(session: AsyncSession, display_name: str = "Travis") -> User:
    """A user in a household of their own. `users.family_id` is NOT NULL since phase 36."""
    family = Family()
    session.add(family)
    await session.flush()
    session.add(Entitlement(family_id=family.id))
    user = User(family_id=family.id, display_name=display_name)
    session.add(user)
    await session.commit()
    return user


async def _child(session: AsyncSession) -> Child:
    child = Child(
        name="Miles",
        birthdate=dt.date(2022, 6, 14),
        family_timezone="America/Detroit",
    )
    session.add(child)
    await session.commit()
    return child


async def _prompt(session: AsyncSession, body: str = "Describe his laugh.") -> Prompt:
    prompt = Prompt(
        kind="question",
        cadence="daily",
        completion_mode="text",
        body=body,
        theme="everyday-ordinary",
        min_age_months=24,
        max_age_months=216,
        source="seeded",
        content_hash=uuid.uuid4().hex,
    )
    session.add(prompt)
    await session.commit()
    return prompt


async def test_updated_at_is_maintained_by_the_trigger_not_the_application(
    session: AsyncSession,
) -> None:
    user = await _user(session)
    first = user.updated_at

    # A bulk UPDATE that never goes through the ORM still has to move the sync cursor.
    await session.execute(
        sa.text("UPDATE users SET display_name = 'Travis T.' WHERE id = :id"),
        {"id": user.id},
    )
    await session.commit()

    after = await session.scalar(sa.select(User.updated_at).where(User.id == user.id))
    assert after > first


def _assignment(child: Child, prompt: Prompt, day: dt.date, **kwargs) -> Assignment:
    return Assignment(
        child_id=child.id,
        prompt_id=prompt.id,
        assigned_on=day,
        expires_on=day + dt.timedelta(days=14),
        **kwargs,
    )


async def test_a_daily_slot_is_unique_per_child_day_slot_and_guardian(
    session: AsyncSession,
) -> None:
    """What makes rerunning the scheduler free, since phase 36 split it per guardian.

    **This assertion was rewritten rather than relaxed.** It previously pinned
    `uq_assignments_child_id_assigned_on_slot`, which phase 36 replaced: the behaviour
    changed first, for a stated reason — two parents each get their own daily prompts — and
    the test now pins what replaced it. The half that did *not* change is below.
    """
    child = await _child(session)
    prompt = await _prompt(session)
    parent = await _user(session)
    day = dt.date(2026, 8, 4)

    session.add(_assignment(child, prompt, day, slot="question", user_id=parent.id))
    await session.commit()

    session.add(_assignment(child, prompt, day, slot="question", user_id=parent.id))
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "uq_assignments_daily" in str(caught.value)


async def test_two_guardians_each_get_their_own_daily_slot_on_the_same_day(
    session: AsyncSession,
) -> None:
    """The point of the split. The old index made this collide; it must not any more."""
    child = await _child(session)
    prompt = await _prompt(session)
    one = await _user(session, "Travis")
    two = await _user(session, "Anna")
    day = dt.date(2026, 8, 4)

    session.add(_assignment(child, prompt, day, slot="question", user_id=one.id))
    session.add(_assignment(child, prompt, day, slot="question", user_id=two.id))
    await session.commit()

    count = await session.scalar(
        sa.select(sa.func.count())
        .select_from(Assignment)
        .where(Assignment.child_id == child.id, Assignment.slot == "question")
    )
    assert count == 2


async def test_a_shared_slot_is_still_one_per_child_and_day(session: AsyncSession) -> None:
    """**The assertion this phase is most likely to have broken silently.**

    `uq_assignments_shared` deliberately omits `user_id`. A single wide unique index over
    `(child_id, user_id, assigned_on, slot)` would have let this pass — every shared row has
    a NULL `user_id`, and in a unique index NULL never equals NULL, so unlimited weekly rows
    for one child and day would have been accepted with no error anywhere.
    """
    child = await _child(session)
    prompt = await _prompt(session)
    day = dt.date(2026, 8, 4)

    session.add(_assignment(child, prompt, day, slot="weekly"))
    await session.commit()

    session.add(_assignment(child, prompt, day, slot="weekly"))
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "uq_assignments_shared" in str(caught.value)


async def test_the_check_refuses_both_wrong_shapes(session: AsyncSession) -> None:
    """A daily row without an owner, and a shared row with one. Both are defects."""
    child = await _child(session)
    prompt = await _prompt(session)
    parent = await _user(session)
    day = dt.date(2026, 8, 4)
    # Read the ids before the first rollback: a rolled-back session expires its instances,
    # and touching `child.id` afterwards is a lazy load on an async session.
    child_id, prompt_id, parent_id = child.id, prompt.id, parent.id

    def row(**kwargs) -> Assignment:
        return Assignment(
            child_id=child_id,
            prompt_id=prompt_id,
            assigned_on=day,
            expires_on=day + dt.timedelta(days=14),
            **kwargs,
        )

    session.add(row(slot="question"))
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "ck_assignments_user_id_by_slot" in str(caught.value)
    await session.rollback()

    session.add(row(slot="weekly", user_id=parent_id))
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "ck_assignments_user_id_by_slot" in str(caught.value)
    await session.rollback()


async def test_an_assignment_must_have_a_prompt_or_a_custom_body(session: AsyncSession) -> None:
    child = await _child(session)
    day = dt.date(2026, 8, 4)

    session.add(
        Assignment(
            child_id=child.id,
            slot="mission",
            assigned_on=day,
            expires_on=day + dt.timedelta(days=14),
        )
    )
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "ck_assignments_prompt_or_custom_body" in str(caught.value)
    await session.rollback()


async def test_constrained_columns_reject_unknown_values(session: AsyncSession) -> None:
    child = await _child(session)
    day = dt.date(2026, 8, 4)
    prompt = await _prompt(session)

    session.add(
        Assignment(
            child_id=child.id,
            prompt_id=prompt.id,
            slot="whenever",  # not one of question | mission | weekly | monthly
            assigned_on=day,
            expires_on=day + dt.timedelta(days=14),
        )
    )
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "ck_assignments_slot" in str(caught.value)
    await session.rollback()


async def test_one_apple_subject_cannot_map_to_two_users(session: AsyncSession) -> None:
    from rascal.models import Credential

    first, second = await _user(session, "A"), await _user(session, "B")

    session.add(Credential(user_id=first.id, provider="apple", subject_id="001.abc"))
    await session.commit()

    session.add(Credential(user_id=second.id, provider="apple", subject_id="001.abc"))
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "uq_credentials_provider_subject_id" in str(caught.value)
    await session.rollback()


async def test_month_tags_defaults_to_empty_not_null(session: AsyncSession) -> None:
    """Empty means any month; NULL would mean the scheduler has to special-case it."""
    prompt = await _prompt(session, body="Photograph his hands. Just his hands.")
    stored = await session.scalar(sa.select(Prompt.month_tags).where(Prompt.id == prompt.id))
    assert stored == []
