# Phase 20 — Onboarding and Settings catch-up
Lane B (iOS) only. Branch `phase-20/onboarding-settings` off `main`.

**Screenshots were not attached to this run.** The brief refers to nine of them by filename; none arrived in the conversation and none are on disk. Every diagnosis below is therefore made from the source — which is what §5 and §12.3 demand anyway ("Trace each to its source. Do not summarise; quote the code") — and the screenshots' described symptoms are used only to confirm that what the code does matches what was seen. Where a claim rests on the screenshot alone, it is marked.

* * *
## 1. What changed
The first real screen of the app no longer opens looking broken, and its date wheel is legible on a phone in Dark Mode. The camera-roll row is back on the **+** sheet in every permission state, which is what it needed to be, because the row is the only door to the explainer that asks for the permission it was gated on. Every count the backfill shows under selected-photos access now says whose photos it counted. The Syncing card's five values were traced to their sources; one was a placeholder, one conflated two different facts, one action reported nothing, and all three are fixed. The daily note says it is a notification, its time is editable, and the duplicate timezone picker is gone. Sync diagnostics moved behind one row, recompute moved onto the birthday sheet as an unchecked checkbox, and the centre **+** is drawn above the tab bar instead of underneath its own stroke.

* * *
## 2. Preflight results — measured, not quoted
| Check | Result |
| --- | --- |
| **0.1** iOS suite green, cold | **678 tests in 81 suites, all passing.** `DerivedData` deleted first, `CODE_SIGNING_ALLOWED=NO`. `docs/roadmap-status.md`'s 678/81 is confirmed by measurement. |
| **0.2** Inherited warnings | **21**, in three files: 14 `RascalTests/PushPermissionTests.swift`, 4 `RascalTests/ExtractionTests.swift`, 3 `Rascal/Extraction/ExtractedDetails.swift`. All `lock`/`unlock` in async contexts, plus three main-actor isolation warnings. |
| **0.3** Screenshot harness | **Runs.** Build → `simctl install` → `launch` → `io screenshot` verified end to end. |
| **0.4** Phase 19's boundary | **Not touched.** `TodayBoardView`, `TodayBoard`, `TodayBoardPreviews` and the widget's slot selection are unmodified. No fix here required editing them. |
| **0.5** Backfill genuinely on this branch | **Confirmed from source.** `BackfillScanResult` (`BackfillScan.swift:197`), explainer (`BackfillPermissionScreen`, `BackfillFlowView.swift:312`), month list (`BackfillSuggestionsScreen`), day picker (`BackfillMonthPickerScreen`). |

**After:** **705 tests in 86 suites, all passing**, cold from a deleted `DerivedData`. **21 warnings, the same 21, in the same three files — zero introduced, and zero in any file this phase touched.**

* * *
## 3. The diagnosis for each of the nine
### §1a — the picker opens in an invalid state
**The brief's stated mechanism is wrong, and the symptom is real.** `@State private var date = Date()` defaults to _today_, and `BirthdateRule.check(Date())` returned `.ok` — a fresh install opened valid. What the brief describes is reachable by a different route: the picker was unbounded, `write()` persisted on **every** wheel change including invalid ones, and `.task` restored whatever was on disk. So a parent who spun the wheel forward and put the phone down came back to the first real screen of the app rendering "That's still ahead of us" under a disabled Continue, before touching anything. That is the state a TestFlight device is in.
### §1b — contrast. **Bisected, and all four of the brief's candidate causes are wrong.**
No ancestor applies `.opacity` or `.disabled`; the scaffold's `.foregroundStyle(Color.ink)` is on the headline `Text` alone, not the container; there is no container `.tint`; nothing dims on invalid. Four variants in the harness, `simctl ui … appearance dark`:

| Variant | Selected row | Adjacent row |
| --- | --- | --- |
| A bare (shipped code) | **1.03:1** | **1.02:1** |
| B `+ .foregroundStyle(.ink)` | **1.03:1** | 1.02:1 |
| C `+ .environment(\.colorScheme, .light)` | **10.51:1** | 2.48:1 |
| D both | 10.51:1 | 2.48:1 |

**B is identical to A**, which confirms the possibility the brief raised: `DatePicker(.wheel)` does not honour the foreground style it is given. And it changes the fix — the fix is the colour scheme, not the foreground style.

