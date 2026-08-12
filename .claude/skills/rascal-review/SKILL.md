---
name: rascal-review
description: Deep multi-agent review of this branch's diff against main. Spawns four specialist reviewers in parallel (api-reviewer for authz and the standing rules, api-performance-reviewer, ios-reviewer for SwiftData durability and the design system, test-coverage-reviewer), independently validates every finding, drops known false positives from .claude/review-history/, and writes a severity-ranked report plus TASK.md. Use whenever the user asks to review this branch, review a PR, check a diff before opening a pull request, asks "what did I miss" or "is this ready to merge", or wants api/ or ios/ changes checked against CLAUDE.md and docs/ — including when they just say "review my changes".
argument-hint: "[--comment] [--pr <number>] [optional focus areas]"
allowed-tools: Read, Glob, Grep, Write, Edit, Agent, Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git merge-base:*), Bash(git show:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr comment:*), Bash(python3:*), Bash(mkdir:*), Bash(date:*)
---

# Rascal Review — four specialists over one branch diff

**Arguments:** $ARGUMENTS

You are the coordinator. You gather the diff, route it to the specialists whose lane it
touches, have every finding independently checked by someone who did not raise it, and write
one ranked report. You do not review the code yourself — your judgment goes into what gets
routed where and what survives validation.

**For every agent you spawn:** tools work; do not test them or make exploratory calls. Call a
tool only when it is needed to confirm something. Say this in each agent's brief.

---

## The bar every finding has to clear

False positives are the thing that kills a review tool. The second time someone reads a
confident paragraph about a bug that isn't there, they stop reading the report. Findings
therefore have to be defects, not opinions.

**Flag:**
- Code that will fail to import, run, or migrate
- Code that produces wrong results regardless of input
- A violation of a rule written down in `CLAUDE.md`, `ios/CLAUDE.md`, `docs/decisions.md`, or
  `docs/design-system.md` — quote the rule verbatim
- Drift from `docs/data-model.md` or `docs/api-contract.md`. The repo's rule is explicit: *if
  the code and the docs disagree, the code is wrong.*
- Authorization holes, leaked archive content, exploitable input handling
- Performance patterns that will fail at this product's real scale (one family, thousands of
  entries, media measured in gigabytes — not a million users)

**Do not flag:**
- Style, naming, or anything `ruff` and the Xcode warning gate already catch
- Missing tests outside what `test-coverage-reviewer` is scoped to
- Pre-existing problems in code this branch did not touch
- The seeded library's he/him copy — that is deliberate and settled (`docs/decisions.md`
  item 10). New copy assuming a child's gender *is* flaggable.
- Anything on the out-of-scope lists in the two CLAUDE.md files, framed as "you should also
  build…" — a review that grows the scope of a branch is not a review
- Something that looks wrong but is correct once you read the surrounding code

If you are not sure a finding is real, it isn't ready to report.

---

## Phase 0 — pre-flight

**Arguments.** `--comment` posts the result to the PR. `--pr <number>` reviews that PR instead
of the working branch. Anything else is a focus area — pass it to every specialist verbatim.

**PR mode.** `gh pr view <number> --json state,isDraft,title,body,headRefName,baseRefName`.
If it is closed, merged, or draft, say so and stop. Use `gh pr diff <number>` for the diff and
the PR's head branch for the report path.

**Branch mode.** Use three-dot diffs throughout:

```bash
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git diff main...HEAD --name-only
git diff main...HEAD --stat
```

Three dots, not two: this repo merges `main` into long-lived branches, and `git diff main`
would hand the reviewers every change that landed on `main` since the branch opened. Reviewing
someone else's merged work is how a review run burns twenty minutes and reports nothing.

If nothing changed, say "No changes to review" and stop.

**Lane routing.** This is a two-lane monorepo and the lanes share nothing but `docs/`:

| Lane | Paths |
|---|---|
| API | `api/**`, `.github/scripts/**`, `.github/workflows/ci.yml`, `docs/api-contract.md`, `docs/data-model.md` |
| iOS | `ios/**`, `docs/design-system.md` |
| Shared docs | the rest of `docs/**` — context for both, reviewed by neither on its own |

Assign files to specialists from that table:

| Specialist | Gets |
|---|---|
| `api-reviewer` | API-lane files |
| `api-performance-reviewer` | API-lane files |
| `ios-reviewer` | iOS-lane files |
| `test-coverage-reviewer` | every changed file — coverage is a claim about src *and* tests |

A specialist with no files is not spawned. An iOS-only branch is a two-agent review, and that
is the common case here.

**Cross-lane note.** If the diff touches both `api/` and `ios/`, say so in the report summary.
It is not automatically a defect, but the standing rule is that a change in one lane is not a
change in the other, and a branch spanning both is usually two pull requests wearing a coat.

**Chunking.** If one specialist's file list exceeds 50 files, sort the paths and split into
contiguous chunks of ≤50, spawning one agent per chunk with a label like
`api-reviewer-2-of-3`. Each agent gets `git diff main...HEAD -- <its files>` — never the whole
diff. This is what keeps a big branch from timing out a single agent.

---

## Phase 1 — the specialists, in parallel

Spawn every `(specialist, chunk)` pair in one turn using the Agent tool with `subagent_type`
set to the reviewer's name. Their system prompts live in `.claude/agents/` and carry the rules,
the codebase examples, and the output schema; the brief you write only supplies the situation:

- The chunked diff (`git diff main...HEAD -- <files>`) or the PR diff for their files
- Their file list with change stats, and the chunk label if chunked
- Focus areas from `$ARGUMENTS`, verbatim, if any
- PR title and body in PR mode — intent changes what counts as a defect
- The branch name, so it lands in their JSON
- Which lane the branch belongs to, and whether it crosses lanes

