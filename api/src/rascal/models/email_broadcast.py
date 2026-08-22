"""One row per daily prompt broadcast. The whole of what this service remembers about email.

**There is no `subscriber_id`, and story 4's `email_sends` table is deliberately not what got
built.** The story specifies a ledger keyed to a `subscribers` row, but the list is
provider-held per `decisions.md` open item 12(4): there is no `subscribers` table, none may be
created, and `POST /v1/subscribe` stores nothing. A ledger keyed per-recipient would be a copy
of the mailing list living in our database under another name — and the privacy page published
on Aug 17, 2026 states plainly that we hold no such copy. Making that sentence false is a worse
outcome than any duplicate this table prevents.

So the row records the **broadcast**, which is not personal data: a date, which prompt went out,
and what Resend said. Who received it is Resend's record and stays there.

**The unique index on `send_date` is the entire idempotency story.** Two Fly machines waking on
the same schedule, a retried scheduled machine, or a hand-run `--date` against a day already
sent all collide on it rather than mailing the list twice.
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import Date, Index, Integer, Text
from sqlalchemy.orm import Mapped, mapped_column

from rascal.models.base import Base, created, one_of, optional_moment, updated, uuid_pk

#: `sent` reached Resend. `skipped` is a dry run — ~~the state everything is in until the P0
#: behavioural gate passes~~, which stopped being true on Aug 19, 2026 when the flag was set;
#: every row since is `sent`. `failed` tried and did not.
BROADCAST_STATUSES: tuple[str, ...] = ("sent", "skipped", "failed")


class EmailBroadcast(Base):
    """A day's prompt broadcast: attempted, skipped, or sent."""

    __tablename__ = "email_broadcasts"
    __table_args__ = (
        one_of("status", BROADCAST_STATUSES, name="ck_email_broadcasts_status"),
        # **At most one send per calendar day.** `skipped` rows are inside the constraint and
        # not outside it: a dry run that "used up" the day is the correct behaviour, because
        # the alternative is a day that dry-runs at 08:00 and sends for real at 09:00 once
        # somebody flips the flag, mailing a prompt whose row already said skipped.
        Index("uq_email_broadcasts_send_date", "send_date", unique=True),
    )

    id: Mapped[uuid_pk]
    #: The calendar day this broadcast belongs to, in UTC. Not a timestamp: the identity of a
    #: daily send is its day, and that is what the unique index is on.
    send_date: Mapped[dt.date] = mapped_column(Date)
    #: Which pool entry went out, 0-based. Recorded rather than recomputed — the pool can be
    #: edited by the owner, and a row that said "index 12" while the file has since changed
    #: would otherwise silently rewrite history.
    pool_index: Mapped[int] = mapped_column(Integer)
    #: The subject exactly as sent, for the same reason.
    subject: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text)
    #: Resend's broadcast id. Null for a dry run, which never had one.
    resend_id: Mapped[str | None] = mapped_column(Text, default=None)
    #: Why it failed, when it did. Never contains an address, because there is no address here.
    error: Mapped[str | None] = mapped_column(Text, default=None)
    #: When it actually went to Resend, as opposed to when the row was written.
    sent_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]
