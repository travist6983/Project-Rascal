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
from rascal.services.social import brand, scenes

MODEL_ROUTES = [
    ("POST", "/v1/social/concepts", {"brief": "Why backdating matters"}),
    ("POST", "/v1/social/treatment", {"brief": "Twenty seconds on camera rolls"}),
    # Chat is in this list on purpose. It streams, and a streaming route cannot turn an
    # exception into a status code once its headers are out — so the key check has to
    # happen before the response starts, and this row is what proves it still does.
    ("POST", "/v1/social/chat", {"messages": [{"role": "user", "content": "hello"}]}),
]
ALL_ROUTES = [
    ("GET", "/v1/social/studio", None),
    ("GET", "/v1/social/assets", None),
    ("POST", "/v1/social/assets", {"headline": "hello"}),
    # Phase 104. `/social/account` and `/social/publications` read a live account and the
    # publish queue; the publish route reaches a public feed. A stranger who could call any of
    # them would be reading the product's marketing credentials or posting under its name.
    ("GET", "/v1/social/account", None),
    ("GET", "/v1/social/publications", None),
    # The two that reach a public feed. Listed here as well as in `test_social_publishing.py`
    # so the sweep covers them by construction.
    ("POST", "/v1/social/assets/00000000-0000-0000-0000-000000000000/publish", {}),
    ("POST", "/v1/social/publications/00000000-0000-0000-0000-000000000000/cancel", None),
    # Phase 120. Both halves of the canvas video path: the route that takes the browser's
    # recording, and the one that mints a read URL for what came out of it. A stranger who
    # could call the second would be reading files off the media bucket.
    ("POST", "/v1/social/assets/00000000-0000-0000-0000-000000000000/video", None),
    ("GET", "/v1/social/assets/00000000-0000-0000-0000-000000000000/video", None),
    ("GET", "/v1/social/renders/00000000-0000-0000-0000-000000000000/file", None),
    # The three that were missing when this comment claimed the list walked every social route.
    ("PATCH", "/v1/social/assets/00000000-0000-0000-0000-000000000000", {"headline": "x"}),
    (
        "POST",
        "/v1/social/assets/00000000-0000-0000-0000-000000000000/render",
        {"provider": "openai_image", "kind": "image"},
    ),
    ("POST", "/v1/social/assets/00000000-0000-0000-0000-000000000000/image", None),
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


async def test_the_studio_serves_exactly_what_the_console_reads_and_nothing_else(
    client: AsyncClient, admin
) -> None:
    """**The `video` block is two keys, and the assertion is that it is only two.**

    It was written with eight — the transitions, both bounds, the copy maxima and the byte cap
    — for a scene editor the composer does not have. Six of them were therefore served by the
    API and read by nothing, which is the phase 101 defect committed by the phase that cites it.
    `admin.js` reads `platforms` and `ffmpeg`, both in `whyNotRecord`, and nothing else; the
    other two gates it applies come from the browser (`cards.canRecord()`) and the renderer
    (`cards.SIZES`), not from here.

    So this asserts the exact key set. A key added back without a reader fails it.
    """
    payload = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()
    video = payload["video"]

    assert set(video) == {"platforms", "ffmpeg"}, (
        "a key here that no console file reads is a field that can be wrong forever"
    )
    assert video["platforms"] == list(brand.VIDEO_PLATFORMS)
    assert video["ffmpeg"] is True, "this machine has ffmpeg, so the payload must say so"

    # Every video platform must be a size the renderer actually has, or the console would offer
    # a recording at a size `cards.js` silently falls back to `generic` for.
    for platform in brand.VIDEO_PLATFORMS:
        assert platform in brand.PLATFORM_SIZES

    from pathlib import Path

    source = (Path(__file__).resolve().parents[1] / "src/rascal/admin/static/admin.js").read_text()
    for key in video:
        assert f"video.{key}" in source or f"video?.{key}" in source, (
            f"the API serves video.{key} and no console file reads it"
        )


async def test_a_machine_without_ffmpeg_says_so_everywhere_it_matters(
    client: AsyncClient, admin, monkeypatch: pytest.MonkeyPatch
) -> None:
    """**The one branch this suite could not otherwise reach, and it decides a whole feature.**

    Every machine that runs these tests has ffmpeg, so `video.ffmpeg` and the renderer's
    `configured` flag are both `True` and an assertion that compares them to
    `transcode.available()` is a tautology — it would pass against a hardcoded `True`. Patching
    the probe is the only way to exercise the answer the console gates the Record button on.
    """
    from rascal.services.social import transcode

    payload = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()
    with_ffmpeg = {item["key"]: item for item in payload["renderers"]}["canvas_video"]

    monkeypatch.setattr(transcode, "available", lambda: False)
    payload = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()
    without = {item["key"]: item for item in payload["renderers"]}["canvas_video"]

    assert payload["video"]["ffmpeg"] is False
    # **Both are False here and that is the trap this line closes.** `ANTHROPIC_API_KEY` is
    # unset for this module, so `canvas_video.configured` is False either way — asserting on it
    # alone would pass against a `configured` that ignored ffmpeg entirely. What has to differ
    # is the *reason*, so the two payloads are compared rather than one being inspected.
    assert with_ffmpeg["configured"] is False and without["configured"] is False
    assert "ffmpeg" in without["setup"], "the setup line must still name the missing half"


async def test_a_post_is_refused_before_recording_when_the_machine_has_no_ffmpeg(
    client: AsyncClient, admin, session, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`preflight`'s second guard, which exists so the refusal comes *before* the recording.

    Twenty seconds of the operator's time is the cost of discovering this after the fact, and
    the message has to name ffmpeg or it sends them to look at the browser.
    """
    from rascal.models import SocialAsset
    from rascal.services.social import transcode

    monkeypatch.setattr(transcode, "available", lambda: False)
    asset = SocialAsset(
        headline="a treatment",
        format="video",
        treatment={
            "scenes": [
                {
                    "template": "quote",
                    "palette": "cream",
                    "eyebrow": None,
                    "headline": "one",
                    "subhead": None,
                    "duration_ms": 3000,
                    "transition": "cut",
                },
                {
                    "template": "quote",
                    "palette": "ink",
                    "eyebrow": None,
                    "headline": "two",
                    "subhead": None,
                    "duration_ms": 4000,
                    "transition": "fade",
                },
            ]
        },
    )
    session.add(asset)
    await session.commit()

    response = await client.post(
        f"/v1/social/assets/{asset.id}/video",
        content=b"\x1a\x45\xdf\xa3",
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "ffmpeg"
    assert "ffmpeg" in response.json()["error"]["message"]


async def test_the_canvas_video_renderer_reports_itself_configured(
    client: AsyncClient, admin
) -> None:
    """The provider strip is what tells the operator video is available at all.

    `canvas_video` replaced `storyboard` in phase 120 and needs both halves of what it claims:
    a key for the scene graph and an ffmpeg for the re-encode. Without a key it must say so
    rather than showing a green pill above a button that answers 422.
    """
    from rascal.services.social import transcode

    payload = (await client.get("/v1/social/studio", headers=auth_headers(admin))).json()
    by_key = {item["key"]: item for item in payload["renderers"]}

    assert "storyboard" not in by_key, "the old shot-list renderer is gone"
    canvas = by_key["canvas_video"]
    assert canvas["kind"] == "video"
    # `_no_key` unsets ANTHROPIC_API_KEY for this module, so it cannot be configured here
    # whatever ffmpeg says — and the setup line has to name both halves.
    assert canvas["configured"] is False
    assert "ANTHROPIC_API_KEY" in canvas["setup"] and "ffmpeg" in canvas["setup"]
    assert transcode.available() or "ffmpeg" in canvas["setup"]


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
    assert "Never invent a Pocket Chronicle prompt" in brief
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
    """Derived from the scenes, in the order and at the times the scenes actually run."""
    track = scenes.caption_track(
        [
            {"headline": "Three thousand photos.", "duration_ms": 3000},
            {
                "headline": "One story.",
                "subhead": "The question is the difference.",
                "duration_ms": 4000,
            },
        ]
    )
    assert track.startswith("WEBVTT")
    assert "00:00:00.000 --> 00:00:03.000" in track
    assert "00:00:03.000 --> 00:00:07.000" in track
    # The subhead is a second cue line rather than a second cue: it is on the same card.
    assert "One story.\nThe question is the difference." in track


def test_a_scene_with_no_headline_produces_no_cue_and_still_moves_the_clock() -> None:
    """The running sum is over every scene, not only the ones that produced text.

    A cue whose start is computed from the scenes before it *that happened to have words* is
    off by however long the silent ones ran, and every cue after it is off too. Nothing about
    the file would look wrong — the timings would be internally consistent and would describe
    a different video.
    """
    track = scenes.caption_track(
        [
            {"headline": "", "duration_ms": 2000},
            {"headline": "After the quiet one.", "duration_ms": 3000},
        ]
    )
    assert track.count("-->") == 1, "a headline-less scene must not get a cue"
    assert "00:00:02.000 --> 00:00:05.000" in track, "and must still advance the clock"


@pytest.mark.parametrize(
    ("copy", "must_contain", "must_not_contain"),
    [
        ("R&D on a Tuesday", "R&amp;D on a Tuesday", "R&D"),
        ("we were <3 about it", "we were &lt;3 about it", "<3"),
        ("before --> after", "before --&gt; after", "before --> after"),
    ],
)
def test_scene_copy_cannot_break_the_cue_it_is_written_into(
    copy: str, must_contain: str, must_not_contain: str
) -> None:
    """**Three characters a WebVTT cue payload may not carry raw, and all three fail silently.**

    A conforming parser reads `<` as the start of a cue span and drops everything to the next
    `>`; a cue line containing `-->` ends the cue and is reparsed as a timings line, deleting it
    outright; and `&` left bare makes the escape for the other two ambiguous. The result in every
    case is a caption that says less than the card draws — the exact divergence this whole
    derivation exists to make impossible.

    **Escaped rather than rejected**, because the card draws these characters verbatim and the
    cue has to say the same words. Refusing a headline containing "R&D" would be the caption
    format's rules leaking into the copy.
    """
    # **Both fields, because both are interpolated.** The subhead goes through the same
    # `_cue_text` and an escape applied to only one of them would pass a headline-only test.
    for field in ("headline", "subhead"):
        scene = {"headline": "a headline", "subhead": "a subhead", "duration_ms": 3000}
        scene[field] = copy
        track = scenes.caption_track([scene])
        assert must_contain in track, field
        assert must_not_contain not in track, field
        # The cue survives at all, which is what `-->` in particular destroys.
        assert track.count(" --> ") == 1, field


def test_the_running_sum_clamps_the_same_junk_the_browser_clamps() -> None:
    """**`scenes.py` and `timeline.js` must agree, and the docstring says they do.**

    `timeline.js`'s `boundaries()` reads `Math.max(0, Math.trunc(scene.duration_ms) || 0)`. The
    `max` is the half that matters: `Math.trunc` and `int()` already truncate toward zero
    identically and `NaN || 0` and `None or 0` already both give zero, but without the clamp the
    two sides agree on every duration a validated treatment can hold and *disagree on a negative
    one* — the one case where "the same running sum" would quietly stop being true. Nothing else
    in the system compares them.

    A negative also reaches `stamp`, where `divmod(-1, 1000)` is `(-1, 999)` in Python and would
    render `-1:59:59.999` — a string no WebVTT parser accepts, produced without an error.
    """
    assert scenes.boundaries_ms([{"duration_ms": -5000}, {"duration_ms": 3000}]) == [0, 3000]
    assert scenes.total_ms([{"duration_ms": -5000}, {"duration_ms": 3000}]) == 3000
    assert scenes.stamp(-1) == "00:00:00.000"
    # And the shapes both sides already coped with stay coping, so the clamp is the only change.
    assert scenes.boundaries_ms([{}, {"duration_ms": None}, {"duration_ms": 1500.7}]) == [
        0,
        0,
        1500,
    ]
    assert scenes.total_ms([]) == 0


def test_the_stamp_carries_minutes_and_hours_and_not_only_seconds() -> None:
    """Asserted against literals, because every other test compares `stamp` to itself.

    A treatment is bounded at sixty seconds, so nothing in ordinary use crosses a minute — which
    is exactly why the minute and hour fields have never been exercised by anything. `stamp` is
    a public function of a module whose claim is exactness, and an off-by-one in the `// 60` or
    a `%` in the wrong place would be invisible until somebody widened the bound.
    """
    assert scenes.stamp(0) == "00:00:00.000"
    assert scenes.stamp(1) == "00:00:00.001"
    assert scenes.stamp(999) == "00:00:00.999"
    assert scenes.stamp(1_000) == "00:00:01.000"
    assert scenes.stamp(59_999) == "00:00:59.999"
    assert scenes.stamp(60_000) == "00:01:00.000"
    assert scenes.stamp(3_599_999) == "00:59:59.999"
    assert scenes.stamp(3_600_000) == "01:00:00.000"
    assert scenes.stamp(45_296_789) == "12:34:56.789"


def test_the_cue_boundaries_are_exactly_the_scene_boundaries() -> None:
    """The invariant a stored, separately-editable track could not hold, on uneven durations.

    Before phase 120 the track was derived once, at generation, and then kept in a column that a
    `PATCH` could overwrite and that editing the shots did not refresh. Recomputing on every
    write is what makes this assertion mean anything: it is a property of the row now, not of
    the row's first minute.
    """
    graph = [
        {"headline": "One", "duration_ms": 1200},
        {"headline": "Two", "duration_ms": 3700},
        {"headline": "Three", "duration_ms": 2450},
        {"headline": "Four", "duration_ms": 8000},
    ]
    ends = scenes.boundaries_ms(graph)
    assert ends == [1200, 4900, 7350, 15350]

    stamps = [
        line.split(" --> ") for line in scenes.caption_track(graph).splitlines() if " --> " in line
    ]
    starts = [0, *ends[:-1]]
    assert [start for start, _ in stamps] == [scenes.stamp(ms) for ms in starts]
    assert [end for _, end in stamps] == [scenes.stamp(ms) for ms in ends]


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


def test_every_transition_the_model_may_name_is_one_the_timeline_can_draw() -> None:
    """`brand.TRANSITIONS` is written three times: here, as a `Literal`, and as `ENTER_MS` in JS.

    The first two are asserted equal in `schemas/social.py` at import time. Nothing bound either
    to the third, and the JS side fails *soft*: `ENTER_MS[scene.transition] ?? 0` reads an
    unknown transition as a zero-length window, which is a silent hard cut — a schema-valid
    treatment rendering as something nobody asked for, with no error anywhere.

    Same shape as the two tests above, and for the same reason: the renderer lives in JavaScript
    and a substring check on its source is the only guard available without a JS test runner.
    """
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[1] / "src/rascal/admin/static/timeline.js"
    ).read_text()
    opening = source.index("ENTER_MS = {") + len("ENTER_MS = {")
    table = source[opening : source.index("}", opening)]
    for transition in brand.TRANSITIONS:
        assert f"{transition}:" in table, f"{transition} is offered to the model but has no timing"
    # And the other direction: a timing for something the model can never name is dead code that
    # reads as a supported option. The slice starts *after* the opening brace so the first key
    # is parsed like every other one — it used to be swallowed by the `ENTER_MS = {` prefix,
    # which made `cut` the one entry this half could not see.
    named = {part.split(":")[0].strip() for part in table.split(",") if ":" in part}
    assert named, "the ENTER_MS table did not parse — this assertion would pass on nothing"
    assert named - set(brand.TRANSITIONS) == set(), (
        f"the timeline draws transitions the model cannot ask for: "
        f"{sorted(named - set(brand.TRANSITIONS))}"
    )
    assert set(brand.TRANSITIONS) - named == set(), "a transition has no timing"


def test_the_templates_and_palettes_the_model_may_name_are_all_drawable() -> None:
    from pathlib import Path

    source = (Path(__file__).resolve().parents[1] / "src/rascal/admin/static/cards.js").read_text()
    for palette in brand.PALETTES:
        assert f"{palette}: {{" in source, f"{palette} is offered to the model but not drawn"
    for template in brand.TEMPLATES:
        # **A quoted comparison, not a bare substring.** `drawCard` branches on
        # `template === "stat"` and `template === "prompt"`, so the name has to appear as a
        # string literal. A bare `in source` is satisfied by the word turning up in a comment —
        # which is how "announcement" would keep passing after the branch that draws it was
        # deleted, since the file's own prose names all four.
        assert f'"{template}"' in source, f"{template} is offered to the model but not drawn"


def test_social_renders_land_under_their_own_prefix() -> None:
    """Marketing output must never be mistaken for somebody's archive in a bucket listing."""
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[1] / "src/rascal/services/social/renderers.py"
    ).read_text()
    body = source.split("def store(")[1].split("\ndef ")[0]
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


async def test_the_eyebrow_is_stored_with_the_card_it_is_drawn_on(
    client: AsyncClient, session: AsyncSession, admin
) -> None:
    """Phase 142. The composer drew it on every published card and kept it nowhere."""
    created = await client.post(
        "/v1/social/assets",
        json={"headline": "A card", "eyebrow": "Also true"},
        headers=auth_headers(admin),
    )
    assert created.status_code == 201, created.text
    assert created.json()["eyebrow"] == "Also true"

    asset_id = created.json()["id"]
    updated = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"eyebrow": "Still true"},
        headers=auth_headers(admin),
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["eyebrow"] == "Still true"
