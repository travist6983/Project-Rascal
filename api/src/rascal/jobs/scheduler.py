"""`python -m rascal.jobs.scheduler` — the daily job Fly runs on a schedule.

With no arguments it uses the current instant, so every child gets the date that instant
falls on in their own `family_timezone`. `--date` runs one calendar day for everyone, which
is what a backfill or a date you slept through needs.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import sys
import uuid

from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services.scheduler import run_scheduler


async def _run(as_of_date: dt.date | None, child_id: uuid.UUID | None) -> int:
    async with get_sessionmaker()() as session:
        run = await run_scheduler(session, as_of_date=as_of_date, child_id=child_id)
        await session.commit()
    print(
        f"scheduler: {run.created} created, {run.skipped_existing} already there, "
        f"{run.expired} expired, {len(run.exhausted)} slot(s) with no eligible prompt"
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
    args = parser.parse_args(argv)
    configure_logging()
    return asyncio.run(_run(args.date, args.child_id))


if __name__ == "__main__":
    sys.exit(main())
