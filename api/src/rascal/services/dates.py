"""Dates and ages.

"Today" is always a date in the child's `family_timezone`, derived from an instant. Never
UTC, never the server's local time. Without this the 5am job hands you tomorrow's mission at
9pm.
"""

from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from rascal.errors import validation_failed


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise validation_failed(
            f"{name!r} is not a known IANA timezone.", field="family_timezone"
        ) from exc


def local_date(instant: dt.datetime, timezone: str) -> dt.date:
    """The calendar date an instant falls on, in the given zone.

    Two children in different zones can get different dates from the same UTC moment, and
    that is correct.
    """
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=dt.UTC)
    return instant.astimezone(zone(timezone)).date()


def local_hour(instant: dt.datetime, timezone: str) -> int:
    """The hour of the clock on the wall in that zone, 0-23.

    The scheduler fires hourly and uses this to pick out the children for whom it is
    currently 5am. One daily UTC cron can only ever be 5am in one place, and it drifts an
    hour against DST twice a year.
    """
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=dt.UTC)
    return instant.astimezone(zone(timezone)).hour


def today_in(timezone: str, *, now: dt.datetime | None = None) -> dt.date:
    return local_date(now or dt.datetime.now(tz=dt.UTC), timezone)


def age_in_months(birthdate: dt.date, on: dt.date) -> int:
    """Completed months between a birthdate and a date. Never negative.

    Whole months only: a child born on the 30th is 1 month old on the 30th of the next
    month, not on the 29th.
    """
    months = (on.year - birthdate.year) * 12 + (on.month - birthdate.month)
    if on.day < birthdate.day:
        months -= 1
    return max(months, 0)


def age_at_instant(birthdate: dt.date, instant: dt.datetime, timezone: str) -> int:
    """The stored `child_age_months` for an entry, from its `occurred_at`."""
    return age_in_months(birthdate, local_date(instant, timezone))
