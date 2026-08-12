# Entry Detail v2 — design import inventory

Phase 22, `ios/phase-22-entry-detail-v2`, off `main` @ 17e1ad2. Written 2026-08-11.

**This run ends here, at the end of §1, and that is the recommended outcome rather than a
failure.** The reason is one design decision that is not mine to make — see
[§6 Recommendation](#6--recommendation-why-this-stops-at-the-inventory). Everything §1 asked for
is below.

---

## 1 — Provenance: what was read, and how

**The MCP import succeeded.** No fallback to `docs/entry-detail/` was needed.

The `claude_design` MCP named in the brief is not connected to this session, but the design
project is reachable through the `DesignSync` tool's read methods against the same project id:

```
get_project  e227a63f-e516-4426-8074-eb12edd15ad2
  → { name: "Rascal App", type: PROJECT_TYPE_PROJECT, canEdit: true }
```

Read in full: `RASCAL Entry Detail.dc.html`, `tokens/colors.css`, `readme.md`, `SKILL.md`,
`image-slot.js`, `support.js`.

**The skill came with it.** `SKILL.md` at the project root is `rascal-design` — "essential design
guidelines, colors, type, fonts, assets, and UI kit components". Its `readme.md` is the brand's
own written system and is the authority this inventory reconciles the export against, alongside
`docs/design-system.md`. Two of the conflicts below are the export disagreeing with **its own**
design system, not with ours.

### The two imported JS files, characterised honestly

- **`image-slot.js`** (64.8 KB) self-declares as scaffolding on line 1:
  `// @ds-adherence-ignore -- omelette starter scaffold (raw elements/hex/px by design)`. It is a
  drag-and-drop image placeholder web component. The only thing it contributes to intent is the
  attributes the export sets on it: `shape="rect" fit="cover"` inside `position:absolute;inset:0`
  — i.e. **media fills its frame edge to edge, cover-cropped, never letterboxed.**
- **`support.js`** (70.6 KB) is `dc-runtime`, the generated React runtime for the `.dc.html`
  format (`x-dc`, `sc-if`, `sc-for`, `DCLogic`). The brief asks that it be read for motion timing
  intent. **It contains none** — grepping it for `cubic-bezier`, `ms` durations and `transition:`
  returns nothing. All motion in this design is inline in the HTML, and per the brief it is
  superseded by `docs/design-system.md` regardless.

---

## 2 — Every state, region and control in the export

The export's own thesis, from its header: *"Media fills the screen. Everything else — the caption,
his age, the date, the prompt that started it — lives in a cream sheet resting on top of it. One
grammar, seven kinds of entry: the layer behind the sheet is the only thing that changes."*

### Regions common to all seven

| Region | Detail |
|---|---|
| Status bar | Simulated 52px iOS chrome. Prototype furniture — not ours to build. |
| Back affordance | 40px circular button, top-left, inset 16px, at `top:62px`. |
| Overflow menu | 40px circular `⋯` button, top-right. Maps to today's toolbar menu (Edit / Delete). |
| Bottom sheet | Rounded `26px` top corners, sits on the bottom edge, holds all text content. |
| Grab handle | 38×5px rounded bar, `#DCD2C4`, centred at sheet top. |
| Home indicator | 134×5px bar, ink at 22% — prototype furniture. |
| Scrim | Top gradient `rgba(20,18,26,.5) → transparent`, 150px tall, over media only. |

### The seven states

| # | State | Backdrop | What the sheet holds | New controls |
|---|---|---|---|---|
| 01 | **Photo** | Full-bleed photo, cover | Title, age chip, date-time. Expands to: prompt block, "Assigned" line, tag chips, **Edit entry** + **Share** buttons | Tap handle to expand; `⤢` to hide chrome (immersive); tap-anywhere to restore |
| 02 | **Ten photos** | Full-bleed photo | Horizontal **thumbnail strip** (56px, 12px radius, first ringed in accent), title, body, age chip, "date · 10 photos" | `1 of 10` counter pill; strip |
| 03 | **Video** | Full-bleed still | **Scrubber** (elapsed / track / knob / duration), title, body, age chip, "date · 0:42" | Centre 76px play button; scrubber |
| 04 | **Voice** | Lavender gradient wash | Title, transcript excerpt, **"Read the whole thing"**, age chip, "date · 1:47" | 84px periwinkle play disc; 44-bar waveform; `0:00 / 1:47` |
| 05 | **Written** | Flat canvas `#FDFAF4`, no glass | Age chip, date, tag chips. Content sits *above* the sheet: a periwinkle **"The question"** card, then a 26px Nunito title, then body | — |
| 06 | **Did it** | Sage gradient wash | Note line, age chip, date, "Did it" chip | 74px white disc with a sage check; prompt rendered as the 28px hero |
| 07 | **Sealed letter** | Peach→pink gradient wash | Age chip, "Sealed <date>", **lock row**: "Opens 19 June 2040" + "13y 10m" | Envelope motif (214×150 card, triangular flap, 56px wax seal reading `R`) |

### What the export does right, and it matters

**State 06 answers the three-completion-shapes trap correctly.** A did-it entry has no artifact, and
rather than leaving a hole the export promotes the prompt to hero type over a sage wash with the
line *"Nothing was recorded. That's allowed — it still happened."* That is the correct instinct and
it should survive into whatever gets built.

**State 07 renders no media and no body.** The sealed state is genuinely closed — see Q3 for the
part that is wrong.

---

## 3 — Token reconciliation

**Rule applied, not relitigated:** `tokens/colors.css` + `Palette.swift` outrank a hardcoded value
in the prototype. No new `Palette` constants proposed.

This is the **fourth consecutive export** to hardcode values its own `tokens/colors.css` does not
contain (after Moments, Today and Settings). As before, the token file matches `Palette.swift`
almost exactly.

### Mapped cleanly — export value is the token

| Export | Used for | `tokens/colors.css` | `Palette.swift` |
|---|---|---|---|
| `#C05A2B` | accent, wax seal, scrubber, primary button | `--rascal-terracotta` | `terracotta` |
| `#5566D6` | age-chip text, voice UI | `--rascal-peri` | `periwinkle` |
| `#E9EBFB` | age-chip fill, question card, "Written" chip | `--rascal-lav` | `periwinkleSoft` |
| `#23253C` | ink | `--rascal-ink` | `ink` |
| `#6E6A63` | every secondary line | `--rascal-muted` | `inkMuted` |
| `#FFFDF9` | sheet / card surface | `--rascal-surface` | `surface` |
| `#FDFAF4` | written-state canvas | `--rascal-canvas` | `canvas` |
| `#EDE5DA` | hairline | `--rascal-border` | `border` |
| `#FBEDE2` | peach chip, sealed lock row | `--rascal-peach` | `terracottaSoft` |
| `#E8F0E6` | "Did it" chip | `--rascal-sage` | `sage` |
| `#FDE8DC → #F7DDE8 → #FBF6EF` | **sealed wash** | ✗ | **`Gradients.wash` — exact match, already sanctioned** |

### Unmapped — hardcoded in the export, absent from its own tokens

| Export | Used for | Nearest sanctioned | Resolution |
|---|---|---|---|
| `#5E7A57` | did-it check stroke | `sageInk` `#4B7A4F` | Use `sageInk`. The export invented a second sage ink. |
| `#A8A096` | dim/placeholder text | `inkFaint` `#B4ADA3` | Use `inkFaint`. |
| `#F2EBE0` | neutral tag chip fill | `chipPlain` `#F4EEE5` | Use `chipPlain`. |
| `#DCD2C4` | sheet grab handle | `border` `#EDE5DA` | Use `border` — or moot, the handle goes with the expansion (Q2). |
| `#E6DCCE` | divider, scrubber track | `border` `#EDE5DA` | Use `border`. |
| `#D9CFC0` | dashed "Add tag" border | `--rascal-ink-disabled` is `#D9CFC2` — one digit off; no `Palette` equivalent | Moot: "Add tag" is dropped (D4). |
| `#F0E2D4` | envelope border | `sealedBorder` `#F0DFD5` | Use `sealedBorder`. |
| `#F6E2D3` | envelope flap gradient end | ✗ | Flat `terracottaSoft`. |
| `#DFE2F6` | **voice wash mid-stop** | ✗ | See Q4 — flat `periwinkleSoft`. |
| `#EFF4EC` | **did-it wash mid-stop** | ✗ | See Q4 — flat `sage`. |
| `#3A3128`, `#2A2733` | dark fill behind media | ✗ | Dropped. Near-black behind a photo contradicts "never pure black" and has no token. |
| `#EFE9DF` | prototype page background | ✗ | Not an app surface. Ignored. |
| `rgba(253,250,244,.88–.92)` | **frosted sheet fill** | ✗ | See Q2 — the export contradicts its own README here. |
| `rgba(20,18,26,.42–.5)` | media scrims | `--rascal-scrim` is `rgba(35,37,60,.40)` | Use the token's value if a scrim survives. |

### Non-colour tokens

| Export | `Layout.swift` | Note |
|---|---|---|
| Sheet top radius `26px` | `cardRadius` 20 / `heroRadius` 18 | Unmapped; nearest is `cardRadius`. |
| Thumbnail radius `12px` | `mediaInsetRadius` 14 | Use 14. |
| Question card radius `16px` | `quoteBlockRadius` 16 | Exact match. |
| Envelope radius `16px` | `quoteBlockRadius` 16 | Exact match. |
| Chip radius `99px` | Capsule | Match. |
| Screen gutter `20px` / `30px` / `34px` | `screenMargin` 16 | Export uses three gutters; ours has one. |
| Type: Nunito 800 26/28px, body 16–17px, meta 12.5–14px | `typeRole(...)` | Maps to `detailTitle` / `body` / `metadata` / `label`. No new sizes needed. |

### Motion

The export's inline animations — `fadeUp .28s cubic-bezier(.32,.72,0,1)`, `fadeIn .22s ease`,
`fadeUp .26s ease`, `pulseSoft` — are **superseded by `docs/design-system.md`** per the brief:
gentle springs, `response: 0.35, damping: 0.7`. Recorded, not adopted. `support.js` contributed
nothing here (§1).

---

## 4 — Open questions, numbered

### Q1 — Is full-bleed media allowed on Entry Detail? **This is the blocking one.**

The export's entire grammar is "media fills the screen, text floats in a sheet on top". Against it:

- `docs/design-system.md`, Layout rules: *"Photos sit inset with padding and rounded corners;
  **they rarely bleed to the screen edge**."*
- `docs/decisions.md`, **Rejected — do not revisit**: *"Full-bleed edge-to-edge photo timeline as
  the primary view."*
- `docs/decisions.md`, Settled/Design: *"Timeline is a scannable date-grouped card list with
  thumbnails. **Not a full-bleed story feed.**"*

**Both rejections name the *timeline*, not the detail screen, and "rarely" is not "never".** So this
is not a literal conflict with a settled decision — Entry Detail is plausibly the "rare" case the
layout rule leaves room for, and it is the one screen in the app whose entire job is looking at one
artifact.

But it is one step away from a twice-rejected direction, on the screen the brief calls "in 2040,
this is the product". **I am not willing to resolve that autonomously.** It needs a yes or a no.

### Q2 — Frosted glass: the export contradicts its own design system

Every sheet in the export is `background: rgba(253,250,244,.88); backdrop-filter: blur(26px)
saturate(1.25)`. The imported `readme.md` says, in its own words:

> Transparency & blur — used in exactly two places: the iOS-native permission alert and the scrim
> itself. **Frosted-glass panels are not part of this brand.**

The prototype violates the rule the same project states. Proposed resolution: **opaque `surface`
with the standard hairline and resting shadow, no blur.** Recorded here rather than applied,
because it changes how the sheet reads against a photo and is coupled to Q1.

### Q3 — The sealed state drops "Open it", and its copy contradicts the shipped behaviour

The export's sealed letter says:

> "Written when he was 4 years, 1 month. **It opens on his eighteenth birthday and not before —
> not even for you.**"

There is no **Open it** affordance anywhere in state 07.

This directly contradicts §3 of the brief and the shipped code
(`EntryDetailScreen.sealedCard`), whose comment is explicit: *"it says … that the parent may open
it anyway — because they wrote it, and a lock the author cannot pick is a lock on the wrong
person."*

**Resolution is already dictated and needs no decision: keep the existing sealed reader's
vocabulary and the Open it affordance**, and treat the export's envelope motif as skin only. The
export's copy is not adoptable. Flagged because a future importer will hit the same sentence.

### Q4 — Two gradients the palette does not have

The voice wash (`#E9EBFB → #DFE2F6 → #FBF6EF`) and the did-it wash (`#E8F0E6 → #EFF4EC → #FBF6EF`)
exist in neither `tokens/colors.css` nor `Palette.swift`.

`Gradients.wash` is the **sealed** treatment and §4 of the brief says reuse it there and *"do not
invent a second one"*. Adding two more gradients would be inventing a second and a third.

Proposed resolution: **flat `periwinkleSoft` and flat `sage`** as the backdrops. This keeps the
"the wash is the picture" idea for artifact-less entries while adding no `Palette` constants. It
loses the gradient, and that loss should be a conscious one.

### Q5 — Does the sheet's date line replace the metadata list, or sit above it?

The export compresses today's `metaRow` key/value list ("Age at the time", "Date", "Photos",
"Length", "Saved") into one line: `[4 years, 1 month] Sunday 9 August 2026 · 10 photos`.

