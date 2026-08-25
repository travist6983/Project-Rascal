"""The admin console's API.

Two things get most of the attention here.

**Authorization**, because this is the widest read surface in the service and it is guarded by
one boolean. Every route is swept for a non-admin and for no token at all, the same way
`test_authorization_sweep.py` sweeps the child-scoped routes — a route added later and wired
to `CurrentUser` instead of `AdminUser` is exactly the mistake a sweep exists to catch.

**Leakage**, because "counts, never content" is a rule with no compiler behind it. The sweep
below arranges a child, an entry with a distinctive title and body, and a media row with a
transcript and an `s3_key`, then asserts that none of those strings appears anywhere in any
admin response. It fails the moment somebody adds a convenient `title` to a payload.

S3 is `moto`. Nothing here talks to AWS, Anthropic, Fly, Neon or Resend.
"""

from __future__ import annotations

import datetime as dt
import json
import uuid
from collections.abc import Iterator

import httpx
import pytest
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import Entry, Media
from rascal.services import billing, s3
from rascal.services.grants import issue_grant

#: Strings planted in the archive that must never appear in an admin response.
SECRET_TITLE = "the-word-he-invented-for-the-moon"
SECRET_BODY = "he called it a gloamy and would not be corrected"
SECRET_TRANSCRIPT = "gloamy gloamy gloamy said the four year old"
SECRET_KEY = "children/abc/def-the-private-object-key.m4a"
SECRET_CHILD = "Wolfgang-the-improbable"

ADMIN_GETS = [
    "/v1/admin/snapshot",
    "/v1/admin/library",
    "/v1/admin/ops",
    "/v1/admin/costs",
    # Phase 121. **Both are in the leakage sweep below and that is the point of adding them
    # here rather than only to the authorization list**: the grant panel is the first admin
    # surface that renders a *household* rather than a count, so "counts, never content" is
    # under more pressure on these two routes than on any that came before them.
    "/v1/admin/households",
    "/v1/admin/grants",
]


@pytest.fixture(autouse=True)
def _offline() -> Iterator[None]:
    """No provider is configured in the suite, so five of seven cards never open a socket.

    The other two open none either, for different reasons: Tigris uses the S3 client media
    already has, which `moto` intercepts, and Apple takes no client at all because Apple
    publishes no billing API to call. The cache is cleared on both sides so one test's
    provider answers cannot satisfy another's assertions.
    """
    billing.clear_cache()
    s3.get_s3_client.cache_clear()
    yield
    billing.clear_cache()
    s3.get_s3_client.cache_clear()


@pytest.fixture
def bucket() -> Iterator[None]:
    settings = get_settings()
    s3.get_s3_client.cache_clear()
    with mock_aws():
        s3.get_s3_client().create_bucket(
            Bucket=settings.s3_bucket,
            CreateBucketConfiguration={"LocationConstraint": settings.s3_region},
        )
        yield
    s3.get_s3_client.cache_clear()


@pytest.fixture
async def admin(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture
async def archive(session: AsyncSession):
    """One household with one thoroughly identifiable entry in it."""
    parent = await make_user(session, display_name="A parent")
    # `make_child(parent=…)` grants the guardian row; granting again collides on the PK.
    child = await make_child(session, name=SECRET_CHILD, parent=parent)
    prompt = await make_prompt(session)
    # UTC, because that is the clock `admin_metrics` computes its windows in — the machine's
    # own date would agree only sometimes and would put the assignment outside the window
    # for four hours a day on a runner east of UTC.
    assignment = await make_assignment(
        session, child, prompt, assigned_on=dt.datetime.now(tz=dt.UTC).date(), user=parent
    )
    assignment.status = "done"

    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=parent.id,
        assignment_id=assignment.id,
        occurred_at=dt.datetime.now(tz=dt.UTC),
        child_age_months=50,
        entry_type="audio",
        title=SECRET_TITLE,
        body=SECRET_BODY,
    )
    session.add(entry)
    await session.flush()
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key=SECRET_KEY,
            kind="audio",
            bytes=2048,
            upload_status="complete",
            transcript=SECRET_TRANSCRIPT,
        )
    )
    await session.commit()
    return {"parent": parent, "child": child, "prompt": prompt, "entry": entry}


# --- Authorization ----------------------------------------------------------------------------


