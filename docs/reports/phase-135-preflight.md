# Phase 135 — preflight: photo library authorization for the historical-photo browser

**Lane:** iOS · **Branch:** `ios/phase-135-photo-library-authorization`, cut from `origin/main` at
`0f131288b6782eed2dc86734ed4c9dc147c41c83` ("removed vellum logos") · **Written:** Aug 30, 2026,
before any Swift file was touched. Nothing under `ios/` changed in this phase.

---

## Verdict, first

**Gate 1's first stop condition fires. Do not implement this brief.**

> *"The browser already calls `requestAuthorization` correctly on a `.notDetermined` status. The
> defect is then somewhere else and this brief has the wrong target."*

It does. `ios/Rascal/Rascal/Backfill/BackfillScanner.swift:334` calls
`await PHPhotoLibrary.requestAuthorization(for: .readWrite)`, reached only from behind an
explainer, only on a `.notDetermined` status, exactly as the brief's implementation spec asks for.
Every other element of that spec — one authority, four states handled explicitly, `.limited`
rendering content, `presentLimitedLibraryPicker`, a Settings-only `.denied` state with no retry
funnel, no silent picker fallback — already exists and shipped in build 20. **The brief describes
work that was done by phase 18 on Aug 10–11, 2026 and has been in the tree for twenty days.**

Two further findings that would each have stopped the brief on their own:

- **`PHAccessLevel` has no `.read` case.** The spec's "Access level: `.read`, not `.readWrite`"
  cannot be written. The enum is `addOnly = 1, readWrite = 2` and nothing else.
- **The reported symptom is real and is not a code defect.** It is what iOS shows for an app that
  has used the out-of-process picker and never requested library authorization. The owner's own
  screenshot proves the mechanism (below).

**Six real defects were found while proving that, none of which is the brief's target.** They are
listed at the end as candidate phases, not done here.

---

## Gate 0 — the number

Four commands, four answers, reported separately as the brief requires.

| Command | Answer |
|---|---|
| `git log --all --pretty=format:'%s%n%b' \| grep -oiE 'phase [0-9]+'` | **132** |
| `git for-each-ref refs/heads refs/remotes \| grep -oiE 'phase-[0-9]+'` | **132** |
| `gh pr list --state all --limit 200 --jq '.[].title'` | **132** |
| `grep -rhoiE 'phase[- ][0-9]+' docs/` | **134** |

**They disagree, and the docs answer is the correct one.** `max + 1` across all four gives
**135**.

