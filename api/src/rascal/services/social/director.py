"""Talking to Claude. The one place in the running service that calls a model.

**Raw `httpx` against `/v1/messages`, not the `anthropic` SDK**, matching
`scripts/generate_prompts.py` — which has called this API from this repo since phase 46. Two
reasons to keep the pattern rather than add the SDK: `httpx` is already a dependency and is
already the client this service makes every outbound call with, and one shape of Anthropic
call in the tree is easier to keep current than two.

**What this can and cannot do, because the distinction decides the whole feature.** Claude
takes text and images in and produces text out. It does not generate images and it does not
generate video — there is no endpoint for either, on any model. So this module writes the
words, picks the layout, and writes the *brief* for a pixel renderer; the pixels come from a
card template in the browser or from a third-party provider in `renderers.py`. A module here
that claimed to "generate an image with Claude" would be a lie with a spinner on it.
"""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.services.social import brand

log = logging.getLogger("rascal.social")

API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"

#: Opus, not the Sonnet that `generate_prompts.py` defaults to. That script writes hundreds of
#: candidates a human then filters, where volume and cost dominate; this one writes a handful
#: of things that go out under the product's name, where judgment does. Both read
#: `ANTHROPIC_MODEL` so either can be moved without a deploy.
DEFAULT_MODEL = "claude-opus-5"

#: Generous, because a concept set is several hundred tokens of structured output and a
#: truncated one is a 422 the owner cannot act on. Well under any streaming threshold.
MAX_TOKENS = 8000

#: The shape `POST /v1/social/concepts` gets back. `additionalProperties: false` and a full
#: `required` list are not optional here — structured outputs enforce the schema, and a
#: schema that permits extra keys permits the model to answer a different question.
CONCEPT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "concepts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "angle": {
                        "type": "string",
                        "description": "What this post is actually arguing, in one clause. "
                        "Two concepts with the same angle are one concept.",
                    },
                    "template": {"type": "string", "enum": list(brand.TEMPLATES)},
                    "palette": {"type": "string", "enum": list(brand.PALETTES)},
                    "headline": {"type": "string"},
                    "subhead": {"type": "string"},
                    "caption": {"type": "string"},
                    "alt_text": {"type": "string"},
                    "hashtags": {"type": "array", "items": {"type": "string"}},
                    "image_prompt": {
                        "type": "string",
                        "description": "A brief for a photographic image model, for the day "
                        "one is connected. Written even when no provider is configured — it "
                        "costs nothing now and is the expensive half to reconstruct later.",
                    },
                },
                "required": [
                    "angle",
                    "template",
                    "palette",
                    "headline",
                    "subhead",
                    "caption",
                    "alt_text",
                    "hashtags",
                    "image_prompt",
                ],
                "additionalProperties": False,
            },
        }
    },
    "required": ["concepts"],
    "additionalProperties": False,
}

SHOT_LIST_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "premise": {"type": "string"},
        "shots": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "seconds": {"type": "integer"},
                    "visual": {"type": "string"},
                    "on_screen_text": {"type": "string"},
                    "voiceover": {"type": "string"},
                },
                "required": ["seconds", "visual", "on_screen_text", "voiceover"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["title", "premise", "shots"],
    "additionalProperties": False,
}


def _require_key(settings: Settings) -> str:
    if not settings.anthropic_api_key:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "ANTHROPIC_API_KEY is not set, so the studio has nobody to ask. It is an ordinary "
            "sk-ant-api… key from console.anthropic.com → API keys — not the admin key the "
            "cost panel wants, which is a different kind of key.",
            field="anthropic_api_key",
        )
    return settings.anthropic_api_key


def _headers(api_key: str) -> dict[str, str]:
    return {
        "x-api-key": api_key,
        "anthropic-version": API_VERSION,
        "content-type": "application/json",
    }


def _explain(response: httpx.Response) -> str:
    """The API's own reason, which `raise_for_status()` throws away.

    Same argument `generate_prompts.py` makes: a bare "400 Bad Request" surfaced in a console
    is not a diagnosis, and the body is the only place the API says why.
    """
    try:
        payload = response.json()
        message = payload.get("error", {}).get("message")
    except ValueError:
        message = None
    return message or response.text[:300] or f"HTTP {response.status_code}"


def _base_request(settings: Settings, messages: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "model": settings.anthropic_model or DEFAULT_MODEL,
        "max_tokens": MAX_TOKENS,
        "system": brand.system_prompt(),
        "messages": messages,
        # Adaptive rather than a token budget: `budget_tokens` is removed on this model family
        # and returns a 400. Depth is controlled by `effort` instead.
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": "medium"},
        # No `temperature` and no `top_p`. Both are removed on Opus 5 and either one is a 400,
        # which is the single easiest thing to carry over from older code by habit.
    }


