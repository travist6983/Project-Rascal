"""The social studio.

Two things carry most of the weight.

**The D7 cap**, because it is the only thing standing between a working social generator and
the slow public disclosure of the mission library. `decisions.md` D7 keeps that library out of
anything public *"whole or in generated slices"* and calls it the one asset a competitor would
want; a studio that puts one prompt on one card is precisely a generated slice, and the danger
is that no single post looks like a problem. The tests below check that the body is read
server-side rather than accepted from the caller, that the cap counts distinct prompts rather
than posts, that a discarded draft does not count, and that the cap actually refuses.

**That nothing here claims Claude makes pictures.** `GET /social/studio` is the screen's own
description of itself, and a future edit that quietly promises image generation from the
Anthropic key would be a lie the console would then display. One test reads the copy.

No network. `ANTHROPIC_API_KEY` is unset in the suite, so every model route refuses before it
opens a socket — which is also the behaviour worth asserting.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import SocialAsset
from rascal.services.social import brand, renderers

MODEL_ROUTES = [
    ("POST", "/v1/social/concepts", {"brief": "Why backdating matters"}),
    ("POST", "/v1/social/shot-list", {"brief": "Thirty seconds on camera rolls"}),
    # Chat is in this list on purpose. It streams, and a streaming route cannot turn an
    # exception into a status code once its headers are out — so the key check has to
    # happen before the response starts, and this row is what proves it still does.
    ("POST", "/v1/social/chat", {"messages": [{"role": "user", "content": "hello"}]}),
]
ALL_ROUTES = [
    ("GET", "/v1/social/studio", None),
    ("GET", "/v1/social/assets", None),
    ("POST", "/v1/social/assets", {"headline": "hello"}),
    *MODEL_ROUTES,
]


@pytest.fixture
async def admin(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture(autouse=True)
def _no_key(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """The suite must never be able to reach Anthropic, even if a developer exports a key."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    yield


# --- Authorization ------------------------------------------------------------------------


@pytest.mark.parametrize(("method", "path", "payload"), ALL_ROUTES)
async def test_every_social_route_needs_an_admin(
    client: AsyncClient, session: AsyncSession, method: str, path: str, payload
) -> None:
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()
    response = await client.request(method, path, json=payload, headers=auth_headers(stranger))
    assert response.status_code == 403, f"{path} is reachable by a non-admin"


@pytest.mark.parametrize(("method", "path", "payload"), ALL_ROUTES)
async def test_no_token_is_refused(client: AsyncClient, method: str, path: str, payload) -> None:
    response = await client.request(method, path, json=payload)
    assert response.status_code == 401, path


# --- Honesty about what the model can do ---------------------------------------------------


async def test_the_studio_says_claude_cannot_make_pictures(client: AsyncClient, admin) -> None:
    """The console renders this sentence. If it ever stops being true, this test fails first."""
    payload = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()
    cannot = payload["director"]["cannot"].lower()
    assert "does not generate images" in cannot
    assert "no such endpoint" in cannot or "no such" in cannot

    by_key = {item["key"]: item for item in payload["renderers"]}
    # The card renderer is the one that needs nothing, and it must stay that way — it is the
    # whole reason this feature works on day one.
    assert by_key["cards"]["configured"] is True
    # Everything that needs a vendor is off in a fresh checkout, and each says what to set.
    for key in ("openai_image", "replicate_image", "replicate_video"):
        assert by_key[key]["configured"] is False, key
        assert by_key[key]["setup"], f"{key} does not say how to connect it"


@pytest.mark.parametrize(("method", "path", "payload"), MODEL_ROUTES)
async def test_a_missing_key_refuses_by_naming_the_variable(
    client: AsyncClient, admin, method: str, path: str, payload
) -> None:
    response = await client.request(method, path, json=payload, headers=auth_headers(admin))
    assert response.status_code == 422, response.text
    assert "ANTHROPIC_API_KEY" in response.json()["error"]["message"]
    # The two Anthropic keys in this service are different kinds of key, and confusing them is
    # the likeliest way somebody wastes an evening. The refusal has to say so.
    assert "admin" in response.json()["error"]["message"].lower()


async def test_the_brand_brief_never_carries_the_library(client: AsyncClient, admin) -> None:
    """Claude is told the rules; it is not given the asset the rules are about."""
    # Whitespace-normalised: the brief is wrapped prose and a line break inside a phrase is
    # formatting, not a change of meaning. Asserting on the raw string makes this test fail
    # the next time somebody re-wraps a paragraph, which teaches people to delete it.
    brief = " ".join(brand.system_prompt().split())
    assert "Never invent a Vellum prompt" in brief
    assert "it is not published" in brief
    # A body from the real library must not be reachable from the brief by any path.
    assert "What did {they} say" not in brief


# --- The D7 cap ---------------------------------------------------------------------------


