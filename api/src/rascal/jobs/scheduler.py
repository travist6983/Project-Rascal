"""`python -m rascal.jobs.scheduler` — the job Fly runs hourly.

It fires every hour and does work only for the children for whom it is currently 5am on the
wall. A single daily cron can only be 5am in one timezone and drifts an hour against DST
twice a year; twenty-four cheap wakeups remove that whole class of bug. The run is
idempotent on `(child_id, assigned_on, slot)`, so a double-fire costs nothing.

`--date` runs one calendar day for every child regardless of the hour, which is what a
backfill or a date you slept through needs. `--any-hour` does the same for "now".
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import sys
import uuid

from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services.scheduler import SCHEDULER_LOCAL_HOUR, run_scheduler


async def _run(
    as_of_date: dt.date | None, child_id: uuid.UUID | None, only_local_hour: int | None
) -> int:
    async with get_sessionmaker()() as session:
        run = await run_scheduler(
            session,
            as_of_date=as_of_date,
            child_id=child_id,
            only_local_hour=only_local_hour,
        )
        await session.commit()
    print(
        f"scheduler: {run.created} created, {run.skipped_existing} already there, "
        f"{run.expired} expired, {run.skipped_off_hour} not at their 5am, "
        f"{len(run.exhausted)} slot(s) with no eligible prompt"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--date",
        type=dt.date.fromisoformat,
        default=None,
        help="YYYY-MM-DD. Runs that calendar day for every child instead of 'now'.",
    )
    parser.add_argument(
        "--child-id", type=uuid.UUID, default=None, help="Restrict the run to one child."
    )
    parser.add_argument(
        "--any-hour",
        action="store_true",
        help="Ignore the local-hour filter (default: only children where it is 5am).",
    )
    args = parser.parse_args(argv)
    configure_logging()

    # An explicit --date is a deliberate backfill, so the wall clock stops being the point.
    only_local_hour = None
    if args.date is None and not args.any_hour:
        only_local_hour = SCHEDULER_LOCAL_HOUR
    return asyncio.run(_run(args.date, args.child_id, only_local_hour))


if __name__ == "__main__":
    sys.exit(main())
