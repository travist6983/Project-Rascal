# RASCAL — Data Model

Postgres is the source of truth. SwiftData mirrors a subset locally as a cache.

Last updated: **Aug 3, 2026** — build-ready. This file is the authority for the initial
Alembic migration; if the code and this file disagree, the code is wrong.

---

## Tables

### `users`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `email` | text | nullable — Apple relay emails are unreliable |
| `display_name` | text | |
| `is_admin` | boolean | gates writes to the mission library |
| `notify_enabled` | boolean | default `false`; the client turns it on after the parent grants OS permission |
| `notify_local_time` | time (no zone) | default `19:00`; a wall clock read in the **child's** `family_timezone`, never the device's and never UTC |
| `last_sign_in_at` | timestamptz | nullable. Written by every path that proves the app ran — Apple sign-in, dev-login, **and a token refresh** — throttled to a day. **Null means never observed, not long ago.** Feeds D3's inactivity clock; nothing reads it yet. See the lifecycle section below |
| `marketing_consent` | boolean | default `true`. Win-back email only; needs a working unsubscribe when there is email to unsubscribe from |
| `transactional_consent` | boolean | default `true`. Deletion warnings, which send regardless of the marketing lane. **Two fields and never one flag**, per D3a — and not settable through the API |
| `email_deliverable` | boolean | default `true`. **Not a third consent lane** — the two above are what the parent *chose*, this is whether the channel physically *works*. A private relay can be switched off from Apple's Settings at any time and mail is then never forwarded again, with no bounce and no error; D3's hard stop is that deletion may not fire without a notice confirmed delivered, so without this the silence is indistinguishable from success. Written **only** by Apple's `email-disabled`/`email-enabled` notifications, never by a client. Read by phase 38 |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

### `credentials`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | |
| `provider` | text | `apple` \| `google` \| `password` \| `email`. `password` is **dead** as of phase 52 — the dev fixture moved to `email` and its rows migrated — and stays permitted because removing a value from a CHECK is a migration that can only fail, for nothing |
| `subject_id` | text | provider's stable user identifier. For `email`, the lowercased address |
| `revoked_at` | timestamptz | nullable. A **soft** revocation, never a delete. Set by `DELETE /me/credentials/{id}` and by Apple's `consent-revoked`; cleared by signing in with the same subject again. Also the "added but not yet verified" state for an `email` credential |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | maintained by the `set_updated_at()` trigger |

Unique on `(provider, subject_id)`. Sign in with Apple is one row here — never the identity model itself.

**The unique constraint deliberately ignores `revoked_at`, and this is the load-bearing
decision in this table.** A revoked credential keeps holding its `(provider, subject_id)`, so a
later sign-in with the same subject matches *that row* and therefore that user. Putting
`revoked_at` in the key — or hard-deleting on revoke — would let the next sign-in mint a
**second** user and leave the archive behind the first one unreachable. That is the only
failure here the person it happens to cannot undo, and it is silent: they would see a working
app with an empty archive. It follows that **the lookup must not filter `revoked_at`** either;
the filter that looks obviously correct is the bug.

**`updated_at` and its trigger make `credentials` the odd one out** among the auth tables —
`refresh_tokens` and `idempotency_keys` have neither. It earns one because a revocation is a
change to a row that is otherwise write-once, and `updated_at` is the cursor clients sync on: a
revocation nothing can observe is a revocation nobody can act on.

**Nothing anywhere matches a credential on email address.** Linking is explicit, through
`POST /me/credentials` from inside a session. Two people share addresses, one person's Apple
relay address is not their Google address, and an archive of a childhood is not a thing to hand
over on a string comparison.

### `refresh_tokens`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | |
| `token_hash` | text | SHA-256 of the opaque token. The raw value is never stored. |
| `expires_at` | timestamptz | 30 days from issue |
| `revoked_at` | timestamptz | nullable — set on rotation or logout |
| `created_at` | timestamptz | |

Index on `token_hash`. Access tokens are stateless JWTs with a 15-minute life; refresh
tokens are opaque, server-side, and **rotate on every use** — presenting a refresh token
revokes it and issues a new pair. A revoked token being presented again means either a
race or a theft; treat it as a 401 and revoke the whole chain.

### `email_sign_in_tokens`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `credential_id` | uuid FK | `ON DELETE CASCADE`. **Keyed on the credential, not the user** — the link belongs to the *address*, so revoking that credential invalidates every outstanding link to it with no second statement |
| `token_hash` | text | SHA-256. The raw value exists in one email and never again — the same rule `refresh_tokens` follows, so a database dump is not a set of working keys |
| `purpose` | text | `verify` \| `sign_in`. **Only `verify` may clear `credentials.revoked_at`** — a sign-in link that could reactivate an address the parent removed would make Remove a suggestion rather than an action |
| `expires_at` | timestamptz | 15 minutes from issue |
| `consumed_at` | timestamptz | nullable. A timestamp rather than a boolean, so a replay can be told apart from a link that was never opened |
| `created_at` | timestamptz | |

