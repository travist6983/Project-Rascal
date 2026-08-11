# Phase 18 — remaining work (the UI)

> **Superseded on Aug 11, 2026. Kept for the record; do not build from it.**
>
> Two things in this plan were reversed against `docs/mobile-app-design-composer/`, deliberately
> and after being raised:
>
> - **Placement.** The suggestion does *not* live inside the composer. **+** opens an *Add to the
>   archive* sheet, and the camera roll is a browse entry point below a divider leading to its own
>   flow. This costs every entry one tap — see `docs/decisions.md`.
> - **Selection.** Not month-wide multi-select with three preselected. A selection is confined to
>   **one day** and nothing is preselected, so `occurred_at` is exact rather than the earliest of a
>   spread.
>
> What shipped, and what is still unverified, is in `phase-18-verification.md`.

**Branch:** `phase-18/backfill`, now based on `main` (was stacked on the blocked #42).
**Baseline on this branch:** 639 tests / 74 suites, 0 Swift warnings.
**Delivered:** 662 tests / 79 suites, 0 warnings measured cold.
**Decided (2026-08-11):** the suggestion lives **inside the composer**, reached by the existing
**+** button. See `docs/decisions.md`. ← *reversed the same day; see the note above.*

## What already exists — do not rebuild it

| Type | File | Gives you |
|---|---|---|
| `BackfillScanner` | `Backfill/BackfillScanner.swift` | `@MainActor @Observable`. `state: .idle/.scanning/.ready([BackfillCluster])/.unavailable`, `isLimitedLibrary`, `scan(entryDates:)`, `cancel()`, `dismiss(_:)` |
| `BackfillCluster` | `Backfill/BackfillScan.swift` | `month`, `assetCount`, `cloudOnlyCount` |
| `BackfillMonth` | `Backfill/BackfillDate.swift` | `label()`, `key`, `fallbackDate()` |
| `BackfillEntryPlan` | `Backfill/BackfillEntryPlan.swift` | resolves `occurredAt` + `occurredAtSource`, `isDateDefaulted`, `composerRequest(childId:)` |
| `PhotoLibraryBackfillSource` | `Backfill/BackfillScanner.swift` | the real PhotoKit source |

**The `occurred_at` rule and the never-an-assignment rule are done and tested.** Do not
reimplement either; call `BackfillEntryPlan`.

## The work

### 1. Wire the scanner into `RootView`
- Build one `BackfillScanner` alongside `transcription`/`thumbnails`. **One per process.**
- Feed it `entryDates` from the local store: `FetchDescriptor<Entry>` mapping `occurredAt`.
  Compare locally — never ask the server.
- Kick a scan on `.task` and on foreground, `force: false` so the cache does its job.

### 2. The composer row (`Composer/ComposerView.swift`)
Show **only** when `request.assignment == nil` (freeform — the **+** path) and the scanner has
at least one cluster. Absent entirely otherwise; a row that says "nothing to backfill" is noise.

- Copy: `"40 photos from October 2025, nothing logged."` Specific, factual.
- **No guilt.** Not "you've missed", no running tally of empty months. The no-guilt rule is not
  softened by this one being technically true.
- Visually distinct from a `PromptCard` — this is not a mission. Reuse `SettingsRow`'s quiet
  register rather than terracotta card styling.
- A dismiss affordance calling `scanner.dismiss(cluster.month)`.

### 3. The picker sheet
- Multi-select from that month's assets, default selection **3**
  (`BackfillEntryPlan.suggestedSelectionCount`). Not a hard cap.
- Needs a new `BackfillAssetSource` method to fetch *assets for one month* — the current protocol
  only returns dates. Add `assets(in: BackfillMonth)` returning identifiers + creation dates, and
  a thumbnail request path. **Keep the stub source in tests in step.**
- iCloud-only assets: show as unavailable rather than failing on load.

### 4. Prefill and save
- Build `BackfillEntryPlan(month:creationDates:)` from the selection.
- Show the resolved date with the existing **DatePill** before saving.
- **When `isDateDefaulted`, say so on screen** — a defaulted date that renders identically to a
  real one is the failure this feature exists to prevent.
- Load asset data through the existing `ImagePipeline`, stage via `MediaCoordinator.shared`, save
  through the existing composer path. **Entries drain before media** — standing rule.
- One entry per selection.

## Tests still owed
- A month with photos and no entries surfaces the row; a month with entries does not.
- The row is **absent** when `request.assignment != nil` (a served mission never shows it).
- Selecting assets produces one entry with several media and `assignment_id` nil.
- A defaulted date is visibly flagged.
- Dismissing from the composer persists across a relaunch.

Existing suites already cover clustering, dismissal, cancellation, limited access, and the
`occurred_at` rule including the timezone fixture.

## Then
Certainty pass → update `phase-18-verification.md` → Dynamic Type XXL screenshots + VoiceOver
audit (now possible, since there is UI) → flip PR #44 out of draft.
