# Sprint runbook — Aug 16, 2026 overnight loop

**Goal:** an email typed on the marketing site becomes a confirmed, unsubscribable row we own; a
second guardian can be invited into the household; and phase 16 stops being blocked by a document.

Read this file before running any story. It carries the rules that no individual story owns.

---

## Lanes and order

Three lanes run in parallel. Within a lane, stories run strictly in order. **Never run two stories
from the same lane at once** — `CLAUDE.md`'s two-lane discipline is what keeps `api/` and `ios/`
agents from editing each other's tree, and this sprint adds a third repo.

| Lane | Order |
|---|---|
| `api/` (monorepo) | **1** → **3a** → **4** |
| `ios/` (monorepo) | **6** → **3b** |
| `Rascal-Marketing` (separate repo) | **2** → **5** |
| docs (monorepo) | **7**, last, after everything above has merged or halted |

Story **3b** additionally waits on **3a** merging, because it builds against 3a's API contract.
Story **2** waits on **1**. Story **4** waits on **3a** only for merge ordering, not for behaviour.

---

## Loop semantics — read this twice

The loop may re-enter any story. **Every story must be idempotent against its own completed work.**

- Each story's preflight checks for its own artifacts (migration revision, table, route, file).
- If the work has already landed: **report `ALREADY LANDED`, exit 0, do not proceed.** That is a
  pass, not a failure.
- A story must never re-run a migration, re-create a table, or re-open a merged PR.
- A story must never "improve" work a previous iteration merged. If it disagrees with what shipped,
  it writes the disagreement into its report and stops.

## Halt semantics

**A hard-stop preflight gate produces a report and halts. It never proceeds on a failed check and
never narrows its own gate to make the work fit.**

If a gate fails, write `HALTED — <gate number> — <one line reason>` at the top of the report, leave
the tree clean, and exit. Do not open a PR. Do not partially implement. The loop moves to the next
story in that lane.

## The shared-document rule

**Only story 7 may write to `docs/roadmap-status.md` and `docs/phase-queue.md`.**

Every other story records what it did in its PR description and in a scratch file at
`docs/sprint-aug16/story-<N>-report.md` (new file, no collision surface). Story 7 reads those
reports and folds them into the shared docs in one commit.

Stories **may** write to files they alone own: `docs/data-model.md` (schema stories only, and only
the section they changed), `docs/api-contract.md` (route stories only, appending their own routes),
and new files anywhere.

## Phase numbering

**Do not infer a phase number from this file, from a previous story, or from memory.**

`docs/phase-queue.md` currently states the high-water mark is 47. `docs/data-model.md` references
phase 49 as shipped. `docs/decisions.md` references phase 50's `pool-health`. **These three
disagree with each other right now.** `roadmap-status.md` is the source.

Every story's first preflight step: read `docs/roadmap-status.md`, find the highest phase number in
the ledger, take the next free one, and **state the number and the line it read it from** at the top
of the report. If the number it takes is lower than one already claimed by a sibling story tonight,
halt and say so.

## Do not merge yourselves

Every story opens a PR. **No story merges its own PR.** A migration reaching production
unsupervised is the one failure that costs an archive rather than a night.

---

## PR description format — every story

```
## What ran, and what was reasoned about
[Split explicitly. "The suite passes" is a thing that ran. "This should work on device" is a
thing that was reasoned about. Do not blur them.]

## Ranked confidence
1. [highest] — [why]
2. …
n. [lowest — the thing most likely to be wrong] — [why]

## Break-tested assertions
[At least two. For each: the assertion, the deliberate change made to the code that should have
broken it, and confirmation that it did break. An assertion that survives a deliberate break is
not testing anything.]

## Out of scope, deliberately
[The list from the story file, plus anything discovered mid-run.]
```

**Assertions are never edited to make a test pass.** If an assertion and the code disagree, assume
the assertion is right, stop, and report both sides.

## Adversarial re-read

Before opening the PR, re-read the diff as an adversary: what did this change silently, what claim
in the PR description is not backed by something that ran, and what would a careful reviewer catch
that the author did not. Write the findings into the PR. If the re-read finds something material,
fix it and re-read.

---

## Owner errands, in the order they unblock things

| # | Errand | Unblocks |
|---|---|---|
| 1 | Register a domain and add Resend's SPF/DKIM records | **Every real send.** Until this verifies, Resend only sends from `onboarding@resend.dev` to your own account address |
| 2 | `fly secrets set --app rascal-api MAIL_API_KEY=…` — ~~`RESEND_API_KEY`~~, **corrected Aug 18, 2026: there is no `RESEND_API_KEY` and nothing reads one.** `Settings` has named it `MAIL_API_KEY` since phase 56, because the port is provider-agnostic and the provider is chosen by `MAIL_PROVIDER`. Setting the name in this row would have left every send raising a missing-key error with the secret sitting right there | Story 1's send path. **Full-access key, not `sending_access`** — the contacts upsert needs more than send |
| 3 | `fly secrets set --app rascal-api RESEND_WEBHOOK_SECRET=…` | Story 1's webhook signature verification |
| 4 | Create a Resend Audience, set `RESEND_AUDIENCE_ID` | Story 4's broadcast |
| 5 | Set your own family to `subscribed` (SQL in story 3a) | Inviting your wife. The free-tier gate is live code and will refuse otherwise |
| 6 | Review `docs/marketing/email-sequence.md` and remove the `NEEDS REVIEW` marker | Story 4. It halts while the marker is present |

**None of these block the code landing.** Every story is written so that a missing secret degrades
to a logged no-op rather than an import failure — see story 1, gate 5.
