"""`users.email_deliverable` — the interlock that makes a dead email channel audible

**This is a safety interlock, not bookkeeping**, and it is a third column beside phase 49's
two rather than a variation on them. `marketing_consent` and `transactional_consent` record
what a parent *chose*. This records whether the channel physically *works*, which is not a
preference and is not something they told us — Apple does.

D3a: a Sign in with Apple private relay address can be switched off by the parent at any time,
from Settings, silently. Nothing bounces, nothing errors; mail is simply never forwarded again.
D3's hard stop is that deletion may not fire unless a notice was confirmed delivered on some
channel. Without this column the silence is indistinguishable from success, and the first
consequence of getting it wrong is an archive deleted after warnings nobody received.

`email-disabled` and `email-enabled` from `POST /webhooks/apple-signin` are the only writers.
Nothing reads it yet — phase 38, lifecycle notices, is what reads it.

**Defaults `true`, and the default is a claim about existing rows rather than a guess.** Every
account that exists today has a working channel as far as anything knows; Apple has told us
nothing to the contrary, and a `false` default would suspend deletion for every user forever,
which is the failure mode of an interlock that is stuck on rather than one that works.

Reversible. The downgrade drops the column, which loses whatever Apple has told us since —
inherent to the column existing at all.

Revision ID: 0012_email_deliverable
Revises: 0011_credential_linking
Create Date: 2026-08-16
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0012_email_deliverable"
down_revision = "0011_credential_linking"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column(
            "email_deliverable",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
    )


def downgrade() -> None:
    op.drop_column("users", "email_deliverable")
