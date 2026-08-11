# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: **Aug 10, 2026** — CI is billing-blocked again; see §0. The widget adds one line to §1: the App Group has to be on the developer portal before a device build means anything.

---

## iOS Seal control — `POST /entries` cannot hear "do not seal this"

The seal control shipped and works. This is the one thing it cannot express through the create
route, and it is **four lines to fix in Lane A**.

`create_entry` seals a letter whenever `unlock_at_age` arrives as `None`:

```python
# api/src/rascal/services/entries.py
if unlock_at_age is None and prompt is not None:
    # Letters are sealed by default. The server owns this, not the client.
    unlock_at_age = prompt.default_unlock_age
```

That default is right, and it is why a letter written by any client is sealed even if the client
has never heard of sealing. The problem is that **Pydantic gives `None` for an omitted key and for
an explicit `null` alike**, so the handler cannot tell "I have no opinion" from "the parent turned
this off". A letter prompt the parent deliberately unsealed is created sealed at the prompt's
default, whatever the client sends.

**`PATCH /entries/{id}` does not have this problem** — `routers/entries.py` dumps with
`model_dump(exclude_unset=True)`, so an explicit null reaches the service as a field that was set
and clears it. The two routes disagree about what null means.

**Worked around in the client, visibly and temporarily.** `EntryCreateRequest` now always writes
`unlock_at_age`, including as an explicit null, so the client is already correct. Because the
server currently collapses that, `APIClient.createEntry` compares what it sent with what came back
and, when the server sealed a row that asked not to be sealed, says it again through `PATCH`.

**It lives in `createEntry` rather than in the composer on purpose.** The composer is not the only
writer: `EntrySync` re-sends an entry saved while offline through the same call, so a letter
written on a train with sealing turned off would otherwise arrive sealed hours later with nobody
told. One place, every caller. It is also self-detecting — it fires only when the response
disagrees with the request — so the day this is fixed it stops doing anything.

If the corrective `PATCH` cannot land, `Entry.applyServerResponse` copies the archive's value back
onto the row, so the phone shows what the permanent record actually holds rather than what was
intended, and the composer says so.

**What Lane A needs to do:** have `create_entry` take the field's *setness* rather than its value —
`payload.model_fields_set` at the router, or pass a sentinel — so an explicit null means "not
sealed" and an absent key keeps the prompt default. The day that lands,
`unsealIfTheServerSealedItAnyway` stops firing, and can be deleted with its round trip.

---

## iOS Onboarding — the avatar has nowhere to go, and pronouns have nowhere to live

Found by building first-run setup against the merged API. Neither blocks onboarding, which ships
complete: the avatar is optional by design and a skipped one is a finished setup. Both are Lane A's
to own.

### There is no endpoint that presigns an upload for a child's avatar

`children.avatar_key` exists and `PATCH /children/{id}` accepts it, so the *destination* is
modelled. Nothing mints a key. The only presign route is `POST /media/upload-url`, and
`UploadUrlRequest.entry_id` is **required** — its access check is `entry_access_from_body` and
`plan_upload` creates a `media` row against an entry. There is no child-scoped equivalent, and the
registered router list in `main.py` has nothing else that could serve one.

**Not worked around, deliberately.** Pushing avatar bytes through the entry-scoped route would
file a picture of a child in the archive as some entry's artifact — a wrong row in a permanent
archive, which is worse than no upload. So the processed image is stored on the device only, by
`LocalAvatarStore` in `Application Support/avatars/`, and `avatar_key` stays null.

**Consequence:** an avatar does not survive a new phone and does not reach the browser client
reserved for 2027. Everything else about the child does.

**What the client needs.** A child-scoped presign, mirroring the media one minus the entry:

```
POST /v1/children/{child_id}/avatar-upload-url
Body:     { "content_type": "image/jpeg", "bytes": 41234 }
Returns:  { "upload_url": "https://…", "avatar_key": "children/{id}/avatar/{uuid}.jpg",
            "expires_in": 900 }
```

Parent role, single PUT only — an avatar is a ~512px square and never needs multipart. The client
would then `PATCH /children/{id}` with the returned `avatar_key`, which already works today. A
matching `GET /v1/children/{id}/avatar-url` is needed to read it back, since the bucket is private.
`LocalAvatarStore` is the seam that would be swapped, and the crop and JPEG conversion already run.

### Onboarding cannot collect pronouns, because `children` has no column for them

`docs/decisions.md` open item 10 says the mission library stays he/him until **onboarding collects
the child's pronouns**, and lists it as needed "with onboarding". This phase built onboarding and
**could not close it.** `Child` has `name`, `birthdate`, `avatar_key`, `family_timezone` and
nothing else (`api/src/rascal/models/child.py`), so there is nowhere to put the answer, and adding
a column is a Lane A change the iOS lane may not make.

