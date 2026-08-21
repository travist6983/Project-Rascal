"""Rendering a shot list into a video.

The guards get the most attention here on purpose: every one of them exists to stop the job
spending real money on a treatment it cannot finish, and a guard with no test is a guard that
quietly stops guarding.
"""

from __future__ import annotations

import datetime as dt
import subprocess
import uuid
from pathlib import Path

import httpx
import pytest
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy import select

from factories import make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.services.social import gemini, renders, stitch


@pytest.fixture
async def admin(session):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture(autouse=True)
def _no_video_key(monkeypatch: pytest.MonkeyPatch):
    """The suite must never be able to reach Google, even with a real key in the environment.

    Belt and braces beside the mocked transports: a render costs money, and a test that
    accidentally generates seven clips is an expensive way to learn that.
    """
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    yield


SHOTS = {
    "shots": [
        {
            "visual": "A thumb scrolling a photo grid.",
            "seconds": 4,
            "voiceover": "Your camera roll is good at one thing.",
            "on_screen_text": "4,812 photos",
        },
        {"visual": "The scroll slows.", "seconds": 4, "voiceover": "Keeping."},
    ]
}


async def _asset(client: AsyncClient, admin, **extra) -> str:
    body = {"headline": "shot list post", "alt_text": "A card.", "format": "video", **extra}
    created = await client.post("/v1/social/assets", json=body, headers=auth_headers(admin))
    assert created.status_code == 201, created.text
    return created.json()["id"]


def _settings(**overrides):
    base = {"gemini_api_key": "AIza-fake", "gemini_video_cents_per_second": 10}
    return get_settings().model_copy(update={**base, **overrides})


# --- The prompt -------------------------------------------------------------------------------


def test_a_shot_becomes_direction_with_its_caption_and_line_quoted() -> None:
    prompt = gemini.shot_prompt(SHOTS["shots"][0])
    assert '"4,812 photos"' in prompt, "the on-screen text must be quoted, not paraphrased"
    assert '"Your camera roll is good at one thing."' in prompt
    assert "about 4 seconds" in prompt


def test_every_prompt_refuses_identifiable_faces() -> None:
    """The product is about children. The safest footage for it contains no faces at all.

    Asserted rather than trusted to the treatment: Claude writes shot lists that happen to
    avoid faces, and "happens to" is not a safety property.
    """
    for shot in [*SHOTS["shots"], {"visual": "anything at all"}]:
        assert "identifiable faces" in gemini.shot_prompt(shot)


def test_a_shot_with_no_voiceover_asks_for_silence_rather_than_improvising() -> None:
    assert "No dialogue." in gemini.shot_prompt({"visual": "A still card."})


# --- The vendor edge --------------------------------------------------------------------------


async def test_a_200_with_no_video_in_it_is_an_error_not_an_empty_clip() -> None:
    """Every Gemini video model is preview, so the response shape moving is a question of when.

    This module has never seen a real 200 — the video models have a free-tier quota of zero —
    which is exactly the circumstance where an unrecognised shape must be loud.
    """
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json={"steps": []}))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(RuntimeError, match="no video in it"):
            await gemini.render_shot(client, _settings(), SHOTS["shots"][0])


async def test_a_429_is_reported_as_billing_rather_than_rate_limiting() -> None:
    """The first thing a working key does here is fail, and Google's wording misdirects."""
    transport = httpx.MockTransport(
        lambda request: httpx.Response(429, json={"error": {"message": "quota"}})
    )
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(RuntimeError) as caught:
            await gemini.render_shot(client, _settings(), SHOTS["shots"][0])
    assert "billing" in str(caught.value)
    assert "free-tier quota of zero" in str(caught.value)


async def test_an_unconfigured_key_raises_lookup_error() -> None:
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json={}))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(LookupError):
            await gemini.render_shot(client, _settings(gemini_api_key=None), SHOTS["shots"][0])


async def test_the_key_never_reaches_the_error_message() -> None:
    transport = httpx.MockTransport(lambda request: httpx.Response(500, json={"error": {}}))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(RuntimeError) as caught:
            await gemini.render_shot(
                client, _settings(gemini_api_key="SENTINEL-KEY"), SHOTS["shots"][0]
            )
    assert "SENTINEL-KEY" not in str(caught.value)


# --- The guards, which all run before any money is spent --------------------------------------


async def test_a_post_with_no_shot_list_is_refused(client: AsyncClient, admin) -> None:
    asset_id = await _asset(client, admin)
    response = await client.post(f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin))
    assert response.status_code == 422
    assert "no shot list" in response.json()["error"]["message"]


