# Overnight Phase Loop — Run State

**Run started:** 2026-08-10 (overnight, unattended)
**Phases:** 14 → 15 → 16 → 17 → 18, stacked branches, five PRs, none merged.

Read this file first if you are resuming mid-run.

---

## Branch stack

| Ord | Phase | Branch | Base |
|-----|-------|--------|------|
| 1 | 14 — Push Notifications (client) | `phase-14/push-notifications` | `main` |
| 2 | 15 — Prompt Pool Durability | `phase-15/pool-durability` | `phase-14/push-notifications` |
| 3 | 16 — Video Audio Tracks | `phase-16/video-audio` | `phase-15/pool-durability` |
| 4 | 17 — Structured Extraction | `phase-17/extraction` | `phase-16/video-audio` |
| 5 | 18 — Camera-Roll Backfill | `phase-18/backfill` | `phase-17/extraction` |

---

## Current status

**Run complete.** All five phases attempted, five PRs open, nothing merged.

**Finished:** 2026-08-10. The morning report is `docs/phases/OVERNIGHT-REPORT.md` — read that
first; it is ordered by what gets expensive if left alone.

| Phase | PR | Status |
|---|---|---|
| 14 | #40 | Complete — but **cannot merge before PR #38** |
| 15 | #41 | Complete |
| 16 | #42 | Blocked at preflight — draft, docs only, no code |
| 17 | #43 | Blocked at preflight — draft, docs only, no code |
| 18 | #44 | Incomplete — engine built and tested, UI not — draft |

Branches are stacked, so **review and merge bottom-up**: 14 → 15 → 16 → 17 → 18.

---

## Preflight findings across all five phases (gathered up front)

These were checked before any code was written, because three of the five phases carry
hard preflight gates whose answers change what the run can deliver.

| Phase | Gate | Result |
|-------|------|--------|
| 14 | `POST /v1/devices`, `DELETE /v1/devices/{token}`, notify fields on `/me` are live | **Not on `main`.** Fully implemented in **open, unmerged PR #38** (`api/push-notifications`). Contract read from source, not inferred. See DECISIONS D-002. |
| 15 | `main` green, migrations clean | Pending — checked at phase start |
| 16 | `docs/device-verification-transcription.md` records a completed device run | **FAILS.** 0 of 45 checkboxes ticked; the document's own first line reads "Nothing in this feature has ever run." Hard gate, phase cannot start. |
| 17 | `PATCH /v1/entries/{id}` can write tags with `source = device_ai` | **FAILS.** `EntryUpdate.tags` is `list[str]` with no source field; only `PATCH /media/{id}/derived` writes `device_ai`, and it is media-scoped so it cannot serve a text-only entry. Hard gate. |
| 18 | No external gate | Clear |

---

## Phase log

### Phase 14 — Push Notifications (client)
- Status: **PR open** — https://github.com/travist6983/Project-Rascal/pull/40
- Branch: `phase-14/push-notifications` (off `main`)
- Tests: 588/60 → **619 tests / 70 suites**, green, 0 Swift warnings
- Certainty pass found 4 issues, incl. a missing `aps-environment` entitlement and a
  vacuously-passing "Not now" assertion. Both fixed.
- **Not mergeable before PR #38** (the server half) — see DECISIONS D-002.

### Phase 15 — Prompt Pool Durability
- Status: **PR open** — https://github.com/travist6983/Project-Rascal/pull/41
- Branch: `phase-15/pool-durability` (off `phase-14/push-notifications`)
- Tests: 339 → **363**, green, ruff clean
- Certainty pass found 3 issues, incl. migration 0001 iterating a mutable constant, which would
  have broken migrate-from-empty. Fixed.
- Dev archive pool health captured in the PR: 24 eligible questions → 24 days to first repeat.

### Phase 16 — Video Audio Tracks
- Status: **BLOCKED, draft PR open** — https://github.com/travist6983/Project-Rascal/pull/42
- Branch: `phase-16/video-audio` (off `phase-15/pool-durability`), docs only
- Gate: `docs/device-verification-transcription.md` records 0 of 45 boxes and no results.
  No implementation attempted.

### Phase 17 — Structured Extraction
- Status: **BLOCKED, draft PR open** — https://github.com/travist6983/Project-Rascal/pull/43
- Branch: `phase-17/extraction` (off `phase-16/video-audio`), docs only
- Gate: `PATCH /v1/entries/{id}` cannot write `source = device_ai`; `EntryUpdate.tags` is
  `list[str]` and `services/entries.py` hardcodes `"user"` at lines 432 and 659.
  The exact API change needed is written up in `docs/phases/phase-17-BLOCKED.md`.

### Phase 18 — Camera-Roll Backfill
- Status: in-progress — branch created, no code yet
- Branch: `phase-18/backfill` (off `phase-17/extraction`)
- **The run continued past two consecutive blocked phases deliberately** — see DECISIONS D-008.
