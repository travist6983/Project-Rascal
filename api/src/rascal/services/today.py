"""The Today screen, assembled in one query.

"Today" is the date in the child's `family_timezone`, computed here and never by a client.
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from rascal.models import Assignment, Child, Entry
from rascal.schemas.today import AssignmentOut


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
    rows = (
        (
            await session.execute(
                select(Assignment)
                .where(Assignment.child_id == child.id, Assignment.assigned_on <= today)
                .options(selectinload(Assignment.prompt))
                .order_by(Assignment.assigned_on.asc(), Assignment.slot.asc())
            )
        )
        .scalars()
        .all()
    )

    # done_today is anything completed with occurred_at today — in the child's timezone,
    # so an entry logged at 11pm in Auckland does not land on yesterday's screen.
    local_day = func.date(func.timezone(child.family_timezone, Entry.occurred_at))
    completed_today = set(
        (
            await session.execute(
                select(Entry.assignment_id).where(
                    Entry.child_id == child.id,
                    Entry.assignment_id.is_not(None),
                    Entry.deleted_at.is_(None),
                    local_day == today,
                )
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
