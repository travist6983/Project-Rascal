# Deploying RASCAL — the whole thing, in order

**This is the procedure.** Follow it top to bottom and you end with a verified deployment.
`docs/DEPLOY.md` is the reference behind it — why Neon is split into two URLs, how backups
and rollback work, what to do when something specific is broken. When the two disagree,
this file wins.

Written for someone doing this at 11pm. Every step says what to run, what you should see,
and what it means if you see something else. Nothing here requires a laptop except §7.

**Nothing in this repo has ever been deployed.** The steps below have not been executed
end to end by anyone — see §9 for exactly what has and has not been verified, and do not
skip that section.

---

## 0. What you are about to build

One Fly app, `rascal-api`, in `ord`. One always-running machine serving the API, one
scheduled machine waking hourly to assign prompts and expire lapsed ones. A Neon Postgres
behind it and a Tigris bucket beside it.

**The archive does not depend on the scheduler.** `GET /v1/children/{id}/today` fills the
day's empty slots itself, on the child's local date, using the scheduler's own selection
code. A scheduled machine that never fires costs milliseconds on the first read of the day,
not a lost day. So if §5 goes wrong, the product still works — come back to it in the
morning.

---

## 1. Fly — create the app

```bash
fly auth login
fly apps create rascal-api --org personal
```

`rascal-api` is hardcoded in `api/fly.toml`, `.github/workflows/deploy.yml`, and
`.github/workflows/smoke.yml`. If the name is taken, change it in all three.

---

## 2. Neon — the database, and why there are two URLs

Create a project and a database named `rascal`. Neon hands you two connection strings, and
**you need both**:

- The **pooled** one (host contains `-pooler`) is PgBouncer in transaction mode. That is
  what a long-lived FastAPI process wants: the app opens a SQLAlchemy pool and holds
  connections for the life of the machine, and Neon's per-project connection ceiling is the
  scarce resource. This becomes `DATABASE_URL`.
- The **direct** one is what Alembic needs. A migration uses session-level machinery —
  advisory locks, prepared statements, some DDL — that transaction-mode pooling does not
  support. Run migrations through the pooler and they fail in ways that name neither
  pooling nor Alembic. This becomes `DIRECT_DATABASE_URL`.

Rewrite both to SQLAlchemy's scheme and keep `sslmode=require`:

```
postgresql+psycopg://user:password@host/rascal?sslmode=require
```

`api/src/rascal/config.py` prefers `DIRECT_DATABASE_URL` for Alembic and falls back to
`DATABASE_URL` when it is unset — which is correct locally, where there is no pooler, and
wrong in production, where forgetting it means every deploy's release command is a coin
flip.

---

## 3. Tigris — the bucket

```bash
fly storage create        # from inside api/, so it attaches to rascal-api
```

Note the bucket name it generates and the key pair it prints. **The secret is shown once.**

A new access key has no permissions until you grant them:

```bash
fly storage dashboard <bucket-name>    # or:
tigris access-keys assign <key-id> --bucket <bucket-name> --role Editor
```

You do **not** set `S3_REGION` or `S3_ENDPOINT_URL` yourself — they are in `api/fly.toml`
under `[env]`, as `auto` and `https://fly.storage.tigris.dev`. Do not also set them with
`fly secrets set`: when a name is in both places, which one the machine sees depends on
flyctl's version, and that is not a thing to discover at 11pm.

---

## 4. Secrets — every one, and what breaks without it

Set these on the Fly app. Nothing else is required, and no value below belongs in the repo.

```bash
fly secrets set --app rascal-api \
  DATABASE_URL="postgresql+psycopg://…-pooler….neon.tech/rascal?sslmode=require" \
  DIRECT_DATABASE_URL="postgresql+psycopg://….neon.tech/rascal?sslmode=require" \
  JWT_SECRET="$(openssl rand -hex 32)" \
  S3_BUCKET="<the bucket name from §3>" \
  AWS_ACCESS_KEY_ID="tid_…" \
  AWS_SECRET_ACCESS_KEY="tsec_…" \
  APPLE_BUNDLE_ID="com.travisterry.childarchive"
```

