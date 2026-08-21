"""One shot in, one video clip out, from Google's Gemini API.

**This is the only module here that has never seen a 200 from its vendor.** The Gemini video
models have a free-tier quota of exactly zero — a key that answers text requests perfectly
returns `generate_content_free_tier_requests, limit: 0` for video until billing is enabled on
the project — so everything below is written from Google's documentation and verified only as
far as the request being accepted and quota-refused. That is stated here rather than
discovered later, and it is why `_video_bytes` treats **an unrecognised response shape as an
error rather than as an empty result**. A renderer that silently produces nothing is worse
than one that says it no longer understands the answer.

**Why Omni Flash rather than Veo.** Google's own video overview names
`gemini-omni-flash-preview` the default and points at Veo only for scene extension and
last-frame control. For a Vellum treatment it wins on the thing that matters: it is the only
model whose documentation claims on-screen text renders legibly, and every shot in a treatment
carries a caption. It is also synchronous, so there is no long-running operation to poll and
no two-day expiry to race, and at roughly ten cents a second it is a quarter of Veo's price.

**No API stitches clips.** Omni Flash generates three to ten seconds; Veo does four, six or
eight. A thirty-second treatment is seven generations and a concatenation, which is
`stitch.py`.

**The voiceover is prompt-directed, not verbatim.** Google documents quoting speech in the
prompt as an "audio cue" and offers no script parameter, no voice selection, and no guarantee
of exact delivery. `shot_prompt` therefore asks for the line and the caller must treat what
comes back as an approximation — see `docs/decisions.md`.
"""

from __future__ import annotations

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


async def render_shot(client: httpx.AsyncClient, settings: Settings, shot: dict[str, Any]) -> bytes:
    """Generate one clip. Raises `LookupError` unconfigured, `RuntimeError` with a sentence."""
    if not settings.gemini_api_key:
        raise LookupError("gemini_video")

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


__all__ = ["NO_PEOPLE", "STYLE", "render_shot", "shot_prompt"]