The disagreement has a known cause, already documented by the phase it happened to: phases 133 and
134 landed under the commit subjects *"doc updates"* and *"docs"*, with no `Phase N:` title and no
PR, so `git log`, `git for-each-ref` and `gh pr list` cannot see them. `roadmap-status.md`'s own
134 row records the identical three-way undercount from Aug 29. `docs/decisions-log.md:13` (*"phase
133, the App Store Connect submission session"*) and `docs/phase-queue.md:859` (*"Follow-ups phase
134 generated"*) are the two live references the fourth command finds.

`phase-queue.md`'s header sentence was **not** used as a source, per the standing rule. It offers
134, which is spent.

**No line in `docs/phase-queue.md` asks for this work.** `grep -niE 'photo library|photo access|
authorization|camera roll' docs/phase-queue.md` returns three hits, all of them device-verification
scheduling (`:438`, `:443`, `:559`). There is nothing to delete on completion.

---

## Gate 1 — the five questions

### 1. Every Photos call site, classified

Grepped per symbol, not as one combined pattern. **38 code lines across 7 files**, plus 23
comment-only mentions and one test-target `import Photos` that constructs nothing.

**DIRECT-ASSET PATH — 23 lines, 2 files**

`Backfill/BackfillScanner.swift` (17): `:328` `authorizationStatus(for: .readWrite)` · `:334`
`requestAuthorization(for: .readWrite)` · `:337` `map(_ status: PHAuthorizationStatus)` · `:361`,
`:425` `PHFetchOptions()` · `:366`, `:434` `PHAsset.fetchAssets(with: .image,…)` · `:400`, `:401`
`PHAssetResource.assetResources` · `:467` `PHCachingImageManager()` · `:561`, `:563`, `:564`,
`:598`, `:599` identifier→asset resolution · `:584`
`PHImageManager.default().requestImageDataAndOrientation` · `:724`
`presentLimitedLibraryPicker(from:)`.

`:724` is classified **direct-asset, not picker**: it is the selection-widening sheet for a grant
that already exists, not an out-of-process picker that avoids one.

`Captions/CaptionProbe.swift` (6): `:77` `PHFetchOptions()` · `:80` `PHAsset.fetchAssets` · `:83`
candidate array · `:137` `requestContentEditingInput` · `:151`, `:152` `PHAssetResource`.
**This is a second direct-asset walker with no authorization call anywhere** — see defect B.

**WRITE PATH — 3 lines, 1 file.** `Media/VideoPipeline.swift:105`
`requestAuthorization(for: .addOnly)` · `:107` `performChanges` · `:108`
`PHAssetCreationRequest`. Note the literal string `PHAssetChangeRequest` has zero occurrences under
`ios/`; a grep for it misses the app's only library write, which uses the subclass.

**PICKER PATH — 11 lines, 3 files.** `Composer/ComposerView.swift:159`, `:264`, `:322`, `:513`,
`:549` · `Onboarding/AvatarStep.swift:21`, `:109`, `:133` ·
`Settings/ChildPhotoField.swift:82`, `:127`, `:349`. Two of these (`ComposerView.swift:264`,
`ChildPhotoField.swift:127`) are the lowercase `.photosPicker(…)` modifier and are missed by a
case-sensitive grep for `PhotosPicker`.

**TEST/FAKE — 1 line.** `RascalTests/BackfillTests.swift:1596` `import Photos`, present only
because `ThumbnailRequest` carries a `PHImageRequestID` in its signature
(`BackfillScanner.swift:647`). Both fakes conform to `BackfillAssetSource` and touch no PhotoKit
type.

**Zero occurrences anywhere under `ios/`:** `PHPickerViewController`, `PHAccessLevel`,
`PHPhotoLibraryChangeObserver`, `PHAssetChangeRequest`.

### 2. Is `requestAuthorization` called?

**Yes, twice, and only twice.**

`BackfillScanner.swift:334`, `.readWrite`, inside `PhotoLibraryBackfillSource.requestAuthorization()`.
Reached by exactly one chain, three taps from launch, every step confirmed:

1. **`+`** — `DesignSystem/FloatingTabBar.swift:140` → `App/RootView.swift:576`
   (`onCreate: { showingAddSheet = true }`) → sheet at `RootView.swift:373`.
2. **"Browse your camera roll"** — `Backfill/AddToArchiveSheet.swift:192` (`choose(.backfill)`) →
   `RootView.swift:416-431` `consumePendingAdd` → `showingBackfill = true` → `fullScreenCover`
   `RootView.swift:376`.
3. **"Look through my photos"** — `Backfill/BackfillFlowView.swift:452` → `onAgree` →
   `grantAndScan()` `:293-294` → `BackfillScanner.requestAccess()` `:261-262` → `:334`.

Step 3 exists only if `decideStage()` (`BackfillFlowView.swift:262-271`) read `.notDetermined` and
set `stage = .permission`. The lifecycle hook is `.task { await decideStage() }`
(`BackfillFlowView.swift:115`) — the browser's first appearance, not launch, not onboarding, which
is what the brief asks for.

`VideoPipeline.swift:105`, `.addOnly`, is the separate write path: save the original full-quality
recording back to the camera roll. One call site — `ComposerView.swift:352` inside
`importCapturedVideo`, itself fired only by the in-app camera's completion at `:258`.

### 3. Is `authorizationStatus` read, and does anything fall back to a picker?

Read at `BackfillScanner.swift:328`, via `BackfillScanner.run()`'s first line
(`BackfillScanner.swift:181`) — a **status read, never a request**. `RootView.swift:272`, `:298`
and `:353` all reach it on launch and foreground; none of them can prompt.

**There is no silent fallback.** `grep -rniE 'photospicker|PHPickerViewController|photoLibrary:'
ios/Rascal/Rascal/Backfill/` exits 1 — zero hits. `decideStage()` switches all four cases onto
named screens with no `default` and no fallthrough:

| Status | Screen | User sees |
|---|---|---|
| `.notDetermined` | `BackfillPermissionScreen` (`BackfillFlowView.swift:177`) | the explainer, then the system prompt on agree |
| `.authorized` | `.suggestions` or `BackfillNothingToSuggestScreen` | the grid |
| `.limited` | `BackfillLimitedAccessScreen` (`:183`) then `.suggestions` | content, plus "Continue with these" |
| `.denied` | `BackfillNoAccessScreen` (`:631-660`) | one honest sentence and a Settings button |

The `+` sheet's camera-roll row is unconditional in every state
(`AddToArchiveSheet.swift:38`, `var includesCameraRoll: Bool { true }`), and that is deliberate: the
doc comment at `:16-22` records the exact "sealed behind its own door" defect the brief predicts,
already found and already fixed. It is the one authorization behaviour with test coverage
(`BackfillTests.swift:524-537`).

The five `PhotosPicker` sites are separate, user-chosen surfaces. **None of them is selected
because authorization is absent.**

### 4. `NSPhotoLibraryUsageDescription`

**Present, literal, non-empty, in both plists. No xcconfig indirection — the brief's `blocked.md`
§19 trap does not apply here.**

`Info.plist:122` / `Info-Debug.plist:100`, verbatim:

> Pocket Chronicle reads the dates on your photos and how many there are, so it can suggest months
> worth writing about. The pictures themselves stay on your phone — nothing is uploaded, and
> nothing is added to the archive unless you pick it.

Also present in both: `NSPhotoLibraryAddUsageDescription` (`:124`/`:102`),
`NSCameraUsageDescription` (`:126`/`:104`), `NSMicrophoneUsageDescription` (`:128`/`:106`), and
`PHPhotoLibraryPreventAutomaticLimitedAccessAlert = true` (`:120`/`:98`).

`Config.xcconfig:55` sets `INFOPLIST_FILE = Info.plist` with `:56` overriding to `Info-Debug.plist`
for Debug only, and `:61` `GENERATE_INFOPLIST_FILE = NO`. `project.pbxproj` has no
`PBXShellScriptBuildPhase` at all, so nothing rewrites the plist at build time. **A Release archive
ships `Info.plist` with all four strings.** Confirmed against the shipped artifact, not inferred —
see the build-20 evidence below.

One correction to the brief: it gives the path as `ios/Rascal/Rascal/Info.plist`. The plists live
at `ios/Rascal/Info.plist`, beside the `.xcodeproj`, and `ios/CLAUDE.md:44-47` records that this is
load-bearing — `Rascal/Rascal/` is a synchronized folder group, so a plist placed there is also
copied as a resource and the build fails with *"Multiple commands produce Info.plist."* Following
the brief's path literally is a documented build break.

### 5. Which screen is the browser, confirmed from code

`ios/Rascal/Rascal/Backfill/BackfillFlowView.swift` (741 lines), the flow;
`BackfillMonthPickerScreen.swift` (517), the per-month grid. It **enumerates**, it does not
present a picker: `BackfillScanner.swift:366` and `:434`
`PHAsset.fetchAssets(with: .image, options:)` behind `PHFetchOptions` with a `creationDate`
predicate, thumbnails through `PHCachingImageManager` (`:467`) and full bytes through
`PHImageManager.default().requestImageDataAndOrientation` (`:584`). Zero picker symbols in the
directory.

---

## What actually explains the symptom

**The owner's screenshots settle it, and they settle it against the brief.**

The device Photos list shows per-app grants side by side: Amazon *Full Access*, Canva *Limited
Access*, Home Depot **Add Photos Only**, Chronicle **Private Access**. That list is the proof the
tree could not supply. iOS labels each grant distinctly, so *Private Access* is not a fifth
rendering of "limited" — it is the row for an app that has been given **no photo grant at all** and
whose only library contact was the out-of-process picker. Home Depot's *Add Photos Only* is what
Chronicle would read if `VideoPipeline.swift:105`'s `.addOnly` request had ever fired.

**One cause explains all three reported symptoms**: in this install, no permission-requiring API
has ever been invoked.

- **Photos** — the picker path (`ComposerView.swift:264`, `ChildPhotoField.swift:127`,
  `AvatarStep.swift:109`) was used; `BackfillScanner.swift:334` was not. Reaching it takes the
  three taps listed above and ends at a button reading *"Look through my photos."*
- **Camera / Microphone absent** — the only capture surface is `UIImagePickerController` with
  `sourceType = .camera` (`Media/MediaPreviewRow.swift:127-152`); `grep -rn "AVCapture" ios/
  --include='*.swift'` returns exactly one hit and it is a doc comment at `:124`. Presenting that
  controller in `.video` mode prompts for both camera and microphone. Their absence means it was
  never presented.
- **The recorded video** reached the archive by one of two zero-permission routes: `PhotosPicker`
  with `matching: .any(of: [.images, .videos])` (`ComposerView.swift:266-271`, movie handling at
  `:329-341`), or the share extension — `RascalShare-Info.plist:77` declares
  `NSExtensionActivationSupportsMovieWithMaxCount = 10`, and that plist carries no usage-description
  key of any kind.
- **`.addOnly` never fired** for the same reason: `preserveOriginal` is reachable only downstream of
  the in-app camera (`ComposerView.swift:258` → `:352`).

**Build 20 contains the code.** Read from the shipped artifact rather than the tree: the archive
at `~/Library/Developer/Xcode/Archives/2026-08-28/` records
`Distributions.0.uploadedBuildNumber = "20"`, and it is the only one of 21 local archives whose
`CFBundleDisplayName` is `Chronicle` (builds 6–8 are *Dogear*, 9–19 *Vellum*). `strings -a` on
`Rascal.app/Rascal` finds `requestAuthorizationForAccessLevel:handler:`,
`authorizationStatusForAccessLevel:`, `presentLimitedLibraryPickerFromViewController:`, and the
copy *"Browse your camera roll"*, *"Look through my photos"*, *"Share more photos"* and *"Photo
access is off"*. `otool -L` links `Photos.framework` and `PhotosUI.framework`. **The premise is
refuted in the binary the owner is running, not merely in `main`.**

`docs/Device-Verification/device-verification-backfill.md` opens *"Nothing in this feature has met a
real camera roll"* and its 23 boxes are all unticked — including `:12-14`, *"The permission
explainer is the only thing standing between you and a one-shot iOS prompt. Tap 'Not now' first and
confirm nothing was asked. Then reopen and grant."* No artifact in the repo records the prompt ever
being seen.

**The one-tap falsification:** open Chronicle → `+` → *Browse your camera roll* → *Look through my
photos*. If the system prompt appears and Settings then shows the three-way picker, this diagnosis
is confirmed and no code needed to change. If the explainer does not appear, that is a new and
different defect and this report is wrong.

**Method note, stated because the brief asks for it.** Everything above with a file:line, a command,
or an archive key was executed. Three platform claims are *reasoning*: that PHPicker requires no
grant, that `UIImagePickerController(.camera)` in `.video` mode prompts for camera and microphone,
and that a per-app Settings page lists only permissions the app has requested. The first and third
are now corroborated by the screenshots; the second is not, and nothing here depends on it alone.

---

## The `.read` instruction cannot be implemented

`$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/Photos.framework/Headers/PHPhotoLibrary.h:29-32`:

```objc
typedef NS_ENUM(NSInteger, PHAccessLevel) {
    PHAccessLevelAddOnly = 1,
    PHAccessLevelReadWrite = 2,
} API_AVAILABLE(macos(11), ios(14), tvos(14));
```

There is no `.read`. `requestAuthorization(for: .read)` does not compile. The narrower grant the
brief wants does not exist in PhotoKit: `.addOnly` is *write-only* — it grants no read at all and
would break the scan outright.

The existing comment at `BackfillScanner.swift:331-333` reaches the right answer for a slightly
wrong reason — it argues against `.addOnly` rather than noting that `.readWrite` is the only
readable level — but the code is correct and **must not be changed.**

The brief also asks to fold `VideoPipeline.swift:105` into the one authority. **Do not.** `.addOnly`
and `.readWrite` are different grants with different Settings consequences; consolidating them would
make saving a video ask for the whole library, which is a privacy regression and an App Review
question this app currently does not have to answer.

---

## Real defects found while proving the above

**None of these is the brief's target. None was implemented. Each is a candidate phase, and the
first three are the ones worth allocating.**

**A — the Settings round-trip is a dead end.** `BackfillFlowView` has exactly one lifecycle hook,
`.task { await decideStage() }` (`:115`); a grep for `scenePhase`/`onChange`/`onAppear`/
`willEnterForeground` over the file returns nothing else. The `.denied` screen's only action is
`SettingsLinkButton()` (`:656`), and `.limited` offers the same (`:610`). A parent who grants
access in Settings and comes back lands on a frozen screen still saying access is off. `RootView`
observes `scenePhase` (`:276`); the flow view does not.

**B — `CaptionProbe` walks the camera roll with no authorization handling, and it shipped in build
20.** `Captions/CaptionProbe.swift:77`, `:80`, `:83`, `:137`, `:151`;
`grep -rn -iE 'authoriz|permission|requestAuth|PHPhotoLibrary' ios/Rascal/Rascal/Captions/`
returns nothing. Reachable with no gate and no `#if DEBUG`:
`Settings/SyncScreen.swift:30-32` (`group("Photo caption check")`) → `:46` → 
`CaptionProbeScreen.swift:129` `CaptionProbe.run()`. *"Photo caption check"* is a literal in the
build-20 binary. On an unauthorized library this fetch returns empty and the screen reports zero
candidates as though it had counted — the exact silent-empty failure the brief was written about,
in the screen the brief does not name.

**C — the scan cache is not keyed to the grant, and it survives force-quit.**
`BackfillScanner.swift:188` sets `isLimitedLibrary`, then `:191` serves `cache.load()` without
reference to it. `libraryToken()` returns `nil` (`:347-350`), so `isFresh` degrades to a 24-hour
age check (`BackfillScan.swift:342-345`), and the foreground scan is deliberately `force: false`
(`RootView.swift:296-298`). A parent who scanned at Full and then narrowed to Selected Photos sees
whole-library counts under `.limited` copy for up to 24 hours — breaking
`AddToArchiveSheet.swift:45-52`'s own rule that *"a count is only ever stated when it is a complete
one"* in the one state that rule was written for.

**D — widening cannot refresh the grid.** `BackfillThumbnails.swift:66` memoizes a month's asset
list; `grep -n monthAssets` over the file returns only `:66`, `:75`, `:77` — **there is no
invalidation path**, and `stopCachingEverything()` (`:136-139`) clears `cachingWindows`, not this.
The loader is built once per presentation (`BackfillFlowView.swift:74`). `widenSelection()`
(`:244-247`) refreshes the scanner and never touches the loader, so after adding photos the card's
total updates while its thumbnails do not, and reopening the month shows the pre-widen grid under a
larger number. Recovery requires dismissing the whole flow. **This is the brief's break-test 2, and
it would fail today.**

**E — the widen affordance is on the wrong screen.** `LimitedLibraryNotice` renders at exactly one
site, `BackfillSuggestionsScreen.swift:62`. The screen a `.limited` parent actually lands on
(`BackfillFlowView.swift:183-188`) offers only *"Continue with these"* and Settings (`:608-610`),
and the month grid — where a missing photo is most visible — has none.

**F — the authorization path has zero test coverage.** `_didRequestAuthorization` is instrumented
at `BackfillTests.swift:209`, `:231-232`, `:237` and **asserted by nothing**. No test constructs a
`.notDetermined` stub source, and `grep -rn 'widenSelection|LimitedLibraryPicker|requestAccess|
decideStage|BackfillPermissionScreen' ios/Rascal/RascalTests/` returns no matches at all. The exact
property the brief doubts — that the prompt is reachable and fires once, from behind the explainer —
is the one thing untested. This is the gap where "build something" contradicts nothing settled.

**G — minor.** `ComposerView.swift:513-517` and `:549-553` hardcode `matching: .images` while the
sheet-driven picker at `:268` honours `isVideoPrompt`. On a video prompt the first in-composer
library tile cannot offer a video; the add-more path (`:469`, `:487`) can.

Also noted and deliberately **not** acted on, per the brief's out-of-scope list: the missing Camera
and Microphone rows, which §"What actually explains the symptom" shows are the same cause, not a
separate defect.

---

## What was not done, and why

- **No Swift file was edited.** Gate 1 is a hard stop and it fired.
- **No `decisions.md` entry.** The `.read` vs `.readWrite` question is not a decision — one of the
  two options does not exist. Writing a decision entry for it would be recording a choice nobody
  can make.
- **No `phase-queue.md` deletion.** No line there asks for this.
- **No build, no test run.** Nothing changed, so there is no baseline to move. The brief's
  break-tests 1–6 are device tests that require the owner; break-test 7 has nothing to measure.

## Method

Gate 0 and Gate 1 were answered by fifteen independent agents over the tree, the plists, the
`project.pbxproj`, the shipped build-20 archive and the docs, followed by six adversarial passes
that tried to break three claims. Claim A (*the browser already requests authorization; stop*) and
Claim C (*`.read` does not exist*) survived every attack, 0/2 refuted each. Claim B (*no silent
fallback; `.limited` works*) was **refuted 2/2 on its second half only** — the fallback half held
without counter-example, and defects D and E are what broke "working". Every finding reproduced in
this report was re-run by hand before it was written down.

---

## One thing found in passing, and the owner's call

**`docs/reports/` was deleted two days ago and this report re-creates it.** Commit `079bf02`
("docs", Aug 28, 2026) removed all twelve files in it — 4,587 lines, including
`phase-132-beta-auth-flap.md`, `phase-130-gate-document-diffs.md` and
`phase-120-proposed-diffs.md`. That looks deliberate, not accidental.

It leaves **fourteen dead references** across `docs/` and `CLAUDE.md`, and one of them matters
beyond bookkeeping: `CLAUDE.md`'s struck scope paragraph cites
`docs/reports/phase-120-proposed-diffs.md` §5 as the authority for a correction it says the tree
does not otherwise have, and quotes that report's own first line. **That citation now points at
nothing** — which is the same failure mode the paragraph was written to describe.

This report was written to the path the brief specified. Whether `docs/reports/` comes back, the
fourteen citations get struck, or this file moves elsewhere is the owner's call, not one to make
inside a phase that was told to stop.

---

# Addendum — the fixes, Aug 30, 2026

The owner read the report above and asked for the six defects fixed. That is the whole scope of
this half; the brief's original target was not built, because it already exists.

## What changed

| # | Fix | Where |
|---|---|---|
| A | The flow reconciles the grant on foreground, scoped to a change that matters | `BackfillFlowView.swift:142-145`, `:321-334`, `:673-731` |
| B | `CaptionProbe` reads the grant through the one authority and refuses a closed library | `CaptionProbe.swift:79-90`, `:138-160` |
| C | The scan cache records the grant it was computed under, and rejects a mismatch | `BackfillScan.swift:280-289`, `:352-372` |
| D | `BackfillThumbnailLoader.forgetAssets()`, plus a generation both grids key `.task(id:)` on | `BackfillThumbnails.swift:68-74`, `:89-113` |
| E | The widen affordance on the limited landing screen and the month grid | `BackfillFlowView.swift:680-694`, `BackfillMonthPickerScreen.swift:31-37` |
| F | Four suites, 20 tests, over the authorization path that had none | `BackfillTests.swift` |

Deliberately **not** changed: `PhotoLibraryBackfillSource.requestAuthorization`'s `.readWrite`,
`VideoPipeline.swift:105`'s separate `.addOnly`, the explainer gate, the unconditional camera-roll
row, and the four usage strings. All were correct.

## The review found this phase's own fix for A was inert

A 38-agent adversarial review over the diff returned one high-severity finding, confirmed 2/2, and
it was mine:

> The `scenePhase` hook is gated on `previous == .background` at the instant `current == .active`,
> but iOS interposes `.inactive` on every foreground, so `reconcileAuthorization()` never runs.

Correct. A UIScene goes background → foreground-inactive → foreground-active, and SwiftUI publishes
each edge separately, so a guard wanting both halves at once is never satisfied. **The fix compiled,
passed 1281 tests, and did nothing.**

The tree already knew. `TodayScreen.swift:286-288` writes the same fact down for the opposite
reason — *"`.background` specifically, not 'anything that is not active'. iOS delivers `.inactive`
for a pulled-down notification, Control Center, the app switcher, a screenshot and an incoming
call"* — and all eight other `scenePhase` observers (`RootView.swift:276`,
`SettingsScreen.swift:244`, `SubscriptionSection.swift:106`, `TodayScreen.swift:290`,
`TranscriptionBacklogSection.swift:41`, `AudioRecorderSheet.swift:64`, `PaywallSheet.swift:79`,
`OnboardingGate.swift:1120`) match `.active` alone. This one was the sole exception.

