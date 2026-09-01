---
description: Tiered, budget-capped verification of the current diff. Tier 0 (deterministic, no LLM) always runs first and is the fast/cheap gate; Tier 1 (up to 3 read-only review agents) only looks at what Tier 0 couldn't rule out on its own; Tier 2 (adversarial reproduction) only runs if you ask for it. Report-only — it never edits source itself.
argument-hint: "[base-branch] [--tier2]"
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(python3 .claude/scripts/verify_tier0.py *), Agent, Write
---

# /verify — tiered, capped verification

**Arguments:** $ARGUMENTS

This exists because review effort has run away twice on this account: a 23-agent doc sweep that
burned ~170M tokens, and an 85-agent review workflow on a 700-line diff. Neither extra scale
caught anything a bounded pass wouldn't have. This command is the opposite shape on purpose —
cheap deterministic checks first, LLM review only on what's actually uncertain, and a hard
ceiling on how many agents can ever run.

Parse `$ARGUMENTS`: an optional base branch (default `origin/main`), and an optional `--tier2`
flag. If a base branch is given, pass it through everywhere below in place of `origin/main`.

## Tier 0 — deterministic, always runs, no LLM

Run:

```
python3 .claude/scripts/verify_tier0.py origin/main
```

This is the whole gate for formatter, linter, type-checker status, the full test suite
(serialized behind its own lockfile — never run this yourself in parallel with the script, and
never spawn a subagent that also runs pytest concurrently with it), a coverage-diff status, and
the repo-specific invariant guards (lane boundary, test deletions, `.gitignore` additions,
authorization-helper scoping). It prints a JSON report to stdout and a short summary to stderr.

- If `overall` is `"fail"` (a hard failure: formatter, linter, tests, or a lane-boundary
  violation): stop here. Report the failure verbatim from the JSON — don't spend a single LLM
  review token on a diff that doesn't even pass its own tests yet.
- If `flagged_hunks` is empty: stop here too. Tier 0 found nothing that needs a second opinion —
  report pass, and say plainly that Tier 1 wasn't needed rather than running it out of habit.
- Otherwise, continue to Tier 1 with exactly the `flagged_hunks` list Tier 0 produced — nothing
  more.

Be honest in your report about what Tier 0's invariant guards actually cover: as written, the
auth-scoping and uncovered-by-tests checks are Python/API-lane specific (they read
`api/src/rascal/routers/` and `api/src/rascal/deps.py`). An iOS-only diff will legitimately show
`flagged_hunks: []` because there's nothing in scope for those checks to flag — that's a real
gap in Tier 0's current coverage, not evidence the diff is clean. Say so instead of letting a
clean report read as more thorough than it is.

## Tier 1 — targeted review, capped at 3 subagents

Group `flagged_hunks` into at most 3 batches (by file, or by shared reason — whatever keeps
related hunks together). For each batch, spawn the `verify-tier1` agent type with:

- exactly the files and reasons in that batch — nothing else in the diff
- a findings path to write to (a distinct temp file per agent)
- the reminder that a claim without a reproducing test doesn't become a finding

Never spawn more than 3 of these, and never let one touch anything but `Read`/`Grep`/`Glob`/
`Bash` and its own findings file — that restriction is also baked into the agent's own tool
list, so it's structural, not just a prompt.

Once all batches finish: read each findings file, merge, and **discard any finding whose
`reproducing_test` is empty or missing** — don't act on it, don't report it as a finding, note
it only under "not acted on" if you mention it at all. Report what's left, grouped by file.

## Tier 2 — adversarial reproduction, only on `--tier2`

Skip this section entirely unless `--tier2` was passed. If it was: for each surviving Tier 1
finding, spawn one adversarial agent whose job is to actually write and run the reproducing test
against the current tree, and confirm it fails for the stated reason before it's reported as
confirmed. Cap the total subagent count across Tier 1 + Tier 2 at 5 — if Tier 1 used 3, Tier 2
gets at most 2, so batch or serialize rather than exceeding the ceiling. A Tier 1 finding that
Tier 2 couldn't reproduce gets reported as "claimed, not reproduced" rather than dropped
silently — that distinction is useful to whoever reads the report.

## Report

End with:

1. **Verdict**: pass / fail / needs-human-look, in one line.
2. **What ran**: which tiers, how many Tier 1/Tier 2 agents, and why (or why not) each tier
   after 0 escalated.
3. **Findings**, if any survived — file, line, claim, the reproducing test.
4. **What Tier 0 couldn't check** — not-configured tooling (type checker, coverage) and any
   lane the invariant guards don't yet cover for this diff, stated plainly rather than implied
   by a clean report.
5. **Estimated cost of this run** (tokens/agents) versus a naive multi-agent fleet doing the
   same diff — this is the number that's supposed to keep the budget honest over time.

This command never edits source. If a finding needs fixing, that's a decision for whoever asked
for the verification, not something to act on here.
