# RASCAL — Agent decisions log

Judgment calls made while building the backend, one line each, with the reason. Settled
decisions from `docs/decisions.md` are not repeated here; this file records only choices
that file left open.

## M0 — Skeleton and tooling

- **The five spec files were at the repo root, not in `docs/`.** Moved them into `docs/`
  with `git mv` rather than stopping — the task's own repo layout puts them there, and the
  history is preserved.
- **psycopg 3 as the driver, not asyncpg.** One `postgresql+psycopg://` URL drives both the
  async application engine and Alembic's sync engine, so there is exactly one connection
  string and no async Alembic template to maintain.
- **Async SQLAlchemy throughout.** FastAPI plus `pytest-asyncio` and `httpx.AsyncClient` are
  async end to end already; a sync session would mean a threadpool hop on every request.
- **`.env` lives at the repo root, not in `api/`.** The Makefile, `docker-compose.yml`, and
  the app all read one file. `rascal.config` resolves it by walking up from the package.
- **Every `uv` command runs from `api/`.** `api/pyproject.toml` is the project root *and* the
  ruff and pytest config root, so running from the repo root would silently ignore both.
- **Postgres on host port 5433.** Straight from the task; keeps a locally installed 5432 usable.
- **`sqlalchemy.url` is absent from `alembic.ini`.** `alembic/env.py` reads `DATABASE_URL`
  through `rascal.config`, so a connection string can only come from one place.
- **Tests own a separate `<dbname>_test` database**, dropped and rebuilt once per session by
  running the real migrations, then truncated between tests. A dev database is never dropped.
- **Tests truncate before each test rather than after.** A failing test leaves its rows
  behind for inspection, and no test can pass on a neighbour's leftovers.
- **A `NullPool` engine per test.** `pytest-asyncio` gives each test its own event loop, and
  a pooled connection opened on a closed loop is a hang waiting to happen.
- **Structured logging is a JSON-lines formatter in `logging_config.py`.** The roadmap allows
  no observability beyond structured logging, and this is the whole of it.
- **`Settings` carries a few tuning constants** (token TTLs, presign TTL, multipart
  threshold, expiry days) that the specs state as prose. Naming them once beats scattering
  literals, and tests can reason about them.

## M1 — Schema and migrations

- **`refresh_tokens` added** as the task instructed — rotating server-side tokens so a lost
  phone can be cut off. `docs/data-model.md` already documents the table; the migration
  builds it.
- **`idempotency_keys` added** (`user_id` + `key` PK, endpoint, stored status and body).
  `POST /entries` must return the original 201 byte-for-byte on a replay and `POST /sync/push`
  carries a key per record; neither is possible without persisting the original response.
- **`media.s3_upload_id` added.** S3 hands back a multipart upload id at initiation and needs
  it again to complete, and `POST /media/{id}/complete` takes only etags — so the server has
  to remember it.
- **`prompts.content_hash` added.** The seed loader is keyed on a stable hash of
  `(kind, cadence, body)`; storing it with a unique index makes re-seeding an upsert rather
  than a scan.
- **The On This Day functional index is pinned to UTC** —
  `extract(month from occurred_at AT TIME ZONE 'UTC')`. Postgres rejects the spec's literal
  SQL on a `timestamptz` column because the result depends on the session TimeZone and so is
  not IMMUTABLE. `GET /children/{id}/moments` extracts identically, so index and query agree.
- **`entry_type` is the seven prompt kinds plus `text`.** Freeform entries have no prompt to
  denormalize from, and the contract's own example body sends `"entry_type": "text"`.
- **`entry_tags` gained `updated_at` and `deleted_at`, `tags` gained `updated_at`.**
  `/sync` needs a cursor on tag data and untagging has to arrive as a row with `deleted_at`
  set — a client cannot infer a removal from an absence. `tags` rows themselves are never
  deleted, so `tags` has no `deleted_at`.
- **The `/sync` `tags` array carries entry-tag links, not bare tags** — `entry_id`, `tag_id`,
  `name`, `source`, `updated_at`, `deleted_at`. The link is the thing that changes; a bare
  tag list would not let a client reconstruct which entry lost which tag.
- **`guardians`, `credentials`, and `refresh_tokens` have no `updated_at`.**
  `docs/data-model.md` is explicit about their columns and is the authority for this
  migration. Their mutations (revocation) are recorded by dedicated timestamps instead.
- **`theme` is plain text with no CHECK.** The constrained-column list in
  `docs/data-model.md` does not include it, and the library will grow themes — a new theme
  should be seedable without a migration.
- **Named CHECK constraints follow the `ck_<table>_<column>` convention** produced by the
  metadata naming convention, which is exactly the `ck_assignments_status` form the spec asks
  for.
- **Extra indexes beyond the spec:** `ix_assignments_child_id_status_assigned_on` (the
  `/today` and expiry queries), `ix_media_entry_id` and `ix_entry_tags_tag_id` (foreign keys
  Postgres does not index for you), `uq_tags_child_id_name` (tags are per child).

## M2 — Prompt seeding

- **The markdown-to-YAML converter lives at `api/scripts/mission_library_to_yaml.py`.** The
  task calls it a one-time conversion, but `docs/mission-library.md` tells you to regenerate
  the YAML after adding prompts — so it is a committed, re-runnable script rather than a
  throwaway. It is the only code in the repo that reads markdown, and it never runs at
  request time.
- **113 prompts convert from the library**, against the "~105" in the doc's header: 30
  question, 23 photo, 12 video, 12 audio, 25 activity, 3 measurement, 8 letter. (Kind counts
  cut across cadence — the weekly and monthly tables contribute activity, video, photo, and
  measurement rows.)
- **The coverage table at the bottom of `docs/mission-library.md` under-counts four kinds.**
  Eligible at 48 months, the seed file actually holds question 30 (doc 30), photo 22 (doc
  "~19", or 18 once seasonal prompts are filtered), video 11 (doc 9), audio 11 (doc 11),
  activity 16 (doc 15), weekly 10 (doc 9), monthly 4 (doc 4), letter 8 (doc 8). The doc was
  written before the last few prompts were added. The test asserts the exact figures *and*
  treats the doc's table as a floor, so drift is caught in either direction without
  hard-coding a stale number.
- **`content_hash` joins `(kind, cadence, body)` with unit separators (`\x1f`)** so a body
  containing the delimiter cannot collide with a different kind or cadence.
- **The upsert's `DO UPDATE` carries a `WHERE ... IS DISTINCT FROM` guard.** Without it every
  re-seed would touch all 113 rows, fire the `updated_at` trigger, and make every client
  resync the whole library for nothing.
- **`body` is not in the updatable field set.** It is part of the identity hash, so an edited
  body is a new prompt — which is correct: the old one may already have assignments and
  entries pointing at it.
- **The loader validates the YAML before touching the database**, so a bad seed file fails
  with a line reference rather than a CHECK constraint violation halfway through.
- **A test regenerates the YAML from the markdown and compares.** Drift between the authoring
  surface and the seed file is a silent content bug otherwise.

## M3 — Auth and authorization

- **Everything mounts under `/v1`**, per `docs/api-contract.md` ("Base: `/v1`",
  "`GET /health` … the only route outside `/v1`"). So the contract's `POST /auth/apple` is
  served at `/v1/auth/apple`.
- **`dev-login` uses `provider = "password"` with the email as `subject_id`.** It is a local
  account, so the password provider is the honest slot for it; using `apple` would put a
  fake Apple subject in the table. No password is stored because none is checked — the route
  only exists when `ENVIRONMENT == "local"`.
- **`authorization_code` on `POST /auth/apple` is accepted and ignored.** The contract lists
  it, but RASCAL verifies the identity token directly and never calls Apple's token
  endpoint. Documented in the schema rather than silently dropped.
- **A repeat Apple sign-in only fills gaps in `email` and `display_name`.** Apple sends the
  name exactly once, at first authorization; a later login must not blank it.
- **An unknown `kid` earns exactly one JWKS refetch** before failing. Apple rotates keys
  without warning, and a cached key set would otherwise lock everyone out until the TTL.
- **Refresh-token reuse commits the chain revocation before raising.** The request-scoped
  session rolls back on an exception, so without an explicit commit the revocation — the
  entire point of detecting reuse — would be discarded with the error response.
- **Revoking an unknown or already-revoked token on logout is a no-op, not an error.** A
  client retrying a logout should not see a failure.
- **`deps.py` exposes five resolvers over one check.** `require_child_access` is the whole
  of the authorization logic; `child_access` (path), `child_access_from_query`,
  `child_access_from_body`, `entry_access`, `media_access`, and `assignment_access` differ
  only in where they find the child id. Handlers never check ownership themselves.
- **A guardian row pointing at a missing child is a 404, not a 403.** That is a data bug
  rather than a permission problem, and conflating them would hide it. Every ordinary
  permission failure — stranger, viewer attempting a write, revoked guardian, unknown child
  id — is 403 `not_authorized`.
- **`POST /children/{id}/guardians` is not implemented.** `docs/api-contract.md` marks it P2
  and the guardian invite flow is explicitly out of scope for this task.
- **`GET /children` returns `age_months` alongside `role`**, computed in the child's
  `family_timezone`. The client would otherwise have to compute an age, and rule 1 says the
  server owns that.

## M4 — Core endpoints

- **Thumbnail and poster-frame generation is out of scope.** `POST /media/{id}/complete`
  marks the row and leaves `thumb_key` null, per the task and `docs/decisions.md`.
- **`POST /prompts/batch-review` is not implemented.** It accepts or rejects candidates
  "sitting in the review queue", and the admin prompt review queue is on the task's explicit
  out-of-scope list — the endpoint cannot exist without building the thing it operates on.
  `GET /prompts` and `POST /prompts` are built. Recorded in `docs/blocked.md`.
- **The `/prompts` routes require a token but no special role.** They are marked "admin, me
  only" in the contract, but there is no admin concept anywhere in `docs/data-model.md` and
  inventing one would be a schema change nobody asked for. P0 is one account.
- **`q` on `GET /entries` is a case-insensitive substring match** over title and body, not
  full-text search — Postgres `tsvector` search is P1 and explicitly out of scope.
- **A duplicate entry id without an `Idempotency-Key` is a 409.** With the header it replays
  the original 201. Retrying without the header is a genuine collision and saying so beats
  guessing which of the two bodies the client meant.
- **`entry_type` is optional on `POST /entries`** and denormalized from the assignment's
  prompt when omitted. Freeform entries with no prompt fall back to `text`.
- **`unlock_at_age` defaults from the prompt's `default_unlock_age`** when the client does
  not send one. Letters are sealed by default, and the server owns that rule.
- **Deleting an entry soft-deletes its media too.** Otherwise a client that already synced
  the media row would keep rendering it after the entry vanished.
- **Untagging soft-deletes the `entry_tags` link rather than removing the row**, so the
  change syncs as a row. The `tags` row itself survives — it is vocabulary, not content.
- **A user edit may drop a `device_ai` tag; a `device_ai` write may never drop a user tag.**
  The protection runs one way. Re-running extraction has to be free, and a human is always
  allowed to overrule the model.
- **The `/sync` `tags` array carries entry-tag links** (`entry_id`, `tag_id`, `name`,
  `source`, `updated_at`, `deleted_at`), for the reason recorded under M1.
- **The sync cursor is the newest `updated_at` actually returned**, not "now" — a
  server-clock cursor could skip a row written between the query and the response.
- **`POST /sync/push` takes `child_id` at the top level.** The contract's body shows only
  `entries`, `media`, and `idempotency_keys`, but every route has to resolve a child through
  `deps.py`; a push whose records span two children could not be authorized as one request.
- **`GET /children/{id}/moments` always returns all four keys** — `date`, `fallback`,
  `groups`, `entries`. The contract describes the empty case as a different shape; returning
  one predictable model instead means a typed client parses one thing. `fallback` says which
  case happened.
- **`GET /children/{id}/today` accepts an optional `date` override.** The server still owns
  the computation; this only lets you look at another day while building the client, and it
  is what the acceptance test uses to exercise an arbitrary date.
- **`POST /assignments/{id}/custom` revives a dismissed or expired item.** You would not
  hand-author a replacement in order to leave it off the screen.
- **`_loaded()` sets `populate_existing`.** A handler that just wrote tags or media would
  otherwise get the collection SQLAlchemy loaded earlier in the same session. Every writer
  here flushes first, so there is nothing pending to clobber.
- **`media_id` is optional on `POST /media/upload-url`.** The contract has the server mint
  it, but `docs/data-model.md` says media UUIDs are client-generated for offline creation.
  Accepting one covers both; omitting it keeps the documented behaviour.
- **`bytes` and `duration_seconds` come from the client.** The server never sees the object,
  so it has nothing else to go on.

## M5 — Scheduler

- **Selection is split in two.** `choose_prompt(...)` is the pure function — candidates in,
  one prompt out, no database, no clock, seedable RNG. `select_prompt(child, slot,
  as_of_date, session)` is the thin wrapper the task's signature describes: it loads the
  pool and the child's history, then calls the pure half. The rules live in the half that
  can be unit-tested without Postgres.
- **The relaxation ladder, strictest first:** (1) age + season, 180-day cooldown, theme
  rotation on; (2) age + season, **90-day cooldown**, theme rotation on; (3) age + season,
  90-day cooldown, theme rotation dropped; (4) age + season, no cooldown; (5) **season only
  — the age window gives here**; (6) anything in the pool. Cooldown relaxes before the age
  window, exactly as `docs/data-model.md` requires: an age-inappropriate prompt is worse
  than a repeat.
- **Weighted random means a prompt this child has never seen weighs 3, a repeat weighs 1.**
  The spec says "weighted random pick" without naming weights; favouring unseen content is
  the weighting that serves the product, and it is what the cooldown is already reaching for.
- **The theme window includes `as_of_date` itself.** The question and the mission are picked
  seconds apart in the same run, and "avoids serving two prompts from the same theme back to
  back" has to cover that pair.
- **The `monthly` slot draws from every `cadence: monthly` prompt — measurement *and*
  letters.** `docs/data-model.md` annotates the slot "(measurement)", but the eight letters
  are `cadence: monthly` with no slot of their own, and restricting the slot to measurement
  would make them unreachable forever. Flagged in `docs/blocked.md`: a dedicated `letter`
  slot is a one-line CHECK change if you would rather they were separate.
- **The `mission` slot draws from photo, video, audio, activity, and measurement** — every
  daily kind except `question`, which has its own slot, and `letter`, which is monthly.
- **`run_scheduler` takes either an instant or a date.** `as_of` (an instant) is the real
  job: each child's `assigned_on` is that instant read in their own `family_timezone`, so
  two zones legitimately differ. `as_of_date` (a plain date) runs one calendar day for
  everyone, which is what a backfill and the debug route want. Passing both is an error.
- **Every child is active.** `docs/data-model.md` gives `children` no `active` column, so
  "for each active child" means every child.
- **An exhausted slot is left empty and logged, never filled with a fallback.** No fake data;
  the log line names the child and the slot so you know what to go and author.
- **`POST /debug/scheduler/run` is scoped to the caller's own children**, even in a local
  build, so a shared development database is not a way to schedule for someone else's kid.
- **`POST /debug/reset-today` hard-deletes.** It is the only hard delete in the service, it
  only exists when `ENVIRONMENT == "local"`, and assignments are scheduler output rather
  than archive — regenerating them is the whole point of the route.
- **Log extras are prefixed (`assignments_created`, not `created`).** `created` is a reserved
  `LogRecord` attribute and the stdlib raises rather than shadowing it.

## M6 — Deployment artifacts

- **The scheduled machine is created with `fly machine run --schedule daily`, not in
  `fly.toml`.** Fly has no schedule stanza; `fly.toml` carries a comment with the exact
  command and `docs/DEPLOY.md` has the runbook, including the fact that a scheduled machine
  is not managed by `fly deploy` and has to be recreated after a behaviour change.
- **One uvicorn worker per machine.** Postgres connection count on Neon is the scarce
  resource — scaling means more machines, not more workers behind one connection pool.
- **`min_machines_running = 1` with `auto_stop_machines = "suspend"`.** A cold start on the
  morning the widget fires is the one moment this has to be instant.
- **The IAM policy has no `s3:DeleteObject`.** Nothing in this service deletes an object —
  deletion is soft and lives in Postgres — so the credential should not be able to either.
- **S3 gets versioning, an incomplete-multipart abort rule at 7 days, and `ExposeHeaders:
  ["ETag"]` in CORS.** The ETag header is not optional: a multipart upload cannot complete
  without the client reading it off each part response.
- **Neon's pooled endpoint, and the `postgresql+psycopg://` scheme.** Neon hands you a
  `postgresql://` URL; the scheme has to be rewritten for psycopg 3, and the pooler endpoint
  is what survives Fly machines suspending and resuming.
- **`ENVIRONMENT=prod` is a plain `[env]` value, not a secret.** It is not sensitive, and
  having it visible in `fly.toml` is what makes "dev-login cannot exist in production"
  auditable at a glance.

## M7 — Documentation and the acceptance test

- **The acceptance test seeds the real library**, not fixtures, and runs against a Saturday
  so the weekly slot fires too — the simplest possible day would not have exercised
  `slots_for`.
- **The acceptance test asserts the reverse direction as well**: after both entries, `today`
  holds only the weekly item and `done_today` holds the question and the mission. A test
  that only checks what was created would pass with a broken Today screen.
- **A second test asserts the OpenAPI document covers every path in the contract**, so
  `make dev` serving `/docs` is a checked property rather than a claim.
- **`docs/blocked.md` separates "blocked on you" from "deferred by decision".** Three things
  need a credential you hold; three were left out on purpose and say why; two are judgment
  calls flagged for review because they are cheap to change now and expensive later.

---

# Task 02 — hardening pass

## A — Correctness

- **A1: releasing an assignment checks for other live entries first.** Two entries can answer
  one mission, so deleting the first must not unmark the second. `release_assignment` only
  reverts when nothing else still completes it.
- **A1: `completed_by` is nulled alongside the status.** A `pending` row carrying a
  `completed_by` would be a lie the next reader has to reconcile.
- **A2: `ENTRY_TYPES` narrowed to what the derivation can produce** — `photo`, `video`,
  `audio`, `text`, `did_it`. `question`, `activity`, `measurement`, and `letter` can no
  longer be written, so leaving them in the CHECK would advertise filter values that always
  return nothing. Narrowing is free while the database is empty, which is the whole reason
  to do it now. Migration `0002_entry_type_artifact`, reversible.
- **A2: title-only entries are `did_it`, not `text`.** The rule as specified is "text when
  there's a body"; a title with no body is a rare composer state and inventing a fourth case
  would be guessing. Flagged here because it is the one edge the spec did not name.
- **A2: `entry_type` on `POST /entries` and `POST /sync/push` is accepted and ignored**,
  marked deprecated in the schema, rather than removed. Removing it would 422 an existing
  client for sending a field it has always sent; ignoring it makes the server authoritative
  the same way it already is for `child_age_months`.
- **A2: `PATCH /entries/{id}` recomputes the type when the body changes.** Not named in the
  task, but without it adding a body to a `did_it` entry leaves a stale type, which is the
  same class of bug the item exists to fix.
- **A2: "first attached kind" is ordered by `(created_at, id)`.** The relationship's order is
  not deterministic, and the phrase has to mean the same thing on every recompute.
- **A3: `chunk_bytes` is null for a single PUT.** There is nothing to split, and returning
  the constant anyway would imply the client should chunk when it should not.
- **A4: the lag applies uniformly, including when nothing changed** — `cursor = newest -
  30s`, and `newest` falls back to now on an empty pull. A special case for the empty branch
  would be a second rule to reason about for no benefit.
- **A5: audited every write path that returns `updated_at`.** Only the two media routes were
  stale. Entry paths already re-read through `_loaded(...populate_existing)`, child create
  and update already called `session.refresh`, `create_prompt` already refreshed, and
  `AssignmentOut` carries no `updated_at` on the wire.

## B — Schema changes made while the database was empty

- **B1: the `monthly` pool is `MISSION_KINDS`, not "everything except letter".** `SlotSpec`
  already expresses an inclusion list; adding an exclusion mechanism for one case would be a
  second way to say the same thing.
- **B1: the letter slot fires on the 15th, per the task.** Verified the two never collide —
  a day is at most three items, which holds the "two items is the most that survives a bad
  Tuesday" line rather than stacking four on the 1st.
- **B1: `downgrade()` deletes letter assignments before narrowing the CHECK.** Postgres
  cannot create a constraint the existing rows violate, so a reversal that leaves them makes
  the migration irreversible in practice — which is the thing every migration here promises
  not to be.
- **B1: the test-suite `SATURDAY` moved from 2026-08-15 to 2026-08-22.** The old date was
  also the 15th, so it fired the weekly *and* letter slots and no longer tested the weekly
  rule alone.
- **B1: unlock-age inheritance already worked** (`create_entry` falls back to
  `prompt.default_unlock_age`); it now has a test on the letter path, plus one proving a
  client can still override it.
- **B2: only `POST /prompts` is gated, not `GET /prompts`.** Reading the library is how a
  client renders a prompt; the task named library-*mutating* routes.
- **B2: `require_admin` is a standalone dependency, not folded into `require_child_access`.**
  It is not a question about a child — it is about who may write the library every child
  draws from.
- **B2: `is_admin` is exposed on `UserOut`** so a client can hide the library editor rather
  than offer it and take a 403.
- **B2: `dev-login` promotes its fixture user on every call**, not just at creation. An
  account created before this migration would otherwise be permanently unable to author a
  prompt locally.
- **The acceptance test now runs the fullest day the scheduler can produce** — Saturday the
  15th, four slots — rather than the three it asserted before.

## C — Build and deploy hygiene

- **C1: the uv pin is now 0.8.17**, the version that generated `uv.lock` (`revision = 3`).
  **The image was still not built — the Docker daemon was unavailable in this session too.**
  The pin is a reasoned fix, not a verified one.
- **C2: the local-hour filter is a `run_scheduler` argument, not a hard-coded 5.** The job
  passes `SCHEDULER_LOCAL_HOUR`; tests pass it explicitly; `--any-hour` and `--date` pass
  nothing. One code path, three deliberate callers.
- **C2: an explicit `--date` implies no hour filter.** A backfill for a named day is a
  deliberate act and has nothing to do with what time it is right now.
- **C2: `SchedulerRun` gained `skipped_off_hour`** so the 23 daily no-op runs say why they
  did nothing, rather than looking like a scheduler that stopped working.
- **C3: the 19-byte key was never `JWT_SECRET` — I misdiagnosed this in the last session.**
  `.env.example` held a 43-byte value. The warning came from
  `tests/test_auth.py::test_a_token_signed_with_the_wrong_secret_is_rejected`, which forges
  a token with the literal `"not-the-real-secret"` (19 bytes). Lengthening the example alone
  would not have silenced it. The forged key is now long enough — the point of that test is
  the *wrong* key, not a short one — and `.env.example` is a 32-byte value regardless,
  because it is better hygiene and the generation command belongs next to it.

## D — Documentation

- **The coverage table gained a Total column and an "any-month" column.** Eligible-by-age was
  the only figure before, and it overstates what the scheduler can draw on a given day —
  four photo prompts are seasonal, so August sees 18 of the 22, not 22.
- **The `COVERAGE_TABLE_FLOOR` dict is gone from `test_seeding.py`.** It existed only because
  the doc disagreed with reality; the doc now matches, so one set of exact figures is the
  whole assertion.
- **The `/sync` contract now states the client obligation, not just the server behaviour.**
  A lagged cursor is only safe if clients upsert by id — a client that treats every returned
  row as new will duplicate data, so that sentence is in the contract in bold.
- **`docs/blocked.md` was rewritten rather than edited.** It had grown a "deferred by
  decision" section as long as the blocked one; blocked now means blocked, deferred is
  clearly separated, and a "resolved since last review" list closes out the nine items this
  pass fixed.

## Follow-up — entry_type consults the prompt's completion_mode

- **Deriving purely from content was wrong in the other direction.** A note on a did-it
  mission made it a `text` entry and dropped it out of the Did it filter — the same lie as
  the audio bug, pointing the other way. The rule now consults
  `prompt.completion_mode` between the media check and the content check.
- **Media still outranks the prompt.** A did-it mission someone photographed anyway is a
  photo entry: the artifact exists and the Photos filter has to find it. Tested explicitly,
  because it is the one place the two rules could disagree.
- **A title with no body is `text`.** Settles the edge flagged in the last report: a title is
  written content, so it is enough on its own.
- **`completion_mode_for()` returns None for a parent-authored `custom_body` assignment**, not
  just for a freeform entry. There is no prompt behind a custom item saying what shape the
  answer takes, so the content decides.
- **`PATCH /entries/{id}` now recomputes on a `title` change too**, not only `body` — both are
  content under the new rule.

---

# Task 03b — deploy automation, durability, search, prompts

## M1 — Deploy from GitHub Actions

- **`DIRECT_DATABASE_URL` added to `Settings`, used only by Alembic.** Neon's pooled endpoint
  is PgBouncer in transaction mode, which does not support the advisory locks and prepared
  statements a migration needs. `sync_database_url` prefers it and falls back to
  `DATABASE_URL`, so local development — which has no pooler — is unchanged.
- **The deploy checks Fly's release status explicitly.** `flyctl deploy` can exit 0 while the
  release command errored, which would put a running app in front of an unmigrated database.
  The workflow reads `flyctl releases --json`, requires `succeeded`, and dumps 80 log lines
  when it is not.
- **`/health` is polled for 90s and compared byte-for-byte** to `{"status":"ok","db":"ok"}`.
  A 200 with a degraded body would otherwise pass.
- **`concurrency: cancel-in-progress: false` on deploy.** Cancelling a deploy halfway can
  leave the release command half-applied; queueing is the safe behaviour.
