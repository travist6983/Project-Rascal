"""The household, and the invite that adds a second parent to it.

Two routers, because they have different authentication shapes and mixing them would put an
unauthenticated route inside a file whose every other route requires a bearer token — which
is exactly how one of them eventually loses its guard.

`/families/me` is about the caller's own household, so it needs no `child_access`: the
household is reached through `user.family_id` and there is no id in the path to forge.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from fastapi import APIRouter, Path, status
from sqlalchemy import select

from rascal.deps import CurrentUser, SessionDep
from rascal.errors import not_found
from rascal.models import Guardian, GuardianInvite, User
from rascal.schemas.family import (
    FamilyOut,
    GuardianOut,
    InviteAccepted,
    InviteCreate,
    InviteCreated,
    InviteOut,
    InvitePreview,
)
from rascal.services.guardians import (
    accept_invite,
    entitlement_for,
    family_children,
    family_members,
    find_open_invite,
    hash_token,
    issue_invite,
    revoke_invite,
)

router = APIRouter(prefix="/families", tags=["families"])
invites_router = APIRouter(prefix="/invites", tags=["families"])


async def _pending_invites(session, family_id: uuid.UUID) -> list[InviteOut]:
    now = dt.datetime.now(tz=dt.UTC)
    rows = await session.execute(
        select(GuardianInvite)
        .where(
            GuardianInvite.family_id == family_id,
            GuardianInvite.accepted_at.is_(None),
            GuardianInvite.revoked_at.is_(None),
            GuardianInvite.expires_at > now,
        )
        .order_by(GuardianInvite.created_at)
    )
    return [
        InviteOut(
            id=invite.id,
            email=invite.email,
            role=invite.role,
            expires_at=invite.expires_at,
            created_at=invite.created_at,
        )
        for invite in rows.scalars().all()
    ]


@router.get("/me", response_model=FamilyOut)
async def read_my_family(session: SessionDep, user: CurrentUser) -> FamilyOut:
    """The caller's household: who is in it, what it is entitled to, who has been asked."""
    entitlement = await entitlement_for(session, user.family_id)
    members = await family_members(session, user.family_id)

    # One query for every guardian row belonging to this household's members, so the role and
    # grant date come from the rows that actually govern access rather than being inferred
    # from family membership.
    member_ids = [member.id for member in members]
    grants = {}
    if member_ids:
        rows = await session.execute(
            select(Guardian.user_id, Guardian.role, Guardian.granted_at)
            .where(Guardian.user_id.in_(member_ids), Guardian.revoked_at.is_(None))
            .order_by(Guardian.granted_at)
        )
        for user_id, role, granted_at in rows.all():
            # The earliest grant is when they joined the household in any meaningful sense.
            grants.setdefault(user_id, (role, granted_at))

    guardians = [
        GuardianOut(
            user_id=member.id,
            display_name=member.display_name,
            role=grants.get(member.id, ("parent", member.created_at))[0],
            granted_at=grants.get(member.id, ("parent", member.created_at))[1],
            is_you=member.id == user.id,
        )
        for member in members
    ]
    return FamilyOut(
        family_id=user.family_id,
        tier=entitlement.tier,
        guardians=guardians,
        pending_invites=await _pending_invites(session, user.family_id),
    )


@router.post("/me/invites", response_model=InviteCreated, status_code=status.HTTP_201_CREATED)
async def create_invite(
    body: InviteCreate, session: SessionDep, user: CurrentUser
) -> InviteCreated:
    """Mint an invite link. **402 on the free tier** — the second parent is what a
    subscription is sold on, per D4.

    The raw token is in this response and nowhere else, ever.
    """
    invite, raw = await issue_invite(session, user, email=body.email, role=body.role)
    return InviteCreated(
        id=invite.id,
        email=invite.email,
        role=invite.role,
        expires_at=invite.expires_at,
        created_at=invite.created_at,
        token=raw,
    )


@router.delete("/me/invites/{invite_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_invite(
    invite_id: Annotated[uuid.UUID, Path()], session: SessionDep, user: CurrentUser
) -> None:
    """Withdraw an outstanding invite. Idempotent — revoking twice is a success."""
    await revoke_invite(session, invite_id, user)


@invites_router.get("/{token}", response_model=InvitePreview)
async def preview_invite(token: Annotated[str, Path()], session: SessionDep) -> InvitePreview:
    """**Unauthenticated on purpose** — you have to be able to see what a link is before you
    sign in to accept it.

    What it discloses is deliberately thin: who invited you, the role, when it expires, and
    the children's *first names*. Enough for the right person to recognise their own
    household; not enough to be worth harvesting. An unknown, expired, revoked or spent token
    is a flat 404 rather than a 410, because the caller is a stranger at this point and that
    a token once existed is more than they need.
    """
    invite = await find_open_invite(session, token)
    inviter = await session.get(User, invite.invited_by_user_id)
    children = await family_children(session, invite.family_id)
    return InvitePreview(
        invited_by=inviter.display_name if inviter else None,
        role=invite.role,
        expires_at=invite.expires_at,
        children=[child.name for child in children],
    )


@invites_router.post("/{token}/accept", response_model=InviteAccepted)
async def accept(
    token: Annotated[str, Path()], session: SessionDep, user: CurrentUser
) -> InviteAccepted:
    """Join the household. Authenticated, because it writes to the caller's own account.

    Idempotent: the same user accepting the same link twice succeeds twice and writes nothing
    the second time. A parent who taps a link, loses signal and taps again gets a household,
    not an error.
    """
    # Deliberately not `find_open_invite`: a *spent* invite must reach `accept_invite` so
    # the same user re-tapping their own link gets the idempotent success rather than a 404.
    invite = await session.scalar(
        select(GuardianInvite).where(GuardianInvite.token_hash == hash_token(token))
    )
    if invite is None:
        raise not_found("Invite")
    children = await accept_invite(session, invite, user)
    return InviteAccepted(family_id=invite.family_id, children=[child.id for child in children])
