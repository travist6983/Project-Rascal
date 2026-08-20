# Phase 97 — the social studio

**Aug 19, 2026. API lane. Branch `api/phase-97-social-studio`. Local only, nothing deployed,
nothing posted.**

The ask was *"image generation, video generation and captioning, and perhaps the ability to ask
for different types of images via a chat and our anthropic key."* Three of those four can be
done with an Anthropic key. One cannot, and the design turns on saying so.

---

## The fact that shapes everything

**Anthropic has no image endpoint and no video endpoint, on any model.** Claude takes text and
images *in* and produces text *out*. There is no configuration of `ANTHROPIC_API_KEY` that
produces a picture.

There were two ways to handle that. Build a "Generate image" button, wire it to a diffusion
vendor, and let the Anthropic key sit unused next to it — which answers the letter of the
request and leaves the interesting part on the floor. Or split the job at the seam that
actually exists:

**Claude is the art director.** It knows the product, the voice from
`docs/marketing/email-sequence.md`, and six hard rules. It writes angles, headlines, captions,
alt text, hashtags, image briefs and shot lists, and it picks the layout.

**The pixels come from a canvas.** `admin/static/cards.js` draws a brand card in the Vellum
palette at any platform size and exports it as PNG, or records the card settling in and exports
WebM. No vendor, no key, no per-image cost.

**A photographic renderer is a port.** OpenAI and Replicate, unconfigured by default, each
reporting the environment variable to set — the same shape phase 96's cost panel uses.

For a warm typographic brand whose posts are sentences, the card renderer is not a consolation
prize. A diffusion model asked for "a cream card with one line of terracotta type" produces
something differently wrong every time and cannot be told to hit `#C05A2B`. The template hits
it exactly, every time, and cannot draw anything that is not in the design system.

---

## What ships

| | Needs | Works tonight |
|---|---|---|
| Chat with an art director | `ANTHROPIC_API_KEY` | with a key |
| Post concepts — angle, copy, caption, alt text, hashtags, image brief | `ANTHROPIC_API_KEY` | with a key |
| Brand cards → PNG at any platform size | nothing | **yes** |
| Brand cards → WebM (the card settling in) | nothing | **yes** |
| Shot list + WebVTT caption track | `ANTHROPIC_API_KEY` | with a key |
| Photographic images | `OPENAI_API_KEY` or `REPLICATE_API_TOKEN` | no |
| Generated video footage | `REPLICATE_VIDEO_MODEL` | no |

Four templates (`quote`, `prompt`, `stat`, `announcement`), five palettes, six platform sizes.
The renderer **shrinks text until it fits** rather than clipping — a headline running off the
bottom is the one failure that makes an export unusable, and a model writing free-form copy
will produce one eventually however clearly the brief states a word count.

---

## The guard that took the most thought

`docs/decisions.md` D7: *"`api/seeds/prompts.yaml` and `docs/mission-library.md` never enter the
marketing repo, whole or in generated slices — a prompt sampler on the page is a hand-picked
handful, hard-coded, never a generated cut of the library. **It is the one asset in this project
a competitor would actually want.**"*

A social studio that can put a prompt on a card is a machine for producing exactly those slices.
Publicly. Permanently. One post at a time. **That is the shape of leak nobody notices, because
no single post looks like a problem** — and over a year of daily posting it is the whole library.

This is the first thing in the project that could have given that asset away by accident, so
the guard is structural rather than a note in a comment:

1. **Claude never sees the library.** No tool, no context, and the brief tells it not to invent
   lines that read like one. A test asserts a real library body is not reachable from the brief.
2. **Featuring a body is an explicit act.** The API takes a `featured_prompt_id` and reads the
   body server-side; a caller-supplied `featured_body` is ignored. Otherwise the ledger would be
   counting something other than the library.
3. **Every body is counted against a cap.** `SOCIAL_FEATURED_PROMPT_CAP`, default 24, shown on
   screen as a bar. Counted per **distinct prompt** — three posts about one prompt disclose one
   prompt — and a discarded draft does not count, which is enforced by a partial index rather
   than by whichever query remembers to filter.

The alternative was trusting the operator. Rejected because the risk is cumulative and
invisible, which is precisely the kind a person cannot hold in their head.

---

## Nothing posts anything

No platform integration, no scheduler, no publish route. Generate, review, download, and put it
out yourself. `status = "published"` is the owner recording that they did.

Two reasons. Open item 12 gates outbound marketing on the P0 behavioural test, and social is the
same spirit as email. And an automation that posts on its own is one bad generation away from
doing so under the product's name.

**Alt text is required** to move an asset to `exported` or `published`, checked at that moment
rather than at creation — a rule enforced while somebody is still typing is a rule that gets
switched off.

---

## Three bugs the browser found that no test would have

Worth listing because all three passed every assertion I had written.

**`display: flex` beat `[hidden]`.** `.panel` set a display value, which silently overrides the
UA stylesheet's low-specificity `[hidden] { display: none }`. Tabs highlighted correctly and
left the previous panel on screen. The DOM assertions all passed, because `hidden` was set
exactly as intended. (This one was phase 96's, found the same evening.)

**`requestAnimationFrame` does not fire in a background tab.** The WebM recorder was driven by
rAF, so recording from an unfocused tab hung forever with the button stuck on "Recording…". It
runs on `setInterval` now, with a hard deadline that resolves the promise regardless.

**The page's own CSP silently drops `style=` attributes.** `style-src 'self'` with no
`unsafe-inline` — which the console deliberately has — means an inline style in generated markup
never applies, with no console warning. The D7 ledger bar's fill inherited its track's width, so
**an empty budget drew as a completely full one**. A progress bar that lies, in the alarming
direction, about the one number this feature exists to keep honest. Tones and widths go through
data attributes and the CSSOM now.

---

## Numbers

- **891 tests pass**, 1 skipped, via `make test`. 32 new in `test_social.py`.
- `ruff check` / `ruff format --check` clean over `api/` and `.github/`.
- Migration `0018_social_assets`, up and down, trigger and both expectation lists updated.
- Eight new endpoints; 74 operations across 64 paths.
- **Zero new dependencies.** The model call is raw `httpx` against `/v1/messages`, matching
  `scripts/generate_prompts.py`, which has called that API from this repo since phase 46.

Model settings follow the current API: `thinking: {"type": "adaptive"}` and
`output_config.effort`, no `temperature` or `top_p` (both removed on Opus 5 and either is a
400), no `budget_tokens`, and `output_config.format` with a JSON schema for the structured
routes so there is no parse to fail and no retry loop.

---

## Open, and deliberately left

- **Nothing is deployed and no key is set**, so the model half is untested against the real API.
  The refusal path is tested; the success path is not. **That is the largest unverified claim
  in this phase** — set `ANTHROPIC_API_KEY` and run one concept set before trusting it.
- **No photographic provider is connected**, so `POST /social/assets/{id}/render` has never
  reached OpenAI or Replicate.
- **Video is a shot list plus an animated card, not generated footage.** Real footage needs a
  vendor and costs per second, which is why that path runs on demand and never on a schedule.
- **The chat has no memory.** The console holds the transcript and sends it back; a
  half-finished brainstorm is deliberately not in the database.
- **No scheduling, no queue, no auto-post**, and adding one is a decision about open item 12
  rather than a missing feature.
