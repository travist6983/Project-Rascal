"""How much is in one child's archive.

Three counts and two dates, computed on every call. This exists because the client cannot
answer any of it: the timeline is a paged, partial cache, so `docs/settings-v2-inventory.md`
dropped the hero's stats strip (D1) and its "First entry — 21 Jun 2022" line (D12) rather than
let the app assert the size of an archive it has only seen part of. That is the same rule the
Timeline header follows — *"it never claims to know the size of the archive. Until the last
page has landed it reads '412 so far'"* — and the honest way to lift it is a server that
counts, not a client that guesses.

**Deleted rows are excluded everywhere**, per the read-path rule. A soft-deleted entry takes
its media with it in the contract, so media is counted through a join to a live entry rather
than on its own `deleted_at` alone — a media row whose entry was deleted is not in the
archive, whatever its own column says.

**The two dates are calendar days in the child's `family_timezone`, not timestamps.** An entry
recorded at 9pm in Detroit is a Detroit day, and returning an instant would let a client in
another zone render the first day of the archive as the day before.

**The zone is applied in Python, and it must never reach SQL.** `family_timezone` is validated
against Python's `zoneinfo`, whose name set is *larger* than Postgres's — `Asia/Calcutta` and
`US/Eastern` are accepted by `ChildCreate` and rejected by `timezone()` with
`time zone "Asia/Calcutta" not recognized`, which is a 500 on a read endpoint for a child whose
household is spelled a way the API itself allows. The first version of this file pushed the zone
into the query to convert every row in the same pass as the aggregate.

That turned out to be unnecessary as well as unsafe: **converting to a fixed zone is monotonic**,
so the earliest instant is the earliest local day whatever the zone. Taking `min`/`max` of the raw
column and converting exactly two values afterwards is the same answer, one query, and no
user-controlled string in the SQL.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from zoneinfo import ZoneInfo

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import MEDIA_KINDS
from rascal.models import Child, Entry, Media


@dataclass(frozen=True)
class ChildStats:
    entries: int
    sealed: int
    media: dict[str, int]
    first_entry_on: dt.date | None
    last_entry_on: dt.date | None


def _live_entries(child_id) -> Select:
    return select(Entry).where(Entry.child_id == child_id, Entry.deleted_at.is_(None))


async def child_stats(session: AsyncSession, child: Child) -> ChildStats:
    """Everything the hero strip and the first-entry line need, in one round trip."""
    live = _live_entries(child.id).subquery()

    # The raw instants. Monotonicity is what makes this correct: the earliest `occurred_at` is
    # the earliest local day in every zone, so the day can be derived after the aggregate rather
    # than inside it — and the zone never has to be a string Postgres has to recognise.
    counts = (
        await session.execute(
            select(
                func.count(),
                func.count().filter(live.c.unlock_at_age.is_not(None)),
                func.min(live.c.occurred_at),
                func.max(live.c.occurred_at),
            ).select_from(live)
        )
    ).one()

    zone = ZoneInfo(child.family_timezone)

    def local_day(moment: dt.datetime | None) -> dt.date | None:
        """The calendar day this instant fell on where the child lives.

        `None` on an empty archive, which is the honest answer rather than today standing in.
        The column is `timestamptz`, so the value arrives aware; the `replace` is a belt-and-braces
        guard for a driver that hands back a naive UTC value rather than a wrong-by-hours answer.
        """
        if moment is None:
            return None
        aware = moment if moment.tzinfo else moment.replace(tzinfo=dt.UTC)
        return aware.astimezone(zone).date()

    # Grouped rather than one query per kind: three round trips to say the same thing is three
    # chances for them to disagree with each other about a write that landed in between.
    by_kind = dict(
        (
            await session.execute(
                select(Media.kind, func.count())
                .join(Entry, Entry.id == Media.entry_id)
                .where(
                    Entry.child_id == child.id,
                    Entry.deleted_at.is_(None),
                    Media.deleted_at.is_(None),
                )
                .group_by(Media.kind)
            )
        ).all()
    )

    return ChildStats(
        entries=counts[0],
        sealed=counts[1],
        # Every kind, always, including the ones at zero. A key that appears only once a child
        # has recorded audio is a key the client has to guard, and "no audio yet" is a fact the
        # archive knows — `photos · 0` is a truthful cell and an absent one is a crash.
        media={kind: by_kind.get(kind, 0) for kind in MEDIA_KINDS},
        first_entry_on=local_day(counts[2]),
        last_entry_on=local_day(counts[3]),
    )
