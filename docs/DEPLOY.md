# RASCAL — deploying the API

**You never need a laptop to deploy.** GitHub Actions builds and ships; you tap a button.

There is a one-time setup — four accounts to click through and four secrets to paste — and
every step of it is doable in a mobile browser. After that, deploying is: push to `main`, or
open the Actions tab and tap **Run workflow**.

- **`.github/workflows/deploy.yml`** — deploys on push to `main` and on demand. Runs
  migrations through Fly's `release_command`, checks the release actually succeeded, then
  polls `/health` until the app is genuinely serving.
- **`.github/workflows/smoke.yml`** — on demand, read-only. Tap it any time to find out
  whether the deployed API is alive and correctly locked down.

---

## One-time setup

Roughly twenty minutes on a phone. Do the four sections in order; the last one needs values
from the first three.

### 1. Fly — create the app

In a mobile browser at [fly.io](https://fly.io): sign up, add a card (the free allowance
covers this), then **Launch** → **Create app from scratch**. Name it `rascal-api` in region
`ord` (Chicago — closest to Detroit).

Do **not** deploy anything from the Fly UI. The app just needs to exist so the workflow has
somewhere to push.

If `rascal-api` is taken, pick another name and change two lines to match:
`app = "…"` in `api/fly.toml`, and `FLY_APP:` in `.github/workflows/deploy.yml`. Both are
editable in the GitHub mobile app — tap the file, then the pencil.

**Get a deploy token:** Fly dashboard → your app → **Tokens** → **Create deploy token**.
Copy it. It starts with `FlyV1`. This is `FLY_API_TOKEN` in section 4.

### 2. Neon — create the database

