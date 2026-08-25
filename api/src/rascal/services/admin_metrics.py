"""The numbers behind the admin console.

**The rule this module is written to, and the only one that matters: counts, never content.**

Nothing here selects `entries.title`, `entries.body`, `media.caption`, `media.transcript`, a
child's name, or an `s3_key`. Not because the owner is untrusted — he is the only admin — but
because a browser console that can page through a family's archive is a different product
with a different threat model, and the cheapest time to decide it will never exist is before
the first query is written. Aggregates answer every question this screen is for: how many
households, how much is stored, whether the scheduler ran. None of them need a sentence a
parent wrote about their kid.

`GET /v1/admin/*` is the only caller. Every function takes an open session and issues a fixed
number of statements — no per-row fan-out, no lazy loads on the async session.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Any

from sqlalchemy import Date, Integer, Text, and_, cast, func, or_, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import DAILY_SLOTS
from rascal.models import (
    Assignment,
    Child,
    DeletionRequest,
    Device,
    EmailBroadcast,
    Entitlement,
    EntitlementGrant,
    Entry,
    Family,
    Media,
    NotificationSend,
    Prompt,
    PromptLibraryOverride,
    User,
)
from rascal.services.grants import has_active_grant, unexpired
from rascal.services.guardians import access_for


def _utc_now() -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC)


async def _scalar(session: AsyncSession, statement: Any) -> int:
    return int(await session.scalar(statement) or 0)


async def _counts_by(session: AsyncSession, column: Any, *where: Any) -> dict[str, int]:
    """`{value: count}` for one grouped column, in one statement."""
    rows = await session.execute(
        select(column, func.count()).where(*where).group_by(column).order_by(column)
    )
    return {str(value): int(count) for value, count in rows.all()}


async def overview(session: AsyncSession) -> dict[str, Any]:
    """One snapshot of the business. Roughly a dozen statements, none of them per-row."""
    now = _utc_now()
    week = now - dt.timedelta(days=7)
    month = now - dt.timedelta(days=30)

    live_entry = Entry.deleted_at.is_(None)
    live_media = Media.deleted_at.is_(None)

    users_total = await _scalar(session, select(func.count()).select_from(User))
    users_week = await _scalar(
        session, select(func.count()).select_from(User).where(User.created_at >= week)
    )
    users_month = await _scalar(
        session, select(func.count()).select_from(User).where(User.created_at >= month)
    )
    # "Signed in recently" is the only retention number this schema can answer honestly:
    # `users.last_sign_in_at` is the column D3 computes deletion eligibility from, and it is
    # null for anyone who predates it. Null is reported as unknown rather than as "long ago"
    # — treating it as ancient would make the oldest accounts look like the coldest.
    users_seen_week = await _scalar(
        session,
        select(func.count()).select_from(User).where(User.last_sign_in_at >= week),
    )
    users_never_seen = await _scalar(
        session,
        select(func.count()).select_from(User).where(User.last_sign_in_at.is_(None)),
    )

    families_total = await _scalar(session, select(func.count()).select_from(Family))
    tiers = await _counts_by(session, Entitlement.tier)

    children_total = await _scalar(session, select(func.count()).select_from(Child))

    entries_total = await _scalar(
        session, select(func.count()).select_from(Entry).where(live_entry)
    )
    entries_week = await _scalar(
        session,
        select(func.count()).select_from(Entry).where(live_entry, Entry.created_at >= week),
    )
    entries_month = await _scalar(
        session,
        select(func.count()).select_from(Entry).where(live_entry, Entry.created_at >= month),
    )
    entries_deleted = await _scalar(
        session, select(func.count()).select_from(Entry).where(Entry.deleted_at.is_not(None))
    )
    entry_types = await _counts_by(session, Entry.entry_type, live_entry)
    # Backdating is a first-class flow, so how much of it happens is worth watching. A day of
    # slack rather than a strict inequality: an entry written at 00:30 about this evening is
    # not a backfill, and counting it as one would make the number meaningless.
    entries_backdated = await _scalar(
        session,
        select(func.count())
        .select_from(Entry)
        .where(live_entry, Entry.occurred_at < Entry.created_at - dt.timedelta(days=1)),
    )

    media_total = await _scalar(session, select(func.count()).select_from(Media).where(live_media))
    media_bytes = int(
        await session.scalar(
            select(func.coalesce(func.sum(Media.bytes), 0)).where(
                live_media, Media.upload_status == "complete"
            )
        )
        or 0
    )
    media_kinds = await _counts_by(session, Media.kind, live_media)
    media_pending = await _scalar(
        session,
        select(func.count())
        .select_from(Media)
        .where(live_media, Media.upload_status != "complete"),
    )

    devices_active = await _scalar(
        session, select(func.count()).select_from(Device).where(Device.revoked_at.is_(None))
    )
    device_envs = await _counts_by(session, Device.environment, Device.revoked_at.is_(None))

    prompts_total = await _scalar(session, select(func.count()).select_from(Prompt))
    prompts_active = await _scalar(
        session, select(func.count()).select_from(Prompt).where(Prompt.active.is_(True))
    )
    prompt_kinds = await _counts_by(session, Prompt.kind, Prompt.active.is_(True))
    overrides = await _scalar(session, select(func.count()).select_from(PromptLibraryOverride))

    # Completion rate is the product's own vital sign: a prompt served and never answered is
    # the failure the whole thing is judged on. Counted over 30 days of *expired-or-resolved*
    # assignments so today's still-pending items do not drag it down.
    assignment_states = await _counts_by(
        session, Assignment.status, Assignment.assigned_on >= month.date()
    )
    resolved = sum(assignment_states.get(k, 0) for k in ("done", "dismissed", "expired"))
    done = assignment_states.get("done", 0)

    deletions_pending = await _scalar(
        session,
        select(func.count())
        .select_from(DeletionRequest)
        .where(DeletionRequest.cancelled_at.is_(None)),
    )

    return {
        "as_of": now.isoformat(),
        "users": {
            "total": users_total,
            "new_7d": users_week,
            "new_30d": users_month,
            "signed_in_7d": users_seen_week,
            "never_signed_in": users_never_seen,
        },
        "households": {"total": families_total, "by_tier": tiers},
        "children": {"total": children_total},
        "entries": {
            "total": entries_total,
            "new_7d": entries_week,
            "new_30d": entries_month,
            "deleted": entries_deleted,
            "backdated": entries_backdated,
            "by_type": entry_types,
        },
        "media": {
            "total": media_total,
            "bytes": media_bytes,
            "pending_upload": media_pending,
            "by_kind": media_kinds,
        },
        "devices": {"active": devices_active, "by_environment": device_envs},
        "library": {
            "total": prompts_total,
            "active": prompts_active,
            "by_kind": prompt_kinds,
            "overrides": overrides,
        },
        "assignments": {
            "by_status_30d": assignment_states,
            "completion_rate_30d": round(done / resolved, 4) if resolved else None,
            "resolved_30d": resolved,
        },
        "deletions": {"pending": deletions_pending},
    }


async def growth(session: AsyncSession, days: int) -> dict[str, Any]:
    """Daily counts for the last `days`, gap-filled so the chart has no holes.

    Gap-filling happens here rather than in the browser because a missing day and a zero day
    are different facts and only the server knows which is which — a chart that silently
    closes the gap draws a straight line through an outage.
    """
    today = _utc_now().date()
    start = today - dt.timedelta(days=days - 1)
    span = [start + dt.timedelta(days=offset) for offset in range(days)]

    async def by_day(column: Any, model: Any, *where: Any, value: Any = None) -> dict[dt.date, int]:
        bucket = cast(column, Date).label("day")
        measure = func.count() if value is None else func.coalesce(func.sum(value), 0)
        rows = await session.execute(
            select(bucket, measure)
            .select_from(model)
            .where(column >= start, *where)
            .group_by(bucket)
        )
        return {row[0]: int(row[1]) for row in rows.all()}

    new_users = await by_day(User.created_at, User)
    new_entries = await by_day(Entry.created_at, Entry, Entry.deleted_at.is_(None))
    new_bytes = await by_day(Media.created_at, Media, Media.deleted_at.is_(None), value=Media.bytes)

    # An "active household" is one where somebody wrote something that day. Resolved through
    # the author's family rather than the child's, because `families` deliberately does not
    # own children — `guardians` is the only ownership edge and a child can be shared.
    bucket = cast(Entry.created_at, Date).label("day")
    rows = await session.execute(
        select(bucket, func.count(func.distinct(User.family_id)))
        .select_from(Entry)
        .join(User, User.id == Entry.author_id)
        .where(Entry.created_at >= start, Entry.deleted_at.is_(None))
        .group_by(bucket)
    )
    active_households = {row[0]: int(row[1]) for row in rows.all()}

    return {
        "from": start.isoformat(),
        "to": today.isoformat(),
        "days": [
            {
                "day": day.isoformat(),
                "new_users": new_users.get(day, 0),
                "new_entries": new_entries.get(day, 0),
                "new_bytes": new_bytes.get(day, 0),
                "active_households": active_households.get(day, 0),
            }
            for day in span
        ],
    }


async def scheduler_health(session: AsyncSession, days: int = 14) -> dict[str, Any]:
    """Did the daily job actually run, and did every slot get filled?

    **This is the panel `roadmap-status.md` asks for in so many words.** Phase 19 shipped the
    photo-only `mission` slot and it served nothing for weeks: the deploy was green, `/health`
    was green, the tests were green, and the only instrument that could have seen it was
    reading the rows. *"Verify a scheduled job by reading what it produced, not by reading the
    deploy that was supposed to update it."* This reads what it produced.

    A daily slot with a zero here is the shape of the defect — not proof of one, because a day
    with no guardians has nothing to serve either, but it is the number to look at first.
    """
    today = _utc_now().date()
    start = today - dt.timedelta(days=days - 1)

    rows = await session.execute(
        select(Assignment.slot, Assignment.assigned_on, func.count())
        .where(Assignment.assigned_on >= start)
        .group_by(Assignment.slot, Assignment.assigned_on)
        .order_by(Assignment.assigned_on)
    )
    grid: dict[str, dict[str, int]] = {}
    for slot, day, count in rows.all():
        grid.setdefault(str(slot), {})[day.isoformat()] = int(count)

    span = [(start + dt.timedelta(days=offset)).isoformat() for offset in range(days)]
    slots = [
        {
            "slot": slot,
            "daily": slot in DAILY_SLOTS,
            "total": sum(grid.get(slot, {}).values()),
            "days": [grid.get(slot, {}).get(day, 0) for day in span],
            # A daily slot that served nothing across the whole window is the finding; a
            # weekly or monthly one legitimately reads zero on most days.
            "silent": slot in DAILY_SLOTS and not sum(grid.get(slot, {}).values()),
        }
        for slot in sorted(set(grid) | set(DAILY_SLOTS))
    ]

    last_run = await session.scalar(select(func.max(Assignment.created_at)))
    return {
        "span": span,
        "slots": slots,
        "last_assignment_at": last_run.isoformat() if last_run else None,
    }


async def ops(session: AsyncSession) -> dict[str, Any]:
    """Job ledgers and queues. Everything a scheduled machine leaves behind."""
    now = _utc_now()
    week = now - dt.timedelta(days=7)

    migration = await session.scalar(text("SELECT version_num FROM alembic_version LIMIT 1"))

    broadcasts = (
        await session.execute(
            select(
                EmailBroadcast.send_date,
                EmailBroadcast.subject,
                EmailBroadcast.status,
                EmailBroadcast.error,
            )
            .order_by(EmailBroadcast.send_date.desc())
            .limit(10)
        )
    ).all()

    sends_week = await _scalar(
        session,
        select(func.count())
        .select_from(NotificationSend)
        .where(NotificationSend.created_at >= week),
    )
    delivered_week = int(
        await session.scalar(
            select(func.coalesce(func.sum(cast(NotificationSend.delivered_count, Integer)), 0))
            .select_from(NotificationSend)
            .where(NotificationSend.created_at >= week)
        )
        or 0
    )

    # The deletion queue, identified by request id and clock only. Naming the account here
    # would put a person who asked to be forgotten on a dashboard, which is the one place the
    # request is least defensible.
    due = (
        await session.execute(
            select(DeletionRequest.id, DeletionRequest.requested_at, DeletionRequest.execute_after)
            .where(DeletionRequest.cancelled_at.is_(None))
            .order_by(DeletionRequest.execute_after)
            .limit(20)
        )
    ).all()

    return {
        "migration": migration,
        "broadcasts": [
            {
                "send_date": row.send_date.isoformat(),
                "subject": row.subject,
                "status": row.status,
                "error": row.error,
            }
            for row in broadcasts
        ],
        "notifications": {"sends_7d": sends_week, "delivered_7d": delivered_week},
        "deletion_queue": [
            {
                "id": str(row.id),
                "requested_at": row.requested_at.isoformat(),
                "execute_after": row.execute_after.isoformat(),
                "overdue": row.execute_after < now,
            }
            for row in due
        ],
    }


async def library_rows(
    session: AsyncSession,
    *,
    kind: str | None,
    cadence: str | None,
    theme: str | None,
    source: str | None,
    active: bool | None,
    search: str | None,
    limit: int,
    offset: int,
) -> dict[str, Any]:
    """The library, with the two things the public list does not carry.

    **Usage**, so a prompt can be judged rather than guessed at: how many times it has been
    served and how many of those turned into a finished entry. A body that goes out fifty
    times and is answered twice is the editing signal this console exists for.

    **Override state**, so it is visible on the row whether a decision here will survive the
    next deploy — the whole reason `prompt_library_overrides` exists.
    """
    clauses = []
    if kind:
        clauses.append(Prompt.kind == kind)
    if cadence:
        clauses.append(Prompt.cadence == cadence)
    if theme:
        clauses.append(Prompt.theme == theme)
    if source:
        clauses.append(Prompt.source == source)
    if active is not None:
        clauses.append(Prompt.active.is_(active))
    if search:
        clauses.append(Prompt.body.ilike(f"%{search}%"))

    total = await _scalar(session, select(func.count()).select_from(Prompt).where(*clauses))

    served = (
        select(Assignment.prompt_id, func.count().label("served"))
        .group_by(Assignment.prompt_id)
        .subquery()
    )
    completed = (
        select(Assignment.prompt_id, func.count().label("completed"))
        .where(Assignment.status == "done")
        .group_by(Assignment.prompt_id)
        .subquery()
    )

    rows = (
        await session.execute(
            select(
                Prompt,
                func.coalesce(served.c.served, 0),
                func.coalesce(completed.c.completed, 0),
                PromptLibraryOverride.active,
                PromptLibraryOverride.note,
            )
            .outerjoin(served, served.c.prompt_id == Prompt.id)
            .outerjoin(completed, completed.c.prompt_id == Prompt.id)
            .outerjoin(
                PromptLibraryOverride,
                PromptLibraryOverride.content_hash == Prompt.content_hash,
            )
            .where(*clauses)
            .order_by(Prompt.active.desc(), Prompt.kind, Prompt.body)
            .limit(limit)
            .offset(offset)
        )
    ).all()

    themes = sorted(
        str(value)
        for value in (await session.execute(select(Prompt.theme).distinct())).scalars().all()
    )

    return {
        "total": total,
        "themes": themes,
        "prompts": [
            {
                "id": str(prompt.id),
                "kind": prompt.kind,
                "cadence": prompt.cadence,
                "completion_mode": prompt.completion_mode,
                "body": prompt.body,
                "theme": prompt.theme,
                "min_age_months": prompt.min_age_months,
                "max_age_months": prompt.max_age_months,
                "month_tags": prompt.month_tags,
                "source": prompt.source,
                "default_unlock_age": prompt.default_unlock_age,
                "active": prompt.active,
                "content_hash": prompt.content_hash,
                "served": int(served_count),
                "completed": int(completed_count),
                "override": None
                if override_active is None
                else {"active": bool(override_active), "note": override_note},
                "updated_at": prompt.updated_at.isoformat(),
            }
            for prompt, served_count, completed_count, override_active, override_note in rows
        ],
    }


async def top_themes(session: AsyncSession, limit: int = 8) -> list[dict[str, Any]]:
    """Which themes the archive is actually made of, by finished assignment.

    Joined through `assignments` rather than read off entries, because an entry knows what it
    contains and only the assignment knows what was *asked*. Freeform entries have no theme
    and correctly do not appear.
    """
    rows = await session.execute(
        select(Prompt.theme, func.count())
        .select_from(Assignment)
        .join(Prompt, Prompt.id == Assignment.prompt_id)
        .where(Assignment.status == "done")
        .group_by(Prompt.theme)
        .order_by(func.count().desc())
        .limit(limit)
    )
    return [{"theme": str(theme), "count": int(count)} for theme, count in rows.all()]


def _access_state(
    tier: str, trial_ends_at: dt.datetime | None, now: dt.datetime, *, granted: bool
) -> str:
    """`access_for` over two loose columns rather than a mapped row.

    **Not a second formula, and it must never become one.** `recent_signups` aggregates, so it
    groups — which means it selects the two entitlement *columns* it needs rather than the
    entity, since selecting the entity would mean grouping by its primary key as well. There is
    therefore no ORM object to hand to :func:`services.guardians.access_for`, so a throwaway
    unmapped instance is built for the one call and the formula stays in the one place allowed
    to know it. `services/scheduler.py::_active_parents` does select the entity, because it does
    not aggregate; both reach the same function, which is the point.

    `test_entitlement_cadence.py` walks the AST of every module under `src/` looking for anyone
    who compares `trial_ends_at` against a clock instead of doing this, and asserts that every
    call site of `access_for` — this one included — supplies `granted`.
    """
    return access_for(
        Entitlement(tier=tier, trial_ends_at=trial_ends_at), granted=granted, now=now
    ).access


async def recent_signups(session: AsyncSession, limit: int = 12) -> list[dict[str, Any]]:
    """Who arrived lately — enough to recognise an account, and nothing about their archive.

    The email is here because a support conversation starts with one and the owner is the
    only reader. Nothing about the child, and no entry content: a customer list is a
    different thing from an archive, and this screen only gets to be the first one.
    """
    # Read once, before the query, and used by both the grant predicate in SQL and the access
    # computation below it. Two `now()`s here would be two clocks, and a household whose grant
    # expires between them would read `granted` in one half and not the other.
    now = dt.datetime.now(tz=dt.UTC)
    rows = await session.execute(
        select(
            User.id,
            User.email,
            User.display_name,
            User.created_at,
            User.last_sign_in_at,
            User.family_id,
            Entitlement.tier,
            Entitlement.trial_ends_at,
            # Phase 121. A correlated `EXISTS` rather than a join, so a household holding three
            # grants is still one row here and the `count(distinct entries)` above is unharmed.
            has_active_grant(User.family_id, now).label("granted"),
            func.count(func.distinct(Entry.id)).label("entries"),
        )
        .outerjoin(Entitlement, Entitlement.family_id == User.family_id)
        .outerjoin(Entry, and_(Entry.author_id == User.id, Entry.deleted_at.is_(None)))
        .group_by(User.id, Entitlement.tier, Entitlement.trial_ends_at)
        .order_by(User.created_at.desc())
        .limit(limit)
    )
    return [
        {
            "id": str(row.id),
            "email": row.email,
            "display_name": row.display_name,
            "created_at": row.created_at.isoformat(),
            "last_sign_in_at": row.last_sign_in_at.isoformat() if row.last_sign_in_at else None,
            # **`family_id`, `access` and `trial_ends_at` are here so the console's one
            # entitlement lever has something to aim at.** A control that sets a household's
            # trial needs the household's id, and asking the owner to find a UUID by hand is
            # a control nobody uses. None of the three is archive content.
            "family_id": str(row.family_id),
            # **`or "free"` covers the outer join finding no entitlement row at all**, not a
            # null column — `tier` is NOT NULL with a `free` server default, so within a row
            # that exists it is never null. A user with no entitlement row is unreachable
            # (`create_household` writes one with every family, and `users.family_id` is
            # `ON DELETE RESTRICT`, so a family with members cannot be deleted out from under
            # them), and `free` is what the schema would have written anyway.
            #
            # **`services/scheduler.py::_serve` treats the same anomaly as *entitled* and the
            # difference is deliberate.** The scheduler has to choose a behaviour and chooses
            # the one that cannot cost a paying family their board; a console has no such
            # obligation and should not invent a state — it reports the columns as they are.
            "tier": row.tier or "free",
            # Computed by the one authority rather than restated here — a console that
            # disagreed with `GET /today` about whether somebody is entitled would be worse
            # than a console with no column at all.
            "access": _access_state(
                row.tier or "free", row.trial_ends_at, now, granted=bool(row.granted)
            ),
            # **A grant is why a `free` household can read `subscribed` on this screen.** The
            # column beside it still says `free`, which is the point: `tier` is Apple's word and
            # `access` is what the phone will actually be served.
            "granted": bool(row.granted),
            "trial_ends_at": row.trial_ends_at.isoformat() if row.trial_ends_at else None,
            "entries": int(row.entries),
        }
        for row in rows.all()
    ]


# --- Households, for the console's grant panel -------------------------------------------------
#
# **Account metadata and nothing else, and that line is the whole design of this section.** A
# grant is issued *to a household*, so the console has to be able to find one — which means a
# search box over the only strings a person actually has: an email, a display name, a family id
# off another screen. It does not mean opening the household. Nothing below reads `children`,
# `entries`, `media`, `assignments` or `tags`, and `tests/test_admin.py` plants distinctive
# strings in all of those and greps every admin response for them.


def _like_escape(term: str) -> str:
    """Neutralise `LIKE`'s own wildcards inside a term a person typed.

    **`_` is the one that actually bites**, because it is common in an email local part:
    searching `first_last` would otherwise also match `firstXlast`, and in a picker where the
    next click *grants* the selected household, an extra match is a wrong household one keystroke
    away. `%` is the loud version of the same bug — a bare `%` matches everything — and the
    backslash goes first or it would escape the escapes.
    """
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _label(members: list[tuple[str | None, str | None]]) -> str:
    """How a household reads in a picker: its members, oldest first, name before email.

    **Both, when both exist**, because either alone is ambiguous in practice — two dev-login
    fixtures share a display name, and an email with no name attached is unrecognisable at a
    glance six months after the conversation that produced it.
    """
    seen: list[str] = []
    for display_name, email in members:
        for value in (display_name, email):
            if value and value not in seen:
                seen.append(value)
    return " · ".join(seen) if seen else "unnamed household"


async def household_labels(
    session: AsyncSession, family_ids: list[uuid.UUID]
) -> dict[uuid.UUID, str]:
    """One label per household, for a set of ids. **One query, never one per row.**

    The ledger renders a household beside every row, and a lookup per row is the shape that
    reads fine at four rows and is a page of queries at forty.
    """
    if not family_ids:
        return {}
    rows = await session.execute(
        select(User.family_id, User.display_name, User.email)
        .where(User.family_id.in_(family_ids))
        .order_by(User.created_at, User.id)
    )
    grouped: dict[uuid.UUID, list[tuple[str | None, str | None]]] = {}
    for family_id, display_name, email in rows.all():
        grouped.setdefault(family_id, []).append((display_name, email))
    return {family_id: _label(members) for family_id, members in grouped.items()}


async def find_households(
    session: AsyncSession, *, q: str | None = None, limit: int = 20
) -> list[dict[str, Any]]:
    """Households matching *q* on **account metadata only** — email, display name, family id.

    **An empty query is the most recent households rather than an error**, because that is what
    the picker wants on first paint, and asking somebody to type before they can see anything is
    a control nobody uses. Whitespace-only is empty for the same reason: a `q` of `"  "` filtering
    on `%  %` would silently return only the households with two spaces in a name.

    The family id is matched as text so a UUID pasted from another screen finds its household,
    and a *prefix* works because that is what the rest of the console renders — `fillHouseholds`
    shows eight characters, and a search that could not find what the screen displays would be a
    search you have to work around.

    `access` and `entitlement_source` come from the one authority, not from a comparison written
    here: a console that disagreed with `GET /today` about whether somebody is entitled would be
    worse than a console with no column at all.
    """
    now = dt.datetime.now(tz=dt.UTC)

    families = select(User.family_id, func.max(User.created_at)).group_by(User.family_id)
    term = (q or "").strip()
    if term:
        pattern = f"%{_like_escape(term)}%"
        families = families.where(
            or_(
                User.email.ilike(pattern, escape="\\"),
                User.display_name.ilike(pattern, escape="\\"),
                cast(User.family_id, Text).ilike(pattern, escape="\\"),
            )
        )
    # Newest household first, and `family_id` breaks the tie so two households whose newest
    # member arrived in the same transaction do not swap places between two identical searches.
    families = families.order_by(func.max(User.created_at).desc(), User.family_id.desc())
    family_ids = [row.family_id for row in (await session.execute(families.limit(limit))).all()]
    if not family_ids:
        return []

    labels = await household_labels(session, family_ids)

    entitlements = {
        row.family_id: row
        for row in (
            await session.execute(select(Entitlement).where(Entitlement.family_id.in_(family_ids)))
        ).scalars()
    }
    # Two aggregates in one pass: how many rows the household holds at all, and whether any of
    # them is live. `unexpired` is the one definition of the second — this counts it, it does
    # not restate it.
    rows = (
        await session.execute(
            select(
                EntitlementGrant.family_id,
                func.count().label("total"),
                func.count().filter(unexpired(now)).label("live"),
            )
            .where(EntitlementGrant.family_id.in_(family_ids))
            .group_by(EntitlementGrant.family_id)
        )
    ).all()
    counted = {row.family_id: (int(row.total), int(row.live)) for row in rows}

    out: list[dict[str, Any]] = []
    for family_id in family_ids:
        total, live = counted.get(family_id, (0, 0))
        # **A household with no entitlement row is unreachable and is still not invented here.**
        # `create_household` writes one with every family; a throwaway `free` row keeps the one
        # authority the only thing computing an answer, exactly as `_access_state` does above.
        entitlement = entitlements.get(family_id) or Entitlement(family_id=family_id, tier="free")
        access = access_for(entitlement, granted=live > 0, now=now)
        out.append(
            {
                "family_id": family_id,
                "label": labels.get(family_id, "unnamed household"),
                "tier": entitlement.tier,
                "access": access.access,
                "entitlement_source": access.source,
                "grants": total,
            }
        )
    return out
