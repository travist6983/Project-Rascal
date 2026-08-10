# Today v2 — design import inventory

Phase 11 (Today View v2), Lane B. Written Aug 10, 2026 on branch `phase-11-today-v2`
(off `main` @ `919a609`).

**§1–§6 are the Phase 1 import inventory and were written before any Swift existed.** They are
left as they were, because the value of a stop-and-report is that it records what was known at the
time. **§8 records what was decided afterwards and what shipped** — read it alongside §6, which it
answers point for point.

**Design source: the Claude Design MCP**, project `e227a63f-e516-4426-8074-eb12edd15ad2`
("Mobile app design pending"), read directly — not the local fallback. The local export at
`docs/mobile-app-design-today/` is byte-identical in file list and was used for the supporting
files (`tokens/*.css`, `guidelines/*.html`, `components/`, `ui_kits/`).

Primary file: **`RASCAL Today - Paper.dc.html`**. It renders five phone frames of a single skin.

> **Path correction.** The plan says the two required files sit in `mobile-app-design-today/`.
> They are one level deeper, in `mobile-app-design-today/project/`. The bundle's own `README.md`
> refers to a third path (`mobile-app-design-pending/`), which is the project's *name*, not a
> directory that exists here. All three refer to the same content.

---

## 0. Preflight record

| # | Gate | Result |
|---|---|---|
| 0.1 | Working tree clean | **Pass (noted).** Only `?? docs/mobile-app-design-today/` — the design export gate 0.3 requires. No Phase 8 work uncommitted. |
| 0.2 | Fresh branch off up-to-date main | **Pass.** `origin/main` had advanced 12 commits; local `main` fast-forwarded to `919a609`, `phase-11-today-v2` created from it. |
| 0.3 | Design assets present | **Pass.** `project/RASCAL Today - Paper.dc.html` (31,245 B), `project/support.js` (69,150 B). Both non-empty. |
| 0.4 | Design MCP reachable | **Pass.** `get_project` → `canEdit: true`; `list_files` matches the local bundle exactly. |
| 0.5 | Baseline build, zero warnings | **Pass, verified cold.** `DerivedData/Rascal-*` deleted first. `0` warnings matching the CI gate pattern; `0` occurrences of `: warning:` in the whole log. |
| 0.6 | Baseline tests | **Pass.** `Test run with 505 tests in 51 suites passed after 12.067 seconds.` Zero failures. (The `Executed 0 tests` line is the legacy XCTest harness; this suite is Swift Testing.) |
| 0.7 | Today data contract | **Pass.** Every field present, Swift-cased: `completionMode`, `expiresOn`, `doneToday`, `ageMonths`. Plus `assignedOn`, `promptId`, `isCustom`, `unlockAtAge`. |
| 0.8 | Design tokens exist | **Pass (naming corrected).** All 11 tokens exist — but as `extension Color` in `DesignSystem/Palette.swift`, not an `enum Palette`. The `enum Palette` form appears only in `design-system.md`'s illustrative code block. |

