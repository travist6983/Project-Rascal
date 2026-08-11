# Phase 18 — certainty pass

> "please go back through and anything you are not 100% sure about please make sure you are 100%
> certain about all of the code in this phase"

Run as its own pass after the suite was green. Every file was re-read top to bottom.

**This phase is incomplete, and that is the headline finding.** The scan, the clustering, the
dismissal store, the caching, and the `occurred_at` rule are built and tested. **Phases B and C —
the suggestion surface and the picker/composer prefill — were not built.** See the PR's "Not
included"; the honest statement is that this delivers the engine and not the screen.

---

## Findings that changed the code

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

## Assumptions confirmed against source, not memory

| Assumption | How it was confirmed |
|---|---|
| The share sheet's date rule falls back to `now` | Read `Share/PendingShare.swift`: `resolveOccurredAt` returns `(now, .shareTime)` when nothing carried a date. Correct there, catastrophic here — which is why this phase has its own rule rather than reusing that one. Both take the **earliest** usable date, which is the part that is shared. |
| Reading `PHAsset.creationDate` does not trigger an iCloud download | Only `PHFetchOptions` and `PHAssetResource` metadata are touched; no `PHImageManager` request is made anywhere in this phase, and that is what would pull bytes. |
| The scan does not block the main thread | The PhotoKit enumeration runs inside `Task.detached(priority: .utility)`. `BackfillScanner` is `@MainActor` only for publishing state. |
| Cancellation leaves no partial state | `state` is written only with a complete result; both post-await checkpoints return `.idle` instead. Asserted by cancelling mid-run and confirming no `.ready` is ever published. |
| Tests never sleep a fixed interval | The `until` helper yields in a bounded loop. No `Task.sleep` anywhere in the new tests. |
| Limited authorization is a working scan | `BackfillAuthorization.canScan` is true for `.limited`, `isLimitedLibrary` is published, and the scan proceeds. Asserted. |

## Things I could not confirm, stated plainly

- **No real camera roll was scanned.** Every scan assertion runs against a stub source of `Date`
  values. Performance against 40,000 assets, photos with edited metadata, missing
  `DateTimeOriginal`, and iCloud-only assets are all unmeasured — that is what
  `docs/device-verification-backfill.md` is for.
- **`PHAssetResource`'s `locallyAvailable` is read by KVC**, because there is no public API for
  it. It defaults to `true` when absent, so the failure mode is counting a cloud asset as
  on-device rather than the reverse. Unverified on a device.
- **The main-thread assertion is structural, not measured.** The phase asks for it to be asserted
  rather than eyeballed; what is asserted is that the work happens in a detached task, not a
  measurement under a real library.
- **No UI exists**, so the Dynamic Type and VoiceOver artifacts were not produced and are not
  claimed.
