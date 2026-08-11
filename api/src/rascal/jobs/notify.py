"""`python -m rascal.jobs.notify` — the job that sends the one daily notification.

Runs on a Fly scheduled machine, hourly, exactly like `rascal.jobs.scheduler`. The same
mechanism, deliberately: a second scheduling technology inside the app process would be a
second thing that stops when the machine stops, and this job can least afford that.

**Hourly is the floor Fly gives, not the resolution this wants.** A user picks a minute; Fly
schedules hourly. So a window is served by the first run after it opens, up to an hour late,
and `NOTIFICATION_STALENESS` is two hours precisely so one entirely missed run still gets
caught up rather than dropped. Run it more often than hourly if the platform ever allows —
nothing here assumes an interval, and every run is idempotent.

Every run is catch-up: it sends anything whose window has passed today and has not been
sent. There is no read path that repairs a missed notification the way `GET /today` repairs
a missed assignment, which is why this job's durability matters more than the scheduler's.
See `docs/runbook-deploy.md`.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import sys
import uuid

from rascal.config import get_settings
from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services.notifications import run_notifications
from rascal.services.push import build_push_client


async def _run(user_id: uuid.UUID | None, as_of: dt.datetime | None) -> int:
    # Built once per run and closed at the end, so one HTTP/2 connection serves every push
    # rather than one per token.
    client = build_push_client(get_settings())
    try:
        async with get_sessionmaker()() as session:
            run = await run_notifications(session, client=client, as_of=as_of, user_id=user_id)
            await session.commit()
    finally:
        await client.aclose()

    print(
        f"notify: {run.sent} sent to {run.delivered} device(s), "
        f"{run.failed} failed, {run.devices_revoked} device(s) revoked, "
        f"{run.skipped_already_sent} already sent today, "
        f"{run.skipped_not_due} not due yet, {run.skipped_stale} dropped as stale, "
        f"{run.skipped_nothing_pending} with nothing left to do, "
        f"{run.skipped_no_device} with no device, {run.skipped_no_child} with no child"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--user-id", type=uuid.UUID, default=None, help="Restrict the run to one user."
    )
    parser.add_argument(
        "--as-of",
        type=dt.datetime.fromisoformat,
        default=None,
        help=(
            "An ISO 8601 instant to read as 'now'. For reproducing a window locally; the "
            "real job always uses the wall clock. Naive values are read as UTC."
        ),
    )
    args = parser.parse_args(argv)
    configure_logging()

    as_of = args.as_of
    if as_of is not None and as_of.tzinfo is None:
        as_of = as_of.replace(tzinfo=dt.UTC)
    return asyncio.run(_run(args.user_id, as_of))


if __name__ == "__main__":
    sys.exit(main())
