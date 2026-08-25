"""Complimentary entitlement: a household entitled because somebody decided so.

**This module owns one predicate and nothing else owns any part of it.** A grant is active when

    revoked_at IS NULL AND (expires_at IS NULL OR expires_at > :now)

and :func:`active_grants` is the only place that sentence is written. Everything that needs the
answer — the two family routes, `GET /today`, the notification job, the scheduler and the console
— reaches it through this function or through :func:`services.guardians.access_for`, which takes
the boolean it produces. **There is deliberately no second copy in Python**: `services/guardians.py`
never compares a grant's `expires_at` against a clock, because a second place that decides when a
grant ends is a second place that can disagree about whether somebody is entitled, and that is the
failure `test_entitlement_cadence.py` already guards for the trial.

**The clock is passed in rather than read from SQL's `now()`.** Both are the server's, which is
the property that matters — the device never decides this any more than it decides what day it is
— and an injectable `now` is what lets the suite pin the boundary rather than sleep through it.
It is the same shape :func:`services.guardians.access_for` already has.

**Issuing is not the same act as writing a tier and this module cannot do the second one.**
`entitlements.tier` keeps its single writer, the App Store webhook, per D5. A grant is additive:
it sits beside `tier` the way `trial_ends_at` does, and the union is computed rather than stored.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import ColumnElement, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.errors import not_found, validation_failed
from rascal.models import EntitlementGrant, Family

#: How many grants one console request may list. Nothing paginates it because nothing needs to:
#: a ledger with more rows than this is a product that has stopped being one owner and a
#: handful of testers, and that is the day to build the pager rather than today.
GRANT_LIST_LIMIT = 200


def unexpired(now: dt.datetime):
    """*Not revoked and not run out* — **the one definition of a live grant.**

    The clock half of the predicate, with no household in it, so a caller reading many families
    at once can apply it to a whole set without restating it. :func:`active_grants` is this
    scoped to one household and is what almost everything wants.

    `expires_at > :now` is strict, so a grant expires *at* its expiry rather than a moment
    after — the same edge `access_for` takes for the trial, stated here so it is a decision
    rather than an accident of `>` versus `>=`.
    """
    return EntitlementGrant.revoked_at.is_(None) & (
        EntitlementGrant.expires_at.is_(None) | (EntitlementGrant.expires_at > now)
    )


def active_grants(family_id: ColumnElement[uuid.UUID] | uuid.UUID, now: dt.datetime):
    """:func:`unexpired`, scoped to one household.

    Takes either a literal family id or a column, so the same sentence serves a single-household
    lookup and a join in the scheduler's per-parent query. A caller that needs the boolean
    without the row uses :func:`has_active_grant`.
    """
    return (EntitlementGrant.family_id == family_id) & unexpired(now)


def has_active_grant(family_id: ColumnElement[uuid.UUID], now: dt.datetime):
    """A correlated `EXISTS`, for the two paths that read many households at once.

    `services/scheduler.py::_active_parents` and `services/admin_metrics.py::recent_signups` both
    answer "is this household entitled" for a page of rows in one query, and neither can afford a
    lookup per row. They select this beside the entitlement columns and hand the boolean to
    `access_for(granted=…)`, so the formula still lives in exactly one place.
    """
    return select(1).where(unexpired(now)).exists()  # MUTATED


async def active_grant_for(
    session: AsyncSession, family_id: uuid.UUID, *, now: dt.datetime | None = None
) -> EntitlementGrant | None:
    """The grant currently entitling this household, or `None`.

    **Which one, when a household holds several.** The one that keeps them entitled longest: a
    perpetual grant first, then the furthest-out expiry. That is the row whose `expires_at`
    answers *"when does this household stop being entitled"*, which is the only question the wire
    field exists for — picking the newest instead would report an expiry the household will sail
    straight past because an older, longer grant is still holding.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    return await session.scalar(
        select(EntitlementGrant)
        .where(active_grants(family_id, now))
        # `nullsfirst` on a descending order puts perpetual ahead of every date. The two
        # tie-breaks are not decoration: two grants with the same expiry must resolve the same
        # way on two consecutive reads, or the console's expiry line flickers between them.
        .order_by(
            EntitlementGrant.expires_at.desc().nullsfirst(),
            EntitlementGrant.granted_at.desc(),
            EntitlementGrant.id.desc(),
        )
        .limit(1)
    )


