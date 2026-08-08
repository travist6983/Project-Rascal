# Tigris for media storage — setup

**Short answer: yes, Tigris works, and it's a better fit than AWS here.** It's S3-compatible,
it's Fly's native object storage, and RASCAL already deploys to Fly. It replaces section 3 of
`docs/DEPLOY.md` (the AWS bucket) — not the whole document.

**One blocker first.** The API cannot talk to Tigris today. `api/src/rascal/services/s3.py`
builds its boto3 client with no `endpoint_url`, so every request goes to AWS regardless of what
the credentials say. That's a small API-lane change, spelled out in step 1 below. Everything
after it is configuration.

Links:

- Tigris docs — https://www.tigrisdata.com/docs/
- Fly's Tigris guide — https://fly.io/docs/tigris/
- boto3 / Python SDK notes — https://www.tigrisdata.com/docs/sdks/s3/aws-python-sdk/
- CORS — https://www.tigrisdata.com/docs/buckets/cors/
- Console — https://console.storage.dev/

---

## Step 1 — The code change (needed before anything else works)

Three places build an S3 client, and all three assume AWS.

**a. `api/src/rascal/config.py`** — add one optional setting beside the existing S3 block:

```python
    # Any S3-compatible endpoint. Unset means real AWS, which keeps existing deploys working.
    s3_endpoint_url: str | None = None
```

**b. `api/src/rascal/services/s3.py`** — pass it through:

```python
    return boto3.client(
        "s3",
        region_name=settings.s3_region,
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
        endpoint_url=settings.s3_endpoint_url,   # None → AWS, as before
        config=Config(signature_version="s3v4", retries={"max_attempts": 3}),
    )
```

`endpoint_url=None` is exactly the current behaviour, so this is additive — nothing breaks if
you never set the variable. Presigning keeps working: boto3 signs against whatever endpoint the
client was built with, so presigned PUTs come out pointing at Tigris.

**c. The backup path**, if you want backups on Tigris too:

- `.github/workflows/backup.yml` uses `aws s3 cp`, which needs `--endpoint-url "$AWS_ENDPOINT_URL_S3"`
- `.github/scripts/prune_backups.py` calls `boto3.client("s3")` with no endpoint

These are independent of media uploads. You can leave backups on AWS and put only media on
Tigris, or move both — but don't leave `prune_backups.py` pointed at a bucket that no longer
receives backups, or it will prune nothing and report success.

**I have not made this change.** It's under `api/`, which the iOS lane doesn't edit, and lane
rules aside it's your call whether media and backups move together. Say the word and I'll do it
as an API-lane change with tests.

---

## Step 2 — Create the bucket and credentials

Two routes. Both give you the same thing.

### Route A — Fly CLI (simplest, since the app will live on Fly)

```bash
fly storage create
```

Run it from the repo root. In an app context it provisions a bucket and sets these secrets on
the Fly app automatically:

```
BUCKET_NAME
AWS_ENDPOINT_URL_S3     https://fly.storage.tigris.dev
AWS_ACCESS_KEY_ID       tid_…
AWS_SECRET_ACCESS_KEY   tsec_…
```

**Copy the access key and secret out of that output immediately.** `flyctl` cannot retrieve
them again, and `fly secrets list` only shows hashes. You need them locally in `.env` and in
GitHub Actions, neither of which can read Fly's secrets.

Note the Fly app doesn't exist yet — `docs/blocked.md` §3 still lists that as outstanding. If
you'd rather not create the app first, use Route B.

### Route B — Tigris console (works with no Fly app)

Sign in at https://console.storage.dev/, create a bucket, then create an access key scoped to
it. Same credential format.

Either way, later key management is at `fly storage dashboard <bucket-name>` or the console.

### Naming

`.env.example` currently says `rascal-media-dev`, and `backup.yml` defaults to
`rascal-media-prod`. Tigris bucket names are globally unique, so those plain names may be
taken — `fly storage create` generates a unique one for you. Whatever you get, use it verbatim;
don't assume the old names.

---

## Step 3 — What goes in the env files

### Local — repo root `.env`

Replace the four placeholder lines (currently `local-dev-access-key` etc.) with:

```bash
S3_BUCKET=<your-bucket-name>
S3_REGION=auto
S3_ENDPOINT_URL=https://t3.storage.dev
AWS_ACCESS_KEY_ID=tid_…
AWS_SECRET_ACCESS_KEY=tsec_…
```

Two of those deserve explanation:

- **`S3_REGION=auto`.** Tigris is globally distributed and has no regions in the AWS sense.
  `auto` is what its docs specify. Leaving `us-east-2` there is the single most likely way to
  get a signature error that reads like a credentials problem.
