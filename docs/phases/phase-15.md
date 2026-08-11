# Claude Code — Phase 15: Prompt Pool Durability (Lane A)

**Repo:** `travist6983/Project-Rascal`
**Branch:** `api/phase-15-pool-durability`, **off `main`**
**Lane:** API only. **No changes under `ios/`.** Runs safely in parallel with iOS work.
**Run mode:** fully autonomous, unattended. Resolve ambiguity by matching existing code, record every such call in the PR under **Judgment calls**, and keep going.

---

## Mission

The library holds 113 active prompts and the scheduler serves two a day. That arithmetic has a cliff in it, and two separate defects sit behind the cliff.

**Repeats.** Roughly 30 questions are eligible at 48 months. At one a day, the candidate pool empties in about a month, at which point the documented fallback relaxes the 180-day cooldown to 90. Nothing is broken — but the parent starts seeing prompts they answered last month, during exactly the sixty-day window P1 is meant to prove.

**Dismissal amnesia.** A dismissed prompt is excluded only by the same 180-day served-recently rule as any other. A prompt dismissed *because it does not fit this family* — a question about a mother in a household where that is painful, a mission that assumes an ability the child does not have — comes back. Forever, on a loop, for eighteen years.

The second is the one that matters. The first is a scheduling annoyance; the second is the app repeatedly asking a parent something they have already told it to stop asking.

---

## Preflight — hard stop

Any failure: stop, write `docs/blocked.md` with exact output, open a draft PR, do not proceed.

1. `main` green, working tree clean.
2. Run the API suite. Record exact starting test and file counts. Do not carry a number forward.
3. Read `docs/decisions.md` and `docs/mission-library.md` in full. **The library is the most valuable file in the project** — treat its tone rules as binding on anything this phase touches.
4. Read the scheduler's candidate selection end to end, including the cooldown relaxation path, and record in the run log exactly what it does when the pool empties.
5. Read the Phase 12 idempotent-on-read path. **Whatever this phase changes about selection must change in one place that both callers use.** A divergence between the scheduler and the read path would be nearly undetectable and would corrupt variety over years.
6. Confirm migrations run clean from empty against a scratch database.

---

## Phase A — Permanent suppression

New table: `prompt_suppressions` — `child_id`, `prompt_id`, `reason` (nullable), `created_at`, `revoked_at` (nullable, soft delete like everything else). Primary key `(child_id, prompt_id)`.

- The scheduler and the read path both exclude suppressed prompts **unconditionally**. Not on a cooldown, not with a relaxation escape — suppression outranks every relaxation rule including an empty pool.
- **`POST /v1/children/{id}/prompt-suppressions`** — body `{ prompt_id, reason? }`. Idempotent.
- **`DELETE /v1/children/{id}/prompt-suppressions/{prompt_id}`** — soft delete, so a parent can undo.
- **`GET /v1/children/{id}/prompt-suppressions`** — so a client can show what has been suppressed and offer to restore it. A permanent decision the parent cannot review is worse than no decision.

### The client question this phase does not answer

Dismissal today is one action. Whether "dismiss" should mean *not today* or *never again* is a client-side product decision, and this phase deliberately does not make it.

Build the server so both are expressible: dismissing an assignment continues to behave exactly as it does now, and suppression is a separate explicit call. **Write the open question into `docs/decisions.md` as unresolved** and note in the PR that no client currently calls the suppression endpoints.

---

## Phase B — Pool health, as a number

The cliff is invisible today. Make it observable before it arrives.

**`GET /v1/children/{id}/pool-health`** returning, per slot and per kind:

- Eligible prompt count at the child's current age
- Suppressed count
- Count already served within the cooldown
- **Estimated days until the first repeat** at the current serve rate
- Whether the cooldown relaxation is currently active, and which relaxation step

Rules:

- Computed, never cached. This is an admin-grade read, not a hot path.
- **Do not have it "fix" anything.** It reports; the scheduler decides.
- The estimate is an estimate. Say so in the field name or the contract, and do not present a projection as a fact.

---

## Phase C — Verify the documented fallback is the implemented one

`docs/data-model.md` states that when the candidate pool empties, the 180-day cooldown relaxes to 90 **before** the age window relaxes. Confirm the code does that, in that order.

If it does not, **fix the code to match the document, not the reverse** — the ordering is deliberate. A repeat is a mild annoyance; an age-inappropriate prompt served to a four-year-old is a broken product.

Add a test that fails if the order is ever inverted.

---

## Phase D — Getting the 79 candidates in

79 generated candidates are waiting on a human read. `POST /prompts/batch-review` exists in the contract.

- Provide a **CLI** that lists pending candidates in a readable form and accepts or rejects them in bulk from a file. Not a web UI — this is a solo admin task run occasionally from a terminal.
- Show each candidate against the tone rules from `docs/mission-library.md`, so a rejection is a judgment rather than a guess.
- **Flag automatically, reject never.** A candidate using *precious*, *cherish*, *treasure*, or *little moments*, or describing a feeling rather than an action, gets flagged for the human. The model does not get to reject its own peers, and it certainly does not get to approve them.
- **Nothing about this phase generates prompts.** Authoring stays server-side with a real model plus review — settled, and not up for reinterpretation.

---

## Explicitly out of scope

- Any `ios/` change.
- Generating new prompts, at request time or otherwise.
- Changing the weighted-random selection algorithm itself.
- Theme rotation changes.
- Expanding the library's content. That is a human writing task.
- Anything touching push, deploy, or the schema beyond the suppression table.

---

## Tests

- A suppressed prompt is never served, **including when the candidate pool is otherwise empty** — assert against a fixture with exactly one eligible prompt, suppressed.
- Suppression survives cooldown relaxation at every relaxation step.
- Un-suppressing restores eligibility.
- Suppression is per child, not global — asserted with two children.
- The scheduler and the Phase 12 read path exclude identically, asserted against the same fixture through both entry points.
- Cooldown relaxes before the age window, with a test that fails on inversion.
- Pool health reports a correct eligible count against a fixture with known suppression, cooldown, and age-window state.
- The review CLI flags a candidate containing a banned word and does not reject it.
- Migrations run clean from empty.

**Assertions over implementations.** If a test fails and the code disagrees, assume the assertion is right, stop, and report both sides. Do not edit an assertion to make a test pass.

**Verify at least two assertions by breaking the code.** The empty-pool suppression assertion is a required one of the two — it is the one that passes vacuously if suppression is checked in the wrong place.

---

## Docs

- `docs/api-contract.md`: the suppression routes and pool health.
- `docs/data-model.md`: the suppression table.
- `docs/decisions.md`: suppression outranks all relaxation, the unresolved dismiss-versus-suppress client question, and flag-never-reject on candidate review.
- `docs/roadmap-status.md`: what landed, and **rewrite the "Recommended next phase" section rather than leaving it.**

---

## Done when

- [ ] API suite green, zero warnings, count grown, no existing test modified
- [ ] Migrations run clean from empty
- [ ] Two assertions verified by breaking the code, one of them the empty-pool suppression case
- [ ] Selection logic still exists in exactly one place, used by both callers
- [ ] Docs updated
- [ ] Nothing under `ios/` touched
- [ ] PR opened against `main`

PR must include: what shipped, **Judgment calls**, **Blocked**, the pool-health numbers for the dev archive's child as they stand today, test counts before and after, **verification honesty**, and a ranked list of what you are least confident about.
