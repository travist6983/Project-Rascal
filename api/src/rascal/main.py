"""The FastAPI application."""

from __future__ import annotations

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings, get_settings
from rascal.db import get_session
from rascal.errors import ErrorCode, RascalError, register_error_handlers
from rascal.logging_config import configure_logging
from rascal.routers import (
    admin,
    admin_ui,
    auth,
    children,
    debug,
    devices,
    entries,
    export,
    families,
    me,
    media,
    moments,
    prompts,
    social,
    subscribe,
    sync,
    today,
    webhooks,
    wellknown,
)

# docs/api-contract.md: everything lives under /v1 except GET /health and GET /health/db.
API_PREFIX = "/v1"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging()

    app = FastAPI(
        title="RASCAL API",
        version="0.1.0",
        summary="A private archive of a childhood, built one prompt at a time.",
        description=(
            "Plain JSON over HTTPS. Bearer auth. All timestamps ISO 8601 UTC, all IDs UUID.\n\n"
            "Every route lives under `/v1` except `GET /health`, `GET /health/db` and the "
            "universal-link pair, "
            "`/.well-known/apple-app-site-association` and `/signin`."
        ),
    )

    # **CORS, and this is the first browser client this API has ever had.**
    #
    # Scoped three ways on purpose: to the marketing origins from config and **never `*`**, to
    # the one path a browser calls, and to the two methods it needs. `docs/blocked.md` §2b,
    # *"CORS should be tightened when a web client exists"*, reserved that tightening for a browser
    # client — it exists now, and it arrived through a marketing form rather than the web app that
    # sentence was imagining. ~~`docs/blocked.md:809`~~ — **cited by section and by the sentence
    # since Aug 22, 2026 (phase 111), which reordered `blocked.md`: that line is now 579, and a line
    # number in this file points at whatever the next reshuffle leaves behind.**
    #
    # `allow_credentials` stays off. The subscribe route is unauthenticated and reads no cookie;
    # turning it on would be the setting that makes `*` illegal and a real origin dangerous.
    if settings.marketing_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.marketing_origins,
            allow_methods=["POST", "OPTIONS"],
            allow_headers=["Content-Type"],
            allow_credentials=False,
            max_age=600,
        )

    register_error_handlers(app)

    @app.get(
        "/health",
        tags=["health"],
        summary="Liveness",
        # **Liveness only, and it has to stay that way.** This is the route Fly polls every
        # 30 seconds against a machine that is always up, and a probe that touches Postgres
        # is a probe that never lets a serverless database idle. Neon suspends after ~5
        # minutes of inactivity and a suspended compute accrues nothing; the free plan is 100
        # CU-hours a month and the compute floor is 0.25 CU, so the allowance is 400
        # wall-clock hours of un-suspended compute against a 730-hour month. A 30-second poll
        # holds it awake continuously and spends the month around day 17 whether or not one
        # parent opened the app — and hitting the cap suspends the compute until the next
        # billing month, which is an outage rather than a throttle.
        #
        # So this route answers for the process and nothing else: no session, no dependency
        # that opens one, no settings read that could connect. `test_health.py` asserts zero
        # queries by counting cursor executions, not by reading this body.
        #
        # **A green check here therefore does not mean the app can serve.** That trade is
        # deliberate and recorded in docs/decisions.md: a machine with a dead database stays
        # in the load balancer and answers 500s, which the deploy poll and `/health/db`
        # catch, rather than every machine leaving it on a Neon hiccup.
        #
        # Unauthenticated on purpose: Fly's check carries no credentials.
    )
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get(
        "/health/db",
        tags=["health"],
        summary="Database readiness",
        # Exactly what `/health` used to do, on a route nothing polls on a seconds-scale
        # interval: `deploy.yml` for 90 seconds after a release, `smoke.yml` when a human
        # taps it, `scripts/verify_deployment.py`, and a `curl` from a runbook. Each of those
        # is asking the question this route answers, and none of them runs often enough to
        # keep a compute awake.
        #
        # Unauthenticated, like `/health`: it reports reachability, never data.
    )
    async def health_db(session: AsyncSession = Depends(get_session)) -> dict[str, str]:
        try:
            await session.execute(text("SELECT 1"))
        except (SQLAlchemyError, OSError) as exc:
            # 503 and a code that names the failure, rather than the 500 `internal_error` the
            # generic handler in errors.py would render. A readiness probe that answers 200
            # with a degraded body is the hazard `deploy.yml`'s byte-for-byte comparison was
            # written against; one that answers "something went wrong" is only half a step
            # better. Nothing from the driver reaches the client — the message is ours.
            raise RascalError(
                ErrorCode.DATABASE_UNREACHABLE,
                "The database could not be reached.",
            ) from exc
        return {"status": "ok", "db": "ok"}

    app.include_router(auth.router, prefix=API_PREFIX)
    app.include_router(me.router, prefix=API_PREFIX)
    app.include_router(devices.router, prefix=API_PREFIX)
    app.include_router(children.router, prefix=API_PREFIX)
    app.include_router(families.router, prefix=API_PREFIX)
    app.include_router(families.invites_router, prefix=API_PREFIX)
    app.include_router(export.router, prefix=API_PREFIX)
    app.include_router(today.router, prefix=API_PREFIX)
    app.include_router(entries.router, prefix=API_PREFIX)
    app.include_router(media.router, prefix=API_PREFIX)
    app.include_router(moments.router, prefix=API_PREFIX)
    app.include_router(sync.router, prefix=API_PREFIX)
    app.include_router(prompts.router, prefix=API_PREFIX)
    app.include_router(admin.router, prefix=API_PREFIX)
    app.include_router(social.router, prefix=API_PREFIX)
    app.include_router(webhooks.router, prefix=API_PREFIX)
    app.include_router(subscribe.router, prefix=API_PREFIX)
    # The admin console's own HTML, at /admin. Not under /v1 and not JSON: it is a page
    # rather than an endpoint, and it reads this API over the same bearer auth any client
    # uses. Mounted in every environment on purpose — see routers/admin_ui.py.
    app.include_router(admin_ui.router)
    admin_ui.mount(app)

    # No prefix: Apple fetches the association file from the root of the domain and will not
    # follow a redirect to find it, so `/v1` is not available to these two.
    app.include_router(wellknown.router)

    if settings.is_local:
        # dev-login and the debug routes must not exist in a production build. There is a
        # test that asserts it.
        app.include_router(auth.dev_router, prefix=API_PREFIX)
        app.include_router(debug.router, prefix=API_PREFIX)

    return app


app = create_app()