That is a genuine improvement in density and voice. But the current list carries two things the
one-liner has nowhere to put: **"Saved — Here — it'll sync when you're back on"** (the unsynced
state) and the `Length` row. Losing the sync line would remove the only place Entry Detail tells a
parent their entry has not reached the server.

### Q6 — Where does the transcript live?

Today the transcript is a labelled body-copy block, deliberately moved out of the player
(`transcriptSection`). The export puts an excerpt in the sheet behind **"Read the whole thing"**,
which is a new disclosure control (D5). If the excerpt is dropped and the full transcript kept, the
voice sheet becomes tall; if the sheet scrolls, that is fine, but it is a layout decision tied to
Q1.

### Q7 — The export has no "missing entry" state

`EntryDetailScreen.missing` ("That's no longer here.") has no counterpart in the export. Keep the
existing treatment; noted so it is not read as an omission later.

### Q8 — The export has no unsynced, error, or loading state

Consistent with the imported `readme.md`'s own caveat: *"No error, empty, or loading states exist in
any source. They are not invented here."* Ours exist and stay.

---

## 5 — Dropped rather than built, with reasons

| # | Dropped | Why |
|---|---|---|
| D1 | **Paper grain** (`feTurbulence` at 0.05 over every surface) | The export and its README call grain mandatory identity — *"A RASCAL screen without grain looks wrong."* `docs/design-system.md` lists **screen-print texture** under Anti-patterns and `docs/decisions.md` lists it under **Rejected — do not revisit**. Dropped, exactly as Today v2 and Settings v2 dropped it. **Carried forward as open; not resolved here and no compromise invented.** |
| D2 | **Immersive mode** (`⤢` hides chrome; tap anywhere restores) | New functionality. §7. |
| D3 | **Expanding / collapsing sheet** (drag handle, `toggleExpand`) | New functionality. §7. It is also load-bearing for the export: the prompt, tags and buttons only exist in the expanded state. |
| D4 | **"Add tag" chip** | New functionality — tags are read-only on this screen today (`tags(entry)` renders `Chip`s). §7. |
| D5 | **"Read the whole thing"** transcript disclosure | New functionality. §7, and see Q6. |
| D6 | **Share button** | New functionality, §7 — and §6 of the brief names a share sheet as a seal-leak vector specifically. Not something to add casually to the screen that renders sealed letters. |
| D7 | **Inline video scrubber** | New functionality. Today a video opens `MediaViewerScreen` full-screen. §7. |
| D8 | **Thumbnail strip + "1 of 10" counter** | New functionality; today multi-media is a paged `TabView`. §7. |
| D9 | **Simulated iOS status bar, home indicator** | Prototype furniture, not app chrome. |
| D10 | **`image-slot` placeholder tones** (the `TONES` array) | Prototype scaffolding, explicitly `@ds-adherence-ignore`. |
| D11 | **The sealed state's copy** | Contradicts a non-negotiable. Q3. |
| D12 | **Frosted glass / `backdrop-filter`** | Contradicts the export's own README. Q2. |

