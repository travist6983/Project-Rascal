# Story 1 — report

**HALTED — Gate 1 and Gate 4 — this story re-specifies phase 60 with a design the owner settled
the opposite way on Aug 16, 2026, seven minutes before these sprint files were written.**

No code written. No migration. No PR. Tree clean except this report.

---

## Gate 1 — Phase number

**Read from `docs/roadmap-status.md:483`:**

> `| **60** | `POST /v1/subscribe`, and Resend replaces Postmark | ○ **new, Aug 16, 2026 — specified, not built** | API lane, per D7, D8, D8a and open item 12. …`

Highest number in the ledger is **60**. Next free is **61**, corroborated at
`docs/phase-queue.md:11` — *"…**60**, so a genuinely new phase takes **61**"* — and 61 appears
nowhere in `roadmap-status.md`, so it is genuinely unallocated.

**Gate 1 fails, and not on arithmetic.** Story 1 is not new work needing a new number. It is
**phase 60**, which is already allocated, already specified in the ledger, and specified
*differently*. Taking 61 would create a second number for one piece of work and orphan a merged
spec. The gate says state the number and the line; the number the ledger gives this work is 60,
and 60 is taken by a contradicting design.

### The runbook's stated premise for this gate is false

`sprint-runbook.md:64-66` says three files disagree about the high-water mark. All three claims
were checked:

| Runbook claim | Actual |
|---|---|
| "`phase-queue.md` currently states the high-water mark is 47" | **False.** That text is inside a blockquote at `phase-queue.md:16-24` documenting a *past error*: *"This header has now been wrong twice in two days… **Neither file was right. `main` was.**"* The runbook quoted the recorded mistake as the file's current claim. The file's actual header (`:11-14`) says 60 is allocated and 61 is next. |
| "`data-model.md` references phase 49 as shipped" | **True, and not a disagreement.** Phase 49 did ship (`roadmap-status.md` ledger). An accurate historical record is not a conflict. |
| "`decisions.md` references phase 50's `pool-health`" | **True, and not a disagreement.** Phase 50 shipped pool-health. Same as above. |

