# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: **Aug 8, 2026**, after the first run on a machine with a Docker daemon.

---

## iOS Settings — one gap, and one note about the preflight

Neither blocks the Lane B Settings work, which shipped complete. Recorded because both were
discovered by building against the merged API and neither is written down anywhere else.

### ~~There is no `GET /me`, so the app cannot show your own name after a relaunch~~ — RESOLVED Aug 9, in PR #24. The route exists, the client stores the record between launches and refreshes it from `GET /me` on every launch that has a network.

`PATCH /me` exists and works. The user record arrives once, with the sign-in response, and
`AppSession` holds it in memory — so after a force quit the app has a valid keychain token, a
signed-in session, and no idea what the person is called.

Settings handles it honestly: the **Your name** row renders no value at all rather than claiming
"Not set", which would be a statement about the server it has not checked. The Email row falls
back to the configured account. But the correct fix is a `GET /me` returning the same `UserOut`
that `PATCH /me` and `POST /auth/apple` already return — a handful of lines in
`api/src/rascal/routers/me.py`, using the `CurrentUser` dependency that is already there.

Deliberately not built in this run: Lane B is the iOS lane, the endpoint is Lane A's to own, and
the client degrades correctly without it. Item 6 of `docs/device-verification-settings.md` asks
the human to judge how badly it reads on a real device.

### The archive export's progress bar needs a session delegate, not the async API

Not blocking anything — fixed — but written down because it is invisible in code review and the
kind of thing that gets reintroduced.

`URLSession`'s async `download(for:delegate:)` takes a per-task delegate, accepts a
`URLSessionDownloadDelegate`, and **never calls `didWriteData` on it.** That method belongs to
the download delegate, and the async variants only route `URLSessionTaskDelegate` callbacks.
Instrumenting it proved the point: zero callbacks across a full 86MB transfer, on
`URLSession.shared` and on a dedicated session alike, while the progress bar sat at nothing and
the row read as hung — the exact failure the export was supposed to avoid.

Byte progress requires a classic **session-level** delegate and a `URLSessionDownloadTask`,
bridged back to async with a continuation. `ArchiveDownloader` does that, and the same
instrumentation then recorded 180 delegate callbacks and 269 UI state updates from 0.2% to 100%.

Worth knowing for the media path too, if a download ever needs progress there.

### `POST /v1/auth/dev-login` can never satisfy a preflight aimed at a deployed API

Not a defect — the opposite. `main.py` registers `auth.dev_router` only `if settings.is_local`,
and `config.py` says in as many words that nothing else may branch on environment. A deployed
API answering `dev-login` with a usable session would be the bug.

Worth writing down because a run instruction asked for exactly that as a preflight check, and
the only way to satisfy it is against a local API (`make up && make dev`), which is what
`make fixtures` already defaults to. Until section 3 closes there is no deployed API to check
anything against: `rascal-api.fly.dev` does not resolve and every Deploy run has skipped.

## 0. ~~GitHub Actions is not running — account billing~~ — RESOLVED Aug 9, and it found a real bug

**Cleared between 18:36Z and 18:53Z on Aug 9.** The 18:36 runs on PR #24 still died in 3 and 12
seconds with the billing annotation; the 18:53 runs executed properly — `CI` green in 1m50s,
`iOS` running a full 9m27s. Nothing in the repo changed in between, so the account-level block
was lifted rather than worked around.

Kept here because the first genuinely-executed run immediately earned its keep, and because the
original entry claimed local runs were an adequate substitute for CI. They were not:

**`iOS` failed on `SyncScaleTests.fullPullAtArchiveScale()` — 47.5s against a 30s budget** — a
test that passes locally. The cause is not the engine. All three tests in `Sync at scale` are
`@MainActor` and all three apply 736 entries, and Swift Testing runs them in parallel by
default, so they interleave onto the one main actor and the wall clock each one reads spans the
other two's work. Measured directly:

| | `fullPullAtArchiveScale` elapsed |
|---|---|
| alone, locally (`-only-testing`) | **2.7s** |
| beside its two siblings, locally | **10.7s** |
| beside its two siblings, on the CI runner | **47.5s** — fails |