- **`S3_ENDPOINT_URL`.** Use `https://t3.storage.dev` from your Mac and from GitHub Actions —
  it's the canonical endpoint for anything outside Fly. Use `https://fly.storage.tigris.dev`
  from inside a Fly app. Both reach the same buckets; the Fly one is faster from Fly's network.

`.env.example` should get the same keys with placeholder values, so the shape is documented.

### Fly app secrets (when the app exists)

```bash
fly secrets set --app rascal-api \
  S3_BUCKET="<bucket>" \
  S3_REGION="auto" \
  S3_ENDPOINT_URL="https://fly.storage.tigris.dev" \
  AWS_ACCESS_KEY_ID="tid_…" \
  AWS_SECRET_ACCESS_KEY="tsec_…"
```

`fly storage create` already sets `AWS_ENDPOINT_URL_S3`, but the app reads `S3_ENDPOINT_URL`
(the name in step 1), so set that explicitly rather than relying on Fly's variable name.

### GitHub Actions — only if backups move to Tigris

Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | `tid_…` |
| Secret | `AWS_SECRET_ACCESS_KEY` | `tsec_…` |
| Variable | `S3_BUCKET` | your bucket |
| Variable | `S3_ENDPOINT_URL` | `https://t3.storage.dev` |

---

## Step 4 — CORS, and why it matters less than you'd think

`docs/blocked.md` §2 warns that the CORS rule must expose `ETag` or completion fails looking
like a signature error. That's true — **for a browser**. It is not true for the iOS app.

CORS is enforced by browsers, not by HTTP clients. `URLSession` reads the `ETag` response
header off a presigned PUT regardless of any CORS configuration, so the Phase 2 uploader is
unaffected either way.

Set it anyway, for the web client the architecture reserves for 2027:

```bash
aws s3api put-bucket-cors --bucket <bucket> \
  --endpoint-url https://t3.storage.dev \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedOrigins": ["*"],
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["PUT", "POST", "GET", "HEAD"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }]
  }'
```

**One caveat I could not verify:** Tigris's CORS documentation covers origins, methods, and
headers but does not mention `ExposeHeaders`. It's standard S3, so it should be accepted — but
read it back with `get-bucket-cors` and confirm the field survived rather than assuming it did.
Tighten `AllowedOrigins` from `*` when a real web origin exists.

---

## Step 5 — Verify, before writing any client code

These are the exact commands the Phase 2 preflight runs. Run them and you'll know it works
rather than hoping.

```bash
# 1. Bucket reachable and credentials valid
aws s3 ls "s3://<bucket>" --endpoint-url https://t3.storage.dev

# 2. Round trip through the API's own presigner
TOKEN=$(curl -s -X POST localhost:8000/v1/auth/dev-login \
  -H 'content-type: application/json' -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

# …create an entry, then:
curl -s -X POST localhost:8000/v1/media/upload-url \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"entry_id":"<entry>","kind":"photo","filename":"probe.jpg","bytes":2048,"content_type":"image/jpeg"}'
```

Three things to check in that response:

1. `upload_url` host is `…t3.storage.dev` or `…fly.storage.tigris.dev`, **not** `amazonaws.com`.
   If it still says AWS, step 1's code change isn't in effect.
2. `curl -X PUT --upload-file` against that URL returns **200 with an `ETag` response header**.
3. `POST /v1/media/{id}/complete` with that ETag returns 200.

That third one is the real finish line. Right now the failure is unambiguous and earlier than
any of this: the bucket doesn't exist at all —

```
GET https://rascal-media-dev.s3.amazonaws.com/?location
  → <Code>NoSuchBucket</Code>
```

---

## Two things worth knowing before you commit to this

**Addressing style.** boto3 with a custom `endpoint_url` may default to path-style
(`endpoint/bucket/key`) rather than virtual-host (`bucket.endpoint/key`). Tigris supports both,
so this normally doesn't matter — but if presigned URLs come back 404ing on a bucket you know
exists, that's the first thing to try:

```python
config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}, ...)
```

**Multipart.** Phase 2 deliberately excludes video and therefore multipart. Tigris supports the
multipart API, but the multipart phase should re-verify it directly rather than assume parity —
`chunk_bytes` came back `null` on the single-PUT path, and the part-size contract is the one
place where a difference between S3 implementations would be expensive to discover late.

---

## What this changes in the existing docs

- `docs/DEPLOY.md` §3 ("AWS — create the media bucket") is superseded for media. Its IAM policy
  and public-access-block steps are AWS-specific and don't apply; Tigris scopes access through
  the key itself.
- `docs/blocked.md` §2 ("AWS credentials") becomes "object storage", and the remedy becomes this
  document.
- `.env.example` gains `S3_ENDPOINT_URL` and `S3_REGION=auto`.

I'll make those edits once you've decided, so the docs don't describe two different storage
providers at the same time.
