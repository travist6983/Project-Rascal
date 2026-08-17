# Story 2 — report

**HALTED — Gate 1 — story 1 has not merged, so the contract this story is forbidden to guess does
not exist. A second, independent reason not to proceed is below.**

Nothing written. No branch, no commit, no PR, in either repo.

---

## Gate 1 — FAILS, exactly as written

The gate: *"Read story 1's merged PR or `docs/sprint-aug16/story-1-report.md` in the monorepo.
Confirm the three route paths and the exact request body. **Do not guess the contract.** If story 1
has not merged, halt."*

Story 1 halted (`story-1-report.md`) and opened no PR. There are **no route paths to read**.

This gate is well-made and it is doing its job: story 2's form would have posted to
`${API_BASE}/v1/subscribers`, and the merged decisions say the route is **`POST /v1/subscribe`**
(`decisions.md` item 12, D7, `roadmap-status.md:483`). Building the form against the story's guess
would have produced a page that 404s against the endpoint the API will actually ship — and it would
have looked finished.

## The second reason — the tree is not clean before I start

`~/repos/personal/Rascal-Marketing` has **seven modified files uncommitted on `main`**:

```
 docs/site-content.md             |  5 ++++-
 src/assets/site.css              | 33 +++++++++++++++++++
 src/assets/site.js               | 43 ++++++++++++++++++++++++++-
 src/pages/compare/tinybeans.html | 21 +-----------------
 src/pages/faq.html               |  8 ++++----
 src/pages/index.html             |  2 +-
 src/pages/pricing.html           |  2 +-
 7 files changed, 87 insertions(+), 27 deletions(-)
```

`src/assets/site.js` and `site.css` are two of the three files story 2's form would touch. **This is
somebody's work in progress**, and the runbook's requirement to leave a clean tree cannot be met by a
story that starts in a dirty one. I did not stage, stash, commit or revert any of it, and I did not
read further into it than the diffstat above.

**If that work is yours and it is finished, commit it before this story runs again.** If it is
another session's, that session should land it first — the marketing lane has one story after this
one (story 5) and both touch the same files.

## Gate 2 — Idempotency — not landed

No capture form and no confirmation/unsubscribe landing pages exist. `src/pages/terms.html` **does**
already exist, which matters for **story 5** rather than this one.

## Gate 3 — the gate's premise is wrong, though the gate itself would not have fired

The gate says: *"This repo is deliberately no-framework and no-build. If the work seems to need a
bundler, a package, or a transpile step, halt and say why rather than introducing one."*

**The repo has a build step.** `package.json` carries `build: node scripts/build.mjs`, plus
`check`, `serve`, `og`, `social:*`, `video`, and a `dist/` and `node_modules/`. It is
**no-framework**, which is true and worth preserving — but "no-build" is not an accurate description
of it.

The gate would not have fired (a plain form needs no bundler), so this is a note rather than a
finding. It is recorded because the next person to read that sentence will believe it.

## Gate 4 — Design tokens — not reached

`docs/design-system.md` in the monorepo is present and is the authority, as the gate says. Not read
in depth, because no styling work was done.

---

## What unblocks this

Story 2 is **cheap and low-risk once its input exists** — three pages and one form, no framework.
It needs exactly two things:

1. **Story 1's contract**, which needs the phase-60 ratifications in `story-1-report.md`. The route
   is `POST /v1/subscribe` and the request body is whatever that phase settles.
2. **A clean marketing tree.**

**One correction to carry into story 2 whenever it runs:** the story specifies a honeypot field as
the spam defence and refers to "the rate limiter". The merged decision is **Turnstile**, verified
server-side, *"a missing or failed token being a rejection rather than a warning"* (`decisions.md`
item 12(1)), with **no rate limit on the endpoint**. D7 notes Turnstile is host-independent and
costs nothing on GitHub Pages — *"Choosing GitHub Pages did not cost it."* A honeypot is a
reasonable addition; it is not a substitute for the thing the owner chose.

## Deliberately not done

- No form, no `confirmed.html`, no `confirm-error.html`, no `unsubscribed.html`.
- Nothing staged, stashed, committed or reverted in `Rascal-Marketing`.
- Nothing in `api/`, `ios/`, `roadmap-status.md` or `phase-queue.md`.
- No phase number consumed.