**Why no test caught it, and what was done about that.** It was a one-line comparison inside a view
body — nothing a model-level test can reach, and this suite has no view host. So the comparison was
lifted out into `BackfillGrantChange`, a `nonisolated enum` with `shouldReread(_:)` and
`effect(was:now:)`, and given its own suite. The gate is now arithmetic, and asserted.

Five more confirmed findings, all fixed in the same pass:

- **An unchanged `.limited` grant now still re-reads.** A parent can edit the shared selection in
  Settings without the grant level moving at all — which is precisely what the `.limited` screen's
  own Settings link invites — and `guard current != routedGrant` was blind to it.
- **`path.removeAll()` now fires only on a narrowing.** Widening was throwing away a half-made
  one-day selection to tell the parent there was more to see.
- **`assets(in:)` stamps the generation before its `await`** and refuses the write if it moved, so a
  fetch in flight when the grant changes cannot repopulate the memo `forgetAssets()` just emptied.
- **`ProbeError.notAuthorized` carries the grant.** The copy said access is granted "from the camera
  roll browser", which is false after a denial — the browser cannot ask again, and naming it would
  be a retry funnel in all but name. `AddToArchiveModel.cameraRollSubtitle` has always drawn this
  line; the probe's screen now draws it too.
- **Four weak tests corrected.** `limitedGrantScans` asserted only `state != .unavailable`, which a
  scan that found nothing satisfies; strengthening it to the actual clusters **immediately failed**
  and exposed its own fixture sitting below `BackfillPlan`'s `minimumAssets: 3`. `refusalIsRecorded`
  claimed something about a second ask and only asked once. One test duplicated pre-existing
  coverage in `CaptionProbeTests.swift` verbatim and was deleted rather than kept as padding.

