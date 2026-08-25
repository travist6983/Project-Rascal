# Phase 120 — proposed diffs

**Nothing in this file has been applied.** `decisions.md`, `phase-queue.md` and `CLAUDE.md` are the
three surfaces phase 120 was told to propose against rather than edit. `api-contract.md`,
`data-model.md`, `runbook-admin-console.md`, `roadmap-status.md` and `decisions-log.md` were edited
directly, in the PR.

Each block below is the exact replacement text. Rows are **struck rather than deleted**, in this
repository's existing reversal style: the claim is struck with `~~…~~`, an em-dash clause in bold
names the date and the phase that superseded it, and the original reasoning is kept because a
finding can outlive the decision it produced.

---

## 1. `docs/decisions.md:150` — the ffmpeg/transcode row, and the `veo-3.1-lite` default inside it

**Reversed in full.** The row is the one that authorised the transcode line being crossed *and*
carries the model-default reversal as a struck clause. The transcode authorisation survives and
narrows; everything about generating clips goes.

**The finding survives in the strike text and that is deliberate.** A safety filter that refused a
static shot of a photograph captioned *"Why did you take this one?"* — ordinary product copy, with
nothing to appeal — is the strongest argument in this file for not routing brand copy through a
model whose refusals you cannot inspect. It is now the argument *for* the thing that replaced it.

### Replace the whole of line 150 with:

```
| ~~**The studio renders video by generating a clip per shot and joining them with ffmpeg — deliberately crossing the transcode line**~~ — settled Aug 20, 2026; **reversed Aug 25, 2026 by phase 120, and the reason is the finding this row already contains.** | **No vendor generates video for this product any more.** Claude emits a typed **scene graph** — 2–10 cards, each naming a template, a palette, a transition, its copy and a duration, every value from a closed set — and the pixels come from `admin/static/cards.js`, the renderer that already draws the stills, animated over a timeline and captured with `MediaRecorder`. There are no clips, so there is nothing to join. `services/social/gemini.py` and `stitch.py` are deleted; `GEMINI_API_KEY`, `GEMINI_VIDEO_MODEL` and `GEMINI_VIDEO_CENTS_PER_SECOND` are gone. **A thirty-second treatment cost about $1.50 and now costs nothing.** ~~**No video API on any vendor joins clips.** Gemini's Omni Flash generates 3–10 seconds; Veo does 4, 6 or 8; Veo's extend produces one continuous scene rather than seven distinct shots. A thirty-second treatment is therefore seven generations and a concatenation, and the concatenation has to happen somewhere.~~ That was true and is no longer load-bearing: the question it answered — *how do we get thirty seconds out of a model that makes eight* — stopped being asked the moment the renderer became a canvas we already own. **The transcode authorisation survives and narrows rather than widening.** `CLAUDE.md` listed "thumbnail or transcode pipelines" as out of scope; the strike stays, and now covers **one WebM in, one H.264 MP4 out**, for marketing output under `social/` that *this repository's own browser* recorded seconds earlier. It no longer covers concatenation, because there is nothing to concatenate. Thumbnails, transcoding user media and anything touching `children/` remain out of scope and remain the thing that rule was protecting. ~~The concat is a stream copy where the inputs allow it — one model, one resolution — with a re-encode fallback, so the common path is lossless and fast.~~ **The re-encode is now unconditional and a stream copy would be a bug**: `MediaRecorder` writes an *unknown* duration into the WebM header, so a copy carries that straight through and everything downstream reads nothing. **The model-default reversal below is kept in full, because its finding is the strongest argument in this file for the decision above.** ~~**`gemini-omni-flash-preview` over Veo** because Google's own video overview names it the default and it is the only model whose docs claim on-screen text renders legibly, which every shot in a Vellum treatment needs.~~ — reversed Aug 21, 2026 by phase 106, on evidence rather than on a re-reading of the same docs. The first render past billing **refused shot three of a real treatment as "harmful content"** — a static shot of a photograph, captioned *"Why did you take this one?"* — and every Veo 3.1 tier accepted the identical prompt byte for byte. It is ordinary product copy, there is nothing to appeal, and a safety filter that declines a still life cannot be planned around. **That is now the argument for the canvas**: a renderer we own cannot refuse our own copy, cannot be shut down mid-preview, cannot reprice, and draws the palette to the hex value rather than approximately. ~~The default is `veo-3.1-lite-generate-preview`, which is also half the price.~~ **The two promises the row named are settled rather than pending.** The voiceover was prompt-directed with no script parameter and no guarantee of verbatim delivery, so it was never a controllable asset — it is now **gone**, accepted as a real regression, and `-an` in the ffmpeg command is the one line a later TTS pass changes. Every video model on that API being preview is no longer a risk this product carries. **What would reverse this**: a vendor shipping a video model that takes a **script** parameter and renders **exact** on-screen text, at which point a `source: "generated"` scene can be added to the graph without touching anything else — which is the point of making it a typed graph rather than prose. |
```