### Not fixed here, by instruction

- **The `KindBadge` contrast defect** (tint text on a 12% wash of the same tint, ~3.3–3.7:1, below
  AA) — pre-existing and shared. Not fixed, per the brief. **The export does not reuse the
  pattern**: its chips are a token tint fill with a token ink (`#E9EBFB`/`#5566D6`,
  `#E8F0E6`/`#5E7A57`), which is the same *shape* of pairing. Any new surface built from this
  design must have its ratio measured rather than assumed — `#5566D6` on `#E9EBFB` is the pairing
  to check first.

---

## 6 — Recommendation: why this stops at the inventory

No §1 stop condition fired outright: the import worked, every token resolves under the
reconciliation rule, the app has no capability gap, and Q1 is *adjacent to* rather than *in*
conflict with a settled decision.

It stops anyway, for one reason:

> **The export's central device — full-bleed media with a floating glass sheet — cannot be adopted
> without either contradicting `docs/design-system.md`'s layout rule and the export's own
> frosted-glass prohibition, or inventing a compromise between them.**

The brief forbids inventing a compromise for paper grain, and the same logic applies here with more
force, because this one is not a texture — it is the screen's whole structure. Building "the parts
that are in scope" would produce a third thing that is neither the export nor the current screen,
on the screen where the archive is actually read.

