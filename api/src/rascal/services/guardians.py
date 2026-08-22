"""The household: creating one, inviting a second parent into it, and accepting.

**Authorization is unchanged by everything in this file.** `deps.require_child_access` reads
`guardians` and only `guardians`, so accepting an invite grants access by writing the rows it
already reads — no new check, no second code path, nothing to keep in sync. That is why
`accept_invite` writes a `Guardian` row per child rather than anything cleverer.

The tier gate lives here rather than in the router so that "who may invite" is one function
with one answer, testable without HTTP.
"""

from __future__ import annotations

import calendar
import datetime as dt
import hashlib
import secrets
import uuid
from dataclasses import dataclass

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    INACTIVITY_ELIGIBILITY_MONTHS,
    INVITE_EXPIRY_DAYS,
    ISSUABLE_INVITE_ROLES,
    LAPSE_ELIGIBILITY_MONTHS,
    MAX_PARENTS_PER_FAMILY,
    AccessState,
    GuardianRole,
    Tier,
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


@dataclass(frozen=True)
class Access:
    """What one household may reach right now. **Computed per read, never stored.**

    Three fields and no behaviour, deliberately: `entitled` is what the server branches on,
    `access` is what goes on the wire, and `trial_ends_at` is carried through so a caller that
    has this object never has to go back to the row for it.
    """

    #: The column, unchanged and still meaning exactly what it meant before phase 107.
    tier: Tier
    #: The column. Null means *no trial on this household*, not *a trial that ended*.
    trial_ends_at: dt.datetime | None
    #: **The one boolean every gate in this codebase branches on.**
    entitled: bool
    #: The wire value. `subscribed` beats `trial`; `free` is what is left.
    access: AccessState