async def test_an_unconfigured_key_names_the_billing_trap(client: AsyncClient, app, admin) -> None:
    asset_id = await _asset(client, admin, shot_list=SHOTS)
    from rascal.config import get_settings as real_settings

    app.dependency_overrides[real_settings] = lambda: _settings(gemini_api_key=None)
    try:
        response = await client.post(
            f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin)
        )
    finally:
        app.dependency_overrides.pop(real_settings, None)
    assert response.status_code == 422
    assert "free-tier quota of zero" in response.json()["error"]["message"]


async def test_a_second_render_is_refused_while_one_is_running(
    client: AsyncClient, session, app, admin
) -> None:
    """Starting a second would pay for the same seven clips twice.

    A key is supplied here on purpose: the guards run in order, so without one this would be
    refused for the wrong reason and the test would pass while proving nothing.
    """
    from rascal.config import get_settings as real_settings
    from rascal.models import SocialRender

    # A zero-arg callable: FastAPI reads `_settings(**overrides)`'s signature and would ask
    # for a request field called `overrides`.
    app.dependency_overrides[real_settings] = lambda: _settings()
    asset_id = await _asset(client, admin, shot_list=SHOTS)
    session.add(
        SocialRender(
            asset_id=uuid.UUID(asset_id),
            status="running",
            provider=renders.PROVIDER,
            model="m",
            shots_total=2,
        )
    )
    await session.commit()
    try:
        response = await client.post(
            f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin)
        )
    finally:
        app.dependency_overrides.pop(real_settings, None)
    assert response.status_code == 422
    assert "already running" in response.json()["error"]["message"]


async def test_status_is_null_before_anything_has_been_rendered(client: AsyncClient, admin) -> None:
    asset_id = await _asset(client, admin, shot_list=SHOTS)
    response = await client.get(f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin))
    assert response.status_code == 200
    assert response.json()["render"] is None


# --- The whole job, with only the vendor call replaced ---------------------------------------


@pytest.fixture
def bucket():
    """A real bucket, so the job's stores and reads are real."""
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


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
async def test_the_whole_job_runs_end_to_end_with_only_the_vendor_replaced(
    client: AsyncClient, session, admin, bucket, tmp_path: Path, monkeypatch
) -> None:
    """Everything except the HTTP call to Google: real ffmpeg, real bucket, real row.

    The vendor is the one thing that cannot be exercised — the video models have a free-tier
    quota of zero — so it is replaced with clips this test generates itself. Everything after
    it is the shipping code path.
    """
    from rascal.models import SocialAsset, SocialRender
    from rascal.services.social import gemini, renders

    asset = SocialAsset(
        headline="camera roll",
        alt_text="A card.",
        format="video",
        shot_list=SHOTS,
        created_by_user_id=admin.id,
    )
    session.add(asset)
    await session.commit()

    made = [_clip(tmp_path, i + 1, seconds=2) for i in range(len(SHOTS["shots"]))]
    calls: list[str] = []

    async def fake_render_shot(client_, settings_, shot):
        calls.append(gemini.shot_prompt(shot))
        return made[len(calls) - 1]

    monkeypatch.setattr(gemini, "render_shot", fake_render_shot)

    render = SocialRender(
        asset_id=asset.id,
        status="queued",
        provider=renders.PROVIDER,
        model="test-model",
        shots_total=len(SHOTS["shots"]),
    )
    session.add(render)
    await session.commit()
    render_id = render.id

    await renders.run(render_id)

    await session.refresh(render)
    await session.refresh(asset)
    assert render.status == "succeeded", render.error
    assert len(render.clip_keys) == len(SHOTS["shots"]), "a clip key per shot"
    assert all(key.startswith("social/") for key in render.clip_keys), "never under children/"
    assert render.render_key, "the joined file was stored"
    assert render.finished_at is not None
    # 8 seconds of treatment at ten cents a second, recorded as it was spent.
    assert render.cost_cents == 80
    # The post now points at the finished film.
    assert asset.render_key == render.render_key
    assert asset.render_provider == renders.PROVIDER
    # Every shot was actually sent, as direction rather than as raw JSON.
    assert len(calls) == len(SHOTS["shots"])
    assert "identifiable faces" in calls[0]


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
async def test_a_vendor_failure_midway_keeps_the_clips_it_already_paid_for(
    client: AsyncClient, session, admin, bucket, tmp_path: Path, monkeypatch
) -> None:
    """The money is spent at generation. A job that dies on shot two must say what shot one cost."""
    from rascal.models import SocialAsset, SocialRender
    from rascal.services.social import gemini, renders

    asset = SocialAsset(headline="partial", alt_text="A card.", format="video", shot_list=SHOTS)
    session.add(asset)
    await session.commit()

    good = _clip(tmp_path, 1, seconds=2)
    seen = {"n": 0}

    async def flaky(client_, settings_, shot):
        seen["n"] += 1
        if seen["n"] == 1:
            return good
        raise RuntimeError("429 from Gemini. Billing is not enabled.")

    monkeypatch.setattr(gemini, "render_shot", flaky)

    render = SocialRender(
        asset_id=asset.id,
        status="queued",
        provider=renders.PROVIDER,
        model="test-model",
        shots_total=2,
    )
    session.add(render)
    await session.commit()

    await renders.run(render.id)
    await session.refresh(render)
    await session.refresh(asset)

    assert render.status == "failed"
    assert "Billing is not enabled" in render.error
    assert len(render.clip_keys) == 1, "the clip it bought is still recorded"
    assert render.cost_cents == 40, "and so is what that clip cost"
    assert render.render_key is None
    assert asset.render_key is None, "a failed job must not point the post at nothing"


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
async def test_a_failed_commit_does_not_leave_the_row_running_forever(
    client: AsyncClient, session, admin, bucket, tmp_path: Path, monkeypatch
) -> None:
    """The poisoned-session path, which is the one with teeth.

    If the per-clip `commit` is what fails, SQLAlchemy deactivates the transaction and every
    later write raises `PendingRollbackError` — including the one that records the failure. A
    detached background task then raises into nothing and the row stays `running`, which
    `preflight` refuses on forever. `_finish` rolls back first for exactly this.
    """
    from rascal.models import SocialAsset, SocialRender
    from rascal.services.social import gemini, renders

    asset = SocialAsset(headline="poisoned", format="video", shot_list=SHOTS)
    session.add(asset)
    await session.commit()

    async def fine(client_, settings_, shot):
        return _clip(tmp_path, 1, seconds=2)

    monkeypatch.setattr(gemini, "render_shot", fine)
    # An integer overflow on `cost_cents` — reachable through the API, since `shot_list` is
    # free-form JSON — makes the commit itself fail rather than the generation.
    monkeypatch.setattr(renders, "store", lambda *a, **k: "social/x.mp4", raising=False)

    render = SocialRender(
        asset_id=asset.id,
        status="queued",
        provider=renders.PROVIDER,
        model="m",
        shots_total=1,
        cost_cents=2**31 - 1,
    )
    session.add(render)
    await session.commit()
    render_id = render.id

    # Never raises, however the commit fails.
    await renders.run(render_id)

    # Read through a fresh session: `run()` owns its own, and this test's session holds a
    # snapshot from before it committed.
    from rascal.db import get_sessionmaker

    async with get_sessionmaker()() as fresh:
        row = await fresh.get(SocialRender, render_id)
        assert row.status == "failed", f"the row must reach a terminal state, not {row.status}"
        assert row.finished_at is not None
        assert "GEMINI_API_KEY" not in (row.error or "")