**Root cause, exactly:** `ios/Rascal/Rascal/Onboarding/ChildSetupFlow.swift:151` carried none of the three modifiers the app's other two `DatePicker`s carry. `Palette.swift` is entirely fixed `Color(hex:)` with no adaptive variants, and there is no `preferredColorScheme` or `UIUserInterfaceStyle` anywhere. On a phone in Dark Mode the app's own surfaces stay cream while `UIDatePicker` resolves _system_ label and fill colours for dark appearance — near-white rows and a pale grey selection capsule on cream. Everything else on the screen was legible because everything else is an explicit palette colour. In **light** appearance A and C render identically, which is the control that pins it.

`EditChildSheet.swift:79` and `ComposerView.swift:847` already carried `.environment(\.colorScheme, .light)` — two earlier phases hit this and patched locally. Onboarding never got the same treatment.
### §2 — why the row was absent
**Present in the source, and gated.** `AddToArchiveSheet.swift:76`, `if let offered`, where `offered = Self.offer(from: clusters) = clusters.first`. Not a feature flag, not an authorization check _in the sheet_ — a non-empty scan result.

**But transitively it is gated on authorization, which is the bug the brief predicted.**`RootView.offeredClusters` returned `[]` unless `backfill.state == .ready`, and `BackfillScanner.run` sets `.unavailable` and returns whenever `!authorization.canScan` — true for both `.notDetermined` and `.denied`. So on a phone that had never granted access: no clusters → no row → no way to reach the explainer → no grant → no clusters. **The feature was sealed behind its own door.**
### §3 — photo library
- **3.1** `PHPhotoLibrary.authorizationStatus(for: .readWrite)` is read in `PhotoLibraryBackfillSource.authorization()` (`BackfillScanner.swift:260`). It is _requested_ only in `requestAuthorization()` → `BackfillScanner.requestAccess()` → `BackfillFlowView.grantAndScan()` → `BackfillPermissionScreen`'s "Look through my photos". **The decision still holds: nothing else fires it.** One other request exists — `VideoPipeline.swift:105`, `requestAuthorization(for: .addOnly)` — but that is a _different_ permission with its own plist key, fired when saving a captured video back to Photos. Not the scan's, and not in the flow.
  
- **3.2 —** `.limited` **is handled at the flow's entry and was not handled after it.**`decideStage()` routes `.limited` to `BackfillLimitedAccessScreen`, so it is not treated as equivalent to `.authorized`. But "Continue with these" sets `stage = .suggestions`, and `BackfillSuggestionsScreen` had no idea access was limited: every month total there is computed over the shared subset and was presented as a fact about the library, under a headline reading "There's a lot here you haven't written about yet". **That is the live defect.** The `+` sheet had the same problem ("62 photos from October 2025, nothing logged" — "nothing logged" is a claim about a whole month). `presentLimitedLibraryPicker` did not exist anywhere.
  
- **3.3 —** `NSPhotoLibraryUsageDescription` **was present and did not match the explainer.** It read _"Nothing is read or uploaded unless you pick it."_ The scan **does** read the library — dates and counts — without anything being picked, which is exactly what the explainer's first bullet says. The string understated the app at the one moment iOS shows it.
  

**On the owner's question, stated plainly for the record:** the app **cannot** ask which permissions the user would like to grant. Full versus limited is chosen inside Apple's own dialog; the app chooses only _when_ to trigger it and can never pre-select or influence the outcome. What it can do — and now does — is offer `presentLimitedLibraryPicker` afterwards to widen a selection, which is not a permission prompt and may be shown any number of times.
### §4 — the FAB
**It is a child of the capsule, and the capsule's stroke draws on top of it.** Both halves. `createButton` was the middle element of the `HStack` carrying `.background(Color.surface, in: Capsule())` and `.overlay(Capsule().strokeBorder(Color.border, …))` — and an `.overlay` composites above everything in the view it modifies. `Color.border` is `#EDE5DA`, a warm off-white, drawn across the terracotta disc: the "faint white ring". `.offset(y: -10)` on a 52pt disc inside 8pt padding left it about 2pt proud of a ~57pt capsule, so "slightly raised" read as "sunk in".