### What a scoped phase 22b should build, once Q1 and Q2 are answered

Ordered by value, and all of it is genuinely a design pass rather than new functionality:

1. **The one-line metadata grammar** — `[age chip] · date · count` replacing the key/value list,
   keeping a home for the unsynced line (Q5).
2. **The artifact-less states get a backdrop** — flat `periwinkleSoft` for voice, flat `sage` for
   did-it, with the prompt promoted to hero type and the export's line *"Nothing was recorded.
   That's allowed — it still happened."* This is the best idea in the export and it is the one that
   most directly serves the three-completion-shapes rule.
3. **The written state**, which is already the closest match — the periwinkle "The question" card
   above a 26px Nunito title.
4. **The sealed state re-skinned** — envelope motif and `Gradients.wash`, with every word of the
   existing vocabulary and the **Open it** affordance intact.
5. **Media presentation**, only after Q1 is answered.

### One finding from reading the tests, which 22b will need

§5 of the brief requires: *"A sealed entry renders no media, no body, and no derived preview —
asserted against a sealed fixture that **has both a photo and a body**."*

**That test does not exist yet, and the closest one is weaker than it looks.**
`SealControlTests.sealedEntryRendersSealed` — commented as *"the test this phase exists for"* —
builds its fixture with `media: []`:

