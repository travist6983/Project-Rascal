"""The universal-link surface: what iOS fetches, and what a browser gets instead.

Both routes live **outside `/v1`**, the same exemption `GET /health` has, and for a stricter
reason: Apple fetches `/.well-known/apple-app-site-association` from the root of the domain and
will not follow a redirect to find it. A versioned path is not an option.

**This is what makes a magic link open the app.** Without it the link opens Safari, the parent
sees a web page where they expected their archive, and nothing about the failure says why.
"""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, JSONResponse

from rascal.deps import SettingsDep

router = APIRouter(include_in_schema=False)


@router.get(
    "/.well-known/apple-app-site-association",
    summary="Apple app-site-association, for universal links",
)
async def apple_app_site_association(settings: SettingsDep) -> JSONResponse:
    """The association file iOS fetches to decide whether this app may open our links.

    Three things Apple is strict about and each fails silently:

    - **`Content-Type: application/json`**, which is why this is a `JSONResponse` and not a
      static file — a `.json`-less path served as `text/plain` is ignored.
    - **No redirect.** Apple fetches this exact path and does not follow one.
    - **No authentication.** It is fetched by Apple's CDN, not by a signed-in device.

    **Two explicit paths, never `*`.** A universal link is a claim on a URL space, and claiming
    every path on this host would make the app intercept `/health`, the presigned media URLs and
    anything a browser client ever serves. Each new claim is another entry here, deliberately —
    the cost of adding one is the point at which somebody asks whether it should be added.

    `/invite/*` carries its token in the **path** rather than the query, because that is the
    shape the client builds (`GuardiansModel.shareURL`) and a household invite has no other
    parameter to carry. `/signin` keeps its query form; changing it would invalidate every link
    already sent.
    """
    app_id = f"{settings.apple_team_id}.{settings.apple_bundle_id[0]}"
    return JSONResponse(
        content={
            "applinks": {
                "details": [
                    {
                        "appIDs": [app_id],
                        "components": [
                            {"/": "/signin", "?": {"token": "?*"}, "comment": "magic link"},
                            {"/": "/invite/*", "comment": "household invite"},
                        ],
                    }
                ]
            }
        },
        media_type="application/json",
    )


@router.get("/invite/{token}", response_class=HTMLResponse, summary="Invite landing page")
async def invite_landing(token: str) -> HTMLResponse:
    """What a **browser** sees, and it is not the sign-in page's message.

    **The person opening this probably does not have the app**, which is the whole difference.
    A magic link goes to somebody who already has an archive; an invite goes to the other
    parent, who may be meeting Dogear for the first time on a laptop. Telling them to "open
    this on your iPhone" would be an instruction they cannot follow.

    So it says what the link *is* — somebody is sharing a child's archive with them — and where
    to get the app. It does not preview the household: that would disclose a child's name to
    anybody holding a mistyped URL, and `GET /v1/invites/{token}` exists to make that disclosure
    deliberately, to a caller that asked for it.

    **The token is never echoed into the HTML**, the same rule `/signin` follows. It is already
    in the address bar; putting it in the page as well would put it in a copied selection, a
    screenshot, and any "share this page" a browser offers.
    """
    return HTMLResponse(
        """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dogear</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         margin: 0; min-height: 100dvh; display: grid; place-items: center; padding: 2rem; }
  main { max-width: 26rem; text-align: center; }
  h1 { font-size: 1.4rem; font-weight: 600; margin: 0 0 0.75rem; }
  p { margin: 0 0 0.75rem; opacity: 0.8; }
</style>
<main>
  <h1>Someone shared a child\u2019s archive with you</h1>
  <p>Dogear keeps a record of a childhood, one small thing at a time. This link adds you to
     the household, so you both keep the same one.</p>
  <p>It opens in the Dogear app on iPhone. Install it, then tap this link again on that phone.</p>
</main>
"""
    )


@router.get("/signin", response_class=HTMLResponse, summary="Magic-link landing page")
async def signin_landing() -> HTMLResponse:
    """What a **browser** sees. On a phone with the app installed, iOS never reaches this.

    A parent who opens the link on a laptop is the case this exists for, and the copy follows
    the same rules as the app: no guilt, no urgency, nothing red. It says what to do next and
    stops. It deliberately does **not** carry the token into any web flow — there is no web
    client, and a sign-in surface that half-works is worse than one that says where to go.
    """
    return HTMLResponse(
        """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dogear</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         margin: 0; min-height: 100dvh; display: grid; place-items: center; padding: 2rem; }
  main { max-width: 26rem; text-align: center; }
  h1 { font-size: 1.4rem; font-weight: 600; margin: 0 0 0.75rem; }
  p { margin: 0 0 0.75rem; opacity: 0.8; }
</style>
<main>
  <h1>Open this on your iPhone</h1>
  <p>This sign-in link works in the Dogear app, so it needs the phone the app is installed on.</p>
  <p>Open the same email there and tap the link again.</p>
</main>
"""
    )
