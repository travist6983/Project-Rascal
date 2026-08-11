# Phase 18 — certainty pass

> "please go back through and anything you are not 100% sure about please make sure you are 100%
> certain about all of the code in this phase"

Run as its own pass after the suite was green. Every file was re-read top to bottom.

**Aug 11, 2026 — the surface is now built, and the earlier headline is withdrawn.** The engine
findings below stand unchanged. What follows them is the pass over the UI.

**678 tests / 81 suites** after merging `main`, from a baseline of 639 / 74 — the surface added
23 in five suites, and phase 17's extraction arrived with 16 in two.

**Zero warnings in any file this phase touches**, measured from a deleted `DerivedData` — a warm
build reports zero on code that has plenty, which is how the engine pass recorded a clean baseline
that was not one. Twenty-one remain, all inherited and none of them fixed here: 14 in
`RascalTests/PushPermissionTests.swift` (phase 14), 4 in `RascalTests/ExtractionTests.swift` and
**3 in `Rascal/Extraction/ExtractedDetails.swift`** (phase 17 — that last set is in the *app*
target, not a test one). Named rather than absorbed into a "0 warnings" claim, and left to their
own lanes rather than fixed inside a backfill change.

**One conflict on the merge, and it was the one the phase brief warned about.** The composer
sheet's `onDismiss` already had two callers; phase 17 added `extractLatest()` and this phase added
a backfill rescan. Both are additive and both are kept, with the rescan first — it is
non-blocking, where extraction awaits an on-device model and can take seconds. Ordered the other
way, the **+** sheet would go on offering a month the parent has just written in for as long as
inference ran.

---

## Findings that changed the code — the engine

### 1. The month fallback would itself have been the bug it exists to prevent

**Assumed:** that falling back to "the 1st of the month" was sufficient.

**Checked:** wrote the timezone case out. Midnight on 2019-10-01 constructed in one zone and read
in a zone further west is **2019-09-30** — so a backfilled October entry would file under
September, silently, and only for parents who travel or whose device zone differs from the one
the date was built in.

**Fixed:** `BackfillMonth.fallbackDate` returns **midday** on the 1st, with the reason in the
comment, and `monthFallbackSurvivesTimezoneShift` asserts it against Honolulu.

### 2. "Clearly invalid metadata" needed a definition, not a feeling

**Assumed:** that "missing" metadata was the only bad case.

**Checked:** the phase says "missing **or clearly invalid**". A `creationDate` of epoch zero, or
one edited to a date years from the cluster it was grouped into, is present and useless. Without
a definition the code would trust it and file the entry somewhere nobody asked for.

**Fixed:** `isPlausible` defines invalid as *outside the month being backfilled* — the scan
grouped the asset into that month by its own date, so a date outside it did not come from the
grouping. Asserted with an epoch-zero fixture.

### 3. The no-assignment rule was a comment, and is now structural

**Assumed:** that documenting "never create an assignment" was enough.

**Checked:** the phase calls this the rule that must not break and asks for it to be asserted
directly. A comment is not an assertion.

**Fixed:** `BackfillEntryPlan` has **no field that can hold an assignment**, and
`composerRequest` passes `assignment: nil` as a literal rather than a parameter. The test asserts
both the nil and, via `Mirror`, that no such field exists — verified by adding one and watching
it fail.

---

## Findings that changed the code — the surface

### 4. At the accessibility text sizes, the permission screen had no reachable way to grant

**Assumed:** that a `VStack` of spacers in a full-height frame would compress gracefully.

**Checked:** captured it at accessibility XXL. The headline ran off the top under the status bar
and **both actions ran off the bottom entirely.** So the one screen whose whole job is asking for
photo access had no way to grant it, no way to decline it, and no way to scroll to either —
on a screen the parent reaches by asking for this feature.

**This is the worst defect in the phase.** iOS shows its permission prompt once. A parent at
XXL would have hit a dead end and the feature would simply never have worked for them, with
nothing on screen explaining why.

**Fixed:** `BackfillPermissionScreen` scrolls, and its actions live in a `safeAreaInset(edge:
.bottom)` that cannot be pushed anywhere. The same pattern was wrong in
`BackfillLimitedAccessScreen`, `BackfillNoAccessScreen` and `BackfillNothingToSuggestScreen` and
was fixed in all four. Re-captured to confirm.

### 5. A month heading broke inside the word

**Assumed:** that a month and its year side by side in an `HStack` would wrap sensibly.

**Checked:** at XXL, "October 2025" rendered as "**Octobe / r**" beside an untouched "2025" —
two layout boxes, so the month was squeezed to nothing while the year kept its width.

**Fixed:** concatenated into one `Text` in both `BackfillMonthCard` and the month picker's
header, so it wraps as the phrase it is. `String(year)` rather than interpolating the `Int`,
which a locale renders as "2,025".

### 6. A day was marked "Written" before anything had been written

**Assumed:** that the picker's `onUse` was a save.

**Checked:** it opens a composer. The composer dismisses on **Cancel** exactly as it does on
Save, so a parent who picked three photos, thought better of it, and swiped the sheet away came
back to a day badged "Written" with nothing behind it — the same class of lie as a completion
check on a prompt with no entry.

