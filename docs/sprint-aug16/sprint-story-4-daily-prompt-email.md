# Story 4 — The daily prompt email and the welcome sequence

**Lane:** `api/` only. **Runs:** after story 3a merges. **Read `sprint-runbook.md` before starting.**

Two mechanisms, because the owner asked for two things that one mechanism cannot do:

- **The daily prompt** goes to everyone at once → **Resend Broadcast API**.
- **The five-email welcome sequence** is timed off each subscriber's own `confirmed_at` →
  **Resend Emails API**, one send per person.

A Broadcast cannot drip. Do not try to make it.

---

## Hard-stop preflight gates

**Gate 1 — Phase number.** Per the runbook.

**Gate 2 — Story 1 merged**, and `services/resend.py`, `subscribers`, and the webhook route all
exist. If not, halt.

**Gate 3 — The copy has been reviewed.** Read `docs/marketing/email-sequence.md`. **If the file is
missing, or contains the string `NEEDS REVIEW`, HALT.**

The owner approved this copy on **Aug 16, 2026** and the marker is already absent, so this gate
should pass on the first run. **The check stays live anyway** — it is the valve that stops a future
edit-in-progress from being mailed to strangers, and a gate that only guards the case that already
happened guards nothing.

The owner's standing rule is that content is authored with a real model plus his review, never
invented by an agent mid-run. **You implement this copy verbatim. You do not write email copy, you
do not write prompts, you do not "improve" a subject line.** If a piece of copy will not fit the
template, report the conflict; do not resolve it by rewriting the copy.

**Gate 4 — Idempotency.** If `email_sends` exists and both jobs are registered with the scheduler,
report `ALREADY LANDED` and exit 0.

**Gate 5 — No secret required at import.** `RESEND_AUDIENCE_ID` and `RESEND_FROM` are optional.
Unset → dry-run mode. See P5.

---

## Implementation

### P1 — The ledger

`email_sends`:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `subscriber_id` | uuid FK | nullable — a broadcast has no single subscriber |
| `kind` | text | `welcome` \| `daily`, `text` + named CHECK |
| `sequence_index` | int | nullable; 1–5 for `welcome`, null for `daily` |
| `send_date` | date | for `daily`, the broadcast's date |
| `resend_id` | text | message id or broadcast id |
| `status` | text | `sent` \| `failed` \| `skipped`, `text` + named CHECK |
| `error` | text | nullable |
| `created_at` / `updated_at` | | |

Two partial unique indexes, and they are the entire idempotency story:

```sql
CREATE UNIQUE INDEX uq_email_sends_welcome
  ON email_sends (subscriber_id, sequence_index) WHERE kind = 'welcome';
CREATE UNIQUE INDEX uq_email_sends_daily
  ON email_sends (send_date) WHERE kind = 'daily';
```

**Write the ledger row inside the same transaction as the send decision, before the API call.** A
crash between send and record must produce a possible duplicate at most once, and a duplicate is
far better than a job that re-sends email 3 to everyone every hour.

### P2 — The copy loader

Parse `docs/marketing/email-sequence.md` at startup into a structure. **Do not hardcode the copy
into Python** — the owner edits that file, and copy that lives in two places drifts.

Fail loudly at load if the file's shape does not match what the loader expects. A silently-empty
prompt pool would send blank emails on a schedule.

### P3 — The welcome sequence

APScheduler job, hourly.

- For each `confirmed` subscriber, compute days since `confirmed_at`. Send any of emails 1–5 whose
  day offset (0, 2, 5, 9, 16) has passed and which has no `email_sends` row.
- **Backfill guard:** a subscriber confirmed 20 days ago must not receive all five at once. Send at
  most one per subscriber per run, oldest index first. Record the skipped ones as `skipped` so the
  ledger explains the gap rather than leaving it a mystery.
- Throttle to **Resend's 2 requests per second**, and stop the run at **90 sends** to stay under the
  free tier's 100/day with headroom for the confirmations story 1 sends. Log when the cap is hit.
