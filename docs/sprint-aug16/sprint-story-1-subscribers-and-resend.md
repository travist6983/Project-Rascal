# Story 1 — Subscribers and the Resend send seam

**Lane:** `api/` only. **Runs:** first in its lane. **Read `sprint-runbook.md` before starting.**

An email typed on the marketing site becomes a `pending` row, receives a confirmation email, and
becomes `confirmed` when the link is clicked. Unsubscribing is one click and honours a POST. The
send seam built here is the same one phase 38's lifecycle notices will use.

---

## Hard-stop preflight gates

Run all six. **Any failure produces a report and halts.** Do not proceed on a partial pass.

**Gate 1 — Phase number.** Read `docs/roadmap-status.md`. Take the next free phase number from the
ledger. State the number and the line you read it from. Note in the report that `phase-queue.md`,
`data-model.md` and `decisions.md` disagree about the high-water mark; do not resolve that here —
story 7 owns it.

**Gate 2 — The auth PR is merged.** `git log origin/main` must show the auth work merged, and
`api/src/rascal/services/` must contain the credential-linking path. If the auth PR is still open,
**halt** — this story writes to `config.py`, which the auth bundle also touches, and a 3am conflict
on config is how the night ends with nothing merged.

**Gate 3 — Idempotency.** If `subscribers` already exists in `alembic` history *and* the routes are
present in `api/src/rascal/routers/`, report `ALREADY LANDED` and exit 0.

**Gate 4 — The rate-limiting exception.** `CLAUDE.md` currently lists rate limiting as out of scope
for the API lane. The owner granted a **scoped exception, limited to unauthenticated marketing
routes**, on Aug 16, 2026. If `CLAUDE.md` does not yet carry that exception, add it as the first
commit with that wording and that date, and say so in the report. Do not widen it.

**Gate 5 — No secret may be required at import.** Read `docs/runbook-deploy.md` §4. The house
pattern is that a missing secret causes an import failure and a crash-loop. **Every config value
this story adds must be optional**, because they will be set by hand *after* a merge, and a
required-at-import key means an unattended deploy bricks production. If you cannot satisfy this,
halt rather than shipping a required key.

**Gate 6 — CORS origin.** `MARKETING_ORIGINS` must default to `https://travist6983.github.io` and
parse a comma-separated list. If `config.py` has no list-parsing helper, write one — do not add a
scalar that a second origin will have to migrate off.

---

## Implementation, in order

### P1 — The migration

New revision, `subscribers`:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `email` | text NOT NULL | stored as given; matched case-insensitively |
| `status` | text NOT NULL | `pending` \| `confirmed` \| `unsubscribed`. `text` + **named CHECK**, per the constrained-value convention this schema uses everywhere |
| `confirm_token_hash` | text | SHA-256. **The raw token is never stored** — same discipline as `refresh_tokens` |
| `confirm_token_expires_at` | timestamptz | 7 days from issue |
| `confirmed_at` | timestamptz | nullable |
| `unsubscribed_at` | timestamptz | nullable |
| `unsubscribe_token_hash` | text | separate token, no expiry — an unsubscribe link must work forever |
| `last_confirm_sent_at` | timestamptz | nullable. The per-email cooldown clock |
| `source` | text | nullable — which page or campaign. Cheap now, impossible to reconstruct later |
| `resend_contact_id` | text | nullable. Set when the contact is pushed to the Audience |
| `resend_synced_at` | timestamptz | nullable. Null on a confirmed row means the push failed and should be retried |
| `created_at` / `updated_at` | timestamptz | `updated_at` maintained by the existing `set_updated_at()` trigger, **never by application code** |
| `deleted_at` | timestamptz | nullable. Soft delete, per the standing rule |

Indexes:
- `UNIQUE (lower(email)) WHERE deleted_at IS NULL`
- index on `confirm_token_hash`, index on `unsubscribe_token_hash`
- index on `(status, confirmed_at)` — story 4's send query reads it

**No foreign key to `users`, deliberately.** Write the reason into `docs/data-model.md` beside the
table: Sign in with Apple private relay means a signed-up parent's `users.email` may never match the
address they gave the marketing site, so deduping the two populations by email is unreliable.
Phase 49's `users.marketing_consent` covers app users and does **not** cover this table. An absence
with no reason beside it reads as an oversight; this one is a decision.

### P2 — Model and schemas

`models/subscriber.py`, `schemas/subscriber.py`. Nothing surprising. Pydantic v2.

### P3 — `services/resend.py`

Three functions, all async, all with an explicit timeout, **no retries** (a cron retries; a request
handler must not sit on a socket):

- `send_email(to, subject, html, text, headers=None) -> str | None` — returns the Resend message id.
- `upsert_contact(email, unsubscribed=False) -> str | None` — returns the contact id.
- `remove_contact(contact_id) -> bool`

**When `RESEND_API_KEY` is unset, every function logs at WARNING what it would have sent and returns
`None`.** The caller must treat `None` as "not sent" and never as an error that fails the request.