```swift
let entry = try cachedEntry(type: "text", body: "Money is mostly patience…", unlockAtAge: 18)
let card = EntryCardModel(entry: entry, media: [])
#expect(card.preview == nil)
```

Two gaps:

1. **No photo in the fixture.** `card.preview == nil` is guaranteed by the empty media array
   regardless of whether the seal is doing anything — the assertion cannot distinguish "the seal
   suppressed the preview" from "there was never a preview". This is exactly the vacuous-pass
   shape the brief warns about, and it is currently the app's primary seal assertion.
2. **It asserts against `EntryCardModel`, not `EntryDetailScreen`.** The only detail-screen claim
   is `entry.unlockAtAge != nil` — *"what Entry Detail gates its sealed card on"* — which pins the
   input to the branch, not the branch's output. Nothing asserts that the detail screen withholds
   the body.

Neither is a defect in the shipped seal — `EntryDetailScreen.content` gates correctly on
`entry.unlockAtAge != nil && !unsealed` and renders only `sealedCard`. It is a gap in the
*evidence*. **22b should add the §5 fixture (sealed + photo + body) and verify it by breaking the
gate**, which is the required break-test and the one that would have caught a silently-loosened
seal.

### Preflight, for the record

| Check | Result |
|---|---|
| `main` green, working tree clean | ✅ clean, in sync with `origin/main` @ 17e1ad2 |
| Cold suite from deleted `DerivedData`, `CODE_SIGNING_ALLOWED=NO` | ✅ **756 tests, 95 suites, 0 failures** |
| Baseline zero warnings | ⚠️ **21 warnings — see below** |
| `docs/decisions.md` read in full | ✅ |
| `EntryDetailScreen` + all four test files read | ✅ `EntryDetailTests`, `SealControlTests`, `TranscriptionDisplayTests`, `TimelineFixtures` |
| `EntryCard` + sealed skin read | ✅ |

```
xcodebuild test -scheme Rascal \
  -destination 'platform=iOS Simulator,id=2F6BEC36-8650-442B-9F23-E2A2F04A020F' \
  CODE_SIGNING_ALLOWED=NO
```

**The zero-warning precondition does not hold on `main` and did not before this phase.** All 21 are
pre-existing and none is in an Entry Detail file:

- `Rascal/Extraction/ExtractedDetails.swift` — 3 × main-actor isolation on `nilIfEmpty`
- `RascalTests/PushPermissionTests.swift` — 14 × `NSLock` in async contexts
- `RascalTests/ExtractionTests.swift` — 4 × the same

Recorded as a preflight deviation rather than treated as a stop: they are unrelated to this screen,
fixing them is outside this phase's scope, and stopping the design import over them would have
produced nothing useful. Flagged so the "zero warnings" line in a future brief is either met or
consciously relaxed.

**iPhone 17 Pro Max** (`2F6BEC36-…`) was used, addressed by UDID; no iPhone 15 simulator exists on
this machine and two installed simulators share the 17 Pro Max name.
