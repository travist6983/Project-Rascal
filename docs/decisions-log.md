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
