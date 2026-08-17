"""Turning a provider credential into a RASCAL session.

Apple is one row in `credentials`. Adding password or Google auth later means calling
`user_for_credential` with a different provider — no schema change, which is the whole point.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import CredentialProvider
from rascal.errors import ErrorCode, RascalError, not_found
from rascal.models import Credential, User
from rascal.services.guardians import create_household

log = logging.getLogger("rascal.auth")


def _gap_fill(user: User, *, email: str | None, display_name: str | None) -> None:
    """First-non-null-wins, stated rather than accidental.

    A second credential may *fill* `users.email` and `users.display_name` and may never
    overwrite them. Apple sends a display name exactly once, at the first-ever authorization
    for an Apple ID, so a later sign-in — or a sign-in through a different provider that
    happens to know a name — must not blank or replace what is already there. The parent
    changes their name through `PATCH /me` and nowhere else.

    The guard is `column IS NULL and the incoming value is truthy`, so an empty string from a
    provider does not count as an answer either.
    """
    if user.email is None and email:
        user.email = email
    if user.display_name is None and display_name:
        user.display_name = display_name


async def find_credential(
    session: AsyncSession, provider: CredentialProvider, subject_id: str
) -> Credential | None:
    """The one lookup, and it deliberately does **not** filter `revoked_at`.

    A revoked credential still owns its subject. Skipping revoked rows here is the bug that
    orphans an archive: the sign-in would miss the existing row, fall through to the create
    path, and mint a second user for a person who already has one — leaving everything they
    have ever written behind an account they can no longer reach.
    """
    return await session.scalar(
        select(Credential).where(
            Credential.provider == provider, Credential.subject_id == subject_id
        )
    )


async def user_for_credential(
    session: AsyncSession,
    provider: CredentialProvider,
    subject_id: str,
    *,
    email: str | None = None,
    display_name: str | None = None,
) -> User:
    """Find the user behind a provider subject, creating them on first sight.

    **A revoked credential signing in again is un-revoked, and lands on the same user.** That
    is the whole of what makes revocation recoverable: `consent-revoked` from Apple, or a
    parent tapping Remove in Settings, takes the key off the door without demolishing the
    house. Coming back with the same Apple ID puts the key back.
    """
    existing = await find_credential(session, provider, subject_id)
    if existing is not None:
        user = await session.get(User, existing.user_id)
        assert user is not None  # FK with ON DELETE CASCADE guarantees this
        if existing.revoked_at is not None:
            existing.revoked_at = None
            log.info(
                "credential un-revoked by sign-in",
                extra={"user_id": str(user.id), "provider": provider},
            )
        _gap_fill(user, email=email, display_name=display_name)
        return user

    user = User(email=email, display_name=display_name)
    try:
        # **The user and the credential go in together, inside one savepoint.** Flushing the
        # user first put its INSERT outside the rollback: `ROLLBACK TO SAVEPOINT` only undoes
        # what came after, so the loser of the race discarded its credential, kept its user,
        # and committed a `users` row with no credentials, no children and no way to sign in —
        # an orphan nobody would ever notice, accumulating one per double-submitted first
        # sign-in. Two first-ever sign-ins for one subject both miss the SELECT above and both
        # insert; `uq_credentials_provider_subject_id` is what serialises them.
        async with session.begin_nested():
            # A household of one, created with the user. `users.family_id` is NOT NULL, and
            # it is inside this savepoint so the loser of a first-sign-in race discards its
            # family along with its user rather than leaving an empty one behind.
            user.family_id = (await create_household(session)).id
            session.add(user)
            await session.flush()
            session.add(Credential(user_id=user.id, provider=provider, subject_id=subject_id))
            await session.flush()
    except IntegrityError:
        winner = await find_credential(session, provider, subject_id)
        if winner is None:  # pragma: no cover — the constraint is the only way in here
            raise
        existing_user = await session.get(User, winner.user_id)
        assert existing_user is not None
        _gap_fill(existing_user, email=email, display_name=display_name)
        log.info("lost the create race, joined the winner", extra={"provider": provider})
        return existing_user
    log.info("created user", extra={"user_id": str(user.id), "provider": provider})
    return user


async def credentials_for_user(session: AsyncSession, user_id: uuid.UUID) -> list[Credential]:
    """Every credential on the account, revoked ones included.

    Revoked rows are returned rather than hidden: a parent who removed a sign-in method and
    wants it back needs to see that it is off, and a list that silently drops it reads as
    though it were never there.
    """
    rows = await session.scalars(
        select(Credential)
        .where(Credential.user_id == user_id)
        .order_by(Credential.created_at, Credential.id)
    )
    return list(rows)


async def attach_credential(
    session: AsyncSession,
    user: User,
    provider: CredentialProvider,
    subject_id: str,
    *,
    email: str | None = None,
    display_name: str | None = None,
) -> Credential:
    """Attach a verified provider subject to an account that already exists.

    The three outcomes, and none of them is a merge:

    - Already on **this** user → the existing row, unchanged. Idempotent, so a client that
      retries a request it never saw the answer to does not get an error for succeeding twice.
      A revoked one is reactivated, because attaching is a deliberate act that says *I want
      this key to work*.
    - Bound to a **different** user → `409 credential_in_use`, and nothing is written.
      Reassigning it would move a key between two archives; merging them is a feature nobody
      has asked for and cannot be undone by the person it happens to.
    - Otherwise a new row on this user. Several per provider are allowed — two Apple IDs on
      one account is a real household, not a mistake.
    """
    existing = await find_credential(session, provider, subject_id)
    if existing is not None:
        if existing.user_id != user.id:
            raise RascalError(
                ErrorCode.CREDENTIAL_IN_USE,
                "That sign-in already belongs to a different account.",
                field="provider",
            )
        if existing.revoked_at is not None:
            existing.revoked_at = None
            await session.flush()
        _gap_fill(user, email=email, display_name=display_name)
        return existing

    credential = Credential(user_id=user.id, provider=provider, subject_id=subject_id)
    session.add(credential)
    try:
        async with session.begin_nested():
            await session.flush()
    except IntegrityError as exc:
        # Somebody attached the same subject between the SELECT and the INSERT. The unique
        # constraint is the authority, and the answer is the same one the check above gives.
        raise RascalError(
            ErrorCode.CREDENTIAL_IN_USE,
            "That sign-in already belongs to a different account.",
            field="provider",
        ) from exc
    _gap_fill(user, email=email, display_name=display_name)
    log.info("credential attached", extra={"user_id": str(user.id), "provider": provider})
    return credential


async def revoke_credential(
    session: AsyncSession, user: User, credential_id: uuid.UUID, *, now: dt.datetime | None = None
) -> Credential:
    """Soft-revoke one credential, refusing to take the last live one.

    **Bricking an archive must be impossible through this route.** A parent with one sign-in
    method who removes it has locked themselves out of eighteen years of their child's life,
    with no support desk to call. Revoking an already-revoked credential is a no-op rather than
    an error — the state the caller asked for is the state that holds.
    """
    credential = await session.get(Credential, credential_id)
    if credential is None or credential.user_id != user.id:
        # 404 rather than 403: naming somebody else's credential id should not confirm that it
        # exists. Every other route in this service leaks existence deliberately; this one is
        # about another account, so it does not.
        raise not_found("Credential")

    # **Outstanding links die with the credential, and this must happen even on the no-op
    # path.** An `email` credential is created *inactive* — `revoked_at` set — while its
    # `verify` link is in somebody's inbox. Returning early on "already revoked" therefore made
    # Remove a lie for exactly the case it matters most: a parent who mistypes an address,
    # notices, and removes it would still be handing whoever holds that inbox a live link that
    # activates the credential and returns a session on their archive. Spending the tokens is
    # what makes Remove mean removed.
    await _consume_outstanding_tokens(session, credential.id, now=now)

    if credential.revoked_at is not None:
        await session.flush()
        return credential

    # **Guarded in SQL rather than by counting first.** Reading the live rows and then writing
    # is a check-then-act: two concurrent deletes each see two live credentials, each decides
    # it is not the last, and both succeed — leaving an account with no way in, which is the
    # one outcome this function exists to prevent. The `WHERE` below re-tests the population at
    # write time, so the loser of that race updates nothing.
    moment = now or dt.datetime.now(tz=dt.UTC)
    others_live = (
        select(func.count())
        .select_from(Credential)
        .where(
            Credential.user_id == user.id,
            Credential.id != credential.id,
            Credential.revoked_at.is_(None),
        )
        .scalar_subquery()
    )
    result = await session.execute(
        update(Credential)
        .where(
            Credential.id == credential.id,
            Credential.revoked_at.is_(None),
            others_live > 0,
        )
        .values(revoked_at=moment)
    )
    if result.rowcount == 0:
        raise RascalError(
            ErrorCode.LAST_CREDENTIAL,
            "This is the only way left to sign in to this account, so it cannot be removed. "
            "Add another sign-in method first.",
        )
    await session.refresh(credential)
    log.info(
        "credential revoked",
        extra={"user_id": str(user.id), "provider": credential.provider},
    )
    return credential


async def _consume_outstanding_tokens(
    session: AsyncSession, credential_id: uuid.UUID, *, now: dt.datetime | None = None
) -> None:
    """Spend every unconsumed sign-in link for a credential.

    Imported lazily to keep the dependency one-way: `email_sign_in` already imports this
    module, and a top-level import back would be a cycle.
    """
    from rascal.models import EmailSignInToken

    await session.execute(
        update(EmailSignInToken)
        .where(
            EmailSignInToken.credential_id == credential_id,
            EmailSignInToken.consumed_at.is_(None),
        )
        .values(consumed_at=now or dt.datetime.now(tz=dt.UTC))
    )


def subject_hint(provider: CredentialProvider, subject_id: str) -> str:
    """Enough to tell two credentials apart, and never the subject itself.

    A raw `subject_id` is the value that identifies the account to the provider, and a list
    endpoint is not a reason to hand it back. What a parent actually needs from this string is
    *which of these two is which*, so the shape that carries meaning is preserved and the rest
    is not: an address keeps its domain and the first letter of its local part, and an opaque
    provider subject keeps its last four characters.
    """
    if "@" in subject_id:
        local, _, domain = subject_id.partition("@")
        head = local[0] if local else ""
        return f"{head}{'•' * max(len(local) - 1, 1)}@{domain}"
    # **Masked even when short.** Returning the last four of a four-character subject returns
    # the subject. Provider subjects are long in practice, so this is a guard against a future
    # provider rather than today's — which is exactly when it is cheap to add.
    if len(subject_id) <= 8:
        return "•" * 8
    return f"{'•' * 4}{subject_id[-4:]}"


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