Unique index on `token_hash`, which is the only way a token is ever looked up.

### `rate_limit_events`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `bucket` | text | `email:<address>` or `ip:<addr>`. Generic on purpose: a third limiter later is a new prefix, not a new table |
| `created_at` | timestamptz | |

Index on `(bucket, created_at)`. A fixed window, counted on read, with each bucket's expired
rows pruned by the same scan — so the table stays proportional to live traffic without a
scheduled job.

**In Postgres and not in memory, and that is not a preference.** There is more than one Fly
machine, so an in-process counter is per-process theatre: the real limit would be N times
looser than it reads and would reset on every deploy, while passing every test.

The alternative — a long-lived JWT with no server-side record — can't be revoked when I
lose a phone. This archive has my kid's face and voice in it. The extra table is worth it.

### `children`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `name` | text | |
| `birthdate` | date | drives every age computation |
| `avatar_key` | text | S3 key |
| `family_timezone` | text | IANA, e.g. `America/Detroit`. **The scheduler's definition of "today."** |
| `created_at` / `updated_at` | timestamptz | |

### `guardians`
| Column | Type | Notes |
|---|---|---|
| `user_id` | uuid FK | |
| `child_id` | uuid FK | |
| `role` | text | `parent` (read/write) \| `viewer` (read only) |
| `granted_at` | timestamptz | |
| `revoked_at` | timestamptz | nullable |

PK on `(user_id, child_id)`.

**This table is still the whole of authorization**, and phase 36 did not change that. `deps.require_child_access` reads `guardians` and only `guardians`, so accepting a household invite grants access by writing the rows that check already reads — there is no second code path and nothing to keep in sync. What phase 36 added is a way to *create* the second row (`POST /v1/invites/{token}/accept`), not a new way to be authorized.

**Removing a guardian is not specified.** `revoked_at` makes the access half a column write, but what happens to the entries they wrote — `entries.completed_by` records which parent answered — is undecided. `docs/decisions.md` open item 13.

### `families`
The household. Deliberately almost empty: it is an identity, not a record.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `created_at` / `updated_at` | timestamptz | |

`users.family_id` is **NOT NULL** — every user has a family, even a household of one. A nullable owner would mean every read of an entitlement needs a "what if there is not one" branch, and one of those branches eventually decides that missing means subscribed.

A family does **not** own children. `guardians` says who may reach a child and remains the only authorization input; a family exists so that D4's "one price for the whole household" has something to hang on.

### `entitlements`
What a household is entitled to. **One row per family, keyed on the family** — per D4 entitlement is a family-level attribute, never per-user and never per-child, so there is no shape of this table that can hold two opinions about one household.

| Column | Type | Notes |
|---|---|---|
| `family_id` | uuid PK FK | → families |
| `tier` | text | `free` \| `subscribed`, `text` + named CHECK |
| `payer_user_id` | uuid FK | nullable — a family can be `free` with nobody paying, and a lapsed family keeps the payer who lapsed so a win-back knows who to talk to |
| `lapsed_at` | timestamptz | nullable; null while subscribed |
| `updated_at` | timestamptz | |

**Nothing in this codebase writes `tier`.** D5 reserves that for App Store Server Notifications V2, which is phase 37. Until then a family becomes `subscribed` only by the hand-run statement in `docs/runbook-deploy.md`. The absence of a writer is the design, not an oversight — the device never decides whether a household is subscribed, for the same reason it never decides what day it is.

**`last_sign_in_at` is deliberately not on this table.** It is a denormalisation of `users.last_sign_in_at` that must never be written independently, and a column whose only correct value is a `MAX` over another table — before anything computes that `MAX` — is a column that drifts.

### `guardian_invites`
An offer to join a household, good for seven days.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `family_id` | uuid FK | the household being joined |
| `invited_by_user_id` | uuid FK | |
| `token_hash` | text | **SHA-256. The raw token is never stored** — the same rule `refresh_tokens` and `email_sign_in_tokens` follow |
| `email` | text | nullable — an invite may be a bare link |
| `role` | text | `parent` \| `viewer`, `text` + named CHECK. **Only `parent` is issuable**; `viewer` is phase 30 and iceboxed, and `constants.ISSUABLE_INVITE_ROLES` is what the route validates against |
| `expires_at` | timestamptz | 7 days |
| `accepted_at` / `accepted_by_user_id` | | nullable |
| `revoked_at` | timestamptz | nullable |
| `created_at` / `updated_at` | timestamptz | |

