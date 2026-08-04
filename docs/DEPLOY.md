# RASCAL — deploying the API

The exact sequence to get this running on Fly.io with Neon and S3. Nothing here has been
run for you — these are commands for you, with your credentials.

Everything below runs from `api/` unless it says otherwise.

---

## 0. What you need first

| Thing | Where | Why |
|---|---|---|
| Fly.io account + `flyctl` | `brew install flyctl && fly auth login` | Hosting |
| Neon account | neon.tech | Postgres |
| AWS account | console.aws.amazon.com | S3 for media |
| Apple bundle id | Your Xcode project | Verifying identity tokens |

Apple Developer enrollment is **not** required to deploy. It is required before
`POST /v1/auth/apple` can accept a real token — until then, run locally and use
`dev-login`. See `docs/blocked.md`.

---

## 1. Neon

Create a project (region `us-east-2` / Ohio, to sit next to the S3 bucket), then copy the
**pooled** connection string from the Neon dashboard.

Neon hands you a `postgresql://` URL. This service uses psycopg 3, so change the scheme:

```
# Neon gives you:
postgresql://rascal_owner:AbC123@ep-cool-name-123456-pooler.us-east-2.aws.neon.tech/rascal?sslmode=require

# Use:
postgresql+psycopg://rascal_owner:AbC123@ep-cool-name-123456-pooler.us-east-2.aws.neon.tech/rascal?sslmode=require
```

Two things that matter:

- **Use the pooler endpoint** (`-pooler` in the hostname). Fly machines reconnect on every
  suspend/resume cycle and Neon's direct endpoint runs out of connections faster than you
  would expect.
- **Keep `?sslmode=require`.** Neon refuses plaintext, and dropping it produces a connection
  error that reads like a DNS problem.

`api/src/rascal/db.py` sets `pool_recycle=1800`, well inside Neon's idle timeout, so a
suspended machine does not wake up holding a dead connection.

---

## 2. S3

### Create the bucket

```bash
aws s3api create-bucket \
  --bucket rascal-media-prod \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2

# Nothing in this bucket is ever public. Presigned URLs are the only way in or out.
aws s3api put-public-access-block \
  --bucket rascal-media-prod \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Versioning, so a bad client delete is recoverable. This archive is the product.
aws s3api put-bucket-versioning \
  --bucket rascal-media-prod \
  --versioning-configuration Status=Enabled

# Server-side encryption at rest.
aws s3api put-bucket-encryption \
  --bucket rascal-media-prod \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

### CORS

The phone uploads directly to S3, and a browser client will too. Without this, the presigned
PUT fails in a way that looks like a signature problem.

```bash
cat > /tmp/rascal-cors.json <<'JSON'
{
  "CORSRules": [
    {
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["PUT", "GET", "HEAD"],
      "AllowedOrigins": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }
  ]
}
JSON
aws s3api put-bucket-cors --bucket rascal-media-prod --cors-configuration file:///tmp/rascal-cors.json
```

`ExposeHeaders: ["ETag"]` is not optional — a multipart upload cannot complete without the
client reading the ETag off each part response.

Narrow `AllowedOrigins` to your web origin when there is one. A native `URLSession` upload
is not subject to CORS at all, so this rule exists entirely for the browser client in 2027.

### Abort incomplete multipart uploads

A backgrounded video upload that never finishes leaves parts you pay for.

```bash
cat > /tmp/rascal-lifecycle.json <<'JSON'
{
  "Rules": [
    {
      "ID": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }
  ]
}
JSON
aws s3api put-bucket-lifecycle-configuration \
  --bucket rascal-media-prod \
  --lifecycle-configuration file:///tmp/rascal-lifecycle.json