| Name | Where it lives | Missing or wrong → |
|---|---|---|
| `DATABASE_URL` | Fly secret | **Deploy fails at the release command.** `alembic upgrade head` has nothing to connect to, so the deploy stops before any machine takes traffic. This is the good failure. |
| `DIRECT_DATABASE_URL` | Fly secret | Deploy *looks* fine, then the release command runs migrations through the transaction-mode pooler and fails on advisory locks or prepared statements, with an error that mentions neither. Missing is survivable on a tiny schema and unsurvivable later. |
| `JWT_SECRET` | Fly secret | Migrations succeed — they only need a connection string — then the app fails to import, machines crash-loop, and the deploy dies at the health check having already migrated. Rotating it later invalidates access tokens in flight; refresh tokens survive, so clients recover on their next refresh. |
| `S3_BUCKET` | Fly secret | App fails to import. Same crash-loop as above. |
| `AWS_ACCESS_KEY_ID` | Fly secret | App fails to import. |
| `AWS_SECRET_ACCESS_KEY` | Fly secret | App fails to import. |
| `APPLE_BUNDLE_ID` | Fly secret | App fails to import. **Wrong** value is worse: the app starts, and Sign in with Apple rejects every identity token on the `aud` claim. |
| `ENVIRONMENT` | `fly.toml` `[env]`, `prod` | If it ever reads `local`, `dev-login` and every `/debug/*` route are live on the public internet and anyone can mint a session against the real archive. §7 checks this explicitly. |
| `S3_REGION` | `fly.toml` `[env]`, `auto` | App fails to import if unset. If set to a real AWS region, the app starts, presigning succeeds, and **every upload 403s** — Tigris rejects the signed scope, and it reads as a credentials problem. |
| `S3_ENDPOINT_URL` | `fly.toml` `[env]`, Tigris | **The quiet one.** Unset means real AWS. Presigning is an offline signature computation, so nothing fails at boot and the health check stays green — the app just hands the phone an `amazonaws.com` URL that 403s. Only §7's storage check catches this. |
| `FLY_API_TOKEN` | GitHub repo secret | The Deploy workflow fails immediately with a message telling you to run `fly tokens create deploy --app rascal-api`. |
| `FLY_DEPLOY_ENABLED` | GitHub repo **variable**, `true` | Not a secret and not optional: while it is unset, a push to `main` **skips** the deploy and renders grey. Manual dispatch always runs. |

Backups need their own credentials (`BACKUP_DATABASE_URL` and an `AWS_*` pair as GitHub
secrets) — that is `docs/DEPLOY.md` §4 and it is not on the path to a running API.

---

## 5. Deploy

```bash
cd api
fly deploy
```

Or, from a phone: GitHub → Actions → **Deploy** → Run workflow.

`api/fly.toml` sets `release_command = "alembic upgrade head"`, so Fly migrates once, before
the new machines take traffic, and a failed migration fails the deploy. The workflow then
asks Fly whether the release actually *succeeded* — Fly can report a green deploy over a
failed release command — and polls `/health` for 90 seconds.

Then seed the prompt library. It is empty on a fresh database, and an empty library assigns
nothing:

```bash
fly ssh console --app rascal-api --command "python -m rascal.jobs.seed"
```

Expect `113 inserted`. It is idempotent; running it twice is free.

### The scheduled machine

Not created by `fly deploy` — Fly has no fly.toml stanza for scheduled machines:

```bash
fly machine run . \
  --app rascal-api \
  --schedule hourly \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --command "python -m rascal.jobs.scheduler"
```

Hourly rather than daily: the job assigns only to children for whom it is currently 5am on
the wall, so every timezone gets its own 5am and DST stops mattering. It is idempotent on
`(child_id, assigned_on, slot)`, so a double fire costs nothing.

