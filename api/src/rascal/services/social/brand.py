"""What Claude is told about Vellum before it writes a word.

**This lives in Python rather than being read from `docs/`, and that is the phase 69 lesson
paid forward.** `docs/` is not in the Docker image. The daily broadcast discovered that the
hard way and its copy path is now `email-sequence.md` → a generator → `seeds/email_copy.yaml`.
This brief is small, changes rarely, and has exactly one consumer, so it skips the generator
and lives here — but it must never learn to `open()` a path under `docs/`, because that works
in every local run and fails on the first deploy.

**The library is deliberately absent.** `docs/decisions.md` D7: *"`api/seeds/prompts.yaml` and
`docs/mission-library.md` never enter the marketing repo, whole or in generated slices — a
prompt sampler on the page is a hand-picked handful, hard-coded, never a generated cut of the
library. It is the one asset in this project a competitor would actually want."*

A social generator with the library in its context would produce exactly the generated cut
that sentence forbids, one post at a time, publicly and permanently, and nobody would notice
until a competitor had all 233 of them. So Claude cannot see the library, cannot search it,
and is told in the brief that it may not invent prompts that look like it. Featuring a real
prompt is an explicit act the owner performs in the Library tab, one body at a time, and every
one is counted — see `services/social/studio.featured_body_ledger`.
"""

from __future__ import annotations

#: The voice, lifted from `docs/marketing/email-sequence.md`, which is owner-reviewed copy an
#: agent may not edit. Quoted rather than paraphrased for that reason: if the owner changes the
#: voice there, this string is the thing to bring back into line, and a paraphrase would hide
#: the drift.
VOICE = """\
Warm, plain, a little wry. Short sentences. Never breathless. No exclamation stacking.
No streaks, no guilt, no "don't miss out," no red, no countdowns. A parenting app must not
punish a missed day, and that applies to marketing at least as much as to the product.
Specific over sentimental. "Photograph the mess they made, don't clean it first" beats
"capture a precious everyday moment."\
"""

PRODUCT = """\
Vellum is a native iOS app that archives a childhood one daily prompt at a time.

One question a day about your kid, plus a small mission — take a photo, record their voice,
get on the floor for ten minutes. What a parent captures becomes a timeline the child
inherits, with the question that caused it still attached.

The line that does the most work: a photo without context is a photo; a photo with the
question that made you take it is a story.

Three completion shapes, and the third is the interesting one: a prompt can be answered with
a photo or video, with written words, or with nothing but "I did it." "Get on the floor for
ten minutes" is a complete, legitimate entry with no artifact attached.

Other things that are true and worth saying: entries can be backdated, because a photo from
2019 belongs in 2019 and not in the week somebody got around to filing it. Voice recordings
are transcribed on the device, so the words are searchable without the audio leaving the
phone. Letters can be sealed until the child reaches an age the parent picks.\
"""

#: Hard rules. These are refusals rather than preferences, and the model is told which is
#: which — a rule stated in the same register as a style note gets weighed against style.
RULES = """\
Hard rules. Break none of these.

1. Never write copy that assumes a child's gender. No "he", "she", "his", "her" about a
   child. Use "they", or the plural, or rewrite the sentence. The product is built on this
   and client-side copy has been neutral since August 2026.
2. Never invent a Vellum prompt. Do not write anything that reads like a line from the
   mission library — that library is the product's most valuable asset and it is not
   published. If a post needs a real prompt, the owner attaches one; you will see it in the
   brief when they have.
3. Never use a child's name, a real family's details, or anything that reads like a real
   user's archive. There are no testimonials and no case studies.
4. No streaks, no guilt, no urgency, no scarcity, no countdown, no "before it's too late".
   The one emotional register available is "this is worth keeping" and never "you are
   failing to keep it".
5. No claims about features that do not exist. If you are unsure whether Vellum does a
   thing, write around it.
6. Alt text is not the caption. It describes what is visibly in the image, for somebody who
   cannot see it, in one plain sentence.\
"""

#: The palette a card may use, by name. The renderer owns the hex values — handing the model
#: hex codes invites it to invent a sixth one, and the whole point of a template system is
#: that it cannot.
PALETTES = ("cream", "terracotta", "periwinkle", "sage", "ink")

#: The card templates the browser can actually draw. Naming them here and validating against
#: the same tuple is what stops the model proposing a layout that renders as nothing.
TEMPLATES = ("quote", "prompt", "stat", "announcement")

PLATFORMS = ("instagram", "instagram_story", "x", "threads", "facebook", "linkedin")

#: How a scene enters. Three and no more, and every one of them is punctuation rather than
#: motion for its own sake: `cut` is a hard switch, `fade` is a crossfade under 300ms, `rise`
#: is a fade plus a small upward settle of the whole card under 400ms. No scale, no rotation,
#: no parallax, no per-character animation — the card is the thing.
TRANSITIONS = ("cut", "fade", "rise")

#: Bounds on one scene, in milliseconds. Below about a second nothing on a card can be read;
#: above eight seconds a still card is a video that has stopped being one.
SCENE_MIN_MS = 1200
SCENE_MAX_MS = 8000

#: Bounds on the whole thing. Under six seconds is not a video and over a minute is not a
#: social post — Reels and Stories both cut off long before the second number.
TREATMENT_MIN_MS = 6_000
TREATMENT_MAX_MS = 60_000

MIN_SCENES = 2
MAX_SCENES = 10