The budget was right and the apply was never slow; the timer was reading three archives and
calling it one. Fixed by marking the suite `.serialized`, which changes no assertion and no
budget — it makes `elapsed` measure the thing the assertion names.

**The lesson worth keeping:** a wall-clock assertion inside a parallel suite measures the
machine's contention, not the code. This one was invisible on a fast laptop for exactly as long
as CI was down, and it is the kind of test that reports a number nobody should trust.

**Still missing from the picture:** the `image` job, which builds the Docker image and is the
only thing that would catch a Dockerfile-level break. It has never had anything to do with the
iOS lane.

## 1. Apple Developer enrollment — blocks real Sign in with Apple

`POST /v1/auth/apple` is fully implemented and tested: it fetches and caches Apple's JWKS,
verifies the signature, and checks `iss`, `aud` against `APPLE_BUNDLE_ID`, and `exp`. The
tests generate a local RSA keypair and stub the JWKS fetch, so the verification logic is
exercised — including a token signed by the wrong key under the right `kid`, which is the
case that catches decorative verification.

What it cannot do is accept a token from a real device, because `aud` has to match a bundle
id from an enrolled team.

**The bundle id is settled: `com.travisterry.childarchive`.** Deliberately name-neutral,
because the app name is still open and a bundle id is permanent. It is already set in
`.env.example` and in `ci.yml`'s test environment, and the Xcode target is signed with it.

**What I still need:** enrollment itself, and then the same value as a Fly secret. Nothing
in the code changes:

```bash
fly secrets set --app rascal-api APPLE_BUNDLE_ID="com.travisterry.childarchive"
```

Registering the App ID with Sign in with Apple enabled is the other half. Adding the
capability in Xcode under automatic signing does that registration for you.

**Meanwhile:** `POST /v1/auth/dev-login` returns a real session with real tokens against a
fixture account, and it works for curl and for the iOS client. It is registered only when
`ENVIRONMENT == "local"`, and there is a test that builds a production app and asserts the
route does not exist.

## 2. Object storage — resolved. Media uploads work end to end

**No longer blocked.** Storage is Tigris, not AWS. Nothing in this project needs an Amazon
account: every call is plain S3 through boto3, and the `AWS_*` variable names are the S3
protocol's convention rather than a sign of who is serving it.

Verified against the real bucket on Aug 8, 2026, not against `moto`:

```
POST /v1/entries              -> 201
POST /v1/media/upload-url     -> 200, host rascal-media-dev.t3.storage.dev
PUT  <presigned>              -> 200, ETag "4edd3122d08ca94fe65916ddf54008f0"
POST /v1/media/{id}/complete  -> 200, upload_status "complete"
```

Setup, credentials, and the two traps that cost a debugging cycle are in
`docs/tigris-setup.md`. The short version:

- `tigris access-keys create` returns a key with **no permissions**. Everything, including
  presigned PUT, is `AccessDenied` until `access-keys assign <id> --bucket <b> --role Editor`.
- `S3_REGION` must be `auto`. A real region signs a scope the endpoint rejects, and it reads
  as a credentials failure.

**One correction to what this section used to say.** It claimed the CORS rule must expose
`ETag` or completion fails. That is true for a browser and false for the iOS client — CORS is
browser-enforced, and `URLSession` reads the header regardless. The ETag above arrived before
any CORS rule existed. CORS is set anyway (`ExposeHeaders: ["ETag"]`, verified by reading it
back) for the web client the architecture reserves.

**Still worth doing by hand:** a real multipart upload of a video over cellular. Tigris
supports the multipart API but parity has not been proven, and `chunk_bytes` comes back `null`
on the single-PUT path — the client must read the field and tolerate null rather than
hardcoding 8MB.

## 2b. The production media bucket does not exist yet — and must not be created carelessly

Not blocking anything today; local development runs against `rascal-media-dev`. Recorded here
because both items below are six-weeks-from-now problems that nothing currently reminds anyone
about, and one of them is unrecoverable.

**Soft delete must be on for the production media bucket.** `rascal-media-dev` deliberately has
it off — a dev bucket you cannot clear is a nuisance. Production is the opposite case: it holds
the one category of data in this system that cannot be regenerated. `rascal-backups` is already
configured the right way (soft delete, 30-day retention) and is the model to copy:

