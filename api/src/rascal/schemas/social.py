"""Wire models for the social studio.

Strict where a human types, loose where the model answers. The concept payloads coming *back*
from Claude are schema-enforced server-side by `output_config.format`, so mirroring them into
Pydantic would be a second copy of the same constraint — the write models below are the ones
worth being strict about, because they are what a browser sends.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Literal

from pydantic import Field, field_validator, model_validator

from rascal.models.social import SOCIAL_FORMATS, SOCIAL_PLATFORMS, SOCIAL_STATUSES
from rascal.schemas.common import ApiModel
from rascal.services.social import brand
from rascal.services.social.brand import PALETTES, TEMPLATES

Platform = Literal[
    "instagram", "instagram_story", "x", "threads", "facebook", "linkedin", "generic"
]
AssetStatus = Literal["draft", "approved", "exported", "published", "discarded"]
AssetFormat = Literal["card", "photo", "video"]
#: A card is drawn in the browser from one of these, and `brand.py` is the authority on
#: both lists. Constrained here rather than left as a free string because `models/social.py`
#: already claims they are "validated against `services/social/brand.py`" — and until phase
#: 101 nothing enforced it, so the console's own dropdown could save `palette: ""` and the
#: card came back unrenderable.
CardTemplate = Literal["quote", "prompt", "stat", "announcement"]
CardPalette = Literal["cream", "terracotta", "periwinkle", "sage", "ink"]
#: How a scene enters. The same closed-set treatment `template` and `palette` got in phase 101,
#: one level up — a transition the browser cannot draw is a scene that appears out of nowhere,
#: and until a value is a `Literal` nothing stops the console saving `transition: ""`.
SceneTransition = Literal["cut", "fade", "rise"]

# These three and the CHECK-constraint tuples in `models/social.py` are the same sets written
# twice, so assert it here rather than discovering the drift as a 500 from Postgres on a value
# Pydantic happily accepted.
assert set(Platform.__args__) == set(SOCIAL_PLATFORMS)
assert set(AssetStatus.__args__) == set(SOCIAL_STATUSES)
assert set(AssetFormat.__args__) == set(SOCIAL_FORMATS)

# **These two carry no CHECK, by design.** `models/social.py` keeps `template` and `palette` as
# plain text because the renderer that has to know them lives in JavaScript, so a constraint in
# Postgres would be a second list to keep in step. That makes `brand.py` the only authority and
# these asserts the only thing standing between the two copies — and the failure they prevent
# is not a database error but a card the browser cannot draw, which nothing else would catch.
assert set(CardTemplate.__args__) == set(TEMPLATES)
assert set(CardPalette.__args__) == set(PALETTES)
assert set(SceneTransition.__args__) == set(brand.TRANSITIONS)


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


class TreatmentIn(ApiModel):
    brief: str = Field(min_length=3, max_length=4000)
    #: A target, not a contract. The model is asked to land near it and the real bounds are
    #: `VideoTreatment`'s, which is what actually refuses.
    seconds: int = Field(
        default=20,
        ge=brand.TREATMENT_MIN_MS // 1000,
        le=brand.TREATMENT_MAX_MS // 1000,
    )


class VideoScene(ApiModel):
    """One card, held for a while, entering somehow.

    **Every constrained field here is a `Literal` and that is the phase 101 defect one level
    up.** `models/social.py` keeps `template` and `palette` as plain text because the renderer
    that has to know them lives in JavaScript, so a Postgres CHECK would be a second list to
    keep in step — which makes these the only thing standing between the closed set and a card
    the browser cannot draw. Until phase 101 nothing enforced it and the console's own dropdown
    could save `palette: ""`. A scene graph has three such fields rather than two.
    """

    template: CardTemplate
    palette: CardPalette
    eyebrow: str | None = Field(default=None, max_length=brand.EYEBROW_MAX)
    #: Required, and `min_length=1` rather than merely present: a scene with no headline is a
    #: card holding a wordmark for two seconds, and it would also silently produce no caption
    #: cue while still consuming its slice of the clock. `_one_line_of_copy` below is what makes
    #: that true of `"   "` as well as of `""`, and it runs **before** this check for exactly
    #: that reason — see its docstring, which records what happens when it runs after.
    headline: str = Field(min_length=1, max_length=brand.HEADLINE_MAX)
    subhead: str | None = Field(default=None, max_length=brand.SUBHEAD_MAX)
    #: Milliseconds, because that is the unit a WebVTT cue is stamped in and the unit the
    #: browser's clock reads. Seconds here would mean rounding somewhere, and rounding is how
    #: a cue boundary stops being a scene boundary.
    duration_ms: int = Field(ge=brand.SCENE_MIN_MS, le=brand.SCENE_MAX_MS)
    transition: SceneTransition

    @field_validator("eyebrow", "headline", "subhead", mode="before")
    @classmethod
    def _one_line_of_copy(cls, value: object) -> object:
        """Collapse every run of whitespace to a single space, before the length checks run.

        **A blank line terminates a WebVTT cue.** `services/social/scenes.py` interpolates this
        copy straight into the track, so a headline containing one splits its own cue and
        orphans the rest of the sentence into a fragment the parser reads as a timing line. The
        card renderer wraps text itself and has no use for an authored break either, so there
        is nothing to lose by flattening here — at the boundary, once, rather than in every
        consumer.

        **`mode="before"`, and that is the whole design rather than a detail.** Written as an
        `after` validator this ran *past* `min_length`, so `"   "` was already accepted and the
        only way to reject it from there was to return `None` — which Pydantic assigns to a
        required `str` without complaint, leaving `headline=None` on a model whose type says it
        cannot be. That is a worse defect than the one being fixed and it is what this docstring
        exists to stop somebody reintroducing. Running before the constraint, `"   "` becomes
        `""` and `min_length=1` refuses it, which is what the comment on `headline` has always
        claimed happens.

        An emptied optional field is `""` rather than `None`, deliberately: that is the shape the
        model already sends — `TREATMENT_SCHEMA` requires every key, so an absent eyebrow arrives
        as an empty string — and every consumer treats the two identically (`scenes.caption_track`
        tests truthiness, `drawCard` tests `if (spec.eyebrow)`).

        A non-string is handed straight back for Pydantic's own type error to describe; catching
        it here would replace a precise message with a confusing one.
        """
        if not isinstance(value, str):
            return value
        return " ".join(value.split())


class VideoTreatment(ApiModel):
    """The whole video, as data. What Claude writes and what the browser draws.

    **Bounded at both ends and in both dimensions**, because every one of those bounds is a
    thing a model will otherwise produce: a one-scene "video" that is a still, an eleven-scene
    one nobody watches to the end, six scenes of eight seconds that runs longer than a Reel
    will play, and two of 1.2 seconds that is over before a thumb stops.
    """

    scenes: list[VideoScene] = Field(min_length=brand.MIN_SCENES, max_length=brand.MAX_SCENES)

    @model_validator(mode="after")
    def _total_runtime_is_watchable(self) -> VideoTreatment:
        total = sum(scene.duration_ms for scene in self.scenes)
        if not brand.TREATMENT_MIN_MS <= total <= brand.TREATMENT_MAX_MS:
            raise ValueError(
                f"The scenes total {total}ms. A treatment has to run between "
                f"{brand.TREATMENT_MIN_MS}ms and {brand.TREATMENT_MAX_MS}ms — under the first "
                "it is a still with a fade on it, and over the second no feed will play it to "
                "the end."
            )
        return self


class SocialAssetIn(ApiModel):
    platform: Platform = "generic"
    format: AssetFormat = "card"
    angle: str | None = Field(default=None, max_length=500)
    template: CardTemplate | None = None
    palette: CardPalette | None = None
    headline: str | None = Field(default=None, max_length=400)
    subhead: str | None = Field(default=None, max_length=600)
    caption: str | None = Field(default=None, max_length=4000)
    alt_text: str | None = Field(default=None, max_length=1000)
    hashtags: list[str] = Field(default_factory=list, max_length=30)
    image_prompt: str | None = Field(default=None, max_length=4000)
    #: **Typed, not a free `dict`.** It was `dict[str, Any]`, which accepted anything and made
    #: every closed set inside it decorative. `caption_track` and `duration_seconds` are
    #: deliberately absent from this model: both are *derived* from this field by
    #: `services/social/studio.py`, and a caller that could set them could make the captions
    #: disagree with the cards — which is the exact defect phase 120 exists to remove.
    treatment: VideoTreatment | None = None
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
    template: CardTemplate | None = None
    palette: CardPalette | None = None
    headline: str | None = Field(default=None, max_length=400)
    subhead: str | None = Field(default=None, max_length=600)
    caption: str | None = Field(default=None, max_length=4000)
    alt_text: str | None = Field(default=None, max_length=1000)
    hashtags: list[str] | None = Field(default=None, max_length=30)
    image_prompt: str | None = Field(default=None, max_length=4000)
    #: Same rule as on creation: the scene graph is settable, and everything derived from it
    #: is not. See `SocialAssetIn`.
    treatment: VideoTreatment | None = None


class RenderIn(ApiModel):
    provider: str = Field(default="openai_image", max_length=40)
    kind: Literal["image", "video"] = "image"
    prompt: str | None = Field(
        default=None,
        max_length=4000,
        description="Overrides the asset's own `image_prompt` for this one render.",
    )


class PublishIn(ApiModel):
    """Post it now, or queue it for a time.

    `scheduled_for` omitted means now — the row is written and published in the same request,
    which is what the console's button does. A time queues it and the scheduled machine picks
    it up; the shape is one field rather than two endpoints because "post this" and "post this
    at six" are the same decision with a different answer to when.
    """

    scheduled_for: dt.datetime | None = Field(
        default=None,
        description=(
            "UTC. Omit to publish immediately. A time in the past is refused rather than "
            "silently treated as now — it usually means a timezone was got wrong."
        ),
    )

    @field_validator("scheduled_for")
    @classmethod
    def _not_in_the_past(cls, value: dt.datetime | None) -> dt.datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("scheduled_for must carry a timezone offset.")
        if value < dt.datetime.now(tz=dt.UTC) - dt.timedelta(minutes=1):
            raise ValueError(
                "scheduled_for is in the past. Omit it to post now, or send a future time."
            )
        return value
