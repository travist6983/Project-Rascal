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

from fastapi import APIRouter, Depends, Path, status
from sqlalchemy import select

from rascal.deps import CurrentUser, SessionDep, family_access
from rascal.errors import not_found
from rascal.models import Guardian, GuardianInvite, User
from rascal.schemas.family import (
    EntitlementOut,
    FamilyOut,
    GuardianOut,
    InviteAccepted,
    InviteCreate,
    InviteCreated,
    InviteOut,
    InvitePreview,
)
from rascal.services.grants import active_grant_for
from rascal.services.guardians import (
    accept_invite,
    access_for,
    eligible_at,
    entitlement_for,
    family_members,
    find_open_invite,
    hash_token,
    invited_children,
    is_payer_for,
    issue_invite,
    last_sign_in_for,
    revoke_invite,
)
from rascal.services.membership import membership_signals

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

    # **A member with no guardian row reports `granted_at: null`, not a fabricated date.**
    # It is a reachable state — a household whose only child was created before the second
    # parent joined and then deleted, or a member mid-way through accepting — and inventing
    # `member.created_at` there would put a confident wrong timestamp on a screen. `role`
    # falls back to `parent` because membership *is* parenthood in this household model;
    # the date is the part nothing knows.
    guardians = [
        GuardianOut(
            user_id=member.id,
            display_name=member.display_name,
            role=grants[member.id][0] if member.id in grants else "parent",
            granted_at=grants[member.id][1] if member.id in grants else None,
            is_you=member.id == user.id,
        )
        for member in members
    ]
    # One authority, read rather than re-derived. `access` here and `access` on
    # `GET /families/{id}/entitlement` and on `GET /children/{id}/today` are the same
    # function over the same row — see `services/guardians.access_for`.
    #
    # The grant is fetched here rather than through `access_for_family` because this handler
    # already holds the `entitlements` row for `lapsed_at` and `is_payer`, and the row itself
    # is wanted for `grant_expires_at` — one indexed lookup, not two.
    grant = await active_grant_for(session, user.family_id)
    access = access_for(entitlement, granted=grant is not None)
    # Phase 113's four additive fields. Three of them are reads of rows this handler already
    # has — `lapsed_at` and `is_payer` come off the `entitlements` row fetched at the top, so
    # neither costs a query — and `membership_signals` is one indexed lookup that a household
    # on the free tier short-circuits before making.
    signals = await membership_signals(session, user.family_id, tier=entitlement.tier)
    return FamilyOut(
        family_id=user.family_id,
        tier=entitlement.tier,
        access=access.access,
        trial_ends_at=access.trial_ends_at,
        # Phase 121's three additive fields, the same three `GET /families/{id}/entitlement`
        # reports and from the same computation. `entitled` is the union every gate now reads;
        # `tier` above is untouched and still means what Apple said.
        entitled=access.entitled,
        entitlement_source=access.source,
        grant_expires_at=grant.expires_at if grant is not None else None,
        lapsed_at=entitlement.lapsed_at,
        plan=signals.plan,
        billing_retry=signals.billing_retry,
        # **`None` where nobody knows, never `False`.** See `services.guardians.is_payer_for`:
        # a client hides Apple's management sheet on `False`, so a null answered as `False`
        # takes that control away from a parent who is paying.
        is_payer=is_payer_for(entitlement, user.id),
        guardians=guardians,
        pending_invites=await _pending_invites(session, user.family_id),
    )


@router.get("/{family_id}/entitlement", response_model=EntitlementOut)
async def read_entitlement(
    session: SessionDep,
    family_id: Annotated[uuid.UUID, Depends(family_access())],
) -> EntitlementOut:
    """What this household is entitled to. **Any guardian may read it.**

    **`GET /families/me` reports the same `tier` and `access` and this route does not
    second-guess either** — both call `entitlement_for` against the same row and hand it to
    the same `access_for`, so there is one authority and (since phase 107) three shapes. Two
    routes that computed the answer separately is the bug D4 and D5 exist to prevent; three
    routes that render one computation is a household screen, a subscription screen and a
    board that has to explain why half of it is locked.

    `eligible_at` is computed here, per request, from two clocks that both move. See
    `services/guardians.eligible_at`.
    """
    entitlement = await entitlement_for(session, family_id)
    grant = await active_grant_for(session, family_id)
    access = access_for(entitlement, granted=grant is not None)
    # The same derivation `GET /families/me` reports, from the same function over the same
    # ledger — one authority, two shapes, in the pattern `access` already follows.
    signals = await membership_signals(session, family_id, tier=entitlement.tier)
    return EntitlementOut(
        family_id=family_id,
        tier=entitlement.tier,
        access=access.access,
        trial_ends_at=access.trial_ends_at,
        entitled=access.entitled,
        entitlement_source=access.source,
        grant_expires_at=grant.expires_at if grant is not None else None,
        lapsed_at=entitlement.lapsed_at,
        plan=signals.plan,
        billing_retry=signals.billing_retry,
        # **Deliberately still `entitlement.tier` and not `access.entitled`.** `eligible_at` is
        # D3's deletion clock and it starts when a *subscription* ends. A trial running out is
        # not a lapse, `lapsed_at` stays null through one, and passing the trial in here would
        # be the phase that quietly points a deletion timer at every household that tried the
        # app for a fortnight and stopped.
        #
        # **`granted` is passed and the trial still is not, and the asymmetry is the point.** A
        # grant is somebody deciding this household is entitled, so it stops the clock exactly
        # as a subscription does — the case that matters is a household that lapsed for real and
        # was then given a grant, which carries a live `lapsed_at` and must not read a deletion
        # date while it is fully entitled.
        eligible_at=eligible_at(
            entitlement.tier,
            entitlement.lapsed_at,
            await last_sign_in_for(session, family_id),
            granted=grant is not None,
        ),
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
    children = await invited_children(session, invite.invited_by_user_id)
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