```bash
tigris buckets create rascal-media-prod --access private
tigris buckets set rascal-media-prod --soft-delete enable --retention-days 30
tigris access-keys create rascal-api-prod
tigris access-keys assign <key-id> --bucket rascal-media-prod --role Editor
```

The assign step is not optional — a new key has no permissions and every call, including
presigned PUT, returns `AccessDenied`.

**`DEPLOY.md` §3 used to specify versioning for the AWS bucket, and that requirement did not
survive the move to Tigris.** Tigris soft delete covers the same ground — recovering an object
deleted or overwritten by mistake — but it is a different mechanism with a retention window
rather than unlimited history, and it is off by default. That drift is the actual risk: the
old document said "turn on versioning", the new one does not say "turn on soft delete", and
nobody notices until they need it.

**CORS should be tightened when a web client exists.** `rascal-media-dev` is currently
`AllowedOrigins: ["*"]`. That is harmless while the only client is native — CORS is
browser-enforced and `URLSession` ignores it entirely — but it should become the real origin
the day a browser first loads a photo, and nothing else will prompt that.

---

## 3. Fly and Docker — blocks deployment, and blocks verifying the image

Every artifact exists: multi-stage `Dockerfile`, `fly.toml` with `release_command =
"alembic upgrade head"` and a `/health` check, and a full runbook in `docs/DEPLOY.md`.

**Neon is no longer blocked.** A database exists, and the *Migrate Neon* workflow has run
`alembic upgrade head`, the seed job, and `verify_schema.py` against it: `server_version:
16.14`, revision `0004_full_text_search`, 113 prompts, every table, index, CHECK constraint,
trigger, and stored generated column present by name. Neon accepts this schema — that is a
fact now, not an assumption.

**Docker is no longer blocked. Fly still is.** Everything below the Fly line was executed on
a real machine on **Aug 8, 2026**, with a Docker daemon available for the first time:

| Path | Status |
|---|---|
| `.github/workflows/ci.yml` passes | **executed, green** — dozens of runs, lint plus the full suite against a real Postgres 16 |
| `api/Dockerfile` builds | **executed, green** — builds clean; the `0.8.17` uv pin reads `revision = 3` as intended |
| `api/Dockerfile` *runs* | **executed, green** — non-root `rascal` (uid 1001), venv on PATH, binds `0.0.0.0:8080`, `/health` → `{"status":"ok","db":"ok"}` |
| `docker-compose.yml` starts Postgres | **executed, green** — healthy, after the host port was made overridable |
| `make migrate && make seed && make test` | **executed, green** — `0004_full_text_search`, 113 prompts, 265 passed |
| `dev-login` absent outside `local` | **executed, green** — with `ENVIRONMENT=prod` the real image returns 404 for `/v1/auth/dev-login` and `/v1/debug/*` |

The uv pin question is closed: `0.5.11` could not read the `revision = 3` lockfile, `0.8.17`
can, and the image now builds on a machine rather than in theory.

Two things that only surfaced once a real machine ran this, both fixed:

- **The compose host port was hardcoded to 5433**, which another project's Postgres already
  held. The container stayed in `Created` forever and `make up` looked like it hung. The port
  is now `${POSTGRES_PORT:-5433}`; set `POSTGRES_PORT` and the port in `DATABASE_URL` to the
  same free number.
- **`pg_dump` must be major-version 16, not merely ≥ 16.** A 17 client writes `SET
  transaction_timeout` into the dump, Postgres 16 rejects that parameter on the way back in,
  and `tests/test_restore.py` fails with an error that never mentions versions. `ci.yml` was
  testing for ` 1[6-9]\.` and passed only because today's runner still ships 16; both it and
  `backup.yml` now require 16 exactly and put `/usr/lib/postgresql/16/bin` first on PATH,
  because Debian's `pg_dump` is a wrapper that otherwise dispatches to the newest installed
  version. A backup taken by a 17 client would not restore into Neon.

**What I need:** for Fly, sections 1 and 4 of `docs/DEPLOY.md` — create the app, generate a
deploy token, add `FLY_API_TOKEN`, and set the `FLY_DEPLOY_ENABLED` repository variable to
`true`. Until that variable is set the Deploy workflow skips rather than failing, so a push
to `main` is grey instead of red.

