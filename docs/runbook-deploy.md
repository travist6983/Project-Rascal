# Deploying RASCAL — the whole thing, in order

**This is the procedure.** Follow it top to bottom and you end with a verified deployment.
`docs/DEPLOY.md` is the reference behind it — why Neon is split into two URLs, how backups
and rollback work, what to do when something specific is broken. When the two disagree,
this file wins.

Written for someone doing this at 11pm. Every step says what to run, what you should see,
and what it means if you see something else. Nothing here requires a laptop except §7.

**First deployed Aug 10, 2026**, and every step below was executed end to end that evening.
§9 is the inventory of what that did and did not prove — it is shorter than it used to be,
but the two steps that went wrong on the first run are still the two worth reading twice.

---


## The two things a deploy now does that it used to not

**The prompt library is seeded on every deploy.** `fly.toml`'s `release_command` is
`alembic upgrade head && python -m rascal.jobs.seed`. It used to be the migration alone, and the
gap cost a day: phase 24 tokenised all 113 bodies, phase 35's migration applied itself on the next
deploy, and the bodies never loaded because nothing invoked the loader. Production served
`his hands` from rows whose theme had already been renamed. The seed is idempotent — a deploy that
changes no prompts reports `0 inserted, 0 updated, 0 retired` — so this costs nothing and closes
the gap permanently.

**Scheduled machines are moved onto the deployed image.** `fly deploy` only manages machines in a
process group, and a machine created by `fly machine run` has none — so the scheduler and the
notifier pinned the image they were created from and ran it for three days after the app moved on,
firing on time every hour, executing older code. The deploy workflow now finds every machine with
a non-empty `schedule` whose image differs from the app's and runs `fly machine update --image`,
which preserves the schedule, the restart policy, the command and the env.

