# Story 3a — report

**BUILT as phase 36.** Migration `0014_families_and_invites`, five routes, per-guardian daily
assignment. 696 tests pass. PR open, not merged.

**This supersedes an earlier version of this file that halted the story.** The halt was wrong,
and the reason it was wrong is worth keeping: the runbook says *no story merges its own PR*, so
the owner reviews every judgment call before it reaches production. Treating four decisions as
needing sign-off **before** writing code turned a review gate into a permission gate and produced
nothing to review. The decisions are made below, in the diff, and reversible.

---

## Gate 4 — THE BACKFILL SAFETY CHECK — **PASS**, against production

Run against `rascal-api` production (Neon) via `fly ssh console`, not the local fixture — local
would have answered 0 too and proved nothing, because the migration does not run there.

```
SELECT child_id, count(*) FROM guardians WHERE revoked_at IS NULL GROUP BY child_id HAVING count(*) > 1;

GATE4_ROWS: 0
```

Production at the moment this ran (Aug 16, 2026, ~22:2x ET): **1 user, 2 children, 2 active
guardians, 25 assignments, 27 live entries**, alembic head `0013_email_sign_in`.

Two guardian rows for two children is one guardian each. **The backfill window was open and the
evidence is recorded because it stops being derivable the day a second guardian exists.**

## The other gates

- **Gate 1 — phase 36**, read from `docs/roadmap-status.md:479`: *"Guardian invite flow | ○ new,
  Aug 15, 2026 … Different need, different consumer, **deliberately still live**."* **No new number
  was taken.** "Take the next free number" is the wrong rule for work that already has one — 61
  would have orphaned a merged spec. The `entitlements` table is pulled forward from **37** and the
  migration docstring says so, so 37 does not get filed as done.
- **Gate 2 — no `config.py` conflict.** Story 1 halted with no code and no PR, so the surface this
  gate protects is empty. This story turned out not to touch `config.py` at all.
- **Gate 3 — not already landed.** `families`, `entitlements`, `guardian_invites` were all absent.
- **Gate 5 — idempotency survives, and here is exactly how.** The shared-slot index
  (`weekly`, `monthly`, `letter`) **does not include `user_id` at all**, so
  `uq_assignments_child_id_assigned_on_slot`'s guarantee is preserved unchanged for every row that
  kept the old shape. The daily index adds `user_id` to rows where it is NOT NULL, so no
  NULL-distinctness hole opens. The failure mode this avoids is in break-test 1 below.
- **Gate 6 — no config value added**, so nothing can be required at import.

## The four decisions, and where each came from

`decisions.md` open item 11 says its three collisions each need an answer *before anything is
built*. These are those answers.

| # | Decision | Why |
|---|---|---|
| 1 | **Cooldown per parent** | Item 11(c) argues it in its own words: *"two people answering the same question differently is arguably the feature being asked for"*, and names the alternative's cost — per-child, 113 prompts repeat near day 15 instead of day 31 |
| 2 | **Daily slots per parent; `weekly`/`monthly`/`letter` one per child** | Answers 11(b) by restating the completion model rather than extending it. A *measurement* mission firing twice in a month because two people were served it is a data defect, not a duplicate prompt |
| 3 | **`entitlements` now, not in 37** | The gate needs a tier to read, so 36 cannot ship without the table. **Nothing writes `tier`** — D5 reserves that for App Store Server Notifications V2 — and the migration docstring, the model docstring and `runbook-deploy.md` §7a all say so |
| 4 | **Free tier gets no second guardian** | D4: the second guardian is what "one price for the whole household" is sold on. `402 subscription_required`, and the copy names what subscribing unlocks rather than what free lacks |

**All four are reversible in the diff**, which is what makes deciding them here rather than waiting
the right call. If any is wrong, say which and it changes.

## Owner errand this creates

`runbook-deploy.md` **§7a**. Every family defaults to `free`, so **you cannot invite your wife until
your own household is marked subscribed**:

```sql
UPDATE entitlements SET tier = 'subscribed'
WHERE family_id = (SELECT family_id FROM users WHERE email = '<your email>');
```

Documented rather than a config flag on purpose: a `DISABLE_ENTITLEMENT_GATE` var is dead code that
never gets exercised, and it means the first person to hit the paywall is a customer rather than
you. Note the private-relay caveat in §7a if you signed in with Apple and hid your address.

