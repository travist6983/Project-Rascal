"""Registering and revoking the tokens a notification is delivered to."""

from __future__ import annotations

import datetime as dt
import logging
import uuid

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import DevicePlatform, PushEnvironment
from rascal.errors import validation_failed
from rascal.models import Device, User

log = logging.getLogger("rascal.devices")

# An APNs device token is 64 hex characters today. The column is not constrained to that:
# Apple has changed the length before, and a server that rejects a valid token is a phone
# that can never be reached. This is a sanity bound against a client sending a whole file.
MAX_TOKEN_LENGTH = 512


def _clean_token(raw: str) -> str:
    token = raw.strip()
    if not token:
        raise validation_failed("A device token cannot be blank.", field="token")
    if len(token) > MAX_TOKEN_LENGTH:
        raise validation_failed(
            f"A device token is at most {MAX_TOKEN_LENGTH} characters.", field="token"
        )
    return token


async def register_device(
    session: AsyncSession,
    user: User,
    *,
    token: str,
    platform: DevicePlatform,
    environment: PushEnvironment,
    now: dt.datetime | None = None,
) -> Device:
    """Idempotent registration. The same token twice is one row with a fresh `last_seen_at`.

    An upsert on `(token, environment)` rather than a read-then-write, so two launches racing
    each other produce one row instead of a unique-violation. Three things it deliberately
    overwrites on conflict:

    * **`user_id`.** A token belongs to whoever most recently registered it. Somebody signing
      into a different account on the same phone must not keep receiving the previous
      account's notifications, and that phone reports the same token either way.
    * **`revoked_at`, cleared.** Registering *is* the statement that this token is live
      again, so a sign-out followed by a sign-in resurrects the row rather than stranding it.
    * **`last_seen_at`.** The point of calling this on every launch.
    """
    stamp = now or dt.datetime.now(tz=dt.UTC)
    clean = _clean_token(token)

    statement = (
        insert(Device)
        .values(
            id=uuid.uuid4(),
            user_id=user.id,
            token=clean,
            platform=platform,
            environment=environment,
            last_seen_at=stamp,
            revoked_at=None,
        )
        .on_conflict_do_update(
            index_elements=[Device.token, Device.environment],
            set_={
                "user_id": user.id,
                "platform": platform,
                "last_seen_at": stamp,
                "revoked_at": None,
            },
        )
        .returning(Device.id)
    )
    device_id = (await session.execute(statement)).scalar_one()

    # `populate_existing` because the upsert went round the identity map: without it a row
    # this session had already loaded — and `updated_at`, which only the trigger knows —
    # would come back stale.
    device = await session.scalar(
        select(Device).where(Device.id == device_id).execution_options(populate_existing=True)
    )
    assert device is not None  # It was just returned by the insert.
    return device


async def revoke_device(
    session: AsyncSession, user: User, *, token: str, now: dt.datetime | None = None
) -> int:
    """Soft-delete every row this user holds for a token. Returns how many were live.

    Scoped to the caller, so somebody else's token is simply not there — a token is a
    bearer-ish string and answering "that exists, but not for you" would be a way to probe it.

    Revokes across **both** environments. The path carries a token and no environment, sign-out
    means this phone stops receiving on this account, and a phone that has run both a
    development and a TestFlight build legitimately holds a row for each.

    Idempotent: revoking an already-revoked device is a success, because the caller's
    intent — this token is done — is already true.
    """
    stamp = now or dt.datetime.now(tz=dt.UTC)
    clean = token.strip()

    result = await session.execute(
        update(Device)
        .where(
            Device.user_id == user.id,
            Device.token == clean,
            Device.revoked_at.is_(None),
        )
        .values(revoked_at=stamp)
    )
    revoked = result.rowcount or 0
    log.info("device revoked", extra={"user_id": str(user.id), "devices_revoked": revoked})
    return revoked


async def user_owns_token(session: AsyncSession, user: User, token: str) -> bool:
    """Whether the caller has any row for this token, revoked or not.

    Separate from :func:`revoke_device` so a second sign-out is a `204` rather than a `404`,
    while a token this account has never registered is still a `404`.
    """
    found = await session.scalar(
        select(Device.id).where(Device.user_id == user.id, Device.token == token.strip()).limit(1)
    )
    return found is not None


async def live_devices(session: AsyncSession, user_id: uuid.UUID) -> list[Device]:
    """Every token a notification for this user should go to. Send to all of them."""
    rows = await session.execute(
        select(Device)
        .where(Device.user_id == user_id, Device.revoked_at.is_(None))
        .order_by(Device.created_at.asc(), Device.id.asc())
    )
    return list(rows.scalars().all())