Asking for pronouns and then discarding them would be worse than not asking, so onboarding does
not ask. Client copy is neutral throughout and needs no pronoun to render.

**What it needs:** a nullable `children.pronouns` (`text` + a named `CHECK`, per the enum
convention), exposed on `ChildCreate`, `ChildUpdate` and `ChildOut`. The rendering half — pronoun
substitution in prompt bodies — is separable and is the part item 10 says not to let the `{name}`
token block.

---

## iOS Timeline v3 — two things the list endpoint cannot express

Neither blocks the v3 skin, which shipped complete. Both are Lane A's to own, and the client
degrades correctly without either — recorded because they were found by building the screen
against the merged API and are written down nowhere else.

### `GET /entries` does not carry `prompt`, and v3's card is built around it

`EntryOut` has no `prompt`; only `EntryDetail` from `GET /entries/{id}` does, and
`docs/api-contract.md` says so deliberately. The v3 card leads with the prompt the entry
answered, so on a list row there was nothing to quote.

**Worked around inside the iOS lane, in two places, and the pair is good enough to ship.**
The card reads `entries.prompt_body` when it has one, and otherwise resolves `assignment_id`
against a locally cached `Assignment`, whose `body` is the same sentence.

`prompt_body` is filled from two directions:

1. `GET /entries/{id}`, whenever the parent opens the entry.
2. **At composition.** `ComposerView` writes `assignment.body` onto the row as it creates it.
   The sentence is on screen above the field the parent is typing into, so writing it down
   costs nothing and the quote is correct offline, immediately, and for good.

**The assignment fallback is currently the weaker of the two, and a device proved it.**
`Assignment` rows are written *only* by `SyncEngine` from a `/sync` response, and sync pull
ships behind `syncPullEnabled`, which is **off**. So with the app as it ships today the
fallback resolves nothing, and the composer cache in (2) is what actually puts prompts on
cards. The fallback becomes real the day pull is switched on — it is written and tested, not
speculative — but it is not carrying the feature right now.

**Where it still comes up short:** an entry written on another device, or before this build,
shows no quote until the parent opens it once. The zone drops out cleanly, so the card reads
as freeform rather than broken — but it reads as freeform when it wasn't. Only the server
field fixes that one.

The fix is a field, not a feature: `prompt_body` (or the existing `PromptRef`) on `EntryOut`.
The join is already there — `entries.assignment_id → assignments.prompt_id → prompts.body` —
and `EntryDetail` performs it today.

### There is no way to ask the server for sealed entries

The v3 filter row has seven chips and the seventh is **Sealed**. Sealed is `unlock_at_age
IS NOT NULL`, not an `entry_type`, so `?type=` cannot express it and `GET /entries` has no
other parameter that can.

**Shipped as a client-side filter**, on the explicit call that a Sealed chip is worth having.
The consequences are real and are handled rather than hidden:

- The `@Query` narrows on `unlockAtAge != nil` against the local cache.
- The server still pages the whole archive, so `serverType` stays nil and the paging seed stays
  unfiltered — seeding from the oldest *sealed* row would ask for everything older than it and
  strand every ordinary entry in between.
- **Paging needed a loop.** The trigger hangs off the last card appearing, so a page of fifty
  ordinary entries adds no card and therefore nothing to trigger the next page — the filter
  stopped dead on any stretch of archive without a letter in it. `TimelineModel.drain` keeps
  fetching while a client-side-only filter has nothing to show, bounded to
  `clientFilterPageBudget` (10 pages, 500 entries) per load, and never retries a failure.

So a sealed list is correct but can cost ten round trips to fill on an archive where letters
are rare, and after a budget it reports what it found rather than what exists.

`?sealed=true` on `GET /entries` — one `WHERE unlock_at_age IS NOT NULL` — removes the loop,
the budget, and the caveat. It is a small change and it is not urgent.

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
`make fixtures` already defaults to. `rascal-api.fly.dev` resolves as of Aug 10, 2026 — and
answers that route with a 404, which is the correct answer and not a preflight.

## 0. ~~GitHub Actions is not running — account billing. **Recurred Aug 10.**~~ — RESOLVED Aug 10, 2026

**Cleared at ~22:00Z**, and the cause was not a failed payment. The account had five
product-level budgets at **$0 with "stop usage" on**, Actions among them, so every run was
rejected before its first step. Raising the Actions budget to $10 fixed it; a `Backup`
dispatch immediately ran a real 20s job and wrote `rascal-20260810T220343Z.sql.gz`.

