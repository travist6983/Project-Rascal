"""The parts of the schema that are behaviour, not shape."""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
import sqlalchemy as sa
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.models import Assignment, Child, Prompt, User


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
    user = User(display_name="Travis")
    session.add(user)
    await session.commit()
    first = user.updated_at

    # A bulk UPDATE that never goes through the ORM still has to move the sync cursor.
    await session.execute(
        sa.text("UPDATE users SET display_name = 'Travis T.' WHERE id = :id"),
        {"id": user.id},
    )
    await session.commit()

    after = await session.scalar(sa.select(User.updated_at).where(User.id == user.id))
    assert after > first


async def test_assignments_are_unique_per_child_day_and_slot(session: AsyncSession) -> None:
    """This unique index is what makes rerunning the scheduler free."""
    child = await _child(session)
    prompt = await _prompt(session)
    day = dt.date(2026, 8, 4)

    session.add(
        Assignment(
            child_id=child.id,
            prompt_id=prompt.id,
            slot="question",
            assigned_on=day,
            expires_on=day + dt.timedelta(days=14),
        )
    )
    await session.commit()

    session.add(
        Assignment(
            child_id=child.id,
            prompt_id=prompt.id,
            slot="question",
            assigned_on=day,
            expires_on=day + dt.timedelta(days=14),
        )
    )
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "uq_assignments_child_id_assigned_on_slot" in str(caught.value)
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

    first, second = User(display_name="A"), User(display_name="B")
    session.add_all([first, second])
    await session.commit()

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
