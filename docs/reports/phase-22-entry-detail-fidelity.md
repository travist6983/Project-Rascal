# Phase 22 — Entry Detail v2: fidelity correction pass

Branch `ios/phase-22-entry-detail-fidelity`, cut from `origin/main` at `5224dc8`.
Lane B only. Nothing under `api/` was read for writing or touched.

---

## 1. Preflight gate results

| Gate | Result | Detail |
|---|---|---|
| **G1** design file readable | **PASS** | At `docs/entry-detail/project/RASCAL Entry Detail.dc.html` (449 lines), not at the path its README names. All six type sections present — 01 Photo, 02 Ten photos, 03 Video, 04 Voice, 05 Written, 06 Did it — **plus a seventh, 07 Sealed letter**, which §8 puts out of scope. Read top to bottom, along with `support.js` and the `tokens/` CSS. |
| **G2** authority conflict acknowledged | **PASS** | Recorded in §2 below. `design-system.md` was **not** edited. |
| **G3** all six renderable | **PASS** | Via a temporary harness — see below. All six rendered with distinct real data through the production decode path. |
| **G4** clean tree, correct branch, green baseline | **PASS** | Tree clean. Branched from `origin/main` (local `main` was 6 behind; `origin/main` already contains the phase-18 follow-up as PR #58). Cold baseline: build succeeded, **837 tests in 107 suites passed**, **21 warnings**. |
| **G5** lane boundary | **PASS** | Every changed file is under `ios/`. |
| **G6** settled decisions not reopened | **PASS** | Read `docs/decisions.md`. No streaks, no confetti, no completion metrics, no counters. Three completion shapes all render as complete. Soft deletes untouched. The sealed reader is unchanged on purpose. |

**On the baseline warning count.** The brief says 21 inherited warnings. A `build` of the app target alone reports 3; a `test` run reports 18 more from the test target — but only when the app target is compiled cold, which is the trap in `verify-ios-warnings-cold`. Deleting DerivedData first gives **3 + 18 = 21**, matching exactly. Final cold run after all changes: **21**, byte-identical list. Zero added.

**G3, and how the six were produced.** This project has **no UI test target** — only `RascalTests`, a unit target — so there is no way to drive a tap from the command line and navigate the timeline into a detail screen. I built a temporary harness (`Phase22Harness.swift` plus a four-line switch in `RascalApp.swift`, both reverted and **not** in the diff): an in-memory store seeded with one entry of each shape, thumbnails written to the path `ThumbnailStore` checks before the network, and the screen opened through the same `.entryDetail` modifier the real screens use, inside a stand-in for `RootView`'s `ZStack` **including the `FloatingTabBar`** — so the tab-bar defect was reproducible and its fix falsifiable. Entries go in as JSON through `EntryCache.upsert`, because `entryType` and `childAgeMonths` are `private(set)` and settable only from a server response; a harness that wrote them directly would be screenshotting a state the app cannot reach.

---

## 2. The `design-system.md` conflict — proposed, NOT applied

The design file describes a dark immersive canvas with a bottom sheet. `design-system.md` describes a cream screen with an inset hero card. Per G2 I took **structure from the design file and values from the token layer**, and changed no documentation.

`design-system.md` also **contradicts itself** today, which is worth stating first: line 617 says *"The one screen where they do bleed is Entry Detail — settled Aug 11, 2026, phase 22. Media runs edge to edge there… with the reading sheet resting on top of it"*, while line 390 says the hero is *"a 4:3 block at hero radius with a `border` hairline"*. Those cannot both be true, and the code implemented the second one.

### Contradicted lines

| Line | Current text | Contradicted by |
|---|---|---|
| 144 | "Compact row radius: **18** — `DoneCard`, `WaitingCard`, **and the Entry Detail hero**" | There is no hero card. Media is full-bleed with no radius. |
| 384 | "this screen wears the standard navigation bar, titled with the entry's `occurred_at` in compact form and carrying an ellipsis menu" | No navigation bar. Floating translucent chips over the canvas. |
| 390 | "Hero \| pictures, else the voice player, else nothing. One picture is a 4:3 block at hero radius with a `border` hairline; several are a paged carousel 300 tall." | The media fills the canvas. This line is the direct cause of D1. |
| 391 | "Prompt \| filled block at quote radius… `ANSWERED <date>` eyebrow in inkFaint" | The prompt is `THE QUESTION` on written, `THE PROMPT` in the expanded sheet elsewhere, and the artifact itself on did-it. No `ANSWERED` eyebrow anywhere. |
| 394 | "Metadata \| key/value rows under a `border` divider" | One meta row: age capsule, then the date sentence. (The shipped code already did this — the doc was stale before this pass.) |
| 397 | "The voice hero is periwinkleSoft at hero radius with a `periwinkleBorder` hairline, a 52pt periwinkle play circle" | A full-canvas periwinkle ground with an 84pt play circle and a 96pt waveform. |
| 401 | "Tapping a picture opens it fullscreen on `ink`" | Still true, but the design's `[⛶]` is a **chrome toggle over the same canvas** (`hideChrome`/`showChrome` in the file's own script), not a second presentation. |

