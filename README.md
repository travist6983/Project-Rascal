# RASCAL

A private archive of a childhood, built one prompt at a time.

Each day the app hands a parent two things: **a question** to answer about their kid, and
**a mission** — take a photo, shoot a video, record their voice, or do a thing together.
Completed items become entries on a searchable timeline. Years later, the kid gets the keys.

This repository holds **both halves**: the backend in `api/` and the iOS client in `ios/`. ~~*The iOS client is a separate piece of work; `ios/` is empty.*~~ — **that was true when this file was written and stopped being true long before Aug 18, 2026**, when it was finally corrected: `ios/` is a full SwiftUI app of 241 Swift files, on TestFlight against the deployed API. The two are separate **lanes** rather than separate repositories — an agent working in `ios/` never edits `api/` and vice versa, CI is path-scoped, and `ios/CLAUDE.md` carries that lane's rules. **The product is called Vellum**; `RASCAL` is the repository and package name and deliberately stays put, the way `manifest.format` has stayed `rascal-export` across two renames.

- **Specs live in `docs/` and are authoritative.** `data-model.md` is the schema,
  `api-contract.md` is the endpoints, `decisions.md` is settled and not up for relitigation,
  `mission-library.md` is the seed content, `memory-app-roadmap.md` is the scope.
- **Standing rules for anyone working here — human or agent — are in `CLAUDE.md`.**
- Judgment calls made while building are in `docs/decisions-log.md`, and anything waiting on
  you is in `docs/blocked.md`.

**Python 3.12 · FastAPI · SQLAlchemy 2.0 · Alembic · Postgres 16 · S3 · uv · Fly.io**

---

## Run it locally