async def grants_for(
    session: AsyncSession, *, family_id: uuid.UUID | None = None
) -> list[EntitlementGrant]:
    """The ledger, newest first. Every row, including revoked and expired ones.

    **Deliberately unfiltered.** This is the console's history view and a ledger that hides what
    was withdrawn is not a ledger. `EntitlementGrant.status` renders each row's standing.
    """
    query = select(EntitlementGrant).order_by(
        EntitlementGrant.granted_at.desc(), EntitlementGrant.id.desc()
    )
    if family_id is not None:
        query = query.where(EntitlementGrant.family_id == family_id)
    rows = await session.execute(query.limit(GRANT_LIST_LIMIT))
    return list(rows.scalars().all())


async def issue_grant(
    session: AsyncSession,
    *,
    family_id: uuid.UUID,
    granted_by: uuid.UUID,
    reason: str,
    expires_at: dt.datetime | None = None,
    now: dt.datetime | None = None,
) -> EntitlementGrant:
    """Write one grant. **`granted_by` is a parameter, never a request field.**

    The route passes the bearer token's subject. Nothing in the body can reach this argument, and
    a test asserts that a body carrying `granted_by` is ignored rather than honoured — an audit
    column a caller can set is an audit column that says whatever the caller wanted it to.

    Three refusals, in the order a person would hit them:

    * **No such household.** A 404, not a 500 — this id was typed into a console by a human and a
      wrong one is a typo, the same argument :func:`services.guardians.set_trial_ends_at` makes.
    * **An empty reason.** The CHECK would catch it as an integrity error; catching it here makes
      it a 422 with a field name instead of a rendered database complaint.
    * **An expiry already in the past.** It would be legal — the row would simply be inactive from
      the moment it was written — and that is exactly why it is refused: a grant that entitles
      nobody, sitting in a ledger looking like a grant, is worse than a rejected form.
    """
    now = now or dt.datetime.now(tz=dt.UTC)

    if await session.get(Family, family_id) is None:
        raise not_found("Household")

    reason = reason.strip()
    if not reason:
        raise validation_failed("A grant needs a reason.", field="reason")

    if expires_at is not None and expires_at <= now:
        raise validation_failed(
            "That expiry has already passed, so the grant would entitle nobody. "
            "Leave it empty for a grant with no end date.",
            field="expires_at",
        )

    grant = EntitlementGrant(
        family_id=family_id,
        granted_at=now,
        expires_at=expires_at,
        reason=reason,
        granted_by=granted_by,
    )
    session.add(grant)
    await session.flush()
    return grant


async def revoke_grant(
    session: AsyncSession,
    grant_id: uuid.UUID,
    *,
    revoked_by: uuid.UUID,
    now: dt.datetime | None = None,
) -> EntitlementGrant:
    """Withdraw a grant. **Idempotent, and there is no `DELETE`.**

    Revoking twice succeeds and writes nothing the second time, the same shape
    `services.guardians.revoke_invite` already has — a console click that times out and gets
    clicked again must not be an error.

    The row stays. Soft deletes on everything is a standing rule and this is the table where it
    matters most: the record of who you gave something to, why, and when you took it back is the
    part a support conversation actually needs.

    **Revocation takes effect on the next read**, which is immediate everywhere it matters:
    every entitlement surface computes the answer per request, so there is no cached boolean to
    invalidate and no job to wait for.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    grant = await session.get(EntitlementGrant, grant_id)
    if grant is None:
        raise not_found("Grant")
    if grant.revoked_at is None:
        grant.revoked_at = now
        grant.revoked_by = revoked_by
        await session.flush()
    return grant
