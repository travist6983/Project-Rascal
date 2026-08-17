"""The household: creating one, inviting a second parent into it, and accepting.

**Authorization is unchanged by everything in this file.** `deps.require_child_access` reads
`guardians` and only `guardians`, so accepting an invite grants access by writing the rows it
already reads — no new check, no second code path, nothing to keep in sync. That is why
`accept_invite` writes a `Guardian` row per child rather than anything cleverer.

The tier gate lives here rather than in the router so that "who may invite" is one function
with one answer, testable without HTTP.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import secrets
import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    INVITE_EXPIRY_DAYS,
    ISSUABLE_INVITE_ROLES,
    MAX_PARENTS_PER_FAMILY,
    GuardianRole,
)
from rascal.errors import ErrorCode, RascalError, not_found, validation_failed
from rascal.models import Child, Entitlement, Family, Guardian, GuardianInvite, User

# 32 bytes of urlsafe base64. Long enough that guessing is not a strategy, short enough to
# survive being pasted into a text message without a line break.
TOKEN_BYTES = 32


def hash_token(raw: str) -> str:
    """SHA-256, the same rule `refresh_tokens` and `email_sign_in_tokens` follow."""
    return hashlib.sha256(raw.encode()).hexdigest()


async def create_household(session: AsyncSession) -> Family:
    """A new family and its `free` entitlement, together.

    **Both rows or neither.** An entitlement is created here rather than lazily on first read
    because a lazily-created row means every reader needs a "what if it is missing" branch,
    and one of those branches eventually decides that missing means subscribed.
    """
    family = Family()
    session.add(family)
    await session.flush()
    session.add(Entitlement(family_id=family.id))
    await session.flush()
    return family


async def entitlement_for(session: AsyncSession, family_id: uuid.UUID) -> Entitlement:
    entitlement = await session.get(Entitlement, family_id)
    if entitlement is None:  # pragma: no cover — created_household guarantees the row
        raise RascalError(ErrorCode.INTERNAL_ERROR, "This household has no entitlement record.")
    return entitlement


async def family_members(session: AsyncSession, family_id: uuid.UUID) -> list[User]:
    """Everyone in the household, oldest first. Deterministic so the list does not shuffle."""
    rows = await session.execute(
        select(User).where(User.family_id == family_id).order_by(User.created_at, User.id)
    )
    return list(rows.scalars().all())


async def family_children(session: AsyncSession, family_id: uuid.UUID) -> list[Child]:
    """Every child any member of this household guards, without duplicates.

    A child reached by both parents appears once. `DISTINCT` rather than a set comprehension
    so the ordering is the database's and stays stable between calls.
    """
    rows = await session.execute(
        select(Child)
        .join(Guardian, Guardian.child_id == Child.id)
        .join(User, User.id == Guardian.user_id)
        .where(User.family_id == family_id, Guardian.revoked_at.is_(None))
        .distinct()
        .order_by(Child.birthdate, Child.id)
    )
    return list(rows.scalars().all())


async def active_parent_count(session: AsyncSession, family_id: uuid.UUID) -> int:
    """How many adults are in this household already."""
    return (
        await session.scalar(
            select(func.count()).select_from(User).where(User.family_id == family_id)
        )
    ) or 0


async def issue_invite(
    session: AsyncSession,
    inviter: User,
    *,
    email: str | None = None,
    role: GuardianRole = "parent",
    now: dt.datetime | None = None,
) -> tuple[GuardianInvite, str]:
    """Mint an invite and return it with its raw token, **once**.

    The raw value is never stored and never recoverable. A lost link is re-issued, not looked up.

    Two refusals, in the order that makes the message useful:

    * **The household is already full.** Two adults is the household; a third is a different
      product, not a bigger bill, so this is a flat refusal rather than an upsell.
    * **The family is on the free tier.** Per D4 the second guardian is the thing "one price
      for the whole household" is sold on, so it is the natural paywall. The message names
      what subscribing unlocks rather than what free lacks.
    """
    now = now or dt.datetime.now(tz=dt.UTC)

    if role not in ISSUABLE_INVITE_ROLES:
        # `viewer` is phase 30 and iceboxed. The column can hold it; nothing may create one.
        raise validation_failed("Only a second parent can be invited right now.", field="role")

    if await active_parent_count(session, inviter.family_id) >= MAX_PARENTS_PER_FAMILY:
        raise RascalError(
            ErrorCode.CONFLICT,
            "This household already has two parents.",
        )

    entitlement = await entitlement_for(session, inviter.family_id)
    if not entitlement.is_subscribed:
        raise RascalError(
            ErrorCode.SUBSCRIPTION_REQUIRED,
            "Subscribing adds a second parent to your household — you will share the same "
            "children, the same timeline and the same moments, and each of you gets your own "
            "prompts each day.",
        )

    raw = secrets.token_urlsafe(TOKEN_BYTES)
    invite = GuardianInvite(
        family_id=inviter.family_id,
        invited_by_user_id=inviter.id,
        token_hash=hash_token(raw),
        email=email.strip().lower() if email else None,
        role=role,
        expires_at=now + dt.timedelta(days=INVITE_EXPIRY_DAYS),
    )
    session.add(invite)
    await session.flush()
    return invite, raw


async def find_open_invite(
    session: AsyncSession, raw_token: str, *, now: dt.datetime | None = None
) -> GuardianInvite:
    """The invite behind a raw token, if it is still acceptable.

    An expired, revoked or already-accepted link is a 404 rather than a 410: the caller is
    unauthenticated at this point and telling a stranger that a token *existed* is more than
    they need to know.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    invite = await session.scalar(
        select(GuardianInvite).where(GuardianInvite.token_hash == hash_token(raw_token))
    )
    if invite is None or not invite.is_open(now):
        raise not_found("Invite")
    return invite


