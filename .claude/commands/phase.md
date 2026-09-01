---
description: Phase orchestrator. Derives which lanes (api/ios/docs) a phase touches, cuts one worktree per lane from a freshly-fetched origin/main, enforces file ownership per lane, coordinates cross-lane needs through written contract requests instead of cross-lane edits, and reports a merge-order recommendation with a mergeability table. Invoke as /phase <number> [brief].
argument-hint: "<phase-number> [brief describing the work]"
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(python3 .claude/scripts/phase_lane_setup.py *), Bash(python3 .claude/scripts/check_lane_ownership.py *), Bash(python3 .claude/scripts/phase_merge_order.py *), Bash(gh pr create *), Bash(gh pr view *), Agent, Write, Edit
---

# /phase — multi-lane phase orchestrator

**Arguments:** $ARGUMENTS (a phase number, optionally followed by a prose brief)

This exists to turn "implement phase N across both lanes" from a multi-hour supervised relay
into something you check once at the end. It only works if lane boundaries actually hold —
that's what most of this file enforces.

## 1. Derive the lane plan — then ask exactly once

Look up the phase's line in `docs/phase-queue.md` if one exists, and read whatever brief was
given in `$ARGUMENTS`. From that combined text, derive which lanes this phase touches:

- Mentions of Swift, SwiftUI, SwiftData, the simulator, or a path under `ios/` → **ios**
- Mentions of FastAPI, a route, a migration, Postgres, or a path under `api/` → **api**
- A phase that is purely documentation with no code implied → **docs** only

This repo has no `web` lane — there's no `web/` directory here, the marketing site is a
separate repository. Don't derive one.

For each lane, work out its **owned paths**: a code lane owns its own directory (`api/` or
`ios/`) plus whatever docs it's naturally responsible for updating as part of its own work
(its own roadmap-status.md entries, its own decisions-log lines). If two code lanes are both
active, shared root-level files (`CLAUDE.md`, cross-cutting docs) belong to whichever lane's
work is more central to the phase — decide and say why, don't leave it ambiguous.

Print the lane plan as a table (lane, worktree name, owned paths, one-line reason) and the
file-ownership map, then ask **one** yes/no question: "Proceed with this lane plan?" Do not ask
about lane assignment again after this — if something looks ambiguous later, apply this repo's
Preflight Gates rule (pick the most reasonable reading, state the assumption, keep going) rather
than re-opening the question.

If the tree is dirty with only untracked scratch files, or the phase number isn't in
`phase-queue.md` yet: log it and proceed. That's cosmetic, not a reason to halt — this repo's
Preflight Gates rule says so explicitly, and this command exists partly because halting on
trivia has cost whole sessions before.

## 2. Cut the worktrees

Once confirmed, run:

```
python3 .claude/scripts/phase_lane_setup.py <phase-number> "api:api/,docs/..." "ios:ios/,docs/..."
```

(one `lane:path,path,...` argument per confirmed lane). This fetches `origin` first and branches
every worktree from `origin/main` — never local `main`. It writes a `LANE.json` into each
worktree. Read the script's output for the exact worktree paths and branch names before
spawning anything.

## 3. Spawn one agent per lane

For each lane, spawn an `Agent` (general-purpose) with a self-contained brief:

- The lane's worktree path — work only inside it (`cd <worktree_path>` first).
- The phase brief, scoped to what this lane owns.
- **Before any commit**, run `python3 .claude/scripts/check_lane_ownership.py <worktree_path>`.
  If it reports `"status": "fail"`, do not commit the flagged files. Instead write
  `<coordination_dir>/CONTRACT_REQUEST-<lane>-<short-timestamp>.md` describing exactly what
  needs to change in the other lane and why, then stop and report back as blocked — don't route
  around the check.
- Follow this repo's `ship-phase` discipline for the implementation itself: bounded self-review
  via `/verify`, real-surface verification for anything UI/web-facing with a screenshot and
  console output, run the lane's own build + test suite to green.
- **If it can't get green**: don't stall silently. Push what you have and open a **draft** PR
  with a written diagnosis of what's failing and why — that's a real, visible result, a stalled
  agent with nothing to show is not.
- **If it gets green**: push and open a **draft** PR. Do not mark it ready for review — that
  step waits for confirmation from whoever is reading the orchestrator's final report, same as
  every other commit-adjacent action in this repo.

Spawn all lanes' agents in the same turn so they run concurrently — don't run one lane to
completion before starting the next.

## 4. Resolve contract requests as they arrive

If a lane's report says it's blocked on a `CONTRACT_REQUEST`, read the file. Two ways to
resolve it:

- The owning lane genuinely needs to make that change — relay it as a follow-up instruction to
  that lane's agent (resume it; don't start a new one) and have the blocked lane wait.
- The requesting lane was wrong to need it — say why, and tell it to route around the file
  rather than through it.

You (the orchestrator) are not lane-restricted, but resolving a contract by editing the file
yourself defeats the point — always route the actual edit through the lane that owns the path.

## 5. Final report

Once every lane has either opened a PR or reported an unresolvable blocker:

```
python3 .claude/scripts/phase_merge_order.py <phase-number>
```

Report:

1. **Merge-order recommendation** from the script's output, stated as a recommendation with its
   reasoning, not a lock — and say plainly when lanes look independent rather than implying an
   order that isn't there.
2. **One table**: lane | PR number | CI status | mergeable yes/no. "Mergeable" means green and
   PR-opened, not "looks fine to me" — base it on what actually ran.
3. Any contract requests that got resolved, and how.
4. Every PR opened this run is a **draft** — say that plainly, and that marking any of them
   ready for review is your call, not something this command does on its own.
