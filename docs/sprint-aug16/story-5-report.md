# Story 5 — report

**HALTED — the tooling Part 1 requires does not exist, and the initiative description Part 1 would
be run against contains facts the merged docs contradict.**

Nothing written. No `privacy.html`, no `terms.html` change, no `docs/legal/`. No branch, no PR.

**This is the one story of the seven whose gates did not depend on another story**, so it was the
one that might have run tonight. It stopped for its own reasons.

## Reason 1 — `/legal:compliance-check` does not exist

Part 1 says *"Run `/legal:compliance-check` against this initiative"* and write the output to
`docs/legal/compliance-assessment.md`. **There is no such skill available.** The only project skill
is `rascal-review`; no legal or compliance skill exists in the project or user skill directories.

**I did not substitute my own assessment for it.** A GDPR / UK GDPR / CCPA-CPRA / CAN-SPAM / COPPA
analysis of a product that stores a **named minor's** photographs, video, voice recordings and
transcripts, written free-hand by an agent overnight and published as a public legal document, is
not a like-for-like replacement for the named tool. Gate 3 makes the standard itself: *"A privacy
policy that describes retention behaviour the code does not implement is worse than no policy,
because it is a public commitment nobody can keep."* That reasoning applies at least as strongly to
the assessment the policy would be built on.

## Reason 2 — Gate 3 fires on the story's own initiative description

Gate 3: *"Every factual claim… must trace to something in `docs/data-model.md`, `docs/decisions.md`,
or `docs/runbook-deploy.md`. **If a fact is not written down anywhere, do not guess it.**"*

The paragraph Part 1 feeds to the assessment contains two claims the merged docs contradict:

| Claim in the story | What the merged docs say |
|---|---|
| *"collects email addresses for a **daily prompt newsletter**"* | `decisions.md` item 12(3): **weekly**, chosen over daily deliberately |
| Implies a subscriber population we hold — §64 describes *"**subscribers** (an email address and a…)"* as one of two collected populations | `data-model.md`: *"The marketing list is provider-held, and there is no `subscribers` table"* |

A privacy policy is the **worst** document in which to describe data collection that does not
happen. Getting this wrong is not a rework — it is a published, relied-upon false statement about a
minor's data, and it is discoverable by exactly the regulators the policy exists to satisfy.

## Gate 1 — Idempotency — partially landed, worth knowing

- `src/pages/terms.html` **already exists** in `Rascal-Marketing`.
- `privacy.html` does not.
- `docs/legal/compliance-assessment.md` does not.

Not `ALREADY LANDED`, but the terms page is further along than the story assumes.

## Gate 2 — the same premise error story 2 found

*"No build step. As story 2's gate 3."* The marketing repo **does** have a build step —
`package.json` has `build: node scripts/build.mjs`, plus a `dist/` and `node_modules/`. It is
**no-framework**, which is the property worth protecting; "no-build" is not accurate.

## A hazard, same as story 2's

`Rascal-Marketing` has **seven modified files uncommitted on `main`**, two of which
(`src/assets/site.js`, `site.css`) this story would touch. Nothing was staged, stashed, committed or
reverted.

## What unblocks this

1. A real compliance-assessment path — the skill, or an actual lawyer. For a product holding a named
   child's media, this is the item on the whole sprint least suited to being done by an agent at 2am.
2. An initiative description that matches the merged decisions: **weekly**, and a **provider-held**
   list with no `subscribers` table.
3. A clean marketing tree.

**Flagged for the owner, since story 7 §6 asks whether story 5 found an App Store blocker:** the
assessment did not run, so **that question is unanswered rather than answered "no"**. In-app account
deletion is an App Store review requirement for apps with account creation, and whether this app
satisfies it was not determined tonight.
