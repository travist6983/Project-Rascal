# Story 7 — reconciliation. Report.

**Phase 74.** Docs only. Read from `docs/phase-queue.md` after correcting it: the highest number
used is 73, so a genuinely new phase takes 74.

## Gate 1 was not satisfiable as written, and was met in substance

Gate 1 requires every other story to have *"a merged PR or a report ending in `HALTED`"*. The
runbook simultaneously forbids a story merging its own PR. **Taken literally, story 7 can never
run unattended** — it waits on merges that only the owner can perform, which is the same trap
that produced a night of halts and nothing to review.

Met in substance instead: nothing is in flight, every story has a report, and **phases with open
PRs are filed as `PR open` and never as shipped.** That is the honest form of the same
information, and it is what gate 3 asks for.

| Story | State |
|---|---|
| 1 — subscribers and Resend | HALTED, correctly. Its design contradicted merged decisions on all four points; phase 60 shipped the settled one |
| 2 — capture form | Landed in `Rascal-Marketing` (`8162c90`), deployed |
| 3a — guardians, server | ALREADY LANDED — phase 36 |
| 3b — guardians, iOS | ALREADY LANDED — phases 61 and 63 |
| 4 — daily prompt email | Built as phase 69, ~~**PR #118 open**~~ — **merged Aug 18, 2026 at 10:37 UTC (`490f06b`)** |
| 5 — privacy and terms | Landed in `Rascal-Marketing` (`1f823a1`, `e1cb3c2`), deployed |
| 6 — video audio tracks | Merged as phase 16, PR #116 |
| Sweep | Phase 72, **PR #120 open** |
| Rename | Phases 71 and 73, **PRs #119 and #121 open** |

> **Every PR this table calls open has since merged — annotated Aug 18, 2026.** #118 at `490f06b` (10:37 UTC), #119 at `40483b9` (10:45), #120 at `c885885` (10:45) and #121 at `84d107e` (10:46), all within nine minutes of each other. **The table was correct when written and became wrong overnight**, which is exactly the failure mode story 7 was commissioned to catch — a status recorded as a state rather than as a state *on a date*. The rows are kept unedited; only this note is new.

## Story 7's own instructions were partly false, and gate 3 is what settled it

Gate 3: *"If a report claims something and the tree disagrees, **the tree wins** and you write
down the discrepancy."* Applied to story 7 itself, because five of the claims it asks to be
written into `decisions.md` item 12 do not survive contact with `main`:

| Story 7 says to record | The tree |
|---|---|
| *"Our `subscribers` table is the source of truth for consent"* | **There is no `subscribers` table.** Item 12(4) settled the list as provider-held and phase 60 shipped it that way |
| Welcome sequence sends via the Emails API | **It does not send at all** — it was not built, and cannot be without per-subscriber state we deliberately do not hold |
| A webhook exists to reconcile consent | **None was built.** Under a provider-held list Resend is the *only* writer of marketing consent, so the second-writer problem it was justified by does not arise in that form |
| Rate limiting is a scoped `CLAUDE.md` exception for marketing routes | Item 12(1) records the owner **declining** a limit on this route outright; phase 68 already applied the separate correction |
| The numbering disagreement is 47 / 49 / 50 | Thirteen phases stale. The real disagreement was `phase-queue.md` saying **68** while 68 had merged |

The discrepancies are recorded in item 12; the claims are not.

## What was written

1. **`phase-queue.md`'s high-water mark**, 68 → **73**, with the staleness recorded rather than
   quietly fixed. Third time in three days and the mildest — stale, not self-contradicting. The
   rule that worked again: **measure `main`, not a status document's count.**
2. **Six ledger rows** in `roadmap-status.md` — 68 through 73 — each carrying what shipped, what
   was verified versus reasoned about, and what deliberately did not ship.
3. **Open question 11 closed**, with all three answers and the reason the idempotency guarantee
   needed *two* partial indexes rather than one: Postgres treats NULLs as distinct, so a single
   wide index would silently accept a duplicate shared slot. Break-tested, not reasoned.
4. **Open question 12 updated** with what phase 69 actually built, and with the five false claims
   named above.
5. **36 un-iceboxed**, in the owner's framing — he had been reading *guardian* as grandparents,
   which is phase 30 and stays iced, when he wanted a second parent.
6. **Two new open questions filed**: 15, the uncleared Vellum trademark; 16, reconciling the
   provider-held list with `users.marketing_consent`.
7. **Nine follow-ups** in `phase-queue.md`, each a thing somebody has to do.
8. **A `decisions-log.md` entry** for the night.

## Gate 4 — no device box was ticked

**§0 device verification is still 0 of 45**, unchanged. Every phase tonight was server, docs, or
simulator-verified iOS. A box an agent ticked is worth nothing, and none were.

## The finding worth carrying out of this sprint

**The specs were the least reliable document in the room.** Authored roughly thirteen phases
behind `main`, they described tables, routes and exceptions that had been settled the other way or
never existed. Every story that ran had to be built against the tree instead, and the two that
were not built had already shipped.

The corollary is uncomfortable and worth stating: **a gate that reads a stale spec halts correct
work.** Story 4's gate 2 would have stopped phase 69 for the absence of a `subscribers` table that
a merged decision says must not exist. The gates were not wrong to exist — gate 4 in story 3a
caught a genuinely dangerous migration window — but a gate is only as current as the document it
reads.