`RESEND_FROM` defaults to `Dogear <onboarding@resend.dev>`. The sandbox sender only delivers to the
account owner's address — record that in the module docstring so the first person to wonder why a
stranger got nothing finds the answer in the file.

### P4 — Rate limiting

Two mechanisms, and they are not interchangeable:

- **IP burst:** in-process fixed window, 10 requests per IP per hour, applied only to
  `/v1/subscribers*`. Fly runs more than one machine, so this is per-machine and therefore
  approximate. **Say that in the docstring** rather than letting a future reader assume it is global.
- **Per-email cooldown:** `last_confirm_sent_at` on the row, 15 minutes. This one **must** be correct
  across machines, because it is what stops someone mail-bombing a stranger's inbox with
  confirmations. Postgres is the arbiter; enforce it inside the same transaction as the send decision.

### P5 — Routes

`POST /v1/subscribers` — unauthenticated.
- Body: `{ "email": str, "source": str | None }`
- **Always returns `202` with an identical body** whether the address is new, already pending, or
  already confirmed. Anything else turns this route into an oracle that tells any caller whether a
  given email is on the list.
- New address → row + confirmation send. Pending address past cooldown → resend. Pending inside
  cooldown → nothing, still 202. Confirmed → nothing, still 202.
- Unsubscribed address that signs up again → back to `pending` and re-confirm. That is a fresh,
  explicit opt-in and is the correct reading.

`GET /v1/subscribers/confirm?token=…`
- Idempotent. Confirming twice succeeds twice.
- On first success: set `confirmed_at`, `status='confirmed'`, then `upsert_contact` and record
  `resend_contact_id` / `resend_synced_at`. **A failed contact push does not fail the confirmation** —
  the row is confirmed, `resend_synced_at` stays null, story 4 retries it.
- Redirect `302` to `{MARKETING_SITE_URL}/confirmed.html`; expired or unknown token redirects to
  `/confirm-error.html`.

`GET /v1/subscribers/unsubscribe?token=…` **and `POST` on the same path.**
- The POST is not optional. Gmail and Yahoo's one-click sends `List-Unsubscribe-Post`, and a
  GET-only route fails the exact requirement that makes bulk mail deliverable — silently, and only
  in the inboxes you care most about.
- Sets `status='unsubscribed'`, `unsubscribed_at`, and calls `upsert_contact(unsubscribed=True)`.
- GET redirects to `/unsubscribed.html`. POST returns `200` with an empty body — a mail client is
  not following redirects.

### P6 — CORS

`fastapi.middleware.cors.CORSMiddleware`, origins from `MARKETING_ORIGINS`, methods `POST, GET,
OPTIONS`, no credentials. **Applied to the subscriber routes only, never globally, and never `*`.**

This is the first browser client this API has ever had. `docs/blocked.md:809` reserved CORS
tightening for "when a web client exists" — note in the report that the web-client era arrived
through a side door, and that the note in `blocked.md` is now partly answered.

### P7 — The Resend webhook

`POST /v1/webhooks/resend`. Required because the owner chose Broadcasts (option B) for story 4,
which makes Resend a second writer of consent state.

- Verify the Svix signature using `RESEND_WEBHOOK_SECRET`. **Unset → return 503 and log.** Never
  process an unverified webhook, and never make the secret required at import.
- Handle `contact.updated` and any unsubscribe-shaped event: find the subscriber by
  `resend_contact_id`, or by `lower(email)` if the id is unknown, and set `status='unsubscribed'`.
- **Ingest only. Never write back to Resend from this handler** — that is a loop.
- Unknown event types: log and return 200. A webhook that 500s on an unrecognised event gets your
  endpoint disabled.

### P8 — Tests

pytest, async. Cover: the identical-202 for all four states; the cooldown; case-insensitive
uniqueness; confirm idempotency; unsubscribe by both GET and POST; the unset-key path returning 202
with nothing sent; webhook signature rejection; CORS preflight from an allowed and a disallowed
origin.

---

## Break-test at least two assertions

Do both of these, and report the deliberate break and that it was caught:

1. **The enumeration defence.** Change `POST /v1/subscribers` to return `409` for an existing
   address. A test must fail. If none does, the identical-response property is not actually asserted
   and you must write the test that asserts it.
2. **The case-insensitive unique index.** Insert `Foo@Example.com` after `foo@example.com`. A test
   must fail on the constraint. If it passes, the index is wrong — probably a plain unique on
   `email` rather than on `lower(email)`.

---

## Deliberately out of scope

- The daily prompt email, the welcome sequence, and any Broadcast — that is story 4.
- Any join, dedupe, or reconciliation between `subscribers` and `users.marketing_consent`. The two
  populations are separate and stay separate tonight. Record it as an open item in your report for
  story 7 to file.
- Anything in `ios/`.
- Anything touching `roadmap-status.md` or `phase-queue.md`.
- Widening the rate-limiting exception beyond unauthenticated marketing routes.

## Report to

`docs/sprint-aug16/story-1-report.md`, plus the PR description in the runbook's format.
