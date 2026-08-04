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
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

### `credentials`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | |
| `provider` | text | `apple` \| `google` \| `password` |
| `subject_id` | text | provider's stable user identifier |
| `created_at` | timestamptz | |

Unique on `(provider, subject_id)`. Sign in with Apple is one row here — never the identity model itself.

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
| `prompt_id` | uuid FK | nullable if `custom_body` set |
| `custom_body` | text | nullable — parent-authored one-offs |
| `slot` | text | `question` \| `mission` \| `weekly` \| `monthly` |
| `assigned_on` | date | in family timezone |
| `expires_on` | date | `assigned_on + 14` |
| `status` | text | `pending` \| `done` \| `dismissed` \| `expired` |
| `completed_by` | uuid FK | nullable, → users |
| `created_at` / `updated_at` | timestamptz | |

**Unique index on `(child_id, assigned_on, slot)`.** This is what makes the scheduler idempotent — reruns must be free.

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

---

## Implementation conventions

These apply to every table above. They're here so the migration doesn't have to guess.

**Constrained-value columns are `text` with a CHECK constraint, never Postgres enums.**
`status`, `kind`, `cadence`, `completion_mode`, `role`, `source`, `slot`, `provider`,
`upload_status`. Adding a value to a Postgres enum inside a transaction-safe migration is
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

**`unlock_at_age`** — nullable, and impossible to retrofit cleanly at 500 entries. Letters written *to* him — the money letter, the who-you-are-right-now letter — set this. Everything else leaves it null.

**`completion_mode` on prompts** — this is what keeps "never let go of a hug first" a legitimate mission. Any schema that requires media for completion loses half the product.

**`assignment_id` nullable on entries** — not everything worth keeping came from a prompt.

**`family_timezone` on children** — without it, the 5am scheduler hands you tomorrow's mission at 9pm.

---

## Themes (for rotation)

The scheduler avoids serving two prompts from the same theme back to back.

`voice` · `physical-affection` · `his-words` · `everyday-ordinary` · `skills-firsts` · `relationships` · `humor` · `food` · `sleep-routine` · `outdoors` · `making-building` · `fears-comfort` · `growth-measurement` · `letters-forward` · `seasons-holidays` · `me-as-a-parent`

---

## Scheduler logic

Runs 5am in each child's `family_timezone`.

1. Expire assignments where `expires_on < today` and `status = 'pending'`.
2. For each active child, for slot `question` and slot `mission`:
   - Candidate pool = active prompts where cadence matches, `child_age_months` falls inside the age window, and `month_tags` is empty or contains the current month.
   - Exclude any prompt served to this child in the last 180 days.
   - Exclude the theme served in the previous 2 days.
   - Weighted random pick.
3. Saturday: also fill slot `weekly`.
4. First of the month: also fill slot `monthly` (measurement).
5. Insert with `ON CONFLICT (child_id, assigned_on, slot) DO NOTHING`.

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