Unique index on `token_hash`; index on `family_id`.

`accepted_at` and `revoked_at` are timestamps rather than booleans for the same reason `consumed_at` is on the sign-in token: a replay can be told apart from a link that was never used, and *when* somebody joined a household is worth having.

### `prompts`
The mission library. Content, not user data.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `kind` | text | `question` \| `photo` \| `video` \| `audio` \| `activity` \| `measurement` \| `letter` |
| `cadence` | text | `daily` \| `weekly` \| `monthly` |
| `completion_mode` | text | `did_it` \| `media` \| `text` |
| `body` | text | the prompt itself |
| `theme` | text | for rotation — see themes list below |
| `min_age_months` | int | inclusive |
| `max_age_months` | int | inclusive |
| `month_tags` | int[] | seasonal restriction, e.g. `{10,11,12}`. Empty = any month. |
| `source` | text | `seeded` \| `user` \| `llm` |
| `default_unlock_age` | int | nullable — letters default to sealed |
| `active` | bool | |
| `created_at` / `updated_at` | timestamptz | |

Index on `(kind, cadence, active, min_age_months, max_age_months)`.

### `assignments`
What the scheduler served on a given day.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `child_id` | uuid FK | |
| `user_id` | uuid FK | **NOT NULL for `question`, `mission`, `mission_b`; NULL for `weekly`, `monthly`, `letter`** — see below. Added by phase 36 |
| `prompt_id` | uuid FK | nullable if `custom_body` set |
| `custom_body` | text | nullable — parent-authored one-offs |
| `slot` | text | `question` \| `mission` \| `mission_b` \| `weekly` \| `monthly` \| `letter` |
| `assigned_on` | date | in family timezone |
| `expires_on` | date | `assigned_on + 14` |
| `status` | text | `pending` \| `done` \| `dismissed` \| `expired` |
| `completed_by` | uuid FK | nullable, → users |
| `created_at` / `updated_at` | timestamptz | |

**Two partial unique indexes, and they are what make the scheduler idempotent — reruns must be free.** Phase 36 replaced the single `uq_assignments_child_id_assigned_on_slot` with:

```sql
CREATE UNIQUE INDEX uq_assignments_daily  ON assignments (child_id, user_id, assigned_on, slot)
  WHERE slot IN ('question','mission','mission_b');
CREATE UNIQUE INDEX uq_assignments_shared ON assignments (child_id, assigned_on, slot)
  WHERE slot IN ('weekly','monthly','letter');
```

**Daily slots are served per guardian; shared slots are one per child.** Two parents each get their own `question`, `mission` and `mission_b`, and either of them completing a `weekly`, `monthly` or `letter` clears it for both. `ck_assignments_user_id_by_slot` enforces the two shapes, so a row written with the wrong one fails at the INSERT rather than becoming something nothing will read.

**Why two partial indexes rather than one wider one, and this is the part that would silently break if somebody later "simplified" it:** Postgres treats NULLs as distinct in a unique index. A single `UNIQUE (child_id, user_id, assigned_on, slot)` would let the scheduler write an unlimited number of shared-slot rows for one child on one day — every one of them has a NULL `user_id`, and NULL never equals NULL. Idempotency would fail **silently**, on exactly the slots (weekly, monthly) nobody checks daily. The shared index therefore does not mention `user_id` at all, which keeps the old guarantee intact for the rows that kept the old shape.

**Anything using `ON CONFLICT` against either index must repeat its `WHERE` clause.** Postgres will not infer a partial unique index from the column list alone; without the predicate the insert raises *"there is no unique or exclusion constraint matching the ON CONFLICT specification"*. `services/scheduler.py` carries both predicates for this reason.

**On `slot` values.** `mission` is **photo-only** as of migration `0008`, and `mission_b` takes the video, audio and activity kinds it used to share. The slot narrowed without being renamed, so **rows written before `0008` hold non-photo prompts in `mission` and are correct for the day they were served** — see `docs/decisions.md`. A slot name is an identifier for a position in the day, not a description of the kind that fills it.