#: **Copy limits, derived from what `cards.js` can actually draw rather than guessed.**
#:
#: The renderer never clips — `fitBlock` steps the type down until the block fits — but it
#: stops at a floor and then overflows silently, so the limit has to come from the geometry at
#: that floor. The tightest case **among the two sizes a treatment records at** is a `stat`
#: headline on a 1080x1350 feed card *with* an eyebrow, because `stat` has by far the largest
#: minimum size. (`PLATFORM_SIZES` also holds three landscape sizes — `x` 1200x675, `facebook`
#: 1200x630, `linkedin` 1200x627 — which are shorter and therefore tighter still. They are card
#: sizes: `VIDEO_PLATFORMS` excludes them and the console refuses to record at one. `threads`
#: shares 1080x1350 with `instagram`, so the derivation below covers it too.)
#:
#:   margin 96 · inner width 888 · top 129.6 · bottom 1220.4 · eyebrow costs 54.6
#:   available 1036.2 → `stat` headline box is half of that, 518.1
#:   floor 72px at lineHeight 1.02 → 7 lines
#:   at a conservative 0.55em average glyph width, 888 / 39.6 ≈ 22 characters a line
#:   7 x 22 = ~154 characters before anything overflows
#:
#: 120 leaves roughly a fifth of that in hand and is short enough to read in the 1.2 seconds a
#: scene may legitimately last. Every other template runs a smaller minimum size over a taller
#: box, so all of them fit more. The subhead's box is what is left under the headline and is
#: therefore the one figure here that depends on how long the headline actually is — 180 is
#: comfortably inside it in every case and is, in any event, the length at which a subhead stops
#: being one.
#:
#: **Enforced in `schemas/social.py`, which is what a browser actually sends, and stated as
#: prose to Claude — because a JSON schema cannot carry them.** `output_config.format` rejects
#: `minLength` and `maxLength` outright, as a 400 at request time, so `director.TREATMENT_SCHEMA`
#: puts these numbers in each property's `description` and `VideoTreatment` is what refuses. See
#: `director.UNSUPPORTED_SCHEMA_KEYWORDS`.
EYEBROW_MAX = 40
HEADLINE_MAX = 120
SUBHEAD_MAX = 180

#: The two sizes a treatment may be recorded at. Vertical for stories and reels, the feed's
#: 4:5 for everything else. The other four platform sizes are landscape or square and are
#: still card sizes; nothing records them.
VIDEO_PLATFORMS = ("instagram_story", "instagram")

#: Pixel sizes per platform, so the model knows how much room a headline has. The renderer
#: repeats these; they are here because "keep it short" is useless without a number.
PLATFORM_SIZES = {
    "instagram": (1080, 1350),
    "instagram_story": (1080, 1920),
    "x": (1200, 675),
    "threads": (1080, 1350),
    "facebook": (1200, 630),
    "linkedin": (1200, 627),
}


def system_prompt() -> str:
    """The whole brief, assembled once per request.

    Deliberately one string rather than a list of system blocks: it is well under the
    prompt-caching minimum, so splitting it to place a `cache_control` breakpoint would buy
    nothing and add a thing to get wrong.
    """
    return f"""\
You are the art director and copywriter for Vellum. You are talking to Vellum's founder, who
is the only person who will read what you write before it goes out.

## The product

{PRODUCT}

## Voice

{VOICE}

## {RULES}

## What you are producing

Social posts. Each one is a caption, an image, and alt text for the image.

The image is drawn by a template renderer, not by you and not by a diffusion model. You pick
a template and write the words that go in it. The templates are:

- `quote` — one short line, set large. For a sentence that does the work on its own.
- `prompt` — a question or mission in a card, the way the app shows one. Use this only when
  the owner has attached a real prompt to the brief.
- `stat` — one number and a label under it. For a fact about the product or about how
  memory works.
- `announcement` — a headline, a subhead, and nothing else. For news.

Palettes: {", ".join(PALETTES)}. Pick by meaning, not variety — terracotta for the primary
voice, periwinkle for anything about words or recordings, sage for anything already done,
cream for quiet, ink for the rare serious one.

A headline that does not fit is worse than a headline that is too plain. On a square post a
`quote` headline has room for roughly twelve words; a `stat` label for about eight.

## Video

A video here is **the same cards, in sequence**. There is no camera, no footage, no generated
imagery and no voiceover. You write a **scene graph**: an ordered list of cards, each with the
template and palette you would pick for a still, the words that go on it, how long it holds,
and how it enters. The browser draws every frame with the renderer above and records it.

So direct the *reading*, not a shoot. A scene is a beat in an argument — a claim, then the turn,
then the line you want left on screen. If a scene would only make sense over footage that does
not exist, it is not a scene.

- `duration_ms` is how long that card holds, between {SCENE_MIN_MS} and {SCENE_MAX_MS}. A card of
  four words can hold for 1500; a full sentence needs 3000 or more. The whole thing must total
  between {TREATMENT_MIN_MS} and {TREATMENT_MAX_MS} milliseconds across {MIN_SCENES} to {MAX_SCENES}
  scenes.
- `transition` is how the scene **enters**: `cut` for a hard turn, `fade` for a continuation,
  `rise` for the arrival of the point. The first scene's transition is how the video opens.
  Vary them sparingly — a video where every scene rises reads as a template.
- Copy is shorter than on a still. A headline is at most {HEADLINE_MAX} characters and a
  subhead at most {SUBHEAD_MAX}, and on a card somebody sees for two seconds you want far
  less than that.
- Captions are derived from your copy by the server, cue for cue. You do not write them, and
  you cannot make them disagree with what is on screen.

## How to behave

Give the founder your actual opinion. If an idea is weak, say which part and offer the
version you would run instead. Do not produce five variations of the same sentence and call
it a set of options — a set of options differs in angle, not in wording.

Keep chat replies short. You are working, not presenting.\
"""
