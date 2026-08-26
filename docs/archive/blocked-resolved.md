# RASCAL — blocked list, the resolved sections (archived)

**Archived Aug 25, 2026 by phase 123.** `docs/blocked.md` is the page you read to find out what is
waiting on a person or a credential, and it had grown to **202 KB** because a section that closes
stays on it forever. **Seventeen fully-resolved sections are moved here whole and unedited** —
GitHub Actions billing, Apple enrollment, object storage, Fly, the Anthropic key, the six iOS-lane
entries that Lane A closed, §12 (Google client id), §14 (`entry_type`) and §17 (Gemini video).

**Nothing partially resolved moved.** §10a and §18 both carry struck clauses and both still have an
open half — `APP_STORE_APP_APPLE_ID` is unset, the Instagram token still expires — so they stay on
the live page in full. **A section is archived only when every item under it is closed**, which is
a stricter test than "the heading is struck through".

**The evidence moved with them.** Each of these sections carries the command that proved it closed
and the output that command printed; that is the thing that makes a resolved blocker worth keeping
at all, and it is here rather than summarised away.

* * *

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

* * *

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

* * *

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
`docs/Device-Verification/device-verification-widget.md`. Xcode's automatic signing normally registers the group on
first device build; this is not blocked, it is just the one thing to confirm before concluding the
snapshot pipeline is broken.

### 1a. ~~Push — the enrollment cleared, so this is now the only thing on this page genuinely waiting on you~~ — RESOLVED Aug 12, 2026. **A real notification was delivered.**

**Both actions are done, and the feature works end to end in production.**

1. **The key.** Minted in the portal, key id `3V94JLB7NQ`, team `8976QYWNC2`. `APNS_KEY_ID`,
   `APNS_TEAM_ID` and `APNS_PRIVATE_KEY` are set as Fly secrets on `rascal-api`.
2. **The scheduled machine.** `fly machine run` created `8900ddf6719058`
   (`throbbing-water-1063`), hourly, `--restart no`, `init.cmd = python -m rascal.jobs.notify`.
   It is a **second** scheduled machine alongside the scheduler's `185d762c643778`; the two are
   independent and `fly deploy` updates neither.

**What the first real send proved**, on Aug 12, 2026 at 20:40 America/Detroit:

```
HTTP/2 200 OK  ←  https://api.push.apple.com/3/device/…538530d8
notify: 1 sent to 1 device(s), 0 failed, 0 dropped as stale
notification_sends: date 2026-08-12, device_count 1, delivered_count 1, slot mission_b
```

The notification arrived on a locked phone and **tapping it deep-linked to the assignment**, which
closes §3 of `docs/Device-Verification/device-verification-push.md` — the section that could not be tested at all
because the simulator cannot tap a notification.

**The sandbox/production split is confirmed correct, not merely untested.** That `200` came from
the *production* host. A sandbox token sent there is rejected with `400 BadDeviceToken`, so Apple
accepting it proves the device minted a genuine production token and
`ios/Rascal/Rascal/Push/PushEnvironment.swift` maps the environment correctly.

**The description bug this section used to carry is fixed**, in commit `39fb97f` on Aug 12 —
earlier the same day as the first real send, and before this section claimed it was outstanding.
`schemas/device.py` and `docs/api-contract.md` now both say `production` covers "**TestFlight and
the App Store alike**". **Nothing in this section is open.**

**What is still not covered by pytest:** the socket. `ApnsClient`'s pure parts are tested; the
call to Apple is verified by production runs and by the device checklist, not by the suite. That
was true before this and remains true.

The original entry follows.

**Not a separate blocker.** The APNs key comes from the same Apple Developer portal trip as
the Sign in with Apple key, so this unblocks when §1 does, and it is recorded here rather
than as its own entry for that reason.

Push notifications shipped complete against a stubbed APNs client, the way transcription
shipped against a stubbed transcriber. `devices` and `notification_sends` exist, the
preference is on `/me`, and `python -m rascal.jobs.notify` decides correctly *who* should be
notified, *when* in the child's timezone, and *what* the payload contains — all of it
tested. What has never happened is a single real call to Apple.

**What is stubbed, precisely.** `rascal.services.push.ApnsClient` is written and its pure
parts are tested: the ES256 provider token's header and claims, the host chosen per
environment, the request headers, and the mapping from an APNs response onto a result —
including `410` and `BadDeviceToken` revoking the device. **The socket is not tested.** No
byte has been sent to `api.push.apple.com` from this repository, so "Apple accepts this
request" is unverified in every respect: the topic, the payload shape, the token format, and
the provider-token signature.

**What that looks like in production today.** With `APNS_KEY_ID`, `APNS_TEAM_ID` and
`APNS_PRIVATE_KEY` unset, `build_push_client` returns a client that sends nothing and logs
`push not configured` at WARNING. It deliberately does **not** report success — a push
service that silently no-ops is indistinguishable from one that works until somebody notices
their phone has been quiet for a month. `notification_sends` rows are still written, with
`delivered_count` at zero, which is the honest record of what happened.

**What I still need:** an APNs key from the portal — Certificates, Identifiers & Profiles →
Keys → + → Apple Push Notifications service (APNs) — and then three Fly secrets. The `.p8`
is downloadable exactly once. `docs/runbook-deploy.md` §4a has the exact commands.

Nothing in the code changes when the key arrives. The first real send is also the first real
test of it, so treat the first TestFlight notification as a verification step and not as a
formality — in particular that `sandbox` is what a TestFlight build registers.

**Also outstanding, and not credential-blocked:** the notification job needs its own Fly
scheduled machine (`docs/runbook-deploy.md` §4b), created by hand like the scheduler's. A
fresh app has no notification job until someone runs that command, and **nothing fails if
they forget** — the API is green, devices register, and no notification is ever sent. This
matters more than it does for the scheduler, because `GET /today` repairs a missed
assignment and nothing repairs a missed notification.

**Meanwhile:** `POST /v1/auth/dev-login` returns a real session with real tokens against a
fixture account, and it works for curl and for the iOS client. It is registered only when
`ENVIRONMENT == "local"`, and there is a test that builds a production app and asserts the
route does not exist.

* * *

## 2. ~~Object storage~~ — RESOLVED. Media uploads work end to end, in production, from TestFlight

**No longer blocked, and no longer only in development.** Three separate confirmations now, each
stronger than the last:

1. Against `rascal-media-dev` on Aug 8, 2026 — the presign/PUT/complete round trip below.
2. Against `rascal-media-prod` on Aug 10, 2026 — `scripts/verify_deployment.py` check 6, 75 bytes
   presigned by the **deployed** app (`docs/runbook-deploy.md` §9).
3. **From a TestFlight build, by you.** `rascal-media-prod` holds real objects under `children/`
   as of Aug 11, 2026 — a bucket listing shows the prefix and 4.5 MB across three versions, which
   is more than the 75-byte check wrote. The path from a phone in the world through the deployed
   API to the production bucket is exercised, not inferred.

**The one thing still unexercised is multipart** — see the end of this section. A photo is a
single PUT; the multipart path is what a video over cellular takes, and nothing has taken it.

Storage is Tigris, not AWS. Nothing in this project needs an Amazon account: every call is plain
S3 through boto3, and the `AWS_*` variable names are the S3 protocol's convention rather than a
sign of who is serving it.

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

### The cellular half is done. The multipart half is a smaller question than it looked.

**Owner, Aug 16, 2026:** Wi-Fi off, a large video uploaded from a real device over cellular, and it
succeeded. That proves the upload path survives a real cellular network, which is what this line
used to ask for.