### `entries`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | client-generated UUID for offline creation |
| `child_id` | uuid FK | |
| `assignment_id` | uuid FK | **nullable — freeform entries are first-class** |
| `author_id` | uuid FK | → users |
| `occurred_at` | timestamptz | when it happened |
| `created_at` | timestamptz | when it was logged. **Never conflate these.** |
| `child_age_months` | int | computed at write from `occurred_at` − birthdate, then stored |
| `title` | text | nullable |
| `body` | text | nullable |
| `entry_type` | text | denormalized from the prompt for filtering |
| `unlock_at_age` | int | nullable. Sealed until the child is this age. |
| `visibility` | text | `shared` \| `private`. **NOT NULL, defaults `shared`.** Who may read it — see below. Orthogonal to `unlock_at_age`. |
| `deleted_at` | timestamptz | soft delete |
| `updated_at` | timestamptz | sync cursor |
| `search_vector` | tsvector | **stored generated** — `setweight(title, 'A') \|\| setweight(body, 'B')`, config `english` |

Indexes: `(child_id, occurred_at desc)`, a functional index on `(child_id, extract(month from occurred_at), extract(day from occurred_at))` for On This Day, and a GIN index on `search_vector`.

### `media`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | client-generated |
| `entry_id` | uuid FK | |
| `s3_key` | text | |
| `thumb_key` | text | |
| `kind` | text | `photo` \| `video` \| `audio` |
| `captured_at` | timestamptz | from EXIF where available |
| `duration_seconds` | int | nullable |
| `bytes` | bigint | |
| `transcript` | text | nullable — written back from on-device transcription |
| `caption` | text | nullable — written back from on-device captioning |
| `upload_status` | text | `pending` \| `complete` \| `failed` |
| `created_at` / `updated_at` | timestamptz | |
| `search_vector` | tsvector | **stored generated** — `setweight(transcript, 'B') \|\| setweight(caption, 'C')` |

Indexes: `(entry_id)`, and a GIN index on `search_vector`.

Both `search_vector` columns are **generated, not trigger-maintained**. A generated column
cannot drift: there is no window in which the row is written and the vector is not, and no
backfill to remember after a bulk `UPDATE`. The text search configuration is spelled out as
`english` rather than left to `default_text_search_config`, because a generated column's
expression must be `IMMUTABLE` and the one-argument `to_tsvector` reads a GUC.

### `tags` / `entry_tags`
`tags`: `id`, `child_id`, `name`, `created_at`.
`entry_tags`: `entry_id`, `tag_id`, `source` (`user` \| `device_ai`).

Keeping `source` on the join lets you distinguish tags you chose from tags the on-device model extracted, and lets you re-run extraction without clobbering yours.

### `devices`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | one user, many devices — phone today, iPad later |
| `token` | text | the APNs device token |
| `platform` | text + CHECK | `ios` |
| `environment` | text + CHECK | `sandbox` \| `production` — **not optional** |
| `last_seen_at` | timestamptz | written by the registration call, not the trigger |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `revoked_at` | timestamptz | nullable — the soft delete |

Unique on **`(token, environment)`**, not on `token`. A sandbox token and a production token
are different tokens addressed to different APNs hosts, and the same string can legitimately
be both; sending to the wrong host fails silently, which is the usual reason push works in
development and not in TestFlight. Registering is an upsert on that pair, so a client calling
it on every launch produces one row, and a token that re-registers after sign-out comes back
live rather than stranded.

### `notification_sends`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | |
| `child_id` | uuid FK | whose day the notification was about |
| `assignment_id` | uuid FK | nullable, `ON DELETE SET NULL` — the deep link |
| `notification_date` | date | **in the child's `family_timezone`**, not UTC |
| `device_count` | integer | live tokens it was addressed to |
| `delivered_count` | integer | how many APNs accepted |
| `created_at` | timestamptz | |

Unique on **`(user_id, notification_date)`**, and that index *is* the product guarantee: one
notification per user per day. The row is claimed with `ON CONFLICT DO NOTHING` before
anything reaches APNs, exactly the way `assignments` makes the scheduler free to re-run, so
two overlapping runs cannot both decide to send.

No `updated_at` and no soft delete — this is a system ledger rather than user data. It never
syncs to a client and there is nothing here to restore, which is the same reasoning that
leaves `refresh_tokens` and `idempotency_keys` without them.

---

## Implementation conventions

These apply to every table above. They're here so the migration doesn't have to guess.

**Constrained-value columns are `text` with a CHECK constraint, never Postgres enums.**
`status`, `kind`, `cadence`, `completion_mode`, `role`, `source`, `slot`, `provider`,
`upload_status`, `visibility`. Adding a value to a Postgres enum inside a transaction-safe migration is
a chore; adding one to a CHECK is a one-line `ALTER`. Name every constraint explicitly
(`ck_assignments_status`) so migrations can find it later.

