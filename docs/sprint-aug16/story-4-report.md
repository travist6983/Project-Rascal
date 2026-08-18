# Story 4 — the daily prompt email. Report.

**Phase 69**, read from `docs/phase-queue.md:11` — *"61 through 67 all went on Aug 17, so the
next is 68"* — with 68 consumed by the unblock-everything work (`364154c`), so 69 is the next
free number. API lane only.

## Ran in dry-run. Nothing has been emailed to anybody.

Stating it first because the story asks for it explicitly: *"the email pipeline works" means two
very different things depending on the answer.* **No email has been sent.** The job selects the
prompt, renders both bodies, writes its ledger row and logs the full rendered mail — and stops
before the network call.

That is not a stub. It is the whole path with one step withheld, and the withheld step is one
environment variable.

## The cadence question was settled before this ran

Open item 12(3) settled **weekly**; `email-sequence.md` says **daily**. The owner resolved it
**Aug 17: DAILY**, and the reasoning is recorded — weekly was chosen because it was *"age-neutral
by construction"*, and the pool is 30 prompts already age-neutral and token-free, so daily
inherits the property. Daily is implemented, and no copy was touched.

## Gate 2 could not pass, and should not have

Gate 2 requires story 1 merged with `services/resend.py`, a `subscribers` table, and a webhook
route. **None of those exist, and none should** — phase 60 shipped the settled design instead:
the list is provider-held (open item 12(4)), `POST /v1/subscribe` is a thin forward, and D8a
names a second mail port as precisely the failure phase 60's gate exists to catch. Halting on
gate 2 would have been halting because the repo is correct.

So the story was built against what `main` actually has.

## What got built, and the two places it departs from the spec

### Departure 1 — the ledger holds no recipient

Story 4 specifies `email_sends` with a `subscriber_id` FK and a partial unique index per
`(subscriber_id, sequence_index)`. There is no `subscribers` table to point at, and creating one
is forbidden by a settled decision.

More sharply: **a per-recipient ledger would be the mailing list in our database under another
name.** The privacy page published Aug 17 says we hold no copy of it. Making that sentence false
is a worse outcome than any duplicate the table prevents.

`email_broadcasts` records the *broadcast*: a date, which pool index went out, the subject, what
Resend said. No address, no id, no join to a person. A test asserts no column is ever named
`subscriber_id`, `email`, `recipient`, `address` or `contact_id`, so the privacy claim has
something defending it besides good intentions.

**`uq_email_broadcasts_send_date` is the entire idempotency story.** Two Fly machines on one
schedule, a retried machine, or a hand-run `--date` for a day already sent all collide on it.

### Departure 2 — the copy is generated to YAML, not parsed at runtime

P2 says parse `docs/marketing/email-sequence.md` at startup. That cannot work, for two reasons
and the second is fatal:

1. `CLAUDE.md` says **runtime never parses markdown**. The prompt library already solves this
   exact problem with `docs/mission-library.md` → `seeds/prompts.yaml`.
2. **`docs/` is not in the image.** Fly builds with `api/` as the context; the Dockerfile copies
   `src`, `alembic` and `seeds`. A loader pointed at `../docs/...` passes every test on a laptop
   and raises `FileNotFoundError` on the first scheduled run in production.

So `scripts/email_sequence_to_yaml.py` is the only thing that reads the markdown, exactly
mirroring `mission_library_to_yaml.py`, and it emits `seeds/email_copy.yaml`, which ships. The
owner still edits one file and only one file.

**No copy was authored, edited or improved.** The generator is strict — wrong pool count, a
renumbered list, a missing footer, and a missing subject are each a non-zero exit.

## The welcome sequence is not built, and this is the decision to make

P3 is a five-email drip timed off each subscriber's own `confirmed_at`. **We do not know who
confirmed, or when.** That fact lives at Resend, we store nothing, and there is no way to
implement a per-subscriber drip without per-subscriber state on our side.

Three ways forward, none of which an agent should pick:

| Option | What it costs |
|---|---|
| **A. Resend-side automation** | Nothing of ours. Whether Resend can drip off a confirmation date is unverified — **do not assume it can** |
| **B. A local table of contact ids** | Re-opens item 12(2) and (4). Even keyed on opaque contact ids rather than addresses, it is a record of who is on the list, and the privacy page needs rewording *before* it ships |
| **C. Leave it** | The broadcast is the thing the owner asked for first. The five emails are a nice-to-have that has waited this long |

The daily broadcast needs none of this, which is why it shipped alone.

## One conflict to report rather than resolve

`email-sequence.md` gives the pool and the footer but **no body wrapper for the daily email**.
The reviewed site copy says *"The subject line is the prompt, and the body is one line more"* —
and that one line is not in the copy file.

Rendered as: subject = the prompt, body = the prompt and the footer, verbatim. If a line under
the prompt is wanted, it goes in `email-sequence.md`, the generator re-runs, and it takes effect
**with no code change**. Per the file's own header, an agent reports this rather than writing
the line.

## Break-tested

| Break | Result |
|---|---|
| `is_live` ignores `marketing_email_enabled` (credentials alone start sending) | **1 failure** — `test_credentials_alone_do_not_make_it_live` |
| `uq_email_broadcasts_send_date` removed from the migration | **3 failures**, including one asserting the constraint at the database rather than through the service |

The first break also **found a real defect in a test**: with the guard broken,
`test_a_dry_run_consumes_the_day` reached the live path and made an actual HTTPS request to
`api.resend.com` with a fake key. A test that reaches the network when the code is wrong
punishes a mistake by making an outbound request. `_send` is now stubbed there, and in every
test that uses live-looking settings.

## What ran, and what is reasoned

**Observed.** 23 tests pass. Migration applies and reverses. The job renders a real day from the
real copy: `--show --date 2026-08-18` prints prompt 19 of 30 with Resend's unsubscribe token in
both bodies. `ruff check` and `ruff format --check` pass at CI's scope (`. ../.github`). Full
suite: **753 passed**, with 2 pre-existing `test_restore.py` failures that also fail with this
branch's code stashed out (the known pg_dump-16 issue).

**Reasoned, not observed.** **The Resend Broadcasts API has never been called.** The two-step
create-then-send shape, the response containing `id`, and the behaviour of
`{{{RESEND_UNSUBSCRIBE_URL}}}` in a broadcast are all implemented from documentation and are
unverified. The first live run is the first test of that, and it should be run with `--date`
against a real audience of one.

## Turning it on

Nothing sends while `MARKETING_EMAIL_ENABLED` is false, which is the default and the shipped
state. Open item 12 repeats in every line touching this work: **no marketing email before the P0
behavioural gate** — seven days of unforced daily use, which has not started.

The flag is deliberately separate from the credentials. `MAIL_API_KEY` and `RESEND_AUDIENCE_ID`
exist to make the *subscribe* route work; setting them must not also start mailing strangers.
