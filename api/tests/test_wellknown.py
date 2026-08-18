"""The universal-link surface (phase 59).

Every assertion here is about something Apple checks and then fails **silently** about. A wrong
content type, a redirect, or a path under `/v1` does not produce an error anywhere — universal
links simply stop working, the magic link opens Safari instead of the app, and nothing says why.
"""

from __future__ import annotations

from httpx import AsyncClient

from rascal.config import get_settings

AASA = "/.well-known/apple-app-site-association"


async def test_the_association_file_is_served_as_json(client: AsyncClient) -> None:
    """`application/json` or Apple ignores the file. There is no `.json` extension to infer from."""
    response = await client.get(AASA)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")


async def test_it_is_at_the_root_and_not_under_v1(client: AsyncClient) -> None:
    """Apple fetches this exact path and **does not follow a redirect** to find it."""
    assert (await client.get(AASA)).status_code == 200
    assert (await client.get(f"/v1{AASA}")).status_code == 404


async def test_it_needs_no_bearer_token(client: AsyncClient) -> None:
    """Fetched by Apple's CDN, never by a signed-in device."""
    response = await client.get(AASA)
    assert response.status_code == 200
    assert "error" not in response.text


async def test_the_app_id_is_team_dot_bundle(client: AsyncClient) -> None:
    settings = get_settings()
    detail = (await client.get(AASA)).json()["applinks"]["details"][0]

    assert detail["appIDs"] == [f"{settings.apple_team_id}.{settings.apple_bundle_id[0]}"]


async def test_the_claim_is_scoped_to_two_explicit_paths(client: AsyncClient) -> None:
    """**A universal link is a claim on a URL space**, and `*` would claim all of it.

    Claiming every path would make the app intercept `/health`, presigned media URLs and
    anything a browser client ever serves on this host.

    **This assertion was rewritten rather than relaxed.** It pinned `["/signin"]` exactly, and
    phase 62 added the invite claim — the behaviour changed first, for a stated reason, and this
    now pins what replaced it. Pinning the exact list rather than a membership check is the
    point: a third claim should fail here and make somebody justify it.
    """
    components = (await client.get(AASA)).json()["applinks"]["details"][0]["components"]

    assert [c["/"] for c in components] == ["/signin", "/invite/*"]
    assert all(c["/"] != "*" for c in components)


async def test_the_invite_claim_carries_no_query_requirement(client: AsyncClient) -> None:
    """The invite token is in the path, so a `?` clause would make the claim never match.

    `/signin` requires `?token=?*` because its token is a query parameter. Copying that onto a
    path-token claim is the kind of near-miss that fails silently: iOS simply does not hand the
    app the link, and nothing anywhere reports it.
    """
    components = (await client.get(AASA)).json()["applinks"]["details"][0]["components"]
    invite = next(c for c in components if c["/"] == "/invite/*")

    assert "?" not in invite


async def test_the_invite_landing_page_does_not_assume_the_app_is_installed(
    client: AsyncClient,
) -> None:
    """The difference between this page and `/signin`, and the reason it exists separately.

    A magic link goes to somebody who already has an archive. An invite goes to the other
    parent, who may be meeting Vellum for the first time — telling them to open it on the phone
    the app is installed on would be an instruction they cannot follow.
    """
    response = await client.get("/invite/some-token")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "Install it" in response.text


async def test_the_invite_page_never_echoes_the_token(client: AsyncClient) -> None:
    """Same rule as `/signin`. It is already in the address bar; putting it in the page as well
    puts it in a copied selection, a screenshot, and any "share this page" a browser offers."""
    response = await client.get("/invite/a-real-looking-token")

    assert response.status_code == 200
    assert "a-real-looking-token" not in response.text


async def test_the_invite_page_discloses_nothing_about_the_household(
    client: AsyncClient,
) -> None:
    """**No child's name reaches a browser.** `GET /v1/invites/{token}` makes that disclosure
    deliberately, to a caller that asked for it and got a 404 if the token was not real. This
    page is served to anybody who types a URL, so it knows nothing."""
    response = await client.get("/invite/some-token")

    for leak in ("Miles", "guardian", "family_id", "children"):
        assert leak not in response.text


async def test_the_link_base_points_at_the_claimed_path(client: AsyncClient) -> None:
    """The two have to agree, and nothing else checks that they do.

    `/auth/email/complete` is a POST route: a link pointing there would 405 in any browser, and
    on a phone it would never match the association file either.
    """
    claimed = (await client.get(AASA)).json()["applinks"]["details"][0]["components"][0]["/"]

    assert get_settings().email_sign_in_link_base.endswith(claimed)


async def test_the_browser_fallback_says_where_to_go(client: AsyncClient) -> None:
    """What a parent who opens the link on a laptop sees. No guilt, no urgency, nothing red."""
    response = await client.get("/signin")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "iPhone" in response.text


async def test_the_fallback_never_carries_the_token_into_a_web_flow(client: AsyncClient) -> None:
    """There is no web client. A sign-in surface that half-works is worse than one that
    says where to go — and echoing the token into HTML would put it in browser history."""
    response = await client.get("/signin", params={"token": "a-real-looking-token"})

    assert response.status_code == 200
    assert "a-real-looking-token" not in response.text