- **`smoke.yml` asserts the *absence* of `dev-login` and the debug routes**, not just that
  health is green. Those 404s are the only runtime proof that `ENVIRONMENT=prod` took effect.
- **The app's own secrets live in Fly, not GitHub.** GitHub only needs what the *workflows*
  use — the Fly token, AWS keys for backups, and the backup database URL. Fewer copies of a
  credential is fewer places to rotate.

## M2a/M2b — Durability

- **The backup runs in GitHub Actions, not on a Fly machine**, per the task: it has to still
  run on a day when Fly is the broken thing.
- **The backup verifies its own dump before counting it as a backup** — non-trivial size,
  `gzip -t`, and a grep for `CREATE TABLE public.entries`. A `pg_dump` that succeeds against
  the wrong database produces a perfectly valid, perfectly useless file.
- **`BACKUP_DATABASE_URL` is a plain `postgresql://` URL**, not `postgresql+psycopg://`.
  `pg_dump` is not SQLAlchemy and does not understand the driver suffix.
- **Retention keeps the newest object in each calendar bucket** — day, ISO week, month —
  taking the most recent 7, 4, and 12 buckets respectively. An object survives if any rule
  wants it.
- **Prune never deletes a key it cannot parse**, and refuses to delete anything at all if the
  keep-set came out empty. Both are guards against a bug in the selection emptying the prefix.
- **`restore.py` refuses a non-empty target without `--force`.** A mistyped URL should not be
  able to quietly overwrite production.
- **`psql --set=ON_ERROR_STOP=1`.** Without it psql exits 0 after a failed statement and a
  half-restored schema looks like a success.
- **CI installs a Postgres 16 client when the runner's is older.** `pg_dump` refuses to dump a
  server newer than itself, and the restore test is worthless if it silently skips.

## M2c — Full export

- **The zip is staged in a temp file and streamed back in 1MB chunks**, rather than assembled
  in memory or streamed as it is built. A true streaming zip needs a third-party library, and
  eighteen years of video does not fit in a 512MB Fly machine. Disk is the boring option.
- **The database read and the zip build are separate halves.** Every row is flattened to
  plain dicts while still on the event loop; the blocking half (S3 reads, deflate) runs in a
  worker thread and never touches the ORM. A lazy load from inside a thread is how an export
  hangs instead of failing.
- **Media is foldered by `occurred_at`, not `created_at`.** A photo backdated to 2019 files
  under `media/2019/…`. Rule 3, applied to the filesystem.
- **A media row whose object is missing is named, not fatal.** It keeps its metadata, loses
  its `path`, and lands in `manifest.missing_media`. One dead upload must not cost you the
  other seventeen years.
- **Sealed letters export in the clear.** The seal is an app behaviour; `unlock_at_age`
  travels as data. An export you cannot read is not a backup.
- **Parent only.** A viewer reads the timeline; walking off with a copy of the whole
  childhood is the account owner's to do.
- **`format_version` in the manifest.** Whoever opens this in 2044 needs to know which shape
  they are looking at without this repo.

## M3 — Full-text search

- **Stored generated `tsvector` columns, not a trigger.** A generated column cannot drift:
  there is no window in which a row is written and the vector is not, and no backfill to
  remember after a bulk `UPDATE`. It also keeps rule "`updated_at` is the trigger's job"
  from acquiring a sibling that application code might be tempted to maintain.
- **The text search configuration is spelled out as `english`.** A generated column's
  expression must be `IMMUTABLE`, and the one-argument `to_tsvector` reads a GUC. Naming it
  is what makes the column legal, and it stops the index silently changing meaning if the
  server default is ever retuned.
- **`websearch_to_tsquery`, not `plainto_` or `to_tsquery`.** It is the only parser that
  cannot be made to raise on whatever a person types into a search box, and it gives
  `"exact phrase"` and `-excluded` for free. `to_tsquery` would 500 on an unbalanced paren.
- **No prefix matching, and that is a trade.** `hangab` finds nothing. Buying it would mean
  hand-assembling a tsquery out of user input, which is the exact thing
  `websearch_to_tsquery` exists to avoid. Search is on submit, not per keystroke.
- **The match predicate is a UNION of two id sets, not `entries.search_vector @@ q OR id IN
  (...)`.** The two return identical rows, but the OR form makes Postgres fall back to a
  sequential scan over `entries` — it will not combine an index condition with a hashed
  subplan. `test_search.py` runs EXPLAIN over the real statement and fails if either GIN
  index stops being reachable, because that regression is invisible until the archive is
  large enough to hurt.
- **Search paginates on `(rank, occurred_at, id)`, and its cursor is not interchangeable
  with the timeline's.** Passing one across returns 422 rather than a quietly wrong page.
- **The rank is cast to `double precision`.** `ts_rank_cd` returns `real`, and a float4 that
  round-trips out through a cursor and back in as a float8 is not guaranteed to compare
  equal to itself — which would drop or repeat a row at every page boundary.
- **Captions are weighted below transcripts.** Both are on-device AI output, but a caption is
  the machine describing a photo and a transcript is a child talking. The second should never
  lose to the first.
- **No `ts_headline`.** `EntryOut` already returns the full title and body, so the client can
  mark up its own snippet; a server-rendered one would put HTML into a JSON API that a phone
  and a browser would style differently.

## M4 — Prompt generation

- **The review queue is a pull request, and `POST /prompts/batch-review` is cut rather than
  deferred.** A branch with a diff is already an accept/reject interface with a comment
  thread, an audit trail, and an undo. It needs no table, no admin screen, and no endpoint.
  Removed from `docs/api-contract.md` outright — a contract that lists an endpoint nobody
  intends to build is worse than one that does not mention it.
- **The trade, named:** reviewing on a phone means reviewing in the GitHub app, which is
  worse than a purpose-built screen. Not worse enough to justify building the screen.
- **The four rejection rules are implemented in code, not left to the instructions.** A model
  told not to say "precious" mostly does not say "precious", and "mostly" is not a filter.
- **The filters are deliberately narrow where narrowness costs accuracy.** The ability check
  catches `hike`/`jog`/`swim` and stops. A rule aggressive enough to catch every physical
  assumption would reject "get on the floor and play whatever he is playing for ten minutes",
  which is one of the best prompts in the library — so `test_generate_prompts.py` runs the
  real library through its own filters and fails if any of them would be rejected.
- **Rejections are written into the worksheet, not discarded.** A batch where half the
  candidates trip the same filter is telling you the instructions need work, and that signal
  is invisible if the failures are thrown away.
- **The feeling-not-action rule applies to missions only.** "What is he afraid of right now?"
  is a question *about* a feeling and is exactly what the question set is for.
- **Structured output via a forced tool call**, not JSON parsed out of prose. There is no
  code path that has to recover from the model writing a sentence before the array.
- **`httpx` calls the Messages API directly rather than adding the SDK.** httpx is already a
  dependency; one script does not justify another.
- **A missing `ANTHROPIC_API_KEY` exits 0 with a loud message.** It runs from a workflow, and
  a red X for "not configured yet" says something untrue about the code. The workflow itself
  fails on a missing key, because there it really is an error.
- **A new branch per generated batch**, never a reused one. Two batches must not silently
  overwrite each other while one is still open for review.
- **The monthly schedule is commented out, not deleted.** A library that grows on a cron
  without anyone asking is how you end up with three hundred prompts nobody chose.

## Running a migration outside the app (pre-flight against Neon)

- **`DatabaseSettings` is split out of `Settings`, and Alembic resolves its URL through the
  narrow one.** The first real migration of the Neon database failed before Alembic ran:
  `alembic/env.py` went through the full app settings, so a migration demanded an S3 bucket,
  AWS credentials, and an Apple bundle id it would never use. Every context that only
  migrates — the pre-flight workflow, a restore drill, a one-off shell — would have had to
  invent five values, and inventing them is how a real misconfiguration gets papered over.
- **The narrow model is a base class, not a copy.** `Settings` extends `DatabaseSettings`,
  so `database_url`, `direct_database_url`, and `sync_database_url` are declared once and
  cannot drift.
- **`db.py` uses it too, which is what lets the seed job run on a database and nothing else.**
  The service itself still goes through `get_settings()` in `create_app`, so a missing
  `JWT_SECRET` fails at startup exactly as before — `test_config.py` asserts both halves,
  and derives the app-only field list from the models so it cannot go vacuous.
- **`make lint` now lints `.github` as well.** CI already did; the Makefile did not, and the
  gap is how a formatting failure reached CI once already.

## Deploy is skipped, not failed, until Fly exists

- **A red X that means "not set up yet" is training to ignore red Xs.** Every merge to `main`
  was failing the Deploy workflow on a missing `FLY_API_TOKEN`, which marked four correct
  commits as broken.
- **Gated on the repository variable `FLY_DEPLOY_ENABLED`, so the job skips.** Skipped renders
  grey: not a failure, and — this is the point — not a green check claiming a deploy that
  never happened. Of the two dishonest signals, a false green is the worse one.
- **A variable, not the secret.** GitHub does not expose `secrets` to a job-level `if`, and
  probing the token in a prior job would make a *missing* token look like a clean skip
  forever after, including the day someone revokes it. `workflow_dispatch` ignores the gate,
  so the question stays answerable on demand.

## The compose host port is overridable

- **5433 was hardcoded to dodge a local Postgres on 5432, and something else took 5433.**
  Another project's compose stack held it, so `rascal-postgres` never left `Created` and
  `make up` looked like a hang rather than a port conflict.
- **`${POSTGRES_PORT:-5433}`, defaulting to the old value.** Anyone whose 5433 is free sees
  no change. `POSTGRES_PORT` and the port inside `DATABASE_URL` have to be the same number;
  `.env.example` says so where both are set.

## `pg_dump` must be exactly 16, not "16 or newer"

- **A newer client is the dangerous direction, and the guard allowed it.** `ci.yml` accepted
  ` 1[6-9]\.`. pg_dump 17 writes `SET transaction_timeout` into the dump header, Postgres 16
  does not recognise that parameter, and the restore dies under `ON_ERROR_STOP` with an
  error that says nothing about versions. CI passed only because today's runner ships 16.
- **Both `ci.yml` and `backup.yml` now require ` 16\.` and fail loudly otherwise.** The
  backup path matters more than the test: a dump written by a 17 client does not restore
  into Neon, and that is discovered on the day the backup is needed.
- **PATH, not just the package.** Debian's `/usr/bin/pg_dump` is `pg_wrapper`, which
  dispatches to the newest installed version — so installing `postgresql-client-16` beside a
  17 changes nothing until `/usr/lib/postgresql/16/bin` comes first. The Makefile does the
  same locally when a Homebrew `postgresql@16` is present.

## The iOS lane's config chain is two text files, not a pbxproj edit

- **`Config.xcconfig` → `Info.plist` → `Bundle.main`.** The base URL and the dev child id
  reach Swift as Info.plist keys, so pointing the app at localhost, TestFlight, or Fly is a
  config change and never a code change. Both files sit beside `Rascal.xcodeproj`.
- **`INFOPLIST_KEY_*` was tried first and does not work.** It only carries keys Apple already
  knows; a custom key is dropped silently, with a *successful* build. The authored
  `Info.plist` reproduces what Xcode was generating — verified by diffing the built plist
  before and after, the only delta being the three new keys.
- **`Info.plist` lives beside the `.xcodeproj`, not in `Rascal/Rascal/`.** That folder is a
  synchronized group, so a file dropped there is also copied as a resource and the build
  fails with "Multiple commands produce Info.plist".
- **`GENERATE_INFOPLIST_FILE = NO` had to go in `project.pbxproj`.** A target setting beats
  an xcconfig, so this one cannot live with the others. It is the only pbxproj edit, and a
  clean build from an empty derived-data path is what proves it.

## Xcode's own git repository was removed

- **`ios/Rascal/.git` existed** — the New Project sheet's "Create Git repository" default. A
  repo inside a repo is the exact thing the monorepo decision rules out, and its single
  commit had `Config.xcconfig` and `xcuserdata` in it, both deliberately untracked upstream.
- **Removed rather than converted to a submodule.** Nothing in it was unique; the parent
  already tracked every file worth keeping.

## `ci.yml`'s path filter covers `.github/scripts/**`, not just `api/**`

- **The lint job runs `ruff check . ../.github`.** Filtering on `api/**` alone would have
  quietly stopped linting `prune_backups.py` and `verify_schema.py` — two scripts that run
  against production data and that nothing else checks.

## Media lives on Tigris, not S3

- **Nothing here needed Amazon.** Every storage call is plain S3 through boto3, so the only
  thing standing between the code and any S3-compatible store was a missing `endpoint_url`.
  The `AWS_*` credential names stay because they are the protocol's convention; the values are
  Tigris keys.
- **`s3_endpoint_url` defaults to `None`, which means AWS.** Additive, so a deployment that
  never sets it behaves exactly as before. A blank value coerces to `None` rather than to an
  endpoint named empty string, because a half-filled `.env` or an unset CI secret produces
  `""` and boto3's failure names neither.
- **Virtual addressing is stated rather than inherited.** boto3 flips to path-style for a
  custom endpoint; the two sign differently and the mismatch surfaces as a 404 on a bucket
  that demonstrably exists.
- **`export.py` needed no change** because it calls `get_s3_client()` rather than building its
  own — the shared-client design paying for itself.

## The test suite can no longer reach real object storage

- **It tried.** `moto` works by intercepting AWS's endpoints, so a configured
  `S3_ENDPOINT_URL` routes straight past it. The media fixture called `create_bucket` against
  live Tigris and was stopped only by `BucketAlreadyExists` — with a different name the suite
  would have been creating and deleting buckets in production.
- **`conftest` now blanks the endpoint for the whole session**, next to the line that keeps
  the suite off a dev database. A property of the suite, not of the two fixtures that happen
  to use moto today.

## Lane A — the two Settings endpoints

- **`PATCH /me` returns `UserOut`, the shape `/auth/apple` already returns.** A second,
  parallel user model is how two representations of the same row start to drift.
- **`display_name` is validated in the handler, not by Pydantic bounds.** A `max_length` on
  the field would answer over-length with `validation_failed` and blankness with
  `invalid_display_name`; one field showing two codes is a client-side branch nobody wants.
- **`invalid_display_name` is a new `ErrorCode` at 400, not a reuse of `validation_failed`.**
  Adding a code is a deliberate act and this is one: the body parsed and the type was right,
  the value simply is not a name. The enum, the table in `docs/api-contract.md`, and
  `test_error_codes_are_the_documented_ones` moved together.
- **The recompute route answers a `viewer` with `not_authorized`, not `insufficient_role`.**
  The Lane A brief asked for the latter, but authorization here is one dependency
  (`docs/decisions.md`, Settled) and four existing tests pin `403 not_authorized` as what a
  read-only guardian gets on every write route. A second 403 code for one endpoint would
  make this route the exception in a surface whose whole value is having none.
- **Recompute writes only the rows whose value moves.** `set_updated_at()` is a `BEFORE
  UPDATE` trigger with no equality check, so a blanket `UPDATE` would restamp the entire
  archive and push it through every client's sync cursor to correct three rows.
- **It is one ORM bulk update keyed by primary key, in the request's transaction.** The
  `get_session` dependency commits once at the end of the handler, so atomicity is the
  session's, not something the service has to arrange for itself.
- **The 500-entry test asserts a one-month birthdate shift moves every age by exactly one.**
  Re-deriving the expected values with `age_at_instant` would have asserted that the
  function equals itself; the shift's arithmetic is hand-derivable and two rows are pinned
  to values computed by hand as anchors.
- **Single-transaction is asserted through `xmin`.** Every row version written by one
  transaction carries that transaction's id, so a chunked or partial recompute shows up as
  more than one distinct `xmin` across the child's entries.

## Aug 9, 2026 — the client's half of sync

- **The engine ships behind a flag that defaults off.** It touches the cache every screen
  reads from, and it has never met a real archive. A dry run that performs a genuine
  `GET /sync` and applies nothing is the thing that gets read before the flag is flipped.
- **`GET /sync` does not page.** Read from `routers/sync.py`, which declares one query
  parameter besides `child_id`, not inferred from the contract doc. The client still loops,
  for a different reason: the cursor comes back lagged, so a second call closes the gap
  between the lagged position and the present. Two rounds is the normal finish.
- **An empty batch returns an *advancing* cursor.** `service.pull` falls back to `now()` when
  there are no rows to take a maximum from, so the cursor comes back as `now() - 30s`, which
  is ahead of whatever was sent. The loop therefore terminates on an empty batch **before**
  it checks for cursor movement; the other order spins forever against an idle archive.
- **The cursor advances per round, never mid-round.** A round applies whole and is saved
  whole; a failure rolls it back and leaves the cursor where the last clean round put it.
  A partial advance loses records permanently and silently, which is the one failure here
  with no recovery short of a manual reset.
- **Media has no usable `updated_at` to compare against.** `MediaOut` carries one, but a local
  `Media.updatedAt` is stamped by this device's own clock on every state transition, so the
  two are not comparable. "Has anything changed" is answered by comparing the fields
  `applyServerSummary` actually writes, and the predicate mirrors that method including its
  two one-way rules.
- **Assignments carry no `deleted_at`.** They are never soft-deleted server-side; they change
  `status`. There is no soft-delete branch for them, and that is a fact about the contract
  rather than a gap.
- **Tag links fold onto `Entry.storedTagNames`** rather than gaining a `Tag` model, matching
  the existing denormalised design. The link is still what the server sends, because a bare
  tag list would not say which entry lost which tag.
- **A planned change is keyed by entity + id + a discriminator.** Only tags need the
  discriminator, and they need it badly: a link is keyed on the entry id, so six tags on one
  entry would collapse into one planned change and the report would undercount.
- **When one record is decided twice in a run, the more *significant* verdict survives, not
  the later one.** By round two, a record round one inserted is genuinely unchanged — round
  two is looking at round one's own work. Letting the later verdict win made the report say
  "0 soft-deletes" immediately after soft-deleting something. Caught by the tests, and the
  assertions were right.
- **The apply yields to the main run loop every 100 records.** It runs on the main actor
  because that is where the `ModelContext` the views read from lives. This is cooperative —
  it does not move the work off the main thread, it stops the work monopolising it.
- **`GET /me` returns the row `current_user` already loaded** and takes no `SessionDep`.
  Taking the session again only to re-read the same object would be a second query for it.

## Aug 9, 2026 — cutting the Actions bill

Actions is metered because the repo is private; it is free and unlimited on public ones.
macOS bills at **ten times** Linux, so the Free plan's 2,000 minutes is 200 macOS minutes.
Measured from run history: an `ios.yml` run is 3–7 minutes of wall clock, so **30–70 billed
minutes each** — 1.5–3.5% of a month's allowance per run.

- **The push trigger on `ci.yml` and `ios.yml` was `branches: ["**"]`, and that was the bug.**
  A push to a branch with an open pull request fired both the push and the pull_request
  workflow, on different concurrency groups, so neither cancelled the other and every push
  cost double. Both are now `branches: [main]`. `pull_request` already tests the *merge
  result*, which is the thing that matters; the push leg remains so a direct push to main is
  still gated. This is where essentially all of the saving is.
- **Draft pull requests no longer spend a macOS runner.** A draft here means paused or
  blocked work — the stop-condition procedure says to open one — and 40 billed minutes to
  report that an unfinished branch is unfinished is not worth it. `ready_for_review` is in the
  trigger list so marking it ready runs what the guard deferred.
- **Every job in `ci.yml` was unbounded**, which is six hours apiece by default: a single hung
  run could have cost more than a normal month. All three now have timeouts. `ios.yml` came
  down from 25 to 12, against an observed worst case of 7, capping a hang at 120 billed
  minutes rather than 250.
- **The simulator starts booting in the step that picks it**, so the boot overlaps the compile
  in the next step instead of following it. `simctl boot` initiates and returns; waiting is
  `bootstatus`.
- **The build settings are marginal and are labelled as such.** Measured cold and locally,
  `COMPILER_INDEX_STORE_ENABLE=NO`, `ONLY_ACTIVE_ARCH=YES` and
  `-disableAutomaticPackageResolution` take a ~6s compile to ~5s. The job takes 3–7 minutes,
  so compilation is not what it is spending. Kept because they are free, not because they are
  a saving.
- **Rejected: caching DerivedData.** Xcode's build cache is unreliable across runners, and the
  failure mode here is specific — a stale cache means a file is not recompiled, and a file
  that is not recompiled emits no warning. That would silently turn the zero-warning gate
  green. The same mechanism had just hidden nine real warnings from an incremental local run.
- **Rejected: touching `backup.yml`.** It looked like a candidate — a daily cron that had been
  failing all week — but it started succeeding on Aug 8 once the secrets landed. It is the
  archive's insurance, it runs on Linux, and it costs about 45 minutes a month. Left alone.
- **Rejected: making the repo public**, which would make Actions free outright. `docs/` is
  full of personal context about a specific child. Not a trade worth $5.

## Aug 9, 2026 — what CI caught the moment it came back

The billing block cleared between 18:36Z and 18:53Z. The first `iOS` run that was allowed to
execute failed, and it was right to.

- **`Sync at scale` is `.serialized`, and it is about the measurement rather than about safety.**
  All three tests there are `@MainActor` and all three apply 736 entries; Swift Testing runs
  tests in parallel by default, so they interleave onto the one main actor and the wall clock
  each test reads spans the other two's work. `fullPullAtArchiveScale` measured **2.7s alone,
  10.7s beside its siblings locally, and 47.5s on the CI runner** — failing a 30s budget the
  apply is nowhere near. No assertion and no budget changed; the trait makes `elapsed` measure
  the one cold start the assertion names.
- **The general lesson, worth more than the fix: a wall-clock assertion inside a parallel suite
  measures the machine's contention, not the code.** It was invisible on a fast laptop for
  exactly as long as CI was down. Any future timing assertion belongs in a serialized suite.
- **Rejected: raising the 30s budget.** That is editing an assertion to make a test pass, and it
  would have buried the real finding — that the number being asserted on was never the number
  the test claimed to measure.
- **The dry-run report now states its own cost**, split into time waiting on `/sync` and time in
  the apply, because the apply runs on the main actor and the network does not — one total would
  hide which of the two a slow pull actually was. The report is the only artefact the first real
  pull is judged from, and the top open question about this engine is main-actor cost, so a
  report that omitted it was asking for a judgement it withheld the evidence for.
- **Timed on `ContinuousClock`, not `Date`.** A wall clock can step sideways mid-pull — NTP, a
  timezone change — and a negative duration in the report reads as a performance problem that
  never happened.

## Timeline v3 — the entry card rebuilt around the prompt (Aug 9, 2026)

- **The prompt resolves from the assignment when the detail fetch has not cached one.**
  `GET /entries` carries no `prompt`, so leading the card with the quote would have shown a
  blank zone on every row until the parent opened it. `entries.assignment_id` → the cached
  `Assignment.body` is the same sentence, `/sync` keeps it current, and nothing evicts it — so
  the quote is there on a cold launch with no signal. Written up in `docs/blocked.md` as the
  field Lane A could add to make it unnecessary.
- **The overflow count is printed on the fourth tile, not given a fifth.** The old card showed
  three tiles and a `+6`; v3 shows four and a `+5`. The reason is height: a nine-photo card and
  a four-photo card must be the same size, or a long scroll acquires a stair nobody designed.
- **Age moved off the card and onto the day header.** It is a property of the day, not of each
  entry under it, and repeating "4y 2m" on three cards in a row was noise. It reads once per
  group now, as a periwinkle capsule on the trailing edge.
- **The sealed card carries no blurred body, and the mock does.** `EntryCardModel` never reads
  a sealed entry's body — there is nothing on the card to leak, which is stronger than blurring
  it. What the card shows instead is when the letter opens. Rendering filler under a blur to
  match the mockup would be inventing text in a permanent archive.
- **The waveform is the progress bar on Entry Detail.** Bars behind the playhead at full
  strength, the rest faint, replacing the separate capsule rule. One object doing one job. On a
  timeline card the same waveform is drawn flat, with no progress at all — a part-filled
  waveform there would claim the parent had listened to some of it.
- **The bars are not the recording's real levels, deliberately.** A true waveform means
  fetching and decoding every audio entry on a screen that may hold fifty. The heights come
  from `6 + (i * 29) % 18`, which is stable across scrolls — a waveform that reshuffles when a
  card returns reads as a loading state.
- **A voice entry with no note of its own quotes the transcript, in italic.** Recording the
  child and writing nothing is the ordinary way to make one, and his words are then the only
  words the card has. Italic because they are somebody else's; the parent's own summary is set
  upright.
- **Rejected: restyling `Chip` globally to v3's 12pt semibold.** The chip is on Today, Moments,
  and Settings, and a timeline change should not restyle three other screens by a point. An
  opt-in `emphasis` flag carries the v3 weight only where v3 asked for it.
- **The header count says "412 so far" until paging is exhausted.** `@Query` counts what has
  been paged in, not what the archive holds. The design's "412 entries" is a total the client
  has never counted, and printing it would be the timeline inventing a fact about the archive.
- **The closing line lost its pronoun.** The mock reads "Keep scrolling and he gets younger."
  Client-side strings are gender-neutral (`CLAUDE.md`, open item 10), so it ships as "Keep
  scrolling and it only gets younger." The mock's per-screen footers ("Six days in", "Thirty-
  eight afternoons") were dropped: they count, and nothing in this app counts.
- **The prompt is written onto the row at composition, not only fetched.** `Assignment` rows
  come only from `/sync`, and sync pull ships disabled — so on a device the assignment fallback
  resolved nothing and every card was quoteless. `ComposerView` now caches `assignment.body` as
  it creates the entry. Both paths stay: the cache is what works today, the fallback is what
  works for rows this device did not write, once pull is on.
- **Audio is not a picture, and the mosaic had to be told.** `thumbnails` was built from all
  live media, so a voice entry drew a 242pt periwinkle rectangle above the voice band — the same
  recording, rendered twice. The mosaic now takes photos and video only, and `serverMediaCount`
  has the locally-known non-pictures subtracted so the `+N` count stays honest. Only visible on
  a device: every test asserted counts, and the counts were right.
