"""The credential list, and the body that attaches one.

`subject_id` never appears in either direction of this file. It goes in on a request as the
provider's own token — verified here, never trusted as a field — and comes back out only as
the masked `subject_hint`.

**`apple_refresh_token` never appears either, and that matters more.** `subject_id` is an
identifier; the refresh token added by phase 127 is a live credential Apple will act on. The
absence is enforced by `CredentialOut` being an allowlist rather than a `model_config` exclusion,
and asserted by `test_the_list_never_returns_the_stored_apple_refresh_token` rather than trusted
— directly beside the `subject_id` rule above, which it mirrors.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Literal

from pydantic import Field

from rascal.constants import CredentialProvider
from rascal.schemas.common import ApiModel


class CredentialOut(ApiModel):
    id: uuid.UUID
    provider: CredentialProvider
    # Masked. A raw `subject_id` is what identifies the account to the provider, and listing
    # the sign-in methods on an account is not a reason to hand it back.
    subject_hint: str
    created_at: dt.datetime
    # Null means live. A revoked credential stays in the list — a parent who turned one off
    # and wants it back needs to see that it is off, not find it missing.
    revoked_at: dt.datetime | None


class CredentialCreate(ApiModel):
    """A provider token of the same shape the sign-in route for that provider accepts.

    `provider` is narrower than the column's CHECK on purpose: the schema permits a value only
    once something can verify it. `google` was added by phase 54 beside its verifier; `email`
    arrives with phase 57, where the address is proved by a clicked link rather than by a
    token. Until then, asking for one is a 422 that names the field rather than a route that
    quietly accepts an unverifiable claim.
    """

    provider: Literal["apple", "google"] = "apple"
    identity_token: str = Field(min_length=1)
    # Accepted for parity with `POST /auth/apple`, which carries it for parity with Apple's
    # own payload and ignores it. Attaching never sets a name that is already set.
    display_name: str | None = None
