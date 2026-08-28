"""Recording a scene graph into a video.

**What this file used to guard and no longer has to.** Every test here was once about money:
a treatment cost roughly ten cents a second, so the guards that mattered were the ones that
refused before the first paid generation, the ledger that recorded what a half-finished job had
already bought, and the reaper for a job a deploy killed while it was spending. None of that is
reachable now — nothing is bought — and the tests went with the machinery.

**What replaced them is the closed sets and the derived captions.** The value of a typed scene
graph is entirely in what it refuses, so most of this file is refusals: an empty string where a
template goes, a duration outside its bounds, a total runtime no feed would play, a body that is
not a WebM. Phase 101 found a `palette: ""` that nothing rejected one level down from here, and
`shot_list` was a free `dict[str, Any]` until this phase, which made every enum inside it
decorative.

**The one assertion that is the whole point of the phase** is
`test_the_cue_boundaries_are_exactly_the_scene_boundaries` over in `test_social.py`. The track
was derived before this phase too — the difference is that it is now recomputed on every write
and is not a settable field, so a `PATCH` cannot leave a row whose captions describe the
previous video. `test_a_caller_cannot_write_a_caption_track_that_disagrees_with_the_cards` and
`test_editing_the_scenes_re_derives_the_track` are the two halves of that.
"""

from __future__ import annotations

import subprocess
import uuid
from pathlib import Path
from unittest import mock

import pytest
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy import select

from factories import make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.services.social import renders, scenes, transcode


@pytest.fixture
async def admin(session):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


#: A real four-scene graph with uneven durations, because even durations hide arithmetic bugs.
#: 1500 + 3200 + 2000 + 4300 = 11000, comfortably inside the treatment bounds.
SCENES = [
    {
        "template": "quote",
        "palette": "cream",
        "eyebrow": None,
        "headline": "Your camera roll is good at one thing.",
        "subhead": None,
        "duration_ms": 1500,
        "transition": "cut",
    },
    {
        "template": "stat",
        "palette": "terracotta",
        "eyebrow": "the problem",
        "headline": "4,812",
        "subhead": "photos, and not one of them says why.",
        "duration_ms": 3200,
        "transition": "fade",
    },
    {
        "template": "quote",
        "palette": "periwinkle",
        "eyebrow": None,
        "headline": "A photo with the question that made you take it is a story.",
        "subhead": None,
        "duration_ms": 2000,
        "transition": "rise",
    },
    {
        "template": "announcement",
        "palette": "ink",
        "eyebrow": None,
        "headline": "Pocket Chronicle",
        "subhead": "One question a day about your kid.",
        "duration_ms": 4300,
        "transition": "fade",
    },
]

TREATMENT = {"scenes": SCENES}


async def _asset(client: AsyncClient, admin, **extra) -> str:
    body = {"headline": "a treatment", "alt_text": "A card.", "format": "video", **extra}
    created = await client.post("/v1/social/assets", json=body, headers=auth_headers(admin))
    assert created.status_code == 201, created.text
    return created.json()["id"]


def _scene(**overrides) -> dict:
    return {**SCENES[0], **overrides}


@pytest.fixture
def bucket():
    """A real bucket, so the store and the read are real."""
    from rascal.services import s3

    settings = get_settings()
    s3.get_s3_client.cache_clear()
    with mock_aws():
        s3.get_s3_client().create_bucket(
            Bucket=settings.s3_bucket,
            CreateBucketConfiguration={"LocationConstraint": settings.s3_region},
        )
        yield settings.s3_bucket
    s3.get_s3_client.cache_clear()


def _webm(seconds: float | None = None, width: int = 240, height: int = 426) -> bytes:
    """A real VP9 WebM, built by the same ffmpeg the transcoder uses.

    Small deliberately — the assertions are about codec, pixel format, duration and stream
    count, none of which need 1080x1920, and a full-size encode would put seconds on every run.

    **Defaults to the length of `TREATMENT`, because the route now checks that.** `record()`
    refuses a film materially shorter than the scene graph — that is the server half of the
    backgrounded-tab guard — so a fixture of a convenient 1.0s against an 11.0s treatment is a
    fixture every byte-path test would be refused for. Pass `seconds` only where the length is
    the thing under test.
    """
    if seconds is None:
        seconds = scenes.total_ms(SCENES) / 1000
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory) / "in.webm"
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"color=c=0xC05A2B:s={width}x{height}:r=30:d={seconds}",
                "-c:v",
                "libvpx-vp9",
                "-b:v",
                "300k",
                str(out),
            ],
            check=True,
            capture_output=True,
        )
        return out.read_bytes()


needs_ffmpeg = pytest.mark.skipif(not transcode.available(), reason="ffmpeg is not installed")


#: Two scenes totalling 7300ms — inside the 6000..60000 treatment window.
#:
#: **Every refusal test below uses this pair, and that is not incidental.** Written with the
#: module's default 1500ms scene, a two-scene graph totals 4700ms and `VideoTreatment`'s runtime
#: bound refuses it *whatever else it contains* — so the test passes, asserts `422`, and would go
#: on passing with the thing it names deleted. That defect was found in one test here and then
#: found again, by a mutation run, in four more. Each of these now also asserts the **field** the
#: refusal names, which is what distinguishes "refused for the reason this test is about" from
#: "refused at all".
def _pair(**overrides) -> list[dict]:
    return [_scene(duration_ms=3000, **overrides), SCENES[3]]