- **A tile carrying the `+5` drops its placeholder glyph.** The design scrims that number over a
  photograph. With `thumb_key` null it landed over a camera icon instead, and two marks fought
  over one square.

## On-device transcription and the search surface (Aug 9, 2026)

- **The sync engine's pending-local rule did not cover a transcript, and that was the phase's
  real finding.** `hasUnpushedChanges(_ media:)` read only `uploadState` — `staged`, `uploading`,
  `uploaded`. A transcribed row is `complete` by construction, because transcription only runs
  after the upload lands, so the rule considered it settled and a pull carrying the server's
  older row overwrote words that existed nowhere else. Fixed with a first clause on that
  function and a `transcriptState` ladder on the row.
- **The guard also went into `Media.applyServerSummary`, not only into the sync engine.** All
  three pull paths funnel through that method, and `syncPullEnabled` ships false — so the engine
  is the path that mostly is *not* running while the timeline's refetch is the one that is.
  Protecting only the engine would have protected the quiet path and left the loud one open.
- **`failed` counts as pending for a transcript and does not for an upload.** Deliberately
  asymmetric: bytes past the upload cap are safe in storage and the server's copy is better,
  whereas a transcript past its push cap exists only on this phone.
- **`transcriptState` is a second ladder rather than more values on `uploadState`.** The bytes
  and the words are two journeys to the server that fail independently; one row can be complete
  on the first and carrying undelivered work on the second.
- **The derived push lives in `TranscriptionQueue`, not in `MediaCoordinator`.** It reuses the
  existing machinery where reuse is the point — `UploadBackoff`, row-persisted schedule, and
  `MediaCoordinator.sweep()` as the single entry point — while keeping inference, which is
  compute rather than network, out of a type whose job is uploads. Nothing new sweeps and no
  second retry policy exists.
- **`MediaCoordinator` gained an optional `transcription` link, in one direction only.** Same
  shape as `EntrySync.media`. The queue takes the `APIClient` directly rather than holding the
  coordinator back, so two process-lifetime singletons do not point at each other.
- **A backlog row is promoted out of `.none` one at a time, immediately before its own
  inference.** Marking the whole set up front would make a killed manual run resume as
  permanent automatic background work, which is exactly the surprise battery event the manual
  gate exists to prevent. Finished rows stay finished, so pressing the button again resumes.
- **Backlog media with no local file is downloaded to transcribe.** Recordings made on this
  phone are read in place — a voice note has no thumbnail, so its staged original is never
  swept — but the backlog is mostly rows synced from elsewhere, and without the fetch the
  feature would do nothing for them. Audio is small enough that this is defensible; video is
  not, which is one more reason it was cut.
- **The queue trims what the transcriber hands back rather than trusting it.** A test caught
  this: a conformer returning a single space wrote one into a permanent archive. Tidying inside
  `SpeechTranscription` was an implementation detail of one conformer, and the queue is what
  decides what the archive holds.
- **A silent recording settles as `synced` with no transcript, and leaves the backlog.**
  Counting "no words" as outstanding would offer the same silence up for re-inference forever.
- **Search got a magnifier in the Timeline header, because the "existing search affordance" the
  brief refers to does not exist.** The v3 header is title, count, and filter chips. Adding one
  button there was the smallest thing consistent with "revealed by the top bar, not a new tab".
- **Search is its own model with its own cursor.** The two modes page on different keys and the
  server answers `422` for a cursor crossed between them, so a shared `continuation` is
  precisely the thing that must not be shared.
- **The matching transcript line is computed on device from the cache.** `GET /entries` inlines
  `MediaSummary`, which carries no transcript, and fetching detail per result would be the N+1
  the timeline exists to avoid. It works for what this phone wrote, which is the case the
  feature was built for, and shows nothing rather than guessing otherwise. Postgres stems and
  the client cannot, so a stemmed match explains nothing — a smaller wrong than a wrong one.
- **The search match outranks the parent's own body on a card, and only under search.** A result
  whose only connection to the query is a sentence forty seconds into a recording otherwise
  looks like the search is broken.
- **`EntryDetailScreen.transcript(in:)` was extracted so the absence case is assertable.** Same
  reasoning as `EntryCardModel` being a value type: the rule that matters is "renders identically
  to before this feature existed", and that cannot be asserted on a branch buried in a view body.
- **The search tests drive the debounce to zero and await the model.** Written with real sleeps
  first, they passed alone and failed every time in the full run — parallel suites starved the
  tasks past the sleep. A wall clock is not a synchronisation primitive.
- **That rewrite found a real defect.** `fetch` checked `Task.isCancelled` on the success path
  and not on the failure path, so an abandoned request's error wrote a notice and marked the
  list finished — over results belonging to the query still on screen, and after them.

### Hardening pass — turning "not confident" into either a test or a fix

- **`AVAudioFile` opening the recorder's own m4a was assumed, and is now asserted.** The whole
  transcription path treats a failed open as `bytesUnreachable`, so if AAC-in-MP4 were not
  readable that way, every device would fail with a message about the file being missing while
  the stub went on passing. `AudioPipelineTests`'s real-recording fixture was made shared and
  the assertion added.
- **Two `ModelContext`s over one store was reasoned about and is now measured.** The automatic
  trigger crosses them — `MediaCoordinator` marks `complete` in a per-call context, the queue
  reads through the environment's — and a stale read would mean no new recording is ever
  transcribed automatically, with the backlog button as the only route to a transcript. Tested
  against a file-backed store, with the reading context loading the row first so it is a
  refresh question rather than a cold fetch.
- **The readiness ladder was lifted out of its I/O.** `SpeechTranscription.decide` is now a pure
  function over `(preferred, installed, supported)`. The ordering is the entire content —
  installed beats supported, supported beats nothing — and getting it wrong is silent in both
  directions. None of the surrounding API can run here; the decision now can.
- **Bulk backfill refuses cellular.** This was the one thing found in review that would have
  shipped as a genuine harm rather than a rough edge: a backlog run fetches hundreds of files,
  and it was using `URLSession.shared`. Someone pressing a button about transcribing has not
  consented to a few hundred megabytes of cellular data. Only rows from another device are
  affected — a recording made here is read in place — and `URLError.networkUnavailableReason`
  is what tells "deferred" apart from "lost" so the row can say which.
- **The backlog said "4 of 3".** The counter increments after each row and the view can render
  in the gap before the run tears its progress down. Clamped.
- **A non-cancellation error out of the results sequence escaped raw.** It landed in the row's
  failure text as an opaque `Speech` domain string, which is not a sentence anyone should read
  in Settings. Wrapped as `TranscriptionFailure.engine` like every other engine failure.
- **`AssetInventory.reserve` was called per transcription.** Three hundred XPC round trips
  during a backlog run to be told the same thing. Cached per locale per process, and only
  recorded as reserved when the call actually succeeded.
- **The list is no longer rebuilt when search opens from All.** Identity is the `@Query`
  predicate rather than the UI state, and a search is the `.all` predicate however it got
  there — so the common path stops tearing the whole list down. What that does to scroll
  position is still SwiftUI's decision, and the device checklist now says so instead of
  promising the scroll is preserved.

---

## Aug 10, 2026 — Lane A: deploy readiness and scheduler durability

Judgment calls made without asking, each recorded because the brief said to resolve
ambiguity by matching existing code and keep going.

- **The brief's premise was wrong and I did not build to it.** It described assignment
  creation as running in-process on APScheduler. There is no APScheduler in this repo and
  never has been: the job is `python -m rascal.jobs.scheduler` on a Fly scheduled machine,
  and `min_machines_running = 1` was already set. The durability problem it named is real,
  one layer out — a scheduled machine is invisible to `fly deploy` — so the prescribed fix
  was right for a reason the brief did not give.
- **`ensure_day_filled` lives in `services/scheduler.py`, not in `services/today.py`.** It
  reuses `slots_for` and `_fill_slot` directly, which is what "do not write a second
  selection algorithm" requires; putting it in the today service would have meant reaching
  across for two private functions or duplicating them.
- **`?date=` does not trigger creation.** The brief did not say either way. A read endpoint
  a viewer can use to write assignments into an arbitrary past or future is a worse thing
  than an empty screen, so creation is gated on the resolved date equalling the child's real
  local today. The Saturday, monthly, cooldown and expiry cases are therefore tested at the
  service layer, where the day is an argument.
- **The cheap pre-check is one `SELECT slot` for the whole day**, not one per slot. Missing
  slots are computed in Python and only those are passed to `_fill_slot`, whose own
  per-slot check stays as the concurrency belt.
- **`docs/runbook-deploy.md` is the procedure; `docs/DEPLOY.md` becomes the reference.** Two
  runbooks that can disagree is how §5 came to instruct a Tigris-breaking `S3_REGION`. The
  wrong values were corrected in place rather than left for the new file to contradict.
- **`S3_REGION` and `S3_ENDPOINT_URL` went into `fly.toml` `[env]` rather than the secret
  list.** Neither is sensitive, and `[env]` is reviewable in a diff. The runbook says
  explicitly not to set them twice.
- **The verification script requires `DATABASE_URL` and `JWT_SECRET`.** Two of its six
  checks cannot be done over HTTP — no route reports the schema revision, and `dev-login` is
  compiled out of a production build, which `blocked.md` already recorded as unsolvable for
  a deployed preflight. It uses a narrow `DatabaseSettings` subclass rather than the app's
  full `Settings`, so verifying a deployment does not require inventing a bundle id.
- **The Deploy workflow's `api/**` path filter was left alone**, even though it now fires on
  changes to `api/scripts/`, which `.dockerignore` keeps out of the image. Narrowing a
  filter risks skipping a deploy that was needed; an occasional redundant one does not.
- **The scheduler was not removed, and should not be.** It is still the only thing that
  expires lapsed assignments — the read path deliberately does not — so without it the
  `waiting` list grows without bound. That is a slow product problem, not data loss, which
  is exactly the demotion this work was for.

## Aug 10, 2026 — `ios.yml` is dispatch-only until launch

The Aug 9 trims were real and still landed less than the problem needed. Across the first 53
`ios.yml` runs that got a runner: 270 minutes of wall clock, **2,701 billed** — the whole
2,000-minute private-repo allowance, gone in two days.

- **It stopped being an iOS problem the moment the allowance ran out.** Actions is metered per
  account, not per workflow, so exhausting it hard-stops *everything*: `ci.yml` on Linux died
  at 11:19 UTC and `backup.yml` at 09:44, both in about four seconds, both with no runner
  assigned and the same annotation about payments or the spending limit. The last good backup
  is Aug 9 08:58, and every daily after it fails until billing is settled. A gate that takes
  the archive's insurance down with it has inverted its own purpose. The Aug 9 note reasoned
  about `ios.yml`'s share of the budget; the thing that actually mattered was that its share
  was not ring-fenced from anyone else's.
- **The `push`-on-main leg cost the most and proved the least.** 29 runs, 1,320 billed minutes
  — 49% of the total — re-testing merge commits whose pull request had passed minutes before.
  Aug 9 kept it "so a direct push to main is still gated"; no such push exists in this repo's
  history. It was insurance against something nobody does.
- **Dispatch-only rather than deleted.** The file, not the runs, is where the value
  accumulated: runtime simulator discovery by UDID, `/usr/lib/postgresql`-style PATH ordering
  for the toolchain, the warning gate's explicit directory list. Each was learned from a red
  run. `workflow_dispatch` keeps all of it one tap away before a release and costs nothing in
  the meantime.
- **What is actually lost, stated plainly.** Cold-build warning detection is the one benefit a
  local run does not reproduce — a warm `xcodebuild` reports zero warnings on code that has
  plenty, which is exactly how nine real ones stayed hidden. Until this comes back, `rm -rf`
  the DerivedData path before trusting a local zero. The other two — building the merge result,
  and `Config.xcconfig.example` being provably complete — degrade to convention.
- **Not deferred to a self-hosted runner.** It would be free and it is the same Mac the code is
  written on, which is also the objection: the cache is warm, so the warning gate would go
  green for the reason it exists to catch, unless the workflow clears DerivedData first and
  gives back the speed that was the point.

**Aug 10, 2026** — Today v2, built against the design export at `docs/mobile-app-design-today/`.
The import tripped three of the phase's four stop conditions; the full reasoning is in
`docs/today-v2-inventory.md`, and the judgment calls are these.

- **The prototype disagrees with its own token file, and the token file wins.** `RASCAL Today -
  Paper.dc.html` hardcodes `PERI #4B58D4`, `SAGE #5C7A56`, `PERI_B #DDE0F6`, `SAGE_B #DAE7D7`.
  The same bundle's `tokens/colors.css` carries `#5566D6`, `#4B7A4F`, `#DADDF7` — matching
  `Palette.swift` exactly. So the disagreement is one file's, not the design system's, and
  `#4B58D4` sits against the Rejected bullet "electric cobalt as the secondary color". Palette held.
- **Paper grain is out.** The bundle states three times that it is mandatory identity — "a RASCAL
  screen without grain looks wrong" — but `docs/design-system.md` is the authority for writing
  SwiftUI, defines no grain token, and lists "screen-print texture" first among its anti-patterns.
  Neither decisions file mentions grain, paper or noise at all; the absence is unsettled rather
  than permissive, so it needs a decision rather than an invented render path.
- **Card radius stays 20.** The bundle deliberately specifies 24 for app prompt cards. But
  `Layout.cardRadius` is shared by Timeline, Moments, Settings and the composer — 24 either
  restyles every screen or makes Today the only one that differs.
- **The STORIES rail was dropped, and the data exists.** `GET /children/{id}/moments` already
  serves throwbacks and `Moments/ThrowbackCard.swift` already renders them. It was dropped because
  it needs a second call from the screen the contract calls "the single call the home screen
  makes", and because on an archive this young the rail would show the `fallback: "random"` branch
  almost every day — which is the screen Moments was built to be.
- **Skip is a swipe with an eight-second grace window, not an optimistic delete.** There is no
  un-dismiss endpoint. `POST /assignments/{id}/custom` does resurrect a dismissed row, but only by
  overwriting `custom_body` and flipping `is_custom` permanently, so building Undo on it would mean
  corrupting a row to fake a retraction. Instead the row hides immediately and the `dismiss` request
  is *held* for the toast's life. Undo means it was never sent. The failure mode is that a kill
  inside the window loses the skip and the prompt stays — the safe direction, since nothing
  disappears that the parent cannot see. Eight seconds rather than the usual five because VoiceOver
  has to finish announcing the toast before anyone can act on it.
- **The board became a `List`.** `swipeActions` exists only on `List`, and a hand-rolled drag would
  fight the scroll view and be invisible to VoiceOver — which is the whole reason the skip is
  allowed to be a gesture at all.
- **`daysUntilExpiry` anchored on the device's day and now anchors on the server's.** It compared
  a `family_timezone`-computed `expires_on` against `Calendar.current.startOfDay(for: Date())`,
  so a parent in a different zone from their child saw the wrong number. Pre-existing and unrelated
  to the import, fixed because this phase rewrote that exact function. Both DST boundaries are
  covered by tests.
- **The completion burst was not built.** A 96pt disc with an expanding ripple is compliant in kind
  with "circular terracotta checkmark + spring + haptic … no stamp, no confetti" and louder in
  degree. Judged not mine to escalate unilaterally.

## Phase 12 — the share sheet

- **`ImagePipeline.swift` is compiled into the extension rather than its EXIF reader being
  reimplemented.** The brief says the derivation must not be reinvented, and target membership is
  the only way to guarantee the shared photo's date is produced by literally the same code as the
  picked one's. The file is pure ImageIO with no API model and no SwiftData; the calls the
  extension makes (`exifDate`, `makeThumbnail`) read metadata and downsample without ever decoding
  a full image. The alternative — a second small reader — is the divergence the widget's
  duplicated `symbolName` mapping needs a test to prevent, and here there was no need to accept it.
- **`Formatting.swift`, `Layout.swift` and `Motion.swift` joined `Palette` and `Typography` in the
  extension target.** Reaching `Palette` was the requirement; these three are what *using* a
  Palette token correctly costs — `typeRole`, the card and capsule shapes, `TapScaleButtonStyle`,
  and `DurationText` for a video's spoken duration. All are SwiftUI-and-Foundation only. Nothing
  beyond target membership was needed, so the design system reaches the extension unchanged.
- **`ShareCopy` was extracted out of the extension's views into `Rascal/Share/`.** The extension is
  its own module and the test host is the app, so a string built inside `ShareComposer` could only
  be verified by looking at a screenshot. The date sentence is the only warning a parent gets
  before a photo from another year is filed under this week; that is not a thing to eyeball. It
  immediately earned itself — see the grammar defect below.
- **The date is shown and not editable.** The brief asks for it to be visible before saving, which
  it is, in `DatePill`'s vocabulary. A graphical picker is most of a share sheet's height, and the
  entry is editable in the app the moment the drain files it. Recorded because it is a narrowing of
  what "using the DatePill vocabulary" could have meant.
- **Video previews are a glyph tile, not a poster frame.** Extracting one means
  `AVAssetImageGenerator` on a file that may be a 4K minute, inside the process with the memory
  ceiling, to draw an 84pt tile. `MediaPreviewRow` already answers "this media has nothing to draw"
  with a tinted glyph tile for voice notes; this is that answer in terracotta, which is the colour
  video owns. Duration comes from the metadata read that `occurred_at` needs anyway.
- **A record naming files that are all gone, with no note on it, is removed rather than retried
  forever.** The same situation `MediaCoordinator.beginUpload` calls unrecoverable when a staged
  original has vanished. Nothing is destroyed — the bytes were already gone — and creating an empty
  entry from a lost photo would be a lie about what the parent saved. A note with no surviving media
  still becomes a text entry, because the words are real content.
- **A deleted entry reaps its inbox copy even though the server never heard of it.** Without this
  the record sits in the container permanently, retried on every launch against an entry that exists
  precisely so it can be gone.
- **`sweepOrphans` refuses to run at all while a record this build cannot read is present.** Such a
  record names files whose names are unreachable from here, and sweeping past it would delete the
  media belonging to a record a newer build wrote — the one deletion in this feature that could
  destroy a photo.
- **`CFBundleDisplayName` is the literal string `Rascal`.** `$(PRODUCT_NAME)` resolves to the target
  name and would put "RascalShare" in the share sheet. One more place open decision #1 has to change
  when the name closes; the widget gallery was the first.
- **The extension does not know which child a share is for.** It has no session and no
  `GET /children`, and asking inside a twelve-second screen is a question that cannot be afforded.
  The app resolves it at drain time from the child the gate already has. The consequence is that a
  share made before onboarding waits rather than failing, and nothing tells the parent it is
  waiting — flagged in §8 of the device checklist rather than solved.
- **The memory test was rewritten after it passed a mutation it should have failed.** A
  before-and-after `phys_footprint` reading did not move when `FileManager.copyItem` was replaced
  with `Data(contentsOf:)`, because Foundation maps a file that size and mapped clean pages are not
  charged. It samples a peak on a second thread now and reports 316MB against a 40MB ceiling for a
  materialising read. The mmap blind spot is documented in the test rather than left to be
  rediscovered.
- **A screenshot found a grammar defect that two passing assertions had covered.** The fallback
  sentence read "These files don't say when *it* was taken". The suite asserted a prefix and a
  substring, both true of the broken sentence. The assertions are whole sentences now — a partial
  assertion on a sentence tests that the sentence exists, not that it reads.
- **`content_size default` is not a valid `simctl` argument.** It returns "Invalid argument" and
  leaves the previous value alone, so the first set of screenshots was six frames all at XXL, two
  pairs byte-identical. iOS's default size is `large`. Worth recording for whoever writes the next
  harness.

### What a second, adversarial read of phase 12 found

Three real defects on top of a green suite, recorded because the first one is the kind that only
shows up under a race and would have been blamed on the server.

- **`ShareDrain` had no re-entrancy guard, and both of its siblings do.** `EntrySync.running` and
  `MediaCoordinator.sweeping` exist for exactly this; the drain was written as a struct and got
  neither. `RootView.runSweep` is called from `.task` **and** from `scenePhase == .active`, which on
  a cold launch fire within a moment of each other, and converting a video suspends — so a second
  pass reads the same record, sees no entry for it yet, and creates it too. Measured before the fix:
  two concurrent ingests both returned `ingested == 1`. `Entry.id` being `@Attribute(.unique)` hides
  it as an upsert **until the first pass has been pushed**, at which point the second insert replaces
  a synced row with a fresh `pending` one carrying a new `idempotencyKey`, and the next push creates
  a second entry server-side. Now a class with a `running` flag, and a test that fails without it.
- **`ShareInbox.stage` cleared its destination before copying.** A re-stage whose copy then failed
  would have destroyed a good file to make room for one that never arrived. Fresh UUIDs mean it
  cannot trigger today; it is still the wrong shape in the one path that holds the only copy of a
  photo. The destination is displaced only once a complete replacement is on disk.
- **`SharePreviewRow` decoded its thumbnails inside `body`.** The composer's `MediaDraft.image` does
  the same and it is fine in the app, but a share extension has a hard memory ceiling and SwiftUI's
  decision to re-run a body is not a thing to reason about. Decoded once into `@State`, and only for
  the tiles actually on screen — a twenty-photo share now costs four thumbnails rather than twenty.

Two smaller corrections with them: `ingested` was counted even when `context.save()` failed, which
is a return value contradicting the store; and `viewDidDisappear` discarded staged bytes without
checking the sheet was being dismissed rather than merely covered — the failure directions there are
"leak a file the sweep collects" versus "delete a photo someone is about to save", and only one of
those is acceptable.

- **The suite never proved the two halves agree.** Every drain test builds its record by hand, so a
  mismatch between what `ShareComposerModel.save()` writes and what `ShareDrain.ingest()` reads would
  have passed everything. Closed by temporarily compiling the extension's files into the app target
  and running the real model over real `NSItemProvider`s into the real drain — three photos, two
  dated, one entry, `occurred_at` at the earlier EXIF time, note trimmed, originals and thumbnails
  staged, inbox copy held until `existsOnServer`. Not committed: it can only exist while the
  extension's UI is compiled into the app, and leaving it there would ship the share sheet inside the
  app. Removed the way the screenshot harness was.

## Aug 10, 2026 — the first real deployment

The API is live at `https://rascal-api.fly.dev`. `verify_deployment.py` passes 6/6, Smoke is
green, and an hourly scheduler machine sits beside two app machines in `ord`. What follows is
only what the run decided, or got wrong — the procedure itself is `docs/runbook-deploy.md`.

- **Actions was blocked by a $0 budget, not a failed payment.** The annotation names both, and
  the payment clause reads first. Five product budgets sat at $0 with "stop usage" on; raising
  Actions to $10 cleared it. Recorded in `docs/blocked.md` §0 because it has now happened twice
  and been misread as a card problem twice.
- **The existing Neon database was reused rather than a fresh one created.** It was already at
  `0004_full_text_search` with 113 prompts from the *Migrate Neon* workflow, so the release
  command's `alembic upgrade head` was a no-op on the first deploy — which is the right shape:
  deploy day should not be the first time the real database sees the schema. The database is
  named `neondb`, not `rascal`; the runbook's `rascal` was always an example.
- **Both Neon URLs were verified before being set, not after.** Sync engine on the direct
  endpoint (Alembic's path) and async engine on the pooled one (the app's path), each executing
  a real query. The two-URL split has exactly one failure mode and it is silent until a
  migration; paying thirty seconds to rule it out beat reading a mid-migration lock error.
- **`channel_binding=require` was left in both URLs** rather than trimmed to match the
  documented form. psycopg 3 passes it through and both engines connected with it present.
  Editing a working connection string to match a document is the wrong direction.
- **The Tigris credential was round-tripped before it became a Fly secret.** A fresh key has no
  permissions until `access-keys assign`, and the resulting failure reads as bad credentials
  rather than a missing grant — so a real PUT/GET/DELETE plus a presign host check ran first.
- **`deploy.yml` failed a healthy deploy over a status string.** It required `succeeded`;
  flyctl 0.4.81 says `complete`. The app was serving and migrated while the workflow went red.
  Now accepts both, because the alternative is tracking whichever word flyctl prefers, and a
  red X over a working deploy is the failure that teaches you to ignore red Xs.
- **The runbook's `fly machine run` built the wrong machine, silently.** Two causes, both worth
  keeping: `fly machine run` does not read `fly.toml`, so `[env]` never reached it; and
  `--command` is for `--shell` and is otherwise dropped without a warning, so the machine ran
  the image's default CMD — a second uvicorn, hourly. Fixed in all three places the command was
  copy-pasted. `fly machine status --display-config` is the check: `"init": {}` means dropped.
- **The scheduler machine pins the deployed image rather than rebuilding from `.`.** Same
  result, no second build, and the image it runs is provably the one serving traffic. It still
  does not follow later deploys — that was already true and is still the reason not to let the
  archive depend on it.
- **`--restart no` on the scheduled machine.** It runs to completion and exits 0. The default
  `on-failure` turned the misconfigured first attempt into three reboots instead of one clean
  failure, which is noise in exactly the logs you are reading to find the problem.
- **Two app machines were left running, not scaled to one.** `fly deploy` creates an HA pair by
  default and `min_machines_running = 1` is a floor rather than a count. Roughly $6/month
  instead of $3. Flagged rather than silently halved: the redundancy is real, and the call is
  the account holder's.

## Phase 13 — Settings v2 (design import)

- **The Settings export renders one direction, not the two it advertises.** Its header says
  "two directions" and `b1` is fully authored — a navy card, an amber progress bar, dot
  swatches, a periwinkle label tag — but `renderVals()` returns `1a` alone, so `b1` is dead
  code in the prototype. Built `1a`. Implementing a constant the designer's own file never
  draws would be building something nobody has looked at.
