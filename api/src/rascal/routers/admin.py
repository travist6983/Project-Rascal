"""The admin console's read surface.

Every route here is `AdminUser`, which is `users.is_admin` — the same gate the mission
library has used since `0003`, reused rather than reinvented. There is no second permission
model and no admin session cookie: the console is a page that holds a bearer token and calls
this API like any other client, which is why `docs/api-contract.md` can document it as JSON
and a browser can consume it in 2027.

**Counts, never content.** `services/admin_metrics.py` carries the reasoning; the short
version is that nothing in this router can return a sentence a parent wrote, a child's name,
a caption, a transcript, or an object key. If a future route here needs one of those, that is
a product decision to take deliberately, not a field to quietly add.

~~**One route here writes, and it is deliberately the only one.**~~ — **struck by phase 121, which
added two more.** The writes here are `PUT /admin/families/{family_id}/trial` (phase 107, moves a
household's `trial_ends_at`) and `POST /admin/grants` / `POST /admin/grants/{id}/revoke` (phase
121, the complimentary-entitlement ledger). All three go through `SessionDep` and `LocalWrites`
exactly as the library edits in `routers/prompts.py` do, so all three refuse while the console is
pointed at a read-only production database.

**None of them can write `tier`, and that has not changed at all.** D5 reserves that column for
App Store Server Notifications V2, `tests/test_app_store.py::test_tier_has_exactly_one_writer`
asserts there is exactly one assignment to it under `src/`, and phase 121 did not touch it. A
grant is a *second, additive source of entitlement* computed beside `tier` in
`services/guardians.access_for` — **`tier` still means what Apple said**, and the union is what
every gate reads.

The console's own HTML is served by `routers/admin_ui.py`, which shares nothing with this
module but the URL prefix.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from fastapi import APIRouter, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.deps import AdminReadSession, AdminUser, LocalWrites, SessionDep, SettingsDep
from rascal.models import EntitlementGrant, User
from rascal.schemas.admin import (
    AdminCosts,
    AdminGrantIn,
    AdminGrantList,
    AdminGrantOut,
    AdminHousehold,
    AdminHouseholdList,
    AdminOps,
    AdminSnapshot,
    AdminTrialIn,
    AdminTrialOut,
)
from rascal.services import admin_metrics, billing, grants, readonly_db
from rascal.services.grants import active_grant_for
from rascal.services.guardians import access_for, set_trial_ends_at

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get(
    "/snapshot",
    response_model=AdminSnapshot,
    summary="Everything the console's first screen needs",
    description=(
        "One request rather than four, because the four are always wanted together and a "
        "dashboard that paints in four waves reads as broken. Counts and aggregates only — "
        "no archive content is reachable through any admin route."
    ),
)
async def snapshot(
    session: AdminReadSession,
    user: AdminUser,
    days: Annotated[int, Query(ge=7, le=365)] = 60,
) -> AdminSnapshot:
    return AdminSnapshot(
        overview=await admin_metrics.overview(session),
        growth=await admin_metrics.growth(session, days),
        themes=await admin_metrics.top_themes(session),
        signups=await admin_metrics.recent_signups(session),
    )


@router.put(
    "/families/{family_id}/trial",
    response_model=AdminTrialOut,
    summary="Move or clear a household's trial — the console's one entitlement lever",
    description=(
        "Sets `entitlements.trial_ends_at`. A date in the future makes the household "
        "`trial`; a date in the past or `null` makes it `free`. **It cannot write `tier` and "
        "there is deliberately no control that can** — D5 reserves that column for App Store "
        "Server Notifications V2 and a test asserts it has exactly one writer, so a console "
        "button that set it would be a person disagreeing with Apple.\n\n"
        "It exists because the owner is the only user and would otherwise never see the free "
        "tier he is designing: set it to yesterday to drop to `free`, to next month to come "
        "back. **The one household affected is the one named in the path** — this reaches no "
        "other family and reads no archive content.\n\n"
        "**It cannot move a household that is already entitled some other way, and that is "
        "the one case worth knowing about.** `subscribed` beats `trial` and so does an active "
        'grant, so such a household reads `access: "subscribed"` whatever this route writes. '
        "The date is still stored — it matters the day the subscription lapses or the grant "
        "runs out — but the access state does not move, and `entitlement_source` on the "
        "response says which of the two is holding it rather than implying success.\n\n"
        "**The owner's own household is one of these**: `runbook-deploy.md` §7a wrote "
        "`tier = 'subscribed'` by hand and there is no App Store transaction behind it. "
        "To see the free tier from there, set `tier` back to `free` with the statement in "
        "§7a first, then use this."
    ),
)
async def set_family_trial(
    family_id: uuid.UUID,
    payload: AdminTrialIn,
    session: SessionDep,
    user: AdminUser,
    _: LocalWrites,
) -> AdminTrialOut:
    entitlement = await set_trial_ends_at(session, family_id, payload.trial_ends_at)
    # Rendered through the one authority rather than re-derived, so the console cannot show a
    # different answer from the one the phone will get on its next `GET /today`.
    #
    # **The grant is read here for the same reason `tier` is reported.** A complimentary
    # household reads `subscribed` whatever this writes, exactly as a subscribed one does — and
    # a response that said only "access is subscribed" would send the operator to
    # `runbook-deploy.md` §7a to fix a tier that was never the reason. `entitlement_source` is
    # what tells those two apart, and the console's message reads it.
    grant = await active_grant_for(session, family_id)
    access = access_for(entitlement, granted=grant is not None)
    return AdminTrialOut(
        family_id=family_id,
        tier=entitlement.tier,
        access=access.access,
        trial_ends_at=access.trial_ends_at,
        entitlement_source=access.source,
    )


@router.get(
    "/households",
    response_model=AdminHouseholdList,
    summary="Find a household by email, display name, or family id",
    description=(
        "**Account metadata only.** Email, display name, family id, the entitlement state and "
        "how many grants the household holds. Nothing here reads a child, an entry, a caption, "
        "a transcript or an object key, and `tests/test_admin.py` plants distinctive strings in "
        "all of those and greps this response for them.\n\n"
        "An empty `q` returns the most recent households, because that is what a picker wants "
        "on first paint. The family id matches as text, so a UUID pasted from another screen "
        "finds its household and so does the eight-character prefix the console renders."
    ),
)
async def households(
    session: AdminReadSession,
    user: AdminUser,
    q: Annotated[str | None, Query(max_length=200)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> AdminHouseholdList:
    rows = await admin_metrics.find_households(session, q=q, limit=limit)
    return AdminHouseholdList(households=[AdminHousehold(**row) for row in rows])


@router.get(
    "/grants",
    response_model=AdminGrantList,
    summary="The complimentary-entitlement ledger, newest first",
    description=(
        "Every row, including revoked and expired ones — **a ledger that hides what was "
        "withdrawn is not a ledger.** `status` is `active` | `expired` | `revoked`, computed "
        "from the row and the server's clock, and `revoked` outranks `expired` because it is "
        "the thing somebody did.\n\n"
        "`?family_id=` narrows it to one household. `granted_by` is a display name or email, "
        "and is `null` when that account has since been deleted — account deletion "
        "hard-deletes `users` and this column is `ON DELETE SET NULL`."
    ),
)
async def list_grants(
    session: AdminReadSession,
    user: AdminUser,
    family_id: uuid.UUID | None = None,
) -> AdminGrantList:
    rows = await grants.grants_for(session, family_id=family_id)
    return AdminGrantList(grants=await _render_grants(session, rows))


@router.post(
    "/grants",
    response_model=AdminGrantOut,
    status_code=status.HTTP_201_CREATED,
    summary="Entitle a household by decision rather than by payment",
    description=(
        "Writes one row to `entitlement_grants`. `expires_at` is **nullable and null means "
        "perpetual** — not a sentinel date; `reason` is required and free text.\n\n"
        "**`granted_by` is the bearer token's subject and there is no field for it.** A body "
        "carrying one is ignored rather than honoured, and a test asserts that: an audit column "
        "a caller can set says whatever the caller wanted it to.\n\n"
        "**It cannot write `tier` and neither can anything else in this console.** D5 reserves "
        "that column for App Store Server Notifications V2 and a test asserts it has exactly "
        'one writer. A grant does not touch it — the household still reads `tier: "free"` and '
        "now also reads `entitled: true`, and both are true sentences. `422` on an empty reason "
        "or an expiry already in the past, which would be a row that entitles nobody."
    ),
)
async def create_grant(
    payload: AdminGrantIn,
    session: SessionDep,
    user: AdminUser,
    _: LocalWrites,
) -> AdminGrantOut:
    grant = await grants.issue_grant(
        session,
        family_id=payload.family_id,
        # **From the token, never from the body.** `AdminGrantIn` has no field for this and the
        # argument is passed here rather than being defaulted inside the service, so the one
        # place it can come from is the one place that has authenticated somebody.
        granted_by=user.id,
        reason=payload.reason,
        expires_at=payload.expires_at,
    )
    return (await _render_grants(session, [grant]))[0]


@router.post(
    "/grants/{grant_id}/revoke",
    response_model=AdminGrantOut,
    summary="Withdraw a grant. Idempotent, and there is no DELETE",
    description=(
        "Sets `revoked_at` and `revoked_by`. **Revoking an already-revoked grant succeeds and "
        "writes nothing** — a console click that times out and gets clicked again must not be "
        "an error.\n\n"
        "**There is deliberately no `DELETE`.** Soft deletes on everything is a standing rule "
        "and this is the table where it matters most: the record of who you gave something to, "
        "why, and when you took it back is the part a support conversation needs.\n\n"
        "It takes effect on the next read, which is immediate everywhere it matters — every "
        "entitlement surface computes the answer per request, so there is no cached boolean to "
        "invalidate and no job to wait for."
    ),
)
async def revoke_grant(
    grant_id: uuid.UUID,
    session: SessionDep,
    user: AdminUser,
    _: LocalWrites,
) -> AdminGrantOut:
    grant = await grants.revoke_grant(session, grant_id, revoked_by=user.id)
    return (await _render_grants(session, [grant]))[0]


async def _render_grants(
    session: AsyncSession, rows: list[EntitlementGrant]
) -> list[AdminGrantOut]:
    """Ledger rows plus the two names a person needs to read them, in **two** queries.

    One for the households, one for the issuers, however many rows there are. A lookup per row is
    the shape that reads fine at four grants and is a page of queries at forty.

    **`AsyncSession`, not `SessionDep`.** This is a plain helper, not a route: annotating it with
    the `Annotated[..., Depends(...)]` alias would say FastAPI injects it, which it does not — and
    the two callers hand it two *different* sessions (`AdminReadSession` for the list,
    `SessionDep` for the writes), which is exactly what the alias would misdescribe.

    **Account metadata and nothing else**, which is what keeps this router's standing rule
    ("counts, never content") true of the newest surface in it: the household is its members'
    names and emails, and the issuer is one name. No child, no entry, no object key.

    **`null` means the account is gone, and only that.** A live admin who has neither a display
    name nor an email — reachable, both columns are nullable — falls back to the short form of
    their user id rather than to `null`. Rendering them as `null` would put *"account deleted"* on
    the console beside a person who is sitting right there, which is the confident-wrong-answer
    failure this file keeps having to design against.
    """
    if not rows:
        return []
    now = dt.datetime.now(tz=dt.UTC)
    labels = await admin_metrics.household_labels(session, [row.family_id for row in rows])
    actors = {row.granted_by for row in rows if row.granted_by} | {
        row.revoked_by for row in rows if row.revoked_by
    }
    people: dict[uuid.UUID, str] = {}
    if actors:
        people = {
            actor: display_name or email or str(actor)[:8]
            for actor, display_name, email in (
                await session.execute(
                    select(User.id, User.display_name, User.email).where(User.id.in_(actors))
                )
            ).all()
        }
    return [
        AdminGrantOut(
            id=row.id,
            family_id=row.family_id,
            household=labels.get(row.family_id, "unnamed household"),
            reason=row.reason,
            granted_at=row.granted_at,
            expires_at=row.expires_at,
            revoked_at=row.revoked_at,
            status=row.status(now),
            granted_by=people.get(row.granted_by) if row.granted_by else None,
            revoked_by=people.get(row.revoked_by) if row.revoked_by else None,
        )
        for row in rows
    ]


@router.get(
    "/library",
    summary="The mission library, with usage and override state",
    description=(
        "Richer than `GET /prompts`: every row carries how often it has been served, how "
        "often that turned into a finished entry, its `content_hash`, and whether a "
        "`prompt_library_overrides` row is holding its `active` against the seed file."
    ),
)
async def library(
    session: AdminReadSession,
    user: AdminUser,
    kind: str | None = None,
    cadence: str | None = None,
    theme: str | None = None,
    source: str | None = None,
    active: bool | None = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 200,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> dict[str, object]:
    return await admin_metrics.library_rows(
        session,
        kind=kind,
        cadence=cadence,
        theme=theme,
        source=source,
        active=active,
        search=q,
        limit=limit,
        offset=offset,
    )


@router.get(
    "/ops",
    response_model=AdminOps,
    summary="Configuration, the scheduler's output, and the job ledgers",
    description=(
        "The scheduler block reads what the daily job **produced**, not whether its deploy "
        "was green. That distinction is the whole finding of PR #57: the photo slot served "
        "nothing for weeks while every other instrument in the project reported success."
    ),
)
async def ops(session: AdminReadSession, user: AdminUser, settings: SettingsDep) -> AdminOps:
    return AdminOps(
        environment=settings.environment,
        database=_database(settings),
        flags=_flags(settings),
        scheduler=await admin_metrics.scheduler_health(session),
        jobs=await admin_metrics.ops(session),
    )


@router.get(
    "/costs",
    response_model=AdminCosts,
    summary="What the vendors are charging, as far as they will say",
    description=(
        "Seven providers, fetched concurrently and cached briefly. Anthropic and GitHub "
        "publish real cost APIs; Tigris and Apple carry a figure only because a price setting "
        "names one; Fly, Neon and Resend expose no spend at all, so the total covers what is "
        "knowable and names the providers outside it."
    ),
)
async def costs(user: AdminUser, settings: SettingsDep, refresh: bool = False) -> AdminCosts:
    if refresh:
        billing.clear_cache()
    reports = await billing.collect(settings)
    known = sum(r.amount_cents or 0 for r in reports if r.amount_cents is not None)
    return AdminCosts(
        providers=[report.as_dict() for report in reports],
        total_known_cents=known,
        providers_without_pricing=[
            report.label
            for report in reports
            if report.status == "ok" and report.amount_cents is None
        ],
    )


def _database(settings: Settings) -> dict[str, object]:
    """Which database the numbers on screen came from.

    Reported on every load rather than only when it is unusual. A console that names its source
    only in the surprising case is a console you have to remember to distrust — and the whole
    reason this block exists is that six rows of local fixtures are indistinguishable from six
    real customers until somebody says which they are.
    """
    if not settings.admin_read_database_url:
        return {
            "reading": "local",
            "host": readonly_db.describe(settings.database_url),
            "read_only": False,
            "note": "Reading the database this process writes to.",
        }
    return {
        "reading": "remote",
        "host": readonly_db.describe(settings.admin_read_database_url),
        "read_only": True,
        "note": "Reading ADMIN_READ_DATABASE_URL over a connection Postgres refuses writes "
        "on. Library and Studio edits are disabled while this is set — they would save to "
        "your local database while showing you this one.",
    }


def _flags(settings: Settings) -> list[dict[str, object]]:
    """The switches that decide whether a subsystem does anything, and what each one gates.

    Written out rather than dumped from `Settings` for two reasons. A dump would put secrets
    on a web page. And a boolean with no sentence beside it is unreadable six months later —
    `marketing_email_enabled: false` looks like a bug until you know what it gates. The
    sentence is the useful half — and it has to be maintained: this one described open item
    12's hard gate for three days after the owner lifted it on Aug 22, 2026, which is worse
    than no sentence, because an operator reads it as current.
    """
    return [
        {
            "key": "MARKETING_EMAIL_ENABLED",
            "on": settings.marketing_email_enabled,
            "means": "Off, the daily broadcast renders and logs but never calls Resend. "
            "On, it sends once a day at the configured hour. The P0 behavioural gate that "
            "used to forbid this was lifted by the owner on Aug 22, 2026.",
            "tone": "warn" if settings.marketing_email_enabled else "ok",
        },
        {
            "key": "MAIL_PROVIDER",
            "on": settings.mail_provider != "console",
            "value": settings.mail_provider,
            "means": "`console` writes mail to stdout and never opens a socket, so a local "
            "run cannot mail a real parent.",
            "tone": "plain",
        },
        {
            "key": "APNS",
            "on": settings.apns_configured,
            "means": "All three of key id, team id and private key, or push sends nothing "
            "and says so loudly.",
            "tone": "ok" if settings.apns_configured else "warn",
        },
        {
            "key": "TURNSTILE_SECRET_KEY",
            "on": settings.turnstile_secret_key is not None,
            "means": "Unset means POST /v1/subscribe refuses. It is the entire protection "
            "on that route — there is deliberately no rate limit there.",
            "tone": "ok" if settings.turnstile_secret_key else "warn",
        },
        {
            "key": "RESEND_AUDIENCE_ID",
            "on": settings.resend_audience_id is not None,
            "means": "Where a subscriber actually lives. There is no `subscribers` table.",
            "tone": "ok" if settings.resend_audience_id else "warn",
        },
        {
            "key": "GOOGLE_CLIENT_IDS",
            "on": settings.google_configured,
            "means": "Empty means POST /auth/google refuses by naming the setting rather "
            "than rejecting every token for no stated reason.",
            "tone": "plain",
        },
        {
            "key": "S3_ENDPOINT_URL",
            "on": settings.s3_endpoint_url is not None,
            "value": settings.s3_endpoint_url or "(real AWS)",
            "means": "Which object store the presigned URLs point at.",
            "tone": "plain",
        },
        {
            "key": "MARKETING_ORIGINS",
            "on": bool(settings.marketing_origins),
            "value": ", ".join(settings.marketing_origins) or "(none)",
            "means": "Browser origins allowed to call the subscribe route. Never `*`.",
            "tone": "plain",
        },
    ]