---

## 2. `docs/decisions.md:151` — "A render is a row" — **amended, not struck**

The row survives; its *reasoning* does not. One row per attempt and a cost recorded on failure are
still right and are still the design. Clips-as-they-land and sequential generation are gone with
the vendor that made them necessary.

### Replace the whole of line 151 with:

```
| **A render is a row, and the money is recorded as it is spent** — settled Aug 20, 2026; **reasoning amended Aug 25, 2026 by phase 120, the row itself unchanged** | `social_renders` is one row per *attempt*, not a column on the post: a post stays editable after a file is made, so a table that read the current draft to say what was rendered would be rewriting history. **A cost is recorded on the failure path as well as the success path**, and phase 120 is why that clause is worth keeping rather than dropping: the number is now **zero**, and it is still written down, because a ledger that stops recording when the number becomes zero is a ledger that cannot show you it went to zero. It is also the column a future generated-footage path needs back. ~~It takes minutes, it can fail on the seventh of seven clips, and a retry must not erase what the first attempt already bought. Clips are stored and costed as they land, so a job that dies at shot six still says it spent six clips' worth.~~ ~~Generations run **sequentially** because Google's published limit is a rolling ten-minute *spend* cap rather than a request rate, so firing seven at once is the shape most likely to hit it and hitting it halfway pays for nothing.~~ ~~Every guard — no shot list, no key, no ffmpeg, one already running — runs **before the first clip**, because the expensive failure is not a refusal, it is discovering there is no ffmpeg after paying for six clips.~~ — **all three struck.** There are no clips, no vendor and no spend cap, and the work is a few seconds of ffmpeg **inside the request**, so nothing can be left running: the 202-and-poll, the staleness reaper, the *"a render is already running"* 422 and the session-poisoning recovery path all went with them. **Two guards remain and both still run before the browser is asked to record**: no scene graph, and no ffmpeg on the machine. **`queued`, `running`, `cancelled` and `uq_social_renders_one_live_per_asset` are kept unwritten rather than dropped**, on the same argument as `cost_cents`: they are the shape an asynchronous path needs on the day one exists. |
```

---

## 3. `docs/decisions.md` — a **new settled row**, to be appended to `### Technical`

```
| **Claude emits a typed scene graph, the browser draws it, and no vendor generates video for this product** — settled Aug 25, 2026, phase 120 | This is the split phase 97 already settled for images, applied one level up. Claude does the part it is good at — picking a layout and writing the words — and the pixels come from a template renderer that cannot draw anything outside the design system. A video is now an ordered list of the *same cards*: `template` and `palette` from the same closed sets a still uses, a `transition` from `cut \| fade \| rise`, copy, and a `duration_ms`. `admin/static/cards.js` draws every frame and `MediaRecorder` captures the canvas; the API re-encodes the recording to H.264 and stores it. **The renderer is the browser deliberately, and that is a constraint rather than a shortcut.** `drawCard` is the only implementation of a Vellum card in existence; a second one server-side would be a second thing to keep in step with `design-system.md`, and it would put Chromium in a Python image to run it. **Remotion was considered and declined for exactly that reason** — it is a better renderer in the abstract (frame-exact, no tab-focus problem, trivial audio later) and it would mean reimplementing `cards.js` as React components and adding a Node toolchain plus a headless browser to the deploy: two renderers that drift silently, which is the failure this row exists to prevent. **The caption track is derived from the scene copy and the cumulative durations**, one cue per scene, boundaries exactly the scene boundaries — and `caption_track` is not settable by a caller, which is what makes *derived* a property rather than a description of the current state. **What is given up, stated rather than discovered**: there is no voiceover, because a canvas capture has no audio track, and there is no photographic footage, because every output is a drawn card. **What would reverse it**: a product need for real footage — a founder-to-camera cut, a screen recording of the app — at which point the typed graph is the contract and a `source: "generated"` or `source: "clip"` scene extends it without touching the renderer, the transcoder, the schema's closed sets or the derived captions. A cost argument would not reverse it; the canvas is free and the brand is typographic. |
```

