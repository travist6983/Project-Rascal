# RASCAL — standing rules

A native iOS app that archives a child's childhood one daily prompt at a time. This repo
holds both halves: the backend in `api/` and the iOS client in `ios/`. `docs/` holds the
specs and they are authoritative: `docs/data-model.md` (schema), `docs/api-contract.md`
(endpoints), `docs/decisions.md` (settled — do not relitigate), `docs/mission-library.md`
(seed prompts), `docs/memory-app-roadmap.md` (scope).

If the code and `docs/data-model.md` disagree, the code is wrong.

## DO NOT COMMIT ANYTHING WITHOUT ASKING FOR PERMISSIONS 

**One narrow exception:** finishing a merge or rebase you started as part of already-authorized
work (a worktree branch, a phase in flight) — if it hits a conflict, resolve it and complete the
merge/rebase yourself rather than stopping to ask, then report exactly what you chose and why.
This covers only the commit that completes an in-flight merge/rebase; it does not extend to any
other commit, and it is not a reason to skip asking before opening a PR.

## Review Budget

Match review effort to diff size. For diffs under ~1000 lines, do at most TWO self-review
rounds with a single reviewer pass — never spawn multi-agent review fleets. Only escalate to
parallel agents when the diff spans >5 files AND >1500 lines, and state the estimated cost
before launching. Never launch more than 5 subagents without asking first.

## Response Style

When asked a yes/no question (e.g. "is this merge-ready?"), lead with the one-word answer,
then at most 3 bullets of evidence. No status narratives, no recaps of what you did. Save
detail for when it's requested.

## Destructive Operations

Never run `rm -rf`, directory-clearing render scripts, `git checkout <file>`, or `git clean`
on paths containing committed artifacts without first listing exactly what will be deleted and
getting confirmation. Render/build scripts must write to a temp dir and swap, never wipe the
output dir in place. Never change global git config (including `pull.rebase`) — repo-local
only.

## Two lanes

`api/` and `ios/` are separate lanes that share a repo, not a codebase. An agent working in
`ios/` never edits `api/`; an agent working in `api/` never edits `ios/`. `docs/` is shared
and either lane may read it — but a change to `docs/api-contract.md` is an API-lane change.

The rest of this file is the API lane. The iOS lane's rules are in `ios/CLAUDE.md`. CI is
scoped by path so a commit in one lane never runs or deploys the other.

## The rules. Violating any of these is a defect.

1. **The server owns the schedule.** Assignment, expiry, and "what day is it" are
   server-computed in the child's `family_timezone`. Never client-computed.
2. **Sign in with Apple is a credential row, not the identity model.** `users` has a stable
   UUID; Apple is one row in `credentials`. Adding password or Google auth later must
   require zero schema changes.
3. **`occurred_at` and `created_at` are never conflated.** Backdating is a first-class flow.
   Timeline sorts by `occurred_at`; sync filters on `updated_at`.
4. **Three completion shapes:** `did_it`, `media`, `text`. Nothing in the schema or the API
   may assume an entry has media. "Get on the floor for ten minutes" is a complete,
   legitimate entry with no artifact.
5. **Soft deletes and `updated_at` on every user-data table.** Deletions sync as rows with
   `deleted_at` set, never as absences. **One deliberate exception, added by phase 66 on Aug 17,
   2026: account deletion hard-deletes.** A request sits in `deletion_requests` for seven days and
   then the user's data is destroyed, because a soft delete on an erasure would be the service
   keeping exactly what it was asked to stop keeping — and there is no client left to tell. The
   exception is documented in `data-model.md`'s `deletion_requests` section and is the only one;
   **every other table still obeys this rule, and adding a second exception is a decision, not a
   precedent you already have.**
6. **Plain JSON over HTTPS.** No Swift-specific serialization anywhere in the wire format. A
   browser will consume this API in 2027.
7. **On-device AI output is durable data.** `PATCH /media/{id}/derived` persists transcripts
   and captions written back from the phone. The server never regenerates them.
8. **No TODOs.** Every function is finished. No `pass  # implement later`, no stub returning
   fake data, no commented-out branches.

