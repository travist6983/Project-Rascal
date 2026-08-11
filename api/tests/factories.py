"""Fixture builders shared across the suite.

Everything here writes through the ORM rather than the API, so a test can arrange a world
without depending on the endpoints it is about to exercise.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import GuardianRole
from rascal.models import Assignment, Child, Device, Guardian, Prompt, User


async def make_user(
    session: AsyncSession,
    *,
    display_name: str = "Travis",
    notify_enabled: bool = False,
    notify_local_time: dt.time | None = None,
) -> User:
    user = User(display_name=display_name, email=f"{uuid.uuid4().hex[:8]}@example.com")
    # Left at the column defaults unless a test says otherwise, so the twenty tests that do
    # not care about notifications keep exercising the shipped defaults rather than a
    # fixture's opinion of them.
    user.notify_enabled = notify_enabled
    if notify_local_time is not None:
        user.notify_local_time = notify_local_time
    session.add(user)
    await session.flush()
    return user


async def make_device(
    session: AsyncSession,
    user: User,
    *,
    token: str | None = None,
    platform: str = "ios",
    environment: str = "production",
    revoked: bool = False,
) -> Device:
    now = dt.datetime.now(tz=dt.UTC)
    device = Device(
        user_id=user.id,
        token=token or uuid.uuid4().hex * 2,
        platform=platform,
        environment=environment,
        last_seen_at=now,
        revoked_at=now if revoked else None,
    )
    session.add(device)
    await session.flush()
    return device


async def make_child(
    session: AsyncSession,
    *,
    name: str = "Miles",
    birthdate: dt.date = dt.date(2022, 6, 14),
    timezone: str = "America/Detroit",
) -> Child:
    child = Child(name=name, birthdate=birthdate, family_timezone=timezone)
    session.add(child)
    await session.flush()
    return child


async def grant(
    session: AsyncSession,
    user: User,
    child: Child,
    role: GuardianRole = "parent",
    *,
    revoked: bool = False,
) -> Guardian:
    guardian = Guardian(
        user_id=user.id,
        child_id=child.id,
        role=role,
        revoked_at=dt.datetime.now(tz=dt.UTC) if revoked else None,
    )
    session.add(guardian)
    await session.flush()
    return guardian


async def make_prompt(
    session: AsyncSession,
    *,
    kind: str = "question",
    cadence: str = "daily",
    completion_mode: str = "text",
    body: str | None = None,
    theme: str = "everyday-ordinary",
    min_age_months: int = 24,
    max_age_months: int = 216,
    month_tags: list[int] | None = None,
    default_unlock_age: int | None = None,
    active: bool = True,
) -> Prompt:
    body = body or f"Prompt {uuid.uuid4().hex[:8]}"
    prompt = Prompt(
        kind=kind,
        cadence=cadence,
        completion_mode=completion_mode,
        body=body,
        theme=theme,
        min_age_months=min_age_months,
        max_age_months=max_age_months,
        month_tags=month_tags or [],
        source="seeded",
        default_unlock_age=default_unlock_age,
        active=active,
        content_hash=uuid.uuid4().hex,
    )
    session.add(prompt)
    await session.flush()
    return prompt


async def make_assignment(
    session: AsyncSession,
    child: Child,
    prompt: Prompt | None = None,
    *,
    slot: str = "question",
    assigned_on: dt.date | None = None,
    status: str = "pending",
    custom_body: str | None = None,
    expires_in_days: int = 14,
) -> Assignment:
    assigned_on = assigned_on or dt.date(2026, 8, 14)
    assignment = Assignment(
        child_id=child.id,
        prompt_id=prompt.id if prompt else None,
        custom_body=custom_body,
        slot=slot,
        assigned_on=assigned_on,
        expires_on=assigned_on + dt.timedelta(days=expires_in_days),
        status=status,
    )
    session.add(assignment)
    await session.flush()
    return assignment