### Proposed diff — for the owner to apply

```diff
@@ Shape & elevation @@
-- Compact row radius: **18** — `DoneCard`, `WaitingCard`, and the Entry Detail hero. A row is not a card and does not take the card's corner
+- Compact row radius: **18** — `DoneCard` and `WaitingCard`. A row is not a card and does not take the card's corner
+
+- Sheet radius: **26**, top corners only — Entry Detail's reading sheet. Its grabber is 38 × 5 in `border`, centred, with 14 clear beneath it
+
+- Floating chrome: a **40pt** circle of `surface` at 90% with the standard shadow, in a 44pt tap target, inset 16 — the back, overflow and expand controls on Entry Detail. Neutral, never accented

@@ ### EntryDetail @@
-Unlike the timeline root, this screen wears the standard navigation bar, titled with the entry's `occurred_at` in compact form and carrying an ellipsis menu of Edit and Delete.
+**Presented full screen, never pushed.** No navigation bar and no tab bar: the floating bar is a sibling of every tab in `RootView`'s `ZStack`, so a pushed screen cannot hide it. Back and an overflow menu of Edit and Delete ride as floating chips over the canvas.
+
+Three layers. A canvas that runs to every edge, floating chrome over it, and a cream sheet anchored to the bottom safe area — rounded on its top corners only, with a grabber above its content. **The canvas is the only layer that changes across the seven shapes.**

-| Hero | pictures, else the voice player, else nothing. One picture is a 4:3 block at hero radius with a `border` hairline; several are a paged carousel 300 tall. Video carries a play glyph and its runtime. |
-| Prompt | filled block at quote radius, tinted to the entry's kind. `ANSWERED <date>` eyebrow in inkFaint over the prompt in inkMuted. 18 below the hero. |
-| Title and body | detail title and body, both in **ink** … |
-| Transcript | `TRANSCRIPT` label in inkFaint over body copy in ink. …|
-| Metadata | key/value rows under a `border` divider … |
-| Tags | `chipPlain` chips with `emphasis`. |
+| Canvas — picture | the photograph or poster filling the screen, under a 150pt ink scrim at 50% falling to clear. Video adds a centred 76pt play control, terracotta glyph on `surface` at 92%. |
+| Canvas — voice | `periwinkleSoft`, an 84pt periwinkle play circle, a 96pt waveform, and `0:00 / 1:47` in periwinkle. |
+| Canvas — did it | `sage`, a 74pt `sageInk` check on `surface`, **the prompt at detail title** — the artifact, because there is no other — and "Nothing was recorded. That's allowed — it still happened." in `inkMuted`. |
+| Canvas — written | `canvas`, a `periwinkleSoft` callout at quote radius labelled `THE QUESTION` in periwinkle, then the title at detail title and the body at body. |
+| Sheet | title at 20pt semibold, the parent's caption in `inkMuted`, then one meta row: the age as a periwinkle capsule, then the date. Expanding adds `THE PROMPT`, the kind chip and the tags. **A written entry's footer is flush** — `canvas`, no radius, no grabber, no shadow, a `border` hairline on top — because it is the bottom of the same page rather than a surface over another one. |

-The voice hero is periwinkleSoft at hero radius with a `periwinkleBorder` hairline, a 52pt periwinkle play circle, and **the waveform is the progress bar** rather than decoration above one.
+**The waveform is the progress bar** rather than decoration above one.

@@ Formatting @@
-- `DayHeaderText` for the day header's parts, `.full` for VoiceOver and the Entry Detail date line, `.compact` for a navigation bar.
+- `DayHeaderText` for the day header's parts, `.full` for VoiceOver, `.compact` for a navigation bar, and `.entryDate` / `.entryDateAndTime` for the printed date on Entry Detail — "Monday 10 August 2026", day before month and no comma after the weekday.
+
+**One qualifier at most on the Entry Detail date.** A count or a length where the entry has one, the time of day where it does not, and neither on a did-it entry.
```