Five commands from a clean clone. You need [`uv`](https://docs.astral.sh/uv/) and Docker.

```bash
cp .env.example .env    # safe local defaults, no real credentials anywhere
make up                 # Postgres 16 on localhost:5433, waits until healthy
make migrate            # alembic upgrade head
make seed               # 113 prompts from api/seeds/prompts.yaml
make test               # the full suite against a real Postgres
```

Then:

```bash
make dev                # http://localhost:8000 — OpenAPI docs at /docs
```

Port 5433, not 5432, so a Postgres you already have installed keeps working.

### A session, without an Apple Developer account

`dev-login` exists only when `ENVIRONMENT=local`, which is what `.env.example` sets.

```bash
TOKEN=$(curl -s -X POST localhost:8000/v1/auth/dev-login -H 'content-type: application/json' \
  -d '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

CHILD=$(curl -s -X POST localhost:8000/v1/children \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"name":"Miles","birthdate":"2022-06-14","family_timezone":"America/Detroit"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

# Run the daily loop for any date you like, as often as you like.
curl -s -X POST localhost:8000/v1/debug/scheduler/run \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"date\":\"2026-08-15\",\"child_id\":\"$CHILD\"}"

curl -s "localhost:8000/v1/children/$CHILD/today?date=2026-08-15" \
  -H "authorization: Bearer $TOKEN"
```

`POST /v1/debug/reset-today` clears a day so you can run it again against an edited library.
Both debug routes and `dev-login` are absent from a production build, and there are tests
that assert it.

---

## Make targets

| Target | What it does |
|---|---|
| `make up` / `make down` | Postgres 16 on 5433, named volume, healthcheck |
| `make dev` | uvicorn with reload on :8000 |
| `make test` | pytest against a real Postgres (`<dbname>_test`) |
| `make lint` / `make fmt` | ruff check and format |
| `make migrate` | `alembic upgrade head` |
| `make revision m="..."` | new empty migration |
| `make seed` | load `api/seeds/prompts.yaml` — idempotent |
| `make scheduler d=2026-08-15` | run the daily job; omit `d` for now |
| `make reset-db` | downgrade to base, re-migrate, reseed |
| `make psql` | psql shell against the dev database |
| `make fixtures` | capture real API responses into `ios/Fixtures/` |

### `make fixtures`

Logs in with `dev-login`, resolves the child from `GET /v1/children`, and writes the real
responses to `ios/Fixtures/dev-login.json` and `ios/Fixtures/today.json`. **Re-run it
whenever an API response shape changes** — those two files are the iOS client's ground
truth for JSON decoding, and a stale fixture is a client that compiles against a contract
the server no longer serves.

It needs a running API and a child that exists; it fails loudly and writes nothing rather
than capturing an error body. Point it elsewhere with
`make fixtures API_BASE=https://rascal-api.fly.dev` — though note `dev-login` is `404` on a
production build, by design.

---

## Tests

```bash
make test                                             # everything
cd api && uv run pytest -q tests/test_acceptance.py   # the loop, end to end
cd api && uv run pytest -q -k scheduler
```

Every test runs against a real Postgres. The schema is full of CHECK constraints, a
functional index, and a trigger, and SQLite would verify none of it. The suite owns a
separate `<dbname>_test` database, builds it once per session by running the real migrations,
and truncates between tests — your dev database is never touched.

S3 is `moto`. Apple's JWKS is a locally generated RSA keypair. **No test touches the
network.**

`tests/test_acceptance.py` is the one that matters: dev-login, create a child, run the
scheduler for an arbitrary date, fetch `/today`, complete one assignment with a text entry
and another with a `did_it` entry, and see both in `GET /entries`.

---

## Adding a migration

```bash
cd api
uv run alembic revision --autogenerate -m "add whatever"   # or: make revision m="add whatever"
# read the generated file — autogenerate does not see triggers, functional indexes,
# or raw SQL, and it guesses badly about server defaults
make migrate
```

Two conventions the schema depends on:

- **Name every index and constraint.** Alembic autogenerate against unnamed constraints
  produces migrations that cannot be reversed cleanly. `api/src/rascal/models/base.py` sets
  a naming convention that handles this for you.
- **A new table with `updated_at` needs the trigger.** Add it to `TABLES_WITH_UPDATED_AT` in
  `models/base.py` and attach `set_updated_at()` in the migration. `updated_at` is never set
  by application code — a bulk `UPDATE` from psql has to move the sync cursor too.

Every migration must be reversible. `tests/test_migrations.py` runs `upgrade head`, asserts
every table, index, CHECK, function, and trigger by name, then runs `downgrade base` and
asserts nothing survives.

---

## Editing the mission library

`docs/mission-library.md` is the authoring surface. Runtime never parses a markdown table.

```bash
cd api
uv run python scripts/mission_library_to_yaml.py   # regenerates seeds/prompts.yaml
make seed                                          # upserts; never duplicates, never deletes
```

Commit both files. A test regenerates the YAML from the markdown and fails if they disagree.

Tone rules for new prompts are at the top of `docs/mission-library.md`: specific over
sentimental, second person, imperative for missions, never sanctimonious.

---

## Layout

```
CLAUDE.md                  standing rules, for a future session
Makefile                   the whole local loop
docker-compose.yml         Postgres 16 on 5433
.env.example               every key, with safe local defaults
.github/workflows/ci.yml   lint + tests against a Postgres service container
docs/                      the specs, plus decisions-log.md, blocked.md, DEPLOY.md
ios/                       the SwiftUI client — 241 Swift files, its own lane, its own CLAUDE.md
api/
  pyproject.toml           deps, ruff, pytest
  Dockerfile               multi-stage, non-root
  fly.toml                 release_command runs migrations
  alembic/versions/        0001_initial — the whole schema, reversible
  seeds/prompts.yaml       generated; what the loader reads
  scripts/                 the markdown-to-YAML converter (never runs at request time)
  src/rascal/
    main.py                the app factory; everything mounts under /v1 except /health
    config.py              pydantic-settings, reads the repo-root .env
    db.py                  async engine, session-per-request
    deps.py                current_user and child_access. All authorization lives here.
    errors.py              ErrorCode, RascalError, and the one exception handler
    constants.py           every constrained value set, shared by models and schemas
    models/                SQLAlchemy 2.0 declarative
    schemas/               Pydantic v2 wire models
    routers/               HTTP only — no business logic
    services/              scheduler, entries, media, sync, seeding, tokens, apple
    jobs/                  python -m rascal.jobs.{scheduler,seed}
  tests/
```

Routers are thin. Anything worth testing lives in `services/`, which takes a session and
returns objects — no `Request`, no `Response`, no HTTP.

---

## Deploying

`docs/DEPLOY.md`. Fly.io + Neon + S3, with the exact commands, the IAM policy, and how to
verify. Nothing has been deployed for you.
