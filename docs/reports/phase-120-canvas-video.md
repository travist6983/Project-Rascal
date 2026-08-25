# Phase 120 — the Gemini video renderer, replaced by a canvas-rendered scene graph

**API lane.** Branch `api/phase-120-canvas-video`, cut from `origin/main` at `b4a1f1a`. Nothing in
`ios/` is touched.

**In one sentence:** Claude now emits a typed scene graph, the console's own browser draws it with
the `cards.js` that already draws the stills, and the API re-encodes the recording — so no vendor
generates video for this product, a thirty-second treatment costs nothing instead of about $1.50,
and the caption track is derived from the scene copy rather than written beside it.

---

## The five preflight gates

Reported as evidence rather than as verdicts.

### Gate 0 — the phase number is **120**

| Measurement | Highest |
|---|---|
| `git log --all` subjects and bodies | 118 |
| `git for-each-ref refs/heads refs/remotes` | 119 |
| `gh pr list --state all --limit 200` | 118 |
| `grep -rhoiE 'phase[- ][0-9]+' docs/` | 119 |

Union max is **119**, so this is **120**. **The four do not disagree in the sense the gate warns
about.** 119 is `api/phase-119-health-liveness` — a branch that exists locally with uncommitted
work and entries already written into `decisions-log.md`, `api-contract.md` and `blocked.md`, but
no commit on any branch and no PR. That is a phase in flight, not a stale file. `roadmap-status.md`
tops out at 118 and had no row for 119 or 120; this phase adds only its own.

### Gate 1 — `GEMINI_API_KEY` is used for nothing but video. **Pass.**

`grep -rn "GEMINI" api/` returns 72 hits in four files and no others: `config.py` (the three
settings), `services/social/gemini.py`, `services/social/renders.py`, and
`tests/test_social_video.py`. Zero hits in `.github/`, zero in `README.md`. Three commented lines
in the repo-root `.env.example`. Nothing outside the video path reads any of them.

### Gate 2 — the deployed image has libx264. **Pass, and the image is unchanged.**

Verified in a fresh build of the Dockerfile's own runtime lines (`python:3.12-slim-bookworm` +
Debian `ffmpeg --no-install-recommends`), not on a laptop:

```
ffmpeg version 5.1.9-0+deb12u1
V....D libx264       libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
V....D libx264rgb    …
VFS..D vp8 · V....D libvpx · VFS..D vp9 · V..... libvpx-vp9
```

Encoder and both decoders present. **No `Dockerfile` change, no image-size change, no deploy
change.** (`rascal-api:local` on this machine has no ffmpeg at all — it predates the install and
is not the deployed image.)

### Gate 3 — `social_renders` today

| Where | Rows | With non-empty `clip_keys` |
|---|---|---|
| **Production** (`fly ssh console -a rascal-api`) | **0** | 0 |
| Local dev (`rascal` on :5434) | 3, all `failed` | **2** — one with 2 keys, one with 5 |

`social_assets` with a non-null `shot_list` in production: **0**. So `0023` migrates nothing live.

**Recorded rather than discovered, per the gate:** the two local rows point at **seven** objects
under `social/` in `rascal-media-dev`. The migration drops the pointer, not the bytes; those seven
are orphans. Nothing in production is affected because nothing in production exists.

`ADMIN_READ_DATABASE_URL` is not configured on this machine, so the production count came from
`fly ssh console` rather than from that connection.

### Gate 4 — the deletion enumeration, and **the one place the phase prompt is wrong**

The grep is the deletion list. It turned up one instruction that cannot be carried out:

> **There is no Gemini card on the costs panel, and there never has been.** The seven cards are
> `anthropic, github, fly, neon, tigris, resend, apple` — the registry is
> `services/billing/__init__.py:81-95` and the label table is `billing/format.py:19-27`. Nothing on
> `/v1/admin/costs` knows about Gemini, video renders, or `social_renders.cost_cents`. The phase
> prompt says to delete that card and make the seven-card panel six; **it stays seven and nothing
> in `billing/` is touched.** The only place video cost was ever computed is
> `renders.estimate_cents`, served on the asset's render status — that is deleted.

Everything else in the enumeration was real and is gone. Full list in the PR body.

---

## What changed

### The scene graph replaces the shot list