**A successful upload is not, in general, evidence of a multipart upload.** If the split were
decided purely on size and the number were unknown, the two would be indistinguishable from
outside. That was the reason to be careful here — and reading the rule changes the answer.

**2a — the threshold, found (read-only, Aug 16).** The decision is **server-side, not in the iOS
path**, which is worth stating because this section implied otherwise. `api/src/rascal/services/media.py:51-53`:

```python
def wants_multipart(kind: MediaKind, size: int, settings: Settings) -> bool:
    """Video always assumes multipart; everything else crosses over at the threshold."""
    return kind == "video" or size > settings.multipart_threshold_bytes
```

`api/src/rascal/config.py:82-83` — `multipart_threshold_bytes = 15 * 1024 * 1024` (**15 MB**) and
`multipart_chunk_bytes = 8 * 1024 * 1024` (**8 MB**).

**Two ways this differs from "video only, on a size threshold", and both are recorded rather than
changed.** Video is multipart **unconditionally** — `kind == "video"` short-circuits, so a
two-second clip well under 15 MB still takes the multipart path. And the threshold is **not
video-only**: any object over 15 MB qualifies, so a 48MP HEIC or a ProRAW frame takes multipart
too. Whether that is the intended shape is the owner's call; **no code was touched.**

> **~~Video is multipart unconditionally~~ — changed by the owner's call in phase 87, Aug 18, 2026.**
> `wants_multipart` no longer takes `kind` at all: `return size > settings.multipart_threshold_bytes`.
> Size decides for every kind, so a two-second clip now takes the single-PUT path. The quoted
> function above is the pre-87 version and is kept because the paragraphs below reason from it.
>
> **What that costs this section, and it is the interesting part.** The cellular inference below —
> *"because video short-circuits, a video upload takes the multipart path at any size, so the Aug 16
> upload exercised multipart"* — was sound when written and is now **only true of that specific Aug 16
> run**, which happened under the old rule. It cannot be repeated by uploading any video: a future
> cellular test has to send something over 15 MB to exercise multipart at all.
>
> That is worth naming as a shape rather than a correction. **An inference recorded from code becomes
> a claim about history the moment the code changes**, and nothing re-reads it — the sentence stays
> grammatical, stays cited, and quietly stops describing the present. §2b's engineering task is the
> durable answer precisely because it re-derives the fact each time it runs instead of remembering it.
>
> The half that was always right and stays right: the threshold is **not** video-only, so a 48MP HEIC
> or a ProRAW frame over 15 MB takes multipart. That is now the *only* way anything takes multipart.

**What that means for the cellular test.** Because video short-circuits, a video upload takes the
multipart path at any size — so the Aug 16 upload exercised multipart rather than merely coexisting
with it, and `chunk_bytes` came back **8 MB rather than null** (`services/media.py:101` is the
single-PUT branch that nulls it; `:128` is the multipart branch that sets it). **This is inference
from the code, not an observation of that run** — nobody read the response body — and it holds only
if the client sent `kind: video` and the upload ran through to `upload_status: complete`.

**2b — prove `chunk_bytes` server-side. Specified here, not built.** The client is documented as
needing to read `chunk_bytes` and tolerate null rather than hardcoding 8MB. Add a check to
`scripts/verify_deployment.py` that presigns a multipart upload against the deployed API, PUTs two
parts, completes it, and asserts (i) `chunk_bytes` is non-null and (ii) the completed object's size
matches the bytes sent.

**`CompleteMultipartUpload` is where S3-compatible services most often diverge from AWS, and it
fails *after* the data has been spent.** That is the argument for proving it against the deployed
API on demand rather than discovering it on a phone, on cellular, with a parent's video.

This tail is no longer "worth doing by hand". It is **one grep, now done, plus one specified
engineering task.**

* * *

## 3. ~~Fly and Docker — blocks deployment~~ — RESOLVED Aug 10, 2026. **The API is deployed.**

`https://rascal-api.fly.dev` serves, ~~`/health` returns `{"status":"ok","db":"ok"}`~~ —
**`/health` returns `{"status":"ok"}` and `/health/db` returns `{"status":"ok","db":"ok"}` as of
Aug 24, 2026 (phase 119); the evidence this section rests on was collected against the single
route and is not weakened by the split** — and `scripts/verify_deployment.py` passes **6/6**
against it — including the Tigris round trip
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
| `api/Dockerfile` *runs* | **executed, green** — non-root `rascal` (uid 1001), venv on PATH, binds `0.0.0.0:8080`, `/health` → `{"status":"ok","db":"ok"}` (that body is `/health/db` since phase 119, Aug 24, 2026; this row records Aug 8) |
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

* * *

## 4. `ANTHROPIC_API_KEY` — resolved. ~~Four batches~~ **Nine batches, 139 candidates** generated, awaiting your review

**No longer blocked.** The key is set as a repository secret, the *Prompt candidates*
workflow has run, and it opened a pull request that is now merged. ~~`docs/prompt-candidates/`
holds four worksheets~~ — **it holds nine, plus a `README.md`; the five dated 2026-08-22 are a
second sweep and are tabulated after this one** — the first four generated by `claude-sonnet-5`
against ~~the four thinnest themes in the
library~~ — **the four thinnest themes *as of Aug 4, 2026*; two of them are no longer thin, and the
correction is below the table**:

| File | Theme | Kind | Accepted |
|---|---|---|---|
| `fears-comfort-2026-08-04.md` | `fears-comfort` | question | 20 of 20 |
| `making-building-2026-08-04.md` | `making-building` | question | 20 of 20 |
| `outdoors-2026-08-04.md` | `outdoors` | question | 19 of 20 |
| `sleep-routine-2026-08-04.md` | `sleep-routine` | question | 20 of 20 |

All four batches are `question`, which is what `--thinnest` asked for and not a spread across
kinds. The activity, photo, video, and audio sides of those themes are still as thin as they
were; generating for them is another run with `--kind`.

> **Scoped to its date, Aug 22, 2026, because "the four thinnest themes" stopped being true when
> the library reached 133.** Counted today against `api/seeds/prompts.yaml` — group the 133 rows by
> `theme` — **the thinnest five are `fears-comfort` 2, `outdoors` 4, `me-as-a-parent` 5,
> `physical-affection` 5 and `seasons-holidays` 5.** Only two of the Aug 4 four are still down
> there. **`making-building` and `sleep-routine` are 6 each and are no longer thin**, which is the
> same fact the *"How it was unblocked"* subsection below already records against the dispatch
> numbers; it had not been carried up here to the sentence that generalises from them. The table
> stays as it is: it is the record of a run, and a run is dated.

**Status, ~~Aug 16, 2026: the 79 candidates are still unreviewed~~ — Aug 22, 2026: there are now 139
unreviewed candidates, and the second run did not wait for the review.** The owner was
reviewing the first 79 on Aug 16; nothing in this repository records that the review finished.

| Sweep | Files | Kinds | Candidates |
|---|---|---|---|
| Aug 4, 2026 | 4 | `question` ×4 | 79 (one `outdoors` row rejected out of 80) |
| Aug 22, 2026 | 5 | `question`, `video`, `question`, `audio`, `activity` | 60 (12 of 12 in every file) |
| **Total** | **9** | — | **139** |

**Keep both sets.** The Aug 22 worksheets are `fears-comfort-2026-08-22.md` (`question`),
`outdoors-2026-08-22.md` (`video`), `me-as-a-parent-2026-08-22.md` (`question`),
`physical-affection-2026-08-22.md` (`audio`) and `seasons-holidays-2026-08-22.md` (`activity`).
Counted from the files: each header reads *"12 of 12 candidates passed the automated filters"* and
each accepted table holds twelve rows.