The second defect: `RootView` inset content by a hardcoded `.safeAreaPadding(.bottom, 84)`. The bar is a capsule whose height follows Dynamic Type plus a lifted disc — 84 is right for one text size and one FAB geometry. Measured after the fix: **80pt**.
### §5 — the value-source table
See section 4 below, in full.
### §6 — the daily note
`SettingsSectionHeader("Daily note")` / `"One note a day"` / `"It carries that day's mission. Never more than one."` — three strings describing the product principle, none naming the mechanism. The denied state was **already correct**: `preference.offer == .blockedBySystem` replaces the control with a sentence and a Settings link, and nothing re-asks. No dimming existed in the off state either — `NotificationToggleRow` uses `Color.ink` / `Color.inkMuted` regardless of `isOn`.
### §7 — "Sent at" and "In"
**7.1 — the row was a button wired to nothing.** `NotificationSettingsSection.swift:61` set `showingPicker = true`; the file contained **no** `.sheet` **at all**. Dead state. The write path underneath it was already built and already correct — `NotificationPreference.setTime` → `PATCH /v1/me`, optimistic with rollback — but the rollback was **silent**, which the brief requires it not be.

**7.2 — which schema case: the second one.** `docs/data-model.md:19–20` gives `users` exactly two notification columns: `notify_enabled` and `notify_local_time` — _"a wall clock read in the_ **_child's_** `family_timezone`_, never the device's and never UTC"_. **There is no notification timezone on the user.** `UserResponse` carries none either. So there is no field to strand and nothing to keep in step: deleting the row is all that was needed. No migration, no client write-through.
### §8 — Advanced
Correctly built, wrongly placed, exactly as described. The risk is Phase 13's: `SyncStatusModel` is built in `.onChange(of: syncEngine != nil, initial: true)` rather than `.task`, and moving the actions behind a row makes that failure _quieter_ — a missing row instead of a missing card.
### §9 — recompute
A standalone `Corrections` card, driven by `confirmingRecompute` and `runRecompute()` in `SettingsScreen`.

* * *
## 4. The Syncing card — every value, traced
| Value shown | Where it comes from | Live, stale, or placeholder? |
|---|---|---|
| `UPLOADING` eyebrow | `SettingsScreen.syncSummary(outstanding).eyebrow`, literal, branched on `outstanding.isClear` | **Live** (derived) |
| `8 left` chip | `"\(outstanding.total) left"`; `total = entries + deletions + media` | **Live but conflated** — `media` came from `MediaCoordinator.outstandingCount`, `filter { $0.deletedAt == nil && !$0.isComplete }`, which counts `failed` rows identically to rows still on their way |
| `8 files still to upload` | `syncSummary` from `outstanding.media` | Same conflation |
| `They'll finish on their own when you're back on a good connection.` | literal | **Wrong for the failed subset.** `MediaUploadState.failed` is *"past the retry cap… surfaced and manually retryable"* — it will not finish on its own |
| `Transcribe backlog — 4 voice notes have no transcript yet` | `TranscriptionQueue.backlogCount(in:)` + `failedCount(in:)`, recounted on appear, on `scenePhase`, and on progress change | **Live.** Already separates waiting from failed and already hides at zero — **no fix needed** |
| `Last pull — Off` | `SyncStatusModel.lastPullDescription`: `guard let last = engine.lastSuccess else { return engine.pullEnabled ? "Not yet" : "Off" }` | **Placeholder.** A row whose value is a timestamp rendering the feature's on/off state |
| `Position` | `engine.cursor` | **Live** (row hidden when nil and pull off) |
| `Last attempt` | `engine.lastError` | **Live** |
| `Pull changes from the server` | `engine.pullEnabled` via `pullEnabledBinding` | **Live** |
| `Retry now` | `SettingsScreen.retry()` → `sync.sweep()` on the `EntrySync` `RootView` built with the process-wide coordinator | **Live, and reached `MediaCoordinator.shared` correctly.** `RootView.task` does `MediaCoordinator.shared = coordinator` on the same instance it injects — one object, no second created. **It reported nothing afterwards** |

**Nothing was deleted for want of a number.** Every surviving value traces to the local store or the engine's own state, so no row needed dropping and no `GET /children/{id}/stats` was invented.

**Fixes:** `Last pull` now shows a relative time, `"Never"`, or `"Never — pulling is off"`. `failedMedia` is counted separately (`MediaCoordinator.failedCount`), the counter shows `outstanding.waiting`, stalled files get their own line, and when _everything_ is stalled the card drops the counter and the "finish on their own" promise entirely. `Retry now` reports a result derived from the counts either side of the sweep.

