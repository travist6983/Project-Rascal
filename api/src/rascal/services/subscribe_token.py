"""The confirmation link's token: signed, stateless, and deliberately not a row.

**This is what lets double opt-in exist without a subscriber table.**
`docs/sprint-aug16/story-4-report.md` offered three ways to know who confirmed, and two of them
cost something the project has already decided against: option B stores contact ids, which is a
record of who is on the list, and the published privacy page says no such record exists (open
item 12(2) and 12(4)).

A confirmation does not actually need memory. It needs a link that **cannot be forged** — and a
signature gives that without writing anything down. The address travels inside the token, signed
with `JWT_SECRET`; clicking proves the holder received mail at that address, which is the entire
question double opt-in asks.

**Two limits, stated because they are real and neither is a bug to be fixed later.**

1. *Unconfirmed* and *unsubscribed* are the same state at Resend, so the two cannot be told
   apart. That is correct for sending — neither gets mail — and wrong for counting, which is
   why the ledger of what was sent lives in `email_broadcasts` rather than being inferred.
2. A token stays good for its whole life, so a link confirms every time it is opened. Somebody
   who confirms, unsubscribes, then reopens the original mail is resubscribed. **Single-use
   would need state, which is the thing this module exists to avoid**; the expiry below is what
   bounds it instead, and it is short for that reason rather than for security.
"""

from __future__ import annotations

import datetime as dt

import jwt

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError

#: Distinct from `tokens.ACCESS_TOKEN_TYPE`, and checked on the way in. Both are signed with the
#: same secret, so without this an access token would open a confirmation link and a
#: confirmation token would authenticate a request. The `typ` claim is what keeps one key's
#: signatures from being interchangeable across purposes.
TOKEN_TYPE = "subscribe_confirm"

ALGORITHM = "HS256"


class ConfirmTokenInvalid(RascalError):
    """Unknown, malformed, expired, or minted for something else — **one answer for all four**.

    The same rule `complete_sign_in` follows: distinguishing them would say whether a given link
    ever existed, and this route is reachable by anybody with a browser.
    """

    def __init__(self) -> None:
        super().__init__(
            ErrorCode.SIGN_IN_LINK_INVALID,
            "That confirmation link is no longer good.",
        )


def create(email: str, settings: Settings) -> str:
    """Mint a confirmation token for one address.

    The address is the whole payload. There is no id to look up because there is nothing to
    look it up in.
    """
    issued = dt.datetime.now(tz=dt.UTC)
    ttl = dt.timedelta(days=settings.subscribe_confirm_ttl_days)
    payload = {
        "sub": email,
        "typ": TOKEN_TYPE,
        "iat": int(issued.timestamp()),
        "exp": int((issued + ttl).timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGORITHM)


def read(token: str, settings: Settings) -> str:
    """The address inside a valid token, or `ConfirmTokenInvalid`.

    Raises rather than returning `None`, for the reason `turnstile.verify` does: a caller that
    forgets to check a returned value has silently confirmed an address nobody proved.
    """
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[ALGORITHM])
    except jwt.InvalidTokenError as exc:
        # `ExpiredSignatureError` is a subclass, so expiry lands here too — deliberately, per
        # the one-answer rule above.
        raise ConfirmTokenInvalid() from exc

    if payload.get("typ") != TOKEN_TYPE:
        raise ConfirmTokenInvalid()

    address = payload.get("sub")
    if not isinstance(address, str) or "@" not in address:
        raise ConfirmTokenInvalid()
    return address
