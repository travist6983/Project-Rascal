"""`python -m rascal.jobs.broadcast` — the daily prompt email.

A Fly scheduled machine runs this once a day. **Not APScheduler**, which story 4 specifies:
every other job in this service is a `python -m rascal.jobs.*` entrypoint run by Fly
(`scheduler`, `notify`, `delete`), and an in-process scheduler in a web app that runs more than
one machine would fire once per machine.

**It is safe to run twice.** The unique index on `send_date` means the second run reports that
the day is already done and exits 0, so a retried machine or a nervous hand-run costs nothing.

    python -m rascal.jobs.broadcast              # today
    python -m rascal.jobs.broadcast --date 2026-08-20
    python -m rascal.jobs.broadcast --show       # render today's and send nothing, ever

Nothing sends unless `MARKETING_EMAIL_ENABLED=true` and a verified sending domain is
configured. Without them this does the entire job except the network call and prints what it
would have sent.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt

from rascal.config import get_settings
from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services import broadcast
from rascal.services.email_copy import load


async def _run(as_of: dt.date | None) -> int:
    settings = get_settings()
    async with get_sessionmaker()() as session:
        try:
            result = await broadcast.run_broadcast(session, settings, as_of=as_of)
        except broadcast.AlreadySent as exc:
            print(f"broadcast: nothing to do — {exc}")
            return 0

    if result.was_sent:
        print(
            f"broadcast: sent {result.send_date} — prompt {result.pool_index}, "
            f"resend id {result.resend_id}"
        )
        return 0
    if result.status == "failed":
        print(f"broadcast: FAILED {result.send_date} — {result.error}")
        return 1
    print(
        f"broadcast: dry run for {result.send_date} — prompt {result.pool_index}, "
        f"nothing sent because {result.error}"
    )
    return 0


def _show(as_of: dt.date | None) -> int:
    """Render a day and print it. Touches neither the database nor the network."""
    day = as_of or dt.datetime.now(dt.UTC).date()
    copy = load()
    index, prompt = copy.prompt_for(day.timetuple().tm_yday)
    _, plain = broadcast.render(prompt, copy.footer, get_settings().marketing_site_url)
    print(f"date    : {day}")
    print(f"prompt  : {index} of {len(copy.pool)}")
    print(f"subject : {prompt}")
    print(f"---\n{plain}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--date",
        type=dt.date.fromisoformat,
        default=None,
        help="YYYY-MM-DD. The day to send, instead of today (UTC).",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Print the rendered email for the date and exit. No database, no network.",
    )
    args = parser.parse_args(argv)

    configure_logging()
    if args.show:
        return _show(args.date)
    return asyncio.run(_run(args.date))


if __name__ == "__main__":
    raise SystemExit(main())