## 4. `ANTHROPIC_API_KEY` — resolved. Four batches generated, awaiting your review

**No longer blocked.** The key is set as a repository secret, the *Prompt candidates*
workflow has run, and it opened a pull request that is now merged. `docs/prompt-candidates/`
holds four worksheets, generated by `claude-sonnet-5` against the four thinnest themes in the
library:

| File | Theme | Kind | Accepted |
|---|---|---|---|
| `fears-comfort-2026-08-04.md` | `fears-comfort` | question | 20 of 20 |
| `making-building-2026-08-04.md` | `making-building` | question | 20 of 20 |
| `outdoors-2026-08-04.md` | `outdoors` | question | 19 of 20 |
| `sleep-routine-2026-08-04.md` | `sleep-routine` | question | 20 of 20 |

All four batches are `question`, which is what `--thinnest` asked for and not a spread across
kinds. The activity, photo, video, and audio sides of those themes are still as thin as they
were; generating for them is another run with `--kind`.

**These are unreviewed.** Every candidate below passed the automated filters, and each file
says so in its own header: the filters are a spam trap, not an editor. They catch the four
rejection rules where the rule is textually detectable and nothing else. **79 prompts still
need a human to read them.** One candidate was rejected, in `outdoors`, and the reason is
recorded in that file rather than discarded.

Each file explains its own review process — delete the rows you do not want, move the
survivors into the right table in `docs/mission-library.md`, regenerate the YAML, reseed,
update the coverage numbers `test_seeding.py` asserts, and delete the worksheet in the same
commit. It is a worksheet, not a record.

The original blocker, kept for the record:

### How it was unblocked

`api/scripts/generate_prompts.py` is finished. It reads `docs/mission-library.md` as the
style reference, asks for a batch against a target theme, age band, and kind, and filters
what comes back against the library's four rejection rules — implemented in code, and tested
in `api/tests/test_generate_prompts.py` against real prompts from the library, so a filter
calibrated tightly enough to reject "get on the floor for ten minutes" fails the suite.

Thirty-one tests cover the filters, the near-duplicate check, the request construction, and
the rendering. The one thing they could not cover was the model call itself, because there
was no key in this environment — so the script was complete and entirely unproven.

You added `ANTHROPIC_API_KEY` as a repository secret and the workflow was dispatched with
`thinnest: 4`, which picked the four themes above (2, 4, 3, and 4 prompts in the library
respectively). Two things came out of the first real run:

- **The first attempt returned a bare `400 Bad Request` and said nothing else**, because
  `httpx.raise_for_status()` discards the response body. The script now prints the API's own
  error, the model it asked for, the instruction length, and the forced tool name.
- **`ANTHROPIC_MODEL` is read with `.strip() or` a default, not `.get(name, default)`.** An
  unset repository variable arrives as an empty string rather than being absent, so the
  original code would have sent `"model": ""`.

The second attempt succeeded with no other change, so **the cause of that first 400 is still
unknown.** It is written down here rather than explained away.

To run it again — a new theme, or a bigger batch:

```bash
# Actions -> Prompt candidates -> Run workflow, or locally:
export ANTHROPIC_API_KEY=sk-ant-...
cd api && uv run python scripts/generate_prompts.py --thinnest 4
```

Optionally set the `ANTHROPIC_MODEL` repository *variable* to pin a model; the script
defaults to a current one. Every run opens its own branch and pull request — never a reused
one, so two batches cannot overwrite each other while one is still open for review.

---

## Deferred by decision — not blocked, and not waiting on you

These were left out on purpose. Each is a small piece of work if you decide otherwise.

- **`POST /prompts/batch-review`.** Not deferred any more — **cut**, and removed from
  `docs/api-contract.md` rather than left in it as a promise. The review queue it approved
  candidates from is a pull request now: `scripts/generate_prompts.py` writes batches into
  `docs/prompt-candidates/` and the *Prompt candidates* workflow opens a PR with them. A
  branch with a diff is already an accept/reject interface with a comment thread, an audit
  trail, and an undo.
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
