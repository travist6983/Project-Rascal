# Story 7 — report

**PARTIALLY EXECUTED.** Gates 1–4 pass. The reconciliation ran; **§1, most of §3 and all of §4
halted on Gate 3**, which says the tree wins over a report and the discrepancy gets written down.
This report leads with that list, as the story requires.

**Nothing shipped tonight**, so there is no phase to file and **no phase number was consumed by any
of the seven stories.**

---

## The discrepancy list

Everything the sprint documents claimed that the tree does not support. **It is not empty**, and it
is the reason six of the seven stories halted.

| # | Claimed | The tree | Where |
|---|---|---|---|
| 1 | `phase-queue.md` states the high-water mark is **47** | **False.** That text sits inside a blockquote at `phase-queue.md:16-24` documenting a *past* error, whose own conclusion is *"Neither file was right. `main` was."* The file's actual header (`:11-14`) says 60 is allocated and **61 is next** | `sprint-runbook.md:64` |
| 2 | `data-model.md` references phase **49** as shipped, and this is a disagreement | **True but not a disagreement.** Phase 49 did ship. An accurate historical record is not a conflict | `sprint-runbook.md:65` |
| 3 | `decisions.md` references phase **50**'s `pool-health`, and this is a disagreement | **Same.** Phase 50 shipped pool-health | `sprint-runbook.md:65` |
| 4 | *"These three disagree with each other right now"* | **No three-way disagreement exists.** The runbook reasons about a repo at ~47–50; `main` is at **60**, with 51–59 merged Aug 16 (PRs #99, #100, #101) and live | `sprint-runbook.md:66` |
| 5 | The owner granted a rate-limiting exception on Aug 16, scoped to marketing routes | **Contradicted.** `decisions.md` item 12(1): *"**no rate limit is applied to `POST /v1/subscribe`** — the owner's call on Aug 16, 2026"* — opposite call, same date | story 1, gate 4 |
| 6 | Build a `subscribers` table | **Contradicted.** `data-model.md` (commit `f4b50d3`, Aug 16 21:46): *"The marketing list is provider-held, and there is no `subscribers` table"* | story 1 P1; story 7 §4 |
| 7 | New `services/resend.py` beside `services/mail.py` | **Contradicted.** D8a: a second port beside the shipped one *"is precisely the two-systems-disagreeing-about-one-person's-consent failure that phase 60's preflight gate exists to catch"* | story 1 P3 |
| 8 | In-process per-IP rate limiter | **Contradicted by shipped code.** `services/rate_limit.py` is Postgres-backed and its docstring rejects the in-memory design by name: *"a limit N times looser than it reads… it would look like it worked in every test"* | story 1 P4 |
| 9 | Route is `POST /v1/subscribers` | **`POST /v1/subscribe`** | stories 1, 2 |
| 10 | Turnstile is not mentioned anywhere in the email lane | **`roadmap-status.md:483`: *"Turnstile is the entire protection on a public write endpoint"*** | stories 1, 2 |
| 11 | Four owner decisions settled Aug 16 on two-parents-on-one-child | **Absent.** `decisions.md` item 11 carries **no settlement marker** and says its collisions each need *"an answer before anything is built"*. Item 12 carries `✅ PARTIALLY ANSWERED`, so this file does mark settlements | story 3a |
| 12 | Story 3a *"un-iceboxes phase 36"* | **36 was never iceboxed. 30 was.** `roadmap-status.md:434` ices 30 (grandparents as viewers); `phase-queue.md:240-242` says *"**36 is deliberately still in the build queue**"* | story 3a; story 7 §3 |
| 13 | The owner authorised recording §0 of the transcription checklist | **Absent**, and `blocked.md` says the opposite in the same section the story cites: *"**Nobody but the owner may tick those boxes**… must not record a result it did not observe"* | story 6 |
| 14 | The §0 result is confirmed | **Covers part of 1 of 5 boxes.** Nothing on three recordings, reading back against the audio, whether names survive, or whether it invents sentences where he mumbled | story 6 |
| 15 | `docs/phases/phase-16-BLOCKED.md` | **Does not exist.** There is no `docs/phases/` directory | story 6, gate 2 |
| 16 | `docs/marketing/email-sequence.md` exists and its `NEEDS REVIEW` marker is already removed | **`docs/marketing/` does not exist.** A draft sits at `docs/sprint-aug16/email-sequence-draft.md` | story 4 gate 3; runbook errand 6 |
| 17 | `/legal:compliance-check` | **No such skill.** `rascal-review` is the only project skill | story 5 |
| 18 | The marketing repo is *"no-framework and no-build"* | **No-framework is true; no-build is not.** `package.json` has `build: node scripts/build.mjs`, plus `dist/` and `node_modules/` | stories 2, 5 |
| 19 | *"Our `subscribers` table is the source of truth for consent"* | **Exact inversion** of the settled decision — Resend holds the list | **story 7 §4**, this story's own instructions |
| 20 | Daily prompt email | **Weekly**, settled at item 12(3), because weekly is age-neutral by construction | stories 4, 5; story 7 §4 |

**One discrepancy ran the other way, and it was mine.** An earlier draft of `story-6-report.md`
claimed the ledger's *"twelve checklists"* was wrong and there were thirteen. **The ledger was
right.** `docs/Device-Verification/` holds thirteen files, but `entry-detail-inventory.md` is not a
checklist and carries no boxes. Twelve `device-verification-*.md` files, summing to exactly 460.
Corrected in that report rather than quietly dropped.

---

## What this story wrote

### Committed — the doc paths, and the ledger's ability to check itself

`ec87dbb` ("docs rearrane") moved the twelve checklists into `docs/Device-Verification/` and updated
nothing that referenced them. **Twenty-three stale paths across four files**, fixed mechanically.

Two of them were inside `roadmap-status.md`'s own verification block, so **the commands the ledger
supplies to prove its headline number matched nothing and summed to 0.** They now return the values
their inline comments claim:

```
$ grep -chE '^\s*-? *\[[ xX]\]' docs/Device-Verification/device-verification-*.md | awk '{s+=$1} END {print s}'
460
$ grep -chE '^\s*-? *\[[xX]\]'  docs/Device-Verification/device-verification-*.md | awk '{s+=$1} END {print s}'
9
```

**No figure in any document changed.** 460, 9 and twelve were all correct; what was broken was the
ability to verify them. That block already carried a warning that an earlier bug meant it *"could
have read 0 forever"* — it read 0 again, and the second time the glob was the cause rather than the sum.

### Committed — two new open questions (§6)

- **13 — Removing a guardian.** The sprint specified adding one and said nothing about removing one.
  `revoked_at` makes access trivial; the archive is the question, because `entries.completed_by`
  records which parent answered. Filed with the three shapes and why they are not equivalent. **The
  reason to decide it before it is needed:** the request arrives during a separation, from someone
  upset, and *"we never decided"* becomes whatever support chooses that day.
- **14 — In-app account deletion.** Filed as **unanswered rather than as a known gap** — story 5's
  assessment was supposed to cover it and halted. Apple has required it for account-creating apps
  since June 2022; this app creates accounts and has never been submitted.

**Deliberately not filed:** reconciling a marketing list with `users.marketing_consent` (already
recorded in `data-model.md` and item 12(2), and filing it again would be a duplicate), and the
Broadcast migration threshold (no Broadcasts exist, so the threshold is for a design that was not chosen).

### Committed — `decisions-log.md` (§5) and `roadmap-status.md` item 9 (§2)

The judgment calls behind the seven halts, and one new entry in **"Blocked on you, not on code"**
carrying the seven ratifications the night produced. That section is where they belong: none of it
is blocked on code and all of it blocks code.

---

## What this story refused to write, and why

**Gate 3: *"If a report claims something and the tree disagrees, the tree wins and you write down
the discrepancy."*** Applied to this story's own instructions.

- **§1 — "Fix the phase numbering disagreement, first, before anything else."** **Not done: there is
  no disagreement.** Rows 1–4 above. Correcting `phase-queue.md` and `data-model.md` to "agree" with
  `roadmap-status.md` would have introduced errors into two files that are currently right.
- **§3 — "Un-icebox 36."** **Not done: 36 is not iceboxed** and is already in the build queue. 30 is
  iced and stays iced, which §3 also says and which is correct. **"Delete every line whose work
  landed"** — nothing landed, so nothing deleted.
- **§4 — "Close open question 11."** **Not done.** Its three answers are the four unratified
  decisions from story 3a, on a question that says answers are needed *before anything is built* —
  and nothing was built, so the third answer would have recorded the behaviour of two partial unique
  indexes that do not exist. **The proposed answers are not lost**: they are worked out to a yes/no
  in `story-3a-report.md`, with a recommendation on each.
- **§4 — "Close open question 12."** **Not done.** Its text asserts *"Our `subscribers` table is the
  source of truth for consent"* (row 19), daily rather than weekly (row 20), and a rate-limiting
  exception the owner declined (row 5). `CLAUDE.md` calls `decisions.md` **settled — do not
  relitigate**; writing three contradictions into it would have made the file that arbitrates every
  other file disagree with `main`.
- **§4 — the two new decisions.** *"The free tier does not include a second guardian"* is story 3a's
  unratified decision 4. **"COPPA is deliberately out of scope"** is asserted as an owner call with
  no corroboration anywhere — and it is a legal scope decision about a product holding a named
  child's photographs, video and voice. **That is the single line in this sprint I was least willing
  to write on an unverified authorisation.** Both are in the ratification list instead.
- **Gate 4 — no device-verification box was ticked**, by this story or any other. The denominator did
  not grow either, because no story shipped anything to write boxes against. Story 6 listed the
  boxes phase 16 *would* create; they are in its report, unfiled, because the work did not happen.

---

## Gates

- **Gate 1 — PASS.** All seven stories have reports in `docs/sprint-aug16/`; all seven halted.
- **Gate 2 — PASS.** All read in full before anything was written.
- **Gate 3 — PASS, and it did most of the work.** Every claim above carries a file, a line or a command.
- **Gate 4 — PASS.** No box ticked.

## For the owner

The seven ratifications are `roadmap-status.md`'s new **"Blocked on you, not on code"** item 9, and
each traces to a story report. The four phase-36 ones are the highest-value: they are worked out,
gate 4's production evidence is banked, and **that evidence stops being derivable the day a second
guardian exists.**

**One thing to fix in the sprint documents themselves before re-running any of this:** they were
written against a repo state roughly thirteen phases old and one docs reorganisation ago. Re-running
them unchanged will reproduce these same twenty halts.
