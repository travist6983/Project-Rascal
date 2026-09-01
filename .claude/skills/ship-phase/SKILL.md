---
name: ship-phase
description: Implement a phase end to end in a fresh worktree — cut the branch, build it, self-review with a bounded budget, get the suite green, verify UI changes in the real surface, then stop and report merge-readiness before touching git. Use whenever the user asks to implement, build, or ship a phase, or hands off a whole unit of work with "iterate until it's ready" or "review it yourself and tell me if it's mergeable."
argument-hint: "<phase-number> [api|ios]"
---

# Ship a phase

**Arguments:** $ARGUMENTS

This repo's rules already set the budget and the stopping points for this workflow — this
skill just sequences them so you don't renegotiate the shape of the work every time. Read
`CLAUDE.md` (and `ios/CLAUDE.md` if the phase is in that lane) before starting; the steps
below reference sections there rather than repeat them, so if this skill and `CLAUDE.md` ever
disagree, `CLAUDE.md` wins.

## 1. Confirm the phase number and lane

Phase numbers are **read from `docs/roadmap-status.md`, never inferred** — not from this
prompt, not from the highest number you can find, not by guessing. If the arguments name a
number, check it against the file rather than trusting it at face value; if no number was
given, look it up. If the lane isn't stated, work out from the phase spec whether it's `api/`
or `ios/` — this repo's "Two lanes" rule means everything downstream stays inside that one
lane.

## 2. Cut a fresh worktree

`git fetch origin`, then branch the worktree from `origin/main` — never local `main`, which
can be stale relative to what teammates or other sessions have already merged. Name the
branch after the phase.

## 3. Implement

Build the phase. Where the brief is ambiguous, this repo's Preflight Gates rule applies: pick
the most reasonable reading, state the assumption in one line, and keep going rather than
halting to ask.

## 4. Self-review — run `/verify`

Run `/verify` against the diff. It replaces the old ad-hoc "two rounds, single reviewer"
instruction with the same budget enforced more precisely: deterministic checks first
(formatter, linter, tests, invariant guards), LLM review only on what those checks couldn't
rule out, capped at 3 review agents and never spawned at all if Tier 0 came back clean. Don't
pass `--tier2` on your own initiative — that tier is opt-in, not part of the default phase flow.

If `/verify` surfaces a finding in a hunk you wrote this round, don't patch forward on top of
it — revert that hunk to the last known-good state and redo it. A second `/verify` pass after a
fix is fine; looping into a third out of habit is the exact pattern this replaced.

## 5. Test and verify

Run the full suite once, serialized, per this repo's Testing rule — no subagent runs the suite
concurrently against the same database. For anything UI- or web-facing, verify it in the real
rendering surface (drive the browser, or reinstall the simulator build) before calling it
done; this repo has been burned by source-level reasoning that turned out to be a stale
install or a cached asset, not a correct fix. Show the evidence in your report — a screenshot
plus the console output — not just a claim that you checked.

## 6. Stop — do not commit

`CLAUDE.md` is explicit: **do not commit anything without asking for permission.** Once the
suite is green and verification is done, stop here. Report merge-readiness in this repo's
Response Style — lead with YES or NO, then at most three bullets of evidence. No status
narrative, no recap of the steps you took.

Only after the user confirms: commit, push, and open the PR.
