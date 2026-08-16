"""Applying Apple's server-to-server notifications.

**The decision this file exists to hold: `account-delete` is credential-gone, not
account-gone.** Apple is telling us an Apple ID was deleted. It is not telling us to delete a
child's archive, it has no standing to, and the parent who wrote that archive has not asked for
anything. So the two revocation events do exactly the same thing, and neither touches `users`,
`children`, `entries` or `media`. Recorded in `docs/decisions.md` rather than only here,
because a future reader will otherwise read the identical handling as a copy-paste mistake and
"fix" it.

Recoverability is what makes that safe: the credential keeps its `(provider, subject_id)`, so
signing in with the same Apple ID clears `revoked_at` and lands on the same user. The parent
gets their archive back by signing in.
"""

from __future__ import annotations

import datetime as dt
import logging

from sqlalchemy.ext.asyncio import AsyncSession

from rascal.models import User
from rascal.services.apple import AppleServerNotification
from rascal.services.auth import find_credential
from rascal.services.tokens import revoke_all_refresh_tokens

log = logging.getLogger("rascal.apple.events")


async def apply_notification(session: AsyncSession, event: AppleServerNotification) -> str:
    """Act on one verified notification. Returns what was done, for the log.

    **Unknown event types are acknowledged, not refused.** Apple retries anything that is not
    a 2xx, and a type this service will never handle would be retried forever. Silence about a
    type we do not know is the correct answer; a 400 is a promise to handle it later.

    **An unknown `sub` is also acknowledged.** It means the credential was hard-deleted or
    never existed here, and there is nothing to act on. Answering 404 would tell an
    unauthenticated caller which Apple subjects have accounts.
    """
    credential = await find_credential(session, "apple", event.subject_id)
    if credential is None:
        log.info("apple notification for an unknown subject", extra={"type": event.event_type})
        return "ignored:unknown-subject"

    user = await session.get(User, credential.user_id)
    assert user is not None  # FK with ON DELETE CASCADE guarantees this

    match event.event_type:
        # Identical on purpose. See the module docstring and `docs/decisions.md`.
        case "consent-revoked" | "account-delete":
            if credential.revoked_at is None:
                credential.revoked_at = event.event_time or dt.datetime.now(tz=dt.UTC)
            # The session must not outlive the credential behind it. Without this, revoking
            # while the app is closed leaves it signed in until the refresh token expires —
            # up to thirty days of a session the parent believes they ended.
            await revoke_all_refresh_tokens(session, user.id)
            await session.flush()
            log.info(
                "apple credential revoked",
                extra={"user_id": str(user.id), "type": event.event_type},
            )
            return "revoked"

        case "email-disabled" | "email-enabled":
            user.email_deliverable = event.event_type == "email-enabled"
            await session.flush()
            log.info(
                "apple email deliverability changed",
                extra={"user_id": str(user.id), "deliverable": user.email_deliverable},
            )
            return "email-deliverability"

        case _:
            log.info("apple notification of an unhandled type", extra={"type": event.event_type})
            return "ignored:unhandled-type"