Three further findings were dropped as false positives after two independent verifiers each.

## Rounds 2 and 3, and why they happened

The project's convention is that each review round audits the previous round's fixes. It earned its
keep twice.

**Round 2 found a regression introduced by round 1's own fix.** Making `.limited → .limited` return
`.refresh` fed `route(force:)`, which re-derives `stage` from the grant alone — so every foreground
under a Selected Photos grant flashed the scanning screen and dropped the parent back on the
interstitial they had dismissed with "Continue with these". `Effect` was split into four cases:
`.rescan` (same kind of access, re-read data, touch neither `stage` nor `path`), `.reroute`
(widened — re-decide the screen, keep the month), `.rebuild` (narrowed — pop it too). Round 2 also
found that `BackfillMonthPickerScreen.load()` had no cancellation guard, so a cancelled reload wrote
`days = []` and then `selection.retain(Set())` silently discarded the parent's picked photos — a
path the generation re-keying had itself opened; and that a foreground during the system permission
alert could race `grantAndScan`, now held off by a `routing` flag.

**Round 3 found the same regression a third time, relocated.** `loader.forgetAssets()` sat *above*
the `.rescan` guard, so an ordinary foreground still bumped the generation, blanked the open month
grid to a spinner and dumped every decoded thumbnail — the identical "ejected on every foreground"
failure, moved out of `stage` and into the loader. The scan is now the comparison: `.rescan` reads
the library and calls `forgetAssets()` only if `scanner.months` actually moved. Round 3 also found
`defer { loading = false }` firing on the cancelled path, clearing the flag under the successor task
and rendering *"Nothing in this month is on the phone to add."* over a month that has photos.