### Where the design file and §2 of the brief disagree — file wins, reported

1. **Sheet title type.** §2 says "title (Detail title role, 26pt bold rounded)". The file sets it at **20px, weight 600, in the body face** (line 80). 26px Nunito 800 appears only as the *artifact* on Written, Did it and Sealed. Built the file's way.
2. **"Terracotta track" on the video scrubber.** The file's track is `#E6DCCE` with a terracotta *fill and knob* — a neutral track, not a terracotta one.
3. **Strip selection.** §2 says "outlined"; the file specifies a **2pt accent ring** (`box-shadow:0 0 0 2px ${A}`). Built as a 2pt terracotta ring.
4. **Date variants §2 does not mention.** The file prints `· 10 photos` on multi-photo and `· 0:42` / `· 1:47` on video and voice — and **no time** on any of them. That is where the with-time/without-time rule actually comes from.
5. **Written chrome.** §2's shared rule says the back chip is translucent everywhere. On Written the file draws it **solid `#FFFDF9` with a `#EDE5DA` hairline** — no translucency, no blur.
6. **Did-it sheet heading.** §2 says the sheet carries "the title". The file carries **the parent's note** at 17px/600 — the prompt has already taken the title role on the canvas.
7. **The file has an Edit entry / Share button pair** in the expanded photo sheet that §2 never mentions. Not built — Edit already lives in the overflow menu, and a second Edit plus a Share this app has no implementation for would be new scope.
8. **Gradient washes.** The file washes Voice and Did it with gradients. `design-system.md` reserves gradients for named emotional beats, names `Gradients.wash` as the only one and says "there is no third". Tokens are its authority, so these are **flat `periwinkleSoft` and `sage`**. If you want the washes, that is a token decision and the diff above does not make it.

---

## 3. Diagnosis — the three answers

**1. Why is the tab bar visible?**
Neither: it is not pushed *or* failing to hide the bar — **the bar is not in the navigation stack at all.** `RootView.signedIn` (`ios/Rascal/Rascal/App/RootView.swift:418`) is a `ZStack(alignment: .bottom)` whose first child is the current tab and whose second is `FloatingTabBar` (`RootView.swift:497`). Entry Detail was a `navigationDestination` inside the timeline's stack (`TimelineScreen.swift:79`) and Moments' (`MomentsScreen.swift:39`), and both stacks are *inside* that first child. Nothing pushed onto a tab can cover a sibling of the tab. `.toolbar(.hidden, for: .tabBar)` could not have helped either — this app draws its own bar and uses no `TabView`. Compounding it, `.safeAreaPadding(.bottom, tabBarHeight + 4)` at `RootView.swift:491` is applied to the `Group` wrapping all five tabs, so Entry Detail was also being inset to clear a bar it did not want.

**2. Why is the media a fixed band?**
A hard-coded aspect-ratio modifier, in two places. One picture went through `DetailMediaView`, whose box is `Color.terracottaSoft.frame(maxWidth: .infinity).aspectRatio(4/3, contentMode: .fit)` (`Timeline/MediaViewer.swift:42–44`). Several went through `EntryDetailScreen.gallery`'s `.aspectRatio(Self.galleryAspect, contentMode: .fit)` with `galleryAspect = 4.0 / 3.0` (old `EntryDetailScreen.swift:407` and `:413`). At 430pt wide that is a 322pt band, which is the measured 338pt band once the scrim and rounding are included.

**3. Is the sheet a real presentation or a `VStack` with a spacer?**
**Neither — and it is worse than a spacer.** It was a plain child of a `VStack(spacing: 0)` inside a `ScrollView` (old `EntryDetailScreen.swift:60`, `:122–126`), with rounded top corners painted on via `.background(Color.surface, in: UnevenRoundedRectangle(...))`. There was no spacer at all, so on any entry whose content was shorter than the screen the stack simply ended where the content ended and the backdrop `Color.ink` showed through everything below it. That is the 366pt void: not a sheet floating mid-screen, but a stack that stopped. There was no drag interaction and no grabber anywhere in the file.

---

## 4. Defects fixed

