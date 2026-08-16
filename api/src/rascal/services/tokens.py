"""Access tokens, refresh tokens, and rotation.

Access tokens are stateless JWTs with a 15-minute life. Refresh tokens are opaque, stored
only as a SHA-256 hash, and rotate on every use: presenting one revokes it and issues a new
pair. A long-lived JWT with no server-side record cannot be revoked the day a phone goes
missing, and this archive has a child's face and voice in it.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import secrets
import uuid
from dataclasses import dataclass

import jwt
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import RefreshToken, User

ALGORITHM = "HS256"
ACCESS_TOKEN_TYPE = "access"


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    expires_in: int


def _now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


def hash_refresh_token(raw: str) -> str:
    """The raw value exists in exactly one response body and is never stored."""
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def create_access_token(user_id: uuid.UUID, settings: Settings) -> tuple[str, int]:
    """Returns the token and its lifetime in seconds."""
    issued = _now()
    ttl = dt.timedelta(minutes=settings.access_token_ttl_minutes)
    payload = {
        "sub": str(user_id),
        "typ": ACCESS_TOKEN_TYPE,
        "iat": int(issued.timestamp()),
        "exp": int((issued + ttl).timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGORITHM), int(ttl.total_seconds())


def decode_access_token(token: str, settings: Settings) -> uuid.UUID:
    """The user id inside a valid access token, or a 401 in the standard error shape."""
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError as exc:
        raise RascalError(ErrorCode.TOKEN_EXPIRED, "Your session has expired.") from exc
    except jwt.InvalidTokenError as exc:
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Invalid access token.") from exc

    if payload.get("typ") != ACCESS_TOKEN_TYPE:
        # A refresh token is opaque, so this only fires if someone hands us a token we
        # minted for another purpose. Refuse it rather than guess.
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Invalid access token.")
    try:
        return uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Invalid access token.") from exc


async def issue_refresh_token(session: AsyncSession, user_id: uuid.UUID, settings: Settings) -> str:
    """Mint an opaque refresh token, store its hash, and hand the raw value back once."""
    raw = secrets.token_urlsafe(48)
    session.add(
        RefreshToken(
            user_id=user_id,
            token_hash=hash_refresh_token(raw),
            expires_at=_now() + dt.timedelta(days=settings.refresh_token_ttl_days),
        )
    )
    await session.flush()
    return raw


async def issue_token_pair(
    session: AsyncSession, user_id: uuid.UUID, settings: Settings
) -> TokenPair:
    access, expires_in = create_access_token(user_id, settings)
    refresh = await issue_refresh_token(session, user_id, settings)
    return TokenPair(access_token=access, refresh_token=refresh, expires_in=expires_in)


async def revoke_all_refresh_tokens(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Revoke every live refresh token for a user.

    Two callers, and they are the same act for different reasons: a revoked token reappearing
    is a race or a theft, and Apple telling us a parent withdrew consent is a session that
    should not outlive the credential behind it.
    """
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=_now())
    )


async def rotate_refresh_token(
    session: AsyncSession, raw: str, settings: Settings
) -> tuple[User, TokenPair]:
    """Revoke the presented token and issue a new pair.

    A token that was already revoked is either a race or a theft. Either way the safe move
    is the same: refuse it and revoke everything else in the chain.
    """
    stored = await session.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(raw))
    )
    if stored is None:
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Invalid refresh token.")

    if stored.revoked_at is not None:
        await revoke_all_refresh_tokens(session, stored.user_id)
        # Committed here rather than left to the request: the response is an error, and the
        # request-scoped session rolls back on an exception. The revocation has to survive.
        await session.commit()
        raise RascalError(
            ErrorCode.REFRESH_TOKEN_REUSED,
            "This refresh token was already used. All sessions have been revoked.",
        )

    if stored.expires_at <= _now():
        raise RascalError(ErrorCode.TOKEN_EXPIRED, "Your refresh token has expired.")

    stored.revoked_at = _now()
    user = await session.get(User, stored.user_id)
    if user is None:
        raise RascalError(ErrorCode.UNAUTHENTICATED, "Invalid refresh token.")
    return user, await issue_token_pair(session, user.id, settings)


async def revoke_refresh_token(session: AsyncSession, raw: str) -> None:
    """Logout. Revoking an unknown or already-revoked token is a no-op, not an error."""
    stored = await session.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == hash_refresh_token(raw))
    )
    if stored is not None and stored.revoked_at is None:
        stored.revoked_at = _now()
