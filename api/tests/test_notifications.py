"""The send job. One notification per user per day, carrying today's mission.

The two assertions worth naming up front, because both are the kind that passes vacuously
if the code stops working entirely:

* a user whose day is finished gets **zero** sends — asserted on the count, never on the
  absence of a phrase in a message that might not have been built at all;
* the window resolves in the child's ``family_timezone``, asserted with a child in a zone
  where UTC gives a different calendar date. That is the 9pm-tomorrow bug, and reading the
  clock in UTC would turn this test's send into no send at all.
"""

from __future__ import annotations

import datetime as dt
import uuid
from zoneinfo import ZoneInfo

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_device, make_prompt, make_user
from rascal.constants import NOTIFICATION_STALENESS
from rascal.models import Assignment, Entry, NotificationSend, User
from rascal.services.notifications import run_notifications
from rascal.services.push import PushResult, StubPushClient

# A plain Friday: not a Saturday, not the 1st, not the 15th, so `slots_for` is the daily
# pair and nothing else. A date that quietly also carried a weekly would make "the mission
# is what gets sent" ambiguous.
DAY = dt.date(2026, 8, 14)
DETROIT = "America/Detroit"
# UTC-10 all year, so a local evening is the *next* UTC day. No DST to reason about.
HONOLULU = "Pacific/Honolulu"

MISSION = "Get on the floor for ten minutes and let him lead."
QUESTION = "What did he say today that you want to remember?"


async def _never_sleep(_seconds: float) -> None:
    """Retry backoff, without the wait. No test should be slow because APNs might be."""
    return None


def _utc(day: dt.date, at: dt.time, timezone: str) -> dt.datetime:
    """The UTC instant at which it is `at` on the wall clock in `timezone`."""
    return dt.datetime.combine(day, at, tzinfo=ZoneInfo(timezone)).astimezone(dt.UTC)


async def _world(
    session: AsyncSession,
    *,
    timezone: str = DETROIT,
    notify_at: dt.time = dt.time(19, 0),
    notify_enabled: bool = True,
    devices: int = 1,
) -> tuple[User, object, list]:
    """A parent with notifications on, one child, and a prompt pool the day can be filled from."""
    user = await make_user(session, notify_enabled=notify_enabled, notify_local_time=notify_at)
    child = await make_child(session, name="Miles", timezone=timezone)
    await grant(session, user, child, "parent")

    await make_prompt(session, kind="question", cadence="daily", body=QUESTION)
    await make_prompt(
        session, kind="activity", cadence="daily", completion_mode="did_it", body=MISSION
    )

    made = [await make_device(session, user) for _ in range(devices)]
    await session.commit()
    return user, child, made


async def _run(session: AsyncSession, *, at: dt.datetime, client: StubPushClient | None = None):
    push = client or StubPushClient()
    run = await run_notifications(session, client=push, as_of=at, sleep=_never_sleep)
    await session.commit()
    return run, push


async def _sends(session: AsyncSession) -> list[NotificationSend]:
    rows = await session.execute(sa.select(NotificationSend))
    return list(rows.scalars().all())


# --- The window ------------------------------------------------------------------------------


async def test_a_notification_goes_out_once_the_window_has_arrived(
    session: AsyncSession,
) -> None:
    user, _child, _ = await _world(session)

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 1), DETROIT))

    assert run.sent == 1
    assert len(push.sent) == 1
    message = push.sent[0]
    assert message.body == MISSION
    assert message.title == "Miles"

    sends = await _sends(session)
    assert len(sends) == 1
    assert sends[0].notification_date == DAY
    assert sends[0].user_id == user.id


async def test_nothing_is_sent_before_the_window_opens(session: AsyncSession) -> None:
    await _world(session)

    run, push = await _run(session, at=_utc(DAY, dt.time(18, 59), DETROIT))

    assert run.sent == 0
    assert run.skipped_not_due == 1
    assert push.sent == []
    assert await _sends(session) == []


async def test_the_window_resolves_in_the_family_timezone_rather_than_utc(
    session: AsyncSession,
) -> None:
    """The 9pm-tomorrow bug, as a test.

    Honolulu is UTC-10, so 19:30 on the 14th there is **05:30 UTC on the 15th**. A job that
    read the clock in UTC would compare 05:30 against a 19:00 window, decide the window had
    not opened, and send nothing — and if it somehow sent, it would file the row under the
    15th, a day that has not happened where the child lives.
    """
    instant = _utc(DAY, dt.time(19, 30), HONOLULU)
    assert instant.date() == dt.date(2026, 8, 15), "the fixture must straddle a UTC midnight"

    await _world(session, timezone=HONOLULU)
    run, push = await _run(session, at=instant)

    assert run.sent == 1
    assert len(push.sent) == 1
    sends = await _sends(session)
    # The child's date, not the instant's.
    assert sends[0].notification_date == DAY

    # And the assignment it carries belongs to the child's day too.
    assignment = await session.get(Assignment, sends[0].assignment_id)
    assert assignment is not None
    assert assignment.assigned_on == DAY