| # | Defect | Cause | Fix |
|---|---|---|---|
| D1 | Media renders as a fixed band | `.aspectRatio(4/3)` in `DetailMediaView` and `gallery` | New `FullBleedMedia`: a `GeometryReader`-sized `scaledToFill` clipped to the full canvas. Its own view rather than a third mode on `DetailMediaView`, whose fixed box, hairline and radius are all wrong here. |
| D2 | 366pt of empty canvas below the sheet | The sheet was the last child of a short `ScrollView` stack | The sheet is bottom-anchored in a `ZStack`; the canvas fills everything behind it. Measured empty canvas after: **none on any of the six.** |
| D3 | Sheet not anchored to the bottom safe area | same | Anchored, with content padded by the measured safe-area inset and the surface running under the home indicator via `.ignoresSafeArea(edges: .bottom)`. |
| D4 | No grabber, no rounded-top-only treatment | never built | 38 × 5 `border` capsule, 14 clear beneath, `UnevenRoundedRectangle` at radius 26 top-only. **Only where the sheet actually expands** — a grabber over a one-state sheet is the same lie as a chevron on a row that does not navigate. |
| D5 | Floating tab bar visible | see §3.1 | Entry Detail is now **presented, not pushed** — one `.entryDetail(…)` modifier in `EntryDetailPresentation.swift`, used by Timeline, Moments and the harness. A `fullScreenCover` is presented above the root `ZStack` and everything in it. |
| D6 | Expand control missing | never built | `[⛶]` in the top-right cluster, **single photograph only** — not on multi (paging owns the canvas), not on video (the play control already owns it). It hides all chrome; a tap anywhere restores it, which is the design file's own `hideChrome`/`showChrome`. |
| D7 | Chrome buttons carry an accent ring | `Image(systemName: "ellipsis.circle").foregroundStyle(Color.terracotta)` | Neutral: `ink` glyph on `surface` at 90%, 40pt circle in a 44pt target, standard shadow, no stroke. Terracotta is missions and primary action; a back button is neither. |
| D8 | Sheet omits caption, type chip, tag row | never built | Caption under the title where the entry has one; kind chip and tags in the sheet — at rest on written and did-it, behind the drag elsewhere, matching where the file draws them. |
| D9 | Date format wrong | `DayHeaderText.full` is the locale's own order | New `DayHeaderText.entryDate` / `.entryDateAndTime`, joined by hand so no locale can reinsert the comma. `full` is **left alone** — two VoiceOver labels on screens this pass does not own read it. |

### Found beyond D1–D9

- **Video never stated its length.** `factsSentence` read `duration_seconds` off audio rows only, so a video entry's meta line said nothing about how long it ran. Now audio-then-video.
- **`Layout.sheetRadius` was 24 against the file's 26**, with a comment arguing 24 "keeps it on the 4pt step this file already uses". That step does not exist — `heroRadius` is 18, `quoteBlockRadius` 16, glyph tiles 11 and 10. Set to 26.
- **The sheet could not survive Dynamic Type.** An expanded sheet at accessibility XXL is taller than the phone; a hugging `VStack` pushed its own title off the top edge. It now scrolls inside itself, capped at 72% of the screen, `.scrollBounceBehavior(.basedOnSize)` so short sheets are unchanged.
- **Two defects I introduced and caught by screenshot**, both listed here rather than quietly fixed: written repeated its title in the footer (canvas *and* sheet), and `[⛶]` appeared on video.
### Found by a second adversarial pass over my own diff

Nine more, after re-reading the whole diff as someone else's work. Three were regressions I had shipped.