**`updated_at` is maintained by a database trigger, not by application code.** One
`set_updated_at()` function, attached to every table that has the column. A bulk `UPDATE`
run from `psql` at 11pm has to move the sync cursor too, or a client silently misses rows.

**Every index and constraint is named.** Alembic autogenerate against unnamed constraints
produces migrations that can't be reversed cleanly.

**The On This Day index is functional and must be written as raw SQL** in the migration —
SQLAlchemy's `Index()` won't express it the way Postgres needs:

```sql
CREATE INDEX ix_entries_child_month_day ON entries (
    child_id,
    (extract(month from occurred_at)),
    (extract(day from occurred_at))
);
```

**Soft-deletable tables** are `entries` and `media`. Every read path filters
`deleted_at IS NULL` except `/sync`, which must return deleted rows so clients can
propagate the deletion.

**UUIDs are generated client-side for `entries` and `media`** and server-side for
everything else. Both are `uuid` columns; the difference is only who calls `uuid4()`.

---

## Fields that matter more than they look

**`occurred_at` vs `created_at`** — the entire backdating story. A photo from 2023 added tonight has `occurred_at` in 2023 and `created_at` today. Every timeline query sorts by `occurred_at`; every sync query filters on `updated_at`.

**`child_age_months`** — stored, not computed on read. You'll browse by "age 4," and you don't want the whole archive to shift if you correct a birthdate typo.

**`visibility`** — settled Aug 14, 2026 by the owner, and specified here before any of it is built
because the column is the part that cannot be retrofitted cheaply. Three decisions:

*Per-entry, with a per-kind default.* The column lives on the entry, and the kind supplies the
value at creation time — `letter` defaults to `private`, everything else to `shared`. Per-kind
alone was the cheaper design and is wrong for the case that matters: the sensitive entry is
usually an ordinary question answered honestly on a bad week, and a scheme that can only hide
*categories* cannot hide that one. Asking on every save was the other option and is worse for a
different reason — it puts a decision on the screen the app spends its whole design budget keeping
to one tap.

*A viewer sees everything not marked private.* Default `shared`, so an invite shows an archive.
Default-private was considered and rejected on the same grounds the seal was: an invited
grandparent who opens an empty archive concludes the app is broken, and the alternative is
somebody hand-marking four years of entries before the invite is worth sending. The trade is
stated plainly rather than hidden: **a parent who wants something withheld has to withhold it**,
and the app's job is to make that reachable on the entry itself rather than in a settings screen
nobody visits.

*It is orthogonal to `unlock_at_age`.* They are different questions — a seal is **when** an entry
can be read, visibility is **who** may read it — and collapsing them would mean a seal silently
overriding an explicit `shared`. So a sealed letter is hidden from everyone including the parent
until the age, and *then* obeys its visibility like anything else. Two columns, two questions, no
precedence rule to remember.

**Nothing reads this column yet, and that is deliberate.** No route can create a `viewer` row, so
until guardian invites exist the only guardian is a `parent` and every read returns everything.
The column is specified now because it is a migration on the one table that will be largest, and
because the invite phase should not also be the phase that invents the model. Write paths set it
from the kind default from the day it lands; read paths filter on it when there is a role that
needs filtering.

**The column is not in the database, and after Aug 16, 2026 it will not be for a while.** Phase 30
was iceboxed by the owner and this spec was iced with it, having no other consumer — so there is no
migration, no column on `entries`, and no code reading or writing it. **This section is a
specification, not a description of the schema**, which is the one way a reader could be misled by
it; everything else in this file describes tables that exist. It stays here rather than moving to a
scratch document because the reason it was written early is unchanged: retrofitting visibility onto
an archive that already has guardians is a migration over user content.

**`unlock_at_age`** — nullable, and impossible to retrofit cleanly at 500 entries. Letters written *to* him — the money letter, the who-you-are-right-now letter — set this. Everything else leaves it null.

**`completion_mode` on prompts** — this is what keeps "never let go of a hug first" a legitimate mission. Any schema that requires media for completion loses half the product.

**`assignment_id` nullable on entries** — not everything worth keeping came from a prompt.

**`family_timezone` on children** — without it, the 5am scheduler hands you tomorrow's mission at 9pm.

---

## Themes (for rotation)

The scheduler avoids serving two prompts from the same theme back to back.

`voice` · `physical-affection` · `their-words` · `everyday-ordinary` · `skills-firsts` · `relationships` · `humor` · `food` · `sleep-routine` · `outdoors` · `making-building` · `fears-comfort` · `growth-measurement` · `letters-forward` · `seasons-holidays` · `me-as-a-parent`

---

## Scheduler logic

Runs 5am in each child's `family_timezone`.

