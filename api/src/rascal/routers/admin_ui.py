"""Serving the admin console's HTML, CSS and JavaScript.

**This is not the exception to D7.** D7 rejected serving the *marketing site* from this app on
three counts: it couples a landing page's uptime to the API's deploy lifecycle, it puts HTML
in the `api/` lane, and it pays for something a CDN does free. Two of the three do not apply
to an internal console and the third is the point of it:

- *Coupled uptime* is a feature here. An admin console that is up while the API is down is a
  console showing stale numbers about a service nobody can reach. It should go down with it.
- *A CDN does it free* assumes an audience. This page has one reader, is behind a bearer
  token, and would need CORS and a second origin to live anywhere else — six lines of
  `CORSMiddleware` to save nothing.
- *HTML in the `api/` lane* is the real cost, and it is paid deliberately and narrowly: three
  static files under `admin/static/`, no template engine, no build step, no new dependency.
  `StaticFiles` is already in Starlette. **What stays out of scope is serving HTML for the
  product itself**, which is what D7's sentence is actually about and is untouched.

**Mounted in every environment, including production.** Gating it to `local` the way
`dev-login` and `/debug/*` are gated would be security theatre pointing the wrong way: the
page ships no credential and can read nothing without an admin bearer token, so the gate that
matters is `require_admin` on the JSON routes, not the reachability of a stylesheet. A console
that only exists on a laptop is a console that cannot tell you what production is doing.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.responses import Response
from starlette.types import Scope

STATIC_DIR = Path(__file__).resolve().parent.parent / "admin" / "static"


class RevalidatedStatic(StaticFiles):
    """`StaticFiles` that makes the browser ask before reusing a file.

    The console's HTML is `no-store` and its JavaScript was not, which is the wrong way round:
    `index.html` holds no behaviour and `admin.js` and `cards.js` hold all of it. Starlette
    sends `etag` and `last-modified` on a static file and no `Cache-Control` at all, and a
    browser handed validators with no freshness directive invents one — Chrome's heuristic is a
    fraction of the file's age. So a console open across an edit keeps executing the previous
    script and never asks about it. **That is precisely the failure the `no-store` on the HTML
    was written to prevent, applied to the one file that could not suffer it.**

    `no-cache` rather than `no-store`: the validators are already correct, so the browser still
    asks and still gets a 304 with no body back. One reader, one long-lived tab — being right
    about which script is running is worth a conditional request.
    """

    def file_response(
        self,
        full_path: str | os.PathLike[str],
        stat_result: os.stat_result,
        scope: Scope,
        status_code: int = 200,
    ) -> Response:
        response = super().file_response(full_path, stat_result, scope, status_code)
        # Set before the caller can turn this into a 304: Starlette's `NotModifiedResponse`
        # carries `cache-control` through, so the directive survives the revalidation it causes.
        response.headers["cache-control"] = "no-cache"
        return response


router = APIRouter(tags=["admin"])


@router.get(
    "/admin",
    include_in_schema=False,
    summary="The admin console",
    response_class=FileResponse,
)
async def console() -> FileResponse:
    """The whole application, as one file that holds no secret.

    Deliberately uncached: this is one page for one reader, and a stale console after a deploy
    is a worse trade than a fetch. `no-store` rather than a validator, because the thing being
    avoided is a browser holding a *previous deployment's* JavaScript against a changed API —
    which this header alone never achieved, since the JavaScript is not in this file.
    `RevalidatedStatic` is the other half.
    """
    return FileResponse(
        STATIC_DIR / "index.html",
        media_type="text/html",
        headers={"Cache-Control": "no-store"},
    )


def mount(app: object) -> None:
    """Attach `/admin/static` for the stylesheet and the script.

    A function rather than a router, because `StaticFiles` is an ASGI app and mounts on the
    application rather than being included as routes. Called from `create_app`.
    """
    app.mount(  # type: ignore[attr-defined]
        "/admin/static",
        RevalidatedStatic(directory=STATIC_DIR),
        name="admin-static",
    )