- **`tokens/colors.css` matched `Palette.swift` exactly for the third phase running.** Eleven
  hardcoded values in the prototype appear in neither file. Snapped all eleven, added no token.
  The rule settled after Moments and Today did not need relitigating and did not get it.
- **The hero is `terracottaSoft`, not `Gradients.wash`.** The import puts a three-stop gradient
  behind the child card and the palette has its own version of it — but `inkMuted` over that
  gradient measures **4.22:1** on the middle stop, under AA, and the wash is reserved for
  emotional beats besides. `terracottaSoft` is the import's own first stop to the digit, is the
  tinted fill `PromptCard` already pairs with the cream hairline, and measures 4.69:1. The
  "is the child an emotional beat?" argument never had to be had.
- **The export card's photo-stack motif is three rotated cards, which is a named anti-pattern.**
  `transform:rotate(-9deg)`, `rotate(5deg)`, `rotate(-2deg)`. `design-system.md` lists "passport
  stamps, receipt-spike stacks, rotated cards" and says "rejected twice already". Dropped rather
  than softened — the bullet names the exact construction.
- **Three elements were dropped for want of a number rather than for taste.** The hero's stats
  strip, the `First entry` row, and the sync progress bar all need archive-wide counts. No
  endpoint serves them, and the local cache is paged and partial by construction, so any figure
  would be a claim about how much of the archive this phone happens to hold. `design-system.md`
  already settles that exact rule for `TimelineHeader`.
- **`Recompute ages` was refused a seat in `Advanced`.** The import groups it with the dry run
  and the reset. It kept its own card and its own whitespace: a divider between two rows says
  "these belong together", and rewriting every stored age in an archive is not a neighbour of
  asking the server what changed. Everything else about the grouping was adopted verbatim.
- **The section label stayed `inkMuted` and the closing note did too.** The import sets both
  `inkFaint`, which measures **2.13:1** on the canvas. `design-system.md` settles section
  headers as `inkMuted`, and `SectionLabel` is shared with three other screens — restyling it
  here would have restyled them.
- **Chevrons stayed `inkMuted`.** The import's `#C4BAAE` measures 1.88:1 on `surface` and even
  `inkFaint` measures 2.19:1, both under the 3:1 a non-text control is asked for. A chevron
  carries nothing VoiceOver needs, but taking a control *down* toward 2:1 to match a mockup is
  the `KindBadge` mistake in a new surface.
- **A flag that had never changed a pixel was removed rather than revived.** `valueIsMuted` on
  `SettingsRow` and `SettingsValueRow` resolved to `inkMuted` in both branches, and both call
  sites passed it. The import settles the question it was reaching for: every trailing value in
  it is `#6E6A63`, and the two toned variants its own row helper supports are never invoked.
- **`SyncStatusModel` was being built in `.task`, which runs once.** `RootView` builds the
  `SyncEngine` in *its* `.task`, so a render reaching Settings first left the engine nil, and
  `syncStatus` was then never retried — the dry run, the reset and the pull toggle absent for
  the whole session with nothing on screen saying so. Pre-existing since PR #21; found by
  running the app rather than reading it, because the screenshot harness launches straight into
  Settings and that *is* the race. Now `.onChange(of: syncEngine != nil, initial: true)`.
- **The hero's padding lives inside its button.** `cardSurface` pads and then fills, which put
  a 16pt ring of card outside the tap target — including the corner a thumb reaching for the
  avatar lands on. `SettingsCard` gained a `fill` instead, so the content pads itself, which is
  how every row on the screen already worked.
- **Paper grain: still out, still unresolved.** Third phase to drop it and decline to settle it.
  The bundle calls it mandatory identity, `design-system.md` opens its anti-patterns with
  screen-print texture, and neither decisions file mentions grain at all.

## Aug 10, 2026 — closing the five gaps the iOS lane was working around

Everything here was open in `docs/blocked.md` as "the client shipped a workaround rather than
a patch to the backend". The workarounds were the specification.

- **`unlock_at_age` now distinguishes an absent key from an explicit null**, via
  `model_fields_set` rather than a sentinel value. A sentinel would have had to travel through
  the service signature and the sync schema as a third state nothing else in the codebase uses;
  setness is what `PATCH` already gets free from `exclude_unset`, and the two routes disagreeing
  about what null meant was the actual defect.
- **The same fix went into `/sync/push`, which nobody asked for.** The blocked entry only named
  `POST /entries`. But `_apply_entry` creates entries through the same service, and that is the
  path a letter written offline takes — arriving hours later, with the parent long gone from the
  screen where they turned sealing off. It is the worse of the two to get wrong.
- **`prompt_body` is the assignment's `resolved_body`, not `prompts.body`.** A parent-authored
  `custom_body` wins, because the point is to quote what was on screen. Using the raw prompt
  would have quoted the sentence the parent replaced.
- **`sealed` is its own query parameter, not a seventh `entry_type`.** Sealing and artifact kind
  are orthogonal — a sealed photo is possible and has to stay findable as a photo — so folding
  them into one enum would have made the two mutually exclusive.
- **`_loaded` became public `loaded`, and `/sync` now uses it.** Sync selected entries itself and
  restated the eager-load list by hand, so every field `to_entry_out` learned to read had to be
  remembered in two places. `Entry.assignment` is `lazy="raise"`, which turns that miss into a
  500 on the sync path alone — invisible to every timeline test. There is now a test that pulls
  `/sync` and asserts `prompt_body`, and it fails if the shared helper is bypassed.
- **`Entry.assignment` is `viewonly=True`.** Deleting an entry must not touch its assignment —
  `release_assignment` puts it back to `pending`, which is the opposite of a cascade.
- **The avatar presign stores nothing.** It returns a key; `PATCH /children/{id}` commits it
  after the PUT succeeds. The alternative — writing `avatar_key` at presign time — makes an
  abandoned upload into a child record pointing at bytes that never arrived, and only that
  failure is visible to a parent. A fresh UUID per presign rather than a stable `avatar.jpg`,
  so a replaced avatar is never indistinguishable from a corrupted one.
- **`GET /avatar-url` 404s rather than returning a null URL.** "No avatar" and "a URL that will
  not resolve" are different answers, and only the first lets a client draw initials without a
  round trip that fails.
- **`children.pronouns` is a closed set of three, and null means unanswered.** Free text would
  not survive its only consumer: pronoun substitution has to enumerate the forms it writes.
  Widening the set is a migration; storing text nothing can render is not undoable by one.
  Null deliberately does not mean `they/them` — a parent who skipped the question said nothing,
  and `decisions.md` open item 10 is about prompts reading correctly rather than confidently.
- **The three assertions that mattered were checked by breaking the code**, not by trusting a
  green run: dropping the setness guard fails both sealing tests, and reverting `/sync` to its
  hand-written eager loads fails the sync serialization test with a lazy-load error. All 24 new
  tests passed on first run, which is exactly when they are least trustworthy.

## Push notifications (server side)

- **Branched off the Phase 12 branch, not `main`.** The brief said "off `main`", but
  `ensure_day_filled` — the shared path this job is required to reuse — is not on `main`; it
  lives only on the unmerged `claude/deploy-readiness-scheduler-5pr0uh` and has no open PR.
  Branching off `main` would have meant writing a second copy of the selection logic, which
  the brief forbids in stronger terms than it asks for the base branch. The PR therefore
  carries Phase 12's commit as well as this one.
- **One child per user, the oldest they are a `parent` of.** The rule is one notification a
  day *per user*, and sending per child would quietly turn that into N. `viewer` guardians
  are excluded entirely — a grandparent with read access did not sign up for a nightly
  reminder to do somebody else's mission. Second-kid handling is roadmap open item 7.
- **The mission slot wins the one notification**, then weekly, monthly, letter, question. A
  nudge is for the thing you go and do; a question is answered in conversation and needs no
  reminder to be answerable.
- **A user with no registered device is not recorded as sent.** Nothing was attempted, so
  nothing is claimed, and a phone that registers an hour later still gets today's — as long
  as the window has not gone stale.
- **A failed send still burns the day.** The `notification_sends` row is written before the
  push, so a delivery failure is logged and dropped rather than retried on the next hourly
  run. "Never queued into tomorrow" is in the brief; this is the same rule applied within
  the day.
- **`DELETE /devices/{token}` revokes both environments.** The path carries a token and no
  environment, sign-out means this phone stops receiving on this account, and a phone that
  has run both a development and a TestFlight build holds a row for each.
- **A token that re-registers under a different account moves to it.** The phone reports the
  same token either way, and the alternative is the previous account's notifications landing
  on the new account's lock screen.
- **No `/debug/notifications/run` route.** The scheduler has one, but this job is reachable
  as `python -m rascal.jobs.notify --as-of`, and a new debug route is new surface for
  something a CLI already covers.
- **`notification_sends` has no `updated_at` and no soft delete.** It is a system ledger, not
  user data: it never syncs and there is nothing to restore, the same reasoning that leaves
  `refresh_tokens` and `idempotency_keys` without them. `devices` gets both, because it is a
  thing a user owns and revokes.
- **`platform` is `ios` only.** APNs is the only transport implemented; a browser would need
  WebPush, a different protocol and a different credential. `text` + CHECK, so that day is an
  `ALTER`.
- **Added `httpx[http2]`.** APNs speaks HTTP/2 and nothing else, so the `h2` extra is what
  makes the real client able to open a connection at all. No new top-level dependency.
- **Froze migration `0001`'s trigger list as a literal.** It imported the live
  `TABLES_WITH_UPDATED_AT`, so adding any later table with an `updated_at` would have made
  `0001` attach a trigger to a table that did not exist yet, breaking `upgrade head` from
  empty. Unrelated to push, but it blocked it.
- **Extended `EXPECTED_TABLES` / `EXPECTED_INDEXES` / `EXPECTED_CHECKS` in both
  `test_migrations.py` and `.github/scripts/verify_schema.py`.** Both are subset checks, so
  leaving them alone would have passed — and left two new tables unverified on Neon, which is
  the one place it matters. A test enforces that the two lists agree.
- **Changed one existing assertion.** `test_me.py` pinned the `/me` response to an exact set
  of five keys; the preference fields are required to be on `/me` by the brief, so the set
  grew to seven. It is the only existing test touched.

---

## Aug 11, 2026 — Lane A: production audit of the notification feature, before the PR

Asked to be certain this belonged in production rather than merely finished. Four things
were not right. Recorded here because three of them were invisible from the diff alone.

- **The migration chain had two heads.** `0005_devices_and_notifications` was cut against
  `0004_full_text_search`, but `0005_child_pronouns` landed on `main` first from the same
  parent. Rebasing produced a fork, and `alembic upgrade head` refuses to run with two
  heads — the deploy's release command would have failed. Renamed to
  `0006_devices_and_notifications` and re-pointed at `0005_child_pronouns`. Verified by
  walking the exact path production will take: `0005_child_pronouns` → head → back down.
- **The once-a-day guarantee did not survive a crash, though the docstring said it did.**
  The claim row was inserted before the push but committed only at the end of the whole
  run, so a process that died part-way through rolled back every claim it had made while
  the notifications those claims covered had already been delivered. The next hourly run
  would have sent them again — the one thing this feature must never do. Now committed per
  user, immediately after the claim. Two tests cover it, and both fail on the old code.
- **A malformed `.p8` was a permanent silent miss, and the fix above made it worse.** An
  unreadable key raises out of `send()` as a bare `ValueError`, uncaught by the
  `except httpx.HTTPError` around it. With the claim now committed first, that meant the
  user was recorded as notified, heard nothing, and was skipped the next run. Validated at
  `build_push_client` instead, which claims nobody and exits with an actionable message;
  `send` also degrades a signing failure to a result rather than an exception, so one bad
  key cannot cost the *remaining* users their notification too.
- **Runbook §4b told you to build the wrong machine.** It carried the short
  `fly machine run . --command …` form verbatim — the exact command `c5e06ad` records as
  having silently produced an hourly second copy of uvicorn, because `--command` belongs to
  `--shell` and is otherwise dropped without a warning, and because `fly machine run` never
  reads `[env]`. Rewritten to match §5's corrected form, including why each flag is there.

Smaller calls:

- **`_deliver` now takes plain values, not ORM objects.** A commit sits between loading the
  devices and pushing to them, and `resolved_body` reaches through a `lazy="raise"`
  relationship. Reading everything off the ORM before the commit means the delivery path
  cannot be broken by whatever a commit does to the identity map, rather than being correct
  only because `expire_on_commit=False` happens to be set.
- **Device revocation is a Core `UPDATE` by id** rather than an ORM attribute write, for the
  same reason, and `WHERE revoked_at IS NULL` keeps the count honest under a concurrent run.
- **`DELETE /v1/devices/{token}` keeps the token in the path.** It lands in Fly's proxy logs
  and uvicorn's access log, which is not nothing — but an APNs token is an address, not a
  credential, and is useless without the provider key. Changing it would be a contract change
  for a privacy gain that does not exist. Noted rather than acted on.
- **`main`'s roadmap figure of 315 API tests was stale** and its own note said so. Re-measured
  from a clean worktree at `origin/main`: 339 in 25 files. This branch is 413 in 29.

## Phase 18 — the backfill surface (Aug 11, 2026)

- **The camera roll got its own entry point and `+` got a sheet, reversing the morning's
  decision.** Raised as a reversal rather than built quietly, because the composer-row placement
  had been chosen partly on the grounds that it cost the primary action nothing. It now costs one
  tap on every entry. See `docs/decisions.md`; if that trade is wrong, the sheet is the thing to
  change, not the flow behind it.
- **A selection is confined to one day, and nothing is preselected.** The plan allowed month-wide
  multi-select with three chosen for you. The earliest-date rule makes a spread selection's date
  defensible rather than accurate, and one day makes it exact. The rule lives in
  `BackfillSelection` rather than in `@State` so it can be asserted.
- **`BackfillScanResult.months` is optional purely so old caches still decode.** A non-optional
  field fails the decode, `load()` swallows that as a miss, and every device rescans its whole
  library once after the update. Cheap to get right, invisible to get wrong.
- **The child's birthdate travels from the gate as a parameter**, the same way `family_timezone`
  already does and for the same stated reason. `GET /today` carries only `age_months`, which is an
  age as of today and says nothing about a month in 2019.
- **Ages in this flow come from `DraftAge`, the one client-side age calculation.** A month with
  nothing written in it has no server `child_age_months` to render. Never stored, never sent, and
  replaced by the server's number as soon as an entry exists.
- **Nothing downloads, on any path.** Both new `PHImageManager` calls set
  `isNetworkAccessAllowed = false`. Cloud-only assets are counted so the totals stay honest, shown
  as unavailable, and refused as selections.
- **Four accessibility-sized layout defects were found by screenshotting, not by reading.** The
  worst left the permission screen with no reachable way to grant or decline at XXL — on a prompt
  iOS only offers once. Warm builds also under-report warnings; the cold figure is the real one.

## Documentation reconciliation (Aug 11, 2026, evening)

- **`roadmap-status.md` was a day behind `blocked.md` on the two facts that mattered most**, and
  the stale one was the one being read. Enrollment and Fly were struck through as resolved on Aug 10
  in one file and reported as blocking everything in five places in the other. Corrected by
  striking rather than deleting, so the failure stays visible in the section that produced it.
- **Every API-side figure the status file had been carrying forward was wrong.** Three consecutive
  revisions labelled them stale and carried them anyway; "one revision stale" compounded into 33
  missing tests, 8 missing operations and 4 missing entries. Re-derived, not re-copied. The lesson
  written into the file: labelling a figure stale is not the same as it being harmless.
- **Six Lane A gaps recorded in `blocked.md` had been built and none were marked resolved** — the
  seal's setness, `children.pronouns`, both avatar routes, `EntryOut.prompt_body`, `?sealed=`, and
  the tag `source`. Checked by grepping merged code on `main`, one grep per claim, with the greps
  left in the file so the next reader can repeat them.
- **Three client-side workarounds outlived the server fixes that justified them** and are now
  recorded as deletions rather than as blockers: `unsealIfTheServerSealedItAnyway`, the composer's
  prompt-body cache, and `TimelineModel.drain`'s ten-page `clientFilterPageBudget` loop.
- **`main` is red on one `ruff` E501** (`0007_prompt_suppressions.py:82`) with `test` and `image`
  green. Recorded rather than fixed: this pass was a documentation review, and the fix is an
  API-lane code change that nobody asked for.
- **The production media bucket was verified by reading its configuration, not the runbook.** Soft
  delete is on with 30-day retention — the one setting on this project that could not have been
  corrected after the fact. Delete protection is off on all three buckets, which is a different and
  smaller risk, now written down.
- **Four open decisions were answered by the owner** (tone, notification time, second child, did-it
  entries in the book). Tone is the only one with downstream cost: the 79 unreviewed candidates were
  generated against the dry library, and `generate_prompts.py` reads the library as its style
  reference every run, so warm prompts have to reach the library before generation compounds the
  old voice. The seeded 113 are deliberately **not** being rewritten.

## The letter, and the day you are allowed to write one (Aug 11, 2026)

- **Decided: a letter can be written on any day. The 15th is the reminder, not the permission.**
  Design is being done in Claude Design; nothing was built, planned, or scaffolded here. The API
  needs no change — `POST /entries` already takes `unlock_at_age` and reads its setness correctly
  since the create-route fix.
- **The scheduling decision is untouched.** Letters keep their own slot on the 15th, for the
  original reason: the money letter must not lose a monthly coin flip to a height measurement.
  What changed is that the slot was acting as a ration, and that was never decided.
- **This came out of a documentation defect, which is worth recording as one.** "The sealed letter,
  whole" described a finished feature across four paragraphs and never said where the control
  appears. The section read as *shipped*; the app read as *there is no way to write a letter*. Both
  were accurate. A feature section that does not say how the feature is reached cannot be checked
  against the app by the person reading it, and that is now written into the section itself.
- **Left open deliberately, not bundled in:** editing the seal on an entry that already exists.
  `PATCH` supports it, no UI calls it, and `isOffered` is false while editing — so an age set by a
  stepper mis-tap is permanent from inside the app, quietly. Raised, not chosen.

---

## Aug 11, 2026 — Phase 19: three missions a day

Implementation-level calls the brief left to me, and the two places it asked me to check
rather than assume.

- **The theme window needed no change, and that is worth writing down rather than just
  reporting.** The brief flagged that the rule was written for a pair and asked whether it
  covers three picks. It does, by construction: `_fill_slot` inserts each assignment before the
  next slot is selected, and `_history` re-reads the child's day per pick inside the same
  transaction, so the third pick sees the first two exactly as the second saw the first.
  Nothing counts slots, so a fourth would need nothing either. Proven by a test whose pool
  makes the right answer forced rather than lucky, and confirmed by breaking the window to
  exclude today and watching that test fail.
- **`ensure_day_filled` needed no change either.** Both it and `run_scheduler` reach the day's
  slot list through `slots_for`, so `mission_b` arrived in both from one edit. There is still
  exactly one selection path and no second copy to drift.
- **The downgrade deletes `mission_b` rows before narrowing the CHECK**, following 0002's
  letter-slot pattern. Ran it against a real Postgres holding an actual `mission_b` row rather
  than reasoning about it: upgrade, insert, downgrade, confirm the row is gone and the
  constraint narrowed, upgrade again. The deletion is destructive and correct — the row has no
  representable slot at the previous revision — and `entries.assignment_id` and
  `notification_sends.assignment_id` are both `ON DELETE SET NULL`, so the archive keeps the
  entry and loses only the link to what asked for it.
- **`MISSION_KINDS` was left alone and two new tuples were added beside it.** It still feeds
  the weekly and monthly slots, so narrowing it would have silently changed the monthly
  measurement slot — a slot this phase does not own. `MISSION_KINDS_PHOTO` and
  `MISSION_B_KINDS` name what the two daily slots draw.
- **`DAILY_SLOTS` in `constants.py` was updated even though nothing reads it.** A constant that
  says "the daily pair" while the day holds three is the drift this project treats as a defect,
  and a dead constant is the easiest kind to be wrong.
- **`SERVE_INTERVAL_DAYS` in `pool_health.py` gained `mission_b` explicitly**, though its
  `.get(slot, 1)` default would have produced the same answer. Relying on a default to be
  accidentally correct is how the next slot with a different cadence gets reported wrong.
- **`pool_health` reports per *kind*, not per slot, and that is now more misleading than it
  was.** `mission_b` comes back as three rows — video 10, audio 11, activity 16 — when the slot
  actually draws from all 37 pooled. The same was true of `mission` before this phase, so it is
  pre-existing rather than introduced, but the split makes it easier to misread. The PR states
  slot-level figures; the endpoint was not changed, because reshaping it is not this phase's.
- **The monthly slot reports `relaxation_active: true` for video, audio and activity**, because
  it draws `MISSION_KINDS` and the library holds no monthly prompts of those kinds. Noise in
  the report, pre-existing, and fixing it would mean editing `MISSION_KINDS`.
- **iOS: `mission_b` had to become a real `Slot` case rather than falling to `.unknown`.** An
  unrecognised slot deliberately renders as a neutral grey card with no tint — correct for a
  value from a future server release, wrong for one of the three cards a parent sees daily.
  That forced updating one exhaustive switch (`PromptCard.footnoteLabel`); every other use of
  `Slot` is a comparison rather than a switch.
- **Both daily missions display as "Mission", with no A and B in the copy.** Numbering them
  invites the reading that one is optional, or that the pair is a checklist to clear, which is
  the streak thinking this product refuses.
- **The widget change is a fallback, not a reordering.** It already showed `mission` first,
  which matches the push ladder; what it lacked was second place. `mission` draws the thinnest
  pool of the three, so an empty `mission` is a real and recurring case, and without the
  fallback the widget would show no mission at all while one sat on the Today board.
- **Preview fixtures were re-pointed at the slot each kind now belongs to.** They are DEBUG
  only and nothing asserts on them, but a preview showing an audio prompt in `mission` would
  teach the next reader the wrong model.

### The audit pass, and the four things a second read found

Asked to re-read the phase-19 diff as though reviewing someone else's work. It found more
than the §9 hunt had, and the pattern is worth keeping.

- **The §9 hunt for duplicated slot names found three registries and missed a fourth**, because
  I looked where registries live rather than where slot names are *used*. `/debug/board` held
  `spare_slots = ["mission", "weekly", "monthly"]` — a list that predated `letter` as well as
  `mission_b`, so the route whose whole job is "one assignment of every kind" could not place
  five kinds. It is derived from `SLOTS` now. **A guard test for the registries would not have
  caught this**, which is the lesson: the guard covers the places I thought to enumerate.
- **A test can be stale without failing, and those are the dangerous ones.**
  `test_daily_question_and_mission_pools_each_cover_a_fortnight` pooled photo, video, audio and
  activity and asked whether *that* cleared fourteen. It did, and it would have kept saying so
  forever, because the number only grows as prompts are added. Rewritten to ask per slot, which
  is the only version that can fail — and it immediately surfaced that video and audio do not
  clear fourteen on their own.
- **The widget's fallback was tested and the notification's identical fallback was not.** Two
  surfaces, same rule, one covered. Both now, because the two agreeing about which item is "the"
  mission is the actual requirement.
- **`assert len(slots) == 4` was right for a reason the test did not state** — both fixture
  dates are Tuesdays. On a Saturday it is five, and the test would have looked broken when it
  was only badly dated. The precondition is asserted rather than assumed.

Two documentation defects the same pass found, both of the kind this project treats as real:

- **`docs/decisions.md`'s first Settled row still read "One question + one mission per day"**,
  three rows above the row that supersedes it. Marked superseded rather than deleted, because
  the two-item rule is still the reason the letter sits on the 15th.
- **`docs/roadmap-status.md` said `main`'s CI was red on one line.** It was six files; the line
  was simply the one the job reached first. Corrected there as well as fixed in the code,
  because the interesting part is the step ordering — a lint job that stops at its first
  failing step reports its first problem, not its problems.

---

## Phase 20 — onboarding and settings catch-up

- **The onboarding birthday wheel's contrast was a dark-mode defect, not a foreground-style one.**
  Bisected in the harness across four variants. `.foregroundStyle(Color.ink)` is a **no-op** on
  `DatePicker(.wheel)` — measured identical at 1.03:1 with and without it. What fixes it is
  `.environment(\.colorScheme, .light)`, which `EditChildSheet` and `ComposerView` already carry on
  their pickers. The palette is fixed light-mode `Color(hex:)` with no dark variant and the app pins
  no scheme, so on a phone in Dark Mode any *system* control resolves dark-appearance colours over
  the app's cream. Deliberately did **not** add the no-op modifier for symmetry.
- **`OnboardingStepScaffold` now scrolls with its footer in a `safeAreaInset`.** It was a `VStack`
  with a `Spacer(minLength:)` doing the pinning — the same shape Phase 18 fixed on four backfill
  screens. At `accessibility-extra-extra-large` the birthdate step pushed the progress rail up under
  the Dynamic Island. All five onboarding steps share the scaffold, so all five get the fix.
- **`BackfillScanner` now publishes `authorization`, not just `isLimitedLibrary`.** The `+` sheet
  needs the distinction before any backfill screen exists, and `state == .unavailable` is both
  "never asked" and "refused" — which need different sentences.
- **`AddToArchiveModel` was extracted so the four authorization cases are assertable.** The defect
  was a case-analysis bug; a view body cannot be case-analysed in a test.
- **Reused onboarding's `NotifyTimePickerSheet` for Settings rather than writing a second picker**,
  and added the colour-scheme fix to it now that a second caller exists.
- **`Outstanding.total` was left meaning what it meant** — "not in the archive" — so Today's count
  does not move. The split is additive: `failedMedia` is a subset, and `waiting` is the derived
  number Settings shows.
- **The tab bar reports its own height** instead of RootView hardcoding 84. `.offset` moves the
  raised disc without resizing its box, so the bar also carries `.padding(.top, lift)` to make the
  measured frame the bar's real extent.
