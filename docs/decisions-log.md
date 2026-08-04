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
