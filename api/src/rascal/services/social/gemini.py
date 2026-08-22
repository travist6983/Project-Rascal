"""One shot in, one video clip out, from Google's Gemini API.

**This is the only module here that has never seen a 200 from its vendor.** The Gemini video
models have a free-tier quota of exactly zero — a key that answers text requests perfectly
returns `generate_content_free_tier_requests, limit: 0` for video until billing is enabled on
the project — so everything below is written from Google's documentation and verified only as
far as the request being accepted and quota-refused. That is stated here rather than
discovered later, and it is why `_video_bytes` treats **an unrecognised response shape as an
error rather than as an empty result**. A renderer that silently produces nothing is worse
than one that says it no longer understands the answer.

**Two providers, because the first one refused the product's own copy.** Omni Flash was chosen
for the reasons below and then, on the first render that got past billing, **rejected shot three
of a Vellum treatment as "harmful content"** — a static shot of a photograph with the caption
*"Why did you take this one?"*. The same prompt, byte for byte, is accepted by every Veo 3.1
tier. A safety filter that refuses a still life is not one this product can plan around, so
Veo 3.1 Lite is the default as of Aug 21, 2026 and Omni Flash is kept reachable by setting
`GEMINI_VIDEO_MODEL`.

Lite is also **half the price** — $0.05 a second against $0.10 — so the switch made a
thirty-second treatment cheaper *and* renderable. The original Omni Flash argument, kept
because it is still true and still the reason to reach for it if the filter loosens: Google's
video overview names it the default, it is the only model whose documentation claims on-screen
text renders legibly, and it is synchronous, so there is no long-running operation to poll.

**Veo is asynchronous and that is the whole shape difference.** `:predictLongRunning` returns
an operation name; you poll it until `done`, then download the clip from a URI that needs the
API key appended. Verified against the live API rather than read: a 4-second Lite clip took
about ninety seconds and came back as a 416KB MP4. Google's own documentation was already
wrong about one field on this endpoint — `durationSeconds` is documented as a string and is
rejected unless it is a number — so the shapes below are what the API actually did.

**No API stitches clips.** Omni Flash generates three to ten seconds; Veo does four, six or
eight. A thirty-second treatment is seven generations and a concatenation, which is
`stitch.py`.

**The voiceover is prompt-directed, not verbatim.** Google documents quoting speech in the
prompt as an "audio cue" and offers no script parameter, no voice selection, and no guarantee
of exact delivery. `shot_prompt` therefore asks for the line and the caller must treat what
comes back as an approximation — see `docs/decisions.md`.
"""

from __future__ import annotations

import asyncio
import base64
from typing import Any

import httpx

from rascal.config import Settings

#: Google's own guidance is that a video prompt reads as direction rather than as keywords, so
#: the shared preamble carries the look and every shot appends its own action. It is prepended
#: to each of the seven prompts because there is no cross-clip style parameter on Omni Flash —
#: consistency is bought with repetition or not at all.
STYLE = (
    "Documentary-style vertical footage for a family archive app. Warm natural window light, "
    "shallow depth of field, muted domestic palette — creams, terracotta, soft greys. Handheld "
    "but steady. Real homes, not sets. No stock-footage gloss, no lens flares, no text overlays "
    "beyond what is specified."
)

#: Said in every prompt. The product is about children and the safest footage for it contains
#: no identifiable people at all — which is also what the treatments Claude writes already ask
#: for ("No face", "Nobody is photographing anything"). Making it explicit in the prompt keeps
#: that from depending on the treatment remembering.
NO_PEOPLE = (
    "Do not show any identifiable faces. Hands, shoulders and backs only, or no people at all."
)


def shot_prompt(shot: dict[str, Any]) -> str:
    """One shot's direction, as a single prompt string.

    `on_screen_text` is quoted and pinned to a duration because Omni Flash documents timing
    control in natural language; `voiceover` is quoted because quoting is how Google documents
    asking for spoken dialogue. Both are requests, not guarantees.
    """
    parts = [STYLE, NO_PEOPLE, str(shot.get("visual") or "").strip()]
    seconds = shot.get("seconds")
    if seconds:
        parts.append(f"The shot runs about {int(seconds)} seconds.")
    on_screen = str(shot.get("on_screen_text") or "").strip()
    if on_screen:
        parts.append(
            f"Render this text on screen, centred, in a clean sans-serif, legible and "
            f'correctly spelled: "{on_screen}". No other text appears.'
        )
    voiceover = str(shot.get("voiceover") or "").strip()
    parts.append(f'A calm, unhurried voice says: "{voiceover}"' if voiceover else "No dialogue.")
    return " ".join(part for part in parts if part)