`VideoScene` and `VideoTreatment` live in **`schemas/social.py`**, not `models/social.py` as the
phase prompt says. `models/` in this repo is SQLAlchemy ORM only; every Pydantic wire model is in
`schemas/`, and `CardTemplate`/`CardPalette` — the `Literal`s these extend — are already there.
Putting a `BaseModel` in `models/social.py` would have been the first one.

```python
class VideoScene(ApiModel):
    template: CardTemplate       # the same closed set a still card uses
    palette: CardPalette
    eyebrow: str | None          # ≤ 40
    headline: str                # 1..120
    subhead: str | None          # ≤ 180
    duration_ms: int             # 1200..8000
    transition: SceneTransition  # cut | fade | rise — how this scene ENTERS

class VideoTreatment(ApiModel):
    scenes: list[VideoScene]     # 2..10, summing to 6000..60000ms
```

**The copy limits are derived from the renderer, not guessed.** `cards.js` never clips — `fitBlock`
steps the type down — but it stops at a floor and then overflows silently, so the limit comes from
the geometry at that floor. The tightest case **among the two sizes a treatment records at** is a
`stat` headline on a 1080×1350 feed card *with* an eyebrow. (`PLATFORM_SIZES` also holds three
landscape sizes, which are shorter and tighter still; they are card sizes and `VIDEO_PLATFORMS`
excludes them.) margin 96, inner width 888, available height 1036, `stat`'s box is
half of that at 518, floor 72px at lineHeight 1.02 → 7 lines, ~22 characters a line at a
conservative 0.55em → **~154 characters before anything overflows**. 120 leaves a fifth in hand.
The working is in `brand.py` beside the constant.

**`caption_track` is derived and cannot be authored.** `services/social/scenes.py` computes it
from the scene copy and the cumulative durations — one cue per scene, boundaries exactly the scene
boundaries, integer milliseconds throughout. The half that makes that *true* rather than merely
*current* is the removal: `caption_track` and `duration_seconds` came off `SocialAssetIn`,
`SocialAssetUpdate` and `studio.EDITABLE`, so no caller can write one.

`POST /social/shot-list` → **`POST /social/treatment`**.

### The renderer is the browser

`admin/static/timeline.js` is new. Its centre is `sceneAt(scenes, tMs)` — no canvas, no clock, no
DOM, no state — beside the two functions it is built on (`boundaries`, `totalMs`) and the
`ENTER_MS` table the transitions are timed by. It is a file of its own so the part whose
correctness matters can be read without running it, which for months was the only assurance the
browser half had. Its running sum is the same integer sum
`scenes.py` walks, which is what makes "the captions line up with the cards" a property.

`cards.recordTreatment()` paints each scene **once** into a full-size offscreen canvas — a card is
static within its scene, so re-running the type fitter sixty times a second is the same work
repeated — then composites with `drawImage` per frame, captures with `canvas.captureStream(30)`,
and records with `MediaRecorder` (vp9, falling back to vp8 via `isTypeSupported`).

**Motion doctrine: three transitions, high density, low amplitude.** `cut` is a hard switch with no
window. `fade` is a 260ms crossfade. `rise` is a 340ms fade from the background plus a 14px upward
settle at 1080 wide, scaled with the card. No scale, no rotation, no parallax, no per-character
animation.

### The route takes bytes, synchronously

`POST /social/assets/{id}/video` is now the exact shape `POST /social/assets/{id}/image` already
was: `Content-Type: video/webm`, raw body, **64MB cap**, EBML magic number (`1A 45 DF A3`) checked.
The server re-encodes with `-c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -an -movflags
+faststart` under a 180-second hard timeout and answers **200 with the completed `social_renders`
row**. The 202-and-poll, the poll loop in `admin.js`, the staleness reaper and the "a render is
already running" 422 are all gone.

**Never a stream copy**, and the reason is not aesthetic: `MediaRecorder` writes an *unknown*
duration into the WebM header, so a copy carries that straight through and everything downstream
reads `N/A`. The re-encode recomputes timestamps from the frames.

### The migration

`0023_canvas_video`: `social_assets.shot_list` → `treatment`, `social_renders.shots_total` →
`scene_count`, `social_renders.clip_keys` dropped. Up, down and up again, tested with rows present
in both tables at the revision *before* 0023 using the old column names.