@pytest.mark.parametrize("path", ADMIN_GETS)
async def test_a_signed_in_non_admin_is_refused(
    client: AsyncClient, session: AsyncSession, path: str, bucket
) -> None:
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()
    response = await client.get(path, headers=auth_headers(stranger))
    assert response.status_code == 403, f"{path} is readable by a non-admin"
    assert response.json()["error"]["code"] == "not_authorized"


@pytest.mark.parametrize("path", ADMIN_GETS)
async def test_no_token_is_refused(client: AsyncClient, path: str, bucket) -> None:
    response = await client.get(path)
    assert response.status_code == 401, f"{path} is readable with no token at all"


async def test_the_sweep_covers_every_admin_route(client: AsyncClient) -> None:
    """A route added to the admin router without a row above is a hole nobody would notice.

    Asserting the list rather than trusting it is the same move `test_authorization_sweep.py`
    makes for the child-scoped routes, and for the same reason: the sweep is only worth having
    if it cannot silently go out of date.
    """
    from rascal.main import create_app

    paths = {
        path
        for path, operations in create_app(get_settings()).openapi()["paths"].items()
        if path.startswith("/v1/admin") and "get" in operations
    }
    assert paths == set(ADMIN_GETS), (
        "an admin route is missing from ADMIN_GETS — add it so the sweep covers it"
    )


# --- No archive content -------------------------------------------------------------------------


async def test_no_admin_route_returns_archive_content(
    client: AsyncClient, session: AsyncSession, admin, archive, bucket
) -> None:
    """The rule `services/admin_metrics.py` is written to, enforced rather than asserted.

    **The archive's household is granted first, and that is not decoration.** Phase 121 put two
    new routes into `ADMIN_GETS` and one of them renders a *household* rather than a count — the
    first admin surface to do so. Sweeping an empty ledger would pass against any renderer at
    all, including one that printed a child's name beside every row.
    """
    await issue_grant(
        session,
        family_id=archive["parent"].family_id,
        granted_by=admin.id,
        reason="a grant on the household holding every planted string",
    )
    await session.commit()

    leaks = []
    for path in ADMIN_GETS:
        response = await client.get(path, headers=auth_headers(admin))
        assert response.status_code == 200, f"{path}: {response.text}"
        text = response.text
        for secret, what in (
            (SECRET_TITLE, "an entry title"),
            (SECRET_BODY, "an entry body"),
            (SECRET_TRANSCRIPT, "a transcript"),
            (SECRET_KEY, "an object key"),
            (SECRET_CHILD, "a child's name"),
        ):
            if secret in text:
                leaks.append(f"{path} returned {what}")
    assert not leaks, leaks


# --- Snapshot -----------------------------------------------------------------------------------


async def test_the_snapshot_counts_the_world(client: AsyncClient, admin, archive) -> None:
    response = await client.get("/v1/admin/snapshot?days=30", headers=auth_headers(admin))
    assert response.status_code == 200, response.text
    payload = response.json()

    overview = payload["overview"]
    assert overview["entries"]["total"] == 1
    assert overview["entries"]["by_type"] == {"audio": 1}
    assert overview["media"]["total"] == 1
    assert overview["media"]["bytes"] == 2048
    assert overview["children"]["total"] == 1
    # Two accounts: the admin and the parent, each in a household of their own.
    assert overview["users"]["total"] == 2
    assert overview["households"]["total"] == 2
    assert overview["assignments"]["completion_rate_30d"] == 1.0

    assert len(payload["growth"]["days"]) == 30, "the series is not gap-filled"
    assert sum(day["new_entries"] for day in payload["growth"]["days"]) == 1
    assert payload["themes"][0]["count"] == 1
    assert {row["email"] for row in payload["signups"]} == {
        archive["parent"].email,
        admin.email,
    }


async def test_a_deleted_entry_leaves_the_live_count_and_is_reported(
    client: AsyncClient, session: AsyncSession, admin, archive
) -> None:
    """Soft deletes are rows, not absences — the console should say so rather than hide them."""
    archive["entry"].deleted_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()
    payload = (await client.get("/v1/admin/snapshot", headers=auth_headers(admin))).json()
    assert payload["overview"]["entries"]["total"] == 0
    assert payload["overview"]["entries"]["deleted"] == 1


async def test_growth_gap_fills_every_day(client: AsyncClient, admin) -> None:
    payload = (await client.get("/v1/admin/snapshot?days=14", headers=auth_headers(admin))).json()
    days = [row["day"] for row in payload["growth"]["days"]]
    assert len(days) == 14
    assert days == sorted(days)
    assert len(set(days)) == 14


