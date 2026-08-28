"""Pixels. The part Claude cannot do.

**There is no Anthropic image or video endpoint.** Claude takes text and images in and
produces text out; that is the whole surface, on every model. So a studio built on "generate
an image with our Anthropic key" has to answer the question honestly, and there are two honest
answers rather than one:

**The card renderer, which needs no vendor at all and works today.** Claude picks a template
and writes the words; `admin/static/cards.js` draws them onto a canvas in the Pocket
Chronicle design system and hands back a PNG — or, animated over a scene graph and captured with
`MediaRecorder`, a whole video. For a warm
typographic brand whose posts are sentences, this is not a fallback — a diffusion model asked
for "a cream card with a line of terracotta type" produces something worse and differently
wrong every time, and cannot be told to match `#C05A2B` exactly. It is also the only renderer
here that cannot fail at 2am because somebody's credits ran out.

**A third-party provider, for photographs.** Ports below, unconfigured by default, each
reporting the environment variable to set and where the key comes from — the same shape the
cost panel uses, and for the same reason: a card that says "not connected" without a next step
is a dead end.

Nothing in *this* module posts anything anywhere, and that remains true — it makes pixels.
Publishing moved next door in phase 104: `services/social/instagram.py` puts a card on
Instagram, and `services/social/publishing.py` decides whether to. The sentence that used to
end this paragraph — *"publishing is a thing the owner does with the file, on purpose,
somewhere else"* — was true until Aug 20, 2026 and is kept as history.
"""

from __future__ import annotations

import base64
import datetime as dt
import logging
import uuid
from dataclasses import dataclass
from typing import Literal

import httpx
from anyio import to_thread

from rascal.config import Settings
from rascal.services.s3 import get_s3_client
from rascal.services.social import transcode

log = logging.getLogger("rascal.social.render")

RenderKind = Literal["image", "video"]


@dataclass(frozen=True)
class RendererStatus:
    key: str
    label: str
    kind: RenderKind
    configured: bool
    #: What to set, and where the value comes from. Present whether or not it is configured,
    #: because the second most useful moment for that sentence is when somebody is deciding
    #: which provider to sign up for.
    setup: str
    note: str

    def as_dict(self) -> dict[str, object]:
        return {
            "key": self.key,
            "label": self.label,
            "kind": self.kind,
            "configured": self.configured,
            "setup": self.setup,
            "note": self.note,
        }


@dataclass(frozen=True)
class Rendered:
    """Bytes that landed in the bucket, and what made them."""

    s3_key: str
    provider: str
    content_type: str
    bytes_written: int


def statuses(settings: Settings) -> list[RendererStatus]:
    """Every renderer, whether or not it can run. Drives the Studio's provider strip."""
    return [
        RendererStatus(
            key="cards",
            label="Brand cards",
            kind="image",
            configured=True,
            setup="Nothing to configure — it draws in the browser.",
            note="Claude writes the words and picks the template; the canvas draws it in the "
            "Pocket Chronicle palette at any size and exports a PNG, a JPEG for Instagram, "
            "or — since "
            "phase 120 — a whole video, by animating a scene graph and recording the canvas. "
            "No vendor, no key, no per-image cost, and it cannot drift off-brand because it "
            "cannot draw anything that is not in the design system.",
        ),
        RendererStatus(
            key="openai_image",
            label="OpenAI · gpt-image-1",
            kind="image",
            configured=bool(settings.openai_api_key),
            setup="Set OPENAI_API_KEY (platform.openai.com → API keys). Claude writes the "
            "image prompt; this renders it.",
            note="For photographic images. Anthropic has no image endpoint on any model, so "
            "a second vendor is the only way to get one.",
        ),
        RendererStatus(
            key="replicate_image",
            label="Replicate",
            kind="image",
            configured=bool(settings.replicate_api_token),
            setup="Set REPLICATE_API_TOKEN (replicate.com → account → API tokens) and "
            "optionally REPLICATE_IMAGE_MODEL to pin a version.",
            note="One token, many models. The usual choice when the model matters more than "
            "the vendor.",
        ),
        RendererStatus(
            key="replicate_video",
            label="Replicate · video",
            kind="video",
            configured=bool(settings.replicate_api_token and settings.replicate_video_model),
            setup="Set REPLICATE_API_TOKEN and REPLICATE_VIDEO_MODEL to a video model's "
            "version string.",
            note="Video generation is minutes per clip and priced per second on every "
            "provider, so this one runs on demand and never on a schedule.",
        ),
        RendererStatus(
            key="canvas_video",
            label="Brand cards · video",
            kind="video",
            configured=bool(settings.anthropic_api_key) and transcode.available(),
            setup="Uses ANTHROPIC_API_KEY, the same key the chat uses, and ffmpeg on the "
            "machine — which the runtime image installs.",
            note="Claude writes a typed scene graph and the browser draws every frame with "
            "the same renderer that draws a still, records the canvas, and posts the "
            "recording here to be re-encoded as H.264. No vendor generates video for this "
            "product, and the caption track is derived from the scene copy rather than "
            "written beside it, so the two cannot disagree.",
        ),
    ]


