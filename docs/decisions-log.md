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
