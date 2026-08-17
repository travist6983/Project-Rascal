# Story 3a — Guardians: the household, the invite, and per-parent assignment

**Lane:** `api/` only. **Runs:** after story 1 merges. **Read `sprint-runbook.md` before starting.**

The biggest story in this sprint, and the one carrying the only migration that can damage an
existing archive. Read the whole file before writing a line.

Two parents share one household, one subscription, one set of children, one timeline and one set of
moments. Their **settings are already separate** and their **Today boards become separate**. This
closes open question 11 in `docs/decisions.md` and un-iceboxes phase 36.

---

## Decisions this story implements — do not re-derive them

Settled by the owner, Aug 16, 2026:

1. **Prompt cooldown is scoped per-parent**, not per-child. Two parents may be served the same
   prompt on different days, and two people answering the same question differently is the feature,
   not a collision. They may drain the pool — just not on the same day.
2. **Daily slots are per-parent; larger slots stay shared.** `question`, `mission`, `mission_b` are
   served to each guardian individually. `weekly`, `monthly`, `letter` are one per child, and either
   guardian completing one clears it from both boards. A measurement mission must not fire twice in
   a month because two people were served it.
3. **The household is built now, with a real entitlement row.** Not deferred to phase 37.
4. **The free tier does not get a second guardian.** Inviting one requires `tier = 'subscribed'`.
   The invite surface is the upgrade surface.

Consequence worth recording: un-iceboxing 36 **restores D4's consumer.** "One price for the whole
household" now has the thing it is sold on. Note that in your report for story 7.

---

## Hard-stop preflight gates

**Gate 1 — Phase number.** As the runbook specifies. Read `roadmap-status.md`, take the next free
number, state the line you read it from.

**Gate 2 — Story 1 merged.** This story also writes `config.py`. If story 1 is open, halt.

**Gate 3 — Idempotency.** If `families`, `entitlements` and `guardian_invites` all exist in alembic
history and the invite routes are present, report `ALREADY LANDED` and exit 0.

**Gate 4 — THE BACKFILL SAFETY CHECK. This one is not a formality.**

Before writing the `assignments` migration, query production-shaped data:

```sql
SELECT child_id, count(*) FROM guardians
WHERE revoked_at IS NULL GROUP BY child_id HAVING count(*) > 1;
```

**If any row returns, HALT.** The backfill below assigns every existing daily assignment to the sole
guardian of its child. That is trivially correct while there is exactly one guardian and
*unrecoverably wrong* the moment there are two — it would silently attribute one parent's history to
the other. This is the cheap window and the check is what proves you are still inside it.

**Gate 5 — Read the idempotency claim before you change it.** `docs/data-model.md` states in terms
that `uq_assignments_child_id_assigned_on_slot` **is what makes the daily scheduler idempotent** —
the self-heal that lets a missed cron run recover on the next read. You are changing that index. If
you cannot articulate, in the report, exactly how idempotency survives the change, halt.

**Gate 6 — No secret required at import**, as story 1's gate 5.

---

## Implementation, in order. Do not reorder.

### P1 — `families` and `entitlements`

`families`: `id` uuid PK, `created_at`, `updated_at`.

`users`: add `family_id` uuid FK, nullable at first, then backfilled and set NOT NULL in the same
migration. **Backfill: one family per existing user.** There is one user; this is one row.

`entitlements`, exactly as specified in `docs/data-model.md`'s proposed section — do not invent a
different shape:

| Column | Type | Notes |
|---|---|---|
| `family_id` | uuid PK FK | one entitlement per family, never per user or child |
| `tier` | text NOT NULL default `free` | `free` \| `subscribed`, `text` + named CHECK |
| `payer_user_id` | uuid FK | nullable — a family can be `free` with nobody paying |
| `lapsed_at` | timestamptz | nullable; null while subscribed |
| `updated_at` | timestamptz | `set_updated_at()` trigger |

**Do not add `last_sign_in_at` to `entitlements`.** `data-model.md` describes it as a denormalisation
of `users.last_sign_in_at` that must never be written independently, and nothing reads it yet.
Adding a column whose only correct value is a `MAX` over another table, before anything computes
that `MAX`, is a column that will drift.

**Do not build StoreKit, the App Store Server Notifications webhook, or any tier writer.** That is
phase 37 and it is blocked on an owner account errand. `tier` is written by hand tonight and by
phase 37 later. Say so in the migration's docstring so nobody assumes a writer exists.

### P2 — The escape hatch, documented not hidden

The gate is live code and every family defaults to `free`, so **the owner cannot invite anyone until
his own family is marked subscribed.** Write this into `docs/runbook-deploy.md` as a named section:

```sql
UPDATE entitlements SET tier = 'subscribed'
WHERE family_id = (SELECT family_id FROM users WHERE email = '<owner email>');
```

A documented manual row is honest. A config flag that disables the gate is dead code that never gets
exercised, and it means the first person to hit the paywall is a customer.

### P3 — `guardian_invites`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `family_id` | uuid FK | the household being joined |
| `invited_by_user_id` | uuid FK | |
| `token_hash` | text | SHA-256. **Raw token never stored**, per `refresh_tokens` |
| `email` | text | nullable — an invite may be a bare link |
| `role` | text | `parent` \| `viewer`, `text` + named CHECK. **Only `parent` is issuable tonight** — `viewer` is phase 30 and stays iceboxed |
| `expires_at` | timestamptz | 7 days |
| `accepted_at` / `accepted_by_user_id` | | nullable |
| `revoked_at` | timestamptz | nullable |
| `created_at` / `updated_at` | | |

Index on `token_hash`.

### P4 — The `assignments` change. The dangerous one.