- **Two existing assertions were replaced, both because the brief overturned the behaviour they
  pinned**, not to make a failing test pass. Named in full in `docs/phases/phase-20-verification.md`.
- **Left open, raised not chosen:** `DatePicker(.wheel)`'s unselected rows measure 2.48:1 and
  1.20:1 against the canvas — identical in light mode, so intrinsic to `UIDatePicker`'s barrel
  fade and not reachable through public API. `.compact` measures 20.16:1 and is what
  `EditChildSheet` already uses for this same field.
- **Second pass over phase 20's own diff, after it had been reported finished.** Nine defects, all
  in code that compiled and had a green suite. Worth logging as a class rather than a list: four
  were in the recompute sheet and all four came from one change — holding the sheet open to show
  `entries_updated` — which turned Cancel into a lie, disabled the only retry, and briefly left no
  toolbar exit at all. **A screen that gains a state gains every state's exits.**
- **`presentationSizing(.fitted)` is wrong for a sheet whose root is a `ScrollView`.** It is the
  modifier the problem looks like it wants; a `ScrollView` has no intrinsic height, so `.fitted`
  sizes to the proposal and produces a near-full-screen sheet — measured, and worse than the
  `.medium` it was replacing. The `+` sheet uses a seeded, measured `.height()` detent instead.
- **A raised control over a variable-height bar is anchored to the bar's edge, never to its
  centre.** A centre offset only yields a fixed protrusion while the bar is a fixed height.
- **`writeFailed` became `WriteFailure.switching` / `.time`.** One boolean for two different writes
  meant a refused *toggle* reported the send time back, naming the one value nobody was changing.
- **`BackfillActionBackdrop` → `PinnedActionBackdrop`.** Giving `OnboardingStepScaffold` a pinned
  footer made all five onboarding steps depend on a type whose name said "backfill".
- **The readable archive ships inside the same zip, not as a second export.** `index.html` reads
  the bytes `entries.json` already contains, so the viewer cannot disagree with the backup and
  there is nothing to keep in sync. If it is ever wrong you regenerate it from a zip you have.
- **`entries.js` exists because `file://` origins are opaque.** A double-clicked page may not
  `fetch()` a file beside it, and may load one with a `<script>` tag. The payload is duplicated
  rather than the constraint worked around at read time — 9KB compressed on a real archive,
  because the two files deflate nearly identically.
- **Two wrapper files, not one combined object.** `entries.js` and `manifest.js` each wrap their
  own sibling verbatim, so stripping the assignment gives the `.json` back byte for byte and a
  test can assert exactly that. A combined `{manifest, entries}` object would be a third shape
  matching neither file.
- **`</` is escaped to `<\/` in the `.js` files only.** A parent can type `</script>` in an entry
  body, and unescaped it would truncate the archive at that character. `\/` and `\u2028`/`\u2029`
  are JSON escapes, so the value on the other side is identical — asserted, not assumed.
- **The viewer's manifest assertion warns and renders, never refuses.** A format version it has
  never heard of gets a banner and the archive underneath it. An archive that shows nothing
  because it is too new is the failure the whole design exists to avoid.
- **Dates render in `family_timezone`, not the reader's.** `occurred_at` is serialized in UTC, so
  a reader in another zone would see evening entries land on the following day.
- **A card is a `<div role="link">`, not a `<button>`.** Cards contain `<audio controls>`, and
  interactive content inside a button is invalid HTML — today it renders, and in 2040 it is a
  play button that cannot be pressed. The delegated click stops at the first element that owns
  it, so pressing play does not also open the entry.
- **Media that will not load degrades to metadata with a note, in both directions.** A null path
  means the export never had the bytes; an `error` event means the folder changed afterwards.
  Both render as words. A broken-image icon reads as "this archive is damaged", and neither is.
- **`ruff check` failing was hiding five `ruff format` failures.** A make recipe aborts on its
  first failing line, so the one recorded, deliberately-unfixed `E501` on `main` meant nobody had
  seen the format check's output in weeks.

## Aug 11, 2026 — the docs pass that closed four open items

- **Open items 2, 3, 9 and 10 are settled**, leaving **item 1 (the name)** as the only thing in
  `docs/decisions.md`'s Open table. The handoff split into two questions that dissolved each other,
  the export gained a readable layer without a second export path, and pronouns gained a
  fourteen-token contract that lives in `docs/api-contract.md` because every consumer must honour it.
- **`blocked.md` was struck but not moved, and that was the defect.** Four iOS sections sat under a
  heading meaning "blocked" while the preamble already said they were resolved. A struck section is
  not a moved section — a file read for "what is blocking me" gets skimmed by heading. Two are now
  closed outright by phase 19; the rest are named as unstarted follow-ups.
- **`docs/roadmap-status.md`'s phase-numbering instruction had gone stale twice.** It said the next
  phase "should be numbered 12" while 12 through 20 merged underneath it. Re-stating it with a fresh
  absolute number only resets the clock, so the rule now says to **measure `main` directly** and
  labels the number as expected to rot. The four existing collisions (3, 11, 19, 20) are **not**
  renumbered: the PRs are merged and renaming them would make the ledger disagree with every commit
  message in the repo.
- **The iOS test figure was corrected from 705/86 to 714/87**, and the claim that "Phase 19's iOS
  half has never been compiled" was removed — it was true when written and false the same day. The
  trail is measured at every step rather than carried: 678/81 → 705/86 → 714/87.

## Aug 11, 2026 — phase 20 (pronouns): collecting them, and rendering them

- **The contract says fourteen tokens and lists thirteen.** `docs/api-contract.md` and
  `docs/decisions.md` both carry the sentence "Fourteen tokens, one dictionary, no logic" over a
  table of thirteen rows — nine lowercase, three capitalised, and `{name}`. **Thirteen is
  implemented.** The table is the substance; the count is a description of it, and a client that
  invented a fourteenth token to make the sentence true would be adding to a wire format a browser
  client, an export and a printed book must also honour. The two candidates a reader would guess,
  `{Theirs}` and `{Themself}`, are exactly the capitalised forms the table looks to have omitted on
  purpose, since neither plausibly opens a sentence. Reconciling the prose is an API-lane edit and
  was not made from this lane.
- **The renderer runs at the view layer, not in the models.** `Assignment.body` and
  `Entry.promptBody` keep storing the raw tokenised text and every `Text(...)` renders. This is the
  contract's own rule — render at the last moment before a human sees the sentence — and it is also
  what makes "a pronoun change takes effect without a relaunch" need **no cache invalidation at
  all**: nothing cached is rendered, so the next redraw is simply correct. An entry written in 2029
  re-renders when the answer changes in 2034.
- **The widget is the one place that renders before storing**, because the extension reads a file
  out of the App Group and does no networking. The subject is part of the snapshot's identity, so a
  pronoun changed in Settings republishes rather than leaving last week's answer on the Home Screen.
- **`entry.body` is never rendered, and the risk is that it sits one character from
  `entry.promptBody`.** Prompt bodies are the question; `entry.body` is the parent's answer. A
  parent who typed `{they}` literally, or wrote about a game with braces in its name, must get
  their sentence back byte for byte.
- **Custom prompts render like library ones.** `assignment.body` carries `custom_body` when
  `is_custom`, so it is the parent's own *question*. Rendering it in the composer but not the
  widget — or the reverse — is the "same sentence reads differently depending on the screen" defect
  arriving through the back door, and invariant 3 already protects a brace somebody meant literally.
- **The sync dry run deliberately does not render, and it is reachable today.** `SyncPlan`'s
  change preview reports what a `/sync` pull *would* write, so it shows the wire's own bytes;
  substituting into it would make the diagnostic disagree with the payload it is describing.
  **It is not behind the pull flag** — `SyncEngine.dryRun()` says outright that it "works
  regardless of the flag", so any parent can reach it from Settings and see `{their}` in a debug
  report. That is the intended reading of a debug report, but it is a judgment call rather than a
  dead code path. (The `syncPullEnabled` named in several comments no longer exists; the property
  is `SyncEngine.pullEnabled`, backed by `UserDefaults.bool`, so it does still default false —
  that staleness is pre-existing and was not touched here.)
- **`ChildUpdateRequest` is hand-encoded for one property.** Swift's synthesized encoder omits a
  nil optional rather than sending `null`, which `updateMe` already documents — and notes is
  harmless there because none of its columns is nullable. `children.pronouns` is the exception:
  the server reads `model_fields_set`, so only an explicit `null` clears it, and without the
  hand-written encoder Clear would have silently no-opped.
- **`ChildResponse.pronouns` decodes as `String?` and is narrowed afterwards.** This type is on the
  launch path, so a value outside the three — a widened CHECK shipped ahead of a client release —
  would otherwise fail the decode and take out `GET /children`, and with it the app, rather than
  one row of Settings. An unrecognised set reads as unanswered, which renders they/them.
- **Nothing preselects a pronoun and Continue is never gated on one.** The design export's closest
  screen — the "What made you download this?" fork — *does* disable Continue until something is
  picked, and this deliberately departs from it. A skipped pronoun is a finished setup, and the
  onboarding step mirrors `AvatarStep` down to offering both Continue and "Skip for now".
- **Phase 20 now means two things**, and that was a deliberate call rather than an oversight:
  `docs/decisions.md:188` said this work had no number and `roadmap-status.md:172` says collisions
  are never renumbered. Raised before the branch was cut and confirmed. The ledger stays the
  disambiguator.
- **iOS suite 714/87 → 730/88**, warnings unchanged at 21, measured from a deleted `DerivedData`.
  The spec's `iPhone 15 Pro Max` is not installed on this machine; the run used `iPhone 17 Pro Max`
  on OS 26.4.1.

## Phase 22 — Entry Detail v2 design import (Aug 11, 2026)

- **The design import is read through `DesignSync`'s read methods, not the `claude_design` MCP.**
  That MCP is not connected to this session; `get_project` / `list_files` / `get_file` against
  project `e227a63f-…` reach the same files. The import **succeeded** — no fallback to
  `docs/entry-detail/` was needed. The skill the project ships (`SKILL.md` → `rascal-design`) and
  its `readme.md` were read as part of it, and `readme.md` is treated as a second authority
  alongside `docs/design-system.md`.
- **Fourth consecutive export to hardcode values its own `tokens/colors.css` does not contain.**
  Reconciled by the standing rule — tokens + `Palette.swift` win, no new `Palette` constants.
  The substitutions: `#5E7A57`→`sageInk`, `#A8A096`→`inkFaint`, `#F2EBE0`→`chipPlain`,
  `#DCD2C4`/`#E6DCCE`→`border`, `#F0E2D4`→`sealedBorder`. Full table in
  `docs/entry-detail-inventory.md`.
- **The sealed gradient needed nothing.** `Gradients.wash` is already exactly
  `#FDE8DC → #F7DDE8 → #FBF6EF`, the export's sealed wash, digit for digit.
- **The voice and did-it washes are dropped to flat tints** (`periwinkleSoft`, `sage`). Neither
  gradient is in `tokens/colors.css` or `Palette`, and `Gradients.wash` is the *sealed* treatment —
  reusing it there or adding two more would be inventing a second and third gradient, which the
  phase brief forbids.
- **Paper grain dropped again, and still not resolved.** The export calls it mandatory identity;
  `docs/decisions.md` lists screen-print texture under *Rejected — do not revisit*. Third export in
  a row to carry it, third time dropped, deliberately with no compromise invented.
- **Frosted glass dropped — the export contradicts its own design system.** Every sheet is
  `backdrop-filter: blur(26px)`, while the project's own `readme.md` says "Frosted-glass panels are
  not part of this brand." Resolved toward the README.
- **The export's sealed copy is not adoptable.** It says the letter opens on the child's eighteenth
  birthday "and not before — not even for you", and offers no **Open it**. The shipped reader
  deliberately lets the author open it. Kept ours; the envelope motif is skin only.
- **The run stopped at the end of §1 with the inventory**, which the brief pre-blesses. One
  question is not the agent's to answer: whether full-bleed media is allowed on Entry Detail, given
  `design-system.md` says photos "rarely bleed to the screen edge" and `decisions.md` rejects a
  full-bleed *timeline*. Neither forbids it here; both are one step away. Logged in
  `docs/blocked.md`.
- **The seal's primary test is weaker than it reads.** `SealControlTests.sealedEntryRendersSealed`
  asserts `card.preview == nil` against a fixture built with `media: []`, so the assertion holds
  whether or not the seal does anything. No defect in the shipped gate; a gap in the evidence.
  Recorded for 22b, which the brief already requires to assert against a sealed fixture carrying
  both a photo and a body.
- **Preflight deviation: the zero-warning precondition does not hold on `main`.** 21 pre-existing
  warnings (`ExtractedDetails.swift` ×3, `PushPermissionTests` ×14, `ExtractionTests` ×4), none in
  an Entry Detail file. Recorded rather than treated as a stop. iOS suite **756/95**, green, cold.
- **Paper grain closed, Aug 11, 2026.** Settled as rejected. It had stayed open across three phases
  because `decisions.md` said "screen-print texture" and every importer deciding about a
  5%-opacity `feTurbulence` layer read past it. Now named explicitly in the exports' own
  vocabulary so the next import closes it by reading. **Also settled: the exports will keep
  shipping it, and that is not a new argument each time.**
- **Correction to this phase's own seal finding.** The inventory implied the seal's evidence was
  thin overall. It is not — `TimelineViewTests`, `MomentsV2Tests` and `TimelineSearchTests` all
  assert it with media present and all fail when the gate is deleted. One badly-shaped test is not
  a badly-defended invariant. The genuinely uncovered channel was **voice/transcript**, found by
  breaking the gate, and it is closed by PR #55.

## Phase 22b — Entry Detail v2 built (Aug 11, 2026)

- **Full-bleed media on Entry Detail: allowed.** Settled by the founder. `decisions.md` rejects a
  full-bleed *timeline* and `design-system.md` says photos "rarely bleed to the screen edge" —
  Entry Detail is the rare one, being the single screen whose whole job is looking at one artifact.
  Scoped to this screen; it is **not** a licence for the timeline, which the rejection still names.
- **Frosted glass resolved toward the design system, not the export.** The sheet is opaque
  `surface` with no `backdrop-filter`, because the design project's own README says frosted-glass
  panels are not part of the brand. The export contradicted itself here.
- **The backdrop is an enum, not a colour.** `EntryDetailScreen.Backdrop` +
  `static func backdrop(...)`, so "which ground does this entry get" is a rule with tests rather
  than a computed property that can only be looked at. Same move `transcript(in:)` already made.
  **Sealed is checked before media is ever read** — ordering is the safety property, and breaking
  it fails a test.
- **`factsSentence` takes the whole `Entry`, deliberately.** The obvious signature takes a `Date`,
  which moves the choice of `occurred_at` vs `created_at` to the caller where no test can see it.
  Taking the entry is what makes "the date is `occurred_at`" able to fail.
- **The key/value metadata list became one sentence** — `[age chip] date · 10 photos`. **The sync
  line was kept out of it on purpose**: "Here — it'll sync when you're back on" is a state, not a
  fact about the entry, and folding it in would have been the tidy way to lose the only place this
  screen admits an entry has not left the phone.
- **`DetailMediaView` gained `bleeds:` rather than a fork.** One call site, and everything except
  the shape is identical.
- **Dropped as new functionality, per scope:** immersive mode, the expanding sheet, Share, Add tag,
  the video scrubber, the thumbnail strip, "Read the whole thing". Multi-media is still a paged
  `TabView`.
- **Adversarial finding, pre-existing and not fixed here: Edit reaches a sealed letter's body
  without going through Open it.** `edit()` opens the composer, which renders the body, and the
  toolbar offers it on a sealed entry. It is defensible — the author is deliberately not locked out
  — but "Open it" is a conscious act and tapping Edit is not. Flagged rather than changed, because
  changing it is behaviour rather than a design pass.
- **iOS suite 758/95 → 768/96**, warnings unchanged at 21 and none in a touched file, cold from a
  deleted `DerivedData`. Two assertions verified by breaking the code: the sealed-backdrop ordering
  and the `occurred_at` rule.

## Phase 23 — device-side personalization (Aug 11, 2026)

- **The finding this phase turns on: the library is not tokenized.** `PromptTokens.render` ships
  and is wired at eight call sites, but **113 prompt bodies carry 0 `{tokens}` and 99 of them say
  `he`, `him` or `his` literally.** So the deterministic renderer is currently an identity function
  on the real library, and a child whose pronouns are she/her or they/them **is misgendered on
  every screen today, on every device**. Personalization does not fix that in general — it only
  runs where the model is available. **Tokenizing `api/seeds/prompts.yaml` is a Lane A change, is
  out of scope here, and is strictly better than a model for this specific job.** Recorded in the
  PR as the top recommendation.
- **Order is tokens first, then the model.** `PromptTokens` is the exact server-agreed
  substitution and is authoritative; the model is best-effort on what remains, and is validated
  against the token-rendered string rather than the raw body.
- **The guard's false-rejection rate against the shipped library is 0%** — 99 of 99 personalizable
  prompts survive an ideal mechanical substitution. Pinned as an equality in
  `PersonalizationLibraryTests` so tightening a rule shows up as a number that moved.
- **The instruction verb set is read out of the library**, not invented: `record take photograph
  write film ask let go get use trace tell spend show say put measure`, from the 83
  instruction-shaped prompts.
- **Phase E found one thing.** `ComposerView` renders the personalized header three lines above
  `entry.promptBody = assignment.body`, and that field syncs. The write is correct; the adjacency
  is not obviously safe to the next editor. Commented at the write site and pinned by a test.
- **The composer reads the shared cache and does not request.** A composer opened without Today
  having personalized that assignment shows canonical, which is correct. Judgment call: a second
  request site is safe (the center dedupes) but buys little, and the shared cache is the point.
- **iOS suite 772/96 → 796/100**, warnings unchanged at 21 and none in a touched file, cold from a
  deleted `DerivedData`. Two assertions verified by breaking the code, one of them never-persisted.

### Phase 23 — the audit pass, and four things it changed

- **A concurrency defect: the in-flight claim was made across a suspension point.** `request` checked
  `inFlight` at the top, `await`ed the availability check, and *then* inserted — so six concurrent
  renders of one card produced six model calls. Sequential tests could not see it. **This is the
  hazard `APIClient.refreshSession` documents at length and `SyncEngine` cites verbatim**; the fix
  is the one they already prescribe, claiming synchronously before the first `await`. Being on
  `@MainActor` does not help — the actor is released at every suspension, which is the point of it.
  Caught by a `withTaskGroup` test that fails at 6 calls on the old code.
- **The name check matched substrings.** `contains("Sam")` is satisfied by "the **sam**e thing",
  Al by "**al**ways", Bo by "**bo**th — so a model that changed nothing was *accepted* whenever the
  library happened to hold the name inside another word, caching a personalization that
  personalized nothing. Now a whole-word match, with the trailing boundary still allowing a
  possessive because an apostrophe is not a word character.
- **Three Today surfaces were unwired, and that was an inconsistency rather than an omission.**
  `DoneCard`, `WaitingCard` and the skip-undo toast all render the same prompt bodies as
  `PromptCard` on the same board. A mission personalized while open would have snapped back to the
  library's wording the moment it was done — precisely the defect `PromptSubject`'s own comment
  exists to prevent. All three now read the same seam, and the toast personalizes **before**
  truncating, since shortening first would quote back a sentence nobody saw.
- **The composer now requests as well as reads.** It was a cache reader only, which meant a
  composer opened straight from a widget tap or a notification — with no board behind it — was the
  one listed surface where personalization never happened.
- **The cache key is the canonical body, not its hash.** Hashing bought nothing on a handful of
  one-line prompts and a collision would render one prompt's personalization under another's text.
- **iOS suite 772/96 → 801/101** after the audit, warnings unchanged at 21, none in a touched file.

## Phase 18 follow-up — camera-roll browse and picker (Aug 12, 2026)

- **The browse screen's crash was neither of the two causes the brief named, and both of
  those were real anyway.** It was the container: `BackfillSuggestionsScreen` put its cards
  in a plain `VStack` inside a `ScrollView`, which has no viewport to be lazy about and so
  mounts every child before the first frame. Measured on a seeded library of 2,450 photos
  across 175 months: **175 whole-month reads, 700 thumbnail requests, 643MB resident against
  a 236MB baseline** — none of it on screen. Fixed it is 3 reads, 12 requests, 253MB.
- **`LazyVStack` alone fixed nothing, and that is the finding worth keeping.** The cards sat
  inside a nested `VStack(spacing:)` for the card gap, and a lazy stack treats a nested stack
  as one child — so it built all 175 eagerly and the laziness bought exactly zero. Same 175
  and 700, measured. The gap is per-card padding now so each card is its own lazy child.
- **`SUGGESTED` is "this month, in the years before it", capped at five, floored at the birth
  month, with no substitution.** An empty, dismissed or pre-birth candidate shortens the list
  rather than being replaced by a neighbouring month: the section's premise is "this month,
  earlier", and quietly swapping June into an August slot breaks it while looking like it
  worked.
- **`birthMonth` is read out of the `YYYY-MM-DD` string, never from a `Date`.**
  `EditChildModel.dayFormatter` parses in the *device's* zone; reading that instant's month
  back in the child's would file a child born on the 1st into the previous month for a family
  far enough east. `BackfillMonth(calendarDay:)` never builds an instant, so nothing can move it.
- **"What month is it" is answered in `family_timezone`, not `Calendar.current`** — the
  `daysUntilExpiry` defect from phase 11 in a second place. A device in Auckland and a family
  in Los Angeles disagree for up to a day, and on the 1st that day is a whole month of cards.
- **The picker's three visible symptoms were one defect.** `.scaledToFill()` under a
  `.clipShape` with no frame between them clips to the view's own bounds rather than to the
  space proposed, so a portrait asset grew, clipped itself larger and drew over its
  neighbours — and a `LazyVGrid` row is as tall as its tallest child, so it pushed its row
  into the next and painted across the pinned header. The header's "missing" opaque fill was
  never missing; it was being overdrawn.
- **The pill was never obscuring the last row.** `safeAreaInset` already insets scroll content
  by its own height; the screen was adding a hardcoded 110 on top, which is a dead gap that
  changed length the moment a photo was picked. Replaced with 16 of clearance and the app's
  standard `PinnedActionBackdrop`.
- **The grid keeps `docs/design-system.md`'s contact-sheet geometry — 3pt gutters, radius 2.**
  The brief asked for 6pt and radius 14 and attributed both to that file, which specifies the
  opposite and argues for it. Raised rather than silently resolved; the doc won.
- **`cloudOnlyCount` is computed for every asset in the library and read by no view.** The
  scan calls `PHAssetResource.assetResources(for:)` once per asset to produce it. Left in
  place — removing a tested field is a wider change than this pass — but it is the next thing
  to look at on a large real library, and it is recorded here so it is not rediscovered.

## Review fixes, Aug 13 2026 — the api/ deep-dive pass

- **A truncated `/sync` page hands back the *earliest* cut watermark, not `max`.** The four
  collections page independently, so taking the newest stamp across all of them would advance
  the cursor past rows the untruncated collections had not sent yet, and those rows would
  never be requested again. `min` of the collections actually cut, still lagged by
  `CURSOR_OVERLAP_SECONDS`, is the only value that is safe to resume from.
- **`POST /sync/push` now lags its cursor the same way `pull` does.** It was returning a bare
  `now()` taken before the transaction committed, so a client feeding it back as `since`
  skipped the server-derived `entry_type` and `child_age_months` corrections that same push had
  just written. The alternative — dropping the field — was rejected because the response already
  types it identically to the resumable pull cursor.
- **The explicit-null rejection lives in `ChildUpdate`, not in the handler.** `me.py` does it in
  the router with `model_fields_set`, and that shape was considered; the schema won because the
  same file already raises `validation_failed` from a validator, and because it fixes the second
  half of the defect — the timezone validator was being skipped entirely on `None`.
- **`judge()` gained a fifth rejection rule, and the library now fails it on purpose.** New
  generated copy may not assume a gender, so the rule fires on he/him — and the seeded 113 are
  still literal he/him, so the fixtures quoted from them in
  `test_the_library_would_pass_its_own_filters` now trip it. The test asserts that *no other*
  filter touches a real prompt rather than asserting bare acceptance. Tokenising those fixtures
  was considered and rejected: "What word does he mispronounce?" has no grammatical form in the
  token table (there is no token for the inverted `does he` / `do they` order), so tokenising the
  library is authoring work belonging to the tokenisation phase, not a test-file edit.
- **`review_candidates.py` filtered `source == "generated"`, a value the CHECK forbids.** Fixed
  to `llm` and bound to the constant. The tool's premise is still unmet and was left that way:
  `generate_prompts.py` writes markdown worksheets and persists nothing, so the queue this reads
  can never fill. Recorded rather than solved — deciding whether candidates become rows is a
  product call, not a review fix.
- **Export and multipart upload commit before their S3 round trips.** The request transaction
  was held open across a whole-archive download; `expire_on_commit=False` and a plan built of
  plain dicts make the early commit safe. For `plan_upload` a flush reorder was not enough — the
  transaction was already open from the authorization dependency's reads, so it needed an
  explicit commit.
- **Phase 24 rephrased eighteen prompts rather than widening the token contract.** The table has
  no inverted forms — `{they_are}` is *"he is" / "they are"* and an English question needs
  *"is he" / "are they"* — so "What is he obsessed with right now?" cannot be tokenised in place.
  Adding `{are_they}` and friends was rejected: it widens a wire contract three clients implement
  and would have made an API-lane phase wait on an iOS release. The rule used instead is
  **prefer `{name}` where it preserves the sentence exactly, rephrase only where `{name}` would
  have to appear twice** — a name is third-person singular, so the verb stops moving.
