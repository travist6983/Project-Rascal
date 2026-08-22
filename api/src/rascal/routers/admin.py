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

**One route here writes, and it is deliberately the only one.** `PUT
/admin/families/{family_id}/trial` moves a household's `trial_ends_at`, per phase 107. It goes
through `SessionDep` and `LocalWrites` exactly as the library edits in `routers/prompts.py`
do, so it refuses while the console is pointed at a read-only production database. **It cannot
write `tier`** — see the route.

The console's own HTML is served by `routers/admin_ui.py`, which shares nothing with this
module but the URL prefix.
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query

from rascal.config import Settings
from rascal.deps import AdminReadSession, AdminUser, LocalWrites, SessionDep, SettingsDep
from rascal.schemas.admin import (
    AdminCosts,
    AdminOps,
    AdminSnapshot,
    AdminTrialIn,
    AdminTrialOut,
)
from rascal.services import admin_metrics, billing, readonly_db
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
        "**It cannot move a household whose `tier` is already `subscribed`, and that is "
        "the one case worth knowing about.** `subscribed` beats `trial`, so such a "
        'household reads `access: "subscribed"` whatever this route writes. The date is '
        "still stored — it matters the day the subscription lapses — but the access state "
        "does not move, and the response says so rather than implying success.\n\n"
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
    access = access_for(entitlement)
    return AdminTrialOut(
        family_id=family_id,
        tier=entitlement.tier,
        access=access.access,
        trial_ends_at=access.trial_ends_at,
    )


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
