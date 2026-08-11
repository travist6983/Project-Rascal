# Phase 17 — unblocked, and the plan

**Branch:** `phase-17/extraction`, now based on `main` (was stacked on the blocked #42).
**The gate is gone:** PR #45 merged. `POST /entries` and `PATCH /entries/{id}` accept
`{ name, source }` on `tags`, `source` defaulting to `user`. See `docs/api-contract.md`.
**SDK confirmed:** `FoundationModels.framework` is present in the iOS 26.4 simulator SDK, so
`@Generable` and `LanguageModelSession` compile. The app deploys to 18.6, so every touch point
needs `@available(iOS 26, *)` plus a runtime availability check — the same shape
`SpeechTranscription.swift` already uses for `SpeechAnalyzer`.

---

## Decided 2026-08-11: extract once, never re-run

The phase offered "track deleted tags, or do not offer re-running". **Chosen: do not re-run.**

Consequences, all deliberate:

- No tombstone store, and nothing can resurrect a tag the parent deleted — the failure the rule
  exists to prevent is impossible rather than defended against.
- An entry is extracted **at most once, ever**. Editing the body afterwards does not re-extract.
- **Two tests from the phase file are retired** and must not be written as specified:
  *"Re-running replaces `device_ai` tags and leaves `user` tags untouched"* and *"A hand-deleted
  `device_ai` tag does not return on re-run."* They are replaced by a single stronger assertion:
  **extraction never runs twice on the same entry.** Log this in the PR body under Judgment calls
  — it is a deviation from the phase file's test list, not an omission.
- Idempotence is then trivial: the second call is a no-op, so there is no sync churn.

---

## The work

### 1. `Extraction/ExtractedDetails.swift` — the `@Generable` struct
People (names mentioned), place (if stated), mood, tags (**bounded — 5**), one-line summary.
Write against `LanguageModelSession`; keep the call behind a provider protocol so a later
re-route to a different backend does not touch call sites.

### 2. `Extraction/ExtractionQueue.swift` — match `TranscriptionQueue`'s shape
**Read `TranscriptionQueue.swift` first and mirror it.** Availability gate, battery and thermal
posture, backlog handling. Extraction is genuinely deferrable — `isDiscretionary = false` applies
to uploads, not to this. **Do not add a second background-work mechanism.**

### 3. The rules, each with a test
- **Nothing is extracted from a sealed entry.** A sealed letter's contents leaking into tags that
  render on an unsealed surface is the highest-consequence defect available here. Explicit test
  against a sealed fixture; one of the two required break-the-code assertions.
- **`title` and `body` are byte-identical before and after.** The parent's words are the archive.
- Every tag written carries `source = "device_ai"`, via the shape #45 added.
- Availability false degrades silently — no error, no banner, no retry storm.
- Tag count bounded.
- An already-extracted entry is skipped (the never-re-run rule).

### 4. Persistence
Needs a per-entry "extracted" marker. **A new non-optional `@Model` property needs a default at
the declaration** — `var extractedAt: Date? = nil` (optional is safest), per `ios/CLAUDE.md` rule
6. Without it the store refuses to open and the app crashes on every launch with no way back in,
and nothing in the suite can catch it.

## Out of scope — unchanged
Extraction from transcripts. Photo captioning. Any model-authored prompt, mission, or entry text.
Surfacing people or places as a browsable index. Timeline, Moments, Today, capture, `Sync/`, the
widget, the share extension, push.

## Then
Two break-the-code checks (sealed exclusion required) → certainty pass →
`phase-17-verification.md` → `docs/device-verification-extraction.md` (new; model availability
across real hardware, extraction quality against real entries, battery) → flip PR #43 out of draft
and retitle without `[BLOCKED]`.
