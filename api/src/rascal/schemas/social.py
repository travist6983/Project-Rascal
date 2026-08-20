"""Wire models for the social studio.

Strict where a human types, loose where the model answers. The concept payloads coming *back*
from Claude are schema-enforced server-side by `output_config.format`, so mirroring them into
Pydantic would be a second copy of the same constraint — the write models below are the ones
worth being strict about, because they are what a browser sends.
"""

from __future__ import annotations

import uuid
from typing import Any, Literal

from pydantic import Field

from rascal.models.social import SOCIAL_FORMATS, SOCIAL_PLATFORMS, SOCIAL_STATUSES
from rascal.schemas.common import ApiModel

Platform = Literal[
    "instagram", "instagram_story", "x", "threads", "facebook", "linkedin", "generic"
]
AssetStatus = Literal["draft", "approved", "exported", "published", "discarded"]
AssetFormat = Literal["card", "photo", "video"]

# The Literals above and the CHECK-constraint tuples in `models/social.py` are the same three
# sets written twice, so assert it here rather than discovering the drift as a 500 from
# Postgres on a value Pydantic happily accepted.
assert set(Platform.__args__) == set(SOCIAL_PLATFORMS)
assert set(AssetStatus.__args__) == set(SOCIAL_STATUSES)
assert set(AssetFormat.__args__) == set(SOCIAL_FORMATS)


class ChatMessage(ApiModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=20000)


class ChatIn(ApiModel):
    """The whole conversation, every turn.

    The Messages API is stateless and nothing here stores a thread: the console holds the
    history and sends it back. That keeps a half-finished brainstorm out of the database,
    which is the right default for a scratchpad — the things worth keeping become assets.
    """

    messages: list[ChatMessage] = Field(min_length=1, max_length=60)


class ConceptsIn(ApiModel):
    brief: str = Field(min_length=3, max_length=4000)
    count: int = Field(default=4, ge=1, le=8)
    platform: Platform = "instagram"
    featured_prompt_id: uuid.UUID | None = Field(
        default=None,
        description="A mission-library prompt to build a post around. The body is read "
        "server-side from this id — never accepted as text — and using one consumes a unit "
        "of the D7 cap reported by `GET /social/studio`.",
    )


class ShotListIn(ApiModel):
    brief: str = Field(min_length=3, max_length=4000)
    seconds: int = Field(default=30, ge=6, le=180)


class SocialAssetIn(ApiModel):
    platform: Platform = "generic"
    format: AssetFormat = "card"
    angle: str | None = Field(default=None, max_length=500)
    template: str | None = Field(default=None, max_length=40)
    palette: str | None = Field(default=None, max_length=40)
    headline: str | None = Field(default=None, max_length=400)
    subhead: str | None = Field(default=None, max_length=600)
    caption: str | None = Field(default=None, max_length=4000)
    alt_text: str | None = Field(default=None, max_length=1000)
    hashtags: list[str] = Field(default_factory=list, max_length=30)
    image_prompt: str | None = Field(default=None, max_length=4000)
    shot_list: dict[str, Any] | None = None
    caption_track: str | None = Field(default=None, max_length=20000)
    duration_seconds: int | None = Field(default=None, ge=0, le=600)
    featured_prompt_id: uuid.UUID | None = None
    model: str | None = Field(default=None, max_length=80)


class SocialAssetUpdate(ApiModel):
    """Partial. `featured_prompt_id` is deliberately absent — see `services/social/studio.py`.

    Attaching a library body to an existing asset would slip past the cap check, so featuring
    a prompt is a property of creation and nothing else.
    """

    platform: Platform | None = None
    format: AssetFormat | None = None
    status: AssetStatus | None = None
    angle: str | None = Field(default=None, max_length=500)
    template: str | None = Field(default=None, max_length=40)
    palette: str | None = Field(default=None, max_length=40)
    headline: str | None = Field(default=None, max_length=400)
    subhead: str | None = Field(default=None, max_length=600)
    caption: str | None = Field(default=None, max_length=4000)
    alt_text: str | None = Field(default=None, max_length=1000)
    hashtags: list[str] | None = Field(default=None, max_length=30)
    image_prompt: str | None = Field(default=None, max_length=4000)
    shot_list: dict[str, Any] | None = None
    caption_track: str | None = Field(default=None, max_length=20000)
    duration_seconds: int | None = Field(default=None, ge=0, le=600)


class RenderIn(ApiModel):
    provider: str = Field(default="openai_image", max_length=40)
    kind: Literal["image", "video"] = "image"
    prompt: str | None = Field(
        default=None,
        max_length=4000,
        description="Overrides the asset's own `image_prompt` for this one render.",
    )