## Conventions that follow from those rules

- Constrained-value columns are `text` + a named `CHECK` constraint, never Postgres enums.
- `updated_at` is maintained by the `set_updated_at()` Postgres trigger, never by
  application code. Application code that sets `updated_at` is a bug.
- Every index and constraint is explicitly named, so migrations can reverse cleanly.
- Authorization lives in `deps.py` (`current_user`, `child_access`). Never hand-roll an
  ownership check inside a handler. Routes reaching a child indirectly — through an entry,
  media, or assignment id — resolve the owning child and run the same dependency.
- Every read path filters `deleted_at IS NULL` except `/sync`, which must return deleted rows.
- UUIDs are client-generated for `entries` and `media`, server-generated everywhere else.
- Errors are raised as `RascalError` and rendered by the one handler in `errors.py`:
  `{"error": {"code": ..., "message": ..., "field": ...}}`. Codes are the `ErrorCode` enum.
  Never leak a stack trace or a raw SQL error.
- `dev-login` and every `/debug/*` route are registered only when `ENVIRONMENT == "local"`.
- Prompts are seeded from `api/seeds/prompts.yaml`. `docs/mission-library.md` is the
  authoring surface; runtime never parses markdown.
- **The seeded library is tokenised.** See `.claude/rules/prompt-library.md` for the exact
  counts, the loader's token-rejection contract, and re-seeding idempotency — it loads
  automatically when you touch `prompts.yaml`, `mission-library.md`, or `seeding.py`. Never
  write copy that assumes a child's gender — client-side strings are neutral too and stay that
  way.

## Stack

Pinned in `api/pyproject.toml`, `docker-compose.yml`, and `api/fly.toml` — settled, do not
substitute.

## Out of scope for the API lane — stop if you find yourself designing one

Swift or iOS code (that is the other lane, not this one), multi-kid UI concerns,
observability beyond structured logging.

~~*LLM prompt generation, the admin prompt review queue*~~ — **both removed Aug 20, 2026 by
phase 103, on the owner's explicit call, and this list was already wrong about them before that.**
`scripts/generate_prompts.py` has generated candidates with a real model since phase 46 and has a
scheduled workflow; `scripts/review_candidates.py` is the review queue and shipped reading a
`source='llm'`, `active=false` queue that nothing could fill. Phase 103 fills it: `POST
/v1/prompts/generate` and `POST /v1/prompts/candidates`, the console's Library tab, and
`services/candidates.py` — which is the *same* rule set the script uses, moved into `src/` because
`Dockerfile` copies neither `scripts/` nor `docs/`. **What is still out of scope is the thing this
line was protecting**: nothing generates a prompt at request time for a child, nothing activates a
candidate, and no bulk-approve endpoint exists — a candidate is `active=false` until a person reads
it and presses a button. See `decisions.md` and `decisions-log.md` for the reversal.

**Phase 120 removed the other vendor on Aug 25, 2026**, and it is recorded here because this is the
paragraph about what this repository asks a model for. Nothing above has moved. What left the tree
is `services/social/gemini.py` and all three `GEMINI_*` settings — `grep -n -i gemini
api/src/rascal/config.py` returns nothing — so **no vendor generates video pixels for this product
any more** either; the transcode paragraph below says what does instead. Check `api/` before
writing a line here.

~~*thumbnail or transcode pipelines*~~ — **struck for one feature and one only, by the owner's
call of Aug 20, 2026, and narrowed further by phase 120 on Aug 25, 2026.**

**What it covers now: one WebM in, one H.264 MP4 out.** The studio's video is an ordered list of
brand cards; `admin/static/cards.js` draws every frame in the operator's own browser and
`MediaRecorder` captures the canvas (`cards.js:330-331`), and `services/social/transcode.py`
shells out to ffmpeg to re-encode that recording into the format a platform will accept. The
runtime image installs ffmpeg (`api/Dockerfile:53-55`). That is a transcode pipeline by any honest
reading and it was authorised deliberately rather than argued around; `docs/decisions.md` carries
the reasoning.

