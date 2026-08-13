"""The Today screen, assembled in one query.

"Today" is the date in the child's `family_timezone`, computed here and never by a client.
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import false, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.models import Assignment, Child, Entry
from rascal.schemas.today import AssignmentOut
from rascal.services.dates import zone


def to_assignment_out(assignment: Assignment) -> AssignmentOut:
    """Requires `prompt` to be eagerly loaded."""
    prompt = assignment.prompt
    custom = assignment.custom_body is not None
    return AssignmentOut(
        id=assignment.id,
        slot=assignment.slot,
        # A parent-authored one-off wins over the prompt it replaced.
        body=assignment.custom_body if custom else (prompt.body if prompt else ""),
        # A custom body has no library prompt behind it, so it is described by its slot:
        # the question slot is a question, every other slot is something you go and do.
        kind=prompt.kind
        if prompt
        else ("question" if assignment.slot == "question" else "activity"),
        completion_mode=prompt.completion_mode if prompt else "text",
        theme=prompt.theme if prompt else None,
        status=assignment.status,
        assigned_on=assignment.assigned_on,
        expires_on=assignment.expires_on,
        prompt_id=assignment.prompt_id,
        is_custom=custom,
        unlock_at_age=prompt.default_unlock_age if prompt else None,
    )


async def assignments_for(
    session: AsyncSession, child: Child, today: dt.date
) -> tuple[list[Assignment], list[Assignment], list[Assignment]]:
    """`today`, `waiting`, and `done_today` in one pass over the child's open work."""
    # done_today is anything completed with occurred_at today — in the child's timezone, so an
    # entry logged at 11pm in Auckland does not land on yesterday's screen. The window is
    # resolved to two UTC instants here and compared against the bare column, because
    # `date(timezone(zone, occurred_at)) = today` cannot use ix_entries_child_id_occurred_at
    # and makes every Today load convert every entry the child has ever written.
    #
    # The end of the day is one day added to the aware local midnight, which is wall-clock
    # arithmetic: a spring-forward day stays 23 hours and a fall-back day stays 25, so neither
    # loses an hour of completions nor borrows one from tomorrow.
    local_midnight = dt.datetime.combine(today, dt.time.min, tzinfo=zone(child.family_timezone))
    day_start = local_midnight.astimezone(dt.UTC)
    day_end = (local_midnight + dt.timedelta(days=1)).astimezone(dt.UTC)
    completed_today = set(
        (
            await session.execute(
                select(Entry.assignment_id).where(
                    Entry.child_id == child.id,
                    Entry.assignment_id.is_not(None),
                    Entry.deleted_at.is_(None),
                    Entry.occurred_at >= day_start,
                    Entry.occurred_at < day_end,
                )
            )
        )
        .scalars()
        .all()
    )

    # Only two kinds of row can reach the screen: something still pending, and something
    # finished today. Bound the read to exactly that — `assigned_on <= today` on its own is
    # "every assignment this child has ever had", hydrated with its prompt and then thrown
    # away by the loop below, so the hottest screen in the app would get slower every day the
    # archive exists. The pending leg reads ix_assignments_child_id_status_assigned_on.
    rows = (
        (
            await session.execute(
                select(Assignment)
                .where(
                    Assignment.child_id == child.id,
                    Assignment.assigned_on <= today,
                    or_(
                        Assignment.status == "pending",
                        Assignment.id.in_(completed_today) if completed_today else false(),
                    ),
                )
                .options(selectinload(Assignment.prompt))
                .order_by(Assignment.assigned_on.asc(), Assignment.slot.asc())
            )
        )
        .scalars()
        .all()
    )

    today_items: list[Assignment] = []
    waiting: list[Assignment] = []
    done_today: list[Assignment] = []

    for assignment in rows:
        if assignment.status == "done" and assignment.id in completed_today:
            done_today.append(assignment)
        elif assignment.status != "pending":
            continue  # dismissed and expired items are off the screen entirely
        elif assignment.assigned_on == today:
            today_items.append(assignment)
        else:
            # Items stack. Backlog is fine; infinite backlog is guilt, which is what the
            # 14-day expiry is for.
            waiting.append(assignment)

    return today_items, waiting, done_today