**Fixed:** `confirmWritten()` asks the local store whether an entry now exists in that day's range
and only then checks it off.

### 7. The limited-access screen could never leave the scanning state

**Assumed:** the stage machine was linear.

**Checked:** `decideStage` set `.limited` and *then* called `rescanIfNeeded`, which sets
`.scanning` and has no terminal stage to return to. Selected-photos access therefore hung on the
scanning screen permanently.

**Fixed:** scan first, settle the stage after.

### 8. The scan was being polled on the main actor

**Assumed:** `while scanner.state == .scanning { await Task.yield() }` was a cheap wait.

**Checked:** it is a spin loop on the main actor for the entire length of a scan — on the one
feature whose whole design constraint is staying cheap against a 40,000-asset library.

**Fixed:** `BackfillScanner.scanAndWait` awaits the task directly.

---

## Assumptions confirmed against source, not memory

| Assumption | How it was confirmed |
|---|---|
| The share sheet's date rule falls back to `now` | Read `Share/PendingShare.swift`: `resolveOccurredAt` returns `(now, .shareTime)` when nothing carried a date. Correct there, catastrophic here — which is why this phase has its own rule rather than reusing that one. Both take the **earliest** usable date, which is the part that is shared. |
| The composer cannot re-derive the date over the rule's answer | `ComposerView.init` sets `dateWasChosen` when a backfill prefill is present, which is the flag `adoptExifDateIfUnchosen` guards on. Without it, adding one more photo would hand `occurred_at` to `MediaDraftBuilder.suggestedOccurredAt`, whose fallback is today. Asserted at the request boundary. |
| Reading `PHAsset.creationDate` does not trigger an iCloud download | Only `PHFetchOptions` and `PHAssetResource` metadata are touched during the scan. |
| Nothing else downloads either | Both `PHImageManager` paths added this phase set `isNetworkAccessAllowed = false`. A cloud-only asset returns no thumbnail, is not selectable, and throws `notOnDevice` if bytes are asked for anyway. |
| The scan does not identify individual photos | `assets(in:)` is called only from the picker and the card strip, both behind a tap. Asserted: `fetchedMonths` is empty after a full scan. |
| The scan does not block the main thread | The PhotoKit enumeration runs inside `Task.detached(priority: .utility)`. `BackfillScanner` is `@MainActor` only for publishing state. |
| Cancellation leaves no partial state | `state` is written only with a complete result; both post-await checkpoints return `.idle` instead. Asserted by cancelling mid-run and confirming no `.ready` is ever published. |
| A cache written by the previous build still decodes | `BackfillScanResult.months` is optional. A non-optional field would fail the decode, which `load()` swallows as a cache miss — a full library rescan on the first launch after the update, for every user, silently. Asserted against a hand-written legacy payload. |
| Tests never sleep a fixed interval | The `until` helper yields in a bounded loop. The only `Task.sleep` added is the picker's self-clearing notice, in view code, not in a test. |
| Limited authorization is a working scan | `BackfillAuthorization.canScan` is true for `.limited`, `isLimitedLibrary` is published, and the scan proceeds. Asserted. |
| No new copy assumes the child's gender | The mockups say "He was 3 years, 4 months". Every age line written here uses `DraftAge.spoken` — "3 years, 4 months old". `CLAUDE.md` allows the *seeded library* to stay he/him and requires new copy not to be. |
| The age shown is not the archive's | `DraftAge`, explicitly the one client-side age calculation and explicitly not for the archive. A month with no entries has no server `child_age_months` to render, because no entry exists to carry one. Never stored, never sent; the server's own number replaces it the moment an entry is saved. |

## Things I could not confirm, stated plainly

- **No real camera roll was scanned.** Every assertion still runs against a stub source. The
  screenshots were taken against fabricated assets with no thumbnails, so they prove the
  *layout* and say nothing about the flow on a phone with years of photos on it.
  `docs/device-verification-backfill.md` is what closes this.
- **VoiceOver was audited in code, not heard.** Labels, traits, grouping and hints were read
  through on every new view — the offer row and the month rows combine into single elements, day
  headers carry `.isHeader`, tiles carry `.isSelected`, and a cloud-only tile has a hint saying
  why it cannot be picked. **No screen reader was actually run**, which needs a device.
- **`PHAssetResource`'s `locallyAvailable` is read by KVC**, because there is no public API for
  it. It defaults to `true` when absent, so the failure mode is counting a cloud asset as
  on-device rather than the reverse. Unverified on a device.
- **The one-day rule is asserted on the model, not through the UI.** `BackfillSelection` is unit
  tested; that the picker wires taps to it correctly is read, not proven.
- **Staging several full-size photos happens on tap, and its cost is unmeasured.** "Getting them
  ready…" is on the button, but how long that takes for ten 48MP HEICs is not known.
- **The extra tap on **+** is unmeasured.** The reversal in `docs/decisions.md` costs every entry
  in the app one tap. Whether that is the right trade is a product question this pass cannot
  answer, and it is the thing most worth watching after it ships.