**You still create a scheduled machine by hand the first time.** Nothing here invents one — the
`fly machine run` command below is still how they come into existence, and the three flags it
gets right are still the three that were got wrong on Aug 10. What changed is that they no longer
rot afterwards.

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
| `APNS_KEY_ID` | Fly secret | **No notification is ever delivered.** The app starts, the health check is green, `notification_sends` rows are written, and every phone stays silent. See §4a. |
| `APNS_TEAM_ID` | Fly secret | Same as above — all three are required together and a partial set is treated as unconfigured. |
| `APNS_PRIVATE_KEY` | Fly secret | Same as above. The **contents** of the `.p8`, not a path. |
| `APNS_TOPIC` | Fly secret, optional | Defaults to `APPLE_BUNDLE_ID`, which is correct. Set it only if the two ever legitimately differ. **Wrong** is worse than unset: the app starts and APNs rejects every token with `DeviceTokenNotForTopic`. |
| `MAIL_PROVIDER` | Fly secret | **Now `console` or `resend`** — phase 60 deleted the Postmark adapter rather than disabling it, per D8, and the swap was cheap only because it had never run. **Still unset in production, and unlike the rest of this table that is its actual state.** Unset defaults to `console`, which never opens a socket. The app starts, the health check is green, `POST /auth/email/start` returns its unconditional `202`, and **the magic link is printed to the Fly logs instead of being emailed.** Both call sites swallow delivery failures by design — the response must not become a timing oracle — so nothing is logged as an error and nothing fails. **A parent who asks for a sign-in link simply never gets one.** Verified Aug 16, 2026: no `MAIL_*` value is set on `fly.toml` or as a secret, so this is production's actual state, not a hypothetical. |
| `MAIL_API_KEY` | Fly secret | Only read when `MAIL_PROVIDER` names a real provider; with the provider unset it does nothing at all. **Set the provider and leave this unset** and every send raises `MailDeliveryError` at the first call — which the two callers swallow, so the symptom is again `202`-and-no-email, with one `warning` line per attempt. **Wrong** value is identical from the outside: the provider answers `4xx`, which is deliberately never retried, and the parent still sees a cheerful "check your email". The decision conversation called this `RESEND_API_KEY`; **phase 60 kept the provider-agnostic name**, because the port behind it is provider-agnostic by decision (D8a) and a rename would rotate a secret for nothing a parent ever sees. It is now also what `POST /v1/subscribe` authenticates to Resend's contacts API with, so one key covers both the send and the list. **It must be a full-access key, not `sending_access`** — the contacts write needs more than send. |
| `MAIL_FROM` | Fly secret | The address mail is sent as, and therefore **the sending subdomain**, never the apex — D8. Nothing in the app validates it. A wrong or unauthenticated domain sends successfully as far as the API is concerned, and the message is then junked or rejected downstream by the recipient's DMARC evaluation. **The app cannot see this failure**; only the provider dashboard and a test send to a real inbox can. |
| `TURNSTILE_SECRET_KEY` | Fly secret | **Built, phase 60, and it fails closed.** This row previously called out the defect before the code existed — verification written to skip when the key is unset, turning the spam gate off while everything looked healthy. It does the opposite: **no key is a `503`, and so is no answer from Cloudflare.** Unset therefore means the signup endpoint refuses, visibly, rather than accepting junk quietly. There is deliberately **no `ENVIRONMENT == "local"` bypass** — Cloudflare publishes test keys that always pass, which is what a local run uses, because a second way through the gate is the one that survives into production by accident. `POST /v1/subscribe` still carries no rate limit by decision, so this key remains the entire protection on a public unauthenticated write endpoint. |
| `RESEND_AUDIENCE_ID` | Fly secret | **Where a subscriber actually lives**, because there is no `subscribers` table — the list is provider-held per open item 12(4). Unset means `POST /v1/subscribe` answers `503` rather than accepting an address it cannot store, which is the same rule as the Turnstile key above and for the same reason: **accepting a signup we cannot keep would make the marketing page look like it worked.** |
| `MARKETING_ORIGINS` | Fly secret or `fly.toml` | **Built, phase 60. Plural, and it replaces the `MARKETING_ORIGIN` this table used to name** — a list from the first commit, so a custom domain beside the github.io one is a config change rather than a migration off a scalar. Defaults to `https://travist6983.github.io`, which is where D7 puts the marketing site. **Unset or wrong is the quiet failure**: the endpoint keeps working perfectly under `curl` and under every test, while the browser silently refuses the form on the real site — a preflight failure in a console nobody has open. **An empty value means no origin at all, never `*`**: a wildcard is the failure in the other direction and is worse, because any page anywhere may then post to it. |

### 4a. APNs — the push credentials, and where the `.p8` comes from

~~**None of this exists yet**~~ — **done Aug 12, 2026.** The key is minted and the three secrets
are set on `rascal-api`. Keep this section for the next environment, or for the day the key is
rotated. See `docs/blocked.md` §1a for what the first real send proved.

The key is created in the Apple Developer portal — **Certificates, Identifiers & Profiles →
Keys → +**, with **Apple Push Notifications service (APNs)** enabled:

| What | Where |
| --- | --- |
| Create a key | <https://developer.apple.com/account/resources/authkeys/add> |
| Existing keys | <https://developer.apple.com/account/resources/authkeys/list> |
| Team ID | <https://developer.apple.com/account> → Membership details |

Sign in as **Account Holder or Admin.** Under a Developer-role account the Keys section is
read-only or absent, which reads as "the portal is broken" rather than "wrong role".

**The portal now makes you configure the key before it will issue it**, and the two choices are
not cosmetic:

- **Environment: `Sandbox & Production`.** Not Production alone. `build_push_client` builds *one*
  `ApnsClient` from one key and picks the host per device from `APNS_HOSTS`, so a
  production-only key leaves every Xcode debug build — which registers `sandbox` — unable to
  send at all.