1. Expire assignments where `expires_on < today` and `status = 'pending'`.
2. For each active child, for **all three** daily slots in order — `question`, then `mission`, then `mission_b`:
   - Candidate pool = active prompts where cadence matches, **the kind is one this slot draws** (`question` → question; `mission` → photo; `mission_b` → video, audio, activity), `child_age_months` falls inside the age window, and `month_tags` is empty or contains the current month.
   - Exclude any prompt suppressed for this child, before selection begins rather than at any rung of the ladder below.
   - Exclude any prompt served to this child in the last 180 days.
   - Exclude any theme served in the previous 2 days **including today's earlier picks** — each assignment is inserted before the next slot is selected, so the third pick sees the first two.
   - Weighted random pick; a prompt this child has never seen is weighted 3 to 1 against one they have.
3. Saturday: also fill slot `weekly`.
4. First of the month: also fill slot `monthly` (measurement).
5. Fifteenth of the month: also fill slot `letter`.
6. Insert with `ON CONFLICT (child_id, assigned_on, slot) DO NOTHING`.

Steps 3–5 fire **on top of** step 2 and never in place of it, so the worst day the calendar can produce — a Saturday that is also the 15th — is five assignments. A slot whose pool is empty is left empty and logged; it is never filled from another kind's pool.

If the candidate pool empties (small library, narrow age band), relax the 180-day cooldown to 90 before relaxing the age window. Relax the age window last — an age-inappropriate
prompt is worse than a repeat.

### Invocation

The scheduler takes `as_of_date` as an argument and defaults to "now." It never reads the
clock from inside the selection logic. That's what makes it testable, backfillable, and
re-runnable for a date I slept through.

`assigned_on` is the date **in the child's `family_timezone`**, derived from the run
instant. Two children in different zones can get different `assigned_on` values from the
same UTC moment, and that's correct.

Selection is split into a pure function — candidate pool in, one prompt out — and an
impure runner that writes rows. The pure half is where the cooldown, theme rotation, and
age-window rules live, and it's the half worth unit tests.

---

## Sync contract

- Client generates UUIDs for `entries` and `media` so records exist offline before the server sees them.
- Push carries an idempotency key per record; retries are safe.
- Pull is `GET /sync?since={updated_at}` returning changed rows across entities plus a new cursor.
- Conflict resolution: last write wins on `entries`. A mission completed by either parent completes for both.
- Soft deletes sync as rows with `deleted_at` set, never as absences.


## `prompt_suppressions`

| column | type | notes |
|---|---|---|
| `child_id` | uuid | PK, FK → `children.id` on delete cascade |
| `prompt_id` | uuid | PK, FK → `prompts.id` on delete cascade |
| `reason` | text, null | Free text. Deliberately not a constrained set — the useful reasons are the ones nobody thought to enumerate. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | `set_updated_at()` trigger |
| `revoked_at` | timestamptz, null | The soft delete. Withdrawing a suppression, not deleting data. |

Composite primary key on `(child_id, prompt_id)`: one row per pair ever, which is what makes
`POST` idempotent and re-suppression a revival rather than a duplicate.

**Suppression outranks every relaxation rule.** It is enforced in
`services/scheduler._candidates` — the single query both the nightly scheduler and the read path
load candidates through — so a suppressed prompt is absent from the pool that the relaxed
cooldown, the dropped theme rotation, the dropped age window and the final "anything at all"
fallback each fall back to. There is no rung of the ladder that can resurrect one.

Index `ix_prompt_suppressions_child_id_prompt_id_revoked_at` serves that exclusion subquery.

---

## PROPOSED — NOT IMPLEMENTED: monetization, lapse and deletion notices

**Almost none of this exists.** No table below has been created. It is written down so the shape is
settled before it is built — the decisions are D1–D6 in `docs/decisions.md` — and so the two things
that would be expensive to retrofit are decided first: the consent lanes and the per-channel
delivery record.

**Three columns on `users` are the exception and did ship, in phase 49 on Aug 16, 2026** —
`last_sign_in_at`, `marketing_consent` and `transactional_consent`, in migration
`0010_activity_and_consent`. They are listed with the live `users` table above. Nothing reads any
of them yet. They landed ahead of the phase that consumes them because **all three are cheap now
and expensive or impossible later**, and one of them is accumulating a record that cannot be
reconstructed. See "The activity clock landed early" below.

Everything else here modifies no existing table.

### Entitlement sits on the household, never on a user or a child

One row per family. **Not a column on `users`**: any guardian may be the payer, all guardians are
covered, and a per-user flag would make "is this family subscribed" a question with as many answers
as there are guardians. Per D4.