async def test_a_window_missed_beyond_tolerance_is_dropped_rather_than_fired_late(
    session: AsyncSession,
) -> None:
    """A notification at 2am about a day that is nearly over is worse than none."""
    await _world(session)
    late = dt.time(19, 0)
    beyond = _utc(DAY, late, DETROIT) + NOTIFICATION_STALENESS + dt.timedelta(minutes=1)

    run, push = await _run(session, at=beyond)

    assert run.sent == 0
    assert run.skipped_stale == 1
    assert push.sent == []
    # Nothing is claimed either, so a job that comes back tomorrow is not blocked by today.
    assert await _sends(session) == []


async def test_a_window_missed_within_tolerance_still_fires(session: AsyncSession) -> None:
    """The catch-up half. There is no read path that repairs a missed notification, so a
    machine that slept through the hour has to send on the next run."""
    await _world(session)
    within = _utc(DAY, dt.time(19, 0), DETROIT) + NOTIFICATION_STALENESS - dt.timedelta(minutes=1)

    run, push = await _run(session, at=within)

    assert run.sent == 1
    assert len(push.sent) == 1


# --- Once, and only once ---------------------------------------------------------------------


async def test_running_the_job_twice_sends_exactly_one_notification(
    session: AsyncSession,
) -> None:
    """The guarantee is the unique index, not a read-then-write check in front of it."""
    await _world(session)
    at = _utc(DAY, dt.time(19, 5), DETROIT)
    push = StubPushClient()

    first, _ = await _run(session, at=at, client=push)
    second, _ = await _run(session, at=at + dt.timedelta(minutes=30), client=push)

    assert first.sent == 1
    assert second.sent == 0
    assert second.skipped_already_sent == 1
    assert len(push.sent) == 1
    assert len(await _sends(session)) == 1


async def test_a_second_day_gets_its_own_notification(session: AsyncSession) -> None:
    """Once per day, not once ever."""
    await _world(session)
    push = StubPushClient()

    await _run(session, at=_utc(DAY, dt.time(19, 5), DETROIT), client=push)
    await _run(session, at=_utc(DAY + dt.timedelta(days=1), dt.time(19, 5), DETROIT), client=push)

    assert len(push.sent) == 2
    assert {row.notification_date for row in await _sends(session)} == {
        DAY,
        DAY + dt.timedelta(days=1),
    }


# --- Silence when the day is done ------------------------------------------------------------


async def _finish_the_day(
    session: AsyncSession, user: User, child, day: dt.date, timezone: str
) -> None:
    """Both of the day's slots assigned, completed, and evidenced by a real entry.

    `assignments_for` only counts an assignment as done when an entry with that
    `assignment_id` occurred on the day, so setting a status alone would not be a finished
    day — it would be a way for this test to pass without the product working.
    """
    for slot, kind in (("question", "question"), ("mission", "activity")):
        prompt = await make_prompt(session, kind=kind, cadence="daily")
        assignment = await make_assignment(
            session, child, prompt, slot=slot, assigned_on=day, status="done"
        )
        session.add(
            Entry(
                id=uuid.uuid4(),
                child_id=child.id,
                assignment_id=assignment.id,
                author_id=user.id,
                occurred_at=_utc(day, dt.time(12, 0), timezone),
                child_age_months=50,
                entry_type="did_it",
            )
        )
    await session.flush()
    await session.commit()


async def test_a_user_whose_day_is_fully_done_receives_nothing(
    session: AsyncSession,
) -> None:
    """The no-guilt rule, applied correctly. No "great job", no summary, no streak.

    Asserted on **zero sends**, not on the content of a message — a message that was never
    built would satisfy any assertion about what it does not contain.
    """
    user, child, _ = await _world(session)
    await _finish_the_day(session, user, child, DAY, DETROIT)

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 0
    assert run.skipped_nothing_pending == 1
    assert push.sent == []
    assert await _sends(session) == []


async def test_a_day_only_half_done_still_notifies(session: AsyncSession) -> None:
    """The counterweight to the test above: silence is for a *finished* day, and a day with
    one item left is not one. Without this, a job that sent nothing ever would pass."""
    user, child, _ = await _world(session)
    prompt = await make_prompt(session, kind="question", cadence="daily")
    assignment = await make_assignment(
        session, child, prompt, slot="question", assigned_on=DAY, status="done"
    )
    session.add(
        Entry(
            id=uuid.uuid4(),
            child_id=child.id,
            assignment_id=assignment.id,
            author_id=user.id,
            occurred_at=_utc(DAY, dt.time(12, 0), DETROIT),
            child_age_months=50,
            entry_type="did_it",
        )
    )
    await session.commit()

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 1
    # The mission is what is left, and the mission is what it carries.
    assert push.sent[0].body == MISSION