**The pattern across all three rounds is one mistake made three times**: treating "the library
changed" and "the kind of access changed" as the same event. Each round caught it at a different
layer — `stage`, then the loader generation. It is worth writing down because the fix that looks
finished is the one that has only been checked at the layer it was written in.

## Evidence

- **Baseline, measured on the same commit** in a detached worktree with its own `derivedDataPath`:
  **1268 tests in 155 suites**, 0 failures.
- **With the diff, cold** from a deleted `derivedDataPath`: **1288 in 159**, 0 failures, then three
  more green runs. The three warnings in the cold log are `appintentsmetadataprocessor` and a
  deprecated `SKPaymentTransactionState` inside Apple's own `StoreKitTest` header; **no warning
  names a file this phase touched**, and the baseline carries the same three.
- **The fixes are pinned, not asserted.** Reverting C, D and B and re-running made **7 of the new
  tests fail** — including the literal defect: a `.limited` scanner reporting a whole-library count
  of 3 where one photo is shared. The tree was then restored and `diff`ed byte-identically against
  the pre-revert patch.

## What is still untested, said plainly

**A and E are view-level and have no test.** `BackfillGrantChange` pins the *decision* A turns
on — which is the part that was actually wrong — but nothing asserts that `BackfillFlowView`
calls it, that `BackfillLimitedAccessScreen` renders its widen button, or that the month grid
renders its notice. Three independent `nil`-gates decide whether E appears and none is asserted.
This suite has no view host and acquiring one is not this phase's scope.

