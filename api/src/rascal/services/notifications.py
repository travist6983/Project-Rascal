"""The send job: one notification per user per day, carrying today's mission.

**One. Not two.** No reminder, no digest, no weekly summary, and nothing at all on a day
the parent already finished. There is no path through this module that sends twice.

Two properties this job has that the scheduler does not need, and why:

*Catch-up.* Assignment creation was demoted to an optimisation in Phase 12 because
`GET /today` repairs it: a machine that slept through 5am costs milliseconds on the first
read of the day. **A notification has no read to repair it.** Nothing calls anything at
19:00 on the user's behalf. So every run scans every enabled user and sends anything whose
window has already passed today and has not been sent — a machine that missed a run catches
up on the next one, rather than the notification simply never having happened.

*Staleness.* The other half of catch-up. A window missed by more than
:data:`~rascal.constants.NOTIFICATION_STALENESS` is dropped rather than fired late. A
notification at 2am about a mission for a day that is nearly over is worse than none, and a
job that had been down for a day would otherwise wake every user at once when it came back.

The date, the window, and "is it today yet" are all computed in the **child's
`family_timezone`**, through `services.dates` — the same one definition the scheduler uses.
Reading them in UTC is the 9pm-tomorrow bug.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import NOTIFICATION_SLOT_PRIORITY, NOTIFICATION_STALENESS
from rascal.models import Assignment, Child, Device, Guardian, NotificationSend, User
from rascal.services.dates import zone
from rascal.services.devices import live_devices
from rascal.services.push import PushClient, PushMessage, send_with_retry
from rascal.services.scheduler import ensure_day_filled
from rascal.services.today import assignments_for

log = logging.getLogger("rascal.notifications")


@dataclass
class NotificationRun:
    """What a run did. Every skip is counted separately, because "sent 0" has six causes and
    they need very different responses from whoever is reading the log line."""

    considered: int = 0
    sent: int = 0
    delivered: int = 0
    failed: int = 0
    devices_revoked: int = 0
    skipped_no_child: int = 0
    skipped_not_due: int = 0
    skipped_stale: int = 0
    skipped_already_sent: int = 0
    skipped_nothing_pending: int = 0
    skipped_no_device: int = 0
    stale_users: list[str] = field(default_factory=list)


async def _enabled_users(session: AsyncSession, user_id: uuid.UUID | None) -> list[User]:
    statement = select(User).where(User.notify_enabled.is_(True)).order_by(User.id)
    if user_id is not None:
        statement = statement.where(User.id == user_id)
    return list((await session.execute(statement)).scalars().all())


async def _child_for(session: AsyncSession, user: User) -> Child | None:
    """The child this user's notification is about.

    One child, deliberately. The rule is one notification per day per user, and a second kid
    is roadmap open item 7 — whose UI cost is a switcher and per-child scheduling, neither of
    which exists. Sending per-child would quietly turn one notification into N.

    The oldest child the user is a `parent` of, ordered by `created_at` then `id` so the
    choice is stable across runs rather than whatever the planner returned first. `viewer`
    guardians are excluded: a grandparent with read access did not sign up for a nightly
    reminder to do somebody else's mission.
    """
    return await session.scalar(
        select(Child)
        .join(Guardian, Guardian.child_id == Child.id)
        .where(
            Guardian.user_id == user.id,
            Guardian.role == "parent",
            Guardian.revoked_at.is_(None),
        )
        .order_by(Child.created_at.asc(), Child.id.asc())
        .limit(1)
    )


def _first_name(name: str) -> str | None:
    """The child's first name, or nothing. The only thing besides the mission body that a
    notification is allowed to carry."""
    parts = name.strip().split()
    return parts[0] if parts else None


def choose_assignment(today_items: list[Assignment]) -> Assignment | None:
    """Which of today's pending items the one notification carries. Pure.

    The mission first — it is the thing you go and *do*, and a nudge is for doing. The
    question last, because it is answered in conversation and needs no reminder to be
    answerable. Anything whose slot is not in the priority list falls back to the first
    pending item rather than being unreachable.
    """
    if not today_items:
        return None
    by_slot = {item.slot: item for item in today_items}
    for slot in NOTIFICATION_SLOT_PRIORITY:
        if slot in by_slot:
            return by_slot[slot]
    return today_items[0]


@dataclass(frozen=True)
class Window:
    """A user's send window for one child, resolved onto the wall clock where the child lives."""

    local_now: dt.datetime
    local_date: dt.date
    opens_at: dt.datetime

    @property
    def has_arrived(self) -> bool:
        return self.local_now >= self.opens_at

    @property
    def lateness(self) -> dt.timedelta:
        return self.local_now - self.opens_at

    @property
    def is_stale(self) -> bool:
        return self.lateness > NOTIFICATION_STALENESS