**The `social_assets` rename is one step more than the phase asked for** — it specified
`social_renders` only. The column held `visual`/`on_screen_text`/`voiceover` and now holds a scene
graph; a column called `shot_list` holding one is exactly the kind of name that survives a rewrite
and misleads everyone after it.

### What was deleted

`services/social/gemini.py` (286 lines) · `services/social/stitch.py` (225 lines, replaced by
`transcode.py` keeping only the re-encode) · `GEMINI_API_KEY`, `GEMINI_VIDEO_MODEL`,
`GEMINI_VIDEO_CENTS_PER_SECOND` and their `.env.example` block · `renders.estimate_cents` ·
`renderers.caption_track` (moved to `scenes.py` and rewritten) · `SHOT_LIST_SCHEMA` ·
`shot_list_instruction` · `ShotListIn` · the two Gemini sections of `runbook-admin-console.md`, plus its `GEMINI_API_KEY` table row.

**`fly.toml` secrets are deliberately untouched.** Removing a secret from Fly is a separate manual
act: `flyctl secrets unset GEMINI_API_KEY GEMINI_VIDEO_MODEL GEMINI_VIDEO_CENTS_PER_SECOND -a
rascal-api`. Nothing reads them.

---

## Verification — executed vs. reasoned about

**Executed, server side.** `1334 passed, 1 skipped, 0 failed`, with a Postgres 16 client on
`PATH`; without one, two `test_restore.py` tests fail on `pg_dump 17`'s `transaction_timeout`,
which the Makefile already documents and which is not this phase's.

**Executed, end to end.** Five complete treatments written by Claude, saved, recorded by a real
browser through the console's own Record button, uploaded, transcoded and probed:

| Scenes | Runtime | Output | Drift | Size |
|---|---|---|---|---|
| 7 | 21.6s | h264 · 1080×1920 · yuv420p · 30fps · **0 audio** | 33ms | 305KB |
| 5 | 14.7s | same | 33ms | 256KB |
| 4 | 11.4s | same | 33ms | 221KB |
| 4 | 14.0s | same | 33ms | 249KB |
| 5 | 16.2s | same | 33ms | 309KB |

`cost_cents: 0` on every one. The transcode took **1.0 second** for the 21.6-second recording.
Every drift is exactly 33ms — one frame at 30fps — which is the deliberate extra
`requestAnimationFrame` after the final draw, not noise.

**Executed, browser side — and this is new.** `api/scripts/verify_recorder.py` drives `cards.js`
in a headless Chrome over the DevTools protocol and asserts nine outcomes `pytest` cannot reach:
the ordinary path, a throwing progress callback, a tab hidden mid-record, a tab hidden in the one
frame between the final draw and `stop()`, a tab hidden with `requestAnimationFrame` genuinely
parked, a recorder whose `stop()` never fires, a construction failure, the two refusal guards, and
listener/track leaks across three consecutive recordings. All nine pass.

**Two of those cases found live bugs**, which is the case for the harness existing:

- A hidden tab parks the `requestAnimationFrame` that holds the trailing `stop()`. The abort guard
  correctly declined to abort a complete recording — and then nothing stopped the recorder, so the
  watchdog abandoned it fifteen seconds later and blamed the recorder for the tab.
- **The first version of that test passed against the bug.** Stubbing `visibilityState` does not
  park a callback that is already queued, so the trailing `stop()` still ran. The test now wraps
  `requestAnimationFrame` and holds callbacks at the moment they would fire, which is what the
  browser does — and with the fix reverted it reproduces the bug exactly: one callback held,
  eighteen seconds, wrongly rejected.

**Mutation-tested, not merely green.** Every bound, guard and derivation in the diff was broken
deliberately and watched fail for the right reason: the three closed sets, the scene and treatment
duration bounds, the scene-count bounds, both copy limits, the WebVTT escaping, the negative-
duration clamp, the schema-keyword guard, the length check in both directions, the ffmpeg checks
on both sides, `-fflags +genpts` and its position, `-nostdin`, the CFR rate, `exc_info`, the
studio payload's key set, the transition table in both directions, and `stamp`'s minutes.