**Two things to know about it, both reasons not to lean on it:**

1. Nothing fails if you skip this step. Assignments still appear, created by the read path.
   What you lose is expiry — the `waiting` list grows without bound — which is a slow
   product problem, not data loss.
2. It pins the image it was created from. Later deploys do **not** update it. If you change
   `rascal/jobs/scheduler.py` or anything it imports, destroy and recreate it:
   `fly machine list --app rascal-api`, then `fly machine destroy <id> --force`, then the
   command above again.

---

## 6. Confirm it from a phone

GitHub → Actions → **Smoke** → Run workflow. Read-only, no credentials. It checks `/health`,
that `dev-login` and `/debug/*` are 404, that an anonymous caller gets 401, and that the
OpenAPI document publishes the routes it should.

That is the most you can check without a terminal, and it is worth doing before §7.

---

## 7. Verify it properly

Smoke proves the app is up. This proves it *works*:

```bash
cd api
export DIRECT_DATABASE_URL="postgresql+psycopg://….neon.tech/rascal?sslmode=require"
export JWT_SECRET="<the same value you set in §4>"

uv run python scripts/verify_deployment.py --base-url https://rascal-api.fly.dev
```

Six checks: health, schema at head, dev routes absent, a bearer token round-tripping, **a
brand-new child getting a full Today screen on a database where the scheduler has never
run**, and a real byte-for-byte round trip through Tigris.

It needs the database and the signing key, not just the URL — there is no route that reports
the schema revision, and `dev-login` is deliberately compiled out of a production build, so
a token has to be minted with the deployment's own secret.

It creates a user and a child named `deploy-verify`, then deletes them. Pass `--keep` to
leave them. The one thing it cannot clean up is the object it uploads — it holds presigned
URLs, not storage credentials — so it prints the key and the `aws s3 rm` to remove it.

Exit code 0 means every check passed. Anything else prints which check failed and what that
particular failure usually means.

---

## 8. Then

- Flip `FLY_DEPLOY_ENABLED` to `true` (GitHub → Settings → Secrets and variables → Actions →
  Variables) so merging to `main` deploys by itself.
- `docs/DEPLOY.md` §Rollback, §Backups, and §When something is wrong.

---

## 9. What has actually been verified

Be suspicious of this file in proportion to this section.

**Executed against real infrastructure:**

- The Alembic migrations, from an empty database to head — repeatedly, in the test suite and
  by hand.
- The API image builds and runs, binds `0.0.0.0:8080`, serves `/health` as `{"status":"ok",
  "db":"ok"}`, and returns 404 for `dev-login` under `ENVIRONMENT=prod` (Aug 8, 2026).
- Neon accepts this schema — the *Migrate Neon* workflow ran `upgrade head`, the seed job,
  and `verify_schema.py` against the real database.
- `scripts/verify_deployment.py` checks 1–5, against a real Postgres and a real
  `ENVIRONMENT=prod` uvicorn process, including the brand-new-child Today check.

**Never executed by anyone:**

- `fly apps create`, `fly deploy`, `fly secrets set`, `fly storage create`,
  `fly machine run --schedule hourly`. Every Fly command in this file is written from the
  documentation, not from having run it.
- The Deploy and Smoke workflows have never completed a real run — there is no app to
  deploy to, and GitHub Actions is separately blocked on billing (`docs/blocked.md` §0).
- `scripts/verify_deployment.py` check 6, the Tigris round trip, has only been observed
  **failing correctly**: it catches an unset `S3_ENDPOINT_URL` by rejecting an
  `amazonaws.com` presigned URL, and it reports a refused connection as a clean failure. It
  has never completed a successful upload, because no environment available to the agent
  that wrote it can reach Tigris.

The first `fly deploy` is therefore the first real test of §1–§5. Run §7 immediately after
it, and expect §4's table to be the part that earns its keep.