| # | Defect | Fix |
|---|---|---|
| **R1** | **`.colorScheme(.dark)` did nothing it claimed and something it should not.** It does not move the status bar — it only seeds the environment for descendants — so the comment above it was false. Worse, it flips this screen's `Menu` and delete dialog to dark appearance, which is the 1.03:1 drift `design-system.md` measures and forbids. | `.preferredColorScheme`, which is the API that actually sets the status bar, scoped to the picture canvas alone. It is a second scheme pin in the product; the doc line is proposed in §2 rather than added. |
| **R2** | **Sealed letters lost Edit and Delete.** Moving off the navigation bar took the toolbar with it, and I gave the sealed card a back button only. A sealed letter is the one entry a parent most needs to be able to delete — it is the one they cannot open to check. | The overflow menu is on the sealed screen too. |
| **R3** | **The sealed card drifted to the vertical centre** once the navigation bar it sat under was gone — an unintended change to a screen `docs/decisions.md` settles, and its chrome was pinned to the *card's* top edge, floating mid-screen. | Card pinned back to the top; chrome positioned against the screen. |
| **R4** | **Tags were truncated to two.** I had copied `EntryCard`'s cap, which exists because a third chip pushes a card row past its edge. This sheet wraps and has the room, and `design-system.md` puts no cap on Entry Detail. Silently dropping the archive's own vocabulary on the one screen with space for it. | Every tag renders, in a new `FlowRow` layout. |
| **R5** | **Three hardcoded canvas clearances — 200, 170 and 40pt** — tuned to one text size. At accessibility XXL the voice waveform and clock sat behind a sheet that had grown past them, and a long written entry's last lines were permanently underneath the footer. | All three read the sheet's measured height, the way `RootView` reads the tab bar's. Verified at XXL. |
| **R6** | **A written entry was cut off mid-word at the footer hairline**, which reads as a rendering fault rather than as more text below. | `PinnedActionBackdrop` with 26pt above it — the pattern this app already uses everywhere content scrolls under something pinned. |
| **R7** | **`notice` became dead state.** The old `noticeLine` could never render (it was inside the `if let entry` branch, and `notice` is only ever set when `entry` is nil), so `missing` claimed *"This entry was deleted."* for what may be an offline fetch with nothing cached — the archive reporting a loss that has not happened. | `missing` renders the real reason when there is one, under "Can't open this one". |
| **R8** | **`struct FlowRow: Layout` failed to compile** — this file declares `enum Layout`, which shadows SwiftUI's protocol inside the module. | `SwiftUI.Layout`, spelled out, with the trap documented for the next custom layout. |
| **R9** | **Two dead `@State private var path: [UUID]` bindings** left behind in Timeline and Moments, on `NavigationStack`s that no longer have a `navigationDestination`. Appending to either would have been a silent no-op. | Removed; both stacks are plain. |

- **`Layout.sheetOverlap` was orphaned by this pass** — the sheet no longer rides up over anything — and is removed. **`DetailMediaView` (`Timeline/MediaViewer.swift`) is now dead**: `FullBleedMedia` replaced its only caller and nothing constructs it any more, including its `bleeds` parameter, which existed solely for this screen. Left in place rather than deleted — removing a shipped view is a cleanup the owner should sanction, not something to fold into a fidelity pass. Flagged here so it does not sit there unnoticed.

---

## 5. Screenshots

Twelve, iPhone 15 Pro Max (created for this run — no 15 Pro Max existed; only iPhone 17-family devices were installed), iOS 26.3, 1290 × 2796 px = 430 × 932 pt.

**Measurement method, and where I do not trust it.** A pure-Python PNG decoder scanning a column 8pt in from the left edge for the sheet's cream, plus a pass for rows that are one colour across their full width. At default sizes it agrees with the images to within the corner radius. **At XXL it does not** — it reported a 131pt sheet on a screenshot that plainly shows one about 660pt tall, because the probe column stops early once text reflows into it. Where the tool and the image disagree at XXL I have reported the image and said so, rather than printing a number I know to be wrong.

| # | File | Design section | Match | Sheet top | Sheet height | Empty region > 24pt |
|---|---|---|---|---|---|---|
| 1 | `phase22-photo-default` | 01 Photo | Yes | 775pt | 157pt | none — all uniform runs are photograph |
| 2 | `phase22-photos-default` | 02 Ten photos | Yes | 716pt | 216pt | none |
| 3 | `phase22-video-default` | 03 Video | Partial — no in-sheet scrubber, see §9 | 748pt | 184pt | none |
| 4 | `phase22-voice-default` | 04 Voice | Yes, flat ground not gradient | 673pt | 259pt | 129pt and 134pt of `periwinkleSoft` above and below the player — the canvas the design gives it |
| 5 | `phase22-written-default` | 05 Written | Yes | 769pt | 163pt | 344pt of `canvas` between body and footer — the page, on a short entry |
| 6 | `phase22-didit-default` | 06 Did it | Yes | 756pt | 176pt | 227pt of `sage` between the artifact and the sheet — the design leaves the same gap |
| 7–12 | `*-XXL` | all six | Legible, nothing clipped or truncated | sheet grows upward, capped at 671pt (72% of 932) | — | none |

Every screenshot: no tab bar, no navigation bar, sheet flush to the bottom edge, chrome neutral. Files are in the session scratchpad under `shots/`; a `-before` set of the same six is beside them.