# --- The closed sets, which are the whole value of a typed graph -------------------------------


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("template", ""),
        ("template", "collage"),
        ("palette", ""),
        ("palette", "chartreuse"),
        ("transition", ""),
        ("transition", "swipe"),
    ],
)
async def test_a_scene_cannot_name_something_the_renderer_cannot_draw(
    client: AsyncClient, admin, field: str, value: str
) -> None:
    """The phase 101 defect, one level up.

    `models/social.py` keeps these as plain text because the renderer that has to know them is
    in JavaScript, so a Postgres CHECK would be a second list to keep in step — which makes the
    `Literal`s in `schemas/social.py` the only thing between the closed set and a card the
    browser cannot draw. The empty string is in here on its own account: it is what a `<select>`
    with no selection posts, and it is what phase 101 actually found in the database.
    """
    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": _pair(**{field: value})},
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == f"treatment.scenes.0.{field}", (
        "refused for the closed set, not for the runtime — see `_pair`"
    )


@pytest.mark.parametrize("duration", [0, 1199, 8001, 20_000])
async def test_a_scene_duration_outside_its_bounds_is_refused(
    client: AsyncClient, admin, duration: int
) -> None:
    """Both sides. Under about a second nothing on a card can be read; over eight it has stopped.

    Every value here is paired with a scene long enough that the *treatment* bound is satisfied,
    so the only thing left to refuse it is `duration_ms` itself — `20_000` rather than `60_000`
    for the same reason.
    """
    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": [_scene(duration_ms=duration), SCENES[3], SCENES[1]]},
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "treatment.scenes.0.duration_ms"


@pytest.mark.parametrize("count", [0, 1, 11])
async def test_a_scene_count_outside_its_bounds_is_refused(
    client: AsyncClient, admin, count: int
) -> None:
    """One scene is a still with a fade on it; eleven is a video nobody watches to the end.

    A one-scene graph is deliberately given a duration that clears the treatment floor on its
    own: without that it is refused for its runtime and `MIN_SCENES` is never the reason, which
    is exactly the trap `_pair` exists to avoid. `min_length`/`max_length` on the list are field
    constraints, so they are reported against `treatment.scenes` rather than the whole object.
    """
    graph = [_scene(duration_ms=7000) for _ in range(count)]
    response = await client.post(
        "/v1/social/assets",
        json={"headline": "a treatment", "format": "video", "treatment": {"scenes": graph}},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "treatment.scenes"


@pytest.mark.parametrize(
    ("count", "each", "why"),
    [
        (2, 1200, "2400ms is under the floor"),
        (10, 8000, "80000ms is over the ceiling"),
    ],
)
async def test_a_total_runtime_outside_its_bounds_is_refused(
    client: AsyncClient, admin, count: int, each: int, why: str
) -> None:
    """**Every scene legal and the whole thing not.**

    This is the bound a per-field validator cannot see, and it is reachable with values that
    are individually fine — ten eight-second scenes is eighty seconds, which no feed will play
    to the end, and every one of those scenes is inside its own limits.
    """
    graph = [_scene(duration_ms=each) for _ in range(count)]
    response = await client.post(
        "/v1/social/assets",
        json={"headline": "a treatment", "format": "video", "treatment": {"scenes": graph}},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, why
    message = response.json()["error"]["message"]
    # The actual total, not just the letters "ms" — which "…8000ms and 60000ms…" would satisfy
    # while saying nothing about what was sent.
    assert f"total {count * each}ms" in message, message
    assert response.json()["error"]["field"] == "treatment"


async def test_copy_longer_than_the_renderer_can_draw_is_refused(
    client: AsyncClient, admin
) -> None:
    """`cards.js` shrinks type to fit and then stops at a floor, so past that it overflows.

    The limit is derived in `brand.py` from the tightest template's geometry rather than
    guessed, and it is enforced here and in the JSON schema Claude is constrained by — both
    sides, in the same commit, which is what the phase asked for.
    """
    from rascal.services.social import brand

    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": _pair(headline="x" * (brand.HEADLINE_MAX + 1))},
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "treatment.scenes.0.headline"

    # And the just-inside value is accepted, or a limit of zero would pass the assertion above.
    ok = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": _pair(headline="x" * brand.HEADLINE_MAX)},
        },
        headers=auth_headers(admin),
    )
    assert ok.status_code == 201, ok.text


async def test_a_scene_with_no_headline_is_refused_rather_than_silently_uncaptioned(
    client: AsyncClient, admin
) -> None:
    """A headline-less scene is a card holding a wordmark, and it produces no caption cue.

    Both are legal outcomes of a graph the schema permitted, and neither is one anybody asked
    for — so the schema does not permit it. `scenes.caption_track` still handles the case,
    because a derivation that assumes its input was validated is a derivation that breaks the
    first time somebody calls it from somewhere else.
    """
    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": _pair(headline="")},
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "treatment.scenes.0.headline"


# --- The captions are derived, and cannot be authored ------------------------------------------


