# Story 5 — Privacy policy and terms

**Repo:** `Rascal-Marketing`, plus one new doc in the monorepo. **Runs:** independent, any time.
**Read `sprint-runbook.md` before starting.**

The moment an email address is collected there has to be a privacy policy, and App Store review will
ask for the same URL when the app is submitted. This is small now and blocks a submission at the
worst possible moment if it is left.

**This is not legal advice and the output must say so.** The deliverable is a well-organised draft
for a qualified professional to check, not a filing. Any place where the honest answer is "a lawyer
should decide this" gets written down as exactly that rather than smoothed over.

---

## Hard-stop preflight gates

**Gate 1 — Idempotency.** If `privacy.html` and `terms.html` exist on the site and
`docs/legal/compliance-assessment.md` exists, report `ALREADY LANDED` and exit 0.

**Gate 2 — No build step.** As story 2's gate 3.

**Gate 3 — Do not invent facts about the product.** Every factual claim in the policy — what is
collected, where it is stored, who it is shared with, how long it is kept — must trace to something
in `docs/data-model.md`, `docs/decisions.md`, or `docs/runbook-deploy.md`. **If a fact is not written
down anywhere, do not guess it. List it as an open question and leave a clearly marked placeholder.**
A privacy policy that describes retention behaviour the code does not implement is worse than no
policy, because it is a public commitment nobody can keep.

---

## Part 1 — The assessment

Run `/legal:compliance-check` against this initiative:

> A solo-developer iOS app that stores a named minor's photographs, video, voice recordings,
> transcripts and a parent's written notes, sold by subscription, with a marketing website that
> collects email addresses for a daily prompt newsletter and a five-email welcome sequence.
> Data lives in Neon Postgres and Tigris object storage. Sign-in is Sign in with Apple.
> Email is sent through Resend. A second parent can be invited into the household.

Write the output to `docs/legal/compliance-assessment.md`.

Cover at minimum: **GDPR and UK GDPR** (lawful basis, data subject rights, the processor list,
international transfer), **CCPA/CPRA**, **CAN-SPAM and the equivalent EU/UK rules** (double opt-in,
working unsubscribe, sender identification, physical address), and **Apple's App Store
requirements** — privacy nutrition labels, account deletion, and the age-rating questionnaire.

**COPPA is out of scope for this assessment, by the owner's decision, Aug 16, 2026.** Record the
decision and its reasoning in one line so it is not mistaken for an oversight: COPPA attaches when a
child is a *user* of the service. Here the child is a data subject only — the parent supplies
everything, the child has no account, and handoff is years away. **Note that this stops being true
the day a child gets their own access**, which `decisions.md` already contemplates with 13 as a floor.

**The one thing not to soften:** this product stores a named minor's face and voice. The policy must
say that plainly rather than describing it as "user content." Say what it is.

## Part 2 — The pages

`privacy.html` and `terms.html` on the marketing site. Site design language: cream `#FDFAF4`, ink
`#23253C`, terracotta `#C05A2B`, Nunito. Readable measure, real headings, a last-updated date.

**Privacy policy sections:**
- What is collected, in two clearly separated populations — **subscribers** (an email address and a
  signup source, nothing else) and **app users** (account, children's names and birthdates, photos,
  video, audio, transcripts, notes). These are different tables with different lawful bases and the
  policy must not blur them.
- Where it is stored and who processes it: Neon, Tigris, Fly.io, Apple, Resend. Name them.
- What is never done: no sale of data, no advertising identifiers, no third-party analytics on the
  archive.
- **On-device AI**: transcription and extraction run on the phone and the *output* is persisted
  server-side as plain text. Say that the audio is transcribed on the device, because it is a real
  and unusual privacy property and it is worth claiming.
- Retention and deletion, and the account-deletion path. **If the deletion route does not exist yet,
  say what the process is today — an email to the owner — rather than describing a button that
  isn't there.** Apple requires an in-app deletion path for accounts; flag it as a submission
  blocker in the report if it is missing.
- Data subject rights and how to exercise them.
- Contact address. **Placeholder, clearly marked** — a real one is an owner action.

**Terms sections:** the service, accounts and households, subscription and billing (marked as not
yet live), acceptable use, ownership — **the parent's content is the parent's**, and say so
unambiguously — export and portability, termination, disclaimers, governing law (Michigan,
US; flag for the lawyer), and changes to terms.

## Part 3 — Wire them up

Footer links from the landing page and from all three of story 2's landing pages. **Link the privacy
policy from the signup form itself**, next to the submit button, in small but legible type.

---

## Deliberately out of scope

- A cookie banner. The site sets no cookies and runs no analytics. A banner for cookies you do not
  set is worse than none — and if that changes, the banner comes with the change.
- A DPA, SCCs, or any vendor contract review.
- Registering a data protection representative or any filing.
- Actually deciding any legal question. Flag and move on.
- Anything in `api/` or `ios/`.

## Report to

`docs/sprint-aug16/story-5-report.md`. Lead the report with **the list of placeholders and open
questions**, because that list is the actual work product for the owner — the prose is the easy part.