**The second sweep targeted different themes on purpose, and that is the part not to lose.** It went
at the five themes that are thin *now* — the five in the note above — rather than repeating Aug 4's
four, because `making-building` and `sleep-routine` had ~~roughly doubled~~ **gone from 4 prompts
each to 6 — half again, not double; corrected Aug 22, 2026 from this section's own figures** in the
meantime. **And it is not all `question`.** ~~Three of the five kinds in the library are
represented~~ — **four kinds are, and the library carries seven kinds rather than five; corrected
Aug 22, 2026** — which is the `--kind` spread the paragraph below was still describing as future
work; the sentence *"all four batches are `question`"* is true of the Aug 4 table only and must not
be read across the whole directory.

> **Both numbers re-derived rather than trusted, Aug 22, 2026.** The Aug 22 row of the sweep table
> above reads `question`, `video`, `question`, `audio`, `activity` — **four distinct kinds, not
> three.** And `constants.PROMPT_KINDS` holds **seven**: `question`, `photo`, `video`, `audio`,
> `activity`, `measurement`, `letter`, every one of which appears in `prompts.yaml`. *"The five
> kinds"* was counting the daily ones — `letter` (8 rows) and `measurement` (3) are monthly.
> **So `photo` is not the only kind neither sweep has touched**: `letter` is in
> `services/candidates.py`'s `KIND_SHAPES`, can be generated, and has not been; `measurement` is
> the one kind `--kind` cannot be asked for at all. The two sentences below that called `photo`
> *"the one kind"* are corrected in place. The multiplier is the same arithmetic: the dispatch note
> at the end of this section records `making-building` and `sleep-routine` at **4** each on Aug 4
> and **6** each today, which is half again, not a doubling.

~~A second run with `--kind` — activity, photo, video and audio against the same four thin
themes — is wanted, and is **queued deliberately behind the review rather than beside it.**~~ —
**it ran on Aug 22, 2026 without waiting, and against five newly-thin themes rather than the same
four.** ~~`photo` is the one kind still unrepresented in either sweep.~~ — **`photo` and `letter`
both are, and only `photo` was named; corrected Aug 22, 2026, see the note above.**

**The reason is worth stating, because the efficient-looking order is the wrong one.** The review is
the only thing that calibrates the generator. If fifteen `outdoors` questions get cut for the same
reason, that reason belongs in `generate_prompts.py`'s filters or in `mission-library.md`'s
rejection rules **before** the next batch exists. Generating first means reading the same flaw twice
and paying for it twice.

> **Kept, and it is now a record of advice that was not taken. Aug 22, 2026.** The second sweep ran
> with the first still unread, which is exactly the order this paragraph argues against — so the
> risk it names is live rather than hypothetical: **if the 79 turn out to share a flaw, the 60 were
> generated before anyone could have known.** The argument is not struck because it was not
> refuted; it was skipped. Whoever reads the 139 should read the Aug 4 four first and let what gets
> cut there inform the Aug 22 five, which recovers most of the calibration the order gave away.

**The pool arithmetic that makes this worth doing at all:** ~~113~~ **133** seeded prompts, with
repeats beginning around day 31. ~~Adding 79 questions pushes that out — but only for questions. The
activity, photo, video and audio sides of those four themes stay exactly as thin as they are today,
which is what the `--kind` run is for.~~ — **Aug 22, 2026: it is 139 candidates now, and they are
not all questions.** The Aug 22 sweep put `video`, `audio` and `activity` batches into the
directory, so accepting all of them would widen four cadence pools rather than one. **`photo` is
still untouched by either sweep** and is ~~the one kind~~ **one of the two kinds** a `--kind` run
would still be for — **`letter` is the other; corrected Aug 22, 2026.**

> **Corrected Aug 22, 2026. The count has been wrong here since Aug 14, 2026**, which is the day
> phase 25 added twenty already-tokenised bodies on top of phase 24's 113 — `CLAUDE.md` says so in
> as many words, and `api/tests/test_seeding.py:35` asserts `TOTAL_PROMPTS = 133` against
> `api/seeds/prompts.yaml`, which holds 133 rows. **The "around day 31" figure was computed from
> 113 and has deliberately not been rewritten here**, because nobody has redone the arithmetic
> against 133 and a plausible new number invented at this desk would be worse than a stale one with
> its provenance attached. Whoever needs it recomputes it from the cadence pools.

**These are unreviewed.** Every candidate below passed the automated filters, and each file
says so in its own header: the filters are a spam trap, not an editor. They catch the four
rejection rules where the rule is textually detectable and nothing else. ~~**79 prompts still
need a human to read them.**~~ — **139 do, as of Aug 22, 2026: the 79 from Aug 4 and 60 more from
the second sweep.** One candidate was rejected, in `outdoors`, and the reason is
recorded in that file rather than discarded — **that is the Aug 4 `outdoors` worksheet; all five
Aug 22 files accepted 12 of 12.**

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
`thinnest: 4`, which picked the four themes above ~~(2, 4, 3, and 4 prompts in the library
respectively)~~ — **those were the counts on Aug 4, 2026; counted against `prompts.yaml` on Aug 22,
2026 they are `fears-comfort` 2, `making-building` **6**, `outdoors` **4**, `sleep-routine` **6**.**
Two of the four thin themes have since ~~roughly doubled~~ **gained two prompts each, 4 → 6 — half
again rather than double; corrected Aug 22, 2026 against the figures in the sentence immediately
above**, so `--thinnest 4` run again today would not necessarily pick the same four. The historical numbers are kept because they are what the run was
dispatched against. Two things came out of the first real run:

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

* * *

## Resolved since the last review

**Everything in the bulleted list immediately below** was on this list on Aug 3 and is now
closed. **That sentence used to say “everything below” without qualification, and it had quietly
stopped being true** — ~~three~~ ~~**four**~~ ~~**nine**~~ ~~**eleven**~~ **thirteen** `##` sections
further down are not closed. A reader skimming headings after this line would have read all of
them as resolved, which is the exact defect this file records against itself twice. Scoped to its
list, Aug 16, 2026.

> **The number was counted rather than incremented, Aug 22, 2026, and it had drifted by six.** The
> line said "four" and named four — Phase 16, §9, §10, §10a. Counting every `##` heading below this
> point that is not struck gave **ten**: Phase 16 (unrecorded), §9 (the one genuine platform
> block), §10, §10a, §11, §13, §14, §15, §16 and §18. This pass then struck §14, which phase 86 had
> resolved on Aug 18, leaving **nine**. **Both numbers are written here on purpose**: ten is what the
> file actually contained when it was audited, nine is what it contains now, and the difference is
> one section's worth of work rather than a correction. **The failure mode is worth naming, because
> it is not staleness** — a count in prose is maintained by whoever adds the next section, and
> nobody adding §11, §13, §14, §15, §16 or §18 came back up here to increment it. A count that
> six consecutive authors did not update is not a count; the only durable version of this sentence
> is one that says *how to count*, which is what this note now does.