- **Retirement lives in `seed_prompts`, not in a migration.** Changing a body inserts a new prompt
  and leaves the old one active, because the body is the idempotency key. A migration naming 113
  hashes would have worked exactly once; the loader now deactivates any `source == "seeded"` row
  the file no longer contains, so the next library edit gets the same behaviour for free. Scoped
  to `seeded` so a parent's own prompt is not deactivated by the next `make seed`, and it
  deactivates rather than deletes because entries and assignments point at these rows.
- **The export manifest gained `child.pronouns`.** The viewer renders bodies and every seeded body
  now carries tokens, so without it an exported archive prints a literal `{their}`. This does not
  breach "the server never renders": the server ships tokens intact plus the answer needed to
  resolve them, and `assets/app.js` substitutes at read time like every other client.
- **The four `his mom` bodies were rewritten to "someone else in the family", not tokenised.**
  Owner's call, Aug 13, 2026. `{their} mom` fixes the gender and keeps the household shape that
  the library's own rejection rules forbid in new prompts.
- **The `his-words` theme became `their-words`, and only the unreachable rows needed a migration.**
  `theme` is in `seeding.MUTABLE_FIELDS` but not in `sha256(kind, cadence, body)`, so re-seeding
  rewrites a theme on the live rows in place. `0009` exists for what re-seeding can never reach:
  the 99 prompts phase 24 retired, which are gone from `prompts.yaml` forever and would have kept
  the old slug permanently. It updates every matching row rather than only the retired ones, so it
  does not depend on running before or after `make seed`.
- **Tags were not migrated with the theme.** `tags.name` and `prompts.theme` share vocabulary by
  convention only — no code path copies one to the other, and `entries.py:237` builds tags purely
  from client-supplied names. A tag is a word a parent or the on-device model chose about one
  entry, so rewriting it would be editing the parent's own record. Overrule this if a household
  ever ends up with a stray `his-words` tag that bothers them; it is one UPDATE.
- **`test_migrations.py` stopped stepping with `downgrade -1`.** The relative step meant "unwind
  0008" only while 0008 was head, so 0009 silently retargeted it at a migration with nothing to do
  with slots. Revisions are named explicitly now. The same fixture is module-scoped and arrives at
  head, and `upgrade <earlier>` is a no-op in alembic rather than an error — so the new test
  reaches its starting revision by downgrading from a known head.
- **Multi-kid switching is a gate-level state change, and nothing below the gate may mutate a
  child.** `OnboardingGate` renders `RootView` with `.id(child.id)`, so a new `SessionState.ready`
  tears the subtree down and rebuilds it — which is what makes `TodayModel`, `SyncEngine`,
  `ShareDrain`, `TimelineModel`, `MomentsModel` and the Timeline's `@Query` predicates correct
  across a switch. Every one of them captures its child once at init and never re-reads it, so a
  `@State selectedChildId` or a mutable `childId` would leave them all pointed at the previous
  child while the header showed the new one: a sibling's entries under the wrong name, and the
  wrong child's sync cursor advanced. Recorded because the wrong implementation looks simpler and
  its failure is invisible on screen.
- **Switching never erases local data; sign-out still erases everything.** Both children's rows
  live in one SwiftData store and neither is entitled to empty it, so `LocalArchiveErasing` stays
  bound to sign-out. Conversely sign-out remains account-scoped and unconditional — it must not
  become per-child, or a signed-out phone keeps the siblings' thumbnails and faces.
- **Six local reads were unscoped and are now child-filtered**; the device-wide queues are
  deliberately left alone. Today's merge, the widget snapshot, the backfill's month and day
  coverage, the notification re-offer, `ExtractionQueue.pending` and Settings' `?? children.first`
  all see one child now. `EntrySync.unsyncedDescriptor()`, the upload, transcription and staging
  sweeps stay global on purpose: each row carries its own `childId` to its own route, so a sweep
  under one child correctly pushes the other's offline writes, and narrowing them strands work.
- **`Media` has no `childId` and is not given one.** It reaches its child through `entryId`, so
  media reads are scoped by scoping the entries they are grouped against. Adding the column would
  be a schema migration to duplicate a fact the join already carries.
- **The selected child lives in `UserDefaults`, and nothing downstream trusts it.** The gate
  resolves `GET /children` first and only then asks whether the remembered id is among them —
  missing, unparseable and no-longer-present all land on the same branch as never having chosen.
  That is why the store parses on the way out rather than validating on the way in.
- **Adding a child is a Settings entry point, not a switcher one.** The switcher's chevron only
  exists once there are two children, so an "add" that lived only there would be unreachable for
  exactly the account that needs it — the same shape as the camera-roll row that was sealed behind
  its own authorization door.
- **`AddChildSheet` is not `ChildSetupFlow`.** Setup's sixth step is the notification soft-ask, and
  a parent adding a sibling has already answered that for the account; `ios/CLAUDE.md` puts
  re-prompting out of scope by any mechanism. Reusing the flow would mean branching through every
  step to skip the last one. The sheet collects the four fields `POST /children` requires and
  stops — avatar stays where the existing child's is set, in `EditChildSheet`.
- **`addChild` deliberately does not reuse `createChild`'s adopt-the-existing-child guard.** That
  guard exists because setup has no idempotency key and a lost response would otherwise strand a
  parent whose child was already created. It cannot be reused here: this account already has
  children, so "find one and adopt it" would silently select a *sibling* and report success for a
  create that may never have happened. A visible error the parent can retry is the better failure.
- **Letter-on-any-day and editing a seal are one change, because they are one control.** 27 needed
  `SealSetting.isOffered` to stop requiring a `letter` assignment; seal-editing needed it to stop
  refusing while editing. Shipping them apart would have meant two rewrites of the same predicate
  and a half-built seal in between.
- **The composer had to start carrying the entry's existing seal.** `ComposerRequest.editing` sets
  `assignment: nil`, so the control had nothing to seed from — a parent opening a sealed letter
  would have found the toggle off, and saving would have silently unsealed it. The request now
  carries `existingUnlockAtAge`, and it wins over both defaults.
- **`updateEntry(_:)` now sends `unlock_at_age`, and `title` still does not.** The rule is whether
  the caller has an opinion: there is no title field anywhere in the app, so claiming one would
  let editing a body revert a title set on another phone. There *is* a seal control on the edit
  path now, seeded from the row and shown to the parent, so the value sent is one they looked at.
  `.set(nil)` is what unsealing is on the wire — an omitted key means "leave it alone", so without
  the explicit null a seal could be added and never taken back.
- **Sealing is offered on every freeform capture, not only the Write verb.** All four verbs build
  the request as `mode: .text`; the verb only decides what opens on top. `mode` therefore
  separates shapes only on the edit path, which is where the rule refuses to seal an unsealed
  photo — an already-sealed one is always editable, whatever shape it is.
- **Two `GET /today` tests were time bombs, and 14 Aug 2026 was the fuse.** Their fixture date was
  the literal `2026-08-14`, written when that was comfortably in the future. `GET /today`
  self-heals — when the requested date *is* the child's current date, `ensure_day_filled` mints the
  day's missing slots before answering — so for as long as the constant was in the future the tests
  asserted a board nothing had filled, and on the day it arrived the fill ran, minted the
  `mission_b` that migration 0008 added, and the suite went red having never once exercised what it
  claimed to. The fixture date moved into the past, where it cannot become today again; filling has
  its own file in `test_today_self_healing.py` and that is where it belongs. Worth generalising:
  **a fixture date in the future is a test that has not run yet.**
- **`/stats` counts media through a live entry, not through `media.deleted_at`.** A soft-deleted
  entry takes its media with it in the contract, so a media row whose entry is gone is not in the
  archive whatever its own column says. Counting the column alone would have reported files
  belonging to a deleted entry, and it is the kind of wrong that only shows up once somebody
  deletes something.
- **`media` returns every kind including zeros, and the two dates return `null` on an empty
  archive.** A key that appears only once a child has recorded audio is a key every client has to
  guard; `0` is a true statement. And a first-entry date standing in for "there is no first entry"
  renders as a real day on somebody's screen — `null` is the only honest empty.
- **The two dates are family-timezone calendar days.** `occurred_at` is stored UTC and an evening
  entry in Detroit is the next day in UTC, so a `date()` on the raw column reports a day the
  parent did not live. Converted in Postgres rather than Python because it happens in the same
  pass as the aggregate; pulling every row back to convert would make the endpoint O(archive).
- **The fixture-date rule is enforced now, not remembered.** `tests/test_fixture_dates.py` parses
  every test module and fails on any `dt.date(...)` literal that has not happened yet. A future
  date is a test that has not run: it asserts one branch until the clock arrives and then silently
  starts asserting another, and nothing about a green run says which branch it took. Where being
  ahead of the clock is the point — a horizon, a `?date=` override that must *not* self-heal — the
  line carries `# future-date: <why>`, so the exemption is earned where the next reader sees it.
- **`make_assignment`'s default `assigned_on` was `2026-08-14`, and that is how the pattern
  spread.** Every assignment built without an explicit date landed on the real today the moment the
  clock arrived, which is when `GET /today` begins self-healing a board the test just set up. Moved
  into the past, where it cannot become today again.
- **`test_pool_health.py`'s `TODAY` looked like the same bomb and is not.** It is passed as an
  explicit `as_of` to the pure `pool_health()`, so the real clock never participates and the
  assertions are stable whatever day it is. Recorded because "same literal, same file shape" was a
  reasonable suspicion and the answer is a property of how the value is *used*, not how it is
  written — the branch condition is `on == local_today` in `routers/today.py`, and only `/today`
  has one.
- **The twenty new photo prompts were verified against the library's own filters, not just read.**
  Every daily photo body — the original 22 and the new 20 — was run through
  `generate_prompts.judge`, which is the same gate a generated candidate passes. All 42 accepted.
  That check is worth more than it looks: the filters forbid an occasion, an income, an ability and
  a gender, and it is easy to write "photograph them at the beach" without noticing you have
  assumed three of them.
- **They are any-month on purpose.** A seasonal tag makes a prompt invisible for eleven months of
  the year, and the slot's problem was availability *today*. The four seasonal photo prompts stay
  seasonal; nothing new joined them.
- **Verb agreement drove several rewordings.** "the book {they} keep asking for" renders "he keep",
  so it became "{they_have} asked for every night this week"; "the chair {they} always sit in"
  became "the chair that is always {theirs}". The token table has no conjugator by design, so the
  authoring has to route around inflection — the same constraint phase 24 hit at scale.
- **Phase 33's device half is blocked on the platform, and the seam is deliberately not landed
  ahead of it.** There is no public on-device pixels-to-prose API in iPhoneOS26.4 — the model's
  entire input vocabulary is `Transcript.Segment`, text or structure. Writing the protocol now
  would mean a stub that always answers `.unavailable`, a queue that never runs, a Settings row
  that permanently reads "0 waiting" — furniture this screen explicitly refuses — and, worst, a
  SwiftData migration adding a caption state ladder to every media row for a feature that may
  never ship or may ship a different shape. `Media.bytesSent` already bricked the app once over a
  missing declaration default, and every test is `isStoredInMemoryOnly` so nothing catches it.
- **Two claims the repo carried were wrong, and both are corrected.** The queue said the two
  on-device seams "take text, not pixels" — `SpeechTranscribing.transcribe(fileURL:in:)` takes a
  file URL and *returns* text, so there was never a shared input to widen; the case for a third
  protocol is divergence, which is stronger. And the roadmap asserted in the past tense that
  on-device image input "landed in the iOS 27 wave", about a release this repo has never verified,
  which `phase-17.md` then quoted forward as established.
- **The shipping floor is iOS 18.6, not 26.** Eight target-level `IPHONEOS_DEPLOYMENT_TARGET`
  entries say 18.6; the two saying 26.4 are project-level and lose. Recorded because it makes every
  `#available(iOS 26.0, *)` guard load-bearing rather than defensive, and because a captioning
  design that assumed a 26+ floor would have been wrong about its own install base.
- **`/stats` pushed a user-controlled timezone into SQL, and Postgres knows fewer zone names than
  Python does.** `family_timezone` is validated against `zoneinfo`; `Asia/Calcutta` and
  `US/Eastern` pass that and are rejected by Postgres's `timezone()` with `not recognized` — a 500
  on a read endpoint for a household spelled a way the API itself accepts. The original reasoning
  ("convert in the same pass as the aggregate; pulling every row back would be O(archive)") was
  sound about cost and wrong about necessity: **converting to a fixed zone is monotonic**, so the
  earliest instant is the earliest local day in every zone. Taking `min`/`max` of the raw column
  and converting exactly two values in Python is the same answer, still one query, and no
  user-controlled string in the SQL. Regression test uses `Asia/Calcutta` deliberately.
- **The scheduled-machine refresh compared image strings that are never equal.** An app machine
  reports `…:deployment-01M016AD`; a machine that has been through `fly machine update` reports
  `…:deployment-01M016AD@sha256:20b638…`. The first version of that step compared the two raw, so
  the "only when the image differs" guard was permanently true and every deploy restarted both
  cron machines. Bounded — the scheduler is idempotent on `(child_id, assigned_on, slot)` and the
  notifier claims on a unique `(user_id, notification_date)`, so nothing double-fired — but the
  guard did nothing it claimed to. Both sides are now compared with the digest stripped, checked
  against the live app in both directions: empty when the images match, and still non-empty
  against an older target.
- **The defect was invisible to every check that had been run on it.** The workflow parsed, the
  jq was valid, the step reported success, and the deploy went green — it just did the wrong
  thing quietly. What found it was querying the live app and reading the two image strings side by
  side, which is the only place the asymmetry exists at all. Worth remembering for the next piece
  of automation whose correctness lives in a string comparison against a platform's output.
- **An existing seal is carried, never clamped.** `SealSetting.initial` reused `resolvedAge` for
  the edit path, which rounds into the stepper's 10–21 window. That clamp is right for a prompt
  *default* — a number nobody has committed to — and wrong for the archive's own value: an entry
  sealed at 25 rendered "Opens at 21" while `EntryCard` said 25, and an untouched Save moved the
  seal to 21 permanently. It reintroduced, one line below, exactly the regression
  `existingUnlockAtAge` was added to prevent. Latent in the seed library (13/16/18 only) but
  reachable without any unusual client, because `services/entries.py` seals from the prompt's own
  `default_unlock_age` and the server permits 0–120.
- **The backfill's two `UserDefaults` stores are namespaced by child.** `backfill.scan` and
  `backfill.dismissedMonths` were device-wide, so a sibling's coverage was served under this
  child's name and a month waved away for one hid it for the other. This *defeated* the
  `entryOccurredDates` scoping shipped with multi-kid, because a cached scan is returned without
  recomputing — the fix one layer down was invisible behind the cache one layer up.
- **`refreshChildren` was unreachable for the account it was written for.** Its only caller was the
  switcher sheet, which does not open until there are two children — i.e. never for the one-child
  account that needs to discover a second one added elsewhere. It now also runs when the
  add-a-child sheet opens, which is the likeliest moment for that to be true.
- **The fixture-date guard had four holes, and the worst was `<= today`.** It exempted the single
  most dangerous value it exists to catch: on the day `dt.date(2026, 8, 14)` took the suite down,
  the guard written in response would have passed that literal clean. It was also blind to
  `datetime` literals, checked only the line a call *starts* on — so `ruff format` rewrapping an
  assertion silently revoked an exemption — and globbed one directory level while pytest collects
  the whole tree. All four are closed, and the four behaviours are demonstrated rather than
  assumed: today flagged, future `datetime` flagged, past clean, marker honoured.
- **Triage split by how a date is used, not by where it lives.** Fixture timestamps —
  `assigned_on`, `occurred_at`, `deleted_at` — moved into the past, because those are the ones
  that become "today" and change which branch runs. Values handed to a pure function as an
  explicit `as_of` kept their dates and earned a marker, because the clock never sees them. Same
  distinction that made `test_pool_health.py` safe and `test_today.py` a bomb.
- **Four stale claims corrected after the audit found them asserted as verified.**
  `roadmap-status.md` still said the `mission` slot had never held a photo and that per-entry
  visibility was "not even designed" — both false since Aug 14, and #72 had only updated
  `phase-queue.md`, so the two files disagreed. `blocked.md` cited rule 4 for sending data
  off-device; rule 4 is "no third-party dependencies" and says nothing about where bytes go — the
  real basis is the product's own on-device promise. And `mission-library.md` called 40 the
  *untagged* photo pool when untagged is 38 and 40 is what August can serve; the table two
  paragraphs above already said 38. Numbers re-derived from `prompts.yaml`, not from the prose.
- **The hero's stats strip and first-entry line are built, and the rule they were dropped over is
  intact.** D1 and D12 were dropped because counting a paged local cache answers "how much has
  this phone paged in", not "how big is the archive" — the `TimelineHeader` rule. `/stats` counts
  server-side, so the objection is gone rather than overridden: that rule governs a paged list,
  and this is a counted total. Three owner decisions came with it — the middle cell counts
  photographs and not media, the strip does not render until the server answers because nil is
  not zero, and an empty archive shows nothing rather than three zeros.
- **`StagingSweeper` is wired to foreground, after never once having run.** It was written, tested
  and called from nothing, so the disposal rule its own doc comment describes had never executed
  and every uploaded photo's original stayed on the phone forever. **The accepted cost**: entry
  detail's full-resolution pass reads the staged original when it is there, so once the sweep
  removes it that pass comes over the network — the cached thumbnail still paints instantly, which
  is how the fullscreen viewer has always behaved for older entries. Owner's call, Aug 15.
- **Sign-out now forgets the sync cursors.** Emptying the store and keeping the position is the
  combination that silently never refills: signing back in as the same account resumes from a
  timestamp describing an archive that was just deleted. `pullEnabled` deliberately survives — it
  is a device feature flag somebody turned on, not account data. Found by prefix rather than by
  iterating children, because the eraser has no list and a sign-out has to work for a child this
  build never loaded.
- **The caption clobber stays until 33.** Owner's call, Aug 15, and the reasoning is that it is
  genuinely inert: nothing writes a caption on device, so there is nothing to overwrite. Guarding
  it now would guard against a writer that does not exist, and the real fix needs the state ladder
  that phase 33 is deliberately not building ahead of the platform.
- **Phase 34 was specified from nothing on Aug 15.** It had no spec at all — one line in the
  roadmap's launch checklist and a renumbering note. Six of eight questions are answered and in
  `decisions.md`; two are recorded as open in the queue rather than guessed, because both change
  the schema: whether export is free during the cold-storage year, and what the free tier caps.
- **The lapse lifecycle is the owner's, not one of the options offered.** I proposed three shapes
  and the answer was a fourth: 90 days grace, then a recoverable year in cold storage, then
  deletion — and during grace, missions and questions keep working while new *media* is refused.
  That line is better than the read-only line I suggested, because it is drawn where the cost
  actually is: text is free to keep, so the daily habit never has to stop to save money.

## Aug 15, 2026 — the monetization decisions, and what each rejected

**Phase 34 had no specification at all** — one line in the roadmap's launch checklist and a note
explaining its number. It has one now, covering the model, the free tier, lapse behaviour, the
unit, the billing rail and the printed book. None of it is implemented, and nothing below should be
read as describing something that exists.

**The model is a subscription because the cost is a subscription.** Storage and bandwidth grow
every month the product works, and a one-time purchase pays once against eighteen years of that —
the gap widening fastest for the families using it most, which is precisely backwards. Free forever
leaves a recurring cost with no revenue against it; paid up front with no free tier asks for money
before the value is visible, and this app's value is invisible until somebody has used it for a
month.

**The free tier is generous on prompts and mean on storage, deliberately.** Every daily question
and mission forever, unlimited text and did-it entries, audio at two minutes a recording — and 100
photos *lifetime*. Lifetime rather than monthly because a monthly reset lets a free account accrue
eighteen years of storage at zero revenue; the cap has to bound the total, not the rate. 100 is low
on purpose: a free cap can be raised forever and can never be lowered. Competitors meter the
questions themselves by tier, and not doing that is the point of difference worth paying for.

**The arithmetic behind not deleting.** Tigris Standard is $0.02/GB-month and Archive is roughly a
fifth of that, with no egress charge. A lapsed 50 GB archive on Archive tier is therefore about
**$0.20 a month** — around $2.40 a year to keep somebody's childhood rather than delete it. That
number is why lock-and-delete was rejected: the saving does not come close to justifying breaking
the promise the product is sold on.

**The competitor evidence was wrong, and the way it was wrong is worth keeping.** The paragraph
this replaces said *"none of them delete"* and treated Qeepsake and Tinybeans as two independent
products converging on a policy. **They had been one company for nine months.** Tinybeans Group
acquired Qeepsake's assets on 2025-11-03 in a US$2.7M all-stock deal
(`https://www.prnewswire.com/news-releases/tinybeans-acquires-qeepsake-creating-the-leading-privacy-first-family-memory-platform-302603273.html`,
checked 2026-08-15). Two data points that are really one company is the oldest way to mistake a
coincidence for a trend, and it produced a claim that was not merely unsupported but false.

**Tinybeans deletes.** Permanently, after **12 months of account inactivity** — no logins, no
upgrades, no photo-book purchases — having sent email reminders first
(`https://tinybeans.helpscoutdocs.com/article/87-will-my-memories-be-deleted-if-i-cancel-my-subscription-or-downgrade`,
page last updated 2025-07-15, checked 2026-08-15). **This is not the embarrassment it looks like.**
Their trigger is inactivity rather than lapse, which is `last_sign_in_at + 12 months` — one of the
two clocks D3 already uses. The incumbent and this product arrived at the same clock independently,
and D3 then takes the strictly kinder version: both clocks must elapse, media only is deleted and
text never is, a notice must be confirmed delivered on some channel first, and any sign-in cancels
it outright rather than pausing it.

**On cancellation Tinybeans reverts to the free plan and archives media above the 5 GB free cap,
which can be accessed again on upgrade** (same source and date). **Do not let this be described as
the same thing D3 does**, in copy or anywhere else. D3 moves originals to the Archive tier at day 90
and the retrieval path back does **not** require paying — it is a restore of about an hour, a
property of the storage tier rather than a lever. Their archive is retrieval gated on payment; ours
is retrieval gated on time. The two look superficially identical and any future marketing that
attacks the pattern would land squarely on our own storage tiering.

**The export claim has to be made narrowly, because the wide version is publicly correctable.**
Tinybeans export is for paid subscribers via the website, with one exception: free users who have
passed the storage limit and had memories archived can export at no cost via the app
(`https://tinybeans.helpscoutdocs.com/article/29-who-can-export-all-my-tinybeans-moments`, page last
updated 2026-07-29, checked 2026-08-15). So the defensible sentence is **an active free user in good
standing cannot export from Tinybeans and can from Dogear** — not "they don't let you export".

**Two claims from the earlier session are carried forward unverified and are labelled so
deliberately.** *Qeepsake moves cancelled accounts to a Lite tier with entries still readable* and
*Storyworth content becomes read-only unless the user pays again* were both recorded on 2025-08-15
and **were not re-verified on 2026-08-15**. Qeepsake's post-acquisition status is unknown, which
makes its row the less trustworthy of the two. Neither may be asserted anywhere until re-checked.
**An unverified claim that is labelled is useful; one that is not is what caused this correction.**

**Deletion eligibility is computed from two clocks rather than stored as a deadline.**
`max(lapsed_at + 24 months, last_sign_in_at + 12 months)`, derived on read, because either clock can
move — and a stored deadline written when somebody lapsed would be wrong the moment they opened the
app again. Media only is ever deleted; text never is, because an entire abandoned archive's text is
a few hundred kilobytes and *"we have never deleted a word a parent wrote"* is a sentence worth
being able to say.

**The notice sequence is two consent lanes because it is two legal categories.** Win-back is
marketing and needs an unsubscribe that is honoured; a deletion warning is transactional and sends
regardless. Keeping them as separate fields from day one is cheap now and is the thing that is
expensive to untangle later under a GDPR or CCPA request. No marketing mail may enter the warning
window: *"we miss you"* arriving beside *"your photos will be deleted"* is the worst version of this
product, and it is the kind of thing that happens when one flag does two jobs.

**Delivery is recorded per channel per notice because the email channel can fail silently.** Sign in
with Apple private relay forwarding can be switched off by the user at any moment, and nothing tells
the sender. So notices go by in-app banner, push and email, and an account that cannot be reached on
any of them is kept indefinitely and flagged rather than deleted on a timer that assumes the notice
arrived. Any sign-in inside the warning window cancels deletion outright and resets both clocks —
not a pause, because a parent who opens the app has already answered the question the notice asked.

**The household is the unit, and Apple Family Sharing is not used.** Per-child pricing taxes having
another child, and the cost driver is media volume rather than child count. Family Sharing was
rejected for a subtler reason: it creates a second, Apple-owned opinion about who is entitled, and
two authorities that can disagree about the same fact is exactly the shape of bug this codebase
already avoids for identity and for what day it is.

**StoreKit is a receipt, not the entitlement.** App Store Server Notifications V2 write server-side
and every gate reads the server, for the same reason the device does not decide what today is. The
Small Business Program is 15% in year one, and subscriptions drop to 15% in year two regardless of
enrollment.

**The printed book cannot go through IAP** — physical goods are 0% commission and Apple does not
take them — so it needs a non-App-Store checkout, which makes it dependent on a web client this API
has never had. No print partner is chosen. The evaluation is scored on **margin retained rather than
sticker price**, because consumer photo-book brands price at retail and keep the retail margin while
wholesale print-on-demand APIs charge print-and-ship with no service fee for API access, leaving the
entire markup ours to set. Price derives from page count and is computed server-side before
checkout, because that number becomes money. And the annual book is curated rather than exhaustive:
ten photos a day for a year is 3,650 photos, no book holds that, so the export flow needs a
selection step — which bounds the price and makes a better object than a complete one would be.

## Aug 16, 2026 — Phase 41: the caption clobber, retired into 33

