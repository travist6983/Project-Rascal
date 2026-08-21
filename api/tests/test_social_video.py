"""Rendering a shot list into a video.

The guards get the most attention here on purpose: every one of them exists to stop the job
spending real money on a treatment it cannot finish, and a guard with no test is a guard that
quietly stops guarding.
"""

from __future__ import annotations

import subprocess
import uuid
from pathlib import Path

import httpx
import pytest
from httpx import AsyncClient

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


def test_nothing_to_stitch_says_so(tmp_path: Path) -> None:
    with pytest.raises(stitch.StitchError, match="Nothing to stitch"):
        stitch.concat([])