> **And "nine" was wrong within the same pass, for two reasons the stated method catches and the
> author did not. Recounted and corrected to eleven, Aug 22, 2026.** The command is written against
> *this heading* rather than a line number, because the line number was stale before the pass that
> wrote it finished:
>
> ```bash
> sed -n '/^## Resolved since the last review/,$p' docs/blocked.md \
>   | grep '^## ' | grep -v '^## ~~' | tail -n +2
> ```
>
> ~~Today it prints, in file order: **Phase 16, §9, §10, §10a, §11, §13, §15, §16, §18, §19 and
> §20** — eleven.~~ — **struck Aug 25, 2026 by phase 122, which ran the command rather than reading
> the figure.** It prints, in file order: **Phase 16, §9, §10, §10a, §11, §13, §15, §16, §18, §19,
> §20, §21 and §22** — **thirteen**.
>
> **Both intervening numbers are written here on purpose, exactly as ten and nine were above.**
> When this pass audited the file the command printed **twelve**: *"eleven"* had drifted by one
> within three days of being written, because **§21 arrived in the same Aug 22 pass, from a
> different phase, and nobody came back up here to increment it** — precisely the failure the note
> above this one diagnoses in six consecutive authors, committed by the pass that diagnosed it and
> inside the paragraph naming the habit. Then this pass filed **§22** and made it **thirteen**, so
> the difference between twelve and thirteen is one section's worth of work rather than a
> correction. **The figure is written down anyway, because the command beside it is the part that
> survives the next author: run the command, do not quote the number.**
>
> **What moved it.** *First*, this pass moved four resolved iOS sections down here, and three of
> the four carried struck headings while **iOS Settings did not** — so the method counted a section
> whose own heading says *"Nothing in this section is open"* as open. Rather than write the number
> with an exception attached, **its heading is now struck like its three siblings'**, which is the
> only edit made in that move and is noted where the move is described. *Second*, **§19 arrived
> from `origin/main` in the merge that preceded this pass** (phase 108, `09acfa6`) and is a genuine
> open blocker, and **§20 is new below**, filed by this pass. **Neither of those is drift and both
> are why a hand-maintained count is the wrong artifact**: the first correction blamed six
> consecutive authors for not incrementing, and then the very next number was falsified by a merge
> and by its own author in the same sitting. **Run the command; do not read the number.**

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