- **Type: `Team Scoped (All Topics)`.** `resolved_apns_topic` falls back to `APPLE_BUNDLE_ID`,
  so team scoping needs no allowlist kept in sync with a secret. If you choose Topic Specific
  instead, select **`com.travisterry.childarchive`** — the app, *not* `.widget` or `.share`.
  The wrong topic is `DeviceTokenNotForTopic` on every send.

That gives you a `.p8` file and a **Key ID** — which is the `XXXXXXXXXX` in the downloaded
`AuthKey_XXXXXXXXXX.p8` filename. One APNs key works for both the sandbox and the production
hosts — the *token* differs per environment, not the key, which is why `devices.environment`
exists and the API refuses to guess it.

```bash
fly secrets set --app rascal-api \
  APNS_KEY_ID="ABC1234567" \
  APNS_TEAM_ID="DEF7654321" \
  APNS_PRIVATE_KEY="$(cat AuthKey_ABC1234567.p8)"
```

**The `.p8` is downloadable exactly once.** Store it somewhere you will still have it in a
year; regenerating means revoking the old key.

**The newlines matter, and losing them is the likely mistake here.** A `.p8` is a PEM: two
`BEGIN`/`END` lines with base64 between them. `"$(cat …)"` above preserves that. Pasting the
file into the Fly dashboard's secret box, or into a chat window and back out, frequently does
not. The job checks at startup rather than at send time, so a mangled key looks like this and
costs nothing:

```
RuntimeError: APNS_PRIVATE_KEY is set but could not be used to sign a provider token:
Unable to load PEM file. … It must be the full contents of the .p8, newlines and BEGIN/END
lines intact. See docs/runbook-deploy.md section 4a.
```

That is deliberately a hard exit before any user is looked at. If the key were only found to
be bad on the first send, the job would already have claimed and committed those users' days
— they would be recorded as notified, hear nothing, and be skipped the next run as "already
sent". Fix the secret, re-run, and everyone whose window has not gone stale still gets it.

**What happens with these unset** — the state before Aug 12, 2026, and the state of any fresh
environment. `build_push_client` returns a client that sends nothing and logs
`push not configured` at WARNING on every attempt. That is deliberate: a push service that
silently no-ops is indistinguishable from one that works until somebody notices their phone has
been quiet for a month. The rest of the system runs normally, so nothing else is blocked on this.

**This is a two-part failure and the secrets are only half of it.** With the key set but no
scheduled machine (§4b), the symptom is *identical* — every phone silent, API green, nothing in
the log, because the job that would have logged never ran. That was the actual state of
`rascal-api` from deploy until Aug 12, 2026: §4a and §4b were both unexecuted, and each alone is
sufficient for total silence. **If push is not arriving, check for the machine before you suspect
the key.** `fly machine list` is the check, and `notification_sends` being *empty* rather than
full of `delivered_count = 0` rows is what distinguishes the two.

### 4b. The notification job — a second scheduled machine

**Done Aug 12, 2026 on `rascal-api`: machine `8900ddf6719058` (`throbbing-water-1063`).** It is
a *second* scheduled machine, alongside the scheduler's `185d762c643778` — they are independent,
and having one is not having the other. That distinction is what this section existed to prevent
and what was nonetheless missed: the app ran for over a day with the scheduler machine present,
the notify machine absent, and no signal anywhere that half the pair was missing.

The send job is `python -m rascal.jobs.notify`, and like the scheduler it is **not created
or updated by `fly deploy`**. Same shape as §5's scheduler machine, and the same three
load-bearing parts — this command was originally written in the short form that §5 records
as having silently produced an hourly second copy of uvicorn:

```bash
fly machine run registry.fly.io/rascal-api:deployment-<id> \
  --app rascal-api \
  --schedule hourly \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --restart no \
  --env ENVIRONMENT=prod \
  --env S3_REGION=auto \
  --env S3_ENDPOINT_URL=https://fly.storage.tigris.dev \
  -- python -m rascal.jobs.notify
```