* * *
## 5. Contrast measured
Sampled from harness screenshots by taking the modal colour of the background region and the pixel furthest from it in luminance within the glyph box, then WCAG 2.1. **Method validated against the brief's own figure:** `inkFaint` `#B4ADA3` on canvas computes to **2.13:1**, matching the number in §6 exactly.

**§1 — birthdate wheel, dark-mode device**

|     | Before | After | Bar |
| --- | --- | --- | --- |
| Selected row on its capsule | **1.03:1** | **10.51:1** | ≥ 4.5 ✅ |
| Adjacent row above, on canvas | 1.02:1 | **2.48:1** | ≥ 3 ❌ |
| Adjacent row below, on canvas | 1.03:1 | **1.20:1** | ≥ 3 ❌ |

**The adjacent-row bar is not met, and I do not believe it is reachable with** `.wheel`**.** Those two figures are **identical in light appearance** — they are `UIDatePicker`'s barrel-fade gradient, not a consequence of this defect or this fix, and no public API changes them. The private `setValue(_:forKey: "textColor")` route is the one the brief forbids, so it was not taken. `.compact` — the style `EditChildSheet` already uses for this same field — measures **20.16:1** and clears everything. That swap is one line and is the top item in section 9.

**§6 — daily reminder off state**

| | Ratio | Bar |
|---|---|---|
| Off-state subtitle, `inkMuted` `#6E6A63` on card `surface` `#FFFDF9` | **5.29:1** | `inkMuted` floor ✅ |
| Row label, `ink` `#23253C` on `surface` | **14.75:1** | ✅ |
| (`inkFaint`, the value the brief rules out) | 2.13:1 | not used here |

Nothing dims in the off state: same colours, same card, on both branches.

* * *
## 6. Decisions I made that the brief did not make for me
1. **Kept** `.wheel` **and reported the miss, rather than switching to** `.compact` **unasked.** The wheel is the better interaction for a date years in the past, and the reported defect — invisible text — is fully fixed. The shortfall is intrinsic to the control and identical in light mode. Raised rather than chosen; see section 9.
  
2. **Did not add** `.foregroundStyle(Color.ink)` **to the onboarding wheel for symmetry with its two siblings.** I measured it as a no-op there. Adding a modifier proven to do nothing would be decoration that reads as a fix.
  
3. **Made** `OnboardingStepScaffold` **scroll.** §1's acceptance asks me to confirm the screen scrolls with actions pinned at XXL; it did not, and at `accessibility-extra-extra-large` it pushed the progress rail under the Dynamic Island. The scaffold is shared by all five onboarding steps, so this touches all five. Phase 18's pattern, applied to the place that owns the layout.
  
4. **Left** `Outstanding.total` **meaning what it meant.** Splitting it would have moved Today's count, which is Phase 19's surface. `failedMedia` is additive and `waiting` is derived.
  
5. **Reused onboarding's** `NotifyTimePickerSheet` rather than building a second picker, and gave it the colour-scheme fix now that Settings is a caller.
  
6. **Read §6's "shows a plain value — 'Off'" as "must not read as disabled".** The toggle already communicates off; a literal "Off" label beside a switch showing off is redundant. What I built is the undimmed card plus a factual line naming the time it would arrive.
  
7. **Wrapped** `SettingsScreen` **in a** `NavigationStack` so §8's row can push. The root's bar is hidden; the pushed screen turns its own on.
  
8. **Set** `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`, which §3 permits _only if_ the in-app path is built. It is.
  
9. **Rewrote** `NSPhotoLibraryUsageDescription`**.** §3.3 asked whether it matched the explainer. It did not, so I fixed it rather than only reporting it.
  
10. **Carried** `isLimited` **into the pushed month picker too** — found in the §13 re-read, not in the brief.
  

* * *
## 7. Verified empirically vs reasoned about
**Empirically — I ran it and looked at the result**

- 678/81 cold before, 705/86 cold after; 21 inherited warnings before and after, same three files.
  
- The four-variant wheel bisect, in dark and light appearance, and every contrast figure in §5.
  
- The birthdate step rendering fixed on a dark-mode device, at default, XXL and accessibility-XXL.
  