**Defect B's walk is untested against a real library.** `openLibraryRuns` pins the guard's polarity
so `canScan` cannot be silently inverted, but the walk itself finds nothing in a simulator.

Both belong to `docs/Device-Verification/device-verification-backfill.md`, whose 23 boxes are still
unticked and whose first line — *"Nothing in this feature has met a real camera roll"* — remains
the most important sentence about this feature.

---

# Rounds 4–7, and what the whole exercise actually found

Seven review rounds. **Rounds 1–6 each found a real defect; round 7 came back empty and that is where
this stopped.** Rounds 2–6 each found a defect *introduced by the previous round's fix*.

That reads like thrash, and it was not. **Every one of the six was the same error at a different
layer: an invalidation keyed on something narrower than the thing it governs.** Each round could
only see the layer the previous fix had just made reachable.

| Round | The key that was too narrow | What the parent saw |
|---|---|---|
| 1 | the scene phase (`previous == .background`) | the Settings round-trip dead-ended; the fix was inert |
| 2 | `stage`, re-derived from the grant alone | ejected back to the limited interstitial on every foreground |
| 3 | the loader generation, bumped unconditionally | an open month blanked to a spinner on every foreground |
| 4 | a **count** (`scanner.months`) | a selection swap was invisible; an entry write tore the grid down |
| 5 | an **id** (`fresh.map(\.id)`) | a downloaded photo kept its iCloud badge; a date edit reached `occurred_at` |
| 6 | a **grant** (`.limited` only) | full access had no invalidation at all, so a date edit reached `occurred_at` |