Worth keeping because the annotation ("recent account payments have failed **or** your
spending limit needs to be increased") reads as a payment problem first, and it was the
second clause both times. Check the budgets before the card.

The original entry follows.

**Blocked again, and only you can clear it.** Every macOS run since roughly **Aug 10, 00:08Z** has
been rejected before executing a single step. The annotation on the job is explicit:

> The job was not started because recent account payments have failed or your spending limit needs
> to be increased. Please check the 'Billing & plans' section in your settings.

The shape is identical to the first outage: a run that should take 7–9 minutes completes in **3–4
seconds** with zero steps recorded and no uploaded log. Compare `31340226713` (Aug 9 22:46, the
last real run, **7m25s**, green) with `31345406168`, `31346334620` and the re-run of
`31343122733` — 4s, 3s, 4s.

**What this does and does not mean.**

- It does **not** mean `main`'s red is fake. PR #27's run at Aug 9 23:56 genuinely executed and
  genuinely failed on `TranscriptionTests`; that content is what merged. The billing block started
  afterwards, so the *merge* run and everything since never got to say anything.
- It does mean **no branch can currently be verified by CI**, including the fix for that failure.
  PR #28 is red for this reason and this reason only.
- Anything downstream that requires "`main` green" as a precondition is blocked on your billing
  settings, not on code. iOS Phase 9 stopped here.

Local runs are the only verification available meanwhile, and the section below is the standing
reminder of exactly how far that goes: **not far enough.** The last outage ended with CI
immediately catching a wall-clock test that passed on a fast laptop, and this outage began the same
way — two cancellation tests that pass locally and failed on the runner.

---

## 0a. ~~GitHub Actions is not running — account billing~~ — RESOLVED Aug 9, and it found a real bug

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

## 1. ~~Apple Developer enrollment — blocks real Sign in with Apple~~ — RESOLVED Aug 10, 2026

**Verified end to end against production**, from a device build, at `01:06:29Z`. Not inferred
from a green test — the rows are in the archive:

```
POST /v1/auth/apple  ->  200
credentials: provider=apple  subject_id=001022.97b033a…
users:       mpnkj8g55n@privaterelay.appleid.com
```

The enrollment is done, the App ID carries the capability, and `APPLE_BUNDLE_ID` on Fly is
`com.travisterry.childarchive`, matching the target's `PRODUCT_BUNDLE_IDENTIFIER`. The `aud`
check — the one thing no test could exercise, because it needs a token from an enrolled team —
now has a real Apple-signed token behind it.

**Three things that run happened on the way there and are worth keeping.**

- **The stale-session path ran for real, unrehearsed, and was correct.** The phone still held a
  token minted by the local API under a different `JWT_SECRET`. It went
  `GET /v1/children` → 401, `POST /v1/auth/refresh` → 401, `POST /v1/auth/apple` → 200,
  `POST /v1/children` → 201. Refusing a foreign token and falling back to Apple rather than
  stranding the parent is exactly the designed behaviour, and nobody had ever seen it happen.
- **The account was created with `display_name` NULL**, and that is not a defect here — it is
  Apple's one-shot `fullName`, already spent by an earlier sign-in against the local API. The
  name is per (Apple ID, App ID) and does not reset on reinstall. Settings → Your name fixes it
  through `PATCH /me`. Worth knowing before the *next* person's first sign-in: revoke under
  Settings → Apple ID → Sign-In & Security first, or the first real account has no name.
- **The parent chose Hide My Email**, so the owner record is a `privaterelay.appleid.com`
  address. Nothing in the API cares, but it is what any future email path would have to send to.

**Still not exercised:** revocation. `getCredentialState` is called on launch, and no test and
no run has ever seen a parent revoke the app in Settings and come back.

The original entry follows, because the second paragraph is still the accurate description of
what the verification code does.

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

**There is now a file that registration has to land in, and it does not mention Sign in with
Apple yet.** Before the widget there were no entitlements at all, so nothing was missing from
anywhere. `ios/Rascal/Rascal.entitlements` exists as of PR #32 and declares one thing, the App
Group. When you tick Sign in with Apple in Xcode it will add `com.apple.developer.applesignin`
to that same file — **let it, and commit the result.** It was deliberately not added blind here:
adding an entitlement changes device signing, this machine has no device to check it on, and a
wrong guess would have failed the build for a capability that is blocked anyway. Worth knowing
because the failure mode if it is missed is quiet — the button is there, the exchange just never
succeeds.

**The widget adds one more thing to that same registration, and it is worth knowing before you
plug in a device.** The App Group `group.com.travisterry.childarchive` has to exist on the
developer portal and be present in the provisioning profiles for **both** targets. On a simulator
this is free — the build signs ad hoc and the entitlement simply works, which is how the widget was
verified here. On a device, if the group is missing,
`containerURL(forSecurityApplicationGroupIdentifier:)` returns nil, every read and write degrades
to doing nothing by design, and **the widget shows its neutral state forever with no error
anywhere.** That is a silent failure, not a crash, so it is the first section of
`docs/device-verification-widget.md`. Xcode's automatic signing normally registers the group on
first device build; this is not blocked, it is just the one thing to confirm before concluding the
snapshot pipeline is broken.

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

## 3. ~~Fly and Docker — blocks deployment~~ — RESOLVED Aug 10, 2026. **The API is deployed.**

`https://rascal-api.fly.dev` serves, `/health` returns `{"status":"ok","db":"ok"}`, and
`scripts/verify_deployment.py` passes **6/6** against it — including the Tigris round trip
that had never once succeeded anywhere. Two machines in `ord`, an hourly scheduler machine
beside them, secrets set, Smoke green.

The two things the first real deployment broke are recorded in `docs/runbook-deploy.md` §9,
because both were silent: `deploy.yml` failed a healthy deploy over a status string, and the
runbook's `fly machine run` built a machine that ran the API server instead of the scheduler.

Everything below is the record of what this section said while it was open.

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

**What I need — human actions, and only these.** Every one requires a Fly account this agent
has no token for and must not obtain. `docs/runbook-deploy.md` is the ordered version with
exact commands; this is the short list of what is genuinely yours to do:

1. `fly apps create rascal-api` (runbook §1).
2. Neon: copy out **both** the pooled and the direct connection strings (§2).
3. `fly storage create`, then assign the new access key an `Editor` role on the bucket — a
   fresh Tigris key has no permissions at all until you do (§3).
4. `fly secrets set` for the seven secrets in §4. Not `S3_REGION` or `S3_ENDPOINT_URL`;
   those are `fly.toml` `[env]` values now, and setting them twice is how precedence
   becomes a thing you have to reason about.
5. `fly tokens create deploy --app rascal-api`, paste as the `FLY_API_TOKEN` repository
   secret, and set the `FLY_DEPLOY_ENABLED` repository **variable** to `true`. Until that
   variable is set the Deploy workflow skips rather than failing, so a push to `main` is
   grey instead of red.
6. `fly deploy`, then seed the library, then create the scheduled machine (§5).
7. Run `scripts/verify_deployment.py` (§7).

**What is no longer a human action.** Migrations run themselves, as Fly's `release_command`,
before new machines take traffic. Verification is a program rather than a checklist —
`api/scripts/verify_deployment.py`, six checks, exit code 0 or a named failure. And the
thing this section used to imply was a deployment prerequisite is not one any more: **a
missed scheduler run no longer costs a day.** `GET /today` creates the day's assignments
itself, so step 6's `fly machine run` can be skipped or fumbled and the product still works.
Skipping it costs expiry, not assignments.

**All seven were executed on Aug 10, 2026**, in that order, and steps 1–7 are done. What the
run cost in surprises is in `docs/runbook-deploy.md` §9, which is still the honest inventory
of what has and has not run against real infrastructure — it is just a much shorter list of
"has not" than it was this morning.

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
- **Transcribing the audio track of a video.** Cut from the transcription phase rather than
  shipped shaky. The roadmap asks for it and `AVAudioFile` plausibly opens an MPEG-4
  container's audio track — but *plausibly* is the whole problem: nothing in this environment
  can run a single real transcription, so a second input path would be unverifiable on top of
  an already unverified first one. It is also the expensive one, because a backlog video has
  to be fetched to be read at roughly 70MB a minute. **What it needs:** the audio path
  confirmed on a device via `docs/device-verification-transcription.md`. After that it is one
  clause in `TranscriptionQueue.isTranscribable` plus a rule about not doing it on cellular.
- **Backfilling transcripts on a phone that never sees Wi-Fi.** Fetching a recording this device
  does not hold refuses expensive and constrained networks on purpose — a backlog run is hundreds
  of files and nobody consented to that on cellular. The consequence is that those rows never
  backfill on a cellular-only phone; they report *"Waiting for Wi-Fi"* and stop after the retry
  cap. There is deliberately **no override toggle** — Settings has no preferences and adding one
  for this would be the first. **What it would need:** evidence that anyone is actually in this
  position. Recordings made on the phone itself are unaffected, which is the common case.
- **Transcript editing.** A parent will eventually want to correct a word. That is a real
  feature with a real conflict story — two devices editing the same derived field against a
  server documented never to regenerate it — and shipping an editor without that story turns
  "on-device output is durable data" into "whichever phone typed last".
- **A search result matched on someone else's transcript cannot say why it matched.**
  `GET /entries` inlines `MediaSummary`, which carries no transcript, so the client can only
  quote a matching line for a transcript it has cached. It renders as an ordinary card
  otherwise, which is correct rather than broken. **What it needs:** either `transcript` on
  `MediaSummary` or a `matched_snippet` on the search response — both are API-lane changes and
  neither is worth making for this alone.

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
