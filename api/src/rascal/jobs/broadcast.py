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
import zoneinfo

from rascal.config import get_settings
from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services import broadcast, prompt_tokens
from rascal.services.email_copy import load


def _local_now(settings) -> dt.datetime:
    """Now, where the reader is. **The send date is a local date, not a UTC one** — a prompt for
    "today" has to mean the subscriber's today, and at 8am Detroit those differ for four hours
    of every UTC day."""
    return dt.datetime.now(zoneinfo.ZoneInfo(settings.broadcast_timezone))


async def _run(as_of: dt.date | None, *, force: bool) -> int:
    settings = get_settings()

    # **Checked before anything touches the database.** A row claims the day, so an off-hour run
    # that wrote one would cancel that day's send rather than defer it.
    if as_of is None and not force:
        local = _local_now(settings)
        if local.hour != settings.broadcast_send_hour:
            print(
                f"broadcast: not the send hour — it is {local:%H:%M %Z}, "
                f"sending at {settings.broadcast_send_hour:02d}:00. Nothing written."
            )
            return 0
        as_of = local.date()
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


async def _show(as_of: dt.date | None) -> int:
    """Render a day and print it. **Never sends, and never writes a ledger row.**

    It reads the database now, which it did not before phase 90 — the prompt comes from the
    seeded library rather than from a pool in the copy file, so there is nowhere else to get it.
    The property that actually matters is unchanged and is the reason this flag exists: **no
    network call and no row**, so it is safe to run against production at any time.
    """
    day = as_of or dt.datetime.now(dt.UTC).date()
    settings = get_settings()
    copy = load()
    async with get_sessionmaker()() as session:
        picked = await broadcast.pick_prompt(session, day.timetuple().tm_yday)
        total = await broadcast.daily_prompt_count(session)
    if picked is None:
        print("broadcast: the library has no daily prompt to send")
        return 1
    index, chosen = picked
    body = prompt_tokens.render(chosen.body, name=broadcast.NAME_STANDIN, pronouns=None)
    _, plain = broadcast.render(
        body, copy.footer, settings.marketing_site_url, chosen.kind, chosen.completion_mode
    )
    print(f"date    : {day}")
    print(f"prompt  : {index + 1} of {total}")
    print(f"kind    : {chosen.kind} / {chosen.completion_mode}")
    print(f"subject : {body}")
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
    parser.add_argument(
        "--force",
        action="store_true",
        help="Send now regardless of the hour. For a deliberate hand-run; the ledger still "
        "allows only one send per day.",
    )
    args = parser.parse_args(argv)

    configure_logging()
    if args.show:
        return asyncio.run(_show(args.date))
    return asyncio.run(_run(args.date, force=args.force))


if __name__ == "__main__":
    raise SystemExit(main())