- The scaffold overflow at accessibility-XXL, before and after.
  
- The FAB drawn above the capsule with a clean cream ring, over both a `surface` card and a `terracottaSoft` card.
  
- Bottom inset: bar measures **80pt**; scrolled to the bottom, the last card clears it.
  
- Every test in section 8, including each break.
  
- `NSPhotoLibraryUsageDescription` / `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` in both plists.
  

**Reasoned about — read the code, did not run the path**

- The §1a restore-a-future-draft mechanism. Reachable by inspection and consistent with the screenshot; not reproduced on a device.
  
- Everything `.limited`. The simulator has no limited-library grant, so every limited path is exercised through `StubAssetSource` only. `presentLimitedLibraryPicker` has **never been called on a real library** — including whether `topViewController()` finds the right controller under a `fullScreenCover`.
  
- That `Retry now` reaches `MediaCoordinator.shared`: traced through `RootView.task`, not observed.
  
- That the bottom inset reaches all four tabs: the modifier is on the `Group` and no tab screen overrides the bottom safe area (grepped). Verified on a harness reproducing the same code path, **not** on the real Settings screen.
  
- That `NavigationStack` does not disturb the ambient safe-area padding Settings is given.
  
- The §8 race: modelled in a test as the state transition the view performs, not driven through a real cold launch.
  
- Every VoiceOver label.
  

* * *
## 8. Assertions I broke, to prove they work
**§2 —** `includesCameraRoll` **→** `offer != nil` (the original defect):

```
✘ "The camera-roll row is present in every authorization state"
  … (empty → AddToArchiveModel(authorization: .notDetermined, offer: nil)).includesCameraRoll → false
  ↳ row missing with no clusters: .notDetermined
  … .limited / .authorized / .denied — 4 issues
```

**§5.2 — counter back to** `outstanding.total`**; §5.1 —** `lastPullDescription` **back to the toggle state:**

```
✘ "files past the retry cap are not counted as files still on their way"
  Expectation failed: (value.counter → "8 left") == "3 left"
✘ "the toggle is off before anyone touches it, and the rows say so"
  Expectation failed: (model.lastPullDescription → "Off") == "Never — pulling is off"
✘ "flipping the toggle reaches the store the engine reads"
  Expectation failed: (model.lastPullDescription → "Not yet") == "Never"
```

**§9 —** `recomputeAges` **getter no longer conjoined with** `birthdateChanged`**:**

```
✘ "it cannot be true while the birthdate is unchanged, however it got there" — 2 issues
✘ "editing only the name does not offer the box" — 1 issue
  Expectation failed: (edit.recomputeAges → true) == false
```

All three restored and re-run green. **Two tests also failed honestly on the first run, before any deliberate break** — the tone assertions caught my own copy ("Nothing is lost" tripping a `lost` check, and "never a nudge about something you missed" tripping a `missed` check). Both were fixed by changing the copy or by making the assertion precise about negation and word boundaries, never by deleting the check.
### Two existing assertions were replaced
Both because the brief overturned the behaviour they pinned, not to make a failing test pass. Flagging them explicitly because §11 says never to edit an assertion to make a test pass:

1. `BackfillOfferTests.noRowWhenNothingToOffer` — `#expect(AddToArchiveSheet.offer(from: []) == nil)`, commented _"The row is absent, not empty."_ A good rule for a row that **reports** something; the wrong one for a row that is a **door**. §2 and `docs/decisions.md` both require the row unconditionally. Replaced with the four-state test.
  
2. `SyncPullSettingsTests` — `#expect(model.lastPullDescription == "Off")` and `== "Not yet"`. §5.1 calls this value "unambiguously wrong". Replaced with `"Never — pulling is off"` and `"Never"`.
  

* * *
## 9. Ranked by what I am least confident about
1. **The wheel's adjacent-row contrast, at 2.48:1 and 1.20:1 against a 3:1 bar.** _Resolved by:_ deciding whether to switch this picker to `.compact` (measured 20.16:1, already used for this same field on `EditChildSheet`) and accept the interaction change, or accept the miss as a property of `UIDatePicker`. One line either way. **This is the one decision I would most like overruled or confirmed.**
  