**The backgrounded-tab guard was exercised for real**, not reasoned about: it refused, in the
interactive Chrome, with *"Bring this tab to the front before recording."*

**Every recording was made in a headless Chrome, and that is worth stating plainly.** The terminal
application on this machine holds macOS frontmost and will not yield it, so the interactive tab
reported `visibilityState: "hidden"` however it was activated — which the guard correctly refused,
and that refusal is the only observation of it firing in a windowed browser. Same Blink renderer,
same modules, same `MediaRecorder`, real 30fps wall-clock capture. What was *not* exercised is a
person pressing the button in a windowed Chrome.

**Not verified: anything on Fly.** The ffmpeg codec check ran against a fresh build of the
Dockerfile's runtime lines, not a deployed machine. No part of this has run in production.

---

## Three review rounds, 120 verified findings

Every finding was independently verified against the real files before being acted on, and the
sharpest ones were defects in this phase's own work.

**Round one — 29 findings.** The `failed` render row was destroyed by the error it exists to
record (`get_session` rolls back on any exception out of a handler, so the route returned a
correct 422 having left no trace). `UNSUPPORTED_SCHEMA_KEYWORDS` was dead data described by two
comments as guarded by a test that did not exist — the phase 101 defect, committed by the phase
that cites it. The 64MB cap was enforced only on `Content-Length`, absent entirely on a chunked
request. A blank line in a headline split its own WebVTT cue.

**Round two — 41 findings.** **Five bounds tests were passing for the wrong reason.** A two-scene
graph built from the module's default scene totals 4700ms, under the 6000ms treatment floor, so
every one of them was refused for its *runtime* whatever the field under test contained — and
stayed green with the bound deleted. A mutation run proved it. They now use a pair over the floor
and assert the exact `error.field`. The same round found that the account of the caption-track
defect, written into five files, was false: Claude never authored a WebVTT track; the server
derived it, and the real defect was that it was stored in an editable column nothing recomputed.

**Round three — 50 findings.** The `video` block on `GET /social/studio` served eight keys of
which the console read two, with a test docstring asserting the opposite and a comment in
`admin.js` denying a second copy of `VIDEO_PLATFORMS` four lines above one. Phase 101 again. It is
now the two keys that are read, and the fallback is gone. `DURATION_TOLERANCE_SECONDS` turned out
to be pinned nowhere — its two tests bracketed it at (0.0, 7.0) — and is now bracketed at
(0.2, 0.5).

**One fix was worse than the defect it fixed, and the break-test caught it.** The first attempt at
the whitespace-headline guard was an `after`-mode validator returning `None` for an empty string —
which Pydantic assigns to a required `str` without complaint. Running the mutation revealed both
that and the fact that the test proving the fix was itself passing for the wrong reason.

## One adjacent defect fixed, and one named but not fixed

**Fixed:** `GET /social/renders/{id}/file` did not exist, and the console's *Open the film →* button
has been calling it since phase 103. Nothing caught it — `admin.js` has no test runner, no
authorization sweep covers a route that is not registered, and the button only renders after a
render succeeds, which on a paid path had never happened in production. It exists now and is in
`ALL_ROUTES`. Fixing it is scope creep by the letter and the opposite by any honest reading.

**Named, not fixed:** `cards.recordCard` — the four-second single-card WebM export, untouched by
this phase — drives itself with `setInterval` and carries a comment saying that is *because* rAF
does not fire in a background tab. `setInterval` is clamped to one second in a background tab, so
that path produces a 4-frame clip rather than a short one: the same class of silent degradation
this phase makes impossible for treatments. Out of scope; recorded in `decisions-log.md`.

**Also named, not fixed (pre-existing):** the composer has an Eyebrow field that `cards.js` draws
and `composerPayload` never sends, so it is lost on save. That predates phase 120 — `eyebrow` has
never been a column on `social_assets`.

---

## The accepted losses

**No voiceover.** A canvas capture has no audio track. This is a real regression and it is
accepted: the voiceover was prompt-directed with no script parameter, no voice selection and no
guarantee of verbatim delivery, so it was never a controllable asset — and the brand is
typographic, so on-screen copy plus the derived cues is the register anyway. `-an` is the one line
a later TTS pass changes.