async def test_saving_a_treatment_derives_the_caption_track_and_the_runtime(
    client: AsyncClient, admin
) -> None:
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    saved = (await client.get("/v1/social/assets", headers=auth_headers(admin))).json()["assets"][0]

    assert saved["caption_track"] == scenes.caption_track(SCENES)
    assert saved["duration_seconds"] == 11, "1500 + 3200 + 2000 + 4300, rounded to seconds"
    assert saved["treatment"] == TREATMENT
    assert saved["id"] == asset_id


async def test_a_caller_cannot_write_a_caption_track_that_disagrees_with_the_cards(
    client: AsyncClient, admin
) -> None:
    """**The defect this phase removed, asserted as a refusal.**

    Until phase 120 `caption_track` and `duration_seconds` were both editable fields on the
    asset, so a caller could save a track that said something the cards did not, or a runtime
    that was not the sum of the shots, and nothing anywhere compared them. Pydantic ignores an
    unknown key rather than erroring, so the assertion is that the value did not land — not
    that the request failed.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    patched = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={
            "caption_track": "WEBVTT\n\n1\n00:00:00.000 --> 09:59:59.000\nsomething else",
            "duration_seconds": 999,
        },
        headers=auth_headers(admin),
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["caption_track"] == scenes.caption_track(SCENES)
    assert patched.json()["duration_seconds"] == 11


async def test_editing_the_scenes_re_derives_the_track_rather_than_leaving_the_old_one(
    client: AsyncClient, admin
) -> None:
    """The invariant is not "derived on creation" — it is that the track is always these scenes'.

    An edit that changed the graph and left the previous track standing would be the same
    divergence arriving through a different door, and it is the shape a fix applied only to the
    create path actually leaves behind.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    shorter = {"scenes": [SCENES[0], {**SCENES[1], "headline": "9,001", "duration_ms": 5000}]}
    patched = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"treatment": shorter},
        headers=auth_headers(admin),
    )
    assert patched.status_code == 200, patched.text
    assert "9,001" in patched.json()["caption_track"]
    assert "4,812" not in patched.json()["caption_track"]
    assert patched.json()["duration_seconds"] == 7, "1500 + 5000"


# --- The route that takes bytes ----------------------------------------------------------------


async def test_a_post_with_no_treatment_is_refused(client: AsyncClient, admin) -> None:
    asset_id = await _asset(client, admin)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=b"\x1a\x45\xdf\xa3nope",
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422
    assert "no treatment" in response.json()["error"]["message"]


async def test_a_body_that_is_not_a_webm_is_refused_and_the_message_names_the_format(
    client: AsyncClient, admin, bucket
) -> None:
    """Same reasoning as the JPEG check on `/image`.

    A wrong format otherwise surfaces as an ffmpeg error naming neither the format nor the
    file, which sends the next person to read the wrong code.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=b"\xff\xd8\xff\xe0 this is a JPEG",
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422, response.text
    message = response.json()["error"]["message"]
    assert "WebM" in message and "EBML" in message
    assert "ff d8 ff e0" in message, "and it names what it actually got"


async def test_an_empty_body_says_so_rather_than_failing_downstream(
    client: AsyncClient, admin, bucket
) -> None:
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=b"",
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422
    assert "nothing to transcode" in response.json()["error"]["message"].lower()


async def test_a_recording_over_the_cap_is_refused_before_it_is_read_into_memory(
    client: AsyncClient, admin, bucket
) -> None:
    """**On the header, not on `len(data)`.**

    `request.body()` buffers the whole upload first, so a size check afterwards means the
    oversized request has already cost what it was going to cost. The assertion is that a
    declared length alone is enough — the body sent here is four bytes.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    # **Not `MAX + 1`.** At exactly one byte over, the reported size and the reported limit both
    # floor to 64 and the message says "64MB" twice — so an assertion on that string passes if
    # the two are swapped, or if the sentence is otherwise wrong. 200MB makes the two halves
    # distinguishable and the assertion falsifiable.
    over = 200 * 1024 * 1024
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=b"\x1a\x45\xdf\xa3",
        headers={
            **auth_headers(admin),
            "content-type": "video/webm",
            "content-length": str(over),
        },
    )
    assert response.status_code == 422, response.text
    message = response.json()["error"]["message"]
    assert "200MB" in message, "the refusal names what was actually sent"
    assert "limit is 64MB" in message, "and what the limit is"


