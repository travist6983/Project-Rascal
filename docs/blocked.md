# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: **Aug 4, 2026**, after the hardening pass.

---

## 1. Apple Developer enrollment — blocks real Sign in with Apple

`POST /v1/auth/apple` is fully implemented and tested: it fetches and caches Apple's JWKS,
verifies the signature, and checks `iss`, `aud` against `APPLE_BUNDLE_ID`, and `exp`. The
tests generate a local RSA keypair and stub the JWKS fetch, so the verification logic is
exercised — including a token signed by the wrong key under the right `kid`, which is the
case that catches decorative verification.

What it cannot do is accept a token from a real device, because `aud` has to match a bundle
id from an enrolled team.

**What I need:** the bundle id, once enrollment clears. Nothing else changes:

```bash
fly secrets set --app rascal-api APPLE_BUNDLE_ID="com.yourname.rascal"
```

**Meanwhile:** `POST /v1/auth/dev-login` returns a real session with real tokens against a
fixture account, and it works for curl and for the iOS client. It is registered only when
`ENVIRONMENT == "local"`, and there is a test that builds a production app and asserts the
route does not exist.

## 2. AWS credentials — blocks a real upload round-trip

Presigning, multipart planning, and completion are implemented and tested against `moto`, so
the request and response shapes are right and the multipart flow works. Nothing has been
uploaded to a real bucket, because there is no bucket and no credential.

**What I need:** run section 2 of `docs/DEPLOY.md` — bucket, public-access block, versioning,
encryption, CORS, lifecycle rule, IAM user, access key — then set the four S3 secrets. The
IAM policy JSON is in that document, ready to paste.

Two things worth checking by hand afterwards, because `moto` cannot prove either:

- A real presigned PUT from a real device.
- A real multipart upload of a video over cellular. **The CORS rule must expose `ETag`** or
  completion fails in a way that reads like a signature error. The response now carries
  `chunk_bytes`, so the uploader splits at exactly the size the part count was computed from
  — do not hard-code 8MB on the Swift side, read the field.

## 3. Fly and Neon accounts — blocks deployment, and blocks verifying the build

Every artifact exists: multi-stage `Dockerfile`, `fly.toml` with `release_command =
"alembic upgrade head"` and a `/health` check, and a full runbook in `docs/DEPLOY.md`.

**Two sessions in a row, no Docker daemon was available in my environment.** So:

| Path | Status |
|---|---|
| `api/Dockerfile` builds | **never executed** |
| `docker-compose.yml` starts Postgres | **never executed** |
| `.github/workflows/ci.yml` passes | **never executed** |

The uv pin in the `Dockerfile` was `0.5.11`, which cannot read the `revision = 3` format of
the committed `uv.lock` — `uv sync --frozen` would have rejected it outright on the first
build. That is now `0.8.17`, the version that wrote the lock. It is a reasoned fix, not a
verified one, and it is the most likely thing still standing between you and a green
`fly deploy`.

**What I need:** run `docker compose up -d --wait postgres` and `docker build -f
api/Dockerfile api/` once on your machine, or just push and let GitHub Actions be the first
real execution of the CI workflow. Either tells us in a minute.

---

## Deferred by decision — not blocked, and not waiting on you

These were left out on purpose. Each is a small piece of work if you decide otherwise.

- **`POST /prompts/batch-review`.** It accepts or rejects candidates sitting in a review
  queue, and the admin prompt review queue is explicitly out of scope. `GET /prompts` and
  `POST /prompts` are built, and `POST /prompts` writes `source = "user"` — so `source =
  "llm"` plus `active = false` is a review queue the moment you want one. Now that
  `users.is_admin` exists, the authorization half is already done.
- **`POST /children/{id}/guardians`.** P2 in the contract, and the guardian invite flow is
  out of scope. The `guardians` table, both roles, and the whole authorization path are
  built and tested — a viewer reads and cannot write, and a revoked guardian is refused
  everywhere. Only the invite mechanism is missing.
- **Thumbnails and poster frames.** `POST /media/{id}/complete` marks the row and leaves
  `thumb_key` null. The column exists and clients already handle it being null, so the
  pipeline slots in later with no schema or contract change.
- **The `ORDER BY random()` scan in the moments fallback.** Fine at 100 entries, worth
  revisiting at P1.

---

## Resolved since the last review

Everything below was on this list on Aug 3 and is now closed.

- The `monthly` slot serving letters alongside measurements — letters have their own slot on
  the 15th.
- The coverage table in `mission-library.md` under-counting four kinds — corrected, and the
  test now asserts the corrected figures exactly.
- `POST /prompts` being open to any authenticated user — behind `require_admin`.
- Deleting an entry stranding its assignment — released back to `pending`.
- `entry_type` describing the prompt rather than the artifact — derived from what the entry
  contains.
- The multipart response not telling the client the chunk size — `chunk_bytes` is in it.
- The sync cursor's lost-update race — a 30-second overlap window, documented in the contract.
- Stale `updated_at` in media write responses — refreshed after the trigger fires.
- A single daily scheduler cron that could only be 5am in one timezone — hourly, filtered on
  each child's local hour.