The `--env` flags are not optional here either: `build_push_client` reads the full
`Settings`, so a machine without them dies on `s3_region Field required` before it looks at
a single user — the same failure the scheduler machine hit on Aug 10. Verify the same way:
`fly machine status <id> --display-config`, where `init.cmd` must name `rascal.jobs.notify`
and `"init": {}` means `--command` was dropped and this machine is running uvicorn instead.

A good run logs one line and stops:

```
{"logger": "rascal.notifications", "message": "notification run", "users_considered": 1, "notifications_sent": 1, ...}
Main child exited normally with code: 0
```

Every run is idempotent — the unique index on `(user_id, notification_date)` means a
duplicate firing sends once — and every run is catch-up: it sends anything whose window has
passed today and has not been sent, subject to the two-hour staleness tolerance.

**Read this next part before deciding this machine is optional, because it is not.**

`GET /today` repairs a missed *assignment*, which is what demoted the scheduler to an
optimisation. **Nothing repairs a missed notification.** There is no read at 19:00 on the
user's behalf, so a window that no run ever looks at is a notification that simply never
happened, and the user experiences it as the feature being broken. The staleness tolerance
bounds how late catch-up may fire; it cannot invent a run that never occurred.

Two consequences of `fly machine run`, both of which bite harder here than they do for the
scheduler:

1. A fresh app has **no notification job at all** until someone runs this by hand, and
   nothing fails if they forget. The API is green, devices register, preferences save, and
   no notification is ever sent.
2. The machine **pins the image it was created from**. Later deploys do not update it, so
   it can quietly run months-old code. Recreate it whenever the job changes.

Hourly is Fly's floor, not this job's preferred resolution — a user picks a minute, so a
window is served by the first run after it opens. That is exactly why the tolerance is two
hours rather than one. Nothing in the job assumes an interval; run it more often if the
platform ever allows.

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

Not created by `fly deploy` — Fly has no fly.toml stanza for scheduled machines. Pass the
image `fly deploy` just published (`fly releases --app rascal-api` prints it) rather than `.`,
so this pins the deployed build instead of triggering a second one:

```bash
fly machine run registry.fly.io/rascal-api:deployment-<id> \
  --app rascal-api \
  --schedule hourly \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --restart no \
  --env ENVIRONMENT=prod \
  --env S3_REGION=auto \
  --env S3_ENDPOINT_URL=https://fly.storage.tigris.dev \
  -- python -m rascal.jobs.scheduler
```

**Three parts of that are load-bearing**, and this step was first run without them on Aug 10,
2026. What came back was a machine that had quietly become something else:

- **`fly machine run` ignores `fly.toml`.** `[env]` is applied by `fly deploy` and by nothing
  else, so `ENVIRONMENT`, `S3_REGION` and `S3_ENDPOINT_URL` have to be restated as `--env`.
  Secrets *are* inherited — only the `[env]` block is missed — which is why the failure is a
  bare `s3_region Field required` and names nothing about scheduled machines.
- **The command goes after `--`.** `--command` belongs to `--shell` and is otherwise dropped
  **without a warning**: the machine inherits the image's `CMD` and runs a second uvicorn,
  hourly, costing money to serve traffic that never reaches it. Verify with
  `fly machine status <id> --display-config` — `init.cmd` must be the scheduler, and `"init": {}`
  means it was dropped. The `--` is needed because `-m` is flyctl's shorthand for `--metadata`.
- **`--restart no`.** The job exits 0 when it is done; `on-failure` retries a broken config
  three times before giving up.

A good run logs one line and stops:

```
{"logger": "rascal.scheduler", "message": "scheduler run", "children": 0, "assignments_created": 0, ...}
Main child exited normally with code: 0
machine restart policy set to 'no', not restarting
```

Hourly rather than daily: the job assigns only to children for whom it is currently 5am on
the wall, so every timezone gets its own 5am and DST stops mattering. It is idempotent on
`(child_id, assigned_on, slot)`, so a double fire costs nothing.

**Nothing fails if you skip creating it.** Assignments still appear, created by the read path.
What you lose is expiry — the `waiting` list grows without bound — which is a slow product
problem, not data loss.