```

### IAM user and policy

```bash
aws iam create-user --user-name rascal-api
```

Save this as `rascal-s3-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::rascal-media-prod/*"
    },
    {
      "Sid": "BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::rascal-media-prod"
    }
  ]
}
```

No `s3:DeleteObject`. Nothing in this service deletes an object — deletes are soft, in
Postgres — so the credential should not be able to either.

```bash
aws iam put-user-policy \
  --user-name rascal-api \
  --policy-name rascal-s3 \
  --policy-document file://rascal-s3-policy.json

aws iam create-access-key --user-name rascal-api
```

Copy `AccessKeyId` and `SecretAccessKey` from that last output. The secret is shown once.

---

## 3. Fly

### Launch

```bash
cd api

# Creates the app and writes nothing over the committed fly.toml.
fly launch --no-deploy --copy-config --name rascal-api --region ord
```

If `rascal-api` is taken, pick another name and change `app = ` in `api/fly.toml` to match.

### Secrets

One command, every required key. Substitute your real values — everything below is a
placeholder.

```bash
fly secrets set --app rascal-api \
  DATABASE_URL="postgresql+psycopg://rascal_owner:PASSWORD@ep-YOUR-ENDPOINT-pooler.us-east-2.aws.neon.tech/rascal?sslmode=require" \
  JWT_SECRET="$(openssl rand -hex 32)" \
  S3_BUCKET="rascal-media-prod" \
  S3_REGION="us-east-2" \
  AWS_ACCESS_KEY_ID="AKIAXXXXXXXXXXXXXXXX" \
  AWS_SECRET_ACCESS_KEY="YOUR_SECRET_ACCESS_KEY" \
  APPLE_BUNDLE_ID="com.yourname.rascal"
```

`ENVIRONMENT=prod` is already in `fly.toml` under `[env]` — it does not need to be a secret,
and it is what keeps `dev-login` and every `/v1/debug/*` route out of the build.

Rotating `JWT_SECRET` invalidates every access token in flight. Refresh tokens survive it,
so clients recover on their next refresh — but do it deliberately, not casually.

### Deploy

```bash
fly deploy
```

`release_command = "alembic upgrade head"` runs before the new machines take traffic. A
failed migration fails the deploy rather than putting a running app in front of the wrong
schema.

### Seed the mission library

The prompts table is empty on a fresh database.

```bash
fly ssh console --app rascal-api --command "python -m rascal.jobs.seed"
```

Safe to run as often as you like: the loader is keyed on a hash of `(kind, cadence, body)`,
so it updates and inserts but never duplicates and never deletes.

### The scheduler

`fly.toml` has no stanza for a scheduled machine, so it is created once with the CLI and is
then not managed by `fly deploy`:

```bash
fly machine run . \
  --app rascal-api \
  --schedule hourly \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --command "python -m rascal.jobs.scheduler"
```

**Hourly, not daily.** A single daily cron fires at one fixed UTC hour. That hour is 5am in
exactly one timezone, it is the middle of the evening in half the world, and it drifts by an
hour against your own DST twice a year. Instead the job fires every hour and does work only
for the children for whom it is currently 5am on the wall — so every timezone gets its own
5am, correctly, forever, with no configuration.

That costs 24 tiny wakeups a day, which is nothing. Twenty-three of them find no child at
5am, log that, and exit. The run is idempotent on `(child_id, assigned_on, slot)`, so a
double-fire or a retry costs nothing either.

**After a `fly deploy` that changes scheduler behaviour**, the scheduled machine is still on
the old image. Destroy and recreate it:

```bash
fly machine list --app rascal-api          # find the scheduled machine's id
fly machine destroy --app rascal-api --force <machine-id>
# then re-run the `fly machine run` command above
```

Run it by hand any time:

```bash
# Only children for whom it is currently 5am — exactly what the hourly machine does.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler"

# Every child, right now, whatever their local time.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler --any-hour"

# A specific calendar day for every child — a backfill, or a morning you slept through.
fly ssh console --app rascal-api --command "python -m rascal.jobs.scheduler --date 2026-08-14"
```

---

## 4. Verify

```bash
# 1. The app is up and can reach the database.
curl -s https://rascal-api.fly.dev/health
# {"status":"ok","db":"ok"}

# 2. The migration ran.
fly ssh console --app rascal-api --command "alembic current"
# 0001_initial (head)

# 3. The library is seeded. Re-running the loader is free and prints the count.
fly ssh console --app rascal-api --command "python -m rascal.jobs.seed"
# prompts: 0 inserted, 0 updated, 113 unchanged (113 in the library)

# 4. The production build has no dev routes. Both must be 404.
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://rascal-api.fly.dev/v1/auth/dev-login
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://rascal-api.fly.dev/v1/debug/scheduler/run

# 5. The OpenAPI document covers every endpoint.
curl -s https://rascal-api.fly.dev/openapi.json | python3 -c \
  "import json,sys; print('\n'.join(sorted(json.load(sys.stdin)['paths'])))"

# 6. Auth is enforced.
curl -s -o /dev/null -w '%{http_code}\n' https://rascal-api.fly.dev/v1/children
# 401
```

Once you have a real Apple token and a session, `GET /v1/prompts` reports the same figure as
`total`.

Logs, if any of that goes sideways:

```bash
fly logs --app rascal-api
fly status --app rascal-api
```

The logs are JSON, one object per line — pipe them through `jq` and filter on `logger`.

---

## 5. Backups

Neon keeps point-in-time restore on its own schedule; check the retention window on your
plan and raise it if the default is shorter than you would want after a bad migration.

S3 versioning is already on from step 2, so an overwritten object is recoverable.

`docs/memory-app-roadmap.md` puts "backups you actually trust" in P1, including a restore
you have actually performed. Do that before there are sixty days of entries in here, not
after.

---

## 6. Rollback

```bash
fly releases --app rascal-api
fly deploy --image registry.fly.io/rascal-api:deployment-<previous-id>
```

**Migrations do not roll back with the image.** `0001_initial` is reversible
(`alembic downgrade base` drops everything cleanly), but a downgrade on a database with real
entries in it destroys them. Roll the image back, then decide about the schema separately
and deliberately.
