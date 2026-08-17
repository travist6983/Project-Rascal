# Story 4 — report

**HALTED — Gate 3 — `docs/marketing/email-sequence.md` does not exist. Gate 2 fails independently.**

Nothing written. No branch, no commit, no PR. No phase number consumed.

## Gate 3 — FAILS, and it is the gate the story called a valve

The gate: *"Read `docs/marketing/email-sequence.md`. **If the file is missing**, or contains the
string `NEEDS REVIEW`, **HALT**."*

**`docs/marketing/` does not exist at all.** No such directory, no such file.

Story 4 states *"The owner approved this copy on Aug 16, 2026 and the marker is already absent, so
this gate should pass on the first run."* The tree disagrees: there is nothing at that path to
approve or to mark.

**A draft does exist, at a different path:** `docs/sprint-aug16/email-sequence-draft.md`. It carries
no `NEEDS REVIEW` marker. It is **not** the file the gate names, and the gate says do not guess — so
it was not substituted. Runbook owner errand 6 says *"Review `docs/marketing/email-sequence.md` and
remove the `NEEDS REVIEW` marker"*, which describes a file that has never existed in this repo.
Most likely the draft was meant to be moved into `docs/marketing/` and never was; **moving it is an
owner action, not this story's.**

## Gate 2 — FAILS independently

*"Story 1 merged, and `services/resend.py`, `subscribers`, and the webhook route all exist. If not,
halt."* Story 1 halted; none of the three artifacts exist.

## Gate 4 — not reached

`email_sends` does not exist and no jobs are registered. Not `ALREADY LANDED`.

## Carried forward — the story's design conflicts with merged decisions

Recorded so the conflicts are not rediscovered. See `story-1-report.md` for the full table.

- **Daily vs weekly.** This story is built on a *daily* prompt email. `decisions.md` item 12(3)
  settled **weekly over daily**, deliberately: a weekly *"five prompts this week, pick one"* is
  age-neutral by construction, needs no birthdate and no pronouns, and sends a seventh of the
  volume. The prompt library is age-targeted (`min_age_months`/`max_age_months`) and
  pronoun-tokenised, so a daily personalised send reopens a problem that was set aside, not solved.
- **Broadcasts vs the one port.** D8a specifies one port — `send(to, template, context, stream)`
  with `stream` of `marketing | transactional` — extending `services/mail.py`. This story's
  Broadcast transport plus story 1's `services/resend.py` is the second sender D8a names as the
  failure phase 60's preflight gate exists to catch.
- **The webhook's justification.** This story justifies the webhook by Broadcasts making Resend a
  second writer of consent state. Under the merged design the list is **provider-held**, so Resend
  is the *only* writer of marketing consent and the second-writer problem does not arise in that form.

## What unblocks this

Phase 60's ratifications (see `story-1-report.md`), and `docs/marketing/email-sequence.md` existing
at the path the gate reads.