async def test_featuring_a_prompt_snapshots_the_body_server_side(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    prompt = await make_prompt(session, body="Photograph {their} hands. Just {their} hands.")
    await session.commit()

    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "A card",
            "featured_prompt_id": str(prompt.id),
            # A caller-supplied body must be ignored: if it were honoured, the ledger would be
            # counting something other than the library.
            "featured_body": "something the caller made up",
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text
    assert response.json()["featured_body"] == prompt.body


async def test_the_ledger_counts_distinct_prompts_not_posts(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    prompt = await make_prompt(session, body="Describe {their} laugh.")
    await session.commit()
    for _ in range(3):
        created = await client.post(
            "/v1/social/assets",
            json={"headline": "again", "featured_prompt_id": str(prompt.id)},
            headers=auth_headers(admin),
        )
        assert created.status_code == 201, created.text

    ledger = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()[
        "library_ledger"
    ]
    assert ledger["featured"] == 1, "three posts about one prompt is one prompt disclosed"


async def test_a_discarded_draft_does_not_count_against_the_library(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    prompt = await make_prompt(session, body="What is {name} obsessed with right now?")
    await session.commit()
    created = await client.post(
        "/v1/social/assets",
        json={"headline": "draft", "featured_prompt_id": str(prompt.id)},
        headers=auth_headers(admin),
    )
    await client.patch(
        f"/v1/social/assets/{created.json()['id']}",
        json={"status": "discarded"},
        headers=auth_headers(admin),
    )
    ledger = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()[
        "library_ledger"
    ]
    assert ledger["featured"] == 0, "a concept nobody used was never disclosed"


async def test_the_cap_refuses_and_explains_itself(
    client: AsyncClient, session: AsyncSession, app, admin
) -> None:
    from rascal.config import get_settings as real_settings

    capped = real_settings().model_copy(update={"social_featured_prompt_cap": 2})
    app.dependency_overrides[real_settings] = lambda: capped
    try:
        prompts = [await make_prompt(session, body=f"Body number {n}.") for n in range(3)]
        await session.commit()
        for prompt in prompts[:2]:
            ok = await client.post(
                "/v1/social/assets",
                json={"headline": "fine", "featured_prompt_id": str(prompt.id)},
                headers=auth_headers(admin),
            )
            assert ok.status_code == 201, ok.text

        refused = await client.post(
            "/v1/social/assets",
            json={"headline": "one too many", "featured_prompt_id": str(prompts[2].id)},
            headers=auth_headers(admin),
        )
        assert refused.status_code == 422, refused.text
        message = refused.json()["error"]["message"]
        assert "SOCIAL_FEATURED_PROMPT_CAP" in message
        assert "D7" in message

        # A prompt already featured is not a new disclosure and must still work at the cap.
        again = await client.post(
            "/v1/social/assets",
            json={"headline": "same prompt again", "featured_prompt_id": str(prompts[0].id)},
            headers=auth_headers(admin),
        )
        assert again.status_code == 201, again.text
    finally:
        app.dependency_overrides.pop(real_settings, None)


async def test_a_patch_cannot_attach_a_library_body(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """The cap lives in the create path, so `featured_prompt_id` must not be patchable."""
    prompt = await make_prompt(session, body="A body nobody chose.")
    await session.commit()
    created = await client.post(
        "/v1/social/assets", json={"headline": "plain"}, headers=auth_headers(admin)
    )
    patched = await client.patch(
        f"/v1/social/assets/{created.json()['id']}",
        json={"featured_prompt_id": str(prompt.id), "featured_body": prompt.body},
        headers=auth_headers(admin),
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["featured_prompt_id"] is None
    assert patched.json()["featured_body"] is None


# --- Assets --------------------------------------------------------------------------------


async def test_alt_text_is_required_before_a_post_leaves(client: AsyncClient, admin) -> None:
    created = await client.post(
        "/v1/social/assets",
        json={"headline": "A card with no alt text"},
        headers=auth_headers(admin),
    )
    asset_id = created.json()["id"]

    refused = await client.patch(
        f"/v1/social/assets/{asset_id}", json={"status": "exported"}, headers=auth_headers(admin)
    )
    assert refused.status_code == 422, refused.text
    assert refused.json()["error"]["field"] == "alt_text"

    allowed = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"status": "exported", "alt_text": "A cream card with one line of type."},
        headers=auth_headers(admin),
    )
    assert allowed.status_code == 200, allowed.text


async def test_publishing_is_recorded_and_never_caused(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """`published` is the owner saying they posted it. Nothing in this service posts."""
    created = await client.post(
        "/v1/social/assets",
        json={"headline": "Out it goes", "alt_text": "A card."},
        headers=auth_headers(admin),
    )
    published = await client.patch(
        f"/v1/social/assets/{created.json()['id']}",
        json={"status": "published"},
        headers=auth_headers(admin),
    )
    assert published.status_code == 200
    assert published.json()["published_at"] is not None

    row = await session.get(SocialAsset, uuid.UUID(created.json()["id"]))
    await session.refresh(row)
    assert row.render_provider is None, "nothing rendered, and nothing was sent anywhere"


async def test_an_unconfigured_renderer_refuses_with_its_setup_line(
    client: AsyncClient, admin
) -> None:
    created = await client.post(
        "/v1/social/assets",
        json={"headline": "Needs pixels", "image_prompt": "A cream card on a wooden table"},
        headers=auth_headers(admin),
    )
    response = await client.post(
        f"/v1/social/assets/{created.json()['id']}/render",
        json={"provider": "openai_image", "kind": "image"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert "OPENAI_API_KEY" in response.json()["error"]["message"]


async def test_the_asset_list_filters_by_status(client: AsyncClient, admin) -> None:
    for status_value in ("draft", "approved"):
        created = await client.post(
            "/v1/social/assets",
            json={"headline": status_value, "alt_text": "A card."},
            headers=auth_headers(admin),
        )
        await client.patch(
            f"/v1/social/assets/{created.json()['id']}",
            json={"status": status_value},
            headers=auth_headers(admin),
        )
    listed = (
        await client.get("/v1/social/assets?status=approved", headers=auth_headers(admin))
    ).json()
    assert [asset["headline"] for asset in listed["assets"]] == ["approved"]


async def test_a_card_cannot_be_saved_with_an_undrawable_palette(
    client: AsyncClient, admin
) -> None:
    """`models/social.py` says these are validated against `brand.py`. Now they are.

    The console's own dropdown used to offer a blank option labelled "cream" above the real
    one — picking it saved `palette: ""`, which no renderer can draw and which nothing
    refused. The browser bug is fixed; this is the half that stops it recurring from any
    caller.
    """
    for field, bad in (("palette", ""), ("template", ""), ("palette", "chartreuse")):
        response = await client.post(
            "/v1/social/assets",
            json={"headline": "hi", "alt_text": "A card.", field: bad},
            headers=auth_headers(admin),
        )
        assert response.status_code == 422, f"{field}={bad!r} was accepted: {response.text}"


async def test_every_palette_and_template_brand_offers_is_actually_accepted(
    client: AsyncClient, admin
) -> None:
    """The mirror of the above: the schema must not be stricter than the renderer."""
    for palette in brand.PALETTES:
        for template in brand.TEMPLATES:
            response = await client.post(
                "/v1/social/assets",
                json={
                    "headline": "hi",
                    "alt_text": "A card.",
                    "palette": palette,
                    "template": template,
                },
                headers=auth_headers(admin),
            )
            assert response.status_code == 201, f"{palette}/{template}: {response.text}"


# --- Captions --------------------------------------------------------------------------------


def test_the_caption_track_is_webvtt_and_advances() -> None:
    """Most social video is watched with the sound off, so this is reach as well as access."""
    track = renderers.caption_track(
        [
            {"seconds": 3, "voiceover": "You have forty thousand photos."},
            {"seconds": 4, "voiceover": "You cannot find the one you want."},
            {"seconds": 2, "voiceover": "", "on_screen_text": "Vellum"},
        ]
    )
    assert track.startswith("WEBVTT")
    assert "00:00:00.000 --> 00:00:03.000" in track
    assert "00:00:03.000 --> 00:00:07.000" in track
    # A silent shot still gets a cue from its on-screen text rather than a gap.
    assert "Vellum" in track


def test_a_silent_shot_with_no_text_produces_no_cue() -> None:
    track = renderers.caption_track([{"seconds": 3, "voiceover": "", "on_screen_text": ""}])
    assert track.strip() == "WEBVTT"


def test_the_platform_sizes_the_model_is_told_match_the_renderer() -> None:
    """`brand.PLATFORM_SIZES` and `cards.js`'s SIZES are the same table written twice.

    The model is told how much room a headline has; the canvas decides how much there is. If
    those disagree the copy is written for the wrong box, which is invisible until an export
    is a word too long.
    """
    from pathlib import Path

    source = (Path(__file__).resolve().parents[1] / "src/rascal/admin/static/cards.js").read_text()
    for platform, (width, height) in brand.PLATFORM_SIZES.items():
        assert f"{platform}: [{width}, {height}]" in source, platform


def test_the_templates_and_palettes_the_model_may_name_are_all_drawable() -> None:
    from pathlib import Path

    source = (Path(__file__).resolve().parents[1] / "src/rascal/admin/static/cards.js").read_text()
    for palette in brand.PALETTES:
        assert f"{palette}: {{" in source, f"{palette} is offered to the model but not drawn"
    for template in brand.TEMPLATES:
        assert template in source, f"{template} is offered to the model but not drawn"


def test_social_renders_land_under_their_own_prefix() -> None:
    """Marketing output must never be mistaken for somebody's archive in a bucket listing."""
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[1] / "src/rascal/services/social/renderers.py"
    ).read_text()
    body = source.split("def _store")[1].split("\ndef ")[0]
    # The key expression itself, not the prose around it — the docstring explains the choice
    # by naming `children/`, and a test that greps the whole function fails on its own comment.
    key_line = next(line for line in body.splitlines() if "key = f" in line)
    assert 'f"social/' in key_line
    assert "children" not in key_line


def test_settings_keep_the_two_anthropic_keys_apart() -> None:
    """A single `anthropic_key` would 401 on one of its two callers and name the wrong cause."""
    settings = get_settings()
    assert hasattr(settings, "anthropic_api_key")
    assert hasattr(settings, "anthropic_admin_key")