Add `assignments.user_id` uuid FK, **nullable**, and read carefully why:

- **Daily slots** (`question`, `mission`, `mission_b`): `user_id` is NOT NULL. One row per guardian.
- **Shared slots** (`weekly`, `monthly`, `letter`): `user_id` is NULL. One row per child.

Enforce with a CHECK constraint naming both cases explicitly. A nullable column with no constraint
is an invitation to write the wrong shape.

Replace the single unique index with **two partial unique indexes**:

```sql
CREATE UNIQUE INDEX uq_assignments_daily
  ON assignments (child_id, user_id, assigned_on, slot)
  WHERE slot IN ('question','mission','mission_b');

CREATE UNIQUE INDEX uq_assignments_shared
  ON assignments (child_id, assigned_on, slot)
  WHERE slot IN ('weekly','monthly','letter');
```

**Why partial indexes rather than one wider index:** Postgres treats NULLs as distinct in a unique
index. A single `UNIQUE (child_id, user_id, assigned_on, slot)` would let the scheduler create an
unlimited number of shared-slot rows for the same child and day, because every one of them has a
NULL `user_id` and NULL never equals NULL. Idempotency would fail silently, and it would fail on
exactly the slots — weekly and monthly — that are least likely to be noticed quickly. The partial
index on the shared slots does not include `user_id` at all, so it keeps the old guarantee intact
for the rows that kept the old shape.

Backfill, in the same migration:
- daily rows → the sole guardian of that child (gate 4 proved there is exactly one)
- shared rows → NULL

Then add the CHECK, then swap the indexes. **In that order.** Adding the constraint before the
backfill fails on existing rows.

### P5 — The scheduler

`assignments` creation becomes per-guardian for daily slots, unchanged for shared slots.

- Still **idempotent on read** — a missed hourly run self-heals on the next one. This property is
  the reason the index exists and it does not get to regress.
- Still filters on local time per the child's `family_timezone`. Unchanged.
- **Cooldown / recent-serve exclusion is now keyed on `(child_id, user_id)`** for daily slots, and
  stays `(child_id)` for shared slots. This is decision 1 above.
- Backfill entries must still **never** create assignment rows. Unchanged and re-verify it.

### P6 — Routes

- `GET /v1/families/me` → `{ family_id, tier, guardians: [{ user_id, display_name, role, granted_at }] }`
- `POST /v1/families/me/invites` → creates an invite, returns the **raw token once**.
  - **Gate: `tier` must be `subscribed`.** Otherwise `402` with a body naming the upgrade, not a bare
    error. This is a product surface; see the copy note below.
  - Also refuse if the family already has 2 active `parent` guardians. Two is the household.
- `GET /v1/invites/{token}` → unauthenticated preview: who invited you, which household, the
  children's first names. Enough to know the link is real, nothing more.
- `POST /v1/invites/{token}/accept` → authenticated. Sets `users.family_id`, creates a `guardians`
  row with `role='parent'` **for every child in the household**, marks the invite accepted.
  Idempotent: accepting twice is a no-op success.
- `DELETE /v1/invites/{id}` → revoke.

**The 402 body carries copy, and the copy follows the product's rules.** Frame the second guardian
as something the subscription unlocks, never as something the free tier is being punished for
lacking. No red, no urgency, no countdown. If you find yourself writing a wall, rewrite it as a door.

### P7 — Authorization

Every existing `child_access` check keeps working — a new `guardians` row is all it needs. **Verify
this rather than assuming it**, and name the check function and file in the report.

`role='viewer'` remains unissuable. Phase 30 is iceboxed and this story does not un-ice it.

### P8 — Contract and data model

Append the new routes to `docs/api-contract.md`. Update the `guardians`, `assignments` and `users`
sections of `docs/data-model.md`, and move `families` / `entitlements` out of the PROPOSED section
into the live tables. **Touch nothing else in either file.**

### P9 — Tests

Per-guardian daily creation; shared-slot single creation; scheduler idempotency under a double run
for both index shapes; the cooldown being per-parent; invite create/preview/accept/revoke; accept
idempotency; the 402 on a free family; the two-guardian cap; expired and revoked tokens.

---

## Break-test at least three assertions

This story earns a third.

1. **Scheduler idempotency on shared slots.** Change `uq_assignments_shared` to include `user_id`.
   Run the scheduler twice. A test must catch the duplicate weekly row. If nothing fails, the
   idempotency guarantee is not actually asserted anywhere and you must write that test — it is the
   single most important assertion in this story.
2. **The CHECK constraint.** Insert a `question` row with a NULL `user_id`, and a `weekly` row with a
   non-NULL one. Both must fail.
3. **The entitlement gate.** Set a test family to `free` and create an invite. Must be 402.

---

## Deliberately out of scope

- **StoreKit, the App Store Server Notifications V2 webhook, any writer of `tier`.** Phase 37.
- **`storage_tier` on media, lifecycle notices, win-back, deletion clocks.** Phase 38.
- **`entitlements.last_sign_in_at`** — see P1.
- **The `viewer` role and per-entry visibility.** Phase 30, iceboxed, and nothing here un-ices it.
- **Apple Family Sharing.** D4 records why: it creates a second, Apple-owned opinion about who is
  entitled. Do not reach for it.
- **Anything in `ios/`.** Story 3b.
- **Google sign-in.** If credential linking landed in the auth PR, note that in the report; do not
  build on it here.

## Report to

`docs/sprint-aug16/story-3a-report.md`, plus the PR description in the runbook's format. Include the
result of gate 4's query verbatim — the number of children with more than one guardian at the moment
this ran is the evidence that the backfill was safe, and it is not reconstructable afterwards.