---

### ⚠️ Every deploy: update this machine. Not "if you changed the scheduler" — every time.

> **This is not advice. It shipped a real defect for two days and nobody noticed.** See
> `docs/investigations/missing-photo-slot.md`.
>
> Phase 19 split the daily mission into `mission` (photo only) and `mission_b`. It deployed
> cleanly: `alembic` went to head, both app machines took the new image, the read path served
> three slots. **The scheduled machine kept the image it was created from — a build from ~22
> hours before that code existed** — so every morning at 5am local it wrote two slots instead of
> three and filled the photo-only slot from all five mission kinds. Three days ran; the photo
> slot was served **zero** times. The screen looked like a client bug and the database looked
> fine, because the row was present and merely wrong.

`fly deploy` does not touch a machine created with `--schedule`. There is no fly.toml stanza
that would make it. **So the update is a manual step and it belongs in the deploy checklist,
not in a list of caveats — which is where it used to live, and why it was missed.**

The old wording made it conditional: *"if you change `rascal/jobs/scheduler.py` or anything it
imports"*. **That trigger cannot be evaluated reliably.** Phase 19 changed `constants.py`, which
the job imports transitively; nobody made the connection, and the condition asks a human to
compute an import closure from memory at the end of a deploy. **It is now unconditional.**

**Do this after every `fly deploy`:**

```bash
# The image the deploy just published.
IMAGE=$(fly releases --app rascal-api --json | jq -r '.[0].ImageRef')

# The scheduled machine — the one with no process group.
fly machine list --app rascal-api

fly machine update <scheduler-id> --app rascal-api --image "$IMAGE" --yes
```

`fly machine update --image` preserves `schedule`, `init.cmd`, `restart` and `env`, so it is
cheaper and safer than destroy-and-recreate — recreating re-runs every trap in the three
bullets above. Destroy and recreate only if the *config* has to change.

**Then verify, because this failure is invisible from the outside.** Nothing about a stale
scheduler shows up in `/health`, in the app's behaviour, or in a smoke test:

```bash
# Every machine's image. All of them must match; the scheduler is the one that drifts.
fly machine list --app rascal-api --json \
  | jq -r '.[] | "\(.id)  \(.config.schedule // "app")  \(.config.image)"'
```

A one-line check that answers it directly:

```bash
test "$(fly machine list --app rascal-api --json | jq -r '[.[].config.image] | unique | length')" = 1 \
  && echo "all machines on one image" || echo "DRIFT — a machine is on an old image"
```

**The same applies to the notification machine in §4a/§4b**, which is created the same way and
drifts the same way. If it exists, update it in the same step.

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

## 7a. Marking your own household subscribed — the one hand-run statement

**Phase 36's invite gate is live code and every family defaults to `free`, so until you run
this you cannot invite your wife into your own product.**

```sql
UPDATE entitlements SET tier = 'subscribed'
WHERE family_id = (SELECT family_id FROM users WHERE email = '<your email>');
```

Run it against production (Neon), then check `GET /v1/families/me` reports `"tier":
"subscribed"` before minting an invite.

**A documented manual row rather than a config flag, deliberately.** A
`DISABLE_ENTITLEMENT_GATE` env var would be dead code that never gets exercised — and it
would mean the first person to actually hit the paywall is a paying customer rather than you.
This way the gate is exercised the first time anybody uses it, which is now.

**Nothing else writes `tier`.** D5 reserves that for App Store Server Notifications V2, which
is phase 37 and is blocked on an owner account action. Until 37 ships, this statement is the
only way a household becomes subscribed and the only way one becomes free again. If you later
find a family on the wrong tier, this is the lever — there is no admin route and there is
deliberately not going to be one before 37.

**Sign in with Apple private relay caveat.** If you signed in with Apple and hid your email,
`users.email` is a relay address rather than the one you type. Find yourself by
`display_name` or by joining `credentials` instead of guessing the address.

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