async def test_a_recording_over_the_cap_is_refused_when_no_length_was_declared(
    client: AsyncClient, admin, bucket
) -> None:
    """**The header check is not the cap, and this is the request that proves it.**

    `Content-Length` is absent entirely on a chunked request — which is what `fetch()` sends when
    the body is a `ReadableStream` rather than a `Blob` — so the header branch is skipped, the
    body is buffered whole, and without a second check on `len(data)` the cap is advisory. The
    sibling card upload has always had that backstop; the video route was written with only the
    first half.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    # Comfortably over, so the reported size and the reported limit are different numbers —
    # at exactly one byte over, both floor to "64MB" and the assertion cannot tell them apart.
    oversized = b"\x1a\x45\xdf\xa3" + b"\x00" * int(transcode.MAX_RECORDING_BYTES * 1.5)

    async def chunks():
        yield oversized

    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=chunks(),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert "content-length" not in {k.lower() for k in response.request.headers}, (
        "the point of this test is a request with no declared length"
    )
    assert response.status_code == 422, response.text
    message = response.json()["error"]["message"]
    assert "96MB" in message, "the refusal names what actually arrived"
    assert "limit is 64MB" in message


# --- What actually comes out of ffmpeg ---------------------------------------------------------


@needs_ffmpeg
async def test_the_stored_file_is_h264_yuv420p_with_no_audio_and_the_right_length(
    client: AsyncClient, admin, session, bucket
) -> None:
    """**The properties a platform's decoder reads**, not the argv this code happens to run.

    Asserting on the command would only prove the command. `-pix_fmt yuv420p` in particular is
    one flag between "works" and "Instagram rejects it and QuickTime plays it black", and the
    only way to know it took effect is to probe the file.

    The duration is asserted against the *recording's* length rather than the scene graph's,
    because that is what the transcoder is responsible for — and it is worth asserting at all
    only because the re-encode recomputes timestamps. `MediaRecorder` writes an unknown duration
    into the WebM header, so the same assertion against a stream copy would read `N/A`.
    """
    from rascal.models import SocialRender
    from rascal.services import s3

    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 200, response.text
    row = response.json()

    assert row["status"] == "succeeded"
    assert row["provider"] == "canvas", "no vendor made these bytes"
    assert row["model"] == renders.RENDERER_VERSION
    assert row["scene_count"] == len(SCENES)
    assert row["render_key"].startswith("social/"), "never under children/"
    assert row["error"] is None

    stored = (
        s3.get_s3_client()
        .get_object(Bucket=get_settings().s3_bucket, Key=row["render_key"])["Body"]
        .read()
    )
    probed = transcode.probe(stored)
    assert probed["codec_name"] == "h264"
    assert probed["pix_fmt"] == "yuv420p"
    assert probed["audio_streams"] == 0, "a canvas capture has no audio and none is invented"
    expected = scenes.total_ms(SCENES) / 1000
    assert abs(probed["duration_seconds"] - expected) < 0.1, probed
    # Not only the container: a 240x426 input must come out at 240x426. An assertion that stopped
    # at the codec would pass against an encoder that silently rescaled every card.
    assert probed["width"] == 240 and probed["height"] == 426, probed

    # The post points at the file, and the row is the one attempt.
    saved = (await client.get("/v1/social/assets", headers=auth_headers(admin))).json()["assets"][0]
    assert saved["render_key"] == row["render_key"]
    assert saved["render_provider"] == "canvas"
    rows = (await session.execute(select(SocialRender))).scalars().all()
    assert len(rows) == 1


@needs_ffmpeg
async def test_a_success_costs_nothing_and_says_so(client: AsyncClient, admin, bucket) -> None:
    """Zero is the finding this phase exists to produce, so it is reported rather than omitted."""
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.json()["cost_cents"] == 0


async def test_ffmpeg_failing_writes_a_failed_row_with_the_reason_and_never_a_500(
    client: AsyncClient, admin, session, bucket, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failure is an attempt that happened, and it is recorded as one.

    The alternative is a button that reports an error and leaves no trace of having been
    pressed, which makes "it did nothing" and "it failed" the same event. The stderr tail
    reaches the row; the whole of stderr does not — `errors.py` forbids a stack trace and a
    paragraph of ffmpeg is one by another name.
    """
    from rascal.models import SocialRender

    real_run = subprocess.run

    def _failing_run(command, *args, **kwargs):
        # Only ffmpeg. Patching `subprocess.run` outright would also break `ffprobe` and
        # anything else the suite shells out to, and a test that fails for the wrong reason
        # is worse than one that does not run.
        if command and command[0] == "ffmpeg":
            return subprocess.CompletedProcess(
                command,
                1,
                stdout="",
                stderr="some noise\n[libvpx-vp9] failed to decode: corrupt frame\n",
            )
        return real_run(command, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", _failing_run)

    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=b"\x1a\x45\xdf\xa3 pretending to be a recording",
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422, "a readable refusal, never a 500"
    assert "corrupt frame" in response.json()["error"]["message"]

    row = (await session.execute(select(SocialRender))).scalars().one()
    assert row.status == "failed"
    assert "corrupt frame" in row.error
    assert "some noise" not in row.error, "the last line, not the whole of stderr"
    assert row.cost_cents == 0, "a failure is free too, and the ledger says so"
    assert row.render_key is None
    assert row.finished_at is not None


@needs_ffmpeg
async def test_a_recording_shorter_than_the_treatment_is_refused_and_recorded(
    client: AsyncClient, admin, session, bucket
) -> None:
    """**The server half of the backgrounded-tab guard, and the half that cannot be bypassed.**

    `cards.js` refuses to record in a hidden tab because `requestAnimationFrame` does not fire in
    one and the result is a file that is *silently short*. That guard is the browser promising.
    This is the server checking — and it holds against a tab the browser mis-detected, a
    `MediaRecorder` that dropped frames under load, and anything at all posting to this route.

    The refusal is a `failed` row like any other, because the attempt happened and produced
    bytes; they were simply not the video the treatment describes.
    """
    from rascal.models import SocialRender
    from rascal.services import s3

    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(seconds=4.0),  # against an 11.0s treatment
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422, response.text
    message = response.json()["error"]["message"]
    # **In order, not merely both present.** "The recording is 11.0s and the treatment is 4.0s"
    # contains the same two numbers and says the opposite thing.
    assert message.index("4.0s") < message.index("11.0s"), message
    assert "recording is 4.0s" in message and "treatment is 11.0s" in message, message
    assert "background" in message, "the message must name the likely cause, not just the numbers"

    row = (await session.execute(select(SocialRender))).scalars().one()
    assert row.status == "failed"
    assert row.render_key is None, "a short film must not become the post's film"
    assert row.cost_cents == 0

    # And nothing reached the bucket: the check runs before the store, not after it.
    listing = s3.get_s3_client().list_objects_v2(Bucket=get_settings().s3_bucket)
    assert listing.get("KeyCount", 0) == 0, listing


@needs_ffmpeg
@pytest.mark.parametrize(
    ("short_by", "refused"),
    [(0.10, False), (0.20, False), (0.50, True), (1.00, True)],
)
async def test_the_length_tolerance_sits_where_the_constant_says_it_does(
    client: AsyncClient, admin, bucket, short_by: float, refused: bool
) -> None:
    """**Both sides of `DURATION_TOLERANCE_SECONDS`, which nothing else pins.**

    The two tests around this one bracket the constant at (0.0, 7.0): a 4.0s recording against
    an 11.0s treatment keeps being refused for any tolerance under seven seconds, and the
    one-frame-long case is *longer* than expected so the one-sided comparison never consults the
    tolerance at all. Measured: with those two alone, 0.0, 5.0 and 6.9 all pass.

    These four points bracket it into (0.2, 0.5), which is where 0.25 lives — close enough that
    moving the constant in either direction fails, and far enough from the frame-length wobble
    of a real encode not to be flaky.
    """
    from rascal.services.social import renders as renders_module

    assert 0.2 < renders_module.DURATION_TOLERANCE_SECONDS < 0.5, (
        "this test brackets the constant; move them together or not at all"
    )
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(seconds=scenes.total_ms(SCENES) / 1000 - short_by),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == (422 if refused else 200), response.text


@needs_ffmpeg
async def test_a_recording_one_frame_long_is_accepted_because_a_correct_one_always_is(
    client: AsyncClient, admin, bucket
) -> None:
    """The control. A correct recording measures **one frame long**, every time.

    The console draws one extra `requestAnimationFrame` after the final frame so the compositor
    samples it, which puts every real output about 33ms over the graph. A length check with no
    tolerance — or one that compared for equality — would reject every genuine render, and this
    is the assertion that would have caught that before it shipped.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    over = scenes.total_ms(SCENES) / 1000 + 0.034
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(seconds=over),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "succeeded"


# --- Reading it back ---------------------------------------------------------------------------


async def test_status_is_null_before_anything_has_been_recorded(client: AsyncClient, admin) -> None:
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.get(f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin))
    assert response.status_code == 200, response.text
    assert response.json()["render"] is None


@needs_ffmpeg
async def test_the_file_route_hands_back_a_url_for_the_thing_that_was_made(
    client: AsyncClient, admin, bucket
) -> None:
    """The console's *Open the film* button called this route and it did not exist.

    Nothing caught it: `admin.js` has no test runner, the route was never in an authorization
    sweep because there was no route, and the button only appears after a render succeeds —
    which, on a path that cost real money and had never succeeded end to end in production,
    was never.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    render = (
        await client.post(
            f"/v1/social/assets/{asset_id}/video",
            content=_webm(),
            headers={**auth_headers(admin), "content-type": "video/webm"},
        )
    ).json()

    response = await client.get(
        f"/v1/social/renders/{render['id']}/file", headers=auth_headers(admin)
    )
    assert response.status_code == 200, response.text
    assert render["render_key"] in response.json()["url"]
    assert response.json()["expires_in"] > 0


async def test_a_render_that_produced_no_file_is_a_404_carrying_the_reason(
    client: AsyncClient, admin, session
) -> None:
    """*This render has no file* and *here is a URL that will not resolve* are different answers."""
    from rascal.models import SocialAsset, SocialRender

    asset = SocialAsset(headline="failed one", format="video")
    session.add(asset)
    await session.flush()
    render = SocialRender(
        asset_id=asset.id,
        status="failed",
        provider=renders.PROVIDER,
        model=renders.RENDERER_VERSION,
        scene_count=4,
        error="ffmpeg failed (exit 1): corrupt frame",
    )
    session.add(render)
    await session.commit()

    response = await client.get(f"/v1/social/renders/{render.id}/file", headers=auth_headers(admin))
    assert response.status_code == 404
    assert "corrupt frame" in response.json()["error"]["message"]


async def test_an_unknown_render_is_a_404(client: AsyncClient, admin) -> None:
    response = await client.get(
        f"/v1/social/renders/{uuid.uuid4()}/file", headers=auth_headers(admin)
    )
    assert response.status_code == 404


# --- The transcoder on its own -----------------------------------------------------------------


def test_a_body_that_is_not_ebml_is_refused_by_the_transcoder_itself() -> None:
    """Checked in the module as well as at the route, because the route is not its only caller."""
    with pytest.raises(transcode.TranscodeError, match="not a WebM"):
        transcode.to_mp4(b"RIFF....AVI ")


@needs_ffmpeg
def test_the_encoder_recomputes_the_duration_rather_than_trusting_the_header() -> None:
    """**`MediaRecorder` writes an unknown duration into the WebM header**, and this is why.

    A stream copy would carry that straight through into the MP4 and everything downstream —
    a platform's own transcoder, a `<video>` element's scrubber, this suite — would read
    nothing. The re-encode derives the duration from the frames, so it is a number.
    """
    out = transcode.to_mp4(_webm(seconds=1.5))
    probed = transcode.probe(out)
    assert probed["duration_seconds"] is not None
    assert abs(probed["duration_seconds"] - 1.5) < 0.1, probed


def test_the_encoder_pins_every_flag_it_documents_as_load_bearing() -> None:
    """A readable check on the argv, beside the probe rather than instead of it.

    The probe proves the output; this names *why* each flag is in the command, so removing one
    to "simplify" fails a test whose message says what it costs.

    **It reads the command `to_mp4` actually builds, not the `_ENCODE` tuple.** Asserting on
    `_ENCODE` alone missed `-fflags +genpts`, which is spliced in ahead of `-i` because it is a
    *demuxer* option — and which the module documents as the difference between a card that
    starts on frame one and one whose first fraction of a second is trimmed off the front. A
    test that cannot see the flag cannot protect it.
    """
    seen: list[list[str]] = []

    def _capture(command, *args, **kwargs):
        seen.append(list(command))
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="captured\n")

    with mock.patch.object(subprocess, "run", _capture), pytest.raises(transcode.TranscodeError):
        transcode.to_mp4(b"\x1a\x45\xdf\xa3 not really a webm")

    argv = seen[0]
    assert argv[0] == "ffmpeg"
    assert "libx264" in argv, "H.264 is what a platform accepts; VP9 in WebM is not"
    assert "yuv420p" in argv, "4:4:4 H.264 is rejected by Instagram and misrendered by QuickTime"
    assert "-an" in argv, "a canvas capture has no audio; encoding one is bytes for nothing"
    assert "+faststart" in argv, "the moov atom belongs at the front for a file served over HTTP"
    assert "+genpts" in argv, "MediaRecorder can write a first cluster with no timestamp"
    assert "-nostdin" in argv, (
        "ffmpeg reads the console for interactive keys; a copy of it in a web server is a way "
        "to lose bytes that belong to something else"
    )
    assert argv[argv.index("-profile:v") + 1] == "high"
    assert "-y" in argv, "the output path is ours and pre-exists in no case worth prompting about"
    assert argv.index("+genpts") < argv.index("-i"), (
        "-fflags is a demuxer option: after -i it applies to the muxer and means nothing"
    )
    assert argv[argv.index("-r") + 1] == "30", "a VFR mp4 drifts against the caption track"