def store(settings: Settings, data: bytes, *, suffix: str, content_type: str) -> str:
    """Put a rendered asset in the media bucket under its own prefix.

    `social/` rather than `children/`: this is marketing output and must never be mistaken for
    somebody's archive by a lifecycle rule, a deletion sweep, or a person reading a bucket
    listing. The Tigris cost card already reports per-prefix bytes, so the split shows up
    there for free.
    """
    key = f"social/{dt.date.today():%Y/%m}/{uuid.uuid4().hex}{suffix}"
    get_s3_client().put_object(
        Bucket=settings.s3_bucket, Key=key, Body=data, ContentType=content_type
    )
    return key


async def render_image(
    settings: Settings, provider: str, prompt: str, size: str = "1024x1024"
) -> Rendered:
    """Hand an image prompt to whichever provider is configured.

    Raises `LookupError` when the named provider has no credential — the router turns that
    into a **422** carrying the provider's own `setup` sentence, so the console can show the
    same "here is what to set" card it shows before anybody clicks. (This said 503 for three
    phases; `render_asset` has always raised `VALIDATION_FAILED`.)
    """
    if provider == "openai_image":
        if not settings.openai_api_key:
            raise LookupError("openai_image")
        async with httpx.AsyncClient(timeout=httpx.Timeout(180.0)) as client:
            response = await client.post(
                "https://api.openai.com/v1/images/generations",
                headers={"Authorization": f"Bearer {settings.openai_api_key}"},
                json={"model": "gpt-image-1", "prompt": prompt, "size": size, "n": 1},
            )
        response.raise_for_status()
        encoded = response.json()["data"][0]["b64_json"]
        data = base64.b64decode(encoded)
        key = await to_thread.run_sync(
            lambda: store(settings, data, suffix=".png", content_type="image/png")
        )
        return Rendered(key, provider, "image/png", len(data))

    if provider == "replicate_image":
        if not settings.replicate_api_token:
            raise LookupError("replicate_image")
        data = await _replicate(settings, settings.replicate_image_model, {"prompt": prompt})
        key = await to_thread.run_sync(
            lambda: store(settings, data, suffix=".png", content_type="image/png")
        )
        return Rendered(key, provider, "image/png", len(data))

    raise LookupError(provider)


async def render_video(settings: Settings, prompt: str) -> Rendered:
    if not (settings.replicate_api_token and settings.replicate_video_model):
        raise LookupError("replicate_video")
    data = await _replicate(settings, settings.replicate_video_model, {"prompt": prompt})
    key = await to_thread.run_sync(
        lambda: store(settings, data, suffix=".mp4", content_type="video/mp4")
    )
    return Rendered(key, "replicate_video", "video/mp4", len(data))


async def _replicate(settings: Settings, model: str | None, payload: dict) -> bytes:
    """Create a prediction, wait for it, fetch the file.

    Replicate is asynchronous by design — a create returns immediately with a URL to poll —
    so this blocks the request for as long as the model takes. That is acceptable for a button
    somebody presses and watches, and is exactly why nothing here runs on a schedule.
    """
    if not model:
        raise LookupError("replicate model is not configured")
    headers = {
        "Authorization": f"Bearer {settings.replicate_api_token}",
        "Content-Type": "application/json",
        # Ask Replicate to hold the connection open rather than polling it ourselves. Falls
        # back to the poll below when the model is slower than the wait window.
        "Prefer": "wait=60",
    }
    async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0)) as client:
        created = await client.post(
            "https://api.replicate.com/v1/predictions",
            headers=headers,
            json={"version": model, "input": payload},
        )
        created.raise_for_status()
        prediction = created.json()

        while prediction.get("status") in ("starting", "processing"):
            url = prediction.get("urls", {}).get("get")
            if not url:
                break
            polled = await client.get(url, headers=headers)
            polled.raise_for_status()
            prediction = polled.json()

        if prediction.get("status") != "succeeded":
            raise RuntimeError(
                f"Replicate returned {prediction.get('status')}: {prediction.get('error')}"
            )

        output = prediction.get("output")
        url = output[0] if isinstance(output, list) else output
        if not isinstance(url, str):
            raise RuntimeError("Replicate returned no file URL.")
        fetched = await client.get(url)
        fetched.raise_for_status()
        return fetched.content
