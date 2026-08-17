"""`python -m rascal.jobs.delete` — carry out deletions whose grace period has elapsed.

Runs on a Fly scheduled machine, like `rascal.jobs.scheduler` and `rascal.jobs.notify`. The same
mechanism deliberately: a second scheduling technology inside the app process would be a second
thing that stops when the machine stops.

**Daily is enough and hourly is harmless.** Nothing here assumes an interval — a request carries
its own `execute_after`, so a run that is late deletes what was due and a run that is early
deletes nothing. Every run is idempotent because a completed request is no longer pending.

**This is the only job in the service that destroys user data.** `--dry-run` exists for that
reason and prints what would go without touching anything.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import sys

from sqlalchemy import select

from rascal.config import get_settings
from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.models import DeletionRequest
from rascal.services.deletion import run_due_deletions


async def _main(dry_run: bool) -> int:
    configure_logging()
    settings = get_settings()
    now = dt.datetime.now(tz=dt.UTC)

    async with get_sessionmaker()() as session:
        if dry_run:
            due = list(
                (
                    await session.execute(
                        select(DeletionRequest).where(
                            DeletionRequest.cancelled_at.is_(None),
                            DeletionRequest.execute_after <= now,
                        )
                    )
                )
                .scalars()
                .all()
            )
            print(f"due now: {len(due)}")
            for request in due:
                print(f"  user {request.user_id} requested {request.requested_at.isoformat()}")
            return 0

        totals = await run_due_deletions(session, settings, now=now)
        print(
            f"accounts={totals['accounts']} children={totals['children']} "
            f"objects={totals['objects']}"
        )
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what is due and delete nothing.",
    )
    args = parser.parse_args()
    return asyncio.run(_main(args.dry_run))


if __name__ == "__main__":
    sys.exit(main())
