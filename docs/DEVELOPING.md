# Developing Pocket Chronicle

The developer guide for this repository. The project overview is in the [README](../README.md).

`RASCAL` is the repository and package name; the product is **Pocket Chronicle**. The backend
lives in `api/` and the SwiftUI client in `ios/`. They are separate **lanes**: CI is
path-scoped, and `ios/CLAUDE.md` carries the iOS lane's rules.

- **Specs live in `docs/` and are authoritative.** `data-model.md` is the schema,
  `api-contract.md` is the endpoints, `decisions.md` is settled, `mission-library.md` is the
  seed content, `memory-app-roadmap.md` is the scope.
- **Standing rules for anyone working here, human or agent, are in `CLAUDE.md`.**
- Judgment calls made while building are in `docs/decisions-log.md`, and open items are in
  `docs/blocked.md`.

**Python 3.12 · FastAPI · SQLAlchemy 2.0 · Alembic · Postgres 16 · S3 · uv · Fly.io**

---

## Run it locally

Five commands from a clean clone. You need [`uv`](https://docs.astral.sh/uv/) and Docker.

```bash
cp .env.example .env    # safe local defaults, no real credentials anywhere
make up                 # Postgres 16 on localhost:5433, waits until healthy
make migrate            # alembic upgrade head
make seed               # the prompt library from api/seeds/prompts.yaml
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

### …or from the admin console

`make dev`, then <http://localhost:8000/admin> → **Sign in with dev-login**. The Library tab edits
bodies with a live three-column pronoun preview and refuses a token no client can render.

**The markdown is still the tidier path when you have the repo open**, and the console says so on
every seeded prompt it opens. Editing a *seeded* body there cannot be a plain update: `make seed`
runs on every deploy and reconciles the table against `prompts.yaml`, so the console **forks** it
instead — a new `source: "user"` prompt carries the new words and the original is retired through
`prompt_library_overrides`, the one table the re-seed reads rather than overwrites. `Hand back to
the seed file` undoes that and returns the prompt to whatever the markdown says.

---

## The admin console

<http://localhost:8000/admin>. Requires `users.is_admin`; `dev-login`'s fixture user has it.

| Tab | What it answers |
|---|---|
| Today | Households, kids, entries per day, completion rate, bytes stored, newest accounts |
| Library | Every prompt with served/completed counts, filters, and the editor |
| Studio | Art direction, post concepts, brand cards, shot lists — see below |
| Costs | Anthropic, Fly, Neon, Tigris and Resend — see `.env.example` for the four optional keys |
| Ops | Did the scheduler run, which switches are on, the job ledgers and the deletion queue |

Three static files under `api/src/rascal/admin/static/`, no build step and no dependency. It holds
no credential — it asks the same API the app does, with a bearer token in `localStorage`.

**It returns counts and never archive content.** No entry body, caption, transcript, child name or
object key is reachable through any admin route, and a test asserts it.

**The Ops tab reads what the scheduler produced**, not whether its deploy was green — the check PR
#57 did not have. A daily slot that served nothing across the window is flagged in red.

### The Studio

Set `ANTHROPIC_API_KEY` (an ordinary `sk-ant-api…` key — *not* the `sk-ant-admin…` one the cost
panel uses) and the Studio tab will:

- **talk to an art director** who knows the product, the voice and the rules,
- **write post concepts** — angle, headline, caption, alt text, hashtags and an image brief,
- **draw the card** on a canvas in the Pocket Chronicle palette and export it as a **PNG** at any platform
  size, or as a **WebM** of the card settling in,
- **write a shot list** for a short vertical video, with a WebVTT caption track.

**Claude does not generate images or video** — there is no such endpoint on any Anthropic model.
The cards are drawn locally by `admin/static/cards.js`, which is why they need no vendor, cost
nothing per image, and cannot drift off-brand. For photographs, set `OPENAI_API_KEY` or
`REPLICATE_API_TOKEN` and Claude's image brief goes to whichever is configured.

**Nothing posts anything.** Generate, look at it, download the file, put it out yourself.

**Featuring a mission-library prompt is capped.** D7 keeps the library out of anything public,
so Claude never sees it, the body is read server-side from a prompt id you pick, and the Studio
counts how much of the library has been shown against `SOCIAL_FEATURED_PROMPT_CAP`.

---

## Layout

```
CLAUDE.md                  standing rules, for a future session
Makefile                   the whole local loop
docker-compose.yml         Postgres 16 on 5433
.env.example               every key, with safe local defaults
.github/workflows/ci.yml   lint + tests against a Postgres service container
docs/                      the specs, plus decisions-log.md, blocked.md, runbook-deploy.md
ios/                       the SwiftUI client: app, widget, share extension, tests; its own CLAUDE.md
api/
  pyproject.toml           deps, ruff, pytest
  Dockerfile               multi-stage, non-root
  fly.toml                 release_command runs migrations
  alembic/versions/        0001_initial — the whole schema, reversible
  seeds/prompts.yaml       generated; what the loader reads
  scripts/                 the markdown-to-YAML converter (never runs at request time)
  src/rascal/
    main.py                the app factory; all routes mount under /v1 except /health*
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

The API ran on Fly.io (app `rascal-api`) with Neon Postgres and S3-compatible object storage until
the app was retired.
`docs/runbook-deploy.md` is the runbook and `docs/Infastructure/DEPLOY.md` is the reference behind
it: the exact commands, the IAM policy, and how to verify a deploy.