**This closes a queue line rather than fixing a defect.** The Aug 15 decision above — *"the caption
clobber stays until 33"* — was the owner's and it stands unchanged. What was left was that
`phase-queue.md` went on carrying it as an open build item, which is precisely the failure that
file's own header names: *"a queue that carries finished work"*. A decision to defer something is a
finished piece of work. The line is gone and the defect now lives on 33's roadmap row and in
`blocked.md` §9.

**The line named a method that does not exist, and that is the part worth recording.** It said
`Media.applyServerResponse`. There is no such method. `applyServerResponse` is on `Entry`, where it
folds an entry write's acknowledgement and never touches a caption; the caption write is
`Media.applyServerSummary`, at `Media.swift:210`. **A wrong symbol in a deferred-defect note is
worse than a vague one** — it survives being re-read, sends whoever finally acts on it into the
wrong file, and a deferral is by definition read later by someone who was not there. Corrected
everywhere it appears, with line numbers, on the theory that a note nobody can act on was not
really written down.

**The "it is inert" premise was re-verified against the tree rather than carried forward on
trust**, because that premise is the entire justification for deferring. It holds: `Media.caption`
has exactly one writer in the whole application and it is that same server-fold line, and
`RascalAPI.writeDerived` sends the transcript alone and says at `RascalAPI.swift:267` that caption
and tags are deliberately not sent. There is no producer, so there is nothing to overwrite.

**Why it genuinely cannot be fixed early, stated once so it is not re-proposed.** A guard has to
ask whether a local caption is unpushed, which requires a caption sync state on the row, which is a
SwiftData migration over every media row — the same migration phase 33 needs regardless. Guarding
now would add a schema change and a migration crash surface to protect a writer that does not
exist. The fix is a two-line change *inside* a phase that has to happen anyway, not a phase of its
own.

**One thing the queue line did not say and §9 now does:** `SyncEngine.differs(_:from:)`
(`SyncEngine.swift:633`) must be changed in the same commit. Its doc comment promises it *"mirrors
`applyServerSummary` exactly"*, and it currently compares captions unguarded because the writer
does. Fix one without the other and the sync dry-run report starts disagreeing with what the pull
actually does — a divergence that reports phantom updates and is far harder to find than the
original.

**It was deliberately not added to `.claude/review-history/false-positives.json`.** That file's
README draws the line exactly here: suppress a finding that was *wrong*, never one that was right
and deferred, *"because suppressing it hides it from every future review, including the one before
the release that ships it."* A future reviewer flagging `Media.swift:210` is the system working.
The answer is that it is known, deferred and documented — not that it is a false positive.

## Aug 16, 2026 — Phase 42: guardian invites iceboxed, and 34's false blocker

**Owner's call: guardian invites and the `viewer` role are not for a while.** Recorded as a
deferral, not a rejection, and the difference is the whole reason this needed a phase rather than a
line deletion. `phase-queue.md` had exactly two terminal states — the build queue, and *"Deliberately
not doing"*, whose own header says **delete nothing here without a decision to go with it**. Filing
a *not yet* under a heading that means *settled no* would have destroyed the distinction, and the
next reader would have found grandparent invites sitting beside paper grain, which is rejected
permanently and for unrelated reasons. So there is now an `Iceboxed` section, and it says what each
item would cost to restart.

**The icebox is free, and it is worth recording why.** `visibility` was specified in `data-model.md`
and **never migrated** — no column on `entries`, no filter in `deps.py`, no dead code, nothing
half-built to maintain or unwind. The `viewer` value stays in `guardians.role`, where it has been
since `0001` and where `child_access` already enforces it; what has never existed is a route that
can create one. That is precisely the state the project has always been in, so leaving it there
regresses nothing.

**The Aug 12 decision to design it before scheduling it is now paying off, which is not the
outcome it was defended on.** It was argued as hazard avoidance — a visibility model retrofitted
onto an archive that already has guardians is a migration over user content. It turns out to also
be what makes the icebox cheap: the three answers are settled and the column is specified down to
its default, so a restart is a build against a finished spec. **Had the work been deferred as
undesigned, parking it would have parked the design too**, and the restart would have begun with
the argument rather than the migration. Both `decisions.md` rows are kept and annotated rather than
struck, for that reason.

**36 was deliberately left in the build queue, and the overlap is now stated instead of latent.**
30 and 36 both read as "guardian invites" and were written eleven days apart without being
reconciled. They are not the same need: **30 was grandparents as read-only viewers; 36 is a second
parent becoming a full guardian**, which is what D4's one-price-per-household is sold on. Icing 30
does not touch D4. If 36 should ice too that is one line, but it was not assumed.

### 34's blocker was false, and had been since the day it was written

**The line said two open questions blocked the phase and that "nothing should be built until those
two are answered". Both were answered in `decisions.md` on the same day, in the same PR.**

- *Can a family export during the cold-storage year without paying?* **Yes.** D2: the export is
  "always free and complete". D3a puts a one-click free export link inside every deletion warning —
  which is the moment the question was actually about.
- *What does the free tier cap?* **Media**, which is the exact shape the open question recommended.
  D2 caps photos at 100 lifetime and leaves every prompt, all text and all `did_it` entries
  uncapped, so the daily habit is never what stops.

Its summary of the lapse — *"then deletion"* — was superseded the same day too: D3 deletes **media
only and never text**, on two computed clocks.

**A queue line that invents a blocker is worse than one that goes stale on a fact.** A stale fact
gets corrected the next time somebody reads it; a false blocker stops the work and looks like
diligence while doing it. This one recommended answers, got them hours later in a document it
names as authoritative, and went on telling every future reader to stop. The real gate on 34 was
never a decision — it is `blocked.md` §10, an account action, and §10 also records that **38 needs
no Apple account at all**, which the queue never surfaced.

## Aug 16, 2026 — Phase 43: the export takes a date range

**The endpoint took no parameters at all, so the archive was whole-or-nothing.** `from` and `to`
are inclusive, either may stand alone, and omitting both is the previous behaviour exactly — every
caller that predates this is untouched, including the iOS client, which was not edited and did not
need to be.

**The difficulty is the timezone, not the filter, and the filter is the part that looks like the
work.** An entry logged at 8pm on Dec 31 in Detroit is stored as Jan 1 UTC. A range built from
naive UTC dates files it in the following year — and for an annual book that is a mistake nobody
catches until it is printed. The bounds are therefore half-open UTC instants derived from local
midnights, which also keeps the predicate sargable on `(child_id, occurred_at desc)`; converting
the column instead reads better and cannot use an index. The helper went into `services/dates.py`
next to the one definition of "today", rather than into the export, because it is a statement about
what a day *is* and this repo has exactly one of those.

**The test that matters is a boundary test, and it was checked by breaking the code.** Two New
Year's Eve entries, each stored on Jan 1 UTC and each belonging to the year before. Replacing the
zone-aware window with a naive UTC one makes the 2025 export return the 2024 entry — verified by
doing it, not by reasoning about it. A boundary test that passes against both implementations tests
nothing, and this one was worth proving rather than assuming.

**The real correctness work is the manifest, not the query.** A scoped zip and a whole one are
otherwise identical in shape, and the viewer's masthead computes its year range from the entries
that are present — so a one-year export renders as the complete archive of a child who has lived
one year. Three things now prevent that: `manifest.scope` records what the zip is a copy of, the
first line of `manifest.notes` is replaced (the complete export's *"contains every entry"* sentence
is **false** in a partial archive and could not simply be kept alongside a new one), and the viewer
banners it. **The gap before March has to read as a gap in the download, not a gap in the
childhood** — that is the whole reason this feature needed more than a `WHERE` clause.

**`scope` is absent from every archive exported before today, and absent means whole.** The viewer
tests `complete === false` rather than `!complete` on purpose: `undefined` is falsy, so the loose
version would stamp PARTIAL across every archive already downloaded. That is the one bug available
here that rewrites history rather than the present, and it has a test naming it.

**Scoping chooses days, never rows.** Soft-deleted entries inside the range come out exactly as
they do from a whole export. Narrowing *which rows* on the scoped path only would have made the two
paths disagree about what a copy of the archive is.

**What this does not do.** It closes one of phase 32's five problems. The other four — print layout,
PDF generation, QR substitution for A/V, and the playback surface those QRs resolve to — are all
the same problem wearing four hats: a web client this API has never had. 32's gate did not move,
and the queue now says so rather than implying progress.

## Aug 16, 2026 — Phase 44: the verification backlog, reconciled with what shipped

**The backlog is the project's stated front line and it had gone stale against the app.** Eleven
checklists, 409 boxes, nine ticked — and three of those files described screens that no longer
exist in the form they describe. Running them as written would have produced *false* results,
which is worse than not running them: a tester who fails a correct build learns nothing, and a
tester who ticks a box for a feature the checklist never mentions learns less.

**Every finding was checked against the Swift, not against a design document.** That distinction
did work in both directions and is the reason this was worth doing from a keyboard rather than
from a phone.

- **Entry Detail asked twice about a navigation bar that v2 removed.** `EntryDetailScreen` has no
  `navigationTitle` and no `toolbar` anywhere in it. §1.5 asked what the nav-bar title said; §3.1
  asked whether it agreed with the metadata row. Both are re-aimed — §1.5 now asserts the *absence*
  of a title strip and that no body text has been promoted into one, which is the seal assertion it
  was really making, and §3.1 uses the timeline as its second opinion.
- **The design export was not evidence, and one check survived because of it.** The inventory's Q3
  records that the redesign drops **Open it** from the sealed card and replaces its copy with *"not
  even for you"*. The shipped screen keeps the button, because `decisions.md` settled that a lock
  the author cannot pick is a lock on the wrong person. **Had this reconciliation trusted the design
  file, it would have deleted a correct check** and quietly removed coverage of the seal's most
  important escape hatch.
- **The share sheet checklist looked for "Rascal" in four places.** The share sheet renders
  `CFBundleDisplayName`, which has been **Dogear** since Aug 12. Three other occurrences in the same
  file are `RascalShare` and `Rascal.entitlements` — build-system identifiers no parent ever sees,
  deliberately not renamed, and renaming them would cost a provisioning round trip for nothing. The
  file now says which is which at the top, because the next person to grep for "Rascal" will
  otherwise finish the job and break signing.
- **Settings had no boxes for its two newest features.** The stats strip carries three owner
  decisions and **each of them is only observable on a device**: the middle cell counts photographs
  and not media, the strip does not render until the server answers because nil is not zero, and an
  empty archive shows nothing rather than three zeros. Adding a child had no coverage at all,
  despite being multi-kid's only entry point — and multi-kid was the change that re-scoped six local
  reads, where a half-applied switch shows one child's entries under the other's name.

**The count went 409 → 431 and the ticked count did not move.** A denominator that grows on a day
nobody ran anything is the honest direction for this number, and it is worth saying plainly rather
than letting the ratio look like a regression. Entry Detail's header also stopped lying: it claimed
22 against 28 contained, which **this same status file had already identified and left standing**,
and it now says 36.

**What this phase did not do.** It did not tick anything. Nothing here is a substitute for an
evening with a phone, and none of the eight new Entry Detail boxes or fourteen new Settings boxes
has been run. The backlog is now accurate, which is a precondition for running it and not a
substitute for it.

## Aug 16, 2026 — Phase 45: multi-kid had no device coverage

**Multi-kid shipped Aug 13. Nothing verified it on a phone, and phase 44 — a reconciliation of
this exact backlog, run the same day — did not notice.** 44 asked "what changed under these
checklists" and answered it for three files. It did not ask the complementary question: *what
shipped that no checklist mentions at all?* Adding a child got boxes only because it happened to
live on the Settings screen 44 was already editing. That is a reconciliation finding what it was
looking at rather than what was missing, and it is worth writing down because the same blind spot
is available to every future pass over these files.

**Phase 31's own record was the map.** It names six local reads that were unscoped and are now
child-filtered — *"Today's board merge, the widget snapshot, the backfill's month and day
coverage, the notification re-offer, extraction's queue, and Settings' `?? children.first`"*. Five
of the six had not one box between them. A phase that lists its own risky changes in prose and
then ships without a checklist entry for any of them is a gap that only closes if somebody goes
looking, and the prose was sitting in `roadmap-status.md` the whole time.

**Every one of these fails silently, which is the argument for covering them at all.** A wrong
child's data does not crash, does not error and does not look wrong — it looks like an archive.
The reasoning in the code says it better than a checklist can, and each box was written against
the specific read:

- **The backfill's month coverage is the worst of them.** Unscoped, a month the *sibling* wrote in
  counted as covered, so this child's empty months were never offered. The comment in `RootView`
  puts it exactly: *"a prompt that never appears is not a bug anyone can see."* Nothing in the app
  would look wrong, ever, and the loss is a month of a childhood nobody was invited to write down.
- **The notification re-offer is spent once and never comes back**, so an unscoped count handed a
  newly added second child an offer already used up by their sibling — on the one screen where the
  parent is most likely to say yes. There is no second chance to observe this one.
- **The widget snapshot reaches furthest.** It is filtered in memory rather than in the `@Query`,
  because a `@Query` predicate is fixed at init and cannot capture the child. That is correct and
  it is also exactly the shape a later refactor "tidies" back into the predicate. The file it
  writes is what the Lock Screen renders, so a wrong-child snapshot is wrong on a surface nobody
  opens the app to check.

**Two table defects closed on the way, and the second one matters more than its size.** Row 10
still carried Entry Detail at 28 after phase 44 had raised it to 36 — that phase updated the
number in four places and missed the table. And **the widget's boxes had never been in the table's
column at all**: row 1 points at its §1 as a pre-flight, which reads as though the file were
accounted for. It was not. This is the same defect the file had already complained about for
Moments, in the same table, and it survived the complaint. **The table now sums to 451, which is
the first time adding it up has been a check that works** rather than a claim the prose makes
about itself.

**Still nothing ticked.** 451 boxes, 9 of them, all from Aug 12. Two phases in one day grew the
denominator by 42 and moved the numerator by none, and that remains the honest direction: the
backlog is now closer to describing the app, which is a precondition for running it.

## Aug 16, 2026 — Phase 46: measure before building 33

**The ask was "finish 33". The honest answer is that 33 cannot be finished, and the useful answer
is that the decision behind it has never been measured.** Both are now written down.

**The block was re-verified rather than trusted, which is the whole discipline §9 was written to
enforce.** Same SDK — iPhoneOS26.4, Xcode 26.4.1. `Transcript.Segment` is still exactly `case text`
and `case structure`. The interface grep for `CGImage|CVPixelBuffer|UIImage|CIImage` still returns
0. Two days is not long enough for a platform to move, and checking anyway costs thirty seconds
against the alternative of building a phase on a remembered fact.

**What ships is a measurement, not a feature, and the distinction is load-bearing.**
`MAImageCaptioningCopyCaption` reads the XMP field `Iptc4xmpExt:AOContentDescription` — **a
description a human already wrote**, not a model's guess. That is the property that makes it worth
considering at all: `blocked.md` §9 rejects `Vision`'s label-stitching because *"a permanent
plausible lie about somebody's child is worse than an empty field"*, and a human-authored sentence
cannot be that lie. But the entire case rests on a number nobody has ever counted: what fraction of
a real camera roll carries that field. `CaptionProbe` counts it and stops.

**The reader was proven rather than assumed.** The suite writes a caption into a real JPEG with
`MAImageCaptioningSetCaption` and reads it back through the same call the probe uses. It round
trips. **So the API is not in question — only the population is**, and that is a much better place
for the uncertainty to sit than in a "does this even work" that a device evening would have had to
answer alongside everything else.

### Three things deliberately did not ship, and each was available

- **No caption writer, and therefore no state ladder.** The ladder is a SwiftData migration on
  every media row. Committing to it before the number is known is precisely the mistake §9 and the
  queue have both warned about since Aug 14.
- **No clobber guard, and this reverses a line in the plan I proposed.** I offered "measure first,
  *plus the caption clobber guard*" and then checked: `Media.applyServerSummary` writes `caption`
  unguarded and `SyncEngine.differs(_:from:)` compares it unguarded, so **the two agree and there
  is no live defect.** A guard would guard a writer that does not exist — the exact thing phase 41
  decided against. The deferral now points at this measurement rather than at a phase that may
  never land, which is a better place for it to wait.
- **No column for provenance.** The decision is settled — a caption from file metadata is not model
  output, so it needs a source distinction on `entry_tags.source`'s precedent — but `data-model.md`
  is deliberately unchanged. **This is where it differs from per-entry visibility**, which *was*
  specified before being built: that had a closed design and a known consumer, and this has neither
  until the measurement answers. Specifying a migration for a feature that may be deleted next week
  is the cost this project keeps refusing to pay.

**The probe is furniture with a scheduled removal, and that is stated in the code.** It sits under
the sync card rather than on the Settings page, for the same reason the sync diagnostics do — a tool
about an unshipped feature must not read as part of ordinary use. It could not go behind
`#if DEBUG`, because the only phone with a real camera roll runs a release build; that constraint
is why a diagnostic ships to production at all, and it is worth naming so the next reader does not
"fix" it.

**A near-zero result deletes `CaptionProbe` and `CaptionProbeScreen` and closes 33.** That is a
real possible outcome of this phase and it is written into the code, `blocked.md`, the roadmap and
the checklist — in four places on purpose, because a measurement whose disappointing result has no
pre-agreed consequence gets reinterpreted as a reason to build anyway.

**It cannot be run yet.** It needs a real camera roll, which needs a TestFlight build, which is
still the standing blocker on everything. `docs/Device-Verification/device-verification-captions.md` is nine boxes and
the twelfth checklist — 460 now, still nine ticked.

* * *
## Aug 16, 2026 — Phase 47: the app icon

**The owner settled it by naming a file** — `docs/app-icon/rascal-icon-fan.svg`, the third of the
three explorations, *"this is it for sure no matter what name we land on."* The caveat turns out to
be the substantive part: **the mark carries no word**, so it was decidable before the name was and
would not have moved after it. It was listed under the Dogear rename in two places and it was never
really a rename item.

**The whole shipping change is one PNG.** `AppIcon-1024.png` — 1024², no alpha, sRGB — replacing a
placeholder that was a rounded square with a dot in it. There is deliberately no 60pt or 76pt asset
to keep in step: `actool` derives every home-screen size from the single 1024, which was verified by
compiling the catalogue and reading `AppIcon60x60@2x.png` back out rather than trusting it. The
catalogue compiles with no notice or warning, and `Contents.json` did not need a line changed.

**The icon was a build product with no build, and that is the part worth keeping.** The PNG had been
produced by hand at some point and nothing recorded how, so the next edit to the SVG would have been
a fresh guess at parameters that matter. `render-appicon.mjs` is now the step: headless Chrome at
2048, halved to 1024. **Chrome specifically, and supersampled specifically** — this art puts
`feDropShadow` on five separate `clip-path` groups, and the lighter rasterisers either drop the
filter or resolve the clip in the wrong user space, both of which collapse the fan into a single
card silently and only at render time; and at 1024 native, Chrome fringes the 4pt scrubber track.
The script asserts the two things App Store Connect rejects on upload and nothing earlier mentions
— the dimensions and **the absence of an alpha channel**. It reproduces the committed PNG byte for
byte, which is what makes it a check rather than a convenience.

**`generate.mjs` next door was a live trap, and it caught this session before the session caught
it.** Running it — as its own header instructs — rewrote `rascal-icon-tinted.svg` and
`rascal-icon-tonal.svg` over newer committed versions, and regenerated `index.html` from a `VARIANTS`
list containing `scattered` and no `fan`, **deleting the contact sheet's only reference to the icon
that ships**. The fan SVG itself survived, orphaned, which is exactly what made the damage quiet: no
error, no missing file, just a page that no longer mentions the winner. It cannot produce the fan
under any flag — the fan is a different geometry model, five cards placed by `translate`+`rotate`
about their own centres rather than absolute rects growing downward — so it was **not** rewritten to
try. It is kept as the record of how tinted and tonal were derived, and it now refuses to write
without `--overwrite-explorations`, printing what it would clobber and pointing at
`render-appicon.mjs` instead. Past that flag it still does the original thing in full, index.html
included; the flag is the whole warning.

**Two things deliberately did not ship.** **iOS 18 dark and tinted icon variants** — the appiconset
carries only the universal slot, which is valid, and the system derives both. Adding real ones is a
design decision about what this mark looks like desaturated, not a mechanical fill-in, and nobody
has taken it. And **the `docs/` prose still says RASCAL throughout**, including this page's own
heading, which is the rename's own standing decision not to sweep cosmetic prose and bury real
diffs under mechanical ones.

**Recorded because it cost real confusion:** `docs/app-icon/index.html` was the only artefact that
correctly described the current state, and `generate.mjs` — the file that looks authoritative,
carries the instructions, and is newer on disk — was the one that lied. Where those two disagree,
the committed SVGs and the contact sheet are right.

* * *

## Aug 16, 2026 — Phase 51: the `aud` allowlist, and unbundling the APNs topic from it

**`APPLE_BUNDLE_ID` is a list now and keeps its name.** Renaming it would mean rotating a Fly
secret on a live app to buy nothing. It parses comma-separated, strips whitespace and drops
empty entries; one value is still one value, which is what production sets and what every
existing test exercises.

**`services/apple.py` needed no code change, and that is the design working rather than a
shortcut.** The `aud` check already passed `settings.apple_bundle_id` straight to PyJWT, and
PyJWT's `audience=` takes `str | Iterable[str]` with any-match semantics. Changing the type of
the setting changed the behaviour of the check. Only the docstring moved, to stop calling it an
equality.

**`NoDecode` on the annotation is load-bearing.** pydantic-settings JSON-decodes complex types
read from the environment, and `com.travisterry.childarchive` is not JSON. Without it the app
does not start at all — which is a loud failure, but a confusing one.

**The trap was `resolved_apns_topic`, and the setting it needed already existed.** The plan
called for adding `APNS_TOPIC`; it had been there since phase 14 (`config.py:102`). What was
missing was the rule about when it becomes mandatory. Two audiences with no topic now **fails
at startup** rather than silently taking `[0]`: guessing would be right today and wrong the day
somebody reorders a comma-separated secret, and the only symptom of getting it wrong is that no
push is ever delivered — `DeviceTokenNotForTopic`, from Apple, into a log nobody reads.

**An empty audience list also refuses to start.** `jwt.decode(audience=[])` rejects every token
Apple has ever signed, and `resolved_apns_topic` would have nothing to return. A blank or
comma-only value is a half-filled `.env` or an unset CI secret, and failing at construction is
the only reading of it that is ever useful.

**Break-tested three ways**: collapsing the allowlist to its first entry, removing the APNs
startup guard, and removing the empty-list guard each fail the tests written for them.

* * *

## Aug 16, 2026 — Phase 52: credential linking, revocation, and dev-login's second lock

**The unique constraint on `(provider, subject_id)` deliberately did not change**, and this is
the decision the whole phase rests on. A revoked credential keeps holding its namespace, so a
later sign-in with the same subject matches *that row* and therefore that user. Putting
`revoked_at` in the key — or hard-deleting on revoke — would let the next sign-in mint a second
user and leave the archive behind the first one unreachable. That is the only failure in this
table the person it happens to cannot undo, and it is silent: they would see a working app with
an empty archive.

**Three service rules, now stated rather than accidental.**

1. **Lookup finds revoked rows.** `find_credential` filters on `(provider, subject_id)` and
   nothing else, and `user_for_credential` clears `revoked_at` on a successful sign-in. The
   filter that looks obviously correct — `revoked_at IS NULL` — is the bug.
2. **Gap-fill is first-non-null-wins.** A second credential fills `users.email` and
   `users.display_name` only where they are null, and never overwrites. The guard is
   `column IS NULL and the incoming value is truthy`, so an empty string from a provider does
   not count as an answer. The parent changes their name through `PATCH /me` and nowhere else.
3. **`users.email` stays unwritable through the API**, per the contract, and linking does not
   become a back door to it.

**No email matching anywhere.** A credential joins an account because somebody signed in to
that account and asked for it. Two people share addresses, and an Apple relay address is not
the same string as a Google one — an archive of a childhood is not a thing to hand over on a
string comparison.

**`credentials` gets `updated_at` and a trigger, and it is the odd one out.** `refresh_tokens`
and `idempotency_keys` still have neither, and `CLAUDE.md` rule 5 has evidently been read as
covering synced user data rather than auth rows. It earns one here because a revocation is a
change to a row that is otherwise write-once, and a change nothing can observe is a change
nobody can act on. Backfilled to `created_at` rather than `now()`, so existing rows do not
claim this migration edited them.

**`password` stays in the CHECK after the data migration moves every row off it.** Removing a
value from a CHECK is a migration that can only fail — on a row somebody did not migrate — in
exchange for nothing.

**The production claim was measured, not asserted.** The plan said the `password` → `email`
migration touches the dev fixture only. Read from `rascal-api` before writing the migration:
one `users` row, one `credentials` row, `provider = 'apple'`, zero `password` rows. True. The
statement is still written unconditionally, because a migration that is correct only on the
database somebody happened to look at is not a migration.

**`subject_hint` masks by shape rather than by truncation.** What a parent needs from that
string is *which of these two is which*. An address keeps its domain and the first letter of
its local part; an opaque provider subject keeps its last four characters. A raw `subject_id`
never leaves the service.

**`DELETE /me/credentials/{id}` on somebody else's id is 404, not 403.** Every other route here
leaks existence deliberately and says so; this one is about a different account, so it does not.

**`POST /me/credentials` takes `Literal["apple"]` rather than the column's full provider set.**
The schema permits a value only once something can verify it — `google` with phase 54, `email`
with phase 57. Asking for one early is a 422 naming the field, rather than a route that accepts
an unverifiable claim.

**A pre-existing race was fixed rather than inherited.** `user_for_credential` did a SELECT then
an INSERT with only the unique constraint between them, and the loser of two concurrent
first-ever sign-ins raised an uncaught `IntegrityError` — a 500 for what is actually a
successful sign-in. Both it and `attach_credential` now insert inside a savepoint and resolve
the constraint violation into the right answer.