Round 4 also found one defect **older than this phase**: `BackfillScanner.scanAndWait` awaited only
the task it started, and `scan` is cancel-and-replace on a scanner `RootView` and the flow share. So
another caller landing mid-await returned control with nothing written, and `route` settled
`stage = .empty` — *"You've written about every month that has photos"* over a full camera roll,
permanently. It now follows the replacement.

Round 6's three were the worst, because two of them reach `occurred_at` — the one error this whole
feature exists to prevent:

- **`effect` was scoped to `.limited`.** It reasoned about *selection* edits, which was the case in
  front of it rather than the general one. A date corrected in Photos and an original pulled down
  from iCloud happen under full access too. Now any `canScan` grant re-reads; only `.limited` also
  re-counts the month index, because under full access that is a forty-thousand-asset walk.
- **`BackfillThumbnail`'s `.task(id:)` carried the asset id and pixel size, not the generation.** The
  tile survived the very invalidation `revalidate()` triggers, drawing neither the photograph nor
  the iCloud badge while remaining selectable.
- **`selection.retain` was handed month-wide ids.** A photo whose date moved to another day stayed
  selected while the grid regrouped it, and `use()` filters by id across every day — so the entry
  would have been built from two days' dates and filed under the earlier one, breaking the one-day
  rule that makes `occurred_at` exact.