**Executed against Fly, Aug 10, 2026 — the first real deployment:**

- `fly apps create`, `fly secrets set` (all seven, staged before first deploy), `fly deploy`
  via the Deploy workflow, `fly machine run --schedule hourly`. No longer written from the
  documentation.
- The Deploy and Smoke workflows both completed real runs. Release v1 migrated (a no-op —
  Neon was already at `0004_full_text_search`), two machines came up in `ord`, and `/health`
  served `{"status":"ok","db":"ok"}`.
- **`scripts/verify_deployment.py` passed 6/6**, including check 6. The Tigris round trip
  had never completed a successful upload anywhere; it has now, 75 bytes through
  `rascal-media-prod.fly.storage.tigris.dev`, presigned by the deployed app.

**What the first run got wrong, both fixed, both worth expecting:**

- **`deploy.yml` failed a healthy deploy.** Its release check required the status string
  `succeeded`; flyctl 0.4.81 reports `complete`. The app was up, migrated and serving while
  the workflow went red — the worst-shaped failure there is, because it teaches you to
  discount the red. It now accepts both spellings.
- **The scheduler command in §5 built the wrong machine**, silently. See §5; the short
  version is that `fly machine run` ignores `fly.toml`'s `[env]` and drops `--command`
  without a word, so the machine ran a second uvicorn instead of the job and crashed on a
  missing `S3_REGION`.

**What the second run got wrong — Aug 12, 2026, and it was this document's fault:**

- **The scheduled machine was never updated after any deploy, and served two days of wrong
  assignments.** Phase 19 narrowed `mission` to photos and added `mission_b`. It deployed
  correctly in every visible respect — migration at head, both app machines on the new image,
  the read path serving three slots — while the scheduled machine kept the image it was born
  with, from ~22 hours before that code was written. It wrote two slots a day and drew the
  photo-only slot from all five mission kinds. **The photo slot was served zero times out of
  three days**, and the failure was invisible: `/health` was fine, the smoke test was fine, the
  row existed and was merely the wrong kind.
- **This runbook already said to update it.** It was item 2 of a two-item list headed *"both
  reasons not to lean on it"*, directly beneath "nothing fails if you skip this step", and its
  trigger was conditional — *"if you change `rascal/jobs/scheduler.py` or anything it imports"*.
  Phase 19 changed `constants.py`. **An instruction that requires computing an import closure
  from memory, filed under reasons not to care, is an instruction that does not get followed.**
  §5 now states it unconditionally, in the deploy flow, with a one-line drift check — because
  the only reliable version of this rule is "every deploy, no judgement required".
- Full diagnosis, with the production evidence: `docs/investigations/missing-photo-slot.md`.

**Still not exercised by anything:**

- A real multipart upload — a video over cellular. Tigris supports the API; parity with the
  single-PUT path has not been proven end to end (`docs/blocked.md` §2). **Single PUT is now
  proven from a phone in the world**: `rascal-media-prod` holds real objects uploaded from a
  TestFlight build, not just the 75 bytes check 6 wrote.
- ~~Sign in with Apple against a real device token, which is blocked on enrollment.~~
  **Exercised Aug 10, 2026 at `01:06:29Z`** from a device build: `POST /v1/auth/apple → 200`,
  with the `credentials` and `users` rows to show for it. The `aud` claim has now been verified
  against a token Apple actually issued. `docs/blocked.md` §1.
- ~~**Anything APNs.**~~ **Executed Aug 12, 2026.** §4a and §4b have both been run: the key is
  minted and set as Fly secrets, the notification job's scheduled machine is
  `8900ddf6719058`, and `api.push.apple.com` answered `HTTP/2 200` to a real send that
  arrived on a locked phone and deep-linked on tap. `docs/blocked.md` §1a.
- The hourly schedule *firing on its own*. The machine was created and run once by hand, and
  it exited 0 — but no unattended hourly firing has been observed yet.