2. **Every** `.limited` **path is stubbed.** The notice, the widened-selection round trip, the rescan afterwards, and whether `topViewController()` resolves correctly under a `fullScreenCover` have never run against a real library. _Resolved by:_ one device session — grant Selected Photos, open the flow, tap "Share more photos".
  
3. **§1a's mechanism.** I am confident the defect is real and that the fix removes it, less so that restore-from-draft is the _only_ route to it. _Resolved by:_ the TestFlight device — if it still shows a future date on the birthdate step after this build, my mechanism is incomplete.
  
4. **The bottom inset on the real Settings screen**, now that it is inside a `NavigationStack`. Verified on a harness with the same code path, not on the screen from the screenshot. _Resolved by:_ a device screenshot of Settings scrolled to the bottom.
  
5. **The** `+` **sheet's content-sized detent.** `onGeometryChange` feeding `.presentationDetents` can settle visibly on first present. Not observed; the sheet was not screenshotted. _Resolved by:_ opening it once on a device.
  
6. `.presentationDetents([.height(h), .large])` **at accessibility text sizes**, where `h` may exceed the screen. `.large` is in the set, but I did not confirm the transition.
  
7. **The §8 race test models the transition rather than driving a cold launch.** It would not catch a regression that moved the model construction back into `.task` while leaving the state machine intact. _Resolved by:_ a UI test, or the harness launching into Settings on a device.
  

* * *
## 10. What I did not do, and why
- **No screenshots of the composer sheet, the limited-access notice, the diagnostics screen or the recompute checkbox.** The harness reaches a screen by temporarily repointing the app's root, and each of those needs a live session plus a state the simulator cannot produce (a limited grant, a populated sync queue). Their layout is reasoned about, not seen.
  
- **Did not switch the birthdate picker to** `.compact`**.** Item 1 above.
  
- **Did not add an app-wide** `preferredColorScheme(.light)`, though the §1b diagnosis implies every system control in the app has this defect on a dark-mode phone. That is a whole-app change on the strength of one screen's evidence and belongs in its own phase with its own audit. Two pickers already carried the local fix; this phase added it to the two that did not (`ChildSetupFlow`, `NotifyTimePickerSheet`). **Flagged as a standing risk.**
  
- **Did not touch** `TodayBoardView` **or the widget** (§0.4), `api/`, `PHPickerViewController`, `KindBadge`, `SectionLabel`, **paper grain**, or the completion burst.
  
- **Did not build a re-prompt funnel.** `presentLimitedLibraryPicker` is not one — it needs no new permission and iOS's own prompt is never fired twice.
  
- **Nothing is committed.** `CLAUDE.md` requires asking first.
  

* * *
## 10b. Second pass — nine things the first pass got wrong
Everything below was found by re-reading the diff after the work was reported complete, and every one is fixed. They are listed because "it compiled and the suite was green" was true of all of them.

1. `EditChildSheet` **had a stranded doc comment.** `/// On success the sheet closes…` was left above the checkbox after `save()` moved, describing the wrong member — and describing behaviour that was no longer true, since the sheet now stays open.
  
2. **After a successful save the only exit was a button called "Cancel".** Holding the sheet open to show `entries_updated` meant a screen whose changes were already on the server still offered Cancel, and offered a Save that `canSave` had disabled. It is now Done, and Cancel is gone the moment the `PATCH` lands.
  
3. **A failed recompute was unreachable to retry.** With the birthdate now matching the server, `canSave` is false and Save cannot run it again — a parent would have had to change the date to something else and back. There is a "Try again" under the failure line.
  
4. **Done was disabled while the recompute ran**, and Cancel was already gone — a window with no toolbar exit at all. Never disabled now.
  
5. `NotificationPreference.writeFailed` **was one boolean for two different writes**, so a refused _toggle_ rendered "That didn't save — it's still set to 7:00 PM", naming the one value nobody was changing. It is now `WriteFailure.switching` / `.time` and the line names the right control.
  
6. **The tab bar's lift was measured from the capsule's centre.** A fixed centre offset only gives a fixed protrusion while the capsule is a fixed height. It is now anchored to the capsule's top edge, so the disc protrudes the same amount whatever the capsule does. (Verified at `accessibility-extra-extra-large`: the bar measures 78pt at both sizes, because those tab labels use a non-scaling `Font.system(size:)` — so the original would not have broken in practice. The anchored version does not depend on that staying true.)
  
