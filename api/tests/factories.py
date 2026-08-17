"""Fixture builders shared across the suite.

Everything here writes through the ORM rather than the API, so a test can arrange a world
without depending on the endpoints it is about to exercise.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import DAILY_SLOTS, GuardianRole
from rascal.models import (
    Assignment,
    Child,
    Device,
    Entitlement,
    Family,
    Guardian,
    Prompt,
    User,
)


async def make_family(session: AsyncSession, *, tier: str = "free") -> Family:
    """A household and its entitlement, the pair `services.guardians.create_household` makes.

    `tier` is set here rather than through an API because **nothing in this codebase writes
    it** — D5 reserves that for phase 37's App Store notifications, so a test that needs a
    subscribed family sets the column, exactly as the documented hand-run statement does.
    """
    family = Family()
    session.add(family)
    await session.flush()
    session.add(Entitlement(family_id=family.id, tier=tier))
    await session.flush()
    return family


async def make_user(
    session: AsyncSession,
    *,
    display_name: str = "Travis",
    notify_enabled: bool = False,
    notify_local_time: dt.time | None = None,
    family: Family | None = None,
    tier: str = "free",
) -> User:
    """A user in a household of their own, unless `family` puts them in an existing one.

    `users.family_id` is NOT NULL since phase 36, so every user needs a family. Building one
    per user by default keeps the ninety-odd tests that predate households behaving exactly
    as they did — a household of one is what a single parent has always had, it just has a
    row now. Pass `family` to put two users in the same one.
    """
    if family is None:
        family = await make_family(session, tier=tier)
    user = User(
        family_id=family.id,
        display_name=display_name,
        email=f"{uuid.uuid4().hex[:8]}@example.com",
    )
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
    parent: User | None = None,
) -> Child:
    """A child, and optionally the parent who guards them.

    `parent` exists because since phase 36 a child with no guardian is served **no daily
    prompts** — there is nobody to serve them to. That is the correct behaviour and not a
    state production can reach (`POST /children` grants its creator), so a scheduler test
    that wants a board needs to say who the board is for.
    """
    child = Child(name=name, birthdate=birthdate, family_timezone=timezone)
    session.add(child)
    await session.flush()
    if parent is not None:
        session.add(Guardian(user_id=parent.id, child_id=child.id, role="parent"))
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
    source: str = "seeded",
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
        source=source,
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
    user: User | None = None,
) -> Assignment:
    # **In the past, and that is load-bearing.** This was `2026-08-14`, which arrived on
    # 14 Aug 2026 and made every assignment built without an explicit date land on the real
    # today — at which point `GET /today` starts self-healing the board a test just set up.
    # A default in the past cannot become today again. See `test_fixture_dates.py`.
    assigned_on = assigned_on or dt.date(2026, 8, 4)

    # **Daily slots need an owner and shared slots must not have one**, per
    # `ck_assignments_user_id_by_slot`. Resolving the child's sole parent when a test does not
    # name one is what keeps every pre-phase-36 caller working unchanged: they were written
    # when a daily assignment belonged to the child, and for a one-parent household it still
    # effectively does. A test about two parents passes `user` explicitly.
    user_id = user.id if user else None
    if slot in DAILY_SLOTS and user_id is None:
        user_id = await session.scalar(
            select(Guardian.user_id)
            .where(
                Guardian.child_id == child.id,
                Guardian.revoked_at.is_(None),
                Guardian.role == "parent",
            )
            .order_by(Guardian.granted_at, Guardian.user_id)
            .limit(1)
        )
    if slot not in DAILY_SLOTS:
        user_id = None

    assignment = Assignment(
        child_id=child.id,
        user_id=user_id,
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
