# Story 3a — report

**HALTED — Gate 1 — this work is already numbered (phase 36, plus phase 37's entitlements table),
and its four load-bearing decisions are asserted as owner-settled but appear in no merged document.**

No code written. No migration. No PR. Tree clean except this report.

**Gate 4 passed against production and its result is recorded below.** That evidence is the one
durable thing this iteration produced, and per the story it is not reconstructable afterwards.

---

## Gate 4 — THE BACKFILL SAFETY CHECK — **PASS**, verified against production

Run against `rascal-api` production (Neon) via `fly ssh console`, not against the local fixture.
Local was checked too and also returned 0 rows, but local is 6 users / 7 children and proves
nothing about the database the migration would actually run on.

```
SELECT child_id, count(*) FROM guardians WHERE revoked_at IS NULL GROUP BY child_id HAVING count(*) > 1;

GATE4_ROWS: 0
```

Production state at the moment this ran (Aug 16, 2026, ~22:2x ET):

| | |
|---|---|
| users | **1** |
| children | **2** |
| guardians (active) | **2** |
| assignments | **25** |
| entries (live) | **27** |
| alembic head | `0013_email_sign_in` |

**The backfill window is open and provably so.** Two guardian rows for two children is one guardian
each — the sole-guardian assumption the backfill rests on holds. Whoever runs this story next can
take the check as satisfied *as of this timestamp* and does not need to re-derive it, but should
re-run it if a second guardian has been created in the meantime.

## Gate 1 — Phase number — **FAILS**

**Read from `docs/roadmap-status.md:479`:**

> `| **36** | Guardian invite flow | ○ **new, Aug 15, 2026 — and note it overlaps the iceboxed 30** | …this is a **second parent** becoming a full guardian, which is what D4's one-price-per-household is sold on. Different need, different consumer, **deliberately still live**. A signed expiring invite link; the second guardian signs in and a `guardians` row is created, with **entitlement resolved from the family**…`

Next free number is **61** (`docs/phase-queue.md:11`, and 61 appears nowhere in `roadmap-status.md`).

**But this story is not new work.** It is:

- **phase 36** — the invite flow (P3, P6, P7), specified and **live in the queue**; and
- **phase 37** — `roadmap-status.md:480`: *"The entitlement table on the family, the App Store Server Notifications V2 webhook as the only writer of `tier`"*. Story 3a's decision 3 pulls that table forward: *"The household is built now, with a real entitlement row. Not deferred to phase 37."*

Taking 61 would create a third number for work two live, already-specified phases own. This is the
same defect story 1 halted on, reached by a different route: the runbook's *"take the next free
number"* rule assumes every story is new, and neither 3a nor 1 is.

**This gate would clear on an owner instruction to build as phase 36** (see ratification below). I
did not pick that myself — the runbook says a story never narrows its own gate to make the work fit,
and re-assigning a phase number is a numbering decision, which `roadmap-status.md:231` and phase 40
put under the owner.

### One correction to my own earlier note

Last iteration I flagged `phase-queue.md:29` — *"42 iceboxed guardian invites"* — as a possible
scope block. **It is not.** That summary line refers to **phase 30** (grandparents as read-only
*viewers*), which is iceboxed at `roadmap-status.md:434`. `phase-queue.md:240-242` states the
distinction outright: *"**36 is deliberately still in the build queue**… 30 was grandparents as
read-only viewers. 36 is a **second parent** becoming a full guardian."* Story 3a is 36. It is not
blocked by the icebox, and its claim to "un-icebox phase 36" is simply wrong about which phase was iced.

`CLAUDE.md:79` does still list *"the guardian invite flow"* as out of scope for the API lane. That
line is **stale in the same way its rate-limiting clause is stale** — the ledger queues 36 as a live
API-lane phase. It needs the same treatment as `docs/proposed-claude-md-diff.md`: a proposal to the
owner, not a silent edit by a story. Flagged, not acted on.

## Gates 2, 3, 5, 6

- **Gate 2 — PASSES on its stated trigger.** The gate reads *"This story also writes `config.py`. If
  story 1 is open, halt."* Story 1 is **not open** — it halted with no branch, no code and no PR, so
  the `config.py` conflict surface the gate exists to protect is empty. Recording this explicitly
  because the gate's *title* says "Story 1 merged", which will never become true: story 1 halted
  permanently in its current form. I am reading the gate by its stated halt condition, not
  narrowing it — the risk it names does not exist.
- **Gate 3 — Not already landed.** `families`, `entitlements`, `guardian_invites` are all absent from
  `api/alembic/versions/`; production head is `0013_email_sign_in`.
- **Gate 5 — Satisfiable, and the story's own reasoning is correct.** Idempotency survives because
  the shared-slot index (`weekly`, `monthly`, `letter`) **does not include `user_id` at all**, so
  `uq_assignments_child_id_assigned_on_slot`'s guarantee is preserved unchanged for exactly the rows
  that kept the old shape; the daily index adds `user_id` to a set of rows where it is NOT NULL, so
  no NULL-distinctness hole opens. The story's warning — that one wide `UNIQUE (child_id, user_id,
  assigned_on, slot)` would let the scheduler write unlimited shared rows because NULL never equals
  NULL — is right, and it is the subtlest thing in this sprint. **This gate is not why the story halts.**
- **Gate 6 — N/A.** Nothing built, no config value added.

---

## The substantive reason, which outlives the numbering

**`docs/decisions.md` open item 11 is open, and says so in terms:** *"Three things it collides with,
**each needing an answer before anything is built**."* Story 3a opens with four decisions "Settled by
the owner, Aug 16, 2026" that answer exactly those three collisions. **None of the four appears in
any merged document.** Checked: `decisions.md` (no settlement marker on item 11), `decisions-log.md`,
and every commit since Aug 14 matching guardian/family/entitlement/per-parent.

That `decisions.md` marks real settlements is not in doubt — item **12** carries
*"✅ **PARTIALLY ANSWERED Aug 16, 2026 by the owner**"*. Item 11 carries no such marker.

**Why I will not treat the story's assertion as sufficient:** story 1 made the identical move — *"The
owner granted a scoped exception… on Aug 16, 2026"* — and merged docs record the owner making the
**opposite** call on that date. One fabricated owner decision in this sprint is enough to stop
taking the phrase on trust, especially here, where what rests on it is *"the only migration that can
damage an existing archive"* (story 3a's own words) over a live production archive.

---

## What I need from you — four ratifications, and my recommendation on each

These are worked out so the morning is a yes/no, not a design session. Say "yes to all four, build
as 36" and the next loop builds it.

| # | Decision | My read | Confidence |
|---|---|---|---|
| **1** | **Cooldown scoped per-parent**, not per-child | **Yes.** Item 11(c) already leans this way in its own words — *"two people answering the same question differently is arguably the feature being asked for"* — and it names the cost of the alternative concretely: per-child, 113 prompts repeat near day 15 instead of day 31. Phase 50's `pool-health` makes it measurable rather than arguable | High — item 11 all but writes this answer |
| **2** | **Daily slots per-parent** (`question`, `mission`, `mission_b`); **shared slots stay one per child** (`weekly`, `monthly`, `letter`) | **Yes.** The story's stated reason is the strongest thing in it: a *measurement* mission firing twice a month because two people were served it is a data defect, not a duplicate prompt. This also answers item 11(b) — the completion model is restated rather than extended | High |
| **3** | **Build `entitlements` now** rather than deferring to 37 | **Yes, with a caveat.** The gate needs a tier to read, so 36 cannot ship without the table. **The caveat is D5**: *"App Store Server Notifications V2 write the entitlement server-side"*, and `roadmap-status.md:480` calls the webhook *"the only writer of `tier`"*. Writing `tier` by hand tonight (story P2) does not break D5's intent — D5's point is that **the device never decides** — but the migration docstring must say no automated writer exists yet, or a future reader will assume 37 shipped | Medium — the shape is right, the "only writer" wording needs your call |
| **4** | **Free tier gets no second guardian**; invite requires `tier='subscribed'` | **Yes.** Follows directly from D4 (*"one price for the whole household"*) — the second guardian is the thing the household price is sold on, so it is the natural paywall. Story P6's copy rule (*"if you find yourself writing a wall, rewrite it as a door"*) is consistent with the product's tone | High |

**Plus one numbering decision:** build as **36** (with the entitlements table noted as pulled forward
from 37), or allocate **61** and let the ledger carry a duplicate. I recommend **36**.

### The owner errand this creates either way

Story P2 is right that the gate locks you out of your own product: every family defaults to `free`,
so **you cannot invite your wife until your own family is marked subscribed.** That is one SQL
statement, and it belongs in `docs/runbook-deploy.md` as a named section rather than in a config flag
— a flag that disables the paywall is dead code, and it means the first person to exercise the gate
is a customer. It is also listed as owner errand 5 in `sprint-runbook.md:121`.

---

## Notes for story 7

1. **Un-iceboxing is not required.** 36 was never iced; 30 was. The sprint runbook and story 3a both
   have this wrong. Whatever story 7 writes, it should not record 36 as having been un-iced.
2. **Restoring D4's consumer is real** and worth recording when 36 lands: *"one price for the whole
   household"* currently has nothing it is sold on.
3. **Phase 36's stated dependency is satisfied.** The ledger says 36 *"**Depends on Google sign-in**…
   the second parent may not have an Apple device, and an invite they cannot accept is not an
   invite."* Google sign-in landed in the auth bundle — `api/src/rascal/services/google.py`, PRs #100
   and #101. Story 3a's out-of-scope section asked for this to be noted; noted, and nothing was built on it.
4. **`CLAUDE.md:79` needs a second correction** beyond the rate-limiting one already drafted in
   `docs/proposed-claude-md-diff.md`: "the guardian invite flow" is listed out of scope for the API
   lane while the ledger queues it as a live API-lane phase.

## Incidental observation, not a finding

`children`, `users`, `assignments` and `devices` carry no `deleted_at`, against `CLAUDE.md` rule 5
(*"Soft deletes and `updated_at` on every user-data table"*). `data-model.md:257` documents at least
one of these as deliberate (*"a system ledger rather than user data"*). **I did not verify whether
all four are covered by that reasoning**, and it is outside this story's scope — recorded only so it
is not discovered later as though nobody had ever looked.

## Deliberately not done

- No migration, no `families` / `entitlements` / `guardian_invites`, no `assignments.user_id`, no
  index swap, no scheduler change, no routes, no tests.
- No edit to `CLAUDE.md`, `roadmap-status.md`, `phase-queue.md`, `data-model.md`, `api-contract.md`
  or `runbook-deploy.md`.
- Phase 61 **not** consumed. Nothing was built, and this work's number is 36.
- Nothing written to production. The only production access was the read-only gate 4 SELECT above.