async def accept_invite(
    session: AsyncSession,
    invite: GuardianInvite,
    user: User,
    *,
    now: dt.datetime | None = None,
) -> list[Child]:
    """Move `user` into the invite's household and grant them every child in it.

    **Idempotent.** Accepting twice succeeds twice and writes nothing the second time — a
    parent who taps a link, loses signal and taps again must not get an error.

    Returns the children they can now reach.
    """
    now = now or dt.datetime.now(tz=dt.UTC)

    if invite.accepted_at is not None and invite.accepted_by_user_id == user.id:
        # The second tap. Already done, and saying so as a success is the whole point.
        return await family_children(session, invite.family_id)

    if not invite.is_open(now):
        raise not_found("Invite")

    if user.family_id == invite.family_id:
        # Already a member by some other route. Still mark the invite spent.
        invite.accepted_at = now
        invite.accepted_by_user_id = user.id
        await session.flush()
        return await family_children(session, invite.family_id)

    if await active_parent_count(session, invite.family_id) >= MAX_PARENTS_PER_FAMILY:
        raise RascalError(ErrorCode.CONFLICT, "This household already has two parents.")

    children = await family_children(session, invite.family_id)

    # The household the invitee is leaving. If they were its only member it becomes empty —
    # deliberately left in place rather than deleted, because `ON DELETE RESTRICT` on
    # `users.family_id` means an orphaned family is inert, and deleting rows during an accept
    # is how a bad day removes the wrong household.
    user.family_id = invite.family_id

    # Revoked rows count as existing: a guardian row is a PK on (user_id, child_id), so
    # re-adding one would collide rather than un-revoke. Re-granting a revoked guardian is
    # open question 13's problem, not this function's.
    existing = set(
        (
            await session.execute(select(Guardian.child_id).where(Guardian.user_id == user.id))
        ).scalars()
    )
    for child in children:
        if child.id in existing:
            continue
        session.add(Guardian(user_id=user.id, child_id=child.id, role=invite.role))

    invite.accepted_at = now
    invite.accepted_by_user_id = user.id
    await session.flush()
    return children


async def revoke_invite(
    session: AsyncSession,
    invite_id: uuid.UUID,
    user: User,
    *,
    now: dt.datetime | None = None,
) -> GuardianInvite:
    """Withdraw an outstanding invite. Only somebody in the household may."""
    now = now or dt.datetime.now(tz=dt.UTC)
    invite = await session.get(GuardianInvite, invite_id)
    if invite is None or invite.family_id != user.family_id:
        raise not_found("Invite")
    if invite.revoked_at is None:
        invite.revoked_at = now
        await session.flush()
    return invite
