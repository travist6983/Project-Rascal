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


async def test_the_claim_is_scoped_to_the_sign_in_path(client: AsyncClient) -> None:
    """**A universal link is a claim on a URL space**, and `*` would claim all of it.

    Claiming every path would make the app intercept `/health`, presigned media URLs and
    anything a browser client ever serves on this host.
    """
    components = (await client.get(AASA)).json()["applinks"]["details"][0]["components"]

    assert [c["/"] for c in components] == ["/signin"]
    assert all(c["/"] != "*" for c in components)


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
