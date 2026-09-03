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
    AppStoreTransaction,
    Assignment,
    Child,
    DeletionRequest,
    Device,
    EmailBroadcast,
    Entitlement,
    EntitlementGrant,
    Entry,
    Family,
    Guardian,
    GuardianInvite,
    Media,
    NotificationSend,
    Prompt,
    PromptLibraryOverride,
    User,
)
from rascal.services.dates import age_in_months
from rascal.services.grants import active_grant_for, has_active_grant, unexpired
from rascal.services.guardians import access_for
from rascal.services.membership import BILLING_RETRY_NOTIFICATION, BILLING_RETRY_SUBTYPE
from rascal.services.scheduler import COOLDOWN_DAYS, RELAXED_COOLDOWN_DAYS, SLOT_SPECS, _eligible


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
    """One snapshot of the business. Eleven statements, none of them per-row.

    **One pass per table, with `FILTER` doing the counting** (phase 142). This was twenty-six
    separately awaited statements — six full scans of `entries` alone, four of `media` — on one
    session, which is one connection, so none of them overlapped and every one paid the
    replica's round trip, plus its cold start on the first open after Neon's idle timer. The
    docstring above it said "roughly a dozen". A count that needs a table read once should read
    it once; every number below is the same number it was, from one statement per table.
    """
    now = _utc_now()
    week = now - dt.timedelta(days=7)
    month = now - dt.timedelta(days=30)

    live_entry = Entry.deleted_at.is_(None)
    live_media = Media.deleted_at.is_(None)

    # "Signed in recently" is the only retention number this schema can answer honestly:
    # `users.last_sign_in_at` is the column D3 computes deletion eligibility from, and it is
    # null for anyone who predates it. Null is reported as unknown rather than as "long ago"
    # — treating it as ancient would make the oldest accounts look like the coldest.
    users = (
        await session.execute(
            select(
                func.count().label("total"),
                func.count().filter(User.created_at >= week).label("week"),
                func.count().filter(User.created_at >= month).label("month"),
                func.count().filter(User.last_sign_in_at >= week).label("seen_week"),
                func.count().filter(User.last_sign_in_at.is_(None)).label("never_seen"),
            ).select_from(User)
        )
    ).one()

    # Four tables whose only question is "how many rows": one round trip, four scalar
    # subqueries, rather than four awaits for four integers.
    small = (
        await session.execute(
            select(
                select(func.count()).select_from(Family).scalar_subquery().label("families"),
                select(func.count()).select_from(Child).scalar_subquery().label("children"),
                select(func.count())
                .select_from(PromptLibraryOverride)
                .scalar_subquery()
                .label("overrides"),
                select(func.count())
                .select_from(DeletionRequest)
                .where(DeletionRequest.cancelled_at.is_(None))
                .scalar_subquery()
                .label("deletions"),
            )
        )
    ).one()
    tiers = await _counts_by(session, Entitlement.tier)

    # Backdating is a first-class flow, so how much of it happens is worth watching. A day of
    # slack rather than a strict inequality: an entry written at 00:30 about this evening is
    # not a backfill, and counting it as one would make the number meaningless. It compares two
    # columns, so no index can serve it — which is exactly why it rides the one pass over
    # `entries` that the other four counts already needed.
    entries = (
        await session.execute(
            select(
                func.count().filter(live_entry).label("total"),
                func.count().filter(live_entry, Entry.created_at >= week).label("week"),
                func.count().filter(live_entry, Entry.created_at >= month).label("month"),
                func.count().filter(Entry.deleted_at.is_not(None)).label("deleted"),
                func.count()
                .filter(live_entry, Entry.occurred_at < Entry.created_at - dt.timedelta(days=1))
                .label("backdated"),
            ).select_from(Entry)
        )
    ).one()
    entry_types = await _counts_by(session, Entry.entry_type, live_entry)

    media = (
        await session.execute(
            select(
                func.count().filter(live_media).label("total"),
                func.coalesce(
                    func.sum(Media.bytes).filter(live_media, Media.upload_status == "complete"),
                    0,
                ).label("bytes"),
                func.count().filter(live_media, Media.upload_status != "complete").label("pending"),
            ).select_from(Media)
        )
    ).one()
    media_kinds = await _counts_by(session, Media.kind, live_media)

    device_envs = await _counts_by(session, Device.environment, Device.revoked_at.is_(None))

    prompts = (
        await session.execute(
            select(
                func.count().label("total"),
                func.count().filter(Prompt.active.is_(True)).label("active"),
            ).select_from(Prompt)
        )
    ).one()
    prompt_kinds = await _counts_by(session, Prompt.kind, Prompt.active.is_(True))

    # Completion rate is the product's own vital sign: a prompt served and never answered is
    # the failure the whole thing is judged on. Counted over 30 days of *expired-or-resolved*
    # assignments so today's still-pending items do not drag it down.
    assignment_states = await _counts_by(
        session, Assignment.status, Assignment.assigned_on >= month.date()
    )
    resolved = sum(assignment_states.get(k, 0) for k in ("done", "dismissed", "expired"))
    done = assignment_states.get("done", 0)

    return {
        "as_of": now.isoformat(),
        "users": {
            "total": int(users.total),
            "new_7d": int(users.week),
            "new_30d": int(users.month),
            "signed_in_7d": int(users.seen_week),
            "never_signed_in": int(users.never_seen),
        },
        "households": {"total": int(small.families), "by_tier": tiers},
        "children": {"total": int(small.children)},
        "entries": {
            "total": int(entries.total),
            "new_7d": int(entries.week),
            "new_30d": int(entries.month),
            "deleted": int(entries.deleted),
            "backdated": int(entries.backdated),
            "by_type": entry_types,
        },
        "media": {
            "total": int(media.total),
            "bytes": int(media.bytes),
            "pending_upload": int(media.pending),
            "by_kind": media_kinds,
        },
        "devices": {"active": sum(device_envs.values()), "by_environment": device_envs},
        "library": {
            "total": int(prompts.total),
            "active": int(prompts.active),
            "by_kind": prompt_kinds,
            "overrides": int(small.overrides),
        },
        "assignments": {
            "by_status_30d": assignment_states,
            "completion_rate_30d": round(done / resolved, 4) if resolved else None,
            "resolved_30d": resolved,
        },
        "deletions": {"pending": int(small.deletions)},
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

    # **The page first, then the usage of exactly that page** (phase 142). This used to
    # materialise two aggregates over the whole `assignments` table — one for served, one for
    # done — on every Library open and again on every Studio open, unconstrained by the
    # filters or the page, so the work grew with every row the scheduler ever wrote while the
    # screen still showed two hundred prompts. One `FILTER` aggregate over the page's ids is an
    # index lookup on `ix_assignments_prompt_id`, and it stays that size.
    order = (Prompt.active.desc(), Prompt.kind, Prompt.body)
    page = select(Prompt.id).where(*clauses).order_by(*order).limit(limit).offset(offset).subquery()
    usage = (
        select(
            Assignment.prompt_id,
            func.count().label("served"),
            func.count().filter(Assignment.status == "done").label("completed"),
        )
        .where(Assignment.prompt_id.in_(select(page.c.id)))
        .group_by(Assignment.prompt_id)
        .subquery()
    )

    rows = (
        await session.execute(
            select(
                Prompt,
                func.coalesce(usage.c.served, 0),
                func.coalesce(usage.c.completed, 0),
                PromptLibraryOverride.active,
                PromptLibraryOverride.note,
            )
            .join(page, page.c.id == Prompt.id)
            .outerjoin(usage, usage.c.prompt_id == Prompt.id)
            .outerjoin(
                PromptLibraryOverride,
                PromptLibraryOverride.content_hash == Prompt.content_hash,
            )
            .order_by(*order)
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
    # **The twelve accounts first, then their entries** (phase 142). A `LIMIT` after a
    # `GROUP BY` bounds the output, not the work: the previous shape outer-joined every live
    # entry in the archive to every account and counted before it could take the top twelve,
    # which at hundreds of households is a full scan and a hash join to draw a dozen rows.
    # Bounding the accounts first turns the count into a lookup on `ix_entries_author_id`.
    newest = (
        select(User.id.label("user_id"))
        .order_by(User.created_at.desc(), User.id.desc())
        .limit(limit)
        .subquery()
    )
    counts = (
        select(Entry.author_id, func.count().label("entries"))
        .where(Entry.author_id.in_(select(newest.c.user_id)), Entry.deleted_at.is_(None))
        .group_by(Entry.author_id)
        .subquery()
    )
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
            has_active_grant(User.family_id, now).label("granted"),
            func.coalesce(counts.c.entries, 0).label("entries"),
        )
        .join(newest, newest.c.user_id == User.id)
        .outerjoin(Entitlement, Entitlement.family_id == User.family_id)
        .outerjoin(counts, counts.c.author_id == User.id)
        .order_by(User.created_at.desc(), User.id.desc())
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
# off another screen. It does not mean opening the household. Nothing in *this section* reads
# `children`, `entries`, `media`, `assignments` or `tags`; `household_detail`, further down, reads
# those tables as counts and dates and never as content, and `tests/test_admin.py` plants
# distinctive strings in all of them and greps every admin response for them.


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


# --- One household, in full and in metadata ----------------------------------------------------


def _age_label(months: int) -> str:
    years, rest = divmod(max(months, 0), 12)
    return f"{years}y {rest}m"


def _week_start(day: dt.date) -> dt.date:
    """Monday, to match Postgres's `date_trunc('week', …)`."""
    return day - dt.timedelta(days=day.weekday())


async def household_detail(
    session: AsyncSession, family_id: uuid.UUID, *, weeks: int = 12
) -> dict[str, Any] | None:
    """Everything the console may know about one household, and nothing it may not.

    **The line is the same as the rest of this module's: shape, never content.** How many
    entries, of which kinds, written in which weeks; how many bytes; whether the uploads
    finished; how the household answers its prompts; whether a notification reached a device.
    No entry title or body, no caption, no transcript, no object key — and **no child's name**:
    a child is an age and a timezone here, because the support conversation this screen exists
    for needs "a four-year-old" and never needs the name.

    Sixteen statements for a household with a child and ten for one without, none per row, and
    every one bounded by the household: this is the console's deepest read and it must stay
    flat as archives grow.
    `None` when no account belongs to the household, which is what a deleted account leaves
    behind and what a mistyped id looks like; the route turns that into a 404.
    """
    now = _utc_now()
    today = now.date()
    month_ago = now - dt.timedelta(days=30)
    fortnight_ago = today - dt.timedelta(days=14)

    members = (
        await session.execute(
            select(
                User.id,
                User.display_name,
                User.email,
                User.created_at,
                User.last_sign_in_at,
                User.notify_enabled,
                User.is_admin,
            )
            .where(User.family_id == family_id)
            .order_by(User.created_at, User.id)
        )
    ).all()
    if not members:
        return None
    member_ids = [row.id for row in members]

    entitlement = await session.get(Entitlement, family_id)
    grant = await active_grant_for(session, family_id, now=now)
    access = access_for(entitlement, granted=grant is not None, now=now) if entitlement else None
    grant_counts = (
        await session.execute(
            select(
                func.count().label("total"),
                func.count().filter(unexpired(now)).label("live"),
            ).where(EntitlementGrant.family_id == family_id)
        )
    ).one()

    children = (
        await session.execute(
            select(Child.id, Child.birthdate, Child.family_timezone, Child.created_at)
            .join(Guardian, Guardian.child_id == Child.id)
            .where(Guardian.user_id.in_(member_ids), Guardian.revoked_at.is_(None))
            .distinct()
            .order_by(Child.birthdate)
        )
    ).all()
    child_ids = [row.id for row in children]

    # Every archive statement below is bounded by the household's children. A household with
    # no child has no archive, and asking the database about an empty `IN ()` is a wasted
    # round trip — so the empty case is answered here.
    if child_ids:
        live_entry = and_(Entry.child_id.in_(child_ids), Entry.deleted_at.is_(None))
        entries = (
            await session.execute(
                select(
                    func.count().label("total"),
                    func.count().filter(Entry.created_at >= month_ago).label("month"),
                    func.count()
                    .filter(Entry.occurred_at < Entry.created_at - dt.timedelta(days=1))
                    .label("backdated"),
                    func.min(Entry.occurred_at).label("first"),
                    func.max(Entry.occurred_at).label("last"),
                    func.max(Entry.created_at).label("last_written"),
                ).where(live_entry)
            )
        ).one()
        entry_types = await _counts_by(session, Entry.entry_type, live_entry)

        window_start = _week_start(today) - dt.timedelta(weeks=weeks - 1)
        bucket = cast(func.date_trunc("week", Entry.created_at), Date)
        weekly = {
            row[0]: int(row[1])
            for row in (
                await session.execute(
                    select(bucket, func.count())
                    .where(live_entry, Entry.created_at >= window_start)
                    .group_by(bucket)
                )
            ).all()
        }

        live_media = and_(Media.deleted_at.is_(None), Entry.deleted_at.is_(None))
        media = (
            await session.execute(
                select(
                    func.count().label("total"),
                    func.coalesce(
                        func.sum(Media.bytes).filter(Media.upload_status == "complete"), 0
                    ).label("bytes"),
                    func.count().filter(Media.upload_status != "complete").label("pending"),
                )
                .select_from(Media)
                .join(Entry, Entry.id == Media.entry_id)
                .where(live_media, Entry.child_id.in_(child_ids))
            )
        ).one()
        media_kinds = {
            str(kind): int(count)
            for kind, count in (
                await session.execute(
                    select(Media.kind, func.count())
                    .select_from(Media)
                    .join(Entry, Entry.id == Media.entry_id)
                    .where(live_media, Entry.child_id.in_(child_ids))
                    .group_by(Media.kind)
                    .order_by(Media.kind)
                )
            ).all()
        }
        assignment_states = await _counts_by(
            session,
            Assignment.status,
            Assignment.child_id.in_(child_ids),
            Assignment.assigned_on >= month_ago.date(),
        )
    else:
        entries = None
        entry_types = {}
        weekly = {}
        media = None
        media_kinds = {}
        assignment_states = {}

    device_envs = await _counts_by(
        session, Device.environment, Device.user_id.in_(member_ids), Device.revoked_at.is_(None)
    )
    notifications = (
        await session.execute(
            select(
                func.count().label("sends"),
                func.count().filter(NotificationSend.delivered_count > 0).label("delivered"),
                func.max(NotificationSend.notification_date).label("last"),
            ).where(
                NotificationSend.user_id.in_(member_ids),
                NotificationSend.notification_date >= fortnight_ago,
            )
        )
    ).one()
    invites_pending = await _scalar(
        session,
        select(func.count())
        .select_from(GuardianInvite)
        .where(
            GuardianInvite.family_id == family_id,
            GuardianInvite.accepted_at.is_(None),
            GuardianInvite.revoked_at.is_(None),
            GuardianInvite.expires_at > now,
        ),
    )
    deletion = (
        await session.execute(
            select(DeletionRequest.execute_after)
            .where(
                DeletionRequest.user_id.in_(member_ids),
                DeletionRequest.cancelled_at.is_(None),
            )
            .order_by(DeletionRequest.execute_after)
            .limit(1)
        )
    ).first()
    receipt = (
        await session.execute(
            select(AppStoreTransaction)
            .where(AppStoreTransaction.family_id == family_id)
            .order_by(AppStoreTransaction.latest_signed_date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    resolved = sum(assignment_states.get(k, 0) for k in ("done", "dismissed", "expired"))
    done = assignment_states.get("done", 0)
    span = [_week_start(today) - dt.timedelta(weeks=weeks - 1 - i) for i in range(weeks)]
    seen = [row.last_sign_in_at for row in members if row.last_sign_in_at]

    return {
        "household": {
            "family_id": str(family_id),
            "label": _label([(row.display_name, row.email) for row in members]),
            "joined_at": min(row.created_at for row in members).isoformat(),
            "last_sign_in_at": max(seen).isoformat() if seen else None,
        },
        "members": [
            {
                "id": str(row.id),
                "display_name": row.display_name,
                "email": row.email,
                "joined_at": row.created_at.isoformat(),
                "last_sign_in_at": row.last_sign_in_at.isoformat() if row.last_sign_in_at else None,
                "notify_enabled": bool(row.notify_enabled),
                "is_admin": bool(row.is_admin),
            }
            for row in members
        ],
        "children": {
            "total": len(children),
            "ages": [
                {
                    "age": _age_label(age_in_months(row.birthdate, today)),
                    "age_months": age_in_months(row.birthdate, today),
                    "timezone": row.family_timezone,
                    "added_at": row.created_at.isoformat(),
                }
                for row in children
            ],
        },
        "archive": {
            "entries": int(entries.total) if entries else 0,
            "entries_30d": int(entries.month) if entries else 0,
            "backdated": int(entries.backdated) if entries else 0,
            "by_type": entry_types,
            "first_moment_at": entries.first.isoformat() if entries and entries.first else None,
            "last_moment_at": entries.last.isoformat() if entries and entries.last else None,
            "last_written_at": entries.last_written.isoformat()
            if entries and entries.last_written
            else None,
            "weeks": [{"week": day.isoformat(), "entries": weekly.get(day, 0)} for day in span],
            "media": int(media.total) if media else 0,
            "bytes": int(media.bytes) if media else 0,
            "pending_upload": int(media.pending) if media else 0,
            "media_by_kind": media_kinds,
        },
        "prompts": {
            "by_status_30d": assignment_states,
            "resolved_30d": resolved,
            "completion_rate_30d": round(done / resolved, 4) if resolved else None,
        },
        "reach": {
            "devices": sum(device_envs.values()),
            "devices_by_environment": device_envs,
            "notify_enabled": sum(1 for row in members if row.notify_enabled),
            "notification_sends_14d": int(notifications.sends),
            "notification_delivered_14d": int(notifications.delivered),
            "last_notification_on": notifications.last.isoformat() if notifications.last else None,
            "invites_pending": invites_pending,
            "deletion_execute_after": deletion[0].isoformat() if deletion else None,
        },
        "billing": {
            "tier": entitlement.tier if entitlement else "free",
            "access": access.access if access else "free",
            "entitlement_source": access.source if access else "none",
            "entitled": bool(access.entitled) if access else False,
            "trial_ends_at": access.trial_ends_at.isoformat()
            if access and access.trial_ends_at
            else None,
            "lapsed_at": entitlement.lapsed_at.isoformat()
            if entitlement and entitlement.lapsed_at
            else None,
            "grants_live": int(grant_counts.live),
            "grants_total": int(grant_counts.total),
            "grant_expires_at": grant.expires_at.isoformat()
            if grant and grant.expires_at
            else None,
            "receipt": None
            if receipt is None
            else {
                "product_id": receipt.product_id,
                "environment": receipt.environment,
                "type": receipt.latest_notification_type,
                "subtype": receipt.latest_notification_subtype,
                "signed_at": receipt.latest_signed_date.isoformat(),
                "expires_at": receipt.expires_date.isoformat() if receipt.expires_date else None,
                "billing_retry": receipt.latest_notification_type == BILLING_RETRY_NOTIFICATION
                and receipt.latest_notification_subtype == BILLING_RETRY_SUBTYPE,
            },
        },
    }


# --- The subscription ledger ---------------------------------------------------------------------


async def subscriptions(
    session: AsyncSession, *, days: int = 30, limit: int = 20
) -> dict[str, Any]:
    """What Apple has told this service, as a ledger the owner can read at a glance.

    `app_store_transactions` is written by one caller — the notification webhook, plus the
    receipt a phone submits since phase 140 — and until phase 142 the console showed none of
    it: the Membership card had a trial lever and a grants ledger and nothing about the
    subscriptions the product is for. Nine statements when any recent transaction is attributed
    — eight aggregates and one label lookup for the recent rows — and none per row. **The
    ledger's household column is a label, never a receipt's raw payload**, and an unattributed
    transaction — the shape the phase 139 story turned on — is named as such rather than dropped.

    **The trial counts ask `access_for`, they do not restate it.** Exactly one comparison
    against `trial_ends_at` may exist in `src/` and it is `services/guardians.access_for`
    (`tests/test_entitlement_cadence.py` walks the AST to make sure). So every household's
    entitlement row is read — one row per household, which is the number this dashboard is
    about — and handed to the one authority twice: once with today's clock and once with a
    clock a week ahead. A household on trial today and not on trial then is a trial ending
    within the week, decided by the same formula the app is served by.
    """
    now = _utc_now()
    since = now - dt.timedelta(days=days)
    week_ahead = now + dt.timedelta(days=7)

    by_type = await _counts_by(
        session,
        AppStoreTransaction.latest_notification_type,
        AppStoreTransaction.latest_signed_date >= since,
    )
    by_environment = await _counts_by(session, AppStoreTransaction.environment)
    active_by_product = {
        str(product or "unknown"): int(count)
        for product, count in (
            await session.execute(
                select(
                    AppStoreTransaction.product_id,
                    # Households, not rows: Guard 2 keeps one row per (household, environment),
                    # so a household holding a Sandbox and a Production receipt for the same
                    # product is one subscriber here, not two.
                    func.count(func.distinct(AppStoreTransaction.family_id)),
                )
                .join(Entitlement, Entitlement.family_id == AppStoreTransaction.family_id)
                .where(
                    Entitlement.tier == "subscribed",
                    or_(
                        AppStoreTransaction.expires_date.is_(None),
                        AppStoreTransaction.expires_date > now,
                    ),
                )
                .group_by(AppStoreTransaction.product_id)
                .order_by(AppStoreTransaction.product_id)
            )
        ).all()
    }
    ledger = (
        await session.execute(
            select(
                func.count().label("total"),
                func.count().filter(AppStoreTransaction.family_id.is_(None)).label("unattributed"),
                func.count()
                .filter(
                    AppStoreTransaction.latest_notification_type == BILLING_RETRY_NOTIFICATION,
                    AppStoreTransaction.latest_notification_subtype == BILLING_RETRY_SUBTYPE,
                )
                .label("billing_retry"),
                func.count()
                .filter(
                    AppStoreTransaction.expires_date > now,
                    AppStoreTransaction.expires_date <= week_ahead,
                )
                .label("expiring_7d"),
            ).select_from(AppStoreTransaction)
        )
    ).one()
    granted = set(
        (
            await session.execute(
                select(EntitlementGrant.family_id).where(unexpired(now)).distinct()
            )
        ).scalars()
    )
    entitlements = list((await session.execute(select(Entitlement))).scalars())
    today_access = {
        row.family_id: access_for(row, granted=row.family_id in granted, now=now)
        for row in entitlements
    }
    later_access = {
        row.family_id: access_for(row, granted=row.family_id in granted, now=week_ahead)
        for row in entitlements
    }
    on_trial = sum(1 for access in today_access.values() if access.access == "trial")
    trials_ending_7d = sum(
        1
        for family_id, access in today_access.items()
        if access.access == "trial" and later_access[family_id].access != "trial"
    )
    subscribed = sum(1 for row in entitlements if row.tier == "subscribed")
    lapsed = sum(1 for row in entitlements if row.lapsed_at is not None)
    grants_live = await _scalar(
        session, select(func.count()).select_from(EntitlementGrant).where(unexpired(now))
    )

    recent = list(
        (
            await session.execute(
                select(AppStoreTransaction)
                .order_by(AppStoreTransaction.latest_signed_date.desc())
                .limit(limit)
            )
        ).scalars()
    )
    labels = await household_labels(
        session, list({row.family_id for row in recent if row.family_id is not None})
    )

    return {
        "as_of": now.isoformat(),
        "days": days,
        "summary": {
            "subscribed_households": subscribed,
            "on_trial": on_trial,
            "trials_ending_7d": trials_ending_7d,
            "lapsed": lapsed,
            "grants_live": grants_live,
            "transactions": int(ledger.total),
            "unattributed": int(ledger.unattributed),
            "billing_retry": int(ledger.billing_retry),
            "expiring_7d": int(ledger.expiring_7d),
        },
        "by_type": by_type,
        "by_environment": by_environment,
        "active_by_product": active_by_product,
        "recent": [
            {
                "transaction": f"…{row.original_transaction_id[-6:]}",
                "household": labels.get(row.family_id) if row.family_id else None,
                "family_id": str(row.family_id) if row.family_id else None,
                "product_id": row.product_id,
                "environment": row.environment,
                "type": row.latest_notification_type,
                "subtype": row.latest_notification_subtype,
                "signed_at": row.latest_signed_date.isoformat(),
                "expires_at": row.expires_date.isoformat() if row.expires_date else None,
            }
            for row in recent
        ],
    }


# --- Where the library is thin --------------------------------------------------------------------


#: Age bands a parent would recognise, in months. Wide where childhood is wide and narrow where
#: a year changes everything: the first three years get a band each, the rest are grouped.
AGE_BANDS: tuple[tuple[str, int, int], ...] = (
    ("0-1", 0, 11),
    ("1-2", 12, 23),
    ("2-3", 24, 35),
    ("3-5", 36, 59),
    ("5-8", 60, 95),
    ("8-12", 96, 143),
    ("12-18", 144, 215),
)

#: How many days of serving one eligible prompt covers, by cadence. A daily slot spends a
#: prompt a day; a weekly one a prompt a week. The cooldown then decides when a spent prompt
#: may come back, so `eligible times days` is how long a child in that band can go before the
#: scheduler has to relax something.
_DAYS_PER_PROMPT: dict[str, int] = {"daily": 1, "weekly": 7, "monthly": 30}


async def library_coverage(session: AsyncSession, *, as_of: dt.date) -> dict[str, Any]:
    """For every slot and every age band: how many active prompts a child there could be served.

    **The scheduler's own eligibility rule, evaluated at every month of the band**, so the
    number reported is the *thinnest* month — a band whose three-year-olds have forty prompts
    and whose four-year-olds have six is a six, because a child does not skip the thin month.
    The calendar month is today's, because `month_tags` make December a different library from
    July, and the console should show the library as it is being served rather than as it might
    be in six months.

    One statement: the active library, read once. Everything else is arithmetic over it, and
    the arithmetic is `services/scheduler.py`'s, imported rather than restated, so this cannot
    drift from what the scheduler actually does.

    `days` is how long a child in that band can be served from the pool before a prompt has to
    repeat, at the slot's cadence; `thin` is that number falling under the *relaxed* cooldown
    — the point at which the scheduler is already bending its own rules to fill the slot.
    """
    prompts = list((await session.execute(select(Prompt).where(Prompt.active.is_(True)))).scalars())
    month = as_of.month
    slots: list[dict[str, Any]] = []
    for slot, spec in SLOT_SPECS.items():
        pool = [
            prompt
            for prompt in prompts
            if prompt.cadence == spec.cadence and (spec.kinds is None or prompt.kind in spec.kinds)
        ]
        per_prompt = _DAYS_PER_PROMPT[spec.cadence]
        cells = []
        for band, low, high in AGE_BANDS:
            counts = [
                sum(1 for prompt in pool if _eligible(prompt, age, month))
                for age in range(low, high + 1)
            ]
            thinnest = min(counts)
            days = thinnest * per_prompt
            cells.append(
                {
                    "band": band,
                    "eligible": thinnest,
                    "eligible_max": max(counts),
                    "days": days,
                    "thin": days < RELAXED_COOLDOWN_DAYS,
                }
            )
        slots.append(
            {
                "slot": slot,
                "cadence": spec.cadence,
                "kinds": list(spec.kinds) if spec.kinds is not None else None,
                "pool": len(pool),
                "cells": cells,
            }
        )
    return {
        "as_of": as_of.isoformat(),
        "month": month,
        "active_prompts": len(prompts),
        "cooldown_days": COOLDOWN_DAYS,
        "relaxed_cooldown_days": RELAXED_COOLDOWN_DAYS,
        "bands": [band for band, _, _ in AGE_BANDS],
        "slots": slots,
    }