def resolve_window(instant: dt.datetime, timezone: str, local_time: dt.time) -> Window:
    """Read one instant as a wall clock in the child's zone, and place the window on it.

    `local_time` is deliberately not converted to UTC and compared there. 19:00 means 19:00
    where the child lives, on every day of the year — an offset computed once would be wrong
    for half of it, which is the same DST drift that made the scheduler run hourly rather
    than on one daily cron.
    """
    here = zone(timezone)
    local_now = instant.astimezone(here)
    local_date = local_now.date()
    return Window(
        local_now=local_now,
        local_date=local_date,
        opens_at=dt.datetime.combine(local_date, local_time, tzinfo=here),
    )


async def run_notifications(
    session: AsyncSession,
    *,
    client: PushClient,
    as_of: dt.datetime | None = None,
    user_id: uuid.UUID | None = None,
    sleep: Callable[[float], Awaitable[None]] | None = None,
) -> NotificationRun:
    """Send today's notification to every user whose window has arrived and who is not done.

    Safe to run as often as the platform allows and safe to run twice at once: the unique
    index on `(user_id, notification_date)` is the guarantee, and the row is claimed with
    `ON CONFLICT DO NOTHING` *before* anything reaches APNs.
    """
    instant = as_of or dt.datetime.now(tz=dt.UTC)
    run = NotificationRun()

    for user in await _enabled_users(session, user_id):
        run.considered += 1

        child = await _child_for(session, user)
        if child is None:
            # Notifications on, no child yet. Nothing to be about.
            run.skipped_no_child += 1
            continue

        window = resolve_window(instant, child.family_timezone, user.notify_local_time)
        if not window.has_arrived:
            run.skipped_not_due += 1
            continue
        if window.is_stale:
            # Dropped, not fired late. Counted and named so a run of these is visible as the
            # job having been down rather than as users quietly getting nothing.
            run.skipped_stale += 1
            run.stale_users.append(str(user.id))
            log.warning(
                "notification window missed beyond tolerance, dropping",
                extra={
                    "user_id": str(user.id),
                    "child_id": str(child.id),
                    "notification_date": window.local_date.isoformat(),
                    "minutes_late": int(window.lateness.total_seconds() // 60),
                    "tolerance_minutes": int(NOTIFICATION_STALENESS.total_seconds() // 60),
                },
            )
            continue

        # The Phase 12 path, not a second copy of it. If the scheduled machine never fired,
        # the notification still carries a real mission rather than nothing — and the 180-day
        # cooldown, theme rotation, age window and seasonal filter are the scheduler's own.
        await ensure_day_filled(session, child, window.local_date)

        today_items, _waiting, _done_today = await assignments_for(
            session, child, window.local_date
        )
        if not today_items:
            # Every item for today is done, dismissed, or the day was empty. Send nothing:
            # no "great job", no summary, no streak. A parent who finished the day does not
            # get pinged about it.
            run.skipped_nothing_pending += 1
            continue

        devices = await live_devices(session, user.id)
        if not devices:
            # Nothing to send to, so nothing is claimed. A phone registering later today
            # still gets the notification, as long as the window has not gone stale.
            run.skipped_no_device += 1
            continue

        assignment = choose_assignment(today_items)
        assert assignment is not None  # today_items is non-empty.

        claimed = await _claim(session, user, child, assignment, window, len(devices))
        if not claimed:
            run.skipped_already_sent += 1
            continue

        delivered = await _deliver(session, run, client, child, assignment, window, devices, sleep)
        run.sent += 1
        run.delivered += delivered
        await session.execute(
            update(NotificationSend)
            .where(NotificationSend.id == claimed)
            .values(delivered_count=delivered)
        )

    await session.flush()
    log.info(
        "notification run",
        extra={
            "users_considered": run.considered,
            "notifications_sent": run.sent,
            "pushes_delivered": run.delivered,
            "pushes_failed": run.failed,
            "devices_revoked": run.devices_revoked,
            "skipped_no_child": run.skipped_no_child,
            "skipped_not_due": run.skipped_not_due,
            "skipped_stale": run.skipped_stale,
            "skipped_already_sent": run.skipped_already_sent,
            "skipped_nothing_pending": run.skipped_nothing_pending,
            "skipped_no_device": run.skipped_no_device,
        },
    )
    return run


async def _claim(
    session: AsyncSession,
    user: User,
    child: Child,
    assignment: Assignment,
    window: Window,
    device_count: int,
) -> uuid.UUID | None:
    """Take the day's single notification slot, or find it already taken.

    `ON CONFLICT DO NOTHING` on `(user_id, notification_date)`, exactly the way the scheduler
    writes assignments. Deliberately **not** a read-then-write: two runs overlapping would
    both read "not sent" and both send. Written before the push rather than after, so a
    crash between the two costs one notification instead of sending one every retry.
    """
    statement = (
        insert(NotificationSend)
        .values(
            id=uuid.uuid4(),
            user_id=user.id,
            child_id=child.id,
            assignment_id=assignment.id,
            notification_date=window.local_date,
            device_count=device_count,
            delivered_count=0,
        )
        .on_conflict_do_nothing(
            index_elements=[NotificationSend.user_id, NotificationSend.notification_date]
        )
        .returning(NotificationSend.id)
    )
    return (await session.execute(statement)).scalar_one_or_none()


async def _deliver(
    session: AsyncSession,
    run: NotificationRun,
    client: PushClient,
    child: Child,
    assignment: Assignment,
    window: Window,
    devices: list[Device],
    sleep: Callable[[float], Awaitable[None]] | None,
) -> int:
    """Push to every live token, and act on what APNs says back.

    The payload is the mission body, optionally the child's first name, and the assignment id
    for the deep link. Nothing else — no entry content, nothing from a sealed entry, and no
    count of waiting or missed items. This renders on a lock screen other people can see, and
    a backlog number there is a guilt engine you cannot look away from.

    The body is deliberately not truncated. Prompts run long, and cutting one mid-word
    server-side is worse than letting the OS lay it out.
    """
    title = _first_name(child.name)
    delivered = 0

    for device in devices:
        message = PushMessage(
            token=device.token,
            environment=device.environment,
            # `resolved_body` is a parent-authored one-off if there is one, else the library
            # prompt. It is what the Today screen shows for this item, and it is the mission.
            body=assignment.resolved_body,
            assignment_id=assignment.id,
            title=title,
            # One id per user per day, so two devices and a retry cannot become three rows
            # on one lock screen.
            collapse_id=f"rascal-{window.local_date.isoformat()}",
        )
        result = await send_with_retry(client, message, sleep=sleep)

        if result.ok:
            delivered += 1
            continue

        run.failed += 1
        if result.token_is_dead:
            # Without this, dead tokens accumulate forever and the failure rate climbs
            # invisibly until nothing is being delivered at all.
            device.revoked_at = dt.datetime.now(tz=dt.UTC)
            run.devices_revoked += 1
            log.info(
                "device revoked by APNs",
                extra={
                    "device_id": str(device.id),
                    "apns_status": result.status,
                    "apns_reason": result.reason,
                },
            )
        else:
            # Logged and dropped. Never queued into tomorrow — tomorrow has its own mission.
            log.warning(
                "notification failed",
                extra={
                    "device_id": str(device.id),
                    "apns_status": result.status,
                    "apns_reason": result.reason,
                },
            )

    await session.flush()
    return delivered
