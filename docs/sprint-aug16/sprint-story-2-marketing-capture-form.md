# Story 2 — The capture form and its landing pages

**Repo:** `travist6983/Rascal-Marketing` only. **Runs:** after story 1 merges.
**Read `sprint-runbook.md` before starting.**

A visitor types an email, gets told to check their inbox, clicks through, and lands somewhere warm.
Three pages and one form. No framework, no build step, `npm run check` green.

---

## Hard-stop preflight gates

**Gate 1 — Story 1's contract exists.** Read story 1's merged PR or
`docs/sprint-aug16/story-1-report.md` in the monorepo. Confirm the three route paths and the exact
request body. **Do not guess the contract.** If story 1 has not merged, halt.

**Gate 2 — Idempotency.** If the form and all three landing pages exist and `npm run check` passes,
report `ALREADY LANDED` and exit 0.

**Gate 3 — No build step.** This repo is deliberately no-framework and no-build. If the work seems
to need a bundler, a package, or a transpile step, **halt and say why** rather than introducing one.

**Gate 4 — Design tokens.** Read `docs/design-system.md` in the monorepo for the token values. Do
not copy motion timings out of any `.dc.html` file — `design-system.md` is authoritative for tokens
and motion; `support.js` is prototype scaffolding and is not portable.

---

## Implementation

### The form

On the existing landing page. Email input, submit button, and a status region.

- `POST` to `${API_BASE}/v1/subscribers` with `{ email, source }`. `source` identifies the page.
- `API_BASE` is a single named constant at the top of the script, commented as the one thing to
  change when the API moves. Default to the deployed Fly host.
- **A honeypot field**: a visually hidden input a human never fills. If it has a value, show the
  success state and send nothing. Cheap, and it removes most of the volume the rate limiter would
  otherwise absorb.
- Client-side validation is a shape check only (`something@something.something`). The server decides.
- States: idle → sending (button disabled, label changes) → done → error. **The done state says to
  check their inbox**, because the row is `pending` until they click, and a success message that
  implies they are subscribed is a lie the confirmation email then contradicts.
- Any non-2xx, or a network failure, shows one calm error line with a retry. Never a stack trace,
  never a red banner.

### Three landing pages

`confirmed.html`, `unsubscribed.html`, `confirm-error.html`. Each one screen, centred, no
navigation trap — every page offers a way back to the landing page.

- **`confirmed.html`** — warm, brief, says what happens next and roughly how often. No exclamation
  stacking, no confetti.
- **`unsubscribed.html`** — confirms it worked, in one line, with no attempt to win them back on the
  page itself and **no guilt**. A resubscribe link is fine; a "are you sure?" is not.
- **`confirm-error.html`** — the link expired or was already used. Says which is likely, offers the
  form again. Never blames the visitor.

### Copy and visual discipline

Cream canvas `#FDFAF4`, ink `#23253C`, terracotta `#C05A2B` for the primary action, Nunito.
Soft rounded cards.

**Never:** red, urgency states, countdowns, streak language, guilt copy, rotated or condensed type,
risograph or halftone texture, high-saturation accents, stock photography of children.

### Accessibility

Real `<label>` on the input (visually hidden is fine). The status region is `aria-live="polite"` so
a screen reader announces the result. Touch targets at least 44px. Contrast checked against the
cream canvas — note in the report if any token pairing lands below AA, and do not silently darken a
token to fix it.

---

## What you cannot verify, and must say so

**You cannot exercise this against a live API.** Story 1's routes will not be deployed when this
runs, and CORS will not have been confirmed from a real origin. Test the form against a local stub
or a mock, and in the PR's *"what ran vs. what was reasoned about"* section say plainly that the
end-to-end path is reasoned, not observed. Do not write "works end to end."

---

## Deliberately out of scope

- The privacy policy and terms pages — story 5.
- Any email content or templates — story 4.
- A domain, DNS, or anything touching Resend.
- Analytics, tracking pixels, or a cookie banner. There is nothing to track yet and a banner for
  cookies you do not set is worse than none.

## Report to

`docs/sprint-aug16/story-2-report.md` in the monorepo (not the marketing repo), plus the PR
description in the runbook's format.
