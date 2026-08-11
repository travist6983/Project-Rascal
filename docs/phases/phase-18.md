# Claude Code — iOS Phase 18: Camera-Roll Backfill

**Repo:** `travist6983/Project-Rascal`
**Branch:** `ios/phase-18-backfill`, **off `main`**
**Lane:** iOS only. **No `api/` changes** — freeform entries are already first-class.
**Run mode:** fully autonomous, unattended. Resolve ambiguity by matching existing code, record every such call in the PR under **Judgment calls**, and keep going.

---

## Mission

P3 item 3, and quietly one of the highest-value things left to build.

Scan the photo library for clusters in months with no entries, and surface them: *you have 40 photos from last October and nothing logged — pick three.* Nothing leaves the device until the parent chooses. This is only possible on native, and it is the thing that gives the archive a past.

There is a second effect worth naming. Moments returns `fallback: "random"` on every date and will for a year, because the archive is days old. Backfilled entries carry a historical `occurred_at`, which is the only mechanism that will ever make "one year ago" mean anything before next August.

---

## The architectural rule this phase must not break

**The server owns the schedule.** Settled, and the reason two phones and a future browser agree on what today is.

A backfill suggestion depends on what is in *this* phone's camera roll. The server cannot know that, so a backfill **is not an assignment**:

- It never occupies a `question`, `mission`, `weekly`, or `monthly` slot.
- It never creates an `assignments` row.
- It never looks like a served prompt in the UI.
- Entries it produces have `assignment_id` null — freeform entries are first-class and this is what that is for.

It is a client-side affordance, visually distinct from anything the server assigned. **If you find yourself minting an assignment on the device, stop** — that is the rule breaking, and it would put the client and server into disagreement about what was served.

---

## Preflight — hard stop

Any failure: stop, write `docs/blocked.md` with exact output, open a draft PR, do not proceed.

1. `main` green, working tree clean.
2. **The iOS workflow is dispatch-only** since PR #33. Run the suite locally, cold, from a deleted `DerivedData`, with `CODE_SIGNING_ALLOWED=NO`. Record test and suite counts. Do not carry a number forward.
3. Baseline builds with **zero warnings**. An incremental build under-reports warnings.
4. Read `docs/decisions.md` in full.
5. Read the share extension's staging and drain path, and the existing capture pipeline — HEIC→JPEG, EXIF handling, `MediaCoordinator`, `EntrySync.sweep()`. **You are reusing all of it.**
6. Read how the share sheet derives `occurred_at` from capture metadata. **The same rule governs here**, and this phase has far more opportunity to get it wrong.
7. Confirm `MediaCoordinator.shared` remains the single process-wide instance. It is a global by architectural necessity — do not create a second and do not attempt to inject it.

---

## Phase A — The scan

PhotoKit, entirely on device.

- Find months with photos but no entries. Compare against local entry data, not by asking the server.
- **Incremental and cancellable.** A library with 40,000 assets must not block the app, must not run on the main thread, and must survive being interrupted.
- Cache results. Re-scanning the whole library on every launch is not acceptable.
- **Handle limited photo library access.** iOS lets a parent grant access to selected photos only. That is a legitimate state, not an error — scan what you can see and say what you are seeing.
- **Handle assets not downloaded from iCloud.** Do not force downloads, do not stall on them, and do not present an asset you cannot actually read as available.
- Never upload, never transmit, never log asset content. Nothing leaves the device until the parent picks something.

---

## Phase B — The suggestion

Surface a cluster as an invitation, in the register the rest of the app uses.

- Specific and factual: the month, the count. *"40 photos from October 2025, nothing logged."*
- **No guilt.** Not "you've missed," not "don't forget," not a count of empty months as a running tally. A parent who never touches this must never feel worse for it. The no-guilt rule is not softened by the fact that this one is technically true.
- Dismissible, and a dismissed month stays dismissed.
- Visually distinct from a served prompt. It is not a mission and must not read as one.
- Where it lives — Today's lower region, Moments, or its own entry point — follows the existing design vocabulary. Pick one, justify it in `docs/decisions.md`, and **do not invent a new screen**.

---

## Phase C — Picking and saving