def require_key(settings: Settings) -> str:
    """Public because the route calls it *before* it starts streaming.

    Once a `StreamingResponse` has sent its headers the status code is spent, so an exception
    raised inside the generator cannot become a 422 with a message in it — Starlette raises
    "response already started" and the browser reports "network error", which is the least
    useful description of the single likeliest failure here. Checking up front keeps the
    common case an ordinary error response carrying the sentence that names the key to set.
    """
    return _require_key(settings)


async def chat(settings: Settings, messages: list[dict[str, Any]]) -> AsyncIterator[str]:
    """Stream a reply, token by token.

    Streamed because a director's answer to "give me five angles for launch week" is twenty
    seconds of thinking followed by a paragraph, and a console that shows nothing for twenty
    seconds is a console the owner assumes is broken.

    Yields plain text deltas only. Thinking blocks stream with empty text under this model's
    default `display`, so there is nothing to filter out and nothing to show.
    """
    api_key = _require_key(settings)
    request = _base_request(settings, messages) | {"stream": True}

    async with (
        httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=10.0)) as client,
        client.stream("POST", API_URL, json=request, headers=_headers(api_key)) as response,
    ):
        if response.status_code >= 400:
            await response.aread()
            # Yielded rather than raised. The headers are already out, so this is the only
            # channel left that reaches the reader — and a sentence in the transcript beats a
            # connection that dies for no stated reason.
            yield f"\n\n[The Anthropic API said: {_explain(response)}]"
            return
        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                event = json.loads(line[6:])
            except ValueError:
                continue
            if event.get("type") != "content_block_delta":
                continue
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta" and delta.get("text"):
                yield delta["text"]


async def structured(
    settings: Settings,
    instruction: str,
    schema: dict[str, Any],
) -> dict[str, Any]:
    """One turn, constrained to a JSON schema.

    `output_config.format` rather than a tool call or a "reply with JSON" instruction: the
    schema is enforced server-side, so there is no parse to fail and no retry loop to write.
    The first request with a new schema pays a one-time compilation cost and every later one
    is cached for a day.
    """
    api_key = _require_key(settings)
    request = _base_request(settings, [{"role": "user", "content": instruction}])
    request["output_config"] = {
        "effort": "medium",
        "format": {"type": "json_schema", "schema": schema},
    }

    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=10.0)) as client:
        response = await client.post(API_URL, json=request, headers=_headers(api_key))

    if response.status_code >= 400:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED, f"The Anthropic API said: {_explain(response)}"
        )

    payload = response.json()
    # A refusal is an HTTP 200 with an empty `content`, so reading `content[0]` first would
    # raise an IndexError and report a bug in this file rather than a decision by the model.
    if payload.get("stop_reason") == "refusal":
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "The model declined this brief. Rewrite it and try again — nothing was billed.",
        )
    text = next(
        (
            block.get("text", "")
            for block in payload.get("content", [])
            if block.get("type") == "text"
        ),
        "",
    )
    if not text:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"The model returned no text (stop_reason: {payload.get('stop_reason')}).",
        )
    try:
        return dict(json.loads(text))
    except ValueError as exc:  # pragma: no cover — the schema is server-enforced.
        raise RascalError(
            ErrorCode.INTERNAL_ERROR, "The model returned something that was not JSON."
        ) from exc


def concept_instruction(brief: str, count: int, platform: str, featured_body: str | None) -> str:
    """The user turn for a concept set. The brand brief is the system prompt; this is the job."""
    width, height = brand.PLATFORM_SIZES.get(platform, (1080, 1350))
    lines = [
        f"Give me {count} post concepts for {platform} at {width}x{height}.",
        "",
        f"The brief: {brief}",
        "",
        "Each concept must take a different angle. Not a different wording of one angle — a "
        "different argument for why somebody should care.",
    ]
    if featured_body:
        # The one path by which a library body reaches the model, and it arrives because the
        # owner attached it by hand in the Library tab. See `brand.py` on D7.
        lines += [
            "",
            "The owner has attached a real prompt from the mission library. Use it verbatim, "
            "tokens rendered as shown, in at least one concept — that concept should use the "
            "`prompt` template. Do not write variations of it and do not invent siblings.",
            "",
            f"The prompt: {featured_body}",
        ]
    else:
        lines += [
            "",
            "No prompt is attached, so do not use the `prompt` template and do not write "
            "anything that reads like a line from the library.",
        ]
    return "\n".join(lines)


def shot_list_instruction(brief: str, seconds: int) -> str:
    return (
        f"Write a {seconds}-second vertical video for Vellum.\n\n"
        f"The brief: {brief}\n\n"
        "Shots should total roughly the target length. `on_screen_text` is what appears "
        "burned into the frame and should be short enough to read at that duration. "
        "`voiceover` is what is said over it, or an empty string if the shot is silent. "
        "Assume this is shot on a phone by one person with no crew and no actors — a visual "
        "that needs a second pair of hands is a visual that does not get made."
    )