#: Veo generates 4, 6 or 8 seconds and nothing between. A treatment written for five gets six
#: rather than four: a shot that runs long can be trimmed by the concatenation, and one that
#: runs short leaves a gap no later step can fill.
VEO_DURATIONS = (4, 6, 8)

#: How long to wait for one Veo clip. A Lite clip measured about ninety seconds; eight minutes
#: is slack for a queue, not an expectation. The ceiling exists because a render that never
#: returns is worse than one that fails — `renders.py` records the failure and the cost of the
#: clips that did land.
VEO_TIMEOUT_SECONDS = 480
VEO_POLL_SECONDS = 10


def _veo_duration(seconds: Any) -> int:
    """The nearest duration Veo will actually generate, rounding up on a tie."""
    wanted = int(seconds or 4)
    return min(VEO_DURATIONS, key=lambda allowed: (abs(allowed - wanted), -allowed))


def is_veo(model: str) -> bool:
    """Which API shape this model speaks. The id is the only thing that distinguishes them."""
    return model.startswith("veo-")


async def _render_veo(client: httpx.AsyncClient, settings: Settings, shot: dict[str, Any]) -> bytes:
    """One clip from Veo: start an operation, poll it, download what it made."""
    model = settings.gemini_video_model
    started = await client.post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:predictLongRunning",
        params={"key": settings.gemini_api_key},
        json={
            "instances": [{"prompt": shot_prompt(shot)}],
            # A number, not the string Google documents. Sending the string is a 400, which is
            # how the docs being wrong was discovered rather than assumed.
            "parameters": {
                "durationSeconds": _veo_duration(shot.get("seconds")),
                "sampleCount": 1,
                # **9:16, or Veo returns landscape.** Everything this studio makes is a Story
                # or a Reel. The Interactions path below says the same thing in its own dialect
                # (`response_format.aspect_ratio`); omitting it here produced a 1280x720 clip
                # for a vertical treatment, which is not a smaller mistake than failing.
                "aspectRatio": "9:16",
            },
        },
    )
    if started.status_code != 200:
        raise RuntimeError(_error_sentence(started))

    operation = str(started.json().get("name") or "")
    if not operation:
        raise RuntimeError("Veo accepted the request and named no operation to poll.")

    waited = 0
    while waited < VEO_TIMEOUT_SECONDS:
        await asyncio.sleep(VEO_POLL_SECONDS)
        waited += VEO_POLL_SECONDS
        polled = await client.get(
            f"https://generativelanguage.googleapis.com/v1beta/{operation}",
            params={"key": settings.gemini_api_key},
        )
        if polled.status_code != 200:
            raise RuntimeError(_error_sentence(polled))
        payload = polled.json()
        if not payload.get("done"):
            continue
        # A finished operation can still carry an error rather than a clip.
        if error := payload.get("error"):
            raise RuntimeError(
                f"Veo finished with an error: {str(error.get('message') or error)[:160]}"
            )
        return await _veo_bytes(client, settings, payload)

    raise RuntimeError(
        f"Veo did not finish within {VEO_TIMEOUT_SECONDS // 60} minutes. The operation may still "
        "complete — this render is failed rather than left waiting, and the clips already paid "
        "for are recorded."
    )


