# Phase 15 — certainty pass

> "please go back through and anything you are not 100% sure about please make sure you are 100%
> certain about all of the code in this phase"

Run as its own pass after the suite was green. Every file touched was re-read top to bottom.

---

## Findings that changed the code

### 1. Migration 0001 read a mutable constant, and this phase was the first to break it

**Assumed:** that adding `prompt_suppressions` to `TABLES_WITH_UPDATED_AT` was how the trigger
gets attached — that is what the constant is for and what `0001_initial.py` iterates.

**Checked:** read `0001_initial.py`. It does
`for table in TABLES_WITH_UPDATED_AT: CREATE TRIGGER … ON {table}`.

**Consequence:** a migration is a snapshot of one moment, and reading a live constant makes it a
snapshot of whatever the codebase looks like *now*. Adding the ninth table made revision 0001 try
to create a trigger on a table that does not exist until revision 0006 — so **migrating from
empty would have failed at 0001**, which is the one thing preflight #6 exists to check.

**Fixed:** froze 0001's list to the eight tables that revision actually creates, with the reason
written into the file, and attached the new trigger in 0006 where it belongs. Behaviour of 0001
is byte-identical for those eight.

### 2. Three separate copies of the schema expectation lists, not one

**Assumed:** that `tests/test_migrations.py` was the place to record the new table.

**Checked:** `tests/test_verify_schema.py` exists specifically to assert that
`.github/scripts/verify_schema.py` and `tests/test_migrations.py` agree, across **two** lists
each — `EXPECTED_TABLES` and `TABLES_WITH_UPDATED_AT_TRIGGER`. My first edit updated one list in
each file and the guard caught the mismatch immediately.

**Fixed:** all four lists updated. The guard test is doing exactly its job and is why this could
not be shipped half-done.

### 3. The new tests were invisible to the API because they never committed

**Assumed:** that `make_user`/`make_child` were enough to arrange a fixture for an HTTP test.

**Checked:** `conftest.py` gives the `session` fixture and the app's request session **separate
connections** on the same engine, so a flushed-but-uncommitted row is invisible across them. The
repo's convention is an explicit `await session.commit()` before touching `client`; every
existing HTTP test does it. Mine returned `401` because the user genuinely was not there yet.

**Fixed:** committed in every new HTTP test, matching the convention.

---

## Assumptions confirmed against source, not memory

| Assumption | How it was confirmed |
|---|---|
| Both callers share one selection path | Traced both: `run_scheduler` → `_fill_slot` → `select_prompt` → `_candidates`, and `GET /today` → `ensure_day_filled` → `_fill_slot` → the same. Asserted through both entry points against one fixture in `test_the_scheduler_and_the_read_path_exclude_identically`. |
| Suppression cannot be undone by any relaxation rung | Structural, not a filter: a suppressed prompt is excluded in `_candidates`, so it is absent from the list that ladder 6 (`candidates`, "anything at all") falls back to. Asserted with a fixture holding exactly one eligible prompt, suppressed. |
| The documented relaxation order is the implemented one | Read `choose_prompt` line by line. Ladders 1–4 all filter through `_eligible` (age + season) while the cooldown loosens; only ladder 5 drops the age window. **The code already matched `docs/data-model.md`, so no fix was needed** — this phase adds the test that fails on inversion, verified by actually inverting it. |
| `updated_at` is never set by application code | The suppression routes set `revoked_at` and `reason` only. `updated_at` comes from `trg_prompt_suppressions_set_updated_at`, created in 0006 and asserted by `test_migrations`. |
| The composite PK makes `POST` idempotent | `session.get(PromptSuppression, (child_id, prompt_id))` finds the existing row and revives it rather than inserting. Asserted: two identical POSTs, one row. |
| Truncation between tests covers the new table | `conftest._truncate` iterates `Base.metadata.sorted_tables`, so registering the model was sufficient — nothing to add. |
| The CLI's word matching does not fire on substrings | `\b`-anchored regex. Asserted directly: `treasurer` does not trip the `treasure` rule, because a flag list full of false positives is a flag list nobody reads. |
| Nothing in this phase generates prompts | The CLI reads, flags, and sets `active`. There is no generation path and no model call anywhere in it. |

## Things I could not confirm, stated plainly

- **No client calls the suppression endpoints.** Nothing in `ios/` uses them, deliberately —
  whether the client's single dismiss action should mean *not today* or *never again* is an open
  product question this phase does not answer.
- **The pool-health estimate is arithmetic, not a forecast.** It divides what is available today
  by the serve interval and assumes nothing more is suppressed and the age window does not widen.
  Both will happen. The field name carries the caveat.
- **The 79 pending candidates were never loaded.** The dev archive has none with
  `source = 'generated'`, so the CLI was exercised against unit fixtures and its flagging rules,
  not against the real batch.