| Column | Type | Notes |
|---|---|---|
| `family_id` | uuid PK | the household — one entitlement per family, never per user or child |
| `tier` | text | `free` \| `subscribed`, `text` + a named CHECK per the constrained-value convention |
| `payer_user_id` | uuid FK | nullable — who is paying now. Nullable because a family can be `free` with nobody paying |
| `lapsed_at` | timestamptz | nullable; null while subscribed. Set when the entitlement flips to `free` |
| `last_sign_in_at` | timestamptz | most recent sign-in by **any** guardian — a `MAX` over `users.last_sign_in_at`, which **exists now** and is the source of truth. This column is a denormalisation for the eligibility read, and must never be written independently of it |
| `updated_at` | timestamptz | maintained by the `set_updated_at()` trigger, never by application code |

**The deletion eligibility date is computed on read and never stored.**

```
eligible_at = max(lapsed_at + 24 months, last_sign_in_at + 12 months)
```

Both clocks move. A stored deadline written the day a family lapsed would be wrong the moment
somebody opened the app, and a wrong deadline in this particular table deletes photographs. Storing
it would also mean every sign-in rewriting a date somebody could read as a promise.

### Media carries its storage tier

A single column on `media`, **added and not backfilled into the definitions above**:

| Column | Type | Notes |
|---|---|---|
| `storage_tier` | text | `hot` \| `archive`, `text` + named CHECK. Originals move to `archive` at 90 days lapsed; **thumbnails always stay `hot`** so the timeline is instant and browsable whatever the tier |

Search is unaffected: it runs against transcripts and captions in Postgres, which never move.
Full-resolution retrieval from `archive` needs a restore of roughly an hour, or an active
subscription. **That is a property of the storage tier and not a penalty**, and no copy anywhere may
frame it as one.

### The activity clock landed early, and on `users` rather than here

**Phase 49 shipped `users.last_sign_in_at` before this entitlement table existed**, and the reason
is that it is the one column in this section that **cannot be backfilled**. A lapse date can be
reconstructed later from the payment rail, which keeps its own history. *When a parent last opened
the app* exists nowhere else — not in `entries`, which records when somebody wrote rather than when
they looked, and not in `refresh_tokens`, which are revoked and pruned. Every day it did not exist
was a day of the record simply gone, and the households generating it are using the app now.

Putting it on `users` is a refinement of the row above rather than a contradiction of it. The
family-level value is specified as *"most recent sign-in by any guardian"*, which is a `MAX` over
exactly this per-user column — so per-user is strictly more information than the entitlement row
needs, and the entitlement's copy is a denormalisation of it. The household entity belongs to phase
37, which is blocked on an App Store Connect action; waiting for it would have meant waiting on an
account action to start recording history that cannot be recovered afterwards.

**Every path that proves the app ran writes it — including a token refresh, and that is
load-bearing.** An app in daily use rotates its refresh token and never performs a fresh credential
sign-in again, so recording only `POST /auth/apple` would leave the most engaged households looking
dormant against the twelve-month clock and bring their eligibility date due while they were still
writing entries. Writes are throttled to a day's granularity, because an active app rotates four
times an hour and this feeds a twelve-month clock.

**Null means never observed, not long ago.** Every user created before the migration has null.
Treating it as ancient would make the oldest accounts the first eligible for deletion, which is the
precise opposite of correct, so every read must handle null explicitly.

### The two consent lanes are two fields, from day one

**Shipped in phase 49** on `users`, and deliberately **not one flag with two meanings**:

| Column | Type | Notes |
|---|---|---|
| `marketing_consent` | boolean | win-back only. Requires an unsubscribe and must honour it |
| `transactional_consent` | boolean | deletion warnings. Sends regardless of the marketing field |

Untangling one flag into two later, under a GDPR or CCPA request, is the failure this shape exists
to avoid. It costs one extra column now.

Both default `true` — the soft opt-in D3a describes, and what makes deletion warnings sendable to
every existing user. **Neither is settable through the API and `transactional_consent` in
particular must never become so**: a user who could switch it off would silence the deletion warning
and leave the timer running, which converts a safety interlock into a quiet way to lose an archive.
~~Nothing sends email today, so neither lane reaches anybody yet.~~ **Corrected Aug 16, 2026: that
sentence was true when it was written and stopped being true in the same week.** Phase 56 shipped
`services/mail.py` and phase 57 wired it to `POST /auth/email/start` and
`POST /me/credentials/email`, so two routes do call `send()`. **What is still true is the part that
matters here: no real mail has been delivered to anybody**, because `MAIL_PROVIDER` is `console` in
every environment and the console provider prints to stdout without opening a socket. **Neither
consent lane has reached a parent, and neither is consulted by the two routes that send** — a
sign-in link is not a marketing or a lifecycle message and reads no consent column. The distinction
is worth keeping straight, because "nothing is wired" and "nothing is delivered" invite very
different decisions about adding a second sender.