async def test_notifications_off_sends_nothing(session: AsyncSession) -> None:
    """Off by default, and off means off however arrived the window is."""
    await _world(session, notify_enabled=False)

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.considered == 0
    assert run.sent == 0
    assert push.sent == []


# --- What it carries -------------------------------------------------------------------------


async def test_the_notification_carries_the_mission_rather_than_the_question(
    session: AsyncSession,
) -> None:
    """A nudge is for the thing you go and do. The question is answered in conversation."""
    await _world(session)

    _, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert push.sent[0].body == MISSION
    assert QUESTION not in push.sent[0].body


async def test_the_payload_carries_the_assignment_id_for_deep_linking(
    session: AsyncSession,
) -> None:
    await _world(session)

    _, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    message = push.sent[0]
    assignment = await session.get(Assignment, message.assignment_id)
    assert assignment is not None
    assert assignment.assigned_on == DAY
    assert message.payload()["assignment_id"] == str(assignment.id)


async def test_the_payload_never_carries_entry_content_a_sealed_body_or_a_backlog_count(
    session: AsyncSession,
) -> None:
    """This renders on a lock screen other people can see.

    The fixture is deliberately the worst case: a sealed letter written to the child, an
    ordinary entry with a private body, and a backlog of five overdue items. None of it may
    appear, and neither may the number five in any form.
    """
    user, child, _ = await _world(session)

    sealed = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=_utc(DAY - dt.timedelta(days=3), dt.time(9, 0), DETROIT),
        child_age_months=50,
        entry_type="text",
        title="For when you are eighteen",
        body="SEALED-LETTER-BODY-THAT-MUST-NEVER-LEAVE-THE-ARCHIVE",
        unlock_at_age=18,
    )
    ordinary = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=_utc(DAY - dt.timedelta(days=1), dt.time(9, 0), DETROIT),
        child_age_months=50,
        entry_type="text",
        body="PRIVATE-ENTRY-BODY",
    )
    session.add_all([sealed, ordinary])

    # A real backlog: five pending items from previous days, which is exactly the number a
    # guilt-engine notification would want to announce.
    for offset in range(1, 6):
        prompt = await make_prompt(session, kind="activity", cadence="daily")
        await make_assignment(
            session,
            child,
            prompt,
            slot="mission",
            assigned_on=DAY - dt.timedelta(days=offset),
            status="pending",
        )
    await session.commit()

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 1
    payload = push.sent[0].payload()
    rendered = str(payload)

    # Nothing from the archive reaches the wire, anywhere in the payload.
    assert "SEALED-LETTER-BODY-THAT-MUST-NEVER-LEAVE-THE-ARCHIVE" not in rendered
    assert "For when you are eighteen" not in rendered
    assert "PRIVATE-ENTRY-BODY" not in rendered

    # And nothing *else* reaches it either: two keys, and the deep link is an id rather
    # than anything describing what is behind it.
    assert set(payload) == {"aps", "assignment_id"}
    assert set(payload["aps"]) == {"alert", "sound"}

    # No count of waiting or missed items, in any wording. Asserted against the text a
    # human actually sees — the whole payload legitimately contains the assignment UUID,
    # whose hex digits would make a naive substring check pass or fail by coincidence.
    alert = payload["aps"]["alert"]
    visible = f"{alert.get('title', '')} {alert['body']}"
    assert not any(character.isdigit() for character in visible), visible
    assert "waiting" not in visible.lower()

    # What it *does* carry, so this test cannot pass by the payload being empty.
    assert push.sent[0].body == MISSION


async def test_the_body_is_not_truncated_server_side(session: AsyncSession) -> None:
    """Prompts run long. Cutting one mid-word is worse than letting the OS lay it out."""
    long_mission = "Ask him about " + ("the thing he built out of blocks " * 12).strip()
    user = await make_user(session, notify_enabled=True, notify_local_time=dt.time(19, 0))
    child = await make_child(session, name="Miles", timezone=DETROIT)
    await grant(session, user, child, "parent")
    await make_device(session, user)
    prompt = await make_prompt(session, kind="activity", cadence="daily", body=long_mission)
    await make_assignment(session, child, prompt, slot="mission", assigned_on=DAY)
    await make_prompt(session, kind="question", cadence="daily", body=QUESTION)
    await session.commit()

    _, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert push.sent[0].body == long_mission