Baseline command mirrors `.github/workflows/ios.yml` (scheme `Rascal`, `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, `COMPILER_INDEX_STORE_ENABLE=NO`), simulator iPhone 17 Pro, Xcode 26.4.1.

---

## 1. Screen inventory

The design is five frames of one screen, not five screens. Regions, top to bottom.

| # | Region | Purpose | Frames |
|---|---|---|---|
| R1 | **Status bar** | 9:41 + signal bars. Prototype chrome standing in for the real status bar. | all |
| R2 | **Header row** | Child switcher pill (initial disc + name + chevron), then a circular **search** button and a circular **partner avatar** ("D") pushed right. | all |
| R3 | **STORIES rail** | Horizontal rail of three 138×96 tiles: "Today / 11 August 2026", "1 Year Ago / The hose incident", "2 Years Ago / First proper sentence". Mono `STORIES` label above. Bleeds to the screen edge (`margin: 0 -16px`). | 01 only |
| R4 | **Section label** | Mono uppercase label (`TODAY` / `WAITING` / `DONE TODAY`), optional right-aligned meta (`4 waiting`, `3 today`), and a 1px hairline rule beneath. | all |
| R5 | **PromptCard** | Tinted card: glyph tile + mono kind badge, prompt body, optional media thumb strip, optional progress bar, optional footer line + capsule CTA. Optional check disc when done. | 01, 02 |
| R6 | **Upload affordances** | Per-tile ring spinner (sending) / check badge (landed) / dimmed pulsing dot (queued); plus a per-card shimmer progress bar and a dimmed, place-holding CTA. | 02 |
| R7 | **Completion burst** | 96px terracotta disc with a ripple leaving it and a tick popping to 1.16 then settling. Caption "Saved to 11 August", sub "Photo · three frames". | 03 |
| R8 | **All-caught-up card** | Gradient-wash card, 56px check disc, "All caught up", "Three things saved today. Come back tomorrow — or don't. It'll wait." | 04 |
| R9 | **WaitingCard (row)** | Compact `surface` row: 30px glyph tile, 2-line-clamped body, mono kind badge + neutral chip (`2 days left` / `Yesterday`), trailing chevron. | 01, 05 |
| R10 | **Swipe action** | Revealed behind a waiting row on left-swipe: `#EADFD3` panel, terracotta ✕, "Skip". Two reveal depths shown (26px peek, 104px full). | 05 |
| R11 | **DoneCard (row)** | Tinted row by kind: check disc, 1-line-clamped body in `inkMuted`, meta line ("Photo · 4:12pm"), optional 28px thumb pair. | 03, 04 |
| R12 | **Toast** | Ink-filled pill pinned to the bottom: "Skipped "…"" + **Undo** pill. | 05 |
| R13 | **Floating tab bar** | Today · Timeline · (gap) · Moments · Settings, capsule, `surface`. | all |
| R14 | **FAB** | 62px terracotta `+`, centered, overlapping the tab bar, with a 5s infinite bob. | all |

**R13 and R14 are not this screen's to build.** The tab bar and FAB are owned by `RootView`;
they appear in every frame because the prototype draws a whole phone. Out of scope per §5.

**Two components are defined in the design and rendered in no frame:**

- `weekly()` — kicker `SATURDAY · WEEKLY`, gradient wash, body, "Start the day out", foot
  "All week to finish". Never appears in `FRAMES`.
- `status()` — a bare 13.5px line in `#8C8279`. Never appears in `FRAMES`.

There is **no monthly treatment at all**, and no first-run, offline, or error state.

---

## 2. State inventory

### 2a. States the design actually draws

| Design state | Where | Notes |
|---|---|---|
| One pending today item, one waiting item | Frame 01 | The only "normal" board drawn. |
| Two today items, both mid-upload | Frame 02 | Waiting is pushed below the fold "while anything is in flight". |
| Just-completed, with the burst | Frame 03 | Burst sits above `DONE TODAY`. |
| All caught up, with done items listed | Frame 04 | Gradient card + three done rows. |
| Waiting list with swipe partially and fully revealed | Frame 05 | Plus the undo toast. |
| Done row, three kinds | 03, 04 | terracotta (photo), periwinkle (voice/written), sage (did it). |
| Expiring chip | Frame 05 | `2 days left` — neutral grey, not red, not bold, not animated. ✅ |
| Sealed row | Frame 05 | `SEALED` badge + `Sealed until 18` chip. |

### 2b. The §4 required matrix vs. what the design supplies

| # | Required state | Design coverage |
|---|---|---|
| 1 | Both today items pending | **Partial** — frame 01 draws one; frame 02 draws two but both uploading. |
| 2 | One done, one pending | **Absent.** |
| 3 | Both done, waiting empty → all caught up | **Covered** — frame 04. |
| 4 | Waiting with 1 item | **Covered** — frame 01. |
| 5 | Waiting with 8+ (scroll) | **Absent.** Max drawn is 3; the frame clips with `overflow:hidden` and never scrolls. |
| 6 | Expiring ≤3 days | **Covered** — `2 days left`, frame 05. |
| 7 | Expiring tomorrow | **Absent** as a distinct treatment (correctly — it should look identical). |
| 8 | Saturday weekly alongside daily | **Component defined, never rendered.** See `weekly()`. |
| 9 | 1st-of-month monthly slot | **Absent entirely.** No monthly treatment exists. |
| 10 | Brand-new account, zero entries | **Absent.** |
| 11 | Child with no avatar | **This is the design's only avatar state** — an initial on a terracotta disc. There is no photo-avatar variant drawn. |
| 12 | Name at 24+ chars | **Absent.** Prototype name is "Hendrix" (7). Pill has no truncation rule. |
| 13 | Body wrapping 4+ lines | **Absent.** Longest drawn body wraps 3; waiting rows hard-clamp at 2 lines and done rows at 1. |
| 14 | Offline / stale cache | **Absent.** No error, notice, or stale treatment anywhere. |
| 15 | Dynamic Type at AX XXL | **Absent, and structurally excluded** — every size in the file is a fixed `px`, and every row uses `-webkit-line-clamp` plus a fixed 852px frame. |

Nine of fifteen required states have no design to translate. That is expected for a prototype and
is not itself a blocker — but rows 8, 9, 13 and 15 are the ones where inventing a treatment means
making a design decision, not doing a translation.

---

## 3. Token reconciliation

Three sources disagree, and separating them is the single most useful result of this phase:

- **`docs/design-system.md`** — the stated authority for writing SwiftUI.
- **`ios/.../DesignSystem/Palette.swift`** — the shipped code. Matches `design-system.md` exactly.
- **The bundle's `tokens/*.css`** — the design system as the *design tool* holds it.
- **The Paper prototype's inline `<script>`** — hardcoded constants that **disagree with the
  bundle's own token file**.

Where the prototype and the bundle token file differ, the bundle token file agrees with Swift.

### 3a. Colour — prototype constants

| Design value | Matching token | Exact match? |
|---|---|---|
| `#FDFAF4` screen background | `canvas` | **Y** |
| `#23253C` (`INK`) | `ink` | **Y** |
| `#6E6A63` (`MUT`) | `inkMuted` | **Y** |
| `#B4ADA3` (`FAINT`) | `inkFaint` | **Y** |
| `#FFFDF9` (`CARD`) | `surface` | **Y** |
| `#EDE5DA` (`HAIR`) | `border` | **Y** |
| `#C05A2B` (`A`, accent default) | `terracotta` | **Y** |
| `#FBEDE2` (`A_T`) | `terracottaSoft` | **Y** |
| `#E9EBFB` (`PERI_T`) | `periwinkleSoft` | **Y** |
| `#E8F0E6` (`SAGE_T`) | `sage` | **Y** |
| `#FDE8DC → #F7DDE8 → #FBF6EF` wash | `Gradients.wash` | **Y** |
| `#4B58D4` (`PERI`) | `periwinkle` is `#5566D6` | **N** |
| `#5C7A56` (`SAGE`) | `sageInk` is `#4B7A4F` | **N** |
| `#DDE0F6` (`PERI_B`) | `periwinkleBorder` is `#DADDF7` | **N** |
| `#DAE7D7` (`SAGE_B`) | `sageBorder` is `#D8E4D5` | **N** |
| `#F5EFE6` waiting-row chip fill | `chipPlain` is `#F4EEE5` | **N** |
| `#F3DFCF` (`A_B`) terracotta hairline | none | **N** |
| `#8C8579` mono labels, rail label, chip ink | none | **N** |
| `#9A9287` done-card accent, done-row meta | none | **N** |
| `#F6EFE7` done-card fill | none | **N** |
| `#EDE2D6` done-card hairline | none | **N** |
| `#A8998A` dimmed footer text | none | **N** |
| `#B07A5E` dimmed CTA label | none | **N** |
| `rgba(192,90,43,.14)` dimmed CTA fill | none | **N** |
| `rgba(192,90,43,.12)` progress track | none | **N** |
| `#7E7568` weekly footer | none | **N** |
| `#8C8279` status line | none | **N** |
| `#FFF8F1` text/glyph on colour fills | none (`canvas` and `surface` both exist) | **N** |
| `#EADFD3` / `#DFCFBD` swipe action fill / hairline | none | **N** |
| `#F4E3DB` caught-up card hairline | `sealedBorder` `#F0DFD5` is the wash hairline | **N** |
| `rgba(255,248,241,.9)` toast text | none | **N** |
| `rgba(255,248,241,.14)` undo fill | none | **N** |
| `#FFD9C2` undo label | none | **N** |
| `rgba(35,37,60,.45)` / `.3` chevrons | none | **N** |
| `#E0D2C0` `#D5C6B4` `#E8DAC8` `#E9D2BE` `#F0DCCB` `#D2D6EF` stripes | n/a — photo placeholders | n/a |

Notes. Twenty-three colours in one screen have no token. Six of those are a **third step in the ink
ramp between `inkMuted` and `inkFaint`** (`#8C8579`, `#9A9287`, `#A8998A`, `#8C8279`, `#7E7568`,
`#B07A5E`) — `design-system.md` states outright that "the ink ramp is three steps, not two", and
this design uses six. `#EFE9DF` and `#E3DACB` are excluded above: they are the design canvas
behind the phone, not app surfaces.

`#FFF8F1` deserves separate mention. The prototype uses it for text on coloured fills but uses
`#FDFAF4` (`canvas`) for the tick glyph doing the same job — it is inconsistent with itself.

### 3b. Colour — the bundle's own `tokens/colors.css`

| Design value | Matching token | Exact match? |
|---|---|---|
| `--rascal-peri: #5566D6` | `periwinkle` | **Y** |
| `--rascal-sage-ink: #4B7A4F` | `sageInk` | **Y** |
| `--rascal-lav-badge: #DADDF7` | `periwinkleBorder` | **Y** |
| `--rascal-canvas` `-surface` `-border` `-ink` `-muted` `-terracotta` | `canvas` `surface` `border` `ink` `inkMuted` `terracotta` | **Y** |
| `--rascal-peach: #FBEDE2` / `--rascal-lav: #E9EBFB` / `--rascal-sage: #E8F0E6` | `terracottaSoft` / `periwinkleSoft` / `sage` | **Y** |
| `--rascal-muted-soft: #B4ADA3` | `inkFaint` | **Y** |
| `--rascal-peach-deep: #F8E7DC` | none | **N** |
| `--rascal-peach-badge: #F3D9C7` | none | **N** |
| `--rascal-ink-disabled: #D9CFC2` | none | **N** |
| `--rascal-grain` (feTurbulence, 160px, 0.055) | none | **N** |

**The bundle's token file matches `Palette.swift` on every colour it shares.** The prototype's
`PERI`, `SAGE`, `PERI_B` and `SAGE_B` disagree with *both*. That reads as authoring drift in the
prototype, not a deliberate palette change — which makes it a cheap decision, not an expensive one.

### 3c. Radius

| Design value | Matching token | Exact match? |
|---|---|---|
| `18` waiting row, done row, story tile | `Layout.heroRadius` = 18 | **Y** (value; different semantics) |
| `20` toast | `Layout.cardRadius` = 20 | **Y** |
| `14` 64px media thumb | `Layout.mediaInsetRadius` = 14 | **Y** |
| `99px` all pills, discs, chips | `Capsule()` | **Y** |
| `24` prompt card (`--rascal-radius-app-card`) | `Layout.cardRadius` = 20 | **N** |
| `26` caught-up card | none | **N** |
| `11` 34px glyph tile | none | **N** |
| `10` 30px glyph tile (`--rascal-radius-sm`) | none | **N** |
| `8` 28px done-row thumb | none | **N** |
| `7` story mark | none | **N** |
| `28` (`--rascal-radius-sheet`) | none | **N** |

The bundle is explicit that 24 is intentional: *"Two radii do almost everything: 20px for cards,
999px for anything tappable. **The app goes one step softer at 24px for prompt cards.**"* That is a
direct, deliberate contradiction of `design-system.md`'s "Card radius: **20**".

### 3d. Spacing

| Design value | Matching token | Exact match? |
|---|---|---|
| `16` horizontal screen padding (prototype) | `Layout.screenMargin` = 16 | **Y** |
| `16` gap between blocks | `Layout.cardSpacing` = 12 | **N** |
| `18` prompt-card padding | `Layout.cardPadding` = 16 | **N** |
| `14 / 16` waiting- and done-row padding | `Layout.cardPadding` = 16 | **N** |
| `20` weekly padding, `26 / 22` caught-up padding | `Layout.cardPadding` = 16 | **N** |
| `22` (`--rascal-app-gutter`, "measured from the 393pt screens") | `Layout.screenMargin` = 16 | **N** |
| `108` bottom clearance / `110` (`--rascal-app-tabbar-clearance`) | none | **N** |

The gutter is a three-way disagreement: bundle token 22, `design-system.md` 16, prototype 16.
The prototype agrees with the shipped code.

### 3e. Type

| Design value | Matching token | Exact match? |
|---|---|---|
| Nunito 700/800 headings | SF Pro Rounded semibold/bold | **Y by settled policy** |
| Source Sans 3 400/600 body | SF Pro Text | **Y by settled policy** |
| CTA `16px` Nunito 700 | `.cardTitle` 17pt semibold | **N** |
| Prompt body `21px` Nunito 700 `-0.01em` | `.promptBody` 20pt **regular** | **N** |
| `--rascal-app-size-prompt: 22px` | `.promptBody` 20pt | **N** |
| Section label — **`ui-monospace` 11px, ls 1.2px, `#8C8579`** | `.label` 12pt semibold SF Pro Text, ls +0.6, `inkMuted` | **N** |
| Kind badge — mono `10.5px`, ls 1.1px | `.label` 12pt | **N** |
| `--rascal-app-size-badge: 11.5px` Nunito 700 ls .08em | `.label` 12pt | **N** |
| Waiting-row body `15px` w600 | `.body` 16pt / `.cardTitle` 17pt | **N** |
| Done-row body `14.5px` w600 | `.body` 16pt | **N** |
| Done-row meta `12px` | `.metadata` 13pt | **N** |
| Caught-up caption `24px` Nunito 800 `-0.025em` | `.title` 22pt semibold | **N** |
| Burst caption `22px` Nunito 800 | `.title` 22pt semibold | **N** (weight) |
| Header child name `16px` w600 | `.cardTitle` 17pt semibold | **N** |
| `--rascal-app-size-cta: 17px` | `.cardTitle` 17pt | **Y** |
| `--rascal-app-size-body: 16px` | `.body` 16pt | **Y** |
| `--rascal-app-size-screen: 29px` | `.screenTitle` 29pt | **Y** |
| `--rascal-app-size-title: 38px` | `.display` 34pt | **N** |

The font substitution is already settled — `design-system.md`: *"The mockups set headlines in
Nunito; rounded is the system stand-in, and no font file is bundled."* Nothing new is needed there.

**The monospace section label is a new family.** `design-system.md` names exactly two type
families. The bundle adds a third (*"Mono is metadata only — dates, counters, spec keys"*) and the
Today design uses it for every section header and kind badge. SF Mono needs no font file, so this
is a design decision, not a dependency question.

### 3f. Shadow

| Design value | Matching token | Exact match? |
|---|---|---|
| `--rascal-shadow: 0 2px 8px rgba(0,0,0,0.04)` | `Layout.Shadow` y2 / blur8 / 0.04 | **Y** |
| `0 1px 2px rgba(35,37,60,.03)` card | `Layout.Shadow` | **N** |
| `0 1px 2px rgba(35,37,60,.04)` header pill | `Layout.Shadow` (opacity matches) | **N** |
| `0 6px 16px rgba(35,37,60,.13)` CTA | none | **N** |
| `0 10px 30px rgba(192,90,43,.30)` burst disc | none | **N** |
| `0 10px 26px rgba(35,37,60,.22)` toast | none | **N** |
| `-8px 0 18px rgba(35,37,60,.10)` swiped row | none | **N** |
| `0 6px 22px rgba(35,37,60,.10)` tab bar | none — out of scope | **N** |
| `0 8px 22px rgba(192,90,43,.34)` FAB | none — out of scope | **N** |

The bundle's own resting shadow is an exact match for the shipped one. The prototype uses neither,
and its CTA / burst / toast shadows are well past `design-system.md`'s "barely there".

### 3g. Motion

| Design value | Matching token | Exact match? |
|---|---|---|
| `spin .9s linear infinite` upload ring | `UploadRing` (shipped) | **Y in kind** |
| `settle` on a card landing in done | `Motion.cardToDone` 0.4s / `Motion.listInsert` | **N** (values) |
| `tickIn` + `popIn` + `ripple` completion | `Motion.completion` spring(0.35, 0.7) | **N** |
| `shimmer 1.5s linear infinite` on the progress fill | none | **N** |
| `pulseDot 1.4s ease-in-out infinite` queued tile | none | **N** |
| `softPop .6s` caught-up disc | none | **N** |
| `bob 5s ease-in-out infinite` on the FAB | none — out of scope | **N** |
| `fillUp 5.4s` progress fill | n/a — the prototype faking progress | n/a |
| `EASE = cubic-bezier(.32,.72,0,1)` | none | **N** |
| `--rascal-ease-enter: cubic-bezier(.16,1,.3,1)` | none | **N** |
| `--rascal-dur-press: 150ms` | `Motion.tap` 0.12s | **N** |
| `--rascal-dur-enter: 320ms` / `-settle: 620ms` / `-reveal: 900ms` | none | **N** |

`fillUp`, and the `3.6s infinite` loops wrapping `popIn`/`ripple`/`tickIn`/`settle`, are the
prototype demoing itself on a loop. They are not motion specs and must not be read as durations.

---

## 4. Deviations

### D1 — Twenty-three colours with no token, and four near-misses against real ones

Listed in §3a. The four near-misses matter more than the twenty-three absences, because a
one-digit difference is invisible in review and permanent in code:
`PERI #4B58D4` vs `periwinkle #5566D6`, `SAGE #5C7A56` vs `sageInk #4B7A4F`,
`PERI_B #DDE0F6` vs `periwinkleBorder #DADDF7`, `SAGE_B #DAE7D7` vs `sageBorder #D8E4D5`.

**`#4B58D4` sits directly against a Rejected bullet.** `decisions.md` → *Rejected — do not
revisit* lists **"Electric cobalt as the secondary color"**, and the Settled table fixes
"periwinkle `#5566D6` secondary — derived from the reference screenshots, not invented."
The prototype is 3% darker and marginally more saturated at the same hue — not literally cobalt,
but it is a change to a value that is closed, made by a file that disagrees with its own token
sheet.

**There is precedent, and it points one way.** Phase 10 (Moments v2) hit exactly this and recorded
the resolution in `decisions.md`: *"The export hairlines the gradient-wash throwback card at
`#F2DFE4`, which is in no palette; the design system already names the hairline for that wash —
`sealedBorder` — and that is what is used."* Resolved toward the design system, against the export.

### D2 — Paper grain

The bundle states three separate times that grain is mandatory:

- `guidelines/grain.html` card subtitle: *"Identity, not decoration. Every RASCAL surface sits on it."*
- `tokens/base.css`: *"Paper grain is part of the identity, not decoration."*
- `readme.md`: *"An inline SVG `feTurbulence` at `0.055` opacity tiles at 160px over the canvas on
  **every** surface, web and app. **A RASCAL screen without grain looks wrong.**"*

The guideline card draws it as a right/wrong pair, labelling the ungrained swatch **"without — wrong"**.

Against that: `docs/design-system.md` defines no grain token, and its anti-pattern list opens with
*"Risograph, halftone, misregistration, screen-print texture."* `decisions.md` → Rejected repeats
*"Risograph, halftone, misregistration, screen-print aesthetics."* Neither file mentions grain,
paper, noise, or tooth even once — searched both. **The absence is unsettled, not permission**, and
halftone and misregistration are themselves texture treatments, so the nearest settled statement
leans against.

Technically it is a `Canvas`/`Image(uiImage:)` tiled noise layer under the scroll view — not free,
not hard, and a new render path on the app's most-opened screen. The exact spec if it goes ahead:
160×160 tile, `feTurbulence` `fractalNoise`, `baseFrequency 0.9`, `numOctaves 2`, opacity **0.055**
(the token file and guideline agree; the Today prototype uses **0.05** — a fourth internal
inconsistency).

### D3 — Card radius 24 vs 20

Not drift. The bundle says it deliberately: *"The app goes one step softer at 24px for prompt
cards."* `design-system.md` says 20 and is the stated authority. One of the two has to yield, and
`Layout.cardRadius` is used by Timeline, Moments, Settings and the composer — changing it changes
every screen, and changing it only on Today makes Today the odd one out.

### D4 — A monospace type family for section labels and kind badges

`design-system.md` names two families. The bundle names three and uses the third for every section
header on this screen. `SectionLabel` currently renders `.label` (12pt semibold SF Pro Text, +0.6
tracking, `inkMuted`); the design wants `ui-monospace` 11px at 1.2px tracking in `#8C8579` — a
different family, size, tracking **and** colour. `KindBadge` has the same four-way difference.

### D5 — Six-step ink ramp against a stated three

`design-system.md`: *"The ink ramp is three steps, not two."* The design uses six greys between
`ink` and `inkFaint`. Adding them means either three new named tokens with semantics I am not
authorised to assign, or snapping all six to `inkMuted`/`inkFaint`.

### D6 — The design shows no state for six of the fifteen required rows

§2b. Rows 8, 9, 13 and 15 need a designed treatment, not a translation. Row 15 in particular:
every dimension in the file is a fixed pixel and every row is line-clamped, so the design contains
no information about behaviour at accessibility sizes.

### D7 — Shadows past "barely there"

§3f. The CTA, burst disc and toast shadows are 3×–7× the opacity `design-system.md` specifies, on
a screen whose stated rule is *"warmth comes from the cream, not from depth."*

### D8 — `support.js` is not what the plan describes

The plan (§1) says it "contains mock data, tab-switch wiring, and DOM animation timing." It does
not. Line 1 reads `// GENERATED from dc-runtime/src/*.ts — do not edit.` It is the compiled
template engine that interprets `<x-dc>`, `<sc-for>`, `<sc-if>` and `DCLogic` — zero occurrences of
`mockData`, `setInterval`, or any click handler. The mock data and the animation keyframes live in
the `.dc.html` file's own inline `<script type="text/x-dc">`.

**The plan's conclusion still holds** — none of it ports. But the instruction "do not read timing
values out of `support.js`" points at the wrong file: the timing values are in the design file,
which is also the file you are told to treat as the source of truth.

### D9 — An existing defect, found while checking the expiry chip

`AssignmentResponse.daysUntilExpiry` (`ios/Rascal/Rascal/Today/PromptCard.swift:145`) anchors on
`Calendar.current.startOfDay(for: Date())` — the **device's** day — while `expiresOn` is computed
server-side in `family_timezone`. `ios/CLAUDE.md` rule 1 forbids the client deciding what day it
is. A parent in a different timezone from their child sees the wrong number of days.
`TodayResponse.date` is the correct anchor and is already in the same response.

Pre-existing, unrelated to this import, and not fixed here — flagged per §6.

---

## 5. Stop conditions

§1 lists four. **Three trip. The fourth is arguable and I am treating it as tripped.**

### 5.1 Colours that don't map to existing tokens — **TRIPPED**

Twenty-three unmapped, four near-misses, one (`#4B58D4`) adjacent to a Rejected bullet. Listed in
§3a and §4/D1. Per the instruction, I have not added tokens or assigned them meaning.

### 5.2 Paper grain / texture material — **TRIPPED**

§4/D2. The bundle treats it as mandatory brand identity; `design-system.md` neither defines it nor
permits it, and its nearest settled statement is an anti-pattern that covers texture treatments.

### 5.3 Data `/today` doesn't return — **TRIPPED, in three places**

| Design element | Verdict |
|---|---|
| **STORIES rail (R3)** | Not from `/today`. `AssignmentOut` has no entry, no media, no historical date. The data exists behind **`GET /children/{id}/moments`** — already decoded as `MomentsResponse`, already rendered by `Moments/ThrowbackCard.swift`. Building the rail means Today makes a **second network call** plus one `GET /media/{id}/url` per uncached cover. §3 forbids changing the view model or networking layer. |
| **Partner avatar "D" (R2)** | **Nothing in the API returns the guardians on a child.** `POST /children/{id}/guardians` is P2 and has no `GET`. `decisions.md` has zero hits for partner, co-parent, or second parent. |
| **Undo on the toast (R12)** | **No un-dismiss endpoint exists.** Only `POST /assignments/{id}/dismiss` → `dismissed`. `POST /assignments/{id}/custom` does resurrect a dismissed row, but it sets `custom_body` and flips `is_custom` permanently — building Undo on it would corrupt the row and depend on undocumented behaviour. The honest client-side option is a grace window: hold the POST for the toast's life and fire it only if Undo isn't tapped. That is new local state, not a translation. |

Two more, below the stop line but worth deciding:

- **Done-row time of day** ("Photo · 4:12pm") comes from `Entry.occurredAt` in SwiftData. An
  assignment completed on the other parent's phone arrives in `done_today` with no local entry, so
  those rows can show a kind and a body but **not** a time, a duration, or a thumbnail.
- **Search (R2)** needs no new data — `GET /entries?q=` is wired — but `decisions-log.md` records
  that search deliberately lives in the **Timeline** header. Putting a second magnifier on Today
  reopens a settled placement.

### 5.4 Contradicts the Rejected list — **ARGUABLE; treating as tripped**

| Rejected bullet | Verdict |
|---|---|
| Electric cobalt as the secondary color | **Adjacent.** `PERI #4B58D4` against the settled `#5566D6`. Same hue, slightly deeper. Not literally cobalt, but it is a change to a closed value. |
| Risograph, halftone, misregistration, screen-print | **Adjacent.** The grain is paper tooth, not riso — but it is a texture material and the bullet is about texture. |
| Full-bleed edge-to-edge photo timeline as the primary view | **Not violated, but close.** The rail is 138×96 tiles, not full-bleed, and Today is not the timeline. It is however a photo-forward horizontal rail explicitly labelled `STORIES`, on a product whose Settled table says "Not a full-bleed story feed." |
| Streaks, guilt copy, red urgency states | **Clean.** ✅ The design's own note says "no streak, no count-up"; the expiry chip is neutral grey; the caught-up copy is "Come back tomorrow — or don't. It'll wait." The bundle's `voice.html` bans streak language outright. |
| Passport-stamp completion, rotated cards, condensed poster type | **Clean.** ✅ |

One more worth naming: `decisions.md` settles *"Completion = circular terracotta checkmark + spring
+ haptic … No stamp, no confetti."* The burst (R7) is a circular terracotta checkmark — compliant
in kind — but at 96px with a ripple expanding to 2× it is a much louder beat than the 28px
`CompletionCheck` the app ships. Compliant in kind, arguable in degree.

---

## 6. What needs a decision before Phase 2

1. **Periwinkle, sage-ink, and the two hairlines.** Adopt the prototype's values, or hold
   `Palette.swift`? The bundle's own token file sides with `Palette.swift`, and Phase 10 set the
   precedent of resolving toward the design system. Recommendation: hold the palette, treat the
   prototype's four values as authoring drift.
2. **Paper grain: in or out?** If in, it needs a token, a render path, and a decision recorded
   against the riso rejection. If out, the bundle's "looks wrong without it" stands unanswered.
3. **The twenty-three unmapped colours.** Snap to the nearest existing token, or name new ones?
   Six of them are ink-ramp steps 4–6 of a ramp stated to have three.
4. **Card radius 20 or 24**, and whether the answer applies to Today only or to every screen.
5. **Monospace section labels and kind badges** — a third type family, or hold `.label`?
6. **The STORIES rail.** It needs a second endpoint, which §3 forbids. Drop it, or lift the §3
   constraint? Note the archive is six days old: `1 year ago` will be the `fallback: "random"`
   branch on nearly every date for the next year, which is exactly what Phase 10 built Moments to
   handle — and Moments is one tab away.
7. **The partner avatar** — drop it, or open the guardian-list conversation with Lane A?
8. **Undo on skip** — drop it, ship the grace-window version, or ask Lane A for
   `POST /assignments/{id}/restore`?
9. **Search on Today** — drop it, or reopen the settled Timeline-only placement?
10. **Treatments for the six missing states**, especially weekly (defined but never drawn),
    monthly (absent entirely), long bodies, and Dynamic Type at AX sizes.
11. **Phase numbering.** "Phase 11" is already taken — `ios/phase-11-widget` merged as PR #32.
    This is the second Phase 11.

---

## 7. What is already built

Worth stating, because it changes the size of Phase 2. Much of the §2 component list exists:

| Plan calls for | Already exists |
|---|---|
| `PromptCard` | `Today/PromptCard.swift` — tints by kind, kind badge, expiry chip, capsule CTA, done state, upload ring, failure list, unknown-kind neutral fallback |
| `SectionHeader` | `SectionLabel` in `DesignSystem/Typography.swift` |
| `ExpiryChip` | `PromptCard.expiryText` + `Chip` — already `inkMuted`, never red, never animated |
| Kind badge chip | `KindBadge` in `DesignSystem/Layout.swift` |
| Motion tokens | `DesignSystem/Motion.swift` — `tapScale` 0.98/0.12s, `completion` spring(0.35, 0.7), `cardToDone`, `listInsert`, Reduce Motion honoured |
| Completion check | `CompletionCheck` + `Haptics.completion()` |
| Card surface | `.cardSurface(fill:border:)` and a gradient-wash variant |
| Local-over-server merge | `TodayBoard.merge` — done if the server says so **or** a local entry completes it |
| Upload ring | `Today/UploadRing.swift`, byte-weighted via `TodayBoard.MediaProgress` |
| Throwback card | `Moments/ThrowbackCard.swift` |

Genuinely new: `WaitingCard` (compact row), `DoneCard` (compact row), `ChildSwitcherPill`, the
swipe-to-skip gesture, the toast, and the per-tile upload states.

---

## 8. Resolved — what shipped

The eleven questions in §6 blocked Phase 2. They were answered rather than escalated, on an
explicit instruction to proceed. Each answer below follows the strongest precedent available
rather than a preference, and every one of them is reversible.

| § 6 | Question | Resolution | Basis |
|---|---|---|---|
| 1 | Periwinkle, sage-ink, two hairlines | **Held `Palette.swift`.** The prototype's `#4B58D4`, `#5C7A56`, `#DDE0F6`, `#DAE7D7` are treated as authoring drift and were not adopted. | The bundle's own `tokens/colors.css` carries `--rascal-peri: #5566D6`, `--rascal-sage-ink: #4B7A4F`, `--rascal-lav-badge: #DADDF7` — it agrees with the shipped palette, so only the prototype disagrees with both. Phase 10 resolved the same conflict the same way. |
| 2 | Paper grain | **Out.** No grain token, no noise layer. | `design-system.md` is the stated authority for writing SwiftUI, defines no grain, and opens its anti-patterns with "screen-print texture". Adopting it would mean inventing a token and a render path, which §1 explicitly forbids. |
| 3 | 23 unmapped colours | **Snapped to existing tokens.** No new colour was named. | Same instruction. The six ink-ramp steps collapsed onto `inkMuted` / `inkFaint`. |
| 4 | Card radius 20 or 24 | **20.** | `Layout.cardRadius` is shared by Timeline, Moments, Settings and the composer. Changing it restyles every screen; changing it only here makes Today the outlier. |
| 5 | Monospace section labels | **Held `.label`.** | Would be a third type family against a system that names two. |
| 6 | STORIES rail | **Dropped.** | Needs `GET /children/{id}/moments` — a second call from a screen the contract calls "the single call the home screen makes" — and §3 forbids changing the networking layer. Moments is one tab away and already handles the empty case, which is the common case for an archive this young. |
| 7 | Partner avatar | **Dropped.** | No endpoint returns a child's guardians. `POST /children/{id}/guardians` is P2 and has no `GET`. |
| 8 | Undo on skip | **Built, as a grace window.** The swipe hides the row and `POST /assignments/{id}/dismiss` is held for eight seconds; Undo cancels it, and it is never sent. | There is no un-dismiss endpoint, and `POST /assignments/{id}/custom` would resurrect a row only by overwriting `custom_body` and flipping `is_custom` permanently. Not sending the request yet is the only honest undo. |
| 9 | Search on Today | **Dropped.** | `decisions-log.md` settles search in the Timeline header. |
| 10 | Six missing states | **Designed against existing patterns**, each with a `#Preview`. Weekly and monthly use the standard `PromptCard` with a slot-named footnote rather than the unrendered `weekly()` treatment. | |
| 11 | Phase numbering | **Unresolved, cosmetic.** This is the second Phase 11; `ios/phase-11-widget` merged as PR #32. | |

### Also shipped, beyond the design

- **D9 is fixed.** `daysUntilExpiry` anchored on `Calendar.current.startOfDay(for: Date())` — the
  device's day — while `expires_on` is server-computed in `family_timezone`. It now measures
  between two server-named days through `CalendarDay`, which parses at noon UTC and formats back
  in UTC. Fixed rather than left in place because this phase rewrote that exact function, and the
  arithmetic is now covered by tests including both DST boundaries.
- **Tinted cards get tinted hairlines.** `design-system.md` asks for this and the shipped card used
  the cream `border` on every fill.

### Deliberately not built

- **The completion burst** (design frame 03). A 96pt disc with a ripple is louder than the
  `CompletionCheck` that `decisions.md` settles as "circular terracotta checkmark + spring +
  haptic … No stamp, no confetti". Compliant in kind, arguable in degree — and it needs a
  completion event this screen does not currently receive.
- **Thumbnails** on prompt cards and done rows. Needs `ThumbnailStore` and media ids, which reaches
  into the media paths §5 scopes out.
- **The upload thumb strip and per-card progress bar** (design frame 02). `UploadRing` already
  carries byte-weighted progress on the card; the per-tile ring/dot/check needs the per-file `Media`
  rows plumbed through `BoardItem`, which is a model change.
