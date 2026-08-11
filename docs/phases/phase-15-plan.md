# Phase 15 — Prompt Pool Durability — plan

**Branch:** `phase-15/pool-durability`, stacked on `phase-14/push-notifications`
**Lane:** API only. Nothing under `ios/` is touched.

## Preflight results

| # | Check | Result |
|---|-------|--------|
| 1 | `main` green, tree clean | Yes |
| 2 | Suite counted | **339 tests across 28 files**, green |
| 3 | `docs/decisions.md` + `docs/mission-library.md` read | Yes |
| 4 | Scheduler candidate selection read end to end | Yes — recorded below |
| 5 | Phase 12 read path shares selection | **Confirmed** — see below |
| 6 | Migrations clean from empty | Verified against a scratch database |

> The suite fails 2 tests (`test_restore.py`) unless a **PostgreSQL 16** client is first on
> `PATH`. The Homebrew default here is 17, whose dump emits `transaction_timeout` and the PG16
> server rejects it. Pre-existing, environmental, unrelated to this phase. Baseline was taken
> with `PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"`, which is green at 339.

### What the scheduler does when the pool empties (preflight #4, recorded)

`choose_prompt` narrows through six ladders, strictest first, returning from the first
non-empty one:

1. in age window + season, 180-day cooldown, no theme from the last two days
2. in age window + season, **90-day cooldown**, theme rotation still on
3. in age window + season, 90-day cooldown, theme rotation dropped
4. in age window + season, **no cooldown at all**
5. **season only** — the age window relaxes here
6. anything in the pool

`None` only if the pool is empty outright, which logs `no eligible prompt` and leaves the slot
empty rather than inventing one.

### Phase C answered before it was started

**The documented order is already the implemented order.** `docs/data-model.md` says the
180-day cooldown relaxes to 90 *before* the age window gives, and ladders 2–4 exhaust the
cooldown while every one of them still filters on `_eligible` (age + season); only ladder 5
drops the age window. No fix is needed — this phase adds the test that fails if it is ever
inverted.

### Phase 12 read path (preflight #5)

`GET /today` → `ensure_day_filled` → `_fill_slot` → `select_prompt`, and the scheduler's
`run_scheduler` → `_fill_slot` → `select_prompt`. **Both callers funnel through
`select_prompt`, which is the only place candidates are loaded.** So suppression goes into
`_candidates`, the single SQL query behind it — which also makes suppression structurally
unable to be relaxed, because a suppressed prompt never enters the candidate list that ladder 6
falls back to.

## Files

| File | Change |
|------|--------|
| `models/prompt.py` | New `PromptSuppression` model. |
| `models/__init__.py` | Register it. |
| `alembic/versions/0006_prompt_suppressions.py` | New table. |
| `services/scheduler.py` | `_candidates` excludes suppressed prompts for the child. |
| `services/pool_health.py` | New — the computed report. |
| `routers/children.py` | Three suppression routes + `GET /pool-health`. |
| `schemas/prompt.py` | Suppression and pool-health bodies. |
| `scripts/review_candidates.py` | New — the batch-review CLI. |
| `tests/test_prompt_suppressions.py`, `tests/test_pool_health.py`, `tests/test_candidate_review_cli.py` | New. |
| `tests/test_scheduler.py` | Add the relaxation-order test. |

## Order of work

1. Model + migration, verified from empty.
2. `_candidates` exclusion — the one-place change.
3. Routes + schemas.
4. Pool health.
5. Relaxation-order test (Phase C).
6. Review CLI.
7. Break-the-code on the empty-pool suppression case.
8. Docs.