def access_for(entitlement: Entitlement, *, now: dt.datetime | None = None) -> Access:
    """**The one authority on whether a household is entitled.** Pure — a row and a clock in,
    an answer out, no database.

    `api-contract.md` describes `GET /families/me` and `GET /families/{id}/entitlement` as
    *"one authority with two shapes"*. Phase 107 added a third shape — `GET /today`'s `access`,
    `trial_ends_at` and `locked[]` — and it is a shape rather than an authority because it
    reads this function. **Nothing in `src/` may re-derive this formula**, and
    `test_entitlement_cadence.py` greps for the attempt: an entitlement check copied into a
    second place is the defect that eventually disagrees with the first one, on the question of
    whether somebody paid.

    Two properties worth stating because both are load-bearing:

    * **`subscribed` beats `trial`.** A subscriber holding a stale future `trial_ends_at` reads
      `subscribed`, so a client never renders a paying household as one on a countdown.
    * **A trial expiring is not a lapse.** Nothing here touches `lapsed_at` or `eligible_at`;
      `lapsed_at` is about a *subscription* ending, per D3, and a trial quietly running out
      must not start a deletion clock on somebody's photographs. The two clocks are separate on
      purpose and :func:`eligible_at` below still keys off `tier` and `lapsed_at` alone.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    subscribed = entitlement.tier == "subscribed"
    in_trial = entitlement.trial_ends_at is not None and now < entitlement.trial_ends_at
    entitled = subscribed or in_trial
    return Access(
        tier=entitlement.tier,
        trial_ends_at=entitlement.trial_ends_at,
        entitled=entitled,
        access="subscribed" if subscribed else ("trial" if entitled else "free"),
    )


async def access_for_family(
    session: AsyncSession, family_id: uuid.UUID, *, now: dt.datetime | None = None
) -> Access:
    """:func:`entitlement_for` and :func:`access_for`, in the one call most readers want."""
    return access_for(await entitlement_for(session, family_id), now=now)


def is_payer_for(entitlement: Entitlement, user_id: uuid.UUID) -> bool | None:
    """Is *user_id* the one paying for this household? **`None` means nobody knows.**

    Three values, and the third is the entire reason this is a function rather than a
    comparison written at the call site.

    * `True` — this caller is the recorded payer.
    * `False` — somebody else in the household is, and we know who.
    * `None` — `payer_user_id` is null, so **the question is unanswered**.

    **`None` must never collapse to `False`, and the cost of getting it wrong is one-sided.**
    A client hides Apple's subscription-management control on an explicit `False` — that is
    correct, because sending a non-payer to a sheet that will not list this subscription is a
    dead end. Doing the same on a null takes the control away from a parent who *is* paying
    and leaves them no way to change their card, on the strength of a column nobody filled in.
    Saying nothing is strictly better than a confident wrong answer here, so the null case
    stays null all the way to the wire.

    **Null is common rather than exceptional**, which is why this matters:
    `services/app_store_events._set_payer` deliberately declines to write a payer when the
    household has two guardians — `appAccountToken` carries a *family* id, so Apple's
    notification never names a user, and a wrong payer means D3a's win-back emails the wrong
    parent about the other one's cancelled card. Two guardians is exactly the case where "are
    you the payer" is a meaningful question, so the field is unknown precisely where it would
    be most useful. `docs/blocked.md` carries what it would take to fix that; it is a client
    change, not a server one.

    **The raw `payer_user_id` is never returned in its place.** It is another household
    member's UUID, and "who pays" is answerable as a yes/no about the caller without putting a
    second person's identifier in a response body.
    """
    if entitlement.payer_user_id is None:
        return None
    return entitlement.payer_user_id == user_id


async def set_trial_ends_at(
    session: AsyncSession, family_id: uuid.UUID, trial_ends_at: dt.datetime | None
) -> Entitlement:
    """Move or clear one household's trial. **The admin console's only entitlement lever.**

    It exists because the owner is the only user and will otherwise never see the free tier he
    is designing: setting the date to yesterday drops a household to `free`, setting it to next
    month puts it back, and clearing it leaves `free` with no trial at all.

    **All of that is true only while `tier` is `free`.** `subscribed` beats `trial` in
    :func:`access_for`, so a subscribed household reads `subscribed` whatever this writes. The
    date is still stored, and it matters the day the subscription lapses — but the access state
    does not move. **The owner's own household is exactly that case**, by `runbook-deploy.md`
    §7a, which is worth stating in the same breath as "it exists because the owner is the only
    user": reaching the free tier from there needs §7a's statement run in reverse first. This
    function does not do that, and must not — `tier` has one writer.

    **It deliberately cannot write `tier`, and that is the whole reason this is the lever.** D5
    reserves `tier` for the App Store webhook and a test asserts it has exactly one writer, so
    an admin control that set `tier` would either fail that test or quietly become the second
    writer of the column the decision exists to protect — and the second writer would be a
    human clicking a button, disagreeing with Apple. Moving `trial_ends_at` reaches both states
    this console needs without going near it.

    `None` clears the trial. That is a real value rather than a reset: a household with a null
    `trial_ends_at` has no trial, which is not the same as one whose trial ended.

    **Deliberately not :func:`entitlement_for`, and the difference is a 500 versus a 404.**
    That function treats a missing row as an internal error, correctly — every other caller
    reaches it through the caller's own `users.family_id`, so an absent entitlement there is a
    broken invariant rather than a bad input. This one takes an id **a human typed into a
    console**, where a wrong one is a typo. Routing a typo through the internal-error branch
    would turn a mistyped UUID into a 500 and make a `# pragma: no cover` line reachable from
    an HTTP route.
    """
    entitlement = await session.get(Entitlement, family_id)
    if entitlement is None:
        raise not_found("Household")
    entitlement.trial_ends_at = trial_ends_at
    await session.flush()
    return entitlement


async def last_sign_in_for(session: AsyncSession, family_id: uuid.UUID) -> dt.datetime | None:
    """`MAX(users.last_sign_in_at)` across the household's members, or `None`.

    **A MAX over another table, computed on demand and never stored.** `data-model.md`
    describes a `last_sign_in_at` on `entitlements` as a denormalisation that must never be
    written independently, and the live table deliberately does not have one — a column whose
    only correct value is this MAX is a column that drifts, and in this particular table a
    drifted value deletes photographs.

    `None` when nobody has ever signed in — every guardian's column is null. That is a real
    state (an account created by an invite that was accepted and never used again), not a
    missing row, and it means the inactivity clock has not started.
    """
    return await session.scalar(
        select(func.max(User.last_sign_in_at)).where(User.family_id == family_id)
    )


def eligible_at(
    tier: str, lapsed_at: dt.datetime | None, last_sign_in_at: dt.datetime | None
) -> dt.date | None:
    """When a lapsed household's **media** becomes eligible for deletion, per D3.

    `max(lapsed_at + 24 months, last_sign_in_at + 12 months)`, **computed per request and
    never stored.** Both clocks move: a lapsed parent who opens the app pushes the second one
    forward, and D3 makes any sign-in inside the warning window cancel deletion outright. A
    stored deadline would be a date that was true when it was written.

    `None` while the household is `subscribed` — there is no deletion clock on a paying
    household — and `None` when it has lapsed but nothing recorded when.

    **This computes eligibility and nothing deletes on it.** Phase 38 owns the notice
    sequence and the job, and D3's hard stop is that deletion may not fire unless a notice was
    confirmed delivered on some channel. This function is what a client displays and what that
    phase will schedule against.
    """
    if tier == "subscribed" or lapsed_at is None:
        return None
    candidates = [_add_months(lapsed_at, LAPSE_ELIGIBILITY_MONTHS)]
    if last_sign_in_at is not None:
        candidates.append(_add_months(last_sign_in_at, INACTIVITY_ELIGIBILITY_MONTHS))
    return max(candidates).date()


def _add_months(moment: dt.datetime, months: int) -> dt.datetime:
    """Calendar months, clamped to the length of the target month.

    `dt.timedelta` has no month, and 365-day arithmetic drifts off a leap year. Both spans
    here are whole years today, so the clamp only matters for a lapse dated Feb 29 — which is
    exactly the kind of date that produces one support conversation every four years.
    """
    month_index = moment.month - 1 + months
    year = moment.year + month_index // 12
    month = month_index % 12 + 1
    day = min(moment.day, calendar.monthrange(year, month)[1])
    return moment.replace(year=year, month=month, day=day)


async def family_members(session: AsyncSession, family_id: uuid.UUID) -> list[User]:
    """Everyone in the household, oldest first. Deterministic so the list does not shuffle."""
    rows = await session.execute(
        select(User).where(User.family_id == family_id).order_by(User.created_at, User.id)
    )
    return list(rows.scalars().all())


async def invited_children(session: AsyncSession, inviter_id: uuid.UUID) -> list[Child]:
    """The children an invite actually offers: the ones **the inviter** guards.

    **Scoped to the inviter rather than to the household, and the difference is not
    theoretical.** An invitee may already have an archive of their own — they used the app
    solo before being invited into a partner's household. Defining the household's children
    as *"every child any member guards"* would silently absorb that person's existing child
    into the household the moment they accepted, so a later reader of the household would see
    a child the other parent has no guardian row for and never agreed to share.

    Whether two existing archives should merge is a real product question and nobody has
    answered it. Until somebody does, accepting an invite moves you **into** a household and
    grants you its children; it does not contribute yours. `POST /children` grants every
    member from then on, so from the first shared child onward the two definitions coincide.

    `DISTINCT` rather than a set comprehension so the ordering is the database's and stays
    stable between calls.
    """
    rows = await session.execute(
        select(Child)
        .join(Guardian, Guardian.child_id == Child.id)
        .where(Guardian.user_id == inviter_id, Guardian.revoked_at.is_(None))
        .distinct()
        .order_by(Child.birthdate, Child.id)
    )
    return list(rows.scalars().all())


async def active_parent_count(session: AsyncSession, family_id: uuid.UUID) -> int:
    """How many adults are in this household already.

    Callers that go on to *write* based on the answer must hold :func:`lock_household` first.
    """
    return (
        await session.scalar(
            select(func.count()).select_from(User).where(User.family_id == family_id)
        )
    ) or 0


async def lock_household(session: AsyncSession, family_id: uuid.UUID) -> None:
    """Take a row lock on the family, so two accepts into it cannot both pass the cap.

    **The cap is a read-then-write and nothing in the schema enforces it.** "At most two rows
    in `users` for a given `family_id`" is not something a unique index can say, so without
    this two invitees tapping their links in the same second both read one member, both pass,
    and the household ends up with three adults — over a paywall, which is the direction that
    matters commercially as well as correctness-wise.

    A row lock rather than an advisory lock because the row already exists and is the natural
    thing to serialise on: `pg_advisory_xact_lock` would need a hash of the UUID and would
    collide across unrelated families for no benefit. Accepts into *different* households do
    not contend, which is the whole reason to lock the family rather than the table.

    `issue_invite` deliberately does **not** take it. Minting an invite is not the write that
    breaks the cap; accepting is, and a courtesy check at issue time that is occasionally
    stale costs nothing.
    """
    await session.execute(select(Family.id).where(Family.id == family_id).with_for_update())


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
        return await invited_children(session, invite.invited_by_user_id)

    if not invite.is_open(now):
        raise not_found("Invite")

    if user.family_id == invite.family_id:
        # Already a member by some other route. Still mark the invite spent.
        invite.accepted_at = now
        invite.accepted_by_user_id = user.id
        await session.flush()
        return await invited_children(session, invite.invited_by_user_id)

    # Serialise before counting. Everything from here to the flush is the read-then-write the
    # cap depends on, and this is the only thing standing behind it.
    await lock_household(session, invite.family_id)
    if await active_parent_count(session, invite.family_id) >= MAX_PARENTS_PER_FAMILY:
        raise RascalError(ErrorCode.CONFLICT, "This household already has two parents.")

    children = await invited_children(session, invite.invited_by_user_id)

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