@needs_ffmpeg
async def test_a_storage_failure_is_recorded_as_an_attempt_rather_than_becoming_a_500(
    client: AsyncClient, admin, session, bucket, caplog, monkeypatch: pytest.MonkeyPatch
) -> None:
    """**The transcode is not the only thing in that `try`.**

    `record()` wraps the encode *and* the bucket write, and caught only `TranscodeError` — so a
    boto3 error raised straight past it, the row was never added, `get_session` rolled the
    request back, and the operator got a 500 for a storage outage from a function whose docstring
    promises the attempt is recorded either way.

    The error on the row is the exception's **type**, never its text: a boto3 `ClientError`
    stringifies to the whole request context including the bucket and the endpoint, which
    `errors.py` forbids putting on a row for the same reason it forbids a raw SQL error.

    The sentence names no stage, deliberately. The same handler catches an `OSError` writing the
    temp file, so "while storing the recording" would be confidently wrong half the time — and a
    wrong location on a row somebody reads at 2am is worse than no location.
    """
    from rascal.models import SocialRender
    from rascal.services.social import renders as renders_module

    def _no_bucket(*args, **kwargs):
        raise RuntimeError("An error occurred (NoSuchBucket) when calling PutObject: s3://secret")

    monkeypatch.setattr(renders_module, "store", _no_bucket)
    caplog.set_level("WARNING", logger="rascal.social.renders")

    asset_id = await _asset(client, admin, treatment=TREATMENT)
    response = await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    assert response.status_code == 422, "a readable refusal, never a 500"

    # **The traceback has to exist somewhere**, which is the whole argument for the broad
    # `except`: an unexpected error is a defect being reported to an operator as a validation
    # failure, and without `exc_info` the stack would exist nowhere at all.
    assert any(
        record.levelname == "ERROR" and record.exc_info
        for record in caplog.records
        if record.name == "rascal.social.renders"
    ), [(r.levelname, r.name, bool(r.exc_info)) for r in caplog.records]

    row = (await session.execute(select(SocialRender))).scalars().one()
    assert row.status == "failed"
    assert row.error == "RuntimeError while producing the file."
    assert "NoSuchBucket" not in row.error and "s3://" not in row.error
    assert row.cost_cents == 0
    assert row.render_key is None