---

## 6. Empirical verification disclosure

| What I ran and observed | What I reasoned about without running |
|---|---|
| All six types rendered, twice each (default + accessibility XXL) — 12 screenshots, plus a 6-shot "before" set on the unmodified screen | **Sheet drag expands and collapses.** Never driven by a finger. `simctl` cannot tap and there is no UI test target. |
| Sheet top edge, sheet height and every uniform region > 24pt, measured from pixels at default size on all six | **`[⛶]` presents and dismisses.** The control renders; the toggle path was not exercised by touch. |
| The 366pt void reproduced on the *unmodified* screen and measured at 302pt (photo) and 566pt (did-it) in the harness | **Strip paging is bidirectional.** Both ends read one `pictureIndex`, so they cannot disagree — but I did not swipe the canvas or tap a tile. |
| Baseline cold: build succeeded, 837 tests / 107 suites passed, 21 warnings | **Scrubber seeks.** Not shipped — see §9. |
| Final cold: build succeeded, 850 tests / 108 suites passed, 21 warnings, list byte-identical | **Play/pause works on Voice.** The screenshot shows the control at rest at `0:00 / 1:47`. Playback is `VoicePlayerView`'s existing, already-shipped path, reached through a new presentation; I did not hear audio. |
| Both break-test mutations, applied, observed failing, reverted | **`Add tag` opens.** Not shipped — see §9. |
| The date strings in the shipped screenshots: "Monday 10 August 2026, 10:04am", "Sunday 9 August 2026 · 10 photos", "Tuesday 4 August 2026" | **Reduce Motion.** Every animation is behind `@Environment(\.accessibilityReduceMotion)` and falls to a 0.2s `easeOut`, but I did not toggle the setting and re-shoot. |
| Two defects of my own, found by looking at screenshots I had taken | **The real app end to end.** The harness stands up `RootView`'s two layers faithfully, but no run against a live API with a real session was performed. |

The right-hand column is not a list of things I believe are broken. It is a list of things I did not watch happen, and it is longer than I would like — the absence of a UI test target is the reason, and it is the single biggest gap in this pass.

---

## 7. Break-testing

**Mutation 1 — did-it gains a time.** Deleted `guard entry.type != .didIt else { return DayHeaderText.entryDate(occurredAt) }` from `factsSentence`.
Observed, `EntryDetailFidelityTests`:
```
✘ "a did-it entry states the day and no time"
  Expectation failed: (sentence → "Tuesday 4 August 2026, 6:00pm") == "Tuesday 4 August 2026"
  Expectation failed: (sentence.contains(DayHeaderText.entryTime(...)) → true) == false
✘ Test run with 13 tests in 1 suite failed with 2 issues.
```
Reverted; green.

**Mutation 2 — the type is consulted before the artifact.** Moved `if pictureCount > 0 { return .picture }` in `backdrop` to *after* the type switch.
Observed, across the new suite and the existing v2 suite:
```
✘ "the artifact outranks the completion mode" — 2 issues
✘ "a did-it entry with a photo is a picture entry" — 1 issue   ← the pre-existing assertion
✘ Test run with 27 tests in 2 suites failed with 3 issues.
```
Reverted; green. Worth noting that this mutation was caught by an assertion that already existed, which is the outcome the rule in §5 is aiming at.

No assertion passed a mutation it should have caught.

### The one assertion I edited, and why

`EntryDetailV2Tests.factsUseOccurredAt` contained `#expect(sentence == DayHeaderText.full(occurred))`. D9 changes the printed date, so that comparison could not survive the correction it was ordered by. §5 says never edit an assertion to make it pass, and I am flagging this rather than doing it quietly:

- **was:** `#expect(sentence == DayHeaderText.full(occurred))`
- **now:** `#expect(sentence.hasPrefix(DayHeaderText.entryDate(occurred)))`, plus a new `#expect(sentence.hasPrefix(DayHeaderText.entryDate(created)) == false)`

The test's subject — "the date is `occurred_at`, never `created_at`" — is unchanged, its three other clauses are untouched, and it now has one more. The comparison was the mechanism, not the claim. The same one-word change was made at `didItIsComplete`.

I also wrote one bad assertion myself and let the suite catch it: `#expect(sentence.contains("14 July"))` hardcoded a UTC day for a fixture that renders as 13 July locally. Removed rather than papered over — the formatter-based clause beside it already covers the ordering.

