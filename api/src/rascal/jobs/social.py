"""`python -m rascal.jobs.social` — publish whatever the console queued and is now due.

A Fly scheduled machine runs this. **Not APScheduler and not a polling loop**: every other job
in this service is a `python -m rascal.jobs.*` entrypoint run by Fly (`scheduler`, `notify`,
`broadcast`, `delete`), an in-process scheduler in a web app that runs more than one machine
fires once per machine, and Fly gives a real scheduler where GitHub Actions — which the
marketing repository's poster runs on — measurably does not.

    python -m rascal.jobs.social            # publish what is due
    python -m rascal.jobs.social --dry-run  # say what is due, publish nothing
    python -m rascal.jobs.social --account  # which account do the credentials point at?

**At most one post per run, deliberately.** Looking often and posting often are separate
things. The account is shared with the marketing repository's hourly poster, and the spacing
check in `services/social/instagram.py` reads the account itself rather than our rows — so a
backlog drains at about one an hour however often this runs, and the two publishers stay out of
each other's way through Instagram rather than through a lock neither can hold.

**A run that publishes nothing is the normal case and says so.** A green exit and an empty log
are indistinguishable from a broken schedule, which is exactly how a marketing run that printed
*"nothing due"* got read as *"posted successfully"* for several hours.

**Nothing goes out unless `SOCIAL_PUBLISH_ENABLED=true`, and with it off this run does not
rehearse — it refuses.** The check is the first thing `publishing.run` does, before the
duplicate lookup, before spacing, before any container: a queued row is reported as staying
queued and the run exits 0. **`--dry-run` is the rehearsal**, and it is the flag-independent
one. This paragraph used to promise *"the whole job except the two calls to Meta"*, which is
what `broadcast.py` does and not what this does; an operator who believed it would set the flag
off expecting a report of what would have gone out.
"""

from __future__ import annotations

import argparse
import asyncio
import logging

from rascal.config import get_settings
from rascal.db import get_sessionmaker
from rascal.errors import RascalError
from rascal.logging_config import configure_logging
from rascal.services.social import instagram, publishing

log = logging.getLogger("rascal.jobs.social")


async def _account() -> int:
    """Which account, and what is actually on it.

    *"The run was green"* and *"there is a post on the account you are looking at"* are
    different claims, and this is the one that answers the second. Inherited from the marketing
    poster's `--check`, which exists because hours were spent on "posting is broken" when the
    truth was that nobody had confirmed which account the credentials controlled.
    """
    settings = get_settings()
    if not instagram.configured(settings):
        print("social: IG_USER_ID and IG_ACCESS_TOKEN are not set — nothing to check against")
        return 1
    who = await instagram.account(settings)
    space = await instagram.spacing(settings)
    print(f"account   @{who.username}  ({who.account_type}, id {who.id})")
    print(f"media     {who.media_count} posts on the account")
    print(f"last post {space.last_post_at.isoformat() if space.last_post_at else 'never'}")
    print(f"24h       {space.posts_in_last_24h} of {settings.social_daily_post_limit}")
    print(f"publish   {'ENABLED' if settings.social_publish_enabled else 'disabled'}")
    if space.blocked_reason:
        print(f"holding   {space.blocked_reason}")
    for item in (await instagram.recent_media(settings, limit=5))[:5]:
        first = item.caption.split("\n")[0][:72]
        print(f"  {item.timestamp.isoformat()}  {item.permalink or '(no permalink)'}")
        print(f"    {first}")
    return 0


async def _run(*, dry_run: bool) -> int:
    settings = get_settings()

    async with get_sessionmaker()() as session:
        # Before anything else: resolve rows a dead process left mid-publish. Each one holds
        # its asset hostage through the partial unique index until it is settled.
        if not dry_run and instagram.configured(settings):
            for row in await publishing.reclaim(session, settings):
                print(f"social: reclaimed {row.id} — {row.status}")

        pending = await publishing.due(session)
        if not pending:
            print("social: nothing due — nothing published")
            return 0

        first, rest = pending[0], pending[1:]
        if rest:
            # Named rather than silently left: a queue that is behind should say so, because
            # "one an hour" and "stuck" look identical from a single green run.
            print(f"social: {len(pending)} due, publishing the oldest — {len(rest)} will wait")

        if dry_run:
            when = first.scheduled_for.isoformat() if first.scheduled_for else "immediately"
            headline = ((first.caption or "").splitlines() or [""])[0][:72]
            print(
                f"social: would publish {first.id} to {first.platform}\n"
                f"  scheduled  {when}\n"
                f"  caption    {headline}"
            )
            return 0

        try:
            published = await publishing.run(session, settings, first)
        except publishing.TooSoon as exc:
            # Not a failure of this run. The row stays `scheduled` and the next hour takes it —
            # which is the whole mechanism keeping two publishers off one account's toes.
            await session.commit()
            print(f"social: holding off — {exc.message}")
            return 0
        except publishing.PublishingDisabled:
            # A deliberate state, not a fault. Red every hour is how a real alarm stops being
            # read, and this one would be red for as long as the owner meant it to be off.
            await session.commit()
            print(f"social: publishing is switched off — {first.id} stays queued")
            return 0
        except RascalError as exc:
            # The row now carries the reason, so the console can show it without reading Fly.
            await session.commit()
            print(f"social: FAILED to publish {first.id} — {exc.message}")
            return 1
        await session.commit()

    print(
        f"social: published {published.id} — media {published.media_id}"
        f"{f', {published.permalink}' if published.permalink else ''}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Say what is due and publish nothing. No call to Meta.",
    )
    parser.add_argument(
        "--account",
        action="store_true",
        help="Print the account the credentials control and its recent posts, then exit.",
    )
    args = parser.parse_args(argv)

    configure_logging()
    if args.account:
        return asyncio.run(_account())
    return asyncio.run(_run(dry_run=args.dry_run))


if __name__ == "__main__":
    raise SystemExit(main())