# --- The schema Claude is constrained by -------------------------------------------------------


def test_no_schema_carries_a_keyword_structured_outputs_rejects() -> None:
    """**The failure mode this guards is a 400 in production, not a red test.**

    `output_config.format` accepts a small subset of JSON Schema: `minItems` above 1, `maxItems`,
    `minLength`, `maxLength`, `minimum`, `maximum`, `pattern` and friends are all refused, as a
    400 at request time. The official SDKs strip them and validate client-side; this service
    talks to `/v1/messages` with raw `httpx`, so nothing strips them here.

    Measured against the live API on Aug 25, 2026, one refusal at a time — *"For 'array' type,
    'minItems' values other than 0 or 1 are not supported"*, then *"property 'maxItems' is not
    supported"*. Both were written into the schema first, because both are the obvious thing to
    write when the Pydantic model beside it has them.

    So the bound belongs in `treatment_instruction` and in `VideoTreatment`, and this is what
    stops somebody helpfully putting it back. It walks the schemas rather than naming fields,
    because a new property added later is exactly the case a field list would miss.
    """
    from rascal.services.social import director

    offenders: list[str] = []

    def walk(node: object, path: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key in director.UNSUPPORTED_SCHEMA_KEYWORDS:
                    offenders.append(f"{path}.{key} = {value!r}")
                walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{path}[{index}]")

    assert len(director.UNSUPPORTED_SCHEMA_KEYWORDS) >= 6, (
        "emptying the list would make every assertion below vacuous"
    )
    assert {
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
    } <= director.UNSUPPORTED_SCHEMA_KEYWORDS

    walk(director.TREATMENT_SCHEMA, "TREATMENT_SCHEMA")
    walk(director.CONCEPT_SCHEMA, "CONCEPT_SCHEMA")
    assert not offenders, (
        "structured outputs rejects these with a 400 at request time, and nothing in this "
        f"service strips them before the POST: {offenders}. State the bound in the "
        "instruction and enforce it in schemas/social.py instead."
    )


def test_the_schema_still_carries_the_closed_sets_that_do_the_real_work() -> None:
    """The control for the test above, and it is not decoration.

    A schema stripped of every constraint would pass that test perfectly. `enum` **is**
    supported, it is the keyword that makes a template or a transition a closed set, and losing
    it would mean the model could name a card the browser cannot draw — while the guard above
    stayed green.
    """
    from rascal.services.social import brand, director

    scene = director.TREATMENT_SCHEMA["properties"]["scenes"]["items"]["properties"]
    assert scene["template"]["enum"] == list(brand.TEMPLATES)
    assert scene["palette"]["enum"] == list(brand.PALETTES)
    assert scene["transition"]["enum"] == list(brand.TRANSITIONS)
    assert director.TREATMENT_SCHEMA["additionalProperties"] is False
    assert scene.keys() >= {"headline", "duration_ms"}


def test_the_copy_bounds_reach_the_model_as_prose_since_they_cannot_reach_it_as_schema() -> None:
    """`brand.py` says the limits are enforced on both sides. On the model's side they are words.

    That is a real constraint rather than an oversight — see the test above — but a number
    written into a description drifts from the constant silently, which is the one failure mode
    prose has and a keyword does not.
    """
    from rascal.services.social import brand, director

    scene = director.TREATMENT_SCHEMA["properties"]["scenes"]["items"]["properties"]
    assert str(brand.HEADLINE_MAX) in scene["headline"]["description"]
    assert str(brand.SUBHEAD_MAX) in scene["subhead"]["description"]
    assert str(brand.EYEBROW_MAX) in scene["eyebrow"]["description"]
    assert str(brand.SCENE_MIN_MS) in scene["duration_ms"]["description"]
    assert str(brand.SCENE_MAX_MS) in scene["duration_ms"]["description"]

    # **`f"{MIN}ms"`, not `str(MIN)`.** 6000 is a substring of 60000, so a bare containment
    # check for the floor is satisfied by the ceiling and the test cannot tell them apart.
    instruction = director.treatment_instruction("a brief", 20)
    assert f"{brand.TREATMENT_MIN_MS}ms" in instruction
    assert f"{brand.TREATMENT_MAX_MS}ms" in instruction


# --- The scene copy cannot break the track it is interpolated into -----------------------------


@pytest.mark.parametrize(
    "headline",
    ["Two lines\n\nand a gap", "One\nline break", "\n\nleading gap", "trailing gap\n\n"],
)
async def test_a_newline_in_the_copy_cannot_split_its_own_cue(
    client: AsyncClient, admin, headline: str
) -> None:
    """**A blank line terminates a WebVTT cue**, and scene copy is interpolated straight in.

    Left alone, a headline containing one splits its own cue and orphans the rest of the
    sentence into a fragment the parser reads as a timing line. The card renderer wraps text
    itself and has no use for an authored break either, so the copy is flattened at the schema
    boundary — once, rather than in every consumer.
    """
    # 3000 + 4300 = 7300ms, over the treatment floor. Two scenes so the cue count is a number
    # the assertion below can be exact about.
    asset_id = await _asset(
        client,
        admin,
        treatment={"scenes": _pair(headline=headline)},
    )
    saved = (await client.get("/v1/social/assets", headers=auth_headers(admin))).json()["assets"][0]
    assert saved["id"] == asset_id

    track = saved["caption_track"]
    assert "\n\n\n" not in track, "a doubled blank line is a cue the parser cannot place"
    # Exactly two cues, one per scene, however many line breaks the copy tried to add.
    assert track.count(" --> ") == 2
    for scene in saved["treatment"]["scenes"]:
        assert "\n" not in scene["headline"]


@pytest.mark.parametrize("headline", ["   ", "\t\n ", "\u00a0", ""])
async def test_a_whitespace_only_headline_is_refused_rather_than_silently_uncaptioned(
    client: AsyncClient, admin, headline: str
) -> None:
    """`min_length=1` accepts `"   "`, and `caption_track` strips before it tests.

    So such a scene produced no cue while still consuming its slice of the clock — silently,
    which is the exact outcome the comment on `headline` claims cannot happen. The collapse runs
    before the length check, so the field is `""` by the time `min_length` sees it.

    **The durations are over the treatment floor on purpose.** Written with the module's default
    1500ms scene, the pair totals 4700ms and the request is refused by the *runtime* bound — so
    the test passed while proving nothing about headlines, which is exactly what a break-test of
    the validator revealed.
    """
    response = await client.post(
        "/v1/social/assets",
        json={
            "headline": "a treatment",
            "format": "video",
            "treatment": {"scenes": _pair(headline=headline)},
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    # **The exact path, not just "treatment".** The runtime bound refuses with `field:
    # "treatment"`, so asserting on that alone is what let the first version of this test pass
    # for the wrong reason — it was being refused for its durations, not its headline.
    assert response.json()["error"]["field"] == "treatment.scenes.0.headline"


async def test_a_scene_that_survives_validation_always_has_a_headline_that_is_a_string(
    client: AsyncClient, admin
) -> None:
    """The control for the test above: it asserts what a *surviving* scene looks like.

    That test only ever sees refusals, so on its own it cannot tell a validator that rejects
    correctly from one that also mangles the copy it accepts. This one pins the accepted case —
    collapsed, still a `str`, still producing a cue.

    **Stated honestly after break-testing it**: the `after`-mode-returning-`None` mistake this
    phase actually made is caught by the whitespace test above, not by this one, because
    `"  spaced   out  "` collapses to something non-empty and never reaches the `or None`. What
    this test uniquely covers is a collapse that mangles or drops accepted copy.
    """
    asset_id = await _asset(
        client,
        admin,
        treatment={
            "scenes": [
                _scene(headline="  spaced   out  ", subhead="   ", eyebrow="  ", duration_ms=3000),
                SCENES[3],
            ]
        },
    )
    saved = (await client.get("/v1/social/assets", headers=auth_headers(admin))).json()["assets"][0]
    assert saved["id"] == asset_id
    first = saved["treatment"]["scenes"][0]
    assert first["headline"] == "spaced out", "collapsed, not nulled"
    assert isinstance(first["headline"], str)
    assert not first["subhead"] and not first["eyebrow"], "emptied optionals read as absent"
    assert saved["caption_track"].count(" --> ") == 2


async def test_clearing_the_treatment_clears_everything_derived_from_it(
    client: AsyncClient, admin
) -> None:
    """`"treatment": null` is a real operation and used to be silently ignored with a 200.

    A partial update makes *absent* and *explicitly null* both arrive as `None`, so the clear
    did nothing. Worse than doing nothing: leaving a caption track standing beside no scenes is
    the divergence the derivation exists to prevent, arriving by the one door left open.
    """
    asset_id = await _asset(client, admin, treatment=TREATMENT)
    cleared = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"treatment": None},
        headers=auth_headers(admin),
    )
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["treatment"] is None
    assert cleared.json()["caption_track"] is None
    assert cleared.json()["duration_seconds"] is None

    # And an omitted field still means "leave it alone", which is the other half.
    restored = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"treatment": TREATMENT},
        headers=auth_headers(admin),
    )
    assert restored.status_code == 200
    untouched = await client.patch(
        f"/v1/social/assets/{asset_id}",
        json={"headline": "renamed"},
        headers=auth_headers(admin),
    )
    assert untouched.json()["treatment"] == TREATMENT
    assert untouched.json()["caption_track"] == scenes.caption_track(SCENES)


# --- The archive is not reachable from here ----------------------------------------------------


@needs_ffmpeg
async def test_a_render_never_writes_under_the_archive_prefix(
    client: AsyncClient, admin, bucket
) -> None:
    """`social/`, never `children/`. Marketing output must not be mistaken for somebody's archive
    by a lifecycle rule, a deletion sweep, or a person reading a bucket listing."""
    from rascal.services import s3

    asset_id = await _asset(client, admin, treatment=TREATMENT)
    await client.post(
        f"/v1/social/assets/{asset_id}/video",
        content=_webm(),
        headers={**auth_headers(admin), "content-type": "video/webm"},
    )
    listing = s3.get_s3_client().list_objects_v2(Bucket=get_settings().s3_bucket)
    keys = [item["Key"] for item in listing.get("Contents", [])]
    assert keys, "the recording should have been stored"
    assert all(key.startswith("social/") for key in keys), keys