**Output contract:** one JSON object, no prose, no markdown fences, matching the schema in the
agent's own file. `CRITICAL` and `HIGH` only, confidence ≥ 80. Reviewers do not compute
fingerprints — Phase 2 does that, because a hash written by a model is a hash that does not
match anything.

---

## Phase 2 — merge, suppress, rank

This is where the run gets its output folder: `.claude/reviews/<slug>/`, where `<slug>` is the
branch name with `/` replaced by `-`, or `pr-<number>` in PR mode. `mkdir -p` it.

Concatenate every reviewer's `findings` array into one list, write it to
`.claude/reviews/<slug>/raw-findings.json` as `{"findings": [...]}`, and run:

```bash
python3 .claude/skills/rascal-review/scripts/merge_findings.py \
  --suppressions .claude/review-history/false-positives.json \
  < .claude/reviews/<slug>/raw-findings.json \
  > .claude/reviews/<slug>/merged-findings.json
```

It fingerprints each finding on `rule + file + normalised code`, drops fingerprints listed as
known false positives, merges duplicates into one record with both reviewers in `sources`,
drops anything under confidence 80, and ranks what is left. Read the result — the counts it
returns (`suppressed_count`, `duplicate_count`, `dropped_low_confidence_count`) go in the
report, because a review that silently discards things is a review nobody can calibrate.

Keeping the raw file is what makes a disappointing run diagnosable: it is the only record of
what each specialist actually said before filtering.

---

## Phase 3 — validation

The specialists are looking for trouble, which is the job, and it makes them credulous. Every
surviving finding gets checked by an agent that did not raise it, spawned in parallel with
`subagent_type: general-purpose`, receiving:

- The finding object
- The full diff and the PR intent, if any
- This instruction: read the code at that path as it exists now, not just the diff hunk

A validator returns **CONFIRMED** or **REJECTED**, a one-line reason, and a final confidence.
Reject when: the code does not actually do what the finding says; the problem is in lines this
branch did not touch; the rule quoted does not apply to that file or is quoted wrongly; the
behaviour is deliberate and documented in `docs/decisions.md`. Rejecting is the cheap outcome —
a wrong finding costs more than a missed one, because the next review gets skimmed.

If more than 12 findings survive Phase 2, validate the 12 most severe and report the count you
did not validate, listed by file, rather than quietly trimming the tail.

Write the confirmed findings — with the validators' confidences replacing the originals — to
`.claude/reviews/<slug>/validated-findings.json` and run the script over that file again so the
ranking reflects the final numbers. It is idempotent: fingerprints are a pure function of rule,
file and code, so nothing shifts underneath you.

---

## Phase 4 — write it down

Everything lands in the folder Phase 2 created.

**`.claude/reviews/<slug>/findings.json`** — the final script output plus run metadata:
`branch`, `sha`, `generated_at` (from `date -u +%FT%TZ`), `specialists`, `files_reviewed`,
`validated`, `rejected_count`. The intermediate `raw-findings.json`,
`merged-findings.json` and `validated-findings.json` stay beside it; the whole folder is
gitignored and rewritten on the next run of that branch.

**`.claude/reviews/<slug>/report.md`**:

```markdown
# Rascal Review — <branch>

- **Lane**: API | iOS | both (flag it)
- **Files reviewed**: N   **Lines**: +A / -B   **SHA**: <short sha>
- **Findings**: N validated (Critical: N, High: N)
- **Specialists**: <the ones that ran>
- **Suppressed as known false positives**: N   **Rejected in validation**: N   **Below confidence**: N

## Findings by file

### <path>

#### CRITICAL
- **<CATEGORY>** <one-line description> (confidence: N)
  - Lines: <range>
  - Code: `<the offending code>`
  - Rule: <verbatim quote from CLAUDE.md / docs, or why this breaks>
  - Fix: <concrete change, with code>
  - Sources: <specialists> · Fingerprint: `<12 hex>`

#### HIGH
<same shape>

## Reviewed with no findings
<paths>
```

If nothing survived, the report is the summary block plus one line naming the specialists that
ran. That is a real result and worth writing down.

**`TASK.md`** at the repo root — append, never rewrite. Read it first and keep every existing
line, including the completed ones:

```markdown
> Updated by rascal-review on <date> · branch <branch> · N validated findings

## Critical
- [ ] **<CATEGORY>** <what to do> — `<file:line>` (confidence: N)

## High
- [ ] **<CATEGORY>** <what to do> — `<file:line>` (confidence: N)
```

**`--comment`** posts one comment to the PR — print the body first, then
`gh pr comment <number> --body-file <path>`. Without the flag, nothing is posted. In branch
mode with no PR, say so instead of hunting for one.

**Then print:**

```
  RASCAL REVIEW COMPLETE — <n> specialists
  Files:      N (+A / -B)      Lane: <lane>
  Findings:   Critical N · High N
  By source:  api N · api-performance N · ios N · test-coverage N
  Filtered:   suppressed N · rejected N · low-confidence N
  Written:    .claude/reviews/<slug>/report.md
              .claude/reviews/<slug>/findings.json
              TASK.md
```

Then say, in a sentence, what you would fix first and why — the ranking is mechanical, but
which finding actually blocks the merge is a judgment the person reading this wants from you.

---

## When a finding was wrong

If the user says a finding is a false positive, add it to
`.claude/review-history/false-positives.json` with its fingerprint from the report, the reason
in their words, and `expires_at: null` (or a date, if it is only wrong until something lands).
That file is the reason the second review of a branch is quieter than the first, and it only
works if it gets fed. See the README beside it for the shape.
