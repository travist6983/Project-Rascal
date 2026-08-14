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
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass

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

    # `occurred_at` is stored UTC; the archive's day is a family-timezone day. Postgres does the
    # conversion because it is the only participant that can do it in the same pass as the
    # aggregate — pulling every row back to convert in Python would make this O(archive).
    local_day = func.date(func.timezone(child.family_timezone, live.c.occurred_at))

    counts = (
        await session.execute(
            select(
                func.count(),
                func.count().filter(live.c.unlock_at_age.is_not(None)),
                func.min(local_day),
                func.max(local_day),
            ).select_from(live)
        )
    ).one()

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
        first_entry_on=counts[2],
        last_entry_on=counts[3],
    )