**Resend is the sender for both lanes**, per D8 — one account, one domain authentication, a
`stream` argument of `marketing | transactional` on the port distinguishing them. Phase 60 replaces
the Postmark adapter; the two consent columns above are unaffected by that swap, because they are
read by callers and the port has never read them.

**The `email` channel outcome in `lifecycle_notice_deliveries` will be written from Resend's
delivery webhook.** That is a dependency phase 38 inherits, named here rather than designed here —
see the notices section below.

### The marketing list is provider-held, and there is no `subscribers` table

**Settled Aug 16, 2026 by the owner, per open item 12(4) and D8. No table exists and none is
specified here yet** — this note follows the precedent `visibility` set above: written into this
file so that picking it up later is a build against a finished spec rather than a fresh design,
with the difference stated plainly rather than left for a reader to discover.

**Resend holds the list.** Double opt-in, suppression, unsubscribe and sending reputation are all
theirs; `POST /v1/subscribe` is a thin forward that stores nothing. A subscriber is **not** a
`users` row and has no row anywhere in this schema.

**The named trigger for bringing it in-house is the first moment a subscriber can also be a user**,
which is post-launch. Migrating a list is a CSV export; migrating a half-built consent system is
not, which is the whole reason for starting on the provider's side.

**What would need specifying when it returns** — recorded now, while the reasoning is fresh:

- **Identity.** A subscriber has no `users` row, so the table needs its own key. Email is the
  natural one and is also the thing that changes.
- **The dedup problem, which is the hard part and is not solved by adding a table.** Sign in with
  Apple private relay means a signed-up parent's `users.email` may never match the address they
  gave the marketing site, so the same human can be two records with no reliable join between them.
  Any in-house design has to say what happens when one of them unsubscribes.
- **Consent, and how it relates to `users.marketing_consent` above.** Two systems that can disagree
  about one person is the failure D3a's two-column shape exists to avoid; a `subscribers` table
  reintroduces it at a different layer unless the relationship is decided first.
- **Soft deletes and `updated_at`**, per the standing rules, and whether an unsubscribe is a
  `deleted_at` or a consent flag — they are not the same thing and only one of them survives a
  re-subscribe.

Nothing above is a decision. It is the list of decisions the item will owe.

### Notices, and delivery proven per channel

Two tables, because a notice is one decision and a delivery is one attempt per channel.

`lifecycle_notices` — one row per notice sent to a family:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | server-generated |
| `family_id` | uuid FK | |
| `kind` | text | `winback` \| `deletion_warning`, `text` + named CHECK |
| `scheduled_for` | text | which notice this is — `t_minus_90`, `t_minus_30`, `t_minus_7` for warnings |
| `created_at` | timestamptz | |

`lifecycle_notice_deliveries` — one row per channel per notice:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `notice_id` | uuid FK | → `lifecycle_notices` |
| `channel` | text | `in_app` \| `push` \| `email`, `text` + named CHECK |
| `outcome` | text | `delivered` \| `failed` \| `suppressed`, `text` + named CHECK |
| `created_at` | timestamptz | |

**This is why the second table exists.** Sign in with Apple private-relay forwarding can be switched
off by the user at any time, which kills the email channel silently and tells the sender nothing. So
a notice goes out on three channels and each records its own outcome, and **deletion may not fire
unless at least one channel recorded `delivered`.** An account that cannot be reached is kept
indefinitely and flagged for manual review — never deleted on a timer that assumed the notice
arrived.

**The `email` channel's `outcome` comes from Resend's delivery webhook, and that is a dependency
phase 38 inherits rather than one it may skip.** Named here, not designed here: this file does not
specify the webhook route, its signature verification, or how a provider event maps onto
`delivered | failed | suppressed`. What it does say is that **`delivered` on the email channel must
mean the provider confirmed delivery, never that the send call returned without raising.** The two
are far apart — an accepted API call is a queued message, and D3's hard stop lets deletion proceed
once one channel records `delivered`. Treating "no exception" as proof of delivery would let an
archive be deleted on the strength of a message that bounced.

`notification_sends` is **not** this table and must not be extended into it. That one is unique on
`(user_id, notification_date)` and that index *is* the daily-notification product guarantee; a
lifecycle notice is a different thing on a different cadence, and folding them together would break
the guarantee to save a table.