# --- Library ------------------------------------------------------------------------------------


async def test_the_library_carries_usage_and_override_state(
    client: AsyncClient, admin, archive
) -> None:
    payload = (await client.get("/v1/admin/library", headers=auth_headers(admin))).json()
    row = next(p for p in payload["prompts"] if p["id"] == str(archive["prompt"].id))
    assert row["served"] == 1
    assert row["completed"] == 1
    assert row["override"] is None
    assert row["content_hash"]
    assert payload["themes"]


async def test_the_library_filters(client: AsyncClient, session: AsyncSession, admin) -> None:
    await make_prompt(session, body="Something about {their} shoes", theme="everyday-ordinary")
    await session.commit()
    hit = (await client.get("/v1/admin/library?q=shoes", headers=auth_headers(admin))).json()
    assert hit["total"] == 1
    miss = (await client.get("/v1/admin/library?kind=letter", headers=auth_headers(admin))).json()
    assert miss["total"] == 0


# --- Ops ----------------------------------------------------------------------------------------


async def test_ops_reads_what_the_scheduler_produced(client: AsyncClient, admin, archive) -> None:
    payload = (await client.get("/v1/admin/ops", headers=auth_headers(admin))).json()
    assert payload["environment"] == "local"
    assert payload["jobs"]["migration"], "the migration head is not being read"

    slots = {slot["slot"]: slot for slot in payload["scheduler"]["slots"]}
    served = archive["prompt"]
    assert served is not None
    # Every daily slot is present whether or not it served anything, because a slot that is
    # absent from the grid is exactly the one nobody notices is missing.
    assert {"question", "mission", "mission_b"} <= set(slots)
    assert slots["mission"]["silent"] is True
    assert len(payload["scheduler"]["span"]) == 14


async def test_every_flag_says_what_it_gates(client: AsyncClient, admin) -> None:
    """A boolean with no sentence beside it is unreadable six months later."""
    payload = (await client.get("/v1/admin/ops", headers=auth_headers(admin))).json()
    assert payload["flags"]
    for flag in payload["flags"]:
        assert flag["means"].strip(), f"{flag['key']} has no explanation"
    keys = {flag["key"] for flag in payload["flags"]}
    assert "MARKETING_EMAIL_ENABLED" in keys


async def test_ops_leaks_no_secret(client: AsyncClient, admin) -> None:
    """The flags panel reports whether a credential is set, never what it is."""
    settings = get_settings()
    text = (await client.get("/v1/admin/ops", headers=auth_headers(admin))).text
    for secret in (settings.jwt_secret, settings.aws_secret_access_key):
        assert secret not in text


# --- Costs --------------------------------------------------------------------------------------


async def test_unconfigured_providers_are_a_state_not_an_error(
    client: AsyncClient, admin, bucket
) -> None:
    response = await client.get("/v1/admin/costs", headers=auth_headers(admin))
    assert response.status_code == 200, response.text
    payload = response.json()
    by_key = {provider["key"]: provider for provider in payload["providers"]}
    assert set(by_key) == {"anthropic", "github", "fly", "neon", "tigris", "resend", "apple"}

    for key in ("anthropic", "github", "fly", "neon"):
        assert by_key[key]["status"] == "unconfigured"
        # A card that says "not connected" without naming the variable is a dead end.
        assert by_key[key]["setup"], f"{key} does not say how to connect it"

    assert payload["total_known_cents"] == 0


async def test_the_storage_card_reads_the_real_bucket(client: AsyncClient, admin, bucket) -> None:
    settings = get_settings()
    s3.get_s3_client().put_object(
        Bucket=settings.s3_bucket, Key="children/one/two.jpg", Body=b"x" * 1024
    )
    payload = (await client.get("/v1/admin/costs", headers=auth_headers(admin))).json()
    tigris = next(p for p in payload["providers"] if p["key"] == "tigris")
    assert tigris["status"] == "ok"
    assert any("1.0 KB" in metric["value"] for metric in tigris["metrics"])
    # Tigris publishes no billing API, so the card must not invent a figure.
    assert tigris["amount_cents"] is None
    assert "Tigris (storage)" in payload["providers_without_pricing"]