async def _veo_bytes(
    client: httpx.AsyncClient, settings: Settings, payload: dict[str, Any]
) -> bytes:
    """Follow the operation's video URI. **The key goes on the download too**, or it is a 403."""
    samples = ((payload.get("response") or {}).get("generateVideoResponse") or {}).get(
        "generatedSamples"
    ) or []
    uri = ((samples[0] if samples else {}).get("video") or {}).get("uri")
    if not uri:
        raise RuntimeError(
            "Veo answered done with no video in it. The response shape has changed — this "
            "renderer refuses rather than writing an empty file. Keys seen: "
            + ", ".join(sorted(payload)[:8])
        )
    # **`copy_merge_params`, not `params=`.** The URI Veo hands back already carries its own
    # query (`?alt=media`), and httpx *replaces* the query string when you pass `params` —
    # which drops `alt=media` and turns the download into a 400. Found by running it against
    # the live API; every mocked test passed with the broken version.
    downloaded = await client.get(
        httpx.URL(uri).copy_merge_params({"key": settings.gemini_api_key or ""}),
        follow_redirects=True,
    )
    if downloaded.status_code != 200:
        raise RuntimeError(f"Veo's clip URI answered {downloaded.status_code} on download.")
    return downloaded.content


async def render_shot(client: httpx.AsyncClient, settings: Settings, shot: dict[str, Any]) -> bytes:
    """Generate one clip. Raises `LookupError` unconfigured, `RuntimeError` with a sentence."""
    if not settings.gemini_api_key:
        raise LookupError("gemini_video")

    if is_veo(settings.gemini_video_model):
        return await _render_veo(client, settings, shot)

    response = await client.post(
        "https://generativelanguage.googleapis.com/v1beta/interactions",
        headers={
            "x-goog-api-key": settings.gemini_api_key,
            "content-type": "application/json",
        },
        json={
            "model": settings.gemini_video_model,
            "input": shot_prompt(shot),
            # 9:16 because everything this studio makes is a Story or a Reel. Resolution is
            # not sent: Omni Flash is 720p only, and naming a resolution it does not offer is
            # how a request starts being rejected the week the model gains one.
            "response_format": {"type": "video", "aspect_ratio": "9:16"},
        },
    )
    if response.status_code != 200:
        raise RuntimeError(_error_sentence(response))
    return _video_bytes(response.json())


def _error_sentence(response: httpx.Response) -> str:
    """A sentence naming the fix, never a stack trace and never the key.

    The 429 is the one worth spelling out: every Gemini video model has a free-tier quota of
    zero, so the first thing a working key does here is fail, and the message Google returns
    reads like rate limiting rather than like billing.
    """
    try:
        message = str((response.json().get("error") or {}).get("message") or "")
    except ValueError:
        message = ""
    if response.status_code == 429:
        return (
            "429 from Gemini. The video models have a free-tier quota of zero, so this is "
            "almost certainly billing rather than rate limiting — enable billing for the "
            "project at ai.dev/rate-limit. Text models keep working on the same key, which is "
            "what makes this confusing."
        )
    if response.status_code in (401, 403):
        return f"HTTP {response.status_code} from Gemini. GEMINI_API_KEY was not accepted."
    if response.status_code == 404:
        return (
            f"404 from Gemini for model {_model_from_error(message)}. Every video model on this "
            "API is preview and the ids move — check GEMINI_VIDEO_MODEL against the current "
            "model list."
        )
    return f"HTTP {response.status_code} from Gemini." + (f" {message[:160]}" if message else "")


def _model_from_error(message: str) -> str:
    """The model id out of a 404 body, so the message can name it. Best effort."""
    return message.split("models/")[-1].split()[0] if "models/" in message else "the video model"


def _video_bytes(payload: dict[str, Any]) -> bytes:
    """Dig the clip out of an Interactions response.

    **An unrecognised shape raises rather than returning nothing.** Google documents that the
    convenient `output_video` accessor is SDK-only and that raw REST callers walk
    `steps[] → content[] → type: "video"`, so this walks it — and if that walk finds no video,
    that is a change in the response, not a clip of zero bytes. Every model here is preview,
    which makes the shape moving a question of when.
    """
    for step in payload.get("steps") or []:
        for item in step.get("content") or []:
            if item.get("type") != "video":
                continue
            data = item.get("data")
            if isinstance(data, str) and data:
                return base64.b64decode(data)
    raise RuntimeError(
        "Gemini answered 200 with no video in it. The Interactions response shape has "
        "changed — this renderer is refusing rather than writing an empty file. Keys seen: "
        + ", ".join(sorted(payload)[:8])
    )


__all__ = ["NO_PEOPLE", "STYLE", "is_veo", "render_shot", "shot_prompt"]