**Closed Aug 11, 2026 by phase 19 (PR #48)** — the three iOS workarounds this file had been
carrying as "unblocked, unstarted":

- `unsealIfTheServerSealedItAnyway` and its corrective `PATCH` (§iOS Seal control).
- `TimelineModel.drain`'s paging loop, `clientFilterPageBudget`, `isClientSideOnly` and
  `PageResult` — the Sealed chip is a server filter now (§iOS Timeline v3).
- The local `Assignment` lookup in the timeline card's quote resolution (§iOS Timeline v3).

Each deletion was authorised by exercising the server behaviour against a running API rather than
by reading this file. **One of those checks initially failed and was wrong to**: the local API
process predated the Lane A fix by 35 hours and was running without `--reload`, so it was serving
code older than the commit under test. Restarting it flipped the result. **A preflight that
exercises a long-running local server has to first establish that the server is the code under
test.**

~~**Still unstarted, and not blocked:** onboarding does not ask for pronouns (tracked by
`docs/decisions.md` item 10) and the avatar is still device-only (§iOS Onboarding).~~ — **both
shipped, and this line was the last place in the repository still saying otherwise. Struck Aug 22,
2026.**

Verified by reading the iOS tree rather than by asking it: `ChildSetupFlow.swift`'s own header
lists the steps as *"name, birthdate, pronouns, timezone, avatar, notifications"* and `:49` routes
`case .pronouns: PronounsStep(session: session)`. The avatar half is
`ios/Rascal/Rascal/Onboarding/` holding `AvatarStep.swift`, `AvatarStore.swift`, `AvatarSync.swift`
and `AvatarUpload.swift` — the upload seam this file specified, built.

**`docs/roadmap-status.md` struck exactly these two bullets on Aug 18, 2026 and this page never
followed** — they are the pair under *"Two onboarding gaps remain"* in its *§ Phase 8, precisely*:
*"The avatar is still device-only"* and *"Onboarding still does not collect pronouns"*. That is the
failure worth recording rather than the four-day lag: the two documents describe the same two facts and neither of them points at the other, so a correction
landing in one is invisible from the other. The durable fix is not diligence, it is a single owner
per fact — `roadmap-status.md` owns shipped-status, and this file should cite it rather than
restate it. **And cite it by its text.** This sentence carried `docs/roadmap-status.md:348-349`
until Aug 22, 2026; that file has been edited since, `:348` is a note about the highest merged
phase today, and the two bullets are nowhere near it. **A quoted bullet survives an edit above it
and a line number does not**, which is the same reason this phase converted the other numbered
citation on this page. `docs/decisions.md` item 10 remains the tracker for the *rendering* half
(pronoun substitution in prompt bodies), which is a separate piece of work and is still open.

---

**The four sections below were moved here on Aug 22, 2026 by phase 111, eleven days after the
habit that says to do it was written down at the top of this file.** iOS Seal control, iOS
Onboarding, iOS Timeline v3 and iOS Settings were the **first four `##` headings in a document
titled "blocked"**, and all four were resolved — two closed outright by phase 19 (PR #48) on
Aug 11, 2026, one whose own heading reads *"Nothing in this section is open"*, and one whose two
remaining follow-ups shipped and are struck a few paragraphs up.

**Nothing in them was edited in the move, with one exception, named here rather than left for a
reader to find in a diff.** Every strikethrough, every grep, every line reference
and every *"the original entry follows"* is exactly as it was — the reasoning is usually why a fix
is shaped the way it is, and that survives being filed correctly. **Only the position changed, and
the position was the defect**: a reader skimming this file for what is stuck met three hundred and
twenty lines of finished iOS work first, and the strikethroughs that said so are invisible to a
heading skim.

**The exception is iOS Settings' own `##` heading, struck Aug 22, 2026.** It was the only one of
the four that arrived unstruck, and the sentence above is the reason it could not stay that way:
the strikethroughs are what a heading skim reads, and the count two sections up is generated by
literally that skim — `grep -v '^## ~~'` — so an unstruck heading on a section whose own first
words are *"Nothing in this section is open"* made the file's stated counting method disagree with
the file's own text. **The heading was struck rather than the number annotated**, because a count
with a written-in exception is a count nobody can re-derive. Its body is untouched.

* * *

## ~~iOS Seal control — `POST /entries` cannot hear "do not seal this"~~ — RESOLVED, verified Aug 11, 2026

**Built.** `routers/entries.py` now passes the field's *setness* down, exactly as this section
asked:

```python
# api/src/rascal/routers/entries.py:71
unlock_at_age_provided="unlock_at_age" in payload.model_fields_set,
```

and `services/entries.py:431` reads `if unlock_at_age is None and not unlock_at_age_provided and
prompt is not None:` — so an explicit null now means "not sealed" and an absent key still keeps the
prompt's default. The two routes agree about what null means.

**The client-side workaround is gone too, as of Aug 11, 2026 (PR #48, phase 19 item 1).**
`unsealIfTheServerSealedItAnyway` and its corrective `PATCH` are deleted; a create is one request.
Phase 19 did not take the server behaviour on trust — it exercised it against a running API on a
`letter` prompt with `default_unlock_age = 13`, and an explicit null returned `null` while the same
body with the key removed returned `13`. **`EntryCreateRequest`'s hand-written `encode(to:)` stayed**,
because sending the explicit null is what makes the server's answer correct; it reads like dead
ceremony and is the opposite.

**Nothing on this section is outstanding.** It is here for the reasoning, not as work.

The original entry follows, because it is the reason the fix is shaped the way it is.

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

* * *

## ~~iOS Onboarding — the avatar has nowhere to go, and pronouns have nowhere to live~~ — BOTH RESOLVED IN LANE A, verified Aug 11, 2026

**Both columns and both routes now exist. Neither has an iOS client yet**, which is the whole of
what is left, and it is unstarted rather than blocked.

**The avatar presign pair is built**, and it is the shape this section specified:

- `POST /children/{child_id}/avatar-upload-url` — `routers/children.py:117`, "one presigned PUT —
  never multipart, because an avatar is a small square".
- `GET /children/{child_id}/avatar-url` — `routers/children.py:151`, and it **404s when the child
  has no avatar** rather than returning a null URL, on the stated grounds that "this child has no
  avatar" and "here is a URL that will not resolve" are different answers.

**`children.pronouns` exists** — `models/child.py:25`, `text` + a named CHECK via
`one_of("pronouns", PRONOUNS, name="pronouns")`, and it is on `ChildCreate`/`ChildUpdate`/`ChildOut`
(`schemas/child.py:20`) and written by `routers/children.py:80`. `constants.py:67` already
anticipates the consumer: pronoun substitution in prompt bodies.

**What is left is two unstarted iOS tasks, and they belong to different phases.** Neither is
blocked; both are listed here only so the trail from the Lane A build to the client work survives.

- ~~**Onboarding does not ask for pronouns.** `ChildSetupFlow.swift` mentions them only in a
  comment.~~ — **shipped.** `ChildSetupFlow.swift:49` routes `case .pronouns: PronounsStep(...)`.
- ~~**The avatar is still device-only.** `AvatarStore.swift`'s header comment still reads "nothing
  mints one", which was true when it was written and is not now.~~ — **both halves shipped.** The
  upload landed in phase 21, and that header was rewritten with it: it now opens by saying the file
  *"used to say that nothing minted one, which was true when it was written and stopped being true
  when Lane A built the pair."*

**Struck Aug 23, 2026 by phase 115, and the interesting part is not the lag.** The block at the top
of this file struck these same two facts on **Aug 22** with the words *"this line was the last place
in the repository still saying otherwise"* — and these two bullets, in this file, outlived that
sentence by a day. **A correction that asserts it is the last one is a claim about a document it did
not search**, which is the same failure one level up: `roadmap-status.md` struck these bullets on
Aug 18, this page did not follow, the Aug 22 entry noticed the lag and then reproduced it. The
remedy that entry proposes — one owner per fact, cite rather than restate — is right, and it is
worth noting that writing it down did not cause it to happen. **Phase 115 found them by grepping
`docs/` for `avatar` before touching the client, not by reading this section**, which is the only
method that has actually worked on this file.

> **A note on phase numbers, because two of them collide.** An earlier plan assigned pronouns to
> "phase 20" and the avatar to "phase 21". **Phase 20 has since shipped as something else** — the
> nine TestFlight defects, PR #47 — and it explicitly held pronouns and the avatar out of scope
> while editing `ChildSetupFlow.swift` for other reasons. So neither of these has a phase number
> any more. `docs/decisions.md` item 10 tracks the pronouns half; the avatar half is tracked here
> until something claims it.

The original entry follows.

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

* * *

## ~~iOS Timeline v3 — two things the list endpoint cannot express~~ — BOTH RESOLVED IN LANE A, verified Aug 11, 2026

**Both were built and neither was marked here.** The client still carries the workarounds each one
was written to justify, and both can now go.

- **`EntryOut.prompt_body` exists** — `schemas/entry.py:119`. So a list row carries its own quote,
  and the two-direction workaround (the composer writing `assignment.body` onto the row, plus the
  local `Assignment` lookup) is no longer load-bearing. The case this section said only the server
  could fix — *an entry written on another device, or before this build, shows no quote until the
  parent opens it once* — is fixed.
- **`?sealed=` exists** — `routers/entries.py:109`, `true` for sealed only, `false` for unsealed
  only, omitted for both, and its own description makes the point this section made: "Sealing is
  not an `entry_type`". So the Sealed chip can be a server filter.

**Both iOS halves shipped Aug 11, 2026 (PR #48, phase 19 items 2 and 3).** The Sealed chip sends
`?sealed=true`; `TimelineModel.drain`'s paging loop, `clientFilterPageBudget`, `isClientSideOnly`,
`PageResult` and the "reports what it found rather than what exists" caveat are deleted, and the
local `Assignment` lookup is gone from the card's quote resolution. `drain` itself stayed — it is
the paging entry point both callers use, and the loop inside it was the workaround, not the seam.

**The paging-seed warning below was right, and it caught a real bug.** Phase 19 verified the
`?sealed=` filter against a running API before deleting anything — 7 sealed rows of 754, pure in
both directions, paging across three cursor pages with no repeats — and then found that
`oldestCachedOccurredAt()` seeded page two from the oldest cached row of *any* kind. Correct while
the request was unfiltered; silently wrong with `?sealed=true`, where it would skip every letter
between the newest and the oldest cached entry. Fixed and pinned by a test that fails by ~600
million seconds when reverted. **The inherited constraint was load-bearing in a way nobody had
re-derived, which is exactly what this paragraph existed to force.**

**Nothing on this section is outstanding.**

The original entry follows.

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

* * *

## ~~iOS Settings — notes, not blockers. **Nothing in this section is open.**~~ — NEVER A BLOCKER, and struck Aug 22, 2026 so the heading says so to a skim

**This section has never held a blocker and should be read as a lessons file.** It has three
entries: `GET /me`, resolved Aug 9 in PR #24; the export progress bar needing a session delegate,
which was fixed and is recorded only because it is invisible in code review; and a note that
`POST /v1/auth/dev-login` cannot satisfy a preflight aimed at a deployed API — which is not a
defect but advice about how to write preflight checks.

So Settings' contribution to this file is **one fix and two notes**. It is kept under this
filename only because moving it would break the links into it; a reader scanning headings for
"what is blocking me" should skip it entirely.

The only Settings work genuinely outstanding is the **pronouns row**, and it arrives from
`docs/decisions.md` item 10 rather than from here.

Neither of the two notes blocks the Lane B Settings work, which shipped complete. Recorded because
both were discovered by building against the merged API and neither is written down anywhere else.

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
the client degrades correctly without it. Item 6 of `docs/Device-Verification/device-verification-settings.md` asks
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

---

* * *

## ~~Phase 22 — Entry Detail v2: two design questions that are not the agent's to answer~~ — RESOLVED, all three, confirmed by the owner Aug 16, 2026

Owner, Aug 16: *"22 is long done and perfect in all of these."* The phase merged as **PR #54** —
`docs/roadmap-status.md`'s phase ledger, under *§ The iOS build, phase by phase*: *"22 — Entry
Detail v2 | The screen rebuilt against its own design export. Full-bleed media, the cream sheet,
per-shape backdrops | #54 | ✅ merged"*. **Cited by its text since Aug 22, 2026** — the
`docs/roadmap-status.md:219` that stood here points at a blank line in that file today. Moved here
rather than struck in place, per this file's standing habit: **a struck section is not a moved
section.**

**The three outcomes:**

1. **Full-bleed media on Entry Detail: YES**, and scoped to exactly one screen. Entry Detail is the
   one place media may bleed to the edge. **The timeline never does** — the rejection in
   `docs/decisions.md` is untouched and stays untouched. Already recorded in
   `docs/design-system.md` at *"The one screen where they do bleed is Entry Detail — settled
   Aug 11, 2026, phase 22"*, and now carried into `docs/decisions.md` as a settled row so the next
   importer cannot re-derive the argument from first principles.
2. **Frosted glass: resolved toward the design project's `readme.md`** — opaque `surface`, hairline,
   resting shadow, **no blur**. Frosted-glass panels are not part of this brand. The export
   contradicted its own README and the README won.
3. **`KindBadge` contrast (~3.3–3.7:1, below AA): accepted as-is**, per the owner. This is an
   **accepted exception, not an open item.** `#5566D6` on `#E9EBFB` is the pairing to measure first
   in any *new* surface — the exception covers the component as it stands, not the pattern
   everywhere.

The original entry follows, because the reasoning is why the screen is shaped the way it is.

---

### The original entry, Aug 11, 2026

Not blocked on a credential. Blocked on a **design decision**, which is why the phase stopped with
an inventory rather than a screen. Full analysis: `docs/entry-detail-inventory.md`.

#### 1. Is full-bleed media allowed on Entry Detail? ~~**Blocking.**~~ **Answered: yes, this screen only.**

The whole grammar of the import is *"Media fills the screen. Everything else lives in a cream sheet
resting on top of it."* Against that:

- `docs/design-system.md`, Layout: *"Photos sit inset with padding and rounded corners; **they
  rarely bleed to the screen edge**."*
- `docs/decisions.md`, Rejected — do not revisit: *"Full-bleed edge-to-edge photo **timeline** as
  the primary view."*
- `docs/decisions.md`, Settled: *"Timeline is a scannable date-grouped card list… **Not a full-bleed
  story feed.**"*

**Both rejections name the timeline, not the detail screen, and "rarely" is not "never."** So it is
not a literal conflict — Entry Detail is plausibly the rare case, and it is the one screen whose
entire job is looking at one artifact. But it is one step from a twice-rejected direction, on the
screen the phase brief calls *"in 2040, this is the product."*

**What is needed: yes or no.** Everything else in the import is downstream of it — the sheet, the
scrim, where the prompt and transcript live, and whether the metadata compresses to one line.

#### 2. Frosted glass — the export contradicts its own design system. **Answered: the README wins.**

Every sheet is `background: rgba(253,250,244,.88); backdrop-filter: blur(26px) saturate(1.25)`,
while the design project's own `readme.md` states: *"Transparency & blur — used in exactly two
places… **Frosted-glass panels are not part of this brand.**"*

Resolved toward the README (opaque `surface`, hairline, resting shadow, no blur) — but recorded
because it changes how the sheet reads over a photo and is coupled to question 1.

#### Carried forward at the time — both now closed

- ~~**Paper grain.**~~ **CLOSED Aug 11, 2026.** Settled as rejected and written into
  `docs/decisions.md` in the words the exports actually use (`feTurbulence`, "paper grain"), because
  the existing "screen-print texture" line is what three importers in a row read past. The exports
  will keep carrying it; that is a property of their design system, not a new argument.
- ~~**`KindBadge` contrast** (~3.3–3.7:1, below AA).~~ **CLOSED Aug 16, 2026 — accepted as-is by
  the owner**, as a recorded exception rather than a defect to fix. The import does not reuse the
  component, but its chips are the same shape of pairing — `#5566D6` on `#E9EBFB` is the one to
  measure first in any new surface.

---

* * *

## ~~Push notifications — signing now needs the Push capability~~ (Phase 14, Aug 10 2026) — UNBLOCKED Aug 11, 2026

**Enrollment cleared, and the entitlements file has the registration in it.**
`ios/Rascal/Rascal.entitlements` now declares all three things a device build needs, and they were
committed rather than left for Xcode to re-add:

```
aps-environment                     development
com.apple.developer.applesignin     Default
com.apple.security.application-groups   group.com.travisterry.childarchive
```

That closes the note in §1 asking for the Sign in with Apple entitlement to be let in and committed
— it is in. `aps-environment` reading `development` in the file is correct and not a bug: Xcode
substitutes `production` when it archives for distribution, which is why a TestFlight build
registers a production token. See §1a.

**What remains is not signing.** It is the APNs key and the scheduled machine in §1a, and
`docs/Device-Verification/device-verification-push.md` — which is no longer blocked on both open items, because both
are closed. It is runnable as soon as the key exists.

The original entry follows.

**What changed.** `ios/Rascal/Rascal.entitlements` gained `aps-environment`. Without it
`registerForRemoteNotifications()` fails on a real device with "no valid aps-environment
entitlement string found for application", no token is minted, and — because registration
failure is deliberately silent — nothing anywhere says why. Neither the simulator nor the test
suite can catch its absence, so it had to be added on the strength of reading rather than of a
failing test.

**What it blocks.** Signing a build now requires a provisioning profile whose App ID has the
**Push Notifications** capability enabled. That needs the Apple Developer Program enrollment that
has not yet cleared. Unsigned simulator runs — which is how the suite runs,
`CODE_SIGNING_ALLOWED=NO` — are unaffected, so nothing that works today stops working.

**Also blocked on this.** `docs/Device-Verification/device-verification-push.md` cannot be started at all: it needs
enrollment *and* a deployed API, because APNs pushes come from Apple to a server rather than from
a local machine. It is the first checklist in the project gated on both.

**Not blocked.** The client code is complete and its suite is green. Nothing here is waiting on a
decision — only on a credential.

**One thing for Lane A.** `api/src/rascal/schemas/device.py` describes `sandbox` as covering "a
development or TestFlight build". That is wrong: TestFlight is signed with a distribution profile
and addresses the production APNs host. It is a description string with no behaviour attached, so
it is recorded here rather than fixed across lanes.

---

* * *

## ~~Phase 17 (structured extraction) — the API cannot record a tag's source~~ (Aug 10 2026) — RESOLVED Aug 11, 2026

**Unblocked by PR #45 and the phase then shipped as PR #43.** The API change is the one this
section specified rather than the narrower alternative: `schemas/entry.py` now takes a tag on the
wire as `"beach"` **or** `{"name": "beach", "source": "device_ai"}`, with `source` defaulting to
`user` — the file says so in as many words at line 23, "a bare string still means exactly what it
meant before", so no existing client changed.

The reasoning that made this a hard gate held up and is worth keeping: writing model tags as `user`
is unrecoverable, because the information needed to undo it is never stored.

**Still true, and it is the next thing this feature needs:** the model behind the seam has run zero
times. `docs/Device-Verification/device-verification-extraction.md` records **0 of 19** checkboxes, and its own opening
says `SystemLanguageModel.default.availability` has never returned `.available` on anything here.
That is a device checklist, not a blocker.

The original entry follows.

**Not started. No code was written.** This is the phase's own Phase A gate, and it is a hard one.

`PATCH /v1/entries/{id}` cannot write a tag with `source = 'device_ai'`. `EntryUpdate.tags` is a
bare `list[str]`, and `services/entries.py` hardcodes `apply_tags(session, entry, tags, "user")`
at both entry write paths. The `entry_tags.source` column exists and `apply_tags` honours it
correctly — the gap is only that no entry endpoint lets a caller name the source.

`PATCH /media/{id}/derived` does write `device_ai`, but it is keyed on a media row, and phase 17
is scoped to entry *bodies*. A text-only entry has no media to address.

**Why this stops the phase rather than being worked around:** writing model tags as `user` is
unrecoverable. Once the two are indistinguishable no re-run can safely touch them, a hand-deleted
model tag must resurrect, and a parent cannot tell which tags are theirs. The information needed
to undo it is never stored.

**The API change needed (Lane A):** let a tag write carry its source — `EntryCreate.tags` and
`EntryUpdate.tags` accepting `{ name, source }` alongside a bare string, with `source` defaulting
to `"user"` so existing clients are unaffected, and `update_entry` grouping by source and calling
the existing `apply_tags` once per group. `apply_tags` already refuses to let a `device_ai` write
clobber a `user` row, so no new merge logic is required. A dedicated
`PATCH /v1/entries/{id}/derived` mirroring the media one is the narrower alternative.

Full detail, including the exact source lines: `docs/phases/phase-17-BLOCKED.md`.

---

* * *

## ~~§12 — Google sign-in has no client id, so phase 55 cannot be built~~ — RESOLVED Aug 16, 2026

**Closed the same day it was written.** The owner created the Google Cloud project and the iOS
OAuth client; `GOOGLE_CLIENT_IDS` is set on Fly and applied on the phase-54 deploy. The client
id is wired into `.env`, `.env.example` and both xcconfigs, and phase 55 shipped against it.

**Verified in production by the check this section prescribed**, which is the useful part:
`POST /v1/auth/google` with a junk token answers `401 unauthenticated` — *"Google identity
token is malformed"* — rather than `422 … GOOGLE_CLIENT_IDS is unset`. The message no longer
names the setting, which is how you know the setting took.

- [x] Project created
- [x] Consent screen configured, `openid email profile` only
- [x] iOS OAuth client id created
- [x] `GOOGLE_CLIENT_IDS` set on Fly
- [x] `POST /v1/auth/google` returns `401` rather than `422`

**What is still unverified, and it is not a credential problem:** no Google sign-in has ever
been attempted against real Google from a real device, because there is no TestFlight build
path. The original section is kept below for the reasoning and the steps.

### The original entry

**The server half shipped as phase 54 and works. The phone half cannot be started**, and the
reason is an account action rather than a design question.

**What is missing.** There is no Google Cloud project, so there is no OAuth client id, so
`GOOGLE_CLIENT_IDS` has no value to hold. `POST /auth/google` answers `422` naming the setting —
deliberately, so that an unconfigured server says *the setting is unset* rather than rejecting
every real token as unverifiable. A sign-in button on the phone built against a client id that
does not exist is a button that cannot work, and shipping one would be the same class of thing
this project keeps refusing: furniture that permanently reads "0 waiting".

**What it takes, and all of it is yours.**

1. Create a project at `console.cloud.google.com`.
2. Configure the OAuth consent screen. **External**, and it can stay in *Testing* — a private
   family archive does not need verification, and Testing allows up to 100 named test users.
   Scopes: `openid`, `email`, `profile` and **nothing else**. This is identity only; a Drive or
   Workspace scope would be a different product.
3. Create credentials → OAuth client ID → **iOS**, bundle id `com.travisterry.childarchive`.
   That yields a client id of the shape `<numbers>-<hash>.apps.googleusercontent.com`.
4. `fly secrets set --app rascal-api GOOGLE_CLIENT_IDS="<the client id>"`.

Add a second value, comma-separated, if a web client ever needs one — the setting has been a
list since the day it was added, for the same reason `APPLE_BUNDLE_ID` became one in phase 51.

- [ ] Project created
- [ ] Consent screen configured, `openid email profile` only
- [ ] iOS OAuth client id created
- [ ] `GOOGLE_CLIENT_IDS` set on Fly
- [ ] `POST /v1/auth/google` with a junk token returns `401` rather than `422` — which is how you
      know the setting took, because the message stops naming it

**One decision the phase asked for is already made, so it does not block on you.**
`ASWebAuthenticationSession` + PKCE, **not** the GoogleSignIn SDK. More code, no SPM dependency,
and no third-party privacy manifest to reconcile against an app whose whole promise is that a
child's record does not go anywhere. This is the one place in the queue where "boring" and "no
dependency" disagree, and for a private child archive the dependency is the thing worth spending
code to avoid. **Sign in with Apple stays the primary button and stays visually first**; Google
is secondary.

**Not urgent.** Google exists for a household that does not have an Apple device — which the
only current household does. It gates **phase 36** (the guardian invite flow), because a second
parent who cannot accept an invite has not been invited.

---

* * *

## ~~§14 — `entry_type` is provisional for as long as an upload is, and permanent if the upload dies~~ (Aug 18, 2026) — **RESOLVED Aug 18, 2026 by phase 86. Struck Aug 22, 2026, four days late.**

**The owner ruled for shape 1 — recompute at plan time — and it shipped the same day this section
was written.** Commit `a1b25b8`, *"Phase 86: entry\_type follows the media, not the bytes"*, merged
as **PR #137** on Aug 18, 2026.

**This section's central factual claim is false against the current tree, and has been since that
merge.** It says `plan_upload` does not call the recompute. Counted today, `retype_owning_entry` has
four call sites:

| Call site | What it is |
|---|---|
| `api/src/rascal/services/media.py:130` | `plan_upload`, single-PUT return path |
| `api/src/rascal/services/media.py:158` | `plan_upload`, multipart return path |
| `api/src/rascal/services/media.py:208` | `complete_upload` — kept, and its comment now says why: `bytes` and `duration_seconds` may have moved, and rows created before phase 86 were never typed at plan time |
| `api/src/rascal/services/sync.py:352` (in `_apply_media`) | the push-delete path, the only route that removes media |

Both of `plan_upload`'s exits call it. **The dead-upload case this section was written about —
an entry whose recording never uploads staying `did_it` for the life of the archive — cannot
happen any more**, because the type is written when the server first learns the media row exists
rather than when its bytes land.

> **The fourth call site was drafted as `sync.py:352`, "corrected" to `:316` mid-phase, and is
> `:352`.** `grep -n retype_owning_entry api/src/rascal/services/sync.py` answers `350` (a deferred
> import) and `352` (the call); `316` is a blank line. **The correction asserted a `grep` that was
> never run, and it overwrote a right answer with a wrong one inside the very section being struck
> for carrying a stale line reference.** It survived one adversarial audit and was caught by a
> second. Recorded rather than quietly reverted, because the failure is not the wrong number — it
> is that a confident citation is indistinguishable from a verified one once it is written down.
> **Line numbers are the least durable evidence this file uses**; the symbol and the file are worth
> more, and both are given above.

**Why this sat open for four days, which is the part worth keeping.** Phase 86 shipped the code and
did none of the bookkeeping: no row in `docs/roadmap-status.md`, no entry in
`docs/decisions-log.md`, and `docs/data-model.md`'s `entry_type` row still described the column as
*"denormalized from the prompt for filtering"*. **That last one is the dangerous one and it is not
a tidiness complaint**: `CLAUDE.md` says that when the code and `data-model.md` disagree, *the code
is wrong* — so a false sentence there is a standing authorisation for the next agent to "fix"
correct code back to the behaviour phase 86 deliberately changed. **All three were done in phase
111 alongside this strike**, and `data-model.md` now states the derivation rule and says a media
row counts from the moment it exists rather than from the moment its bytes land.

**The client half never waited on any of it.** Phase 80 made the detail screen prefer local staged
bytes over the server's type, so *"Nothing was recorded"* could not appear over a recording that
exists — and that remains the right division: the screen should not have been trusting the server's
type for that question in the first place.

The original entry follows, because the two shapes it lays out are why the ruling went the way it
did.

### The original entry, Aug 18, 2026

**Not blocked, not a bug report, and not an errand. It is a contract question that needs one
decision, and it is API-lane.** Raised by the iOS lane during phase 80, verified against `main`
here before being written down.

**What is true today.** `plan_upload` (`api/src/rascal/services/media.py:79-87`) inserts the server
side `Media` row with `upload_status="pending"` and **does not** call `refresh_entry_type`. The
recompute happens only in `complete_upload` (`:175`), whose comment says exactly what it is doing:
*"The entry's type was provisional until now."* So between planning an upload and completing it,
an entry that has a recording attached is still typed `did_it` — outside the Voice filter, outside
the Photos filter, and described as an entry with no artifact while the bytes sit on the phone.

**The window is normally short and self-healing**, and an earlier version of this finding claimed
it was permanent for every offline entry — that was wrong and was retracted before it reached this
page. `complete_upload` does recompute, `api/tests/test_media.py:345` asserts it
(`test_completing_an_upload_turns_a_did_it_entry_into_a_media_entry`), and the phone re-reads the
type on the next successful fetch.

**The part that is real: an upload that never completes never closes the window.**
`MediaCoordinator.finishUpload` exhausts its backoff ladder and sets `media.state = .failed`
(`ios/Rascal/Rascal/Media/MediaCoordinator.swift:220`). `POST /media/{id}/complete` is then never
called, `refresh_entry_type` never runs, and **the entry stays `did_it` for the life of the
archive** — with a recording that exists, on a phone, that no filter will ever surface.

**The change that would close it, and why it is a decision rather than a fix.** `plan_upload` could
call `refresh_entry_type` at insert time. `derive_entry_type` (`services/entries.py:311`) does not
filter on `upload_status` — its first rule is *"Media attached → the media kind"* — so it would
already answer `audio` for a pending row, with no change of its own. **But that makes `entry_type`
describe a row whose bytes are not in storage yet**, and possibly never will be. That is a change
to what the column means, and `data-model.md` is authoritative about it, so it wants a decision
rather than a patch. The two shapes:

1. **Recompute at plan time.** The type tells the truth from the first moment the server knows a
   recording exists. Cost: a `GET /entries?type=audio` can return an entry whose media 404s at the
   URL step, and a Voice filter can show a take that never arrives.
2. **Leave it at complete time and heal the dead-upload case another way** — a sweep that retypes
   entries whose media has been `pending` beyond some age, or a client that stops trusting the
   server's type for this question.

**The client half is already done and does not wait on this.** Phase 80 made the detail screen
prefer local staged bytes over the server's type, so *"Nothing was recorded"* can no longer appear
over a recording that exists. **That is the right division and it is worth stating: the screen
should not have been trusting the server's type here in the first place.** This item is only about
whether the *server's* answer should also be right.

**Whoever takes this owns the `data-model.md` sentence too**, not just the call site. — **Phase 86
took the call site and left the sentence, which is exactly what this line was written to prevent.
Phase 111 is doing the rest.**

---

* * *

## ~~§17 — Gemini video: an **errand**, and the error names the wrong thing~~ (Aug 20, 2026) — **RESOLVED Aug 21, 2026. Billing is enabled and a clip has been generated.**

**The subject of this section was deleted on Aug 25, 2026, and that is the last thing that will
ever happen to it.** Phase 120 (`01318be`, PR #170) removed `services/social/gemini.py`,
`services/social/stitch.py` and all three `GEMINI_*` settings — `ls api/src/rascal/services/social/`
prints nine files and neither of the two is among them. Claude now writes a typed scene graph, the
console's own browser draws and records it (`admin/static/cards.js`), and ffmpeg re-encodes the
recording (`services/social/transcode.py`). **There is no billing to check, no model to switch and
no errand left in here** — do not read one out of it. It is kept because its *finding* outlived its
subject: a blocker can name the right credential, be right about it, and still not be the last
thing in the way, and the safety refusal recorded below is now part of the argument *for* owning
the renderer. **The one thing phase 120 did leave for you is in §22**, and it is three Fly secrets
nothing reads.

**Closed by phase 106.** Billing was enabled on the key's project, and the render path has now
seen a 200: a four-second Veo 3.1 Lite clip came back as a **416KB MP4** in about ninety seconds.
The last paragraph of this section — *"one thing is genuinely unverified"* — is the one that
closing this actually settles, and it is settled by running it rather than by the billing flip.

**What the first successful render found, which is the part worth carrying forward.** Enabling
billing did not make the feature work; it made the *next* problem visible, and that problem was
not a credential:

- **Omni Flash refused the product's own copy.** The first render past billing rejected **shot
  three of a real Vellum treatment as "harmful content"** — a static shot of a photograph,
  captioned *"Why did you take this one?"*. There is nothing to appeal and nothing to rephrase
  around; a safety filter that refuses a still life is not one this product can plan around.
- **Every Veo 3.1 tier accepts the identical prompt**, byte for byte. So the default moved to
  `veo-3.1-lite-generate-preview`, which is also **half the price** ($0.05 a second against
  $0.10), ~~and Omni Flash stays reachable by setting `GEMINI_VIDEO_MODEL`~~ — **struck Aug 25,
  2026 by phase 122: neither model is reachable by setting anything.** Phase 120 deleted
  `GEMINI_VIDEO_MODEL` along with the client that read it, and `grep -n -i gemini
  api/src/rascal/config.py` returns nothing.
- **Two more things only the live API said**, both now pinned in tests: the clip URI Veo hands
  back already carries `?alt=media`, and passing `params=` to httpx *replaces* the query rather
  than merging it — which silently turns the download into a 400. **Every mocked test passed with
  that bug.** And Veo returns **landscape** unless `aspectRatio` is sent, which produced a
  1280×720 clip for a vertical treatment — not a smaller mistake than failing.

**The general shape of this entry, which is why it is not simply deleted:** it was filed as a
billing errand, the billing diagnosis was correct, and the errand was still not the last thing in
the way. **A blocker that names a credential can be right about the credential and wrong about
being the blocker.** The original entry follows.

### The original entry, Aug 20, 2026

`GEMINI_API_KEY` is set and works. Video still refuses, and it will keep refusing until billing
is enabled **on the project that key belongs to**.

**What was verified against the live API**, rather than read in docs:

- The key is valid — `GET /v1beta/models` returns 50 models, and text generation answers 200.
- Both video families refuse with **429** carrying
  `generate_content_free_tier_requests, limit: 0, model: gemini-omni-flash`.
- Veo answered **400** before it answered 429, which proved two things: the quota check happens
  after validation, and **`durationSeconds` must be a number, not the string Google's own docs
  show**.
- `veo-3.0-*` and `veo-2.0-*` are **absent from the model list** — the June 30, 2026 shutdown
  is real, whatever the pricing page still says.

**The fix is not code.** Enable billing on the key's project and confirm the tier at
[ai.dev/rate-limit](https://ai.dev/rate-limit). Credits attached to a different Google Cloud
project will not move this. **Nothing else in the console is affected** — the render button is
the only thing that needs it, and it refuses with the sentence above rather than failing oddly.

~~**Until then one thing is genuinely unverified**: `services/social/gemini.py` has never seen a
200, so the response-shape walk is written from documentation. It is built to raise on an
unrecognised shape rather than write an empty file, which turns that risk into a loud error
instead of a silent one — but the first successful render is still the real test.~~ — **that test
was run on Aug 21, 2026 and this paragraph called it correctly.** The shape walk written from
documentation was wrong in two places, both caught loudly rather than silently: the download's
query string and the missing aspect ratio, above. **The refusal-on-an-unrecognised-shape design is
what turned a documentation error into a 400 with a sentence instead of an empty MP4 in the
bucket**, which is the one claim in this section that was load-bearing and is now evidence.