# --- Devices ---------------------------------------------------------------------------------


async def test_every_live_device_receives_the_one_notification(
    session: AsyncSession,
) -> None:
    """One user, many devices — phone today, iPad later. Still one notification."""
    await _world(session, devices=3)

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 1
    assert len(push.sent) == 3
    # One id across all three, so two devices cannot become two rows on one lock screen.
    assert len({message.collapse_id for message in push.sent}) == 1
    assert len(await _sends(session)) == 1


async def test_a_revoked_device_receives_nothing(session: AsyncSession) -> None:
    """Sign-out has to actually stop delivery, not just hide the row."""
    _user, _child, devices = await _world(session, devices=2)
    devices[0].revoked_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()

    _, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert [message.token for message in push.sent] == [devices[1].token]


async def test_a_user_with_no_device_is_not_recorded_as_sent(
    session: AsyncSession,
) -> None:
    """Nothing was attempted, so nothing is claimed — a phone registered an hour later still
    gets today's notification, as long as the window has not gone stale."""
    _user, _child, devices = await _world(session, devices=1)
    devices[0].revoked_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 15), DETROIT))

    assert run.skipped_no_device == 1
    assert push.sent == []
    assert await _sends(session) == []


async def test_a_410_from_apns_revokes_the_device(session: AsyncSession) -> None:
    """Without this, dead tokens accumulate forever and the failure rate climbs invisibly."""
    _user, _child, devices = await _world(session, devices=1)
    push = StubPushClient(
        results={devices[0].token: PushResult(ok=False, status=410, reason="Unregistered")}
    )

    run, _ = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT), client=push)

    assert run.devices_revoked == 1
    assert run.failed == 1
    await session.refresh(devices[0])
    assert devices[0].revoked_at is not None


async def test_a_bad_device_token_revokes_the_device(session: AsyncSession) -> None:
    """`BadDeviceToken` arrives as a 400, not a 410, and means the same thing."""
    _user, _child, devices = await _world(session, devices=1)
    push = StubPushClient(
        results={devices[0].token: PushResult(ok=False, status=400, reason="BadDeviceToken")}
    )

    run, _ = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT), client=push)

    assert run.devices_revoked == 1
    await session.refresh(devices[0])
    assert devices[0].revoked_at is not None


async def test_an_ordinary_failure_leaves_the_device_alone_and_is_not_queued(
    session: AsyncSession,
) -> None:
    """A failed send is logged and dropped. Never retried into tomorrow, and never a reason
    to throw away a token that is probably fine."""
    _user, _child, devices = await _world(session, devices=1)
    push = StubPushClient(
        results={devices[0].token: PushResult(ok=False, status=413, reason="PayloadTooLarge")}
    )

    run, _ = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT), client=push)

    assert run.failed == 1
    assert run.devices_revoked == 0
    await session.refresh(devices[0])
    assert devices[0].revoked_at is None
    # The day is still recorded as sent, so a rerun an hour later does not try again.
    sends = await _sends(session)
    assert len(sends) == 1
    assert sends[0].delivered_count == 0
    assert sends[0].device_count == 1


# --- Reusing the scheduler -------------------------------------------------------------------


async def test_the_job_fills_the_day_through_the_shared_scheduler_path(
    session: AsyncSession,
) -> None:
    """A machine that slept through 5am must not also cost the notification.

    Nothing is assigned when this runs, and the notification still carries a real mission
    from the library — created by `ensure_day_filled`, which is the scheduler's own
    selection code rather than a second copy of it.
    """
    _user, child, _ = await _world(session)
    existing = await session.execute(
        sa.select(sa.func.count()).select_from(Assignment).where(Assignment.child_id == child.id)
    )
    assert existing.scalar_one() == 0

    run, push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 1
    filled = await session.execute(
        sa.select(Assignment.slot).where(
            Assignment.child_id == child.id, Assignment.assigned_on == DAY
        )
    )
    assert set(filled.scalars().all()) == {"question", "mission"}
    assert push.sent[0].body == MISSION


async def test_a_viewer_guardian_is_not_notified_about_somebody_elses_child(
    session: AsyncSession,
) -> None:
    """A grandparent with read access did not sign up for a nightly reminder to do a mission."""
    parent, child, _ = await _world(session)
    viewer = await make_user(
        session, display_name="Grandma", notify_enabled=True, notify_local_time=dt.time(19, 0)
    )
    await grant(session, viewer, child, "viewer")
    await make_device(session, viewer)
    await session.commit()

    run, _push = await _run(session, at=_utc(DAY, dt.time(19, 30), DETROIT))

    assert run.sent == 1
    assert run.skipped_no_child == 1
    sends = await _sends(session)
    assert [row.user_id for row in sends] == [parent.id]