7. **The** `+` **sheet's detent set changed from** `.medium` **after the first layout**, so it opened at half screen and resized in front of the parent, on the sheet reached on the way to every entry. The measured height is now seeded so the correction is a few points. `presentationSizing(.fitted)` **was tried first and is measurably worse** — a `ScrollView` has no intrinsic height, so it produced a near-full-screen sheet. Screenshotted both.
  
8. `LimitedLibraryPicker.isAvailable` **was dead code** — never called, and a second source of truth for a state `BackfillScanner.isLimitedLibrary` already owns. Deleted.
  
9. `BackfillActionBackdrop` **was being used by every onboarding screen.** Giving the onboarding scaffold a pinned footer made all five steps depend on a type whose name says "backfill". Renamed `PinnedActionBackdrop`.
  

Also fixed: `SyncDiagnosticsScreen` now fills its width explicitly rather than relying on the card inside to stretch the scroll view, and `retryResult` no longer says "3 still to go" when the three remaining have stopped trying — the same countdown-to-a-non-arrival the card's headline was fixed for, which had survived in the retry message.

**Verified on screen in this pass:** the `+` sheet at default and `accessibility-extra-extra-large`; the FAB at both sizes; the pushed diagnostics screen showing a working back button under a root that hides its navigation bar; and the onboarding name step with the keyboard up, confirming the new scaffold pins its footer above the keyboard rather than behind it.

* * *
## 11. Adversarial re-read (§13)
- **A Syncing-card value that cannot be traced to a live source** — none. Section 4 traces all ten.
  
- **A** `.limited` **path reporting a count as complete** — **found one.** The pushed `BackfillMonthPickerScreen` prints a month total in its subtitle, computed over whatever `PHAsset.fetchAssets` returned, with no indication it was a selection. The suggestions screen's notice does not travel with the push. Fixed: `isLimited` is carried in and the subtitle reads "N photos you've shared".
  
- **The camera-roll row gated on anything** — no. `includesCameraRoll` is `true`; the view renders the divider and row unconditionally; asserted across all four states.
  
- **A screen still scrolling under the tab bar** — none found. The inset is on the `Group` wrapping all five tab cases, and no tab screen overrides the bottom safe area. Caveat in section 7.
  
- **Contrast taken _down_ toward a mockup** — no. §1 went 1.03 → 10.51. §6 was already at 5.29 and was not lowered. No new use of `inkFaint` for anything meant to be read.
  
- **The recompute checkbox reachable with the birthdate unchanged** — no, and this was the specific trap. The guard is in the **getter**, not an `onChange`, so ticking the box and then spinning the date back cannot leave a live flag behind an invisible control. Tested directly.
  
- **A now-unreachable onboarding validation with code behind it** — none. `BirthdateCheck`, `.inTheFuture` and "That's still ahead of us." are deleted. The only surviving mention is one doc comment recording what was replaced and why.
  
- **Copy implying a missed day costs something** — none. Asserted, including the negation-aware check that keeps "never a nudge about something you missed" legal while still catching real guilt copy.
  

* * *
## 12. Doc updates
- `docs/decisions.md` — the recompute-surface amendment (with the argument for why an unchecked-by-default checkbox preserves the settled rule), the `Advanced` card's removal, the FAB, and the Syncing card's audit including the pending-count split.
  
- `docs/decisions-log.md` — eight implementation-level calls plus the wheel-contrast open item.
  
- `docs/design-system.md` — **not touched, deliberately.** §12.11 says to update it _only_ if the FAB fix changed a token or a stated value, and it changed neither: the shadow it now uses is the one the system already specifies (`y: 2, blur: 8, opacity: 0.04`) in place of a terracotta glow that was never a token, the ring is existing `canvas`, and "the center + is a filled terracotta circle, slightly raised" is now more true than it was. The cream ring is a detail the spec does not mention and this phase did not add one — flagged here so the omission reads as a decision rather than an oversight.
  
- `docs/roadmap-status.md` — the iOS test count, in four places. That file's own premise is that every figure in it was measured, so leaving **678 in 81 suites** standing after this branch takes it to **705 in 86** would have made it wrong in exactly the way it exists to prevent. Both ends of the delta are measured: 678/81 at this phase's preflight before any code was written, 705/86 cold afterwards. The two surviving mentions of 678 are the historical baseline and are correct as history.