**No photographic footage.** Every output is a drawn card. If that turns out to be wrong, the scene
graph is the contract and a `source: "generated"` scene extends it without touching the renderer,
the transcoder, the closed sets or the derived captions — which is the point of a typed graph
rather than prose.

**Remotion was considered and declined**, on the owner's call. It is a better renderer in the
abstract — frame-exact, no tab-focus problem, audio trivial later — and it would mean reimplementing
`cards.js` as React components and adding Node plus a headless browser to a Python image: two
renderers that drift silently, which is the failure the whole split exists to prevent.

---

## Ranked confidence

**Most confident, in order:**

1. **The derived caption track.** Integer arithmetic over one input, one running sum in the
   module and the same clamp the browser applies, asserted against independently computed
   boundaries on uneven durations, with the write paths closed so it cannot be authored, and the
   reserved characters escaped. Break-tested six ways.
2. **The closed sets and the bounds.** `Literal`s asserted equal to `brand.py` at import time,
   every one exercised against `""` and an unknown value, every bound tested on both sides with
   the just-inside value too, and each one now asserting the field the refusal names. Every one
   was green under mutation before this was fixed, which is why the assertion changed.
3. **The transcode's output, and the length check.** Five real files probed for codec, pixel
   format, dimensions, frame rate, audio stream count and duration. The server now refuses a film
   short of its graph, which makes the silently-short file impossible rather than guarded against.
4. **The migration.** Up, down and up with rows present at the pre-0023 revision using the old
   column names, asserting the data moved and that the downgrade restores an empty `clip_keys`
   rather than inventing keys.
5. **The synchronous route and its failure path.** Both paths write a row, both are read back
   through a fresh session, the commit-before-raise is break-tested, and an unexpected failure
   carries its traceback while an expected one does not.

**Least confident, in order:**

1. **The interactive-Chrome path.** Every recording and all nine harness cases ran headless. Same
   modules, same Blink, but "the same code" is an argument rather than an observation, and the one
   thing a windowed browser was observed doing is refusing.
2. **The `visibilitychange` race, beyond what the harness simulates.** The harness parks
   already-queued rAF callbacks, which is what a hidden tab does — but a real tab also throttles
   timers, suspends the compositor and may fire `visibilitychange` at moments the simulation
   cannot produce. The two cases that exist are the two that were reasoned about; a third that
   nobody has thought of is not covered.
3. **`video.ffmpeg` is `shutil.which`, not a codec probe.** An ffmpeg present but built without
   `libx264` reports available, the console offers the button, and the failure arrives after the
   operator has sat through a recording. Documented in the runbook; not detected.
4. **The 33ms drift is asserted loosely.** Consistent across five recordings and explained, but
   the assertion is a 0.25s tolerance, so a real timing regression of up to seven frames would
   pass. Tightening it would make the test flaky on a loaded machine, which is the wrong trade —
   but it is a looser guard than it looks.
5. **Old-shape `treatment` documents.** Production holds zero, so nothing live is affected, but a
   dev database with a pre-120 `shot_list` gets a row whose `treatment` has no `scenes` key and
   whose `caption_track` describes a video that can no longer be made. The post refuses to record
   with *"no treatment to record"*, which is correct, and the stale track sits beside it.
6. **`RENDERER_VERSION = "cards-v1"`.** A promise about a future edit that nothing enforces. It is
   the weakest thing in the diff and deliberately so; the alternative is hashing `cards.js`, which
   changes on a comment.

## Documents

**Edited directly, in this PR:** `api-contract.md` (the three route changes, the bytes-through-the-
API rule now covering two routes, and two orphaned table rows that have rendered as a stray
one-column table since phase 103), `data-model.md` (`social_renders` and the three `social_assets`
video columns), `runbook-admin-console.md` (the two Gemini sections and a table row, replaced by the four things
that actually go wrong now), `roadmap-status.md` (a row), `decisions-log.md` (eight entries).

**Proposed, never applied:** `docs/reports/phase-120-proposed-diffs.md` carries the exact
replacement text for `decisions.md` (the ffmpeg/Veo row reversed in full with its finding kept, the
"a render is a row" row amended rather than struck, and a new settled row), `phase-queue.md` (the
render-and-read-the-invoice errand, closed by removal), and `CLAUDE.md` (the transcode scope line,
narrowed further).