## Break-tests — run, not asserted

1. **The NULL-distinctness trap.** Added `user_id` to `uq_assignments_shared`, so it became the one
   wide index the design rejects. `test_a_shared_slot_is_still_one_per_child_and_day` **failed** —
   the second `weekly` row for one child on one day was accepted with no error, because every
   shared row has a NULL `user_id` and NULL never equals NULL. This is the defect that would have
   shipped silently, on the slots nobody checks daily.
2. **Partial-index inference.** Removed `index_where` from the daily `ON CONFLICT`.
   `test_a_rerun_with_two_guardians_creates_nothing` **failed** with exactly
   `psycopg.errors.InvalidColumnReference: there is no unique or exclusion constraint matching the
   ON CONFLICT specification` — Postgres will not infer a partial index from the column list alone.
3. **The entitlement gate.** Made the tier check always pass. **Three tests failed**, including
   `test_a_free_household_cannot_invite_a_second_parent`.

Each break was reverted and the suite re-run green.

## One assertion was rewritten. It is the only one.

`test_assignments_are_unique_per_child_day_and_slot` pinned
`uq_assignments_child_id_assigned_on_slot`, which this phase replaces. **The behaviour changed
first, for a stated reason, and the test was rewritten to pin what replaced it** — not relaxed to
pass. It is now three tests: the daily key including the guardian, two guardians *not* colliding,
and the shared key still refusing a duplicate. A fourth covers the CHECK in both wrong directions.

## What ran

- `uv run pytest -q` → **696 passed, 2 failed**. Both failures are `test_restore.py` and are **this
  machine, not this code**: Homebrew's `pg_dump` is 17.6, the server is 16.14, and a 17 client
  writes `transaction_timeout` into the dump. **Verified pre-existing** by stashing this entire
  branch and re-running them — identical failures.
- `alembic upgrade head` against the dev database **with 34 assignments in it**: 26 daily rows
  attributed, 8 shared rows left NULL, both partial indexes created.
- `alembic downgrade -1` then `upgrade head` again, **with data present**: the old unique constraint
  came back, all 34 assignments survived, and re-upgrading re-applied cleanly.
- `alembic upgrade head` against a **fresh empty database** — the production path — 21 tables, head
  correct.
- `ruff check` and `ruff format --check` clean across `src/` and `tests/`.
- Route registration confirmed from the OpenAPI spec: 46 paths, all five new ones present.

## What was reasoned about, not run

- **The migration has not run against production.** It ran against a dev database with 34
  assignments and against a fresh one. Production has 25 assignments and the same shape, and gate 4
  proved the sole-guardian assumption holds there — but the statement itself has not executed there.
- **No second guardian has ever accepted an invite on a real device.** The flow is tested end to end
  in pytest; nobody has tapped a real link.
- The 402 copy follows the product's tone rules, which is a judgment about words, not a test result.

## Deliberately out of scope

- **StoreKit, App Store Server Notifications V2, any writer of `tier`** — phase 37.
- `storage_tier`, lifecycle notices, deletion clocks — phase 38.
- `entitlements.last_sign_in_at` — a denormalisation of `users.last_sign_in_at` that would drift.
- **The `viewer` role.** Phase 30 stays iceboxed. The column and CHECK can hold `viewer` because a
  migration to widen a CHECK later is pure cost, but `constants.ISSUABLE_INVITE_ROLES` is `("parent",)`
  and the route returns 422 for anything else.
- Apple Family Sharing — D4 records why.
- Anything in `ios/` — that is story 3b, which can now build against a real contract.
- **Sending the invite email.** `email` is recorded and nothing sends it; the client delivers the link.
- **Removing a guardian** — genuinely undecided, and filed as `decisions.md` open item 13.

## For story 7

- **Un-iceboxing is not required.** 36 was never iced; 30 was, and stays.
- **This restores D4's consumer.** "One price for the whole household" now has the thing it is sold
  on, which it did not while 36 was unbuilt.
- Phase 36's stated dependency — Google sign-in, so an invitee without an Apple device can accept —
  **is satisfied**: `services/google.py` shipped in the auth bundle.
