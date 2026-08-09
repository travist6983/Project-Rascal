"""The caller's own record.

`UserOut` — the response shape — lives in `schemas/common.py`, because `/auth/apple`,
`/auth/dev-login`, and `PATCH /me` all return the same user object and there is only ever
one definition of it.
"""

from __future__ import annotations

from rascal.schemas.common import ApiModel


class MeUpdate(ApiModel):
    """The writable half of a user.

    `display_name` only. Email comes from the credential provider — Apple's relay address is
    not the user's to retype, and letting them would decouple the row from the credential
    that produced it.

    Deliberately not `str | None`: bounds and blankness are checked in the handler so every
    rejection carries `invalid_display_name` rather than a mix of that and
    `validation_failed`. A client showing an error under a text field wants one code.
    """

    display_name: str
