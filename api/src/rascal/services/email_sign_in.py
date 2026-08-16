"""Magic-link sign-in.

**The restriction that makes this small: `POST /auth/email/start` never creates a user.** It
matches an existing, active `email` credential or it does nothing at all. Email is a second key
to a door you already own, added deliberately from Settings while signed in. There is no public
signup on this path.

That single rule kills three problems at once:

- **The orphan-account trap.** Without it, an Apple parent who typed their address into the
  email field would get a second, empty archive and no way to tell that was what happened.
- **Account enumeration as a signup surface.** `start` always answers `202`, so the response
  says nothing about whether an address is known.
- **Every argument about self-serve password reset**, because there is no password.

**An address is proved by a click, never by the field it was typed into.** `POST
/me/credentials` with `provider: "email"` creates the credential **inactive** — `revoked_at`
set, which is the existing "not a way in" state rather than a new one — and mails a link.
Clicking it is what activates it. A typo therefore costs nothing: the address that receives
the link is the only one that can turn it into a key.

**The address is never defaulted from `users.email`.** The production account is on a
`privaterelay.appleid.com` address, and Apple can switch relay forwarding off at any time
without telling anybody. A magic link to a relay that has stopped forwarding is a dead key that
looks alive, which is the exact failure `users.email_deliverable` exists to make audible.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import logging
import secrets

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import SignInTokenPurpose
from rascal.errors import ErrorCode, RascalError
from rascal.models import Credential, EmailSignInToken, User
from rascal.services.auth import find_credential

log = logging.getLogger("rascal.email_sign_in")

#: Long enough that guessing is hopeless, short enough to survive a mail client's line wrap.
TOKEN_BYTES = 32

#: Fifteen minutes. Long enough to walk to a laptop, short enough that a link left in an inbox
#: is not a standing key to a child's archive.
TOKEN_TTL = dt.timedelta(minutes=15)


def hash_token(raw: str) -> str:
    """SHA-256, the same rule `refresh_tokens` follows. The raw value is never stored."""
    return hashlib.sha256(raw.encode()).hexdigest()


def normalise(email: str) -> str:
    """Lowercased and trimmed. An address is not case-sensitive in the half that matters here,
    and two rows differing only in case would be two credentials for one inbox."""
    return email.strip().lower()


async def issue_token(
    session: AsyncSession,
    credential: Credential,
    *,
    purpose: SignInTokenPurpose,
    now: dt.datetime | None = None,
) -> str:
    """Mint a link token for a credential and return the raw value, once.

    `purpose` decides what opening it is allowed to do. A `verify` token activates a newly
    added address; a `sign_in` token only signs in. The distinction is load-bearing — see
    `complete_sign_in`.
    """
    moment = now or dt.datetime.now(tz=dt.UTC)
    raw = secrets.token_urlsafe(TOKEN_BYTES)
    session.add(
        EmailSignInToken(
            credential_id=credential.id,
            token_hash=hash_token(raw),
            purpose=purpose,
            expires_at=moment + TOKEN_TTL,
        )
    )
    await session.flush()
    return raw


async def start_sign_in(
    session: AsyncSession, email: str, *, now: dt.datetime | None = None
) -> tuple[str, str] | None:
    """Find an active `email` credential and mint a link for it.

    Returns `(address, raw_token)` when there is something to send, and `None` when there is
    not — an address with no credential, or one whose credential is revoked or still unverified.
    **The caller answers `202` either way.** Anything else here is an enumeration oracle.
    """
    address = normalise(email)
    credential = await find_credential(session, "email", address)
    if credential is None or credential.revoked_at is not None:
        # Deliberately indistinguishable from the success path to a caller, and logged without
        # the address so the log is not the oracle the response refuses to be.
        log.info("email sign-in start with no active credential")
        return None

    raw = await issue_token(session, credential, purpose="sign_in", now=now)
    return address, raw


async def complete_sign_in(
    session: AsyncSession, raw_token: str, *, now: dt.datetime | None = None
) -> User:
    """Consume a link token and return the user behind it.

    Refuses, with `sign_in_link_invalid`, when the token is unknown, already consumed, expired,
    or is a `sign_in` link for a credential that has since been revoked. **All of them are one
    answer**: a client showing "this link is no longer good, here is how to get another" does
    not need to know which, and telling them apart would say whether a link ever existed.

    **Only a `verify` token clears `revoked_at`.** That is what makes one link do double duty
    — proving a newly added address and signing in with an established one are the same act —
    without making Remove a suggestion: an outstanding `sign_in` link for an address the parent
    deleted is refused rather than quietly putting the key back.
    """
    moment = now or dt.datetime.now(tz=dt.UTC)
    token = await session.scalar(
        select(EmailSignInToken).where(EmailSignInToken.token_hash == hash_token(raw_token))
    )
    if token is None or not token.is_live(moment):
        raise RascalError(
            ErrorCode.SIGN_IN_LINK_INVALID,
            "This sign-in link is no longer valid. Ask for a new one.",
        )

    credential = await session.get(Credential, token.credential_id)
    if credential is None:
        raise RascalError(
            ErrorCode.SIGN_IN_LINK_INVALID,
            "This sign-in link is no longer valid. Ask for a new one.",
        )

    if credential.revoked_at is not None and token.purpose != "verify":
        # The address was removed after this link was sent. Spend the token anyway, so it
        # cannot be tried again, and refuse.
        token.consumed_at = moment
        await session.flush()
        raise RascalError(
            ErrorCode.SIGN_IN_LINK_INVALID,
            "This sign-in link is no longer valid. Ask for a new one.",
        )

    # Consume first. If anything below fails, the link is spent rather than replayable.
    token.consumed_at = moment
    if token.purpose == "verify":
        credential.revoked_at = None
    await session.flush()

    user = await session.get(User, credential.user_id)
    assert user is not None  # FK with ON DELETE CASCADE guarantees this
    log.info("email sign-in completed", extra={"user_id": str(user.id)})
    return user


async def attach_email_credential(
    session: AsyncSession, user: User, email: str, *, now: dt.datetime | None = None
) -> tuple[Credential, str] | None:
    """Add an email address to an account, inactive until the link is clicked.

    Returns the credential and the raw link token, or **`None` when the address belongs to
    somebody else** — which the caller answers exactly as it answers success.

    **The silent `None` is the whole privacy argument, and it is a consistency argument too.**
    This route used to answer `409 credential_in_use` there, which told any caller — and anyone
    who can create a free account is a caller — whether a given address signs in to Dogear.
    `POST /auth/email/start` already refuses that exact question with an unconditional `202`,
    so answering it here was not merely a leak but an inconsistency: two endpoints, the same
    question about the same address, two different answers. The quieter one is the correct one.

    The three outcomes:

    - Bound to a **different** user → `None`. Nothing written, nothing sent.
    - Bound to **this** user already → a fresh link, so an expired verification can be retried
      without a second row. An already-active credential is re-verified rather than refused,
      which is the harmless reading and avoids a dead end.
    - Otherwise a new credential with `revoked_at` set, and a link.

    **It does not activate anything.** The click does. That is what makes a typo cost nothing
    rather than hand a stranger's inbox a key to this archive.
    """
    address = normalise(email)
    if "@" not in address or address.startswith("@") or address.endswith("@"):
        raise RascalError(
            ErrorCode.VALIDATION_FAILED, "That does not look like an email address.", field="email"
        )

    moment = now or dt.datetime.now(tz=dt.UTC)
    existing = await find_credential(session, "email", address)
    if existing is not None:
        if existing.user_id != user.id:
            log.info("email credential add refused, address belongs elsewhere")
            return None
        return existing, await issue_token(session, existing, purpose="verify", now=moment)

    credential = Credential(
        user_id=user.id,
        provider="email",
        subject_id=address,
        # Inactive until the click. `revoked_at` is reused rather than a second "pending"
        # column, because the meaning a client needs is identical: this is not a way in yet.
        revoked_at=moment,
    )
    session.add(credential)
    try:
        # A savepoint, so losing the race leaves the surrounding transaction usable — the same
        # shape `attach_credential` already uses. Without it, two accounts adding one address
        # at the same instant gave the loser a raw `IntegrityError`, which reached the generic
        # handler as a 500 and leaked a SQL failure in place of an answer.
        async with session.begin_nested():
            await session.flush()
    except IntegrityError:
        # Somebody claimed the address between the SELECT and the INSERT. Indistinguishable to
        # the caller from the pre-check above, which is the point.
        log.info("email credential add lost the insert race")
        return None
    log.info("email credential added, awaiting verification", extra={"user_id": str(user.id)})
    return credential, await issue_token(session, credential, purpose="verify", now=moment)
