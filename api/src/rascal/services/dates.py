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


def local_day_window(
    start: dt.date, end: dt.date, timezone: str
) -> tuple[dt.datetime, dt.datetime]:
    """UTC bounds for an inclusive range of calendar days in `timezone`, half-open.

    Returns `[begins, ends)` — `begins` is local midnight on `start`, `ends` is local midnight
    on the day *after* `end`. Half-open rather than `<=` on a computed end-of-day, because
    23:59:59.999999 is a value an entry can legitimately have and a closed range drops it.

    **Both bounds are instants, so the comparison stays sargable** and uses the existing
    `(child_id, occurred_at desc)` index. Converting the column instead — `date(occurred_at
    at time zone ...)` — is the version that reads naturally and cannot use an index.

    DST is handled by the conversion rather than by arithmetic: local midnight is resolved in
    the zone first and *then* mapped to UTC, so a range spanning a transition is 23 or 25
    hours on that day and still lands exactly on the two midnights a person would name. Adding
    a day to the UTC instant instead would be an hour off for half the year.
    """
    here = zone(timezone)
    begins = dt.datetime.combine(start, dt.time.min, tzinfo=here)
    ends = dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min, tzinfo=here)
    return begins.astimezone(dt.UTC), ends.astimezone(dt.UTC)


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