- `List-Unsubscribe` and `List-Unsubscribe-Post` headers on every send, pointing at story 1's
  unsubscribe route with the subscriber's own token. These are transactional-API sends, so Resend
  does not add them — we do, and Gmail and Yahoo both require them for bulk.
- Skip anyone whose `status` is not `confirmed` at send time. Re-read the status inside the
  transaction; a person who unsubscribed an hour ago must not get email 4.

### P4 — The daily broadcast

APScheduler job, once daily at a fixed UTC hour.

- Pick the prompt: **day-of-year modulo the pool length**. Deterministic, stateless, and every
  subscriber gets the same one — which is what a Broadcast sends anyway.
- Create a Broadcast against `RESEND_AUDIENCE_ID` and send it.
- Include Resend's `{{{RESEND_UNSUBSCRIBE_URL}}}` placeholder. **For Broadcasts, Resend owns the
  unsubscribe** — that is the consequence of choosing option B, and it is why story 1's webhook
  exists. Do not also inject our own unsubscribe link into a broadcast; two links with different
  semantics in one email is worse than either alone.
- Before sending, **retry the contact sync**: any subscriber with `status='confirmed'` and
  `resend_synced_at IS NULL` gets `upsert_contact` called, at 2/second. A confirmed subscriber who
  is not in the Audience receives nothing and nothing anywhere says so.

### P5 — Dry-run mode, and why it is the default tonight

**Until a sending domain is verified in Resend, no email can reach anyone but the account owner.**
`onboarding@resend.dev` only delivers to the address on the Resend account.

So: if `RESEND_FROM` still contains `resend.dev`, or `RESEND_API_KEY` is unset, **both jobs run in
dry-run** — they select recipients, render the copy, write `email_sends` rows with
`status='skipped'`, and log the full rendered subject and body at INFO. They call nothing.

This is not a stub. It is the real selection logic, the real templates, and the real ledger, with the
network call withheld. Flipping `RESEND_FROM` to a verified domain turns it on with no code change,
and the ledger already proves the selection was correct.

### P6 — Templates

Plain HTML and a text alternative. **Both are required** — a text/plain part is a deliverability
signal, not a nicety.

Cream `#FDFAF4`, ink `#23253C`, terracotta `#C05A2B` for the one link that matters. No images, no
web fonts, no tracking pixel. Table-based layout, because email clients are what they are. Keep it
under 100KB — Gmail clips above that and would cut the unsubscribe footer off the bottom.

### P7 — Tests

Sequence timing at each offset; the one-per-run backfill guard; the unique indexes rejecting a
duplicate; the unsubscribed-mid-flight skip; the daily pick being deterministic for a given date;
dry-run writing `skipped` rows and calling nothing; the throttle; the 90-send cap.

---

## Break-test at least two assertions

1. **Welcome idempotency.** Drop `uq_email_sends_welcome`. Run the job twice for the same
   subscriber. A test must catch the duplicate send. If nothing fails, the property that keeps you
   from emailing a stranger the same thing twice an hour is not asserted anywhere.
2. **The unsubscribed skip.** Set a subscriber to `unsubscribed` between selection and send. The
   send must not happen. If the code reads status once, before the loop, this test will expose it —
   which is the point.

---

## Deliberately out of scope

- Writing, editing or extending any email copy or any prompt. Gate 3.
- Personalising a broadcast per subscriber. Broadcasts are audience-wide; that is the mechanism.
- Any join or reconciliation with `users.marketing_consent`. Separate populations, still separate.
- Migrating off Broadcasts. The threshold to revisit is ~100 subscribers or the free tier's daily
  cap, whichever arrives first — note it in the report as a future gate.
- Open, click, or bounce tracking. Nothing consumes it and it is a privacy surface on a product sold
  on privacy.
- Anything in `ios/` or the marketing repo.

## Report to

`docs/sprint-aug16/story-4-report.md`, plus the PR description in the runbook's format. State
explicitly whether the jobs ran live or in dry-run, because "the email pipeline works" means two very
different things depending on the answer.