~~*The studio's video render generates a clip per shot — no video API on any vendor joins clips —
so `services/social/stitch.py` shells out to ffmpeg to concatenate them.*~~ — **struck Aug 25, 2026
by phase 120 (`01318be`, PR #170): there are no clips.** The browser records one continuous
capture, so there is nothing to concatenate, and `stitch.py` is deleted along with `gemini.py` and
all three `GEMINI_*` settings — `ls api/src/rascal/services/social/` prints nine files and neither
of those two is among them. The re-encode is now **unconditional**, because `MediaRecorder` writes
an unknown duration into the WebM header and a stream copy would carry it straight through into the
MP4 (`transcode.py:16-25`). The strike **narrows**, which is worth saying plainly because a struck
scope line is the sentence an agent quotes when it deletes something: the input is no longer a
vendor's output at all, it is bytes this repository's own console recorded seconds earlier.

**Below, this list counts *three entries* struck for naming shipped subsystems. The strike
immediately above is the fourth, and it is the first for the opposite reason** — the other three
named subsystems that were built and serving, which is the failure of writing this list from
intent rather than from the tree; this one named a file the tree no longer has, inside the very
paragraph this list wrote to authorise it. `api/Dockerfile:43-46` struck the identical sentence
in the same phase that made it false. This file did not, because phase 120 was told to *propose*
against `CLAUDE.md` rather than edit it — `docs/reports/phase-120-proposed-diffs.md` §5 is the
text above, and that report's own first line reads *"Nothing in this file has been applied."* **A correction that exists only in a report
is a correction the tree does not have.**

**It is struck narrowly.** Thumbnails, transcoding *user media*, and anything touching the
`children/` prefix remain out of scope and are the thing the original line was protecting: an
archive that re-encodes what a parent uploaded is an archive that can corrupt it. This
~~concatenates~~ **re-encodes** marketing output that ~~a vendor generated~~ — **this repository's
own browser recorded, since phase 120 on Aug 25, 2026** — seconds earlier, under `social/`, and
never reads a family's bytes.

~~*push notifications, full-text search*~~ — **both removed from this list Aug 18, 2026, because
both are built and served in `api/`.** Push: `services/notifications.py`, `jobs/notify.py`, the
`devices` and `notification_sends` tables, and a scheduled machine that has delivered to a real
locked phone. Full-text search: migration `0004_full_text_search`, the generated `search_vector`
columns on `entries` and `media`, two GIN indexes, and `GET /entries?q=` which the contract
documents as *"full-text search over title, body, caption, and transcript"*. **An out-of-scope
list that names shipped subsystems is worse than no list**: it reads as permission to remove
working code, and it is the sentence an agent quotes when it deletes something. **Three entries
have now been struck for that reason and two of them named code that already existed when the line
was written** — so the failure is not that this list goes stale, it is that it gets written from
intent rather than from the tree. Check `api/` before adding a line here.

**Rate limiting is out of scope for routes that only touch the caller's own data, and
required for any route that can reach somebody else.** A signed-in parent hammering their own
archive is a support conversation, not an attack.

~~*Two routes qualify*~~ — **three, since phase 136 on Sep 2, 2026**, and the second is why this
is not simply "unauthenticated endpoints".
`POST /auth/email/start` is unauthenticated and mails an address a stranger chose.
`POST /me/credentials/email` is *authenticated* and mails an address the account does not own
and has not proved anything about — so without a limit, anyone who can create a free account
can use it, and our sending reputation, to mail a stranger repeatedly.
**`POST /families/me/invites` is the third, and it qualified the day it started sending.** It
took an `email` from phase 36 onward and only ever wrote it to a column, so the rule did not
reach it; phase 136 made it mail the invite, and the same limit went on in the same commit.
**A route does not qualify because of who may call it — it qualifies the moment it can put a
message in a stranger's inbox**, which is a property that changes under you.

The limit lives in the app rather than at the edge because an edge limiter cannot see the
address: it is inside the request body. It is Postgres-backed because there is more than one
Fly machine, so an in-memory counter is per-process theatre.

**`POST /v1/subscribe` deliberately has none**, and that is not an oversight in the rule above:
Turnstile is the whole protection there, by the owner's call of Aug 16, 2026, and it fails
closed. See `decisions.md` open item 12(1).

**A web frontend is no longer out of scope in the sense this line meant.** There is no web
*client* for the archive and there is not going to be one soon — but the marketing site is a
browser calling this API, so CORS, `MARKETING_ORIGINS` and `POST /v1/subscribe` are all API-lane
concerns now. What stays out of scope is serving HTML for the product itself, per D7.

## Testing

Only one pytest run may touch the test database at a time. Never let a subagent run the suite
concurrently with the main session — serialize suite runs or give each runner an isolated
database.

Before claiming a UI or web change works, verify it in the actual rendering surface — drive
the browser for web/HTML, reinstall the simulator build for iOS. Do not trust source-level
inspection alone; stale installs and cached assets have caused false "already correct"
conclusions. Show the evidence, don't just assert the check happened: a screenshot plus the
console output, not a summary of what you looked at.

## Bug Reports

When the user reports a bug, follow this loop and say which step you're on:

1. **Reproduce before theorizing.** Write a failing test — or a browser-driven repro via the
   Chrome tools for UI/auth state — that shows the exact reported symptom, before reading
   source for suspects. If it can't be reproduced, say so plainly and ask for the missing
   ground truth rather than guessing.
2. **Verify the failure reason.** Confirm the test fails for the reported mechanism, not an
   unrelated setup error. State the actual mechanism in one sentence.
3. **Challenge the brief.** Check environment and data state before blaming source — a stale
   simulator install, a manually seeded row, or a misconfigured domain has been the real cause
   here before, not a code defect.
4. **Minimal fix.** Change only the smallest surface that turns the test green. No opportunistic
   refactors, no adjacent cleanup.
5. **Regression sweep.** Run the full suite. If the fix broke something else, that's a new bug —
   restart at step 1 for it, don't patch forward on top of it.
6. **Report:** root cause (one sentence), files changed, test added, suite status. Nothing else
   unless asked.

## Preflight Gates

Preflight checks may warn but must never halt work. If the tree is dirty, a phase number is
missing, or entry points are ambiguous, pick the most reasonable option, state the assumption
in one line, and proceed. Never deliver docs-only output when implementation was requested.

Cut every new branch from a freshly-fetched `origin/main` — `git fetch origin && git worktree
add -b <branch> origin/main` — never from local `main`, which can be stale relative to what's
already merged. Run git mechanics (fetch, worktree, branch, conflict resolution) yourself
rather than asking to have them run for you; a merge conflict gets resolved and reported, not
escalated as a question, per the exception noted under the commit rule above.

## Working here

`cp .env.example .env && make up && make migrate && make seed && make test`. Judgment calls
go in `docs/decisions-log.md`, one line each. Anything blocked on a credential goes in
`docs/blocked.md`.

**Every discrete unit of work gets a phase number, including docs-only work.** Numbers come from
`docs/roadmap-status.md` and are **read from the file, never inferred** — not from memory, not by
adding one to the highest integer in sight, and not from whatever a prompt happens to say.

**A phase number is an identifier, not a position in a queue.** A lower number does not run first,
and phases are executed in whatever order makes sense at the time. Nothing is renumbered or
reordered to make the sequence read as an execution order. The existing collisions at ~~3, 11, 19
and 20~~ — **3, 11, 19, 20 and 103; the fifth added here Aug 25, 2026 by phase 122** — stay exactly
as they are. **103 happened on Aug 20, 2026, and `docs/roadmap-status.md`'s *103 is spent twice*
note has cited this very sentence as its authority ever since — *"the collisions at 3, 11, 19 and
20 stay as they are; this is now the fifth"* — while this sentence went on listing four.** The two rows are *the shot list
becomes a video* (PR #153) and *LLM prompt generation* (PR #152): both shipped, both carrying `103`
in their branch names and their commit subjects, and counting the ledger's own phase column finds
exactly one number used twice. **103 is the only collision this project created *after* the rule
was written** — two branches allocating hours apart on the same day, neither able to see the
other's allocation because neither had written a row yet — and it is why the paragraph above says
numbers are **read from the file**.