---

## 8. Ranked confidence

| Confidence | Change | Reason if not high |
|---|---|---|
| Highest | Date formatting, with/without time, video duration | Asserted seven ways, break-tested, and visible in six screenshots |
| Highest | Type routing, seal ordering, completion mark | Pure functions, exhaustively asserted, one mutation caught by a pre-existing test |
| Highest | Tab bar removal | Diagnosed to a specific line, fixed structurally, absent from all 12 screenshots |
| High | Full-bleed media, bottom-anchored sheet, grabber, chrome | Measured at default size on all six |
| High | Absent-zone behaviour | Asserted, and visible on the photo entry, which has no caption |
| Medium-high | Sheet scroll cap at 72% | Correct at XXL by inspection, but the 0.72 is a judgement, not a token, and no doc names one |
| Medium | Strip paging | One `pictureIndex` drives both ends so they cannot desync, but I never swiped or tapped a tile |
| Medium | `[⛶]` immersive toggle | Renders and is correctly gated; the toggle was not driven by touch |
| Medium | Reduce Motion | Every animation is guarded, but the setting was not toggled and re-shot |
| Lower | Voice canvas vertical placement | Centred; the file puts the group at 150/848 from the top. It reads well and no token governs it, but it is not the file's number |
| Lower | Flat `periwinkleSoft`/`sage` instead of the file's gradients | A deliberate token-authority call (§2.8) that a reader may disagree with. One line each to change if you want the washes |

---

## 9. Open questions — things I stopped on rather than guessed

1. **The in-sheet video scrubber is not shipped.** The design puts an elapsed/duration scrubber inside the sheet. Drawing it is easy; making it *seek* means an inline `AVPlayer` on this screen, which is a new playback surface — video currently plays in the existing fullscreen `MediaViewerScreen`, reached by the centre play control. A scrubber that does not seek is a control that lies. §8 says stop and report rather than expand scope, so the canvas keeps the play control and the sheet states the length. **Needs a decision: build the inline player, or drop the scrubber from the design.**
2. **`Add tag` is not shipped.** §2 and §4 both call for it on Written and Did it. There is no tag editor in this app — tags are read-only in this phase, which is why `Entry.storedTagNames` is a denormalised copy rather than a relationship. Building one is a feature, and a dashed chip opening nothing is a control that lies. Existing tags render; the affordance does not. **Needs a decision.**
3. **Two colours in the design file have no palette equivalent** — the `Add tag` chip's `#D9CFC0` dash and `#A8A096` ink. Per §6 that is a finding, not a constant to add. Note also that `#A8A096` is close to `inkFaint`, which `design-system.md` measures at 2.13:1 on cream and forbids for controls (floor 3:1) — so even with a tag editor, that chip needs `inkMuted`.
4. **The design file's Edit entry / Share buttons** in the expanded photo sheet are not built (§2.7). Edit is in the overflow menu; Share has no implementation. Say the word if the pair should exist.
5. **`DayHeaderText.full` was deliberately left alone**, so the timeline's and the card's VoiceOver labels still speak "Monday, August 10, 2026" while Entry Detail prints "Monday 10 August 2026". That is two orders in one app. Unifying them is a one-line change that touches two screens outside this pass's scope — **your call.**
6. **The sheet's 72% height cap is invented.** No token governs how tall a sheet may grow. It wants a home in `design-system.md` or a better number.
8. **`preferredColorScheme(.dark)` over a photograph is a second scheme pin.** `design-system.md` says the app is light only and "pins no scheme", with the widget as the one exception. Over a photograph under a 50% ink scrim, dark status-bar glyphs do not read, and this is the only API that moves them. The alternative the codebase already uses is `MediaViewerScreen`'s `.statusBarHidden()` — hiding the clock entirely. **Needs a decision: the scoped pin, or hide the status bar over pictures.**
9. **`FlowRow` is a new layout primitive** in `Layout.swift`, which `RascalShare` also compiles. It is ~40 lines, uses only SwiftUI, and exists because chips must wrap rather than truncate at accessibility sizes. If you would rather it not live in the shared design-system file, it moves in one commit.
7. **iPhone 15 Pro Max did not exist on this machine** — only iPhone 17-family simulators. I created one on iOS 26.3 to match the 430 × 932 pt the D1–D9 measurements were taken at. Worth knowing the brief's device is not installed by default here.
