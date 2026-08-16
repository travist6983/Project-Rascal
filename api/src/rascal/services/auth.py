"""Turning a provider credential into a RASCAL session.

Apple is one row in `credentials`. Adding password or Google auth later means calling
`user_for_credential` with a different provider — no schema change, which is the whole point.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

from sqlalchemy import or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import CredentialProvider
from rascal.models import Credential, User

log = logging.getLogger("rascal.auth")


async def user_for_credential(
    session: AsyncSession,
    provider: CredentialProvider,
    subject_id: str,
    *,
    email: str | None = None,
    display_name: str | None = None,
) -> User:
    """Find the user behind a provider subject, creating them on first sight.

    On a return visit, `email` and `display_name` only fill gaps — Apple sends the name
    exactly once, at first authorization, and a later login must not blank it out.
    """
    existing = await session.scalar(
        select(Credential).where(
            Credential.provider == provider, Credential.subject_id == subject_id
        )
    )
    if existing is not None:
        user = await session.get(User, existing.user_id)
        assert user is not None  # FK with ON DELETE CASCADE guarantees this
        if user.email is None and email:
            user.email = email
        if user.display_name is None and display_name:
            user.display_name = display_name
        return user

    user = User(email=email, display_name=display_name)
    session.add(user)
    await session.flush()
    session.add(Credential(user_id=user.id, provider=provider, subject_id=subject_id))
    await session.flush()
    log.info("created user", extra={"user_id": str(user.id), "provider": provider})
    return user


#: How stale the recorded activity has to be before a sign-in rewrites it.
#:
#: Access tokens live fifteen minutes, so an app in active use rotates its refresh token four
#: times an hour. Writing the row on each of those is a write per request for a column read
#: once a year, on a table every authenticated request already touches. A day's granularity is
#: three orders of magnitude finer than the twelve-month clock it feeds.
ACTIVITY_GRANULARITY = dt.timedelta(days=1)


async def touch_last_sign_in(
    session: AsyncSession, user_id: uuid.UUID, *, now: dt.datetime | None = None
) -> None:
    """Record that this user was here, for D3's inactivity clock.

    **A token refresh counts, and getting that wrong deletes active users.** D3's second clock
    is `last_sign_in_at + 12 months`, and a parent who opens the app daily may not perform a
    fresh credential sign-in for years — the app holds a rotating refresh token and never asks
    again. Recording only `POST /auth/apple` would leave the most engaged families looking
    dormant, and the eligibility date would come due while they were still writing entries. So
    every path that proves the app ran on a device somebody has calls this.

    **Throttled in SQL rather than by reading first.** The `WHERE` does the comparison, so the
    common case is one UPDATE that matches no rows rather than a SELECT plus a conditional
    write, and two concurrent refreshes cannot race into two writes of the same day.

    `updated_at` is deliberately left alone: it is maintained by the `set_updated_at()` trigger
    and it is the sync cursor. Bumping every user's row four times an hour would make activity
    look like an edit to the account, and clients would refetch a record that had not changed.
    """
    moment = now or dt.datetime.now(tz=dt.UTC)
    await session.execute(
        update(User)
        .where(
            User.id == user_id,
            or_(
                User.last_sign_in_at.is_(None),
                User.last_sign_in_at < moment - ACTIVITY_GRANULARITY,
            ),
        )
        .values(last_sign_in_at=moment)
        # The trigger owns `updated_at`; this statement must not be read as an application
        # write to it. See `docs/data-model.md`.
        .execution_options(synchronize_session=False)
    )