At [neon.tech](https://neon.tech): sign up, create a project in **AWS us-east-2 (Ohio)** so
it sits next to the S3 bucket. Name the database `rascal`.

You need **two** connection strings from the dashboard, and they are different on purpose.

**The pooled one** (the hostname contains `-pooler`) — this is what the app serves through:

```
postgresql://rascal_owner:PASSWORD@ep-cool-name-123456-pooler.us-east-2.aws.neon.tech/rascal?sslmode=require
```

**The direct one** (same host, no `-pooler`) — this is what Alembic migrates through:

```
postgresql://rascal_owner:PASSWORD@ep-cool-name-123456.us-east-2.aws.neon.tech/rascal?sslmode=require
```

Then change `postgresql://` to `postgresql+psycopg://` on **both**. This service uses
psycopg 3 and the driver is part of the URL.

Three things that will bite you if you skip them:

- **Keep `?sslmode=require`.** Neon refuses plaintext, and dropping it produces an error
  that reads like a DNS problem.
- **The app needs the pooler.** Fly machines suspend and resume, reconnecting each time, and
  Neon's direct endpoint runs out of connections faster than you would expect.
- **Migrations must *not* go through the pooler.** Neon's pooled endpoint is PgBouncer in
  transaction mode, which does not support the session-level machinery Alembic uses —
  advisory locks, prepared statements, some DDL. A migration run through it fails in a way
  that reads like anything except "wrong endpoint". That is the entire reason there are two
  URLs: `DATABASE_URL` (pooled, the app) and `DIRECT_DATABASE_URL` (direct, Alembic).
  `api/src/rascal/config.py` picks the direct one for Alembic and falls back to
  `DATABASE_URL` when it is unset, which is what happens locally where there is no pooler.

### 3. Object storage — Tigris, not AWS

**Superseded.** Media lives on Tigris, which is S3-compatible and is Fly's object storage. The
AWS bucket, public-access block, and IAM policy this section used to describe do not apply —
Tigris scopes access through the key itself.

Full setup, including the two non-obvious traps, is in **`docs/tigris-setup.md`**. The values
the app needs:

```
S3_BUCKET=<bucket>
S3_REGION=auto                        # Tigris has no AWS-style regions
S3_ENDPOINT_URL=https://fly.storage.tigris.dev   # from inside Fly
                                      # https://t3.storage.dev from a laptop or CI
AWS_ACCESS_KEY_ID=tid_…
AWS_SECRET_ACCESS_KEY=tsec_…
```

`S3_ENDPOINT_URL` unset means real AWS, so an older deployment that never sets it is
unaffected. The `AWS_*` names are the S3 protocol's convention; nothing points at Amazon.

### 4. GitHub — paste the secrets

In the GitHub mobile app or a browser: **Settings** → **Secrets and variables** → **Actions**
→ **New repository secret**. Add these, one at a time.

| Secret | Value |
|---|---|
| `FLY_API_TOKEN` | The `FlyV1…` deploy token from section 1 |
| `AWS_ACCESS_KEY_ID` | From section 3 |
| `AWS_SECRET_ACCESS_KEY` | From section 3 |
| `BACKUP_DATABASE_URL` | Neon's **direct** URL, plain `postgresql://` — see the note below |

`BACKUP_DATABASE_URL` is only used by the nightly backup workflow, which runs `pg_dump`
rather than SQLAlchemy — so it takes a plain `postgresql://…` URL with **no** `+psycopg`.
Use the direct endpoint: `pg_dump` holds one long session and has nothing to gain from a
pooler.

Then, on the **Variables** tab of the same screen — *not* Secrets — add one more:

| Variable | Value |
|---|---|
| `FLY_DEPLOY_ENABLED` | `true` |

This is the switch that turns on automatic deploys from `main`. Until it is set, the deploy
workflow skips instead of running, so a push to `main` does not fail for the entirely
correct reason that there is no Fly app yet — a red X that means "not set up" trains you to
ignore red Xs. Setting it says the app exists. If it is on and `FLY_API_TOKEN` is missing,
the workflow fails loudly, which by then is the truth.

### 5. Fly — paste the app's own secrets

The app's runtime configuration lives in Fly, not GitHub. Fly's dashboard has a **Secrets**
section per app where you can add these from a phone:

| Secret | Value |
|---|---|
| `DATABASE_URL` | Neon **pooled**, `postgresql+psycopg://…?sslmode=require` |
| `DIRECT_DATABASE_URL` | Neon **direct**, `postgresql+psycopg://…?sslmode=require` |
| `JWT_SECRET` | 32+ random bytes — see below |
| `S3_BUCKET` | `rascal-media-prod` |
| `S3_REGION` | `us-east-2` |
| `AWS_ACCESS_KEY_ID` | From section 3 |
| `AWS_SECRET_ACCESS_KEY` | From section 3 |
| `APPLE_BUNDLE_ID` | Your bundle id, e.g. `com.yourname.rascal` |

`ENVIRONMENT=prod` is already in `api/fly.toml` under `[env]`. It is not sensitive, and
having it visible there is what makes "dev-login cannot exist in production" auditable at a
glance.

For `JWT_SECRET` on a phone, any 64-character hex string works. If you have a terminal:
`openssl rand -hex 32`. Rotating it later invalidates every access token in flight; refresh
tokens survive, so clients recover on their next refresh — but do it deliberately.

If you do have a terminal, all of section 5 is one command:

```bash
fly secrets set --app rascal-api \
  DATABASE_URL="postgresql+psycopg://…-pooler….neon.tech/rascal?sslmode=require" \
  DIRECT_DATABASE_URL="postgresql+psycopg://….neon.tech/rascal?sslmode=require" \
  JWT_SECRET="$(openssl rand -hex 32)" \
  S3_BUCKET="rascal-media-prod" \
  S3_REGION="us-east-2" \
  AWS_ACCESS_KEY_ID="AKIA…" \
  AWS_SECRET_ACCESS_KEY="…" \
  APPLE_BUNDLE_ID="com.yourname.rascal"
```

---

## Deploying

**From a phone:** GitHub app → **Actions** → **Deploy** → **Run workflow** → pick the branch
→ **Run**. Or merge anything to `main` and it fires by itself.

The workflow:

1. Builds the image on Fly's remote builder — your phone uploads nothing.
2. `flyctl deploy` runs `alembic upgrade head` as the release command **before** new machines
   take traffic. A failed migration fails the deploy rather than putting a running app in
   front of the wrong schema.
3. Asks Fly whether the latest release's status is actually `succeeded`. Fly can report a
   successful deploy while the release command errored; this step catches that and dumps the
   last 80 log lines.
4. Polls `/health` for up to 90 seconds, requiring exactly `{"status":"ok","db":"ok"}`.
   `/health` touches the database, so green means the app is genuinely serving.

If any step fails the workflow goes red with a message naming the likely cause.

### First deploy: two things afterwards

**Seed the mission library.** The prompts table is empty on a fresh database, and the
scheduler with an empty library assigns nothing:

```bash
fly ssh console --app rascal-api --command "python -m rascal.jobs.seed"
```

This one does need a terminal. It is safe to run repeatedly — the loader is keyed on a hash
of `(kind, cadence, body)`, so it updates and inserts but never duplicates and never deletes.

**Create the scheduler machine.** `fly.toml` has no stanza for a scheduled machine, so it is
created once with the CLI and is then not managed by `fly deploy`:

```bash
fly machine run . \
  --app rascal-api \
  --schedule hourly \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --command "python -m rascal.jobs.scheduler"
```

**Hourly, not daily.** A single daily cron fires at one fixed UTC hour — 5am in exactly one
timezone, evening in half the world, and an hour adrift after every DST change. Instead the
job fires every hour and does work only for the children for whom it is currently 5am on the
wall. Twenty-three of the twenty-four firings find nobody, log that, and exit.

After a deploy that changes scheduler behaviour, the scheduled machine is still on the old
image. Destroy and recreate it:

```bash
fly machine list --app rascal-api
fly machine destroy --app rascal-api --force <machine-id>
# then re-run the `fly machine run` command above
```

Run the scheduler by hand any time:

```bash
# Only children for whom it is currently 5am — what the hourly machine does.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler"
# Every child, right now, whatever their local time.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler --any-hour"
# A specific day — a backfill, or a morning you slept through.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler --date 2026-08-14"
```

---

## Checking it from your phone

GitHub app → **Actions** → **Smoke** → **Run workflow**. It takes about fifteen seconds and
asserts:

- `/health` returns `{"status":"ok","db":"ok"}` — serving, and reaching Neon.
- `POST /v1/auth/dev-login` returns **404** — the fixture login does not exist in production.
- `POST /v1/debug/scheduler/run` returns **404** — nor do the debug routes.
- `GET /v1/children` returns **401** — auth is enforced.
- `/openapi.json` publishes the contract.

It creates nothing and needs no credentials, so it is safe to run as often as you like.

---

## Backups

`.github/workflows/backup.yml` runs nightly at 08:10 UTC and on demand. It `pg_dump`s Neon,
gzips, and uploads to `s3://rascal-media-prod/backups/` with a timestamped key, then prunes
to **7 daily, 4 weekly, 12 monthly**. It fails loudly — a silent backup failure is worse than
no backup — and it lives in GitHub Actions rather than on a Fly machine deliberately, so it
still runs on a day when Fly is the thing that is broken.

Restoring is `api/scripts/restore.py`, and CI performs a real dump-drop-restore round trip on
every push (`tests/test_restore.py`), so "a restore you have actually performed" is true
continuously rather than once.

To restore for real:

```bash
aws s3 cp s3://rascal-media-prod/backups/2026/08/rascal-20260804T081000Z.sql.gz .
cd api && uv run python scripts/restore.py --from rascal-20260804T081000Z.sql.gz --url "$DIRECT_DATABASE_URL"
```

It refuses to run against a non-empty database without `--force`, so a mistyped URL cannot
quietly overwrite production.

Neon also keeps its own point-in-time restore; check the retention window on your plan and
raise it if the default is shorter than you would want after a bad migration.

---

## Rollback

```bash
fly releases --app rascal-api
fly deploy --image registry.fly.io/rascal-api:deployment-<previous-id>
```

**Migrations do not roll back with the image.** Every migration here is reversible, but a
downgrade on a database with real entries in it destroys them. Roll the image back, then
decide about the schema separately and deliberately.

---

## When something is wrong

```bash
fly logs --app rascal-api        # JSON, one object per line — pipe through jq
fly status --app rascal-api
```

| Symptom | Almost always |
|---|---|
| Deploy red at "Verify the release command succeeded" | `alembic upgrade head` failed — read the dumped logs |
| Deploy red at "Wait for the app to serve" | `DATABASE_URL` wrong, or missing `?sslmode=require` |
| Migration errors mentioning prepared statements or locks | `DIRECT_DATABASE_URL` is pointing at the **pooled** endpoint |
| Smoke says dev-login answered 200 | `ENVIRONMENT` is not `prod` |
| Multipart upload never completes | The bucket's CORS rule is not exposing `ETag` |
| `/today` is empty for every child | The library was never seeded, or the scheduler machine was never created |