There is no three-way disagreement. The runbook is describing a repo roughly **thirteen phases
stale** (it reasons around 47–50; `main` is at 60, with 51–59 merged Aug 16 via PRs #99, #100,
#101 and live in production). File mtimes put the sprint docs 76 seconds after the last commit,
but mtime is when the files were placed, not what they were authored against.

**Story 7 owns reconciling these files. It should be told the disagreement it is chartered to fix
does not exist.**

## Gate 4 — The rate-limiting exception — FAILS

The gate instructs: if `CLAUDE.md` lacks a rate-limiting exception "limited to unauthenticated
marketing routes", add it with that wording and that date. **Following this instruction would
write two false statements into the standing rules.**

1. **A rate limiter already shipped**, in phase 57: `api/src/rascal/services/rate_limit.py`,
   Postgres-backed, for the auth endpoints. `CLAUDE.md:79` is stale, and the correction is already
   drafted and pending at `docs/proposed-claude-md-diff.md` (written 19:57, "Proposed, not
   applied"). Gate 4 would land a *different, narrower* wording on top of a pending correction
   nobody has approved.
2. **"Limited to unauthenticated marketing routes" is narrower than what shipped and is wrong.**
   The pending diff explains precisely why the line cannot be "unauthenticated endpoints":
   `POST /me/credentials/email` is *authenticated* and mails an address the account has not proved
   anything about. Story 1's wording would exclude a route that is already limited in production.

**And the owner already made the opposite call for this specific endpoint.** `decisions.md` open
item 12(1): *"**no rate limit is applied to `POST /v1/subscribe`** — the owner's call on Aug 16,
2026, on the grounds that no volume is expected that Turnstile would not already stop."* Story 1
Gate 4 claims a scoped exception granted by the owner on Aug 16, 2026 for the same surface. **Two
opposite owner calls, same date.** Only one is in a merged file.

## Gates 2, 3, 5, 6 — for the record

- **Gate 2 — PASS.** Auth is merged: PR #100 (`api/phase-51-59-auth-bundle`), PR #101. Credential
  linking present (`services/auth.py`, `email_sign_in.py`, `apple_events.py`, migration
  `0011_credential_linking.py`).
- **Gate 3 — Not already landed.** No `subscribers` in `api/alembic/versions/`, no subscriber route.
- **Gate 5 — PASS as a constraint.** `docs/runbook-deploy.md:115` §4 confirmed. Nothing was built,
  so nothing required at import.
- **Gate 6 — Would have failed on drift.** Gate 6 wants `MARKETING_ORIGINS` (plural). The merged
  spec (`roadmap-status.md:483`, D7) says `MARKETING_ORIGIN` (singular), *"a one-entry allowlist"*.
  Minor on its own; listed because it is the same drift as everything below.

---

## What this story specifies vs. what `main` settled

Every load-bearing element of Story 1 is contradicted by a merged document. `CLAUDE.md` says
`docs/` is authoritative and `docs/decisions.md` is **settled — do not relitigate**.

| # | Story 1 says | `main` says | Source |
|---|---|---|---|
| 1 | Build a `subscribers` table (P1) | **"The marketing list is provider-held, and there is no `subscribers` table" — "No table exists and none is specified here yet"** | `data-model.md`, commit `f4b50d3`, Aug 16 21:46 |
| 2 | " | "(2) a subscriber is not a `user` — **MOOT for now**… **No `subscribers` table is created and none is specified.**" | `decisions.md` item 12(2) |
| 3 | New `services/resend.py` beside `services/mail.py` (P3) | "**extends the existing `MailProvider` protocol and `send()` in `services/mail.py` rather than adding a second sender beside it** — a second port next to the shipped one is precisely the two-systems-disagreeing-about-one-person's-consent failure that **phase 60's preflight gate exists to catch**" | `decisions.md` **D8a** |
| 4 | In-process per-IP limiter, 10/hr, "per-machine and therefore approximate" (P4) | "**Postgres rather than in-memory, because there is more than one Fly machine.** An in-process counter would be a limit N times looser than it reads… and it would look like it worked in every test." | `services/rate_limit.py` docstring, shipped |
| 5 | " | "**no rate limit is applied to `POST /v1/subscribe`**" | `decisions.md` item 12(1) |
| 6 | Turnstile: **not mentioned anywhere** | "**Turnstile is the entire protection on a public write endpoint**"; "a `TURNSTILE_SECRET_KEY` that skips verification when unset is the defect to design against" | `roadmap-status.md:483` |
| 7 | " | "(1) the spam surface — **CLOSED by Turnstile**, verified server-side… a missing or failed token being a rejection rather than a warning" | `decisions.md` item 12(1) |
| 8 | Route is `POST /v1/subscribers` | Route is `POST /v1/subscribe` | ledger, D7, item 12 |
| 9 | Postmark: not mentioned; left in place | "Phase 60 **replaces** `PostmarkProvider` rather than sitting beside it, with `auth.py` and `me.py` repointed"; "**the adapter is deleted, not disabled**" | `roadmap-status.md:483`, **D8** |

**The sharpest one is #3.** D8a names a second mail port as *the* failure mode phase 60's preflight
gate was written to catch. Story 1's P3 is that second port. Building it would walk the project
into the one trap the owner wrote a gate to prevent.

**#1 deserves a note on how it reads.** Story 1's justification for having no FK to `users` —
private relay makes `users.email` unreliable for dedup — is the reasoning from `decisions.md` item
12(2), where it is the argument for **deferring** the table. Story 1 reuses a deferral rationale as
a build rationale. The words survive; the conclusion is inverted.

---

## Triage of the rest of the sprint — the same root cause

Checked so the loop does not rediscover this one story at a time.

| Story | Status | Why |
|---|---|---|
| **1** | **HALTED** | This report |
| **2** — capture form | **Blocked, and independently wrong** | Its Gate 1 requires story 1 merged. Also POSTs to `/v1/subscribers` (wrong path), has **no Turnstile** — a honeypot only — and cites "the rate limiter" the owner declined. Turnstile is host-independent per D7 and is the settled protection |
| **3a / 3b** — guardians | **Clean of this conflict class** | No email/consent surface. **Separate flag:** `CLAUDE.md:79` lists the guardian invite flow as out of scope for the API lane, and `phase-queue.md:29` records *"42 iceboxed guardian invites"*. 3a needs its own gate run against that — it is a different question, not this one |
| **4** — daily prompt email | **Blocked, and independently wrong** | Its Gate 2 requires story 1's `services/resend.py`, `subscribers` and webhook. Also specifies **daily**; `decisions.md` item 12(3) settled **weekly over daily**, deliberately, because weekly is age-neutral by construction and the library is age-targeted and pronoun-tokenised. Also Broadcasts vs D8a's one-port `send(to, template, context, stream)` |
| **5** — privacy and terms | **Should not ship as written** | Describes "a daily prompt newsletter" and a **subscribers** population held by us. Both are false against `main`. This is a **public legal document making false claims about data collection** — worse than a wrong migration, because it is published and relied upon |
| **6** — video/audio tracks | **Clean of this conflict class** | iOS lane, unrelated surface |
| **7** — reconciliation | **Would encode the inversion** | `:83` asserts *"**Our `subscribers` table is the source of truth for consent**; Resend is the rail."* That is the exact inversion of the settled decision. Story 7 writes to `roadmap-status.md` and `phase-queue.md`, so it would propagate the inversion into the two files that arbitrate everything |

---

## Open items for story 7

1. The runbook's three-way phase-number disagreement **does not exist**; all three claims checked
   and falsified above. Story 7's first task as chartered is a no-op.
2. `CLAUDE.md:79` is genuinely stale, and `docs/proposed-claude-md-diff.md` is the drafted, unapplied
   fix. It needs an owner decision, not a story's improvised wording.
3. `docs/blocked.md` §2b reserved CORS tightening for "when a web client exists". The web-client era
   arrives with phase 60 whatever its final shape. Partly answered; worth recording either way.
   ~~`docs/blocked.md:809`~~ — **repointed to §2b and the quoted sentence Aug 22, 2026 (phase 111),
   which reordered `blocked.md`.** The number was **right on the day**: at `33f77f5`, the commit that
   added this report, `:809` is that exact sentence. On `main` it had slid to the `7b` sub-note lower
   in the same section — still CORS, so still plausible — and here it lands on an unrelated
   `ANTHROPIC_MODEL` note in §4, while the sentence itself sits at `:579`. **A citation that decays
   through *plausible* on its way to *wrong* is the worst kind**, and the section plus the quoted
   sentence is the form that does not.
4. Reconciling a marketing list with `users.marketing_consent` stays open **by design**, not by
   omission — `data-model.md` names the trigger as the first moment a subscriber can also be a user,
   which is post-launch.

## Deliberately not done

- No migration, no model, no schema, no route, no `services/resend.py`, no CORS, no webhook, no tests.
- **No edit to `CLAUDE.md`.** Gate 4 instructed one; it would have been false in two ways.
- No edit to `roadmap-status.md` or `phase-queue.md` (story 7 owns them), and none to `data-model.md`
  or `api-contract.md` — nothing shipped to describe.
- Phase 61 **not** consumed. Nothing was built, and this work's number is 60.
