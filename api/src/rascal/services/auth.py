"""Turning a provider credential into a RASCAL session.

Apple is one row in `credentials`. Adding password or Google auth later means calling
`user_for_credential` with a different provider — no schema change, which is the whole point.
"""

from __future__ import annotations

import logging

from sqlalchemy import select
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
