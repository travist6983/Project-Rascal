"""The caller's own record.

`UserOut` — the response shape — lives in `schemas/common.py`, because `/auth/apple`,
`/auth/dev-login`, and `PATCH /me` all return the same user object and there is only ever
one definition of it.
"""

from __future__ import annotations

import datetime as dt

from pydantic import Field

from rascal.schemas.common import ApiModel


class MeUpdate(ApiModel):
    """The writable half of a user: the display name, and the notification preference.

    Email is not here. It comes from the credential provider — Apple's relay address is not
    the user's to retype, and letting them set it would decouple the row from the credential
    that produced it.

    **Every field is optional and absence means "no opinion".** A Settings screen toggling
    notifications must not have to resend a display name it is not changing, and the reverse.
    The handler reads `model_fields_set` rather than checking for `None`, so an omitted key
    and an explicit `null` are distinguishable — which is exactly the distinction
    `POST /entries` cannot make about `unlock_at_age`, and the reason that is in
    `docs/blocked.md`. Sending an explicit `null` for any field here is a rejection, not a
    clear: none of the three columns is nullable.
    """

    display_name: str | None = None
    notify_enabled: bool | None = Field(
        default=None,
        description="Turn the one daily notification on or off. The client sets this true "
        "only after the parent has granted OS notification permission.",
    )
    notify_local_time: dt.time | None = Field(
        default=None,
        description="Wall-clock time, e.g. `19:00`. Read in the child's `family_timezone`, "
        "never the device's. Seconds are ignored.",
    )