async def test_a_configured_price_produces_a_labelled_estimate(
    client: AsyncClient, session: AsyncSession, app, admin, bucket
) -> None:
    """An estimate is allowed only when it names the number it came from."""
    from rascal.config import get_settings as real_settings

    priced = real_settings().model_copy(update={"storage_price_cents_per_gb_month": 2000})
    app.dependency_overrides[real_settings] = lambda: priced
    try:
        payload = (await client.get("/v1/admin/costs", headers=auth_headers(admin))).json()
    finally:
        app.dependency_overrides.pop(real_settings, None)
    tigris = next(p for p in payload["providers"] if p["key"] == "tigris")
    assert tigris["amount_cents"] is not None
    assert "STORAGE_PRICE_CENTS_PER_GB_MONTH" in tigris["detail"]


async def test_every_ok_card_without_a_figure_says_why(client: AsyncClient, admin, bucket) -> None:
    """Rule 2, as an executable assertion rather than a paragraph in a docstring.

    A card that is working and carries no dollar figure has to explain the absence. Five of the
    seven providers are in that position permanently, and a blank where a number should be
    reads as zero spent rather than as nothing knowable.
    """
    payload = (await client.get("/v1/admin/costs", headers=auth_headers(admin))).json()
    for provider in payload["providers"]:
        if provider["status"] == "ok" and provider["amount_cents"] is None:
            assert provider["detail"], f"{provider['key']} shows no figure and does not say why"


async def test_no_provider_leaks_its_credential_into_the_response(bucket) -> None:
    """Provider errors are the one place a key can reach the browser.

    An httpx `RequestError` stringifies to the URL it was fetching, and several of these APIs
    take their credential in a header built next to that URL — so a transport failure is the
    realistic path by which a secret ends up in a response body. `_safe_message` exists for
    exactly this and had no test.

    Driven through an injected transport rather than the route: every provider is configured
    here, and without one this would make real outbound calls to five vendors.
    """
    sentinels = {
        "anthropic_admin_key": "sk-ant-admin-SENTINEL-A",
        "github_billing_token": "github_pat_SENTINEL_B",
        "fly_api_token": "fo1_SENTINEL_C",
        "neon_api_key": "napi_SENTINEL_D",
        "neon_org_id": "org-SENTINEL-E",
        "mail_api_key": "re_SENTINEL_F",
    }
    configured = get_settings().model_copy(update=sentinels)

    def explode(request: httpx.Request) -> httpx.Response:
        # The worst realistic case: the failure message carries the whole request, credential
        # header and all, which is how a secret gets into a log and then into a response.
        raise httpx.ConnectError(
            f"failed connecting to {request.url} with {dict(request.headers)}", request=request
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(explode)) as client:
        reports = await billing.collect(configured, client=client)

    body = json.dumps([report.as_dict() for report in reports])
    for name, value in sentinels.items():
        assert value not in body, f"{name} reached the response body"
    # And the failures really did happen — otherwise this asserts nothing at all.
    assert any(report.status == "error" for report in reports)


# --- The page itself ------------------------------------------------------------------------------


async def test_the_console_is_served_and_holds_no_credential(client: AsyncClient) -> None:
    """Unauthenticated on purpose: it is markup that can read nothing without a token."""
    response = await client.get("/admin")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    body = response.text
    assert "Vellum" in body
    settings = get_settings()
    assert settings.jwt_secret not in body
    assert settings.aws_secret_access_key not in body


async def test_the_console_assets_are_served(client: AsyncClient) -> None:
    for path in ("/admin/static/admin.css", "/admin/static/admin.js", "/admin/static/cards.js"):
        response = await client.get(path)
        assert response.status_code == 200, path


async def test_the_console_never_runs_a_previous_deploys_javascript(client: AsyncClient) -> None:
    """The page is `no-store` and the scripts it loads must be at least `no-cache`.

    Starlette's `StaticFiles` sends `etag` and `last-modified` and no `Cache-Control`, and a
    browser given validators and no freshness directive invents its own. So an uncached
    `index.html` guarantees nothing: it is the one console file that contains no behaviour, and
    the two that do would keep being served out of the browser's cache across a deploy.
    """
    page = await client.get("/admin")
    assert page.headers["cache-control"] == "no-store"
    for path in ("/admin/static/admin.css", "/admin/static/admin.js", "/admin/static/cards.js"):
        response = await client.get(path)
        assert response.headers["cache-control"] == "no-cache", path
        # The validator has to survive, or "no-cache" costs a full body on every request.
        assert response.headers.get("etag"), path