**dev-login's domain guard closes a different hole from its local-only gating.** The route is
already absent from a production build. What this stops is a *local* API pointed at a *real*
database — a restore drill, a production debugging session — handing back an `is_admin` session
for somebody's actual account because a developer typed their own address. `ENVIRONMENT` can be
right while the database is not. The address is lowercased before the domain is compared,
because a case-sensitive domain check is a hole rather than a check.

**Two test changes that are adjacent to a rule this build is not allowed to break**, both named
here so they can be checked rather than trusted. `test_acceptance.py` signed in as
`travis@example.com`, which the domain guard now refuses: the **input** moved to
`travis@rascal.local` and the assertion is untouched. `test_error_codes_are_the_documented_ones`
pins the `ErrorCode` enum as a literal set, and the two new codes were added to it *and* to the
contract's table — that test exists to make adding a code deliberate, and it did its job.

**Break-tested five ways**, and the first is the one that matters: filtering revoked rows out of
the lookup, allowing the last credential to be revoked, reassigning a bound subject instead of
refusing it, removing the dev-login domain guard, and making gap-fill overwrite. Each fails the
test written for it.

* * *

## Aug 16, 2026 — Phase 53: Apple's notifications, and one decision that will look like a bug

**`account-delete` and `consent-revoked` do exactly the same thing.** Apple is telling us an
Apple ID was deleted, not that a childhood should be. It has no standing to ask for that, and
the parent most likely consolidated Apple IDs and has no idea a notification was sent. Both
events set `credentials.revoked_at` and revoke every refresh token, and neither touches `users`,
`children`, `entries` or `media`. **Written into `decisions.md` rather than left as a code
comment, because the identical handling will read as a copy-paste mistake** — and "fixing" it
would delete somebody's archive on a third party's say-so.

**Three claim-set traps, each of which rejects every real notification if missed.** `sub` is not
a top-level claim — it lives inside `events`, so requiring it fails everything. There is no
`exp`, so requiring that fails everything too. And **`events` is a JSON string, not an object**,
which looks like an error in Apple's documentation and is not. `event_time` is in
**milliseconds**; read as seconds it lands in the year 56000 and every comparison against it is
nonsense.

**The route answers `202` for an unknown subject and an unhandled event type.** Apple retries
anything that is not 2xx, so a 4xx is a promise to handle something later. A `404` for an
unknown subject would also tell an unauthenticated caller which Apple IDs have accounts here.

**Revoking has to kill the sessions too.** Without it, revoking while the app is closed leaves
the phone signed in until the refresh token expires — up to thirty days of a session the parent
believes they ended. `_revoke_chain` was made public as `revoke_all_refresh_tokens` rather than
reached into.

**`email_deliverable` is a third column and not a third consent lane.** Phase 49's two lanes
record what the parent *chose*; this records whether the channel physically *works*, which Apple
tells us and the parent does not.

**Break-tested five ways**, and the first is the one that matters: skipping the signature check,
deleting the account on `account-delete`, leaving sessions alive, reading `event_time` as
seconds, and letting an email event revoke.

**This phase may not be marked complete.** `blocked.md` §11 is the device run, and the assumption
it tests — that Apple's `sub` survives a revoke-and-reauthorize cycle — has never been observed
here. Every one of the nineteen tests would still pass if it were false.

* * *

## Aug 16, 2026 — Phase 54: Google, and a break-test that caught a decorative test

**The JWKS machinery was extracted and shared rather than copied.** `services/oidc.py` holds the
cache, the one-refetch-on-unknown-`kid` rule and the decode; `apple.py` and `google.py` hold what
is actually different. Two hand-maintained copies of a signature check drift, and **the drift is
silent** — the copy that did not get the fix keeps returning 200s. The refactor is safe because
Apple's 76 tests passed through it unchanged, which is the only evidence worth having.

**Google's `iss` is an allowlist because Google publishes two spellings** of its own issuer and
both are seen. Apple's is a single string. The shared decoder checks `iss` itself rather than
handing it to PyJWT, whose `issuer=` takes one value.

**`GOOGLE_CLIENT_IDS` is separate from `APPLE_BUNDLE_ID` from day one.** `aud` is a claim name
the two providers share over entirely unrelated namespaces.

**Unset is a real state and it answers differently.** No Google project exists, so the default is
empty — and empty makes the route `422` naming the setting, rather than `audience=[]` rejecting
every real token as "could not be verified", which is true and useless.

**The break-test discipline earned its keep here.** Pooling the two audience lists — the exact
bug the separation exists to prevent — **passed all 24 tests**. The cross-provider test was
decorative: the stubs use different keys, so an Apple token offered to Google dies on the
signature and the audience check is never reached. A second test now signs with **Google's** key
and puts **Apple's** audience in `aud`, so the audience check is the only thing that can reject
it. That test fails under the pooled-list bug and passes now.

* * *

## Aug 16, 2026 — Phase 56: the mailer, and why it is its own phase

**Building it inside either consumer would have shaped it around that one.** Phase 38's lifecycle
notices and phase 57's magic link both need a mailer; whichever went first would have produced a
lifecycle-notice sender that the second had to work around. So: `send(to, subject, text, html)`,
raises on failure, and **knows nothing about consent, deliverability or credentials** — there is
a test that greps the file to keep it that way, because a comment saying so would rot.

**`console` as the default is a safety property, not a convenience.** It never opens a socket, so
a local run cannot send real mail to a real parent — and the eventual content of these messages is
"your child's archive is scheduled for deletion". The test asserts it by replacing `httpx.AsyncClient`
with something that raises, which catches a future provider that reaches for the network while
still printing something plausible.

**One retry, never on a 4xx.** The failures a retry recovers are a dropped connection and a single
5xx. A 4xx says the message is malformed and will say it again more slowly. A backoff ladder inside
a request handler is worse than a caller that learns quickly that the send failed.

**No recipient in the log line.** An address in a log is the address leaving the system by a path
nobody audited; the message id is what an investigation actually needs.

* * *

## Aug 16, 2026 — Phase 57: magic links, and the token that may not put a key back

**`POST /auth/email/start` never creates a user, and that one restriction is the whole design.**
It kills the orphan-account trap (an Apple parent typing their address into the email field and
getting a second, empty archive), account enumeration as a signup surface, and every argument
about self-serve password reset, at once. Email is a second key to a door you already own.

**An address is proved by the click, never by the field it was typed into.** `POST
/me/credentials/email` creates the credential **inactive** and mails a link. A typo therefore
costs nothing — the inbox that receives the link is the only one that can activate it.

**A token carries a `purpose`, and that column was added because a test was weak.** The first
version cleared `revoked_at` on any successful click, which meant an outstanding sign-in link
could reactivate an address the parent had deliberately removed — **Remove would have been a
suggestion rather than an action**. The test written for it had an `in {200, 401}` assertion,
which is the shape of a test that has stopped asserting anything. Only a `verify` token may
activate a credential now, and re-adding a removed address is the deliberate path back.

**`revoked_at` is reused for "added but not yet verified" rather than adding a second column.**
The meaning a client needs is identical — *this is not a way in* — and a second state that renders
the same way is furniture.

**Rate limiting is in Postgres and the reason is deployment, not preference.** There is more than
one Fly machine, so an in-process counter is per-process theatre: N times looser than it reads,
resetting on every deploy, and passing every test. **Per-email is the limit that matters** — the
abuse is spamming links at one address, and an edge limiter cannot see the address because it is
inside the request body, which is exactly why this lives in the app and not at Cloudflare. A
refusal does not record an attempt, so being refused cannot extend your own lockout.

**A fixed window, not a sliding one.** It permits a burst across a boundary — up to twice the
limit in an instant — and against "how many emails can one address be sent in an hour" that is a
rounding error rather than a hole.

**One mistake worth recording, because the suite caught it and a narrower run would not have.**
A scripted edit added the `purpose` column to `RefreshToken` instead of `EmailSignInToken` — the
two models share an identical two-line signature, and the pattern matched the first one. Every
sign-in in the service broke: **79 failures**, immediately, from a change that lints clean and
reads correctly in isolation.

**Break-tested five ways**, including the one the plan named: removing the never-creates-a-user
guard, making tokens replayable, letting a sign-in link reactivate a removed address, activating
an address without a click, and dropping the per-email limiter.

* * *

## Aug 16, 2026 — the pre-merge security review of phases 51–59

**Six reviewers over three PRs, 18 findings, 14 fixed, two of them critical.** Recorded here
because the findings are more instructive than the fixes, and because two of them are mistakes
worth not repeating rather than bugs worth forgetting.

**The two criticals were both silent, and both were mine.**

*Remove did not mean removed.* An `email` credential is created inactive while its verification
link sits in an inbox, and `revoke_credential` returned early on "already revoked" — so removing
a pending address was a no-op that left the link live. A parent who mistyped an address, noticed,
and removed it was still handing whoever holds that inbox a working session on their child's
archive. **The early return was written as a kindness** — "the state the caller asked for is the
state that holds" — and it was the hole.

*The per-IP rate limit was one bucket for the internet.* It keyed on `request.client.host`, which
behind Fly's proxy is the proxy. Twenty requests an hour from anywhere would have locked every
parent out of magic-link sign-in: **the protection as the denial of service**. The fix reads
`Fly-Client-IP` and deliberately does *not* trust `X-Forwarded-For`, which a caller can forge to
mint a fresh bucket per request — the opposite failure, and the quieter one.

**The most valuable single outcome was a break-test exposing a decorative test.** Pooling Apple's
and Google's audience lists — the exact bug the separation exists to prevent — passed all 24
Google tests. The cross-provider test dies on the *signature*, because the two stubs use
different keys, so the audience check is never reached. It asserted the right outcome for the
wrong reason and would have gone on doing so forever. There is now a test that signs with
Google's key and puts Apple's audience in `aud`, where only the audience check can reject it.
**A test that passes for the wrong reason is worse than no test, because it is counted.**

**A design inconsistency turned out to be the tell for a leak.** `POST /me/credentials/email`
answered `409 credential_in_use` when an address belonged to another account — an enumeration
oracle reachable by anyone who can create a free account. What made it obvious was not the
threat model but the inconsistency: `POST /auth/email/start` already refuses that exact question
about that exact address with an unconditional `202`. Two endpoints, one question, two answers.
**Where two endpoints disagree about how much to say, the quieter one is usually the considered
position and the louder one is usually an oversight.**

**Three findings were about concurrency and all three had the same shape** — check-then-act. The
rate limiter counted before inserting; `revoke_credential` counted live credentials before
writing; `user_for_credential` flushed the user outside the savepoint. Each is correct against
serialised traffic and wrong against exactly the burst it exists to handle. The fixes are the
same shape too: do the write first and let the constraint arbitrate, or re-test the population
in the `WHERE`.

**One fix introduced a bug that was caught before shipping**, and it is recorded because the
near-miss is the lesson. Making the rate-limit sweep global — correct, since a bucket nobody
queries again keeps its rows forever — initially pruned everything older than *the current
call's* window. No limiter with a longer window exists today, so it was latent; it would have
started deleting live rows the day one did. It prunes against a fixed `MAX_RETENTION` now.

**Two assertions were changed, which is the one place in this work that happened.** Both encoded
the `409` contract that the oracle fix deliberately removed. They were rewritten to assert the
property that replaced it — a conflicting add and a fresh add are indistinguishable in status
and body, and the conflicting one writes no row and sends no link — rather than relaxed to pass.
**The distinction that makes it legitimate is that the behaviour changed first, for a stated
reason, and the test was rewritten to pin the new behaviour.**

**The client copy got worse on purpose.** The credentials sheet could previously say "that
address already signs in to a different account"; repeating the server's answer would have put
the leak straight back on screen. It says the same sentence in every case now. A parent who
mistypes into a colleague's address sees a link that never arrives, which the footer states
outright — a real cost, accepted, because the alternative told a stranger something about
somebody else's account.

**Verification honesty about the review itself.** The six reviewers ran on Opus 5; the
independent verification pass did not run, because the workflow hit a spend limit with 21
verification agents still queued. Every finding acted on was therefore confirmed by hand against
the code rather than by a second model. Four lower-severity findings were fixed on that basis in
a follow-up commit. **The subagents had also silently defaulted to a smaller model on the first
attempt** — caught by the owner, not by me, after I asserted they would inherit the session
model without checking. Assert nothing about what a tool resolved; read it back.

## Aug 16, 2026 — the overnight sprint, and seven gates that all held

Seven stories were specified in `docs/sprint-aug16/` and run one per loop overnight. **All seven
halted on their own preflight gates. Nothing was built and no phase number was consumed.** Each has
a report in that directory; the discrepancy list is in `story-7-report.md`.

- **The sprint's story files were authored against a repo that no longer exists**, and the tell was
  in the runbook's own premise. It stated that `phase-queue.md`, `data-model.md` and `decisions.md`
  disagree about the phase high-water mark, and named 47, 49 and 50. **All three claims were checked
  and none holds.** The "47" is inside a blockquote in `phase-queue.md` documenting a *past* error —
  the file's own conclusion there is *"Neither file was right. `main` was."* — and the other two are
  accurate historical records, not conflicts. `main` is at 60 with 51–59 merged the same day. The
  numbering rule that works is the one already written down: **measure `main`, not a status
  document's count.**

- **"Take the next free phase number" is the wrong rule for work that already has one**, and it is
  how two stories failed the same gate by different routes. Story 1 is **phase 60**, specified in
  the ledger with a contradicting design; story 3a is **phase 36** plus phase 37's entitlements
  table. Taking 61 in either case would have orphaned a merged spec. A phase number is an
  identifier; a story that re-specifies existing work needs the existing number, not a new one.

- **Three stories asserted an owner decision that no merged document carries, and the first was
  contradicted outright.** Story 1 claimed a rate-limiting exception granted Aug 16; `decisions.md`
  item 12(1) records the owner making the opposite call on that date. Story 3a claimed four settled
  answers to open item 11, which says in terms that its collisions each need an answer *before
  anything is built*. Story 6 claimed authorisation to record a device-verification result. **After
  the first, the phrase stopped being taken on trust** — the standing habit of writing settlements
  into `decisions.md` is what made the check possible at all, and item 12's `PARTIALLY ANSWERED`
  marker is what proved item 11's silence meant something.

- **A partial result recorded against §0 of the transcription checklist would have destroyed the
  measurement rather than banked it.** §0 has five boxes; the owner's recorded observation covers
  part of one, and says nothing about whether the model invents plausible sentences where the child
  mumbled — the finding that would argue for a confidence signal, a schema change and a separate
  phase. §0's own closing line is why: *"the only measurement in the project that cannot be
  re-derived by running something later — the recordings change as he does."* A ticked §0 stops
  anyone running §0.

- **Gate 4 of story 3a was run against production rather than the local fixture, and that was the
  point of it.** `SELECT child_id, count(*) FROM guardians WHERE revoked_at IS NULL GROUP BY
  child_id HAVING count(*) > 1` returned **0 rows** against Neon: 1 user, 2 children, 2 active
  guardians, 25 assignments, 27 live entries, head `0013_email_sign_in`. The local database would
  have answered 0 too and proved nothing, because the migration does not run there. **The backfill
  window is open and the evidence is banked** in `story-3a-report.md`, because it is not
  reconstructable after a second guardian exists.

- **Nothing was touched in `Rascal-Marketing`**, which has seven uncommitted files on `main`
  including two that stories 2 and 5 would both edit. A story that must leave a clean tree cannot
  start in a dirty one, and the alternative was to guess whose work it was.

- **Story 5 was not replaced with a free-hand substitute.** It calls for a compliance assessment
  from a tool that does not exist here. Writing GDPR/CCPA/COPPA analysis for a product holding a
  named minor's photographs, video and voice, overnight, unreviewed, and publishing it as the basis
  of a public privacy policy is not the same task — and the story's own gate makes the argument:
  *"a public commitment nobody can keep."*

## Aug 17, 2026 — the Vellum rename, and what was deliberately left alone

- **The owner ruled the name is officially Vellum**, with the *Vellum by 180g* trademark risk
  already on the table and no clearance search run. Recorded as a knowing decision with the risk
  left open, not as a resolved question. The expensive surfaces are outbound email — which cannot
  be recalled once sent — and the App Store listing.
- **`manifest.format` stayed `rascal-export` through a second rename.** It has now survived both.
  The viewer checks it, and moving it would make every archive exported before today fail to open
  in a newer viewer. The download filename is decoration and moved both times.
- **`docs/marketing/email-sequence.md` was not touched, and neither was the YAML generated from
  it.** The file's header forbids an agent editing that copy. The owner authorised the *name*, not
  an exception to that rule, and he was asleep. The order when he does it: edit the markdown, then
  re-run `scripts/email_sequence_to_yaml.py` — a direct edit to `api/seeds/email_copy.yaml` is
  silently discarded on the next regeneration.
- **D5a's subscription group was corrected to `Vellum Membership` while that was still possible.**
  App Store product identifiers are permanent on first save; nothing exists in App Store Connect
  yet, so this was a free edit today and an impossible one later.
- **A half-applied rename is worse than either end of it.** The site saying Vellum while the
  sign-in email says Dogear is the state to avoid, which is why the remaining surfaces are
  enumerated in the decision row rather than left to be discovered.
## Aug 17–18, 2026 — the overnight sprint, reconciled (story 7, phase 74)

**The sprint's own specs were the least reliable document in the room**, and that is the entry
worth keeping. They were authored roughly thirteen phases behind `main` and specified an
endpoint (`POST /v1/subscribers`), a table (`subscribers`), a webhook and a rate-limit exception
that either never existed or had been settled the other way. **Every story that ran had to be
built against the tree rather than against its own brief**, and the two that were not built —
3a and 3b — were not built because they had already shipped as phases 36, 61 and 63.

- **Story 7's own instructions were partly false and were not followed literally.** It asks for
  five specific claims to be written into `decisions.md` item 12, three of which contradict
  `main`: a `subscribers` table as the source of truth for consent, a welcome sequence sending
  through the Emails API, and a consent webhook. **Its gate 3 is what authorised ignoring
  them** — *"if a report claims something and the tree disagrees, the tree wins and you write
  down the discrepancy"* — so the discrepancies are recorded in item 12 rather than the claims.
- **Gate 1 was not satisfiable as written and was met in substance.** It requires every other
  story to be merged or halted, while the runbook forbids a story merging its own PR. Taken
  literally, story 7 can never run unattended. Phases with open PRs are filed as **PR open**,
  never as shipped, which is the honest form of the same information.
- **A queue header went stale by six numbers in one evening.** Third time in three days, and the
  mildest — stale rather than self-contradicting. The rule that worked again: measure `main`,
  not a status document's count. Phase 71 read *"the next is 68"*, checked `main`, and found 68
  already merged.
- **Deleting evidence to tidy a report was caught and reversed.** Phase 72's first commit
  replaced story 3a's 196-line report with a 55-line summary of the same conclusion, discarding
  the gate-4 production evidence from a window that has since closed, both break-tests, and the
  adversarial-review table. Restored under a dated header. **The same failure as an absolute that
  goes false: it costs nothing today and everything the day somebody needs it.**

* * *

## Aug 18, 2026 — Phase 70: the Vellum wordmark, the logo kit, and the app icon

**Phase 47 said the icon decision was name-independent, and it was right.** *"The mark carries
no word, so it was decidable before the name was and would not have moved after it."* The name
moved twice — RASCAL to Dogear to Vellum — and the fan did not. What this phase added is one
change to it, not a redraw: the front card's entry title, a 138×15 bar standing in for a line of
type, becomes the actual line of type. The owner chose that over a wordless V-fan and a monogram.

**Both losing candidates are kept in the tree** as `vellum-icon-alt-v.svg` and
`vellum-icon-alt-monogram.svg`. A candidate nobody can look at again is a decision nobody can
revisit, and the V-fan in particular is the one to reach for if the icon ever has to work without
a name — which is the situation this project has now been in twice.

**The five cards are lifted out of `rascal-icon-fan.svg`, not redrawn.** The generator parses the
shipped file for each card's fill and the motif inside its clip, and re-authors only where the
cards sit. A redraw would have put a dozen changes on the table and called them one. **The parse
had a real bug in it**: the file lists cards in *drawing* order, back to front, with the front
card last at rotation 0, and reading that order as positional put the audio card in front. It
looked like a z-order problem. Cards are sorted by tilt now, and the sort carries the comment
saying why.

**The wordmark is drawn, not set.** A monolinear skeleton stroked at a constant weight with round
caps and joins, every curve a true circular arc. Three things follow: no font file ships, no
licence is anybody's to enforce, and the letters render identically in a browser that has never
heard of us. The round terminals are not taste — the app's type is SF Rounded and the cards carry
a 52/252 corner radius, and a flat-cut wordmark beside that art reads as a different company's.
Eight builds were drawn; the owner chose build 5, short ascenders, set lowercase. **The chosen
metrics are the generator's defaults**, so the lockups and the icon are the chosen build by
construction rather than by a number copied into three files by hand.

**Two defects that were invisible until the ground changed, which is the interesting part.**

The colour lockups painted the gap between one card and the next in canvas cream. That is correct
on the app's cream canvas and invisible there — and on the marketing site's white it reads as a
warm halo around every card, so the mark looks soft-edged where it should look cut. They knock the
gap out of the card behind now, which is true transparency, and the same file is right on white,
on cream and on ink. **Byte-identical on cream**, so nothing that was already right changed.

The one-colour lockup failed the same way from the other direction. Depth there cannot come from
tone, because there is only one tone; the first build used translucency, and overlapping sheets
compound and go grey the moment the ground is dark. It knocks out too.

**An asset that encodes an assumption about its surroundings looks correct until the surroundings
change.** Both of these were shipped-looking for hours.

**The hover component deliberately does the opposite, and that is a trade rather than an
inconsistency.** A knockout mask is built from where the cards *are*. The instant a card rotates
away, its notch stays behind and the mark tears — so the animated version strokes its gaps in
white, which moves with the card and costs it ground-independence. Motion and ground-independence
are opposite sides of one choice; the static files and the header component sit on opposite sides
on purpose. Written into both files, because it is exactly the difference a later reader corrects
into a bug.

> **Struck the next day, and the paragraph is kept rather than deleted because the mistake in it
> is the useful part.** *Motion and ground-independence are not opposite sides of one choice.*
> They were opposite sides of **a static mask**, which was the only kind that had been tried, and
> the write-up promoted an untested limit to a law. Give the mask's shapes the same class and the
> same custom properties as the cards they mirror and one CSS rule moves both: the knockout tracks
> the card and never has to know its ground. Corrected in phase 70a.
>
> **Applying it to the marketing site is what exposed it, and the site would have caught the stroke
> version in production.** That masthead is `color-mix(in srgb, canvas 88%, transparent)` over a
> `backdrop-filter`, so page content scrolls underneath and tints it continuously — no solid colour
> a stroke could use stays right at every scroll position. Cream is correct at the top of the page
> and a visible halo over a photograph twenty pixels later: a defect that appears only once
> somebody scrolls, which is the kind that ships.
>
> **The general form is worth more than the fix.** A limit found while building one thing is a
> property of that build until it has been attacked separately. Writing it down as a law makes it
> permanent, and *another agent recorded this one in the marketing repo's brand notes on the
> strength of this paragraph* — a false claim propagating across two repositories inside a day, on
> nothing but confident phrasing.
>
> **And it went both ways the same day, which is the part that makes it a mechanism rather than a
> lapse.** That agent gave a reason for keeping the site's footer tagline as text — that it was the
> only place the product name reached the Markdown twins — and it was invented; the twins are
> rendered from the page body and have never contained the footer. I wrote that reason into
> `footer.html` in good faith because it sounded like something already checked. So each of us
> planted a confident false reason in the other's repository, and **neither of us caught our own.
> Each caught the other's.** The advice was right in both cases; only the reasons were fabricated,
> which is what let them travel.
>
> **Both claims had the same tell: each one explained why something was impossible.** That is the
> class of statement that most deserves a second look and least often gets one, because it closes a
> question rather than opening one — nobody re-derives a dead end. Worth reading twice whenever a
> note says a thing cannot be done.

**The mask also had to be hung on an untransformed wrapper.** `maskUnits="userSpaceOnUse"`
resolves against the referencing element's own user space, so a mask on the rotated card group
interprets its coordinates inside that card's rotated frame. It renders as one solid silhouette
with no gaps at all, which looks like the mask being ignored rather than being applied in the
wrong place.

**Three cards, not five, below about 24px.** `vellum-mark-compact.svg` exists because the
five-card fan stops being five of anything at favicon size, and an honest three beats a smudge
claiming to be five.

**`index.html` is hand-kept and this generator does not write it.** `generate.mjs` next door
regenerates the contact sheet from its own variant list, and doing so once deleted the only page
that mentioned the shipped icon. Importing `generate-vellum.mjs` also writes nothing — the file
writes are behind an entry-point check, because the contact sheet's build imports a function from
it and a module that writes nine files as a side effect of `import` is one you cannot borrow from.

**Nothing has shipped to a phone.** `render-appicon.mjs` still reads `rascal-icon-fan.svg`, and
that file was not modified. Repointing it and re-rendering `AppIcon-1024.png` is an iOS-lane
change under the two-lane rule, and takes its own number. **The icon is drawn and decided, not
shipped**, and treating those as the same thing is how the PNG became a build product with no
build the first time.

**One thing the owner should see rather than have settled for him.** He confirmed the Vellum name
has been checked and is fine, and `decisions.md` open item 15 — filed the same night by another
session — records that no clearance search has been run. Both accounts now stand in the repo, as
disputed rather than as fact. **The chosen icon bakes the wordmark into pixels**, so the cost of
the name being wrong went up with this phase rather than down. That is an argument for settling
item 15, not for reopening the icon.
