# Story 7 — Reconciliation

**Lane:** docs only, monorepo. **Runs: LAST.** After every other story has merged or halted.
**Read `sprint-runbook.md` before starting.**

Docs only. **No code, no migration, no test change.** This story exists because every phase in this
project writes to `roadmap-status.md` and `phase-queue.md`, and six agents appending to two files
overnight is how a night's work becomes six unmergeable branches. Those two files belong to this
story alone.

---

## Hard-stop preflight gates

**Gate 1 — Everything else is finished.** Stories 1, 2, 3a, 3b, 4, 5 and 6 must each have either a
merged PR or a report ending in `HALTED`. **If any story is still in flight, halt** and let the loop
come back to this one.

**Gate 2 — Read every report.** `docs/sprint-aug16/story-*-report.md`, all of them, in full, before
writing anything.

**Gate 3 — Report only what happened.** Every status claim you write carries the evidence that
proves it: a PR number, a command, a file path, a line number. **A shipped-status claim with no
command behind it is the exact failure this document set has caught six times.** If a report claims
something and the tree disagrees, the tree wins and you write down the discrepancy.

**Gate 4 — Do not tick a device-verification box.** Several stories will have *listed* new boxes.
File them as unticked, against the specific read or path they cover. A box an agent ticked is worth
nothing.

---

## What to write

### 1. Fix the phase numbering disagreement — first, before anything else

Right now `phase-queue.md` says the high-water mark is **47**, `data-model.md` references phase **49**
as shipped, and `decisions.md` references phase **50**'s `pool-health`. **Three files, three answers.**

Establish the real number from `roadmap-status.md`'s ledger, correct the other files to agree, and
**write down that they disagreed and for how long**. This is the second time the queue has drifted
from the roadmap; the first time a preflight gate caught it. A drift that gets silently corrected
teaches nothing.

### 2. `roadmap-status.md`

A ledger row per phase that shipped tonight, in the established voice: what shipped, what was
verified versus reasoned about, what deliberately did not ship and why. Include the halted stories
as rows too — a phase that hard-stopped on a gate is a result, and the gate that caught it is the
interesting part.

Update the device-verification counts. The denominator grows tonight; that is the honest direction
for it to move.

### 3. `phase-queue.md`

- **Delete** every line whose work landed. A queue carrying finished work is this file's stated
  failure mode.
- **Un-icebox 36.** Move it out of the Iceboxed section into the build queue or into the shipped
  ledger depending on what 3a and 3b actually did. Record the owner's reason in his own framing:
  he had been reading "guardian" as *grandparents* — which is phase 30, still iced — when what he
  wanted was a **second parent**. The two phases were separated on Aug 15 for exactly this reason
  and the distinction turned out to be the thing that was confusing.
- **30 stays iceboxed.** Grandparents as read-only viewers, and per-entry visibility with it.
  Nothing tonight un-ices it and nothing tonight needs unwinding.
- Add the follow-ups the night generated, one line each.

### 4. `decisions.md`

**Close open question 11** — "two parents on one child." Record all three answers and their reasoning:

- Cooldown is **per-parent**. Two parents may drain the pool, just not on the same day, and the same
  question answered differently by two people is the feature.
- Daily slots (`question`, `mission`, `mission_b`) are **per-parent**; `weekly`, `monthly` and
  `letter` stay **one per child**, either guardian completing them. A measurement mission must not
  fire twice a month.
- The idempotency guarantee survives via **two partial unique indexes**, and the reason it needed two
  rather than one — Postgres treats NULLs as distinct — is the part worth writing down, because it is
  the part that would silently break if someone later "simplified" it.

**Close open question 12** — the marketing email list:
- Provider: **Resend**.
- **Our `subscribers` table is the source of truth for consent**; Resend is the rail.
- Transport: **Broadcasts for the daily prompt, individual Emails-API sends for the welcome
  sequence**, because a Broadcast cannot drip. The webhook exists because Broadcasts make Resend a
  second writer of consent state — that was the known cost of the choice and it was paid, not avoided.
- 12(3) is answered by a **separate age-neutral, token-free pool** in `docs/marketing/email-sequence.md`,
  never drawn from the seeded 113. The signup stays an email box rather than becoming onboarding.
- Rate limiting: a **scoped exception** to `CLAUDE.md`, limited to unauthenticated marketing routes.

**New decision — the free tier does not include a second guardian.** The invite surface is the upgrade
surface. Record the consequence: this **restores D4's consumer.** "One price for the whole household"
now has the thing it is sold on, which it did not while 36 was iced.

**New decision — COPPA is deliberately out of scope for now.** Owner's call, Aug 16, with the
reasoning: the child is a data subject, not a user; the parent supplies everything; handoff is years
out. Record the condition that reverses it — the day a child gets their own access, which
`decisions.md` already contemplates with 13 as a floor.

### 5. `decisions-log.md`

One dated entry per phase, in the established form: what was decided, what was considered and
rejected, and what the decision costs.

### 6. New open questions this sprint generated

File each with a number and a "needed by":

- **Reconciling `subscribers` with `users.marketing_consent`.** Two systems, one person, and an
  unsubscribe currently has two places to land. Deliberately deferred all night; it does not stay
  deferred silently.
- **Removing a guardian.** A destructive action over shared history, and nobody has decided what
  happens to their entries.
- **The Broadcast migration threshold.** ~100 subscribers or the free tier's daily cap.
- **In-app account deletion**, if story 5 flagged it as an App Store submission blocker.
- Anything else the reports surfaced.

---

## Deliberately out of scope

- Any code, any migration, any test.
- Ticking any device-verification box.
- Merging any other story's PR.
- Resolving a disagreement between two reports by picking one. Write down both and let the owner
  decide.

## Report to

`docs/sprint-aug16/story-7-report.md`, plus the PR. **Lead the report with the discrepancy list** —
everything a report claimed that the tree did not support. That list is the most valuable thing this
story produces, and if it is empty, say so explicitly rather than leaving its absence ambiguous.
