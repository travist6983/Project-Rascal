"""Deleting an account, seven days after somebody asks.

Settled in `decisions.md` open item 14 on Aug 17, 2026, and the two answers that shape every
line below:

**The account always; the archive only when no other guardian remains.** A shared archive is not
one parent's to destroy, and the other parent did not ask for anything. Leaving a household
therefore revokes your access and removes your credentials, and the children stay exactly where
they are — until the last guardian goes, and then the archive goes with them. This is also open
item 13's answer, arriving from the other direction.

**Seven days, signed out immediately, and any sign-in cancels it.** The cancel is D3's precedent
rather than a new rule: somebody who signs back in has changed their mind. Revoking every refresh
token at request time is what makes that safe to hook where it is hooked — after revocation, the
only way to reach `touch_last_sign_in` again is a deliberate sign-in.

---

**This is the one place in the service that hard-deletes user data, and that is a deliberate
exception to `CLAUDE.md` rule 5.** Soft deletes exist so a client can learn that a row went away;
there is no client left to tell, and a `deleted_at` on an erasure request would be the service
keeping exactly what it was asked to stop keeping. The rule is right everywhere else and wrong
here, which is worth stating rather than leaving somebody to wonder whether it was forgotten.

**What is never deleted:** another guardian's archive, and any child somebody else still guards.
The tests assert what survives, not only what goes — a deletion test that only checks rows are
gone passes just as happily while the feature destroys the wrong household.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import (
    Assignment,
    Child,
    DeletionRequest,
    Entry,
    EntryTag,
    Guardian,
    GuardianInvite,
    Media,
    NotificationSend,
    PromptSuppression,
    RefreshToken,
    Tag,
    User,
)
from rascal.services import s3

log = logging.getLogger("rascal.deletion")

#: How long between asking and it happening. Settled by the owner, Aug 17, 2026.
#:
#: Stored on the row at request time rather than read here at execution time, so a request made
#: under this policy runs on the terms it was made under however this constant moves later.
GRACE_PERIOD = dt.timedelta(days=7)


async def pending_for(session: AsyncSession, user_id: uuid.UUID) -> DeletionRequest | None:
    return await session.scalar(
        select(DeletionRequest).where(
            DeletionRequest.user_id == user_id,
            DeletionRequest.cancelled_at.is_(None),
        )
    )


async def request_deletion(
    session: AsyncSession, user: User, *, now: dt.datetime | None = None
) -> DeletionRequest:
    """Start the clock, and sign them out of everywhere.

    **Idempotent.** Asking twice returns the first request rather than restarting the clock —
    a second tap must not quietly buy another seven days, and it must not create a second row
    the job would run twice.

    Every refresh token is revoked here, which does two things: it honours "signed out
    immediately", and it makes `cancel_on_sign_in` safe to hook into `touch_last_sign_in`,
    because after this only a deliberate sign-in can reach that function.
    """
    now = now or dt.datetime.now(tz=dt.UTC)

    existing = await pending_for(session, user.id)
    if existing is not None:
        return existing

    # **Both timestamps from one clock.** `requested_at` would otherwise default to the
    # database's `now()` while `execute_after` came from Python's, leaving a row whose own two
    # dates disagree about when the grace period started — harmless in effect and confusing in
    # every log line and support conversation that ever reads it.
    request = DeletionRequest(user_id=user.id, requested_at=now, execute_after=now + GRACE_PERIOD)
    session.add(request)
    await session.execute(delete(RefreshToken).where(RefreshToken.user_id == user.id))
    await session.flush()
    log.info(
        "deletion requested",
        extra={"user_id": str(user.id), "execute_after": request.execute_after.isoformat()},
    )
    return request


async def cancel_deletion(
    session: AsyncSession, user_id: uuid.UUID, *, now: dt.datetime | None = None
) -> DeletionRequest | None:
    """Withdraw a pending request. Idempotent; returns None when there was nothing to cancel."""
    now = now or dt.datetime.now(tz=dt.UTC)
    request = await pending_for(session, user_id)
    if request is None:
        return None
    request.cancelled_at = now
    await session.flush()
    log.info("deletion cancelled", extra={"user_id": str(user_id)})
    return request


async def cancel_on_sign_in(
    session: AsyncSession, user_id: uuid.UUID, *, now: dt.datetime | None = None
) -> None:
    """D3's rule, applied here: signing in cancels an outstanding deletion outright.

    Called from `auth.touch_last_sign_in`, which is the one function every path that proves the
    app ran on a device somebody has already calls — its own docstring makes that argument for
    the inactivity clock, and it is the same set of paths this needs. Hooking it there means a
    new sign-in route cannot forget to cancel.

    **Safe there only because `request_deletion` revokes every refresh token.** Without that, a
    phone in a drawer rotating its token in the background would cancel a deletion its owner
    still wanted.
    """
    await cancel_deletion(session, user_id, now=now)


# --- The destructive half --------------------------------------------------------------------


async def _sole_guardian_children(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    """Children this user guards that **nobody else does.**

    The whole cascade rests on this query, so it is written to be read: for each child the user
    has a live `guardians` row for, count the live rows belonging to anybody else. Zero means
    the archive leaves with them.

    A revoked guardian does not count as somebody else — a revoked row is not access, and
    treating it as a reason to keep an archive would strand it behind nobody.
    """
    # **An alias, and `NOT EXISTS` rather than `count() == 0`.** The outer query already joins
    # `guardians`, so an unaliased inner reference correlates to *that* row and SQLAlchemy
    # drops the subquery's FROM entirely — it raises rather than silently returning nonsense,
    # which is the one mercy in this class of bug. `NOT EXISTS` also stops at the first other
    # guardian instead of counting all of them.
    other = aliased(Guardian)
    someone_else_guards = (
        select(other.user_id)
        .where(
            other.child_id == Child.id,
            other.user_id != user_id,
            other.revoked_at.is_(None),
        )
        .correlate(Child)
        .exists()
    )
    rows = await session.execute(
        select(Child.id)
        .join(Guardian, Guardian.child_id == Child.id)
        .where(
            Guardian.user_id == user_id,
            Guardian.revoked_at.is_(None),
            ~someone_else_guards,
        )
    )
    return list(rows.scalars().all())


async def _media_keys(session: AsyncSession, child_ids: list[uuid.UUID]) -> list[str]:
    """Every object key belonging to these children, through their entries.

    Read **before** the rows go. Deleting the rows first would leave the bytes in the bucket
    with nothing left pointing at them — an orphan nobody could find to remove, which is the
    worst possible outcome for a feature whose entire promise is that the data is gone.
    """
    if not child_ids:
        return []
    rows = await session.execute(
        select(Media.s3_key)
        .join(Entry, Entry.id == Media.entry_id)
        .where(Entry.child_id.in_(child_ids))
    )
    return [key for key in rows.scalars().all() if key]


async def execute_deletion(
    session: AsyncSession,
    request: DeletionRequest,
    settings: Settings,
    *,
    now: dt.datetime | None = None,
) -> dict[str, int]:
    """Carry out one request. Returns a count per thing removed, for the log line.

    **Order matters and is not cosmetic.** Object keys are read first, because the rows are what
    point at them. Then the children that leave with this user, then the user's own rows, then
    the user. The objects are deleted last, after the database work has succeeded — a failed
    transaction that had already emptied the bucket would leave rows pointing at nothing, and
    that is the one direction of this that cannot be retried into correctness.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    user_id = request.user_id

    departing = await _sole_guardian_children(session, user_id)
    keys = await _media_keys(session, departing)

    removed = {"children": len(departing), "objects": len(keys)}

    if departing:
        # `entries` and `assignments` cascade from `children` in the schema; `media` and
        # `entry_tags` cascade from `entries`. These are stated rather than relied upon for the
        # tables whose FK is not `ON DELETE CASCADE`, and the child delete carries the rest.
        await session.execute(
            delete(NotificationSend).where(NotificationSend.child_id.in_(departing))
        )
        await session.execute(
            delete(PromptSuppression).where(PromptSuppression.child_id.in_(departing))
        )
        await session.execute(
            delete(EntryTag).where(
                EntryTag.tag_id.in_(select(Tag.id).where(Tag.child_id.in_(departing)))
            )
        )
        await session.execute(delete(Tag).where(Tag.child_id.in_(departing)))
        await session.execute(delete(Assignment).where(Assignment.child_id.in_(departing)))
        await session.execute(delete(Child).where(Child.id.in_(departing)))

    # Their access to everything else — the children somebody *else* still guards. Those
    # archives are untouched; this is the row that made them reachable.
    await session.execute(delete(Guardian).where(Guardian.user_id == user_id))
    await session.execute(
        delete(GuardianInvite).where(GuardianInvite.invited_by_user_id == user_id)
    )

    # `credentials`, `devices`, `refresh_tokens`, `idempotency_keys` and the request row itself
    # are all `ON DELETE CASCADE` from `users`, so the user delete carries them.
    await session.execute(delete(User).where(User.id == user_id))
    await session.flush()

    # Last, and only once the database work has held.
    await s3.delete_objects(keys, settings)

    log.info(
        "deletion executed", extra={"children": removed["children"], "objects": removed["objects"]}
    )
    return removed


async def run_due_deletions(
    session: AsyncSession, settings: Settings, *, now: dt.datetime | None = None
) -> dict[str, int]:
    """Every request whose grace period has elapsed. The job's entry point.

    **One transaction per request**, committed as it goes: a batch that rolled back on the tenth
    account would undo nine deletions somebody had already been told were done, and "we deleted
    your account" is not a thing to take back.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    due = list(
        (
            await session.execute(
                select(DeletionRequest).where(
                    DeletionRequest.cancelled_at.is_(None),
                    DeletionRequest.execute_after <= now,
                )
            )
        )
        .scalars()
        .all()
    )

    totals = {"accounts": 0, "children": 0, "objects": 0}
    for request in due:
        counts = await execute_deletion(session, request, settings, now=now)
        await session.commit()
        totals["accounts"] += 1
        totals["children"] += counts["children"]
        totals["objects"] += counts["objects"]

    if due:
        log.info("deletion run", extra=totals)
    return totals


def not_pending() -> RascalError:
    return RascalError(ErrorCode.NOT_FOUND, "No deletion is scheduled for this account.")