---

## 4. `docs/phase-queue.md:733–739` — the open errand that no longer exists

The queue carries *"Render one full treatment end to end, and read the invoice afterwards"*. There
is no invoice. Strike rather than delete: the *other* half of that bullet — that nothing had
exercised the pipeline against real vendor output — is the observation that made this phase
possible to argue for.

### Replace those seven lines with:

```
- ~~**Render one full treatment end to end, and read the invoice afterwards.** Gemini billing is
  enabled and phase 106 proved the path with **one four-second clip**. A real treatment is seven
  generations plus an ffmpeg concatenation, and **nothing has exercised the concatenation against
  clips a vendor actually produced** — only against fixtures. The other half is the number:
  `GEMINI_VIDEO_CENTS_PER_SECOND` is 5 because Google publishes $0.05 a second, and **that figure
  has never been reconciled against a Google invoice**, so the console is currently showing an
  estimate somebody typed. One render settles both.~~ — **struck Aug 25, 2026 by phase 120, and
  closed by removal rather than by doing it.** There is no invoice to read and no price to
  reconcile: a treatment costs nothing. **The observation this bullet actually recorded is the one
  worth keeping** — that a paid path had never once run end to end in production, only against
  fixtures — and it is the reason the replacement was arguable at all. Three real treatments have
  now been recorded and transcoded end to end through the console's own button, and the deleted
  `estimate_cents` is the last figure somebody typed that anybody had to trust.
```

---

## 5. `CLAUDE.md` — the transcode scope line

The line is already struck once, narrowly, for the concat. It **narrows further** rather than
widening: concatenation is gone and the input is now something this repository's own browser
recorded rather than something a vendor generated.

### Replace the `~~*thumbnail or transcode pipelines*~~` paragraph with:

```
~~*thumbnail or transcode pipelines*~~ — **struck for one feature and one only, by the owner's call of Aug 20, 2026, and narrowed further by phase 120 on Aug 25, 2026.**

**What it covers now: one WebM in, one H.264 MP4 out.** The studio's video is an ordered list of
brand cards; `admin/static/cards.js` draws every frame in the operator's own browser and
`MediaRecorder` captures the canvas, and `services/social/transcode.py` shells out to ffmpeg to
re-encode that recording into the format a platform will accept. The runtime image installs
ffmpeg. That is a transcode pipeline by any honest reading and it was authorised deliberately
rather than argued around; `docs/decisions.md` carries the reasoning.

~~*The studio's video render generates a clip per shot — no video API on any vendor joins clips —
so `services/social/stitch.py` shells out to ffmpeg to concatenate them.*~~ — **struck by phase
120: there are no clips.** The browser records one continuous capture, so there is nothing to
concatenate and `stitch.py` is deleted. The strike **narrows**, which is worth saying plainly
because a struck scope line is the sentence an agent quotes when it deletes something: the input
is no longer a vendor's output at all, it is bytes this repository's own console recorded seconds
earlier.

**It is struck narrowly.** Thumbnails, transcoding *user media*, and anything touching the
`children/` prefix remain out of scope and are the thing the original line was protecting: an
archive that re-encodes what a parent uploaded is an archive that can corrupt it. This re-encodes
marketing output under `social/` and never reads a family's bytes.
```

---

## 6. `CLAUDE.md` — the LLM-generation scope paragraph, one clause

The paragraph beginning `~~*LLM prompt generation, the admin prompt review queue*~~` ends with a
list of what *is* still out of scope. One clause there is now wrong in the direction that matters:
it implies pixels for video come from a vendor.

### Add to the end of that paragraph:

```
**Phase 120 adds one to that list and removes one from the tree.** Still out of scope: nothing
generates a prompt at request time for a child, nothing activates a candidate, and no bulk-approve
endpoint exists. **No longer true of this repository: that video pixels come from a vendor.** They
come from `cards.js`, in the console's own browser, and `GEMINI_API_KEY` is gone. Check `api/`
before writing a line here — this file already records that three entries were struck for naming
shipped subsystems, and two of them named code that existed when the line was written.
```
