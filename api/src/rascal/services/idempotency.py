"""Replaying a stored response instead of doing the work twice.

`POST /entries` carries an `Idempotency-Key` header and a retry has to return the original
`201` body — never a second row and never a `409`. Keys are scoped to the user.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.errors import ErrorCode, RascalError
from rascal.models import IdempotencyKey


async def replay(
    session: AsyncSession, user_id: uuid.UUID, key: str, endpoint: str
) -> tuple[int, dict[str, Any]] | None:
    """The original response for this key, or None if it has not been used yet."""
    stored = await session.scalar(
        select(IdempotencyKey).where(IdempotencyKey.user_id == user_id, IdempotencyKey.key == key)
    )
    if stored is None:
        return None
    if stored.endpoint != endpoint:
        raise RascalError(
            ErrorCode.CONFLICT,
            "This idempotency key was already used on a different endpoint.",
            field="Idempotency-Key",
        )
    return stored.response_status, stored.response_body


async def remember(
    session: AsyncSession,
    user_id: uuid.UUID,
    key: str,
    endpoint: str,
    status: int,
    body: dict[str, Any],
) -> None:
    """Store the response so a retry replays it.

    DO NOTHING on conflict: two concurrent retries race here, and the first one to land is
    as good as any other — they are storing the same result.
    """
    await session.execute(
        insert(IdempotencyKey)
        .values(
            user_id=user_id,
            key=key,
            endpoint=endpoint,
            response_status=status,
            response_body=body,
        )
        .on_conflict_do_nothing(index_elements=[IdempotencyKey.user_id, IdempotencyKey.key])
    )