## Evidence

- **1298 tests in 159 suites, 0 failures**, cold from a deleted `derivedDataPath`, plus two more
  green runs. Baseline measured on the same commit in a detached worktree: **1268 in 155**.
- **Zero warnings naming any file this phase touched.** The cold log's only three are
  `appintentsmetadataprocessor` and a deprecated `SKPaymentTransactionState` inside Apple's own
  `StoreKitTest` header; the baseline carries the same three.
- **Every fix is pinned by a test that fails when it is reverted**, verified by actually reverting
  each one and re-running: rounds 1–3's fixes broke 7 tests, round 4's broke 4, round 5's broke 2,
  round 6's broke 1. The tree was restored byte-identically after each, checked with `diff` against
  the pre-revert patch.

## Known and unfixed, stated rather than buried

- **Under full access a month card's count can disagree with its photographs for up to 24 hours.**
  The `.rescan` branch refreshes the loader but not `scanner.months`, which the 24-hour cache has
  always governed. Round 7 raised this twice and both verifiers judged it pre-existing rather than
  introduced here — correctly — but it is a real bounded inconsistency and it is written down.
- **Nothing view-level is tested.** The scenePhase wiring, the widen affordance's rendering,
  `load()`'s cancellation guard and the tile's reload key are all view-body code, and this suite has
  no view host. `BackfillGrantChange` and `BackfillThumbnailLoader` exist as pure types precisely so
  the *decisions* can be asserted; their wiring cannot be.
- **`CaptionProbe`'s real library walk is untested** — a simulator has no camera roll.
- **None of this has met a real camera roll.** `docs/Device-Verification/device-verification-backfill.md`
  still has 23 unticked boxes and its first line is still the truest sentence about this feature.