async def test_an_abandoned_render_stops_blocking_the_post(
    client: AsyncClient, session, app, admin
) -> None:
    """A deploy kills the task mid-render. The post must not become unrenderable forever.

    `asyncio.CancelledError` is a `BaseException`, so even the broad handler may not get to
    write a terminal status — which leaves a `running` row that `preflight` refuses on and only
    hand-edited SQL can clear.
    """
    from rascal.config import get_settings as real_settings
    from rascal.models import SocialRender

    asset_id = await _asset(client, admin, shot_list=SHOTS)
    long_ago = dt.datetime.now(tz=dt.UTC) - dt.timedelta(days=1)
    session.add(
        SocialRender(
            asset_id=uuid.UUID(asset_id),
            status="running",
            provider=renders.PROVIDER,
            model="m",
            shots_total=2,
            started_at=long_ago,
        )
    )
    await session.commit()

    app.dependency_overrides[real_settings] = lambda: _settings()
    try:
        response = await client.post(
            f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin)
        )
    finally:
        app.dependency_overrides.pop(real_settings, None)
    assert response.status_code == 202, response.text

    from rascal.db import get_sessionmaker

    async with get_sessionmaker()() as fresh:
        rows = (
            await fresh.scalars(
                select(SocialRender).where(SocialRender.asset_id == uuid.UUID(asset_id))
            )
        ).all()
    assert any(r.status == "cancelled" for r in rows), "the abandoned row is reaped"
    # A second row exists — the render the reaping unblocked. Its own status depends on how far
    # the background task got, which is not what this test is about.
    assert len(rows) == 2, [r.status for r in rows]