- Multi-select from the cluster, with a small default. *"Pick three"* is the framing; three is not a hard limit, but a parent selecting forty photos into one entry is a failure of the interaction.
- Composer prefilled with the media, an optional note, and the resolved date.
- **`occurred_at` comes from the asset's creation date. Always.** A backfilled photo belongs to the year it happened. Defaulting to now would file 2019 under this week, the entry would look completely normal, and it would be wrong permanently — the one error class this whole feature exists to fix.
- Show the resolved date before saving, using the existing DatePill vocabulary.
- Missing or clearly invalid metadata falls back to the month being backfilled, never to today, and the fallback is visible.
- One entry per selection, matching the share sheet's one-entry-per-share rule.
- Saving goes through the existing pipeline. Entries drain before media — standing rule, and it exists to prevent 404s on upload-url calls.

---

## Explicitly out of scope

- Any `api/` change or schema migration.
- Creating assignments on the device, under any framing.
- Face recognition, people clustering, or any grouping beyond time.
- Automatic import of anything. Every entry is a deliberate choice.
- Structured extraction or captioning over backfilled media — separate phases.
- Video backfill, unless it falls out of the existing pipeline for free. If it does not, cut it and say so.
- Timeline, Moments, Today, `Sync/`, the widget, the share extension, push — beyond the one surface the suggestion lives on.

---

## Tests

- A month with photos and no entries is detected; a month with entries is not offered.
- **`occurred_at` resolves from the asset's creation date**, asserted with a timezone fixture where the local date and the asset date differ.
- Missing metadata falls back to the backfilled month, never to today.
- A dismissed month is not re-offered.
- Limited photo library authorization produces a working, honest scan rather than an error.
- An iCloud asset not present on device is handled without stalling.
- The scan is cancellable mid-run and leaves no partial state.
- **No `assignments` row is ever created by this path** — assert it directly.
- A multi-select produces one entry with several media.
- A large library fixture scans without blocking the main thread — assert it, do not eyeball it.

**Assertions over implementations.** If a test fails and the code disagrees, assume the assertion is right, stop, and report both sides.

**Verify at least two assertions by breaking the code.** The `occurred_at` assertion is a required one of the two — it is the defect this feature exists to prevent, and it is invisible once shipped.

**Any test that waits must poll for a condition, never sleep a fixed interval.**

---

## Phase D — Adversarial re-read

A distinct pass after the build is green, reported whether or not it finds anything. It has caught real defects in two phases now. Look for unreachable branches, anything behaving differently under a real `URLSession` than a stub, failures that become terminal and silent, and any path where an asset's date could be replaced by the current date.

---

## Accessibility hook

Dynamic Type **XXL** screenshots of the suggestion, the picker, and the prefilled composer, nothing clipped, plus a VoiceOver audit — the suggestion must read as an invitation, not as a warning. State which artifacts you generated versus assumed.

---

## Docs

- `docs/decisions.md`: backfill-is-not-an-assignment and why, where the suggestion lives, the `occurred_at` fallback rule, and dismissal persistence.
- `docs/roadmap-status.md`: what landed, and **rewrite the "Recommended next phase" section rather than leaving it.**
- `docs/device-verification-backfill.md`: new, and the sharpest questions in it are about a real camera roll — photos with edited metadata, missing `DateTimeOriginal`, iCloud-only assets, and scan performance against a library with years in it. A simulator's photo library answers none of that.

---

## Done when

- [ ] Suite green locally, cold from a deleted `DerivedData`, zero warnings, count grown, no existing test modified
- [ ] Two assertions verified by breaking the code, one of them `occurred_at`
- [ ] No assignment is created by any path in this phase
- [ ] Adversarial re-read performed and reported
- [ ] Dynamic Type XXL screenshots and VoiceOver audit attached
- [ ] Docs and the new device checklist written
- [ ] PR opened against `main`

PR must include: what shipped, **Judgment calls**, **Blocked**, test counts before and after with the command used, **verification honesty** — scan performance and metadata edge cases cannot be assessed against a simulator library, so be explicit — and a ranked list of what you are least confident about, ordered by what would hurt most if wrong.