async def test_a_render_that_is_merely_slow_is_not_reaped(
    client: AsyncClient, session, app, admin
) -> None:
    """Cancelling a slow job starts a second one beside it and pays for the clips twice."""
    from rascal.config import get_settings as real_settings
    from rascal.models import SocialRender

    asset_id = await _asset(client, admin, shot_list=SHOTS)
    session.add(
        SocialRender(
            asset_id=uuid.UUID(asset_id),
            status="running",
            provider=renders.PROVIDER,
            model="m",
            shots_total=2,
            started_at=dt.datetime.now(tz=dt.UTC) - dt.timedelta(seconds=30),
        )
    )
    await session.commit()

    app.dependency_overrides[real_settings] = lambda: _settings()
    try:
        response = await client.post(
            f"/v1/social/assets/{asset_id}/video", headers=auth_headers(admin)
        )
    finally:
        app.dependency_overrides.pop(real_settings, None)
    assert response.status_code == 422
    assert "already running" in response.json()["error"]["message"]


async def test_a_missing_key_is_not_reported_as_a_missing_api_key(
    client: AsyncClient, session, admin, bucket, monkeypatch
) -> None:
    """`LookupError` is also `KeyError`. Reporting one as the other misdirects the fix."""
    from rascal.models import SocialAsset, SocialRender
    from rascal.services.social import gemini, renders

    asset = SocialAsset(headline="keyerror", format="video", shot_list=SHOTS)
    session.add(asset)
    await session.commit()

    async def explodes(client_, settings_, shot):
        raise KeyError("some_field")

    monkeypatch.setattr(gemini, "render_shot", explodes)
    render = SocialRender(
        asset_id=asset.id, status="queued", provider=renders.PROVIDER, model="m", shots_total=1
    )
    session.add(render)
    await session.commit()

    await renders.run(render.id)
    await session.refresh(render)
    assert render.status == "failed"
    assert "GEMINI_API_KEY" not in (render.error or ""), render.error


# --- The estimate -----------------------------------------------------------------------------


def test_the_estimate_is_seconds_times_the_configured_rate() -> None:
    """Eight seconds of treatment at ten cents a second is eighty cents, shown before spending."""
    assert renders.estimate_cents(_settings(), SHOTS["shots"]) == 80
    assert (
        renders.estimate_cents(_settings(gemini_video_cents_per_second=40), SHOTS["shots"]) == 320
    )


# --- The stitch, which is the one part with no vendor in it -----------------------------------


def _clip(tmp: Path, index: int, seconds: int = 2) -> bytes:
    """A real mp4 with real audio, built by the same ffmpeg the stitcher uses."""
    path = tmp / f"c{index}.mp4"
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
            f"color=c=0x{index}05A2B:s=360x640:d={seconds}:r=24",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={300 * index}:duration={seconds}",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            str(path),
        ],
        check=True,
        capture_output=True,
    )
    return path.read_bytes()


def _duration(blob: bytes, tmp: Path) -> float:
    path = tmp / "probe.mp4"
    path.write_bytes(blob)
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(out.stdout.strip())


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
def test_clips_join_into_one_file_of_their_combined_length(tmp_path: Path) -> None:
    clips = [_clip(tmp_path, i, seconds=2) for i in (1, 2, 3)]
    joined = stitch.concat(clips)
    assert abs(_duration(joined, tmp_path) - 6.0) < 0.5


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
def test_a_single_clip_is_returned_untouched(tmp_path: Path) -> None:
    """One shot is already the finished file. Re-encoding it to prove a point is pure loss."""
    only = _clip(tmp_path, 1)
    assert stitch.concat([only]) == only


@pytest.mark.skipif(not stitch.available(), reason="ffmpeg is not installed")
def test_a_join_that_exits_zero_but_lost_a_clip_is_rejected(tmp_path: Path) -> None:
    """An exit code of zero is not correctness, and this is the case that proves it.

    The concat demuxer stream-copies clips whose codecs do not match — h264 packets and mpeg4
    packets written into one h264 track — and exits 0 having produced something that plays as
    garbage after the first clip. Verified by hand before this test existed. The copy is
    therefore accepted only when the joined duration is the sum of the parts.
    """
    h264 = _clip(tmp_path, 1, seconds=2)
    mpeg4_path = tmp_path / "mpeg4.mp4"
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
            "color=c=blue:s=360x640:d=2:r=24",
            "-c:v",
            "mpeg4",
            "-pix_fmt",
            "yuv420p",
            str(mpeg4_path),
        ],
        check=True,
        capture_output=True,
    )
    joined = stitch.concat([h264, mpeg4_path.read_bytes()])
    # Four seconds of playable video, which only the re-encode path can produce here.
    assert abs(_duration(joined, tmp_path) - 4.0) < 0.6


def test_nothing_to_stitch_says_so(tmp_path: Path) -> None:
    with pytest.raises(stitch.StitchError, match="Nothing to stitch"):
        stitch.concat([])
