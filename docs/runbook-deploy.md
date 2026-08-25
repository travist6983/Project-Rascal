# Deploying RASCAL — the whole thing, in order

**This is the procedure.** Follow it top to bottom and you end with a verified deployment.
`docs/Infastructure/DEPLOY.md` is the reference behind it — **the path gained its `Infastructure/` segment in the Aug 16 docs move and every citation here still said `docs/DEPLOY.md` until Aug 18, 2026 (the directory's spelling is the repo's, and is left alone rather than renamed under a doc audit)** — — why Neon is split into two URLs, how backups
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
| `MAIL_API_KEY` | Fly secret | Only read when `MAIL_PROVIDER` names a real provider; with the provider unset it does nothing at all. **Set the provider and leave this unset** and every send raises `MailDeliveryError` at the first call — which the two callers swallow, so the symptom is again `202`-and-no-email, with one `warning` line per attempt. **Wrong** value is identical from the outside: the provider answers `4xx`, which is deliberately never retried, and the parent still sees a cheerful "check your email". The decision conversation called this `RESEND_API_KEY`; **phase 60 kept the provider-agnostic name**, because the port behind it is provider-agnostic by decision (D8a) and a rename would rotate a secret for nothing a parent ever sees. It is now also what `POST /v1/subscribe` authenticates to Resend's contacts API with, so one key covers both the send and the list. ~~**It must be a full-access key, not `sending_access`** — the contacts write needs more than send.~~ — **struck Aug 22, 2026 (phase 111): the deployed key contradicts it and this row was restating as settled a thing that is open.** The key on `rascal-api` answers **403** to `GET /audiences/{id}/contacts` from inside the production machine, and §13 records two readings that fit and settles neither: a narrower key that still covers every call this service makes, or a latent failure the next contacts call will find. **Nobody has run a `POST /v1/subscribe` since the key was deployed**, so nothing here shows the contacts *write* working under it either. **`docs/blocked.md` §13 holds the unresolved note and the one cheap check that would settle it** (one `POST /v1/subscribe` against the deployed API, then look for the contact); read it there rather than deciding from this table. **Do not widen the key on the strength of this row.** |
| `MAIL_FROM` | Fly secret | The address mail is sent as, and therefore **the sending subdomain**, never the apex — D8. Nothing in the app validates it. A wrong or unauthenticated domain sends successfully as far as the API is concerned, and the message is then junked or rejected downstream by the recipient's DMARC evaluation. **The app cannot see this failure**; only the provider dashboard and a test send to a real inbox can. |
| `TURNSTILE_SECRET_KEY` | Fly secret | **Built, phase 60, and it fails closed.** This row previously called out the defect before the code existed — verification written to skip when the key is unset, turning the spam gate off while everything looked healthy. It does the opposite: **no key is a `503`, and so is no answer from Cloudflare.** Unset therefore means the signup endpoint refuses, visibly, rather than accepting junk quietly. There is deliberately **no `ENVIRONMENT == "local"` bypass** — Cloudflare publishes test keys that always pass, which is what a local run uses, because a second way through the gate is the one that survives into production by accident. `POST /v1/subscribe` still carries no rate limit by decision, so this key remains the entire protection on a public unauthenticated write endpoint. |
| `RESEND_AUDIENCE_ID` | Fly secret | **Where a subscriber actually lives**, because there is no `subscribers` table — the list is provider-held per open item 12(4). Unset means `POST /v1/subscribe` answers `503` rather than accepting an address it cannot store, which is the same rule as the Turnstile key above and for the same reason: **accepting a signup we cannot keep would make the marketing page look like it worked.** |
| `MARKETING_ORIGINS` | Fly secret or `fly.toml` | **Built, phase 60. Plural, and it replaces the `MARKETING_ORIGIN` this table used to name** — a list from the first commit, so a custom domain beside the github.io one is a config change rather than a migration off a scalar. Defaults to `https://travist6983.github.io`, which is where D7 puts the marketing site. **Unset or wrong is the quiet failure**: the endpoint keeps working perfectly under `curl` and under every test, while the browser silently refuses the form on the real site — a preflight failure in a console nobody has open. **An empty value means no origin at all, never `*`**: a wildcard is the failure in the other direction and is worse, because any page anywhere may then post to it. |
| `APP_STORE_APP_APPLE_ID` | Fly secret | **Phase 37a, and unset today.** The app's *numeric* Apple ID from App Store Connect, not the bundle id. Apple's library refuses to build a Production verifier without it, so while it is missing `POST /v1/webhooks/app-store` answers **`401` to every notification** and no entitlement is ever written. The app starts and the health check is green — this failure is visible only in the logs and in a household whose payment did nothing. See `docs/blocked.md` §10a. |
| `APP_STORE_BUNDLE_ID` | Fly secret, optional | Defaults to `APPLE_BUNDLE_ID` while that names exactly one audience, which is correct today. **Deliberately not chained to `APNS_TOPIC`** — that setting aims push at one audience, and letting it also decide whose receipts we accept would couple a delivery detail to an authorization boundary. Required once `APPLE_BUNDLE_ID` names more than one audience; unset-and-ambiguous fails closed at the verifier (`401`, with an `ERROR` naming the setting) rather than refusing to start, because nothing here is configured yet and taking the API down for it would be worse than the webhook staying shut. |
| `GITHUB_BILLING_TOKEN` | Fly secret, optional | **Absent today**, verified against `flyctl secrets list -a rascal-api` on Aug 22, 2026, and the only consequence is that the admin console's Actions-spend card renders `unconfigured` with its own setup text. Nothing else degrades and no other card is affected. It must be a **fine-grained** personal access token whose one permission is **Account permissions → Plan → Read-only**. A classic token will not work, and neither will the repo-scoped token CI already holds — this endpoint reads the *account's plan*, not a repository. **A token missing that permission answers `404`, not `403`**, which is the trap: a bare "not found" reads as a mistyped account name and sends you renaming `GITHUB_ACCOUNT` instead of regenerating the token. `403` here means something else entirely — the account is not on GitHub's enhanced billing platform. `services/billing/github.py` says all of this on the card's face for that reason. Only the account owner can mint it. |
| `GITHUB_ACCOUNT` | `fly.toml` `[env]` or Fly secret, optional | Defaults to `travist6983` (`config.py:290`), which is correct, so this is normally left alone. Named here only because it is the thing you will be tempted to change when the row above answers `404`, and it is almost never the problem. |

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
secrets) — that is `docs/Infastructure/DEPLOY.md` §4 and it is not on the path to a running API.

### 4c. The deletion job — a third scheduled machine, and the only one with a legal deadline

**Added to this runbook Aug 18, 2026. It had none — `jobs/delete.py` shipped in phase 66 on Aug 17
and this document, which is where an operator learns that scheduled machines exist at all, did not
mention it.** §4b exists because the notify machine was missed for a day; this is the same omission
one layer up, in the document written to prevent it.

The job is `python -m rascal.jobs.delete`, same shape as §4b and §5, **not created or updated by
`fly deploy`**, and it needs the same non-optional `--env` flags for the same reason.

```bash
fly machine run registry.fly.io/rascal-api:deployment-<id> \
  --app rascal-api \
  --schedule daily \
  --region ord \
  --vm-size shared-cpu-1x \
  --vm-memory 512 \
  --restart no \
  --env ENVIRONMENT=prod \
  --env S3_REGION=auto \
  --env S3_ENDPOINT_URL=https://fly.storage.tigris.dev \
  -- python -m rascal.jobs.delete
```

**`--schedule daily` is sufficient and hourly is harmless.** Nothing in the job assumes an
interval: a request carries its own `execute_after`, so a late run deletes what was due and an
early one deletes nothing. Every run is idempotent, because a completed request is no longer
pending — there is no ledger to double-write.

**Why this one is not optional, and it is a different argument from §4b's.** A missed notification
is a broken feature. **A missed deletion is a promise not kept**: phase 65 established that in-app
account deletion is what Apple's rule requires, phases 66 and 67 built the request and the button,
and **the request is the only half that a machine has to finish.** Without this machine a parent
taps *delete my account*, is signed out, sees every confirmation the app can give — and the row
sits in `deletion_requests` forever. The API stays green the entire time. There is no read path
that repairs it, exactly as there is none for notifications.

**That is the state production is in today, and it is not hypothetical.** `flyctl machines list -a
rascal-api` on Aug 22, 2026 returns **five** machines and none of them runs `python -m
rascal.jobs.delete` — the inventory is at the end of §4d. So nothing on any schedule finishes a
seven-day erasure, and nothing in this repository records the machine described above ever having
been created. `blocked.md` carries the long-form entry; this paragraph is here so that an operator
reading the deletion job's own section does not have to reach §4d to learn that it does not exist.

**`--dry-run` exists because this is the only job in the service that destroys user data**, and it
prints what would go without touching anything. Use it the first time, and after any change to the
grace period. Note that the deletion is a **hard** delete by deliberate exception to the
soft-delete rule — `data-model.md`'s `deletion_requests` section explains why completion is the row
being gone rather than a `completed_at` column, which also means **a run you did not want cannot be
undone from the database.**

### 4d. The broadcast job — a fourth scheduled machine, ~~and it is the one that must NOT be armed yet~~ — **armed Aug 19, 2026, and sending daily**

**Added to this runbook Aug 18, 2026, and it had zero mentions here before that.** The job is
`python -m rascal.jobs.broadcast`, shipped in phase 69 on Aug 17.

**Create it `--schedule hourly`, not daily** — corrected Aug 18, 2026 by phase 90, and the
reason is the same one §4b gives for the notify machine. A `--schedule daily` machine fires
roughly whenever it happened to be created, which would tie the send time to the minute somebody
ran `fly machine run`. So the machine runs hourly and **the job decides which run acts**:
`BROADCAST_SEND_HOUR` (8) in `BROADCAST_TIMEZONE` (`America/Detroit`).

**A run outside that hour writes no ledger row**, and that is the property to preserve if this is
ever changed. A row claims the day, so an off-hour run recording `skipped` would silently cancel
that day's send rather than defer it.

**That decision has been taken. The machine exists and the mail is going out.** Machine
`683e1eea463d28` / `late-fire-837` was created **2026-08-19T02:15:36Z**, the owner's call, and the
first send landed the same day. As of Aug 22, 2026 `email_broadcasts` holds four rows, **all
`status='sent'`** — none failed, none skipped:

| `send_date` | `pool_index` | `resend_id` | `sent_at` |
|---|---|---|---|
| 2026-08-22 | 11 | `d9e6b965-c54c-406a-9fa0-b89fd5f5a512` | 12:15:05Z |
| 2026-08-21 | 10 | `f3e802d5-f091-43e5-a66b-4772adae4223` | 12:15:06Z |
| 2026-08-20 | 9  | `6f8ab6f3-e217-45bc-bbea-c4fe02ead438` | 12:15:07Z |
| 2026-08-19 | 8  | `c4a32683-7972-4658-9710-300be51e407c` | 12:15:08Z |

`MARKETING_EMAIL_ENABLED`, `MAIL_PROVIDER`, `MAIL_FROM` and `RESEND_AUDIENCE_ID` all read
**Deployed** in `flyctl secrets list -a rascal-api`, checked Aug 22, 2026. The hourly wake is
working as designed: today's 13:15Z run logged `broadcast: not the send hour — it is 09:15 EDT,
sending at 08:00. Nothing written.` and did exactly that. **The last two words are part of the log
line, not a gloss** — `jobs/broadcast.py` emits the whole thing from one f-string — and this page
quotes it in full because a runbook is read while somebody is holding a log beside it, and a quote
that stops early is a quote a reader cannot match.

**How many people received those four emails is not knowable from here, and must not be guessed.**
`MAIL_API_KEY` is send-scoped, so `GET /audiences/{id}/contacts` answers **403** from inside the
production machine. The Resend dashboard is the only place that can answer it. **Do not write a
recipient count into this runbook or anywhere else in `docs/` from a number you inferred** — a
send ledger records that a send happened, not who it reached.

**Read the rest of this section before creating one in a new environment, because arming it is a
decision and not a step.**

`MARKETING_EMAIL_ENABLED` defaults false and is **deliberately kept separate from the mail
credentials** so that configuring `MAIL_API_KEY` to make `POST /v1/subscribe` work cannot start
mailing strangers. Without it the job does the entire run except the network call and logs the
rendered mail. ~~**`decisions.md` open item 12 forbids any marketing send before the P0 behavioural
gate**, and `blocked.md` §13 deliberately omits `MARKETING_EMAIL_ENABLED` from its
value-and-destination table for this exact reason: completing that table must not send anything.~~
— **struck Aug 22, 2026 by the owner's call: the behavioural gate no longer gates marketing email,
and the four sends above are intended.** The separation between the flag and the credentials is
kept for what it was actually protecting — setting `MAIL_API_KEY` so that sign-in links work still
does not, by itself, mail a marketing list — but it is no longer a prohibition waiting on a
milestone.

Two properties worth knowing before you run it by hand:

1. **It is safe to run twice.** The unique index on `email_broadcasts.send_date` means a second
   run reports the day already done and exits 0.
2. **`--show` renders today's mail and sends nothing, ever** — that is the safe way to look at it,
   and `--date` lets you inspect a future day.

~~**Unverified as of Aug 18, 2026: the Resend Broadcasts API has never been called from anything.**
Neither CORS, nor a real Turnstile verification, nor this job's network path has run against the
deployed service.~~ — **struck Aug 22, 2026: this job's network path has now run four times against
the deployed service and returned a `resend_id` each time.** ~~CORS and a real Turnstile
verification from the marketing origin are separate claims and are still not evidenced here~~ —
**struck the same day, for being the fourth account of something already settled two files over.**
`docs/blocked.md` §13 records that `POST /v1/subscribe` **has** been exercised from the real origin
— that signup is what revealed Resend's contacts API does no double opt-in, which phase 88 then
fixed — **so CORS and a genuine Turnstile verification have both run against the deployed API.**
`phase-queue.md` and `roadmap-status.md` already defer to §13 for it; **this page defers there too
rather than keeping its own copy**, because a claim held in four places is a claim that will be
corrected in three. The broadcast path never sat behind either of them.

**The full machine inventory, read with `flyctl machines list -a rascal-api` on Aug 22, 2026.**
~~As of this writing the scheduler (`185d762c643778`) and notify (`8900ddf6719058`) machines exist;
**the deletion and broadcast machines are not recorded as created anywhere in this repo.**~~ —
**corrected Aug 22, 2026: there are five machines, the broadcast one is among them, and the
deletion one is still not.**

| ID | Name | Process group | Command | Created |
|---|---|---|---|---|
| `e826d3df469118` | `patient-wood-1946` | `app` | the API itself | 2026-08-11T00:20:51Z |
| `2870901b4761d8` | `delicate-wind-1252` | `app` | the API itself | 2026-08-11T00:20:39Z |
| `185d762c643778` | `divine-hill-1816` | *(none)* | `python -m rascal.jobs.scheduler` | 2026-08-11T00:26:19Z |
| `8900ddf6719058` | `throbbing-water-1063` | *(none)* | `python -m rascal.jobs.notify` | 2026-08-13T00:36:14Z |
| `683e1eea463d28` | `late-fire-837` | *(none)* | `python -m rascal.jobs.broadcast` | 2026-08-19T02:15:36Z |

**Every machine is independent, and having one is not having the others.** Two that this runbook
describes are not in that list: there is **no `python -m rascal.jobs.delete` machine** — §4c's, the
one with the legal deadline, so anything sitting in `deletion_requests` has nothing scheduled to
finish it and the seven-day promise is not being kept by anything — and **no `python -m rascal.jobs.social`
machine**, §4f's. §5's rule covers all of them: every machine with a non-empty `schedule` is moved
onto the deployed image by the deploy workflow, so the image-pinning trap in §4b applies to those
two the moment they exist.

### 4f. The social publishing job — ~~a fifth scheduled machine~~ — **not deployed, and neither are its secrets**

**Added Aug 20, 2026 by phase 104**, and **nothing described below exists in production.** Read
today, Aug 22, 2026: `flyctl machines list -a rascal-api` shows five machines and none of them
runs `rascal.jobs.social` (see §4d's inventory), and `flyctl secrets list -a rascal-api` holds
**no `IG_USER_ID`, no `IG_ACCESS_TOKEN` and no `SOCIAL_PUBLISH_ENABLED`**. So this section is a
plan, not a description: the API-lane social publisher has never been armed, and the only pipeline
posting to that Instagram account today is the `Rascal-Marketing` repository's hourly workflow.

**That is worth knowing before you go looking for a bug.** A console publish that fails, or a post
that appears without one of ours explaining it, is this — not a broken job.

The job is `python -m rascal.jobs.social`, same shape as §4b, §4c and §4d, **not created or
updated by `fly deploy`**:

    fly machine run registry.fly.io/rascal-api:deployment-<id> \
      --app rascal-api --schedule hourly --region ord \
      --vm-size shared-cpu-1x --vm-memory 512 --restart no \
      --env ENVIRONMENT=prod --env S3_REGION=auto \
      --env S3_ENDPOINT_URL=https://fly.storage.tigris.dev \
      -- python -m rascal.jobs.social

**This machine is only for *scheduled* posts.** Pressing publish in the console posts inside the
web request; the machine exists for posts queued for a time, and to pick up an immediate one
whose request died between queueing and publishing. So a service with no scheduled machine still
publishes — it just never publishes anything later.

**Arming it is `SOCIAL_PUBLISH_ENABLED=true`, and that is a decision rather than a step**, the
same shape as §4d. The two Instagram secrets let the console *read* the account; this one lets it
*post*.

**Unlike §4d, off means refuse rather than rehearse.** The check is the first thing the publish
path does, so nothing is generated and nothing is reported — a queued row is named as staying
queued and the run exits 0. **`--dry-run` is the rehearsal**, and it works whatever the flag
says. This paragraph promised the broadcast job's behaviour before Aug 21, 2026, which would
have sent somebody looking for a report that was never going to appear.

Three properties worth knowing:

1. **At most one post per run**, however often it fires. Looking often and posting often are
   separate things.
2. **The spacing rule is read from Instagram, not from our database** — the account is shared
   with the `Rascal-Marketing` repository, whose hourly workflow posts to the same feed and
   cannot see our rows. A run that says *holding off* is usually the other pipeline.
3. **`--dry-run` says what is due and calls nothing; `--account` prints which account the
   credentials control and its recent posts.** Use `--account` first. *"The run was green"* and
   *"there is a post on the account you are looking at"* are different claims, and the marketing
   session lost hours to exactly that distinction.

#### Refreshing the Instagram token — the errand nobody has a calendar entry for

**This procedure had no entry in this runbook until Aug 22, 2026, and `grep IG_ACCESS_TOKEN
docs/runbook-deploy.md` returned nothing.** That is the wrong way round: the one document somebody
opens *while* a publish is failing is the one that did not describe the credential.

**The deadline is roughly 2026-10-19.** `IG_ACCESS_TOKEN` is a long-lived Instagram token, which
Meta issues for about sixty days. The only real timestamp either repository holds is the creation
time of the `Rascal-Marketing` Actions secret, **2026-08-20T00:57:19Z**, so the lapse is inferred
from that and is approximate. See `docs/blocked.md` §18.

**Nothing refreshes it and nothing warns.** The first sign is a failed publish carrying Meta's own
auth error, **`OAuthException 190`** — on this side it surfaces as `publish_failed` with that
sentence attached; on the marketing side it is a red workflow run. There is no expiry check, no
scheduled reminder and no dashboard card that goes amber first.

**Where the credential actually lives today, which is not where §18 says.** §18 describes *"two
stores … this service's Fly secrets and the marketing repository's Actions secrets"*. This
service's Fly secrets are **not** one of them: neither Instagram value is set on `rascal-api`,
verified Aug 22, 2026. The two copies are:

1. **`Rascal-Marketing`'s Actions secrets** — `IG_USER_ID` and `IG_ACCESS_TOKEN`. This is the copy
   that is actually posting.
2. **A developer `.env`** — this worktree's, from `.env.example`'s Instagram block.

So the refresh is currently a **one-store** errand plus a local file, not the two-sitting
coordination §18 warns about. **The day `SOCIAL_PUBLISH_ENABLED` is set on `rascal-api`, it
becomes a two-store errand and §18 becomes correct** — mint once, and set it in both places before
the next hour rolls over, or whichever pipeline you did not update posts with a dead token.

**Doing it:**

1. Mint a fresh long-lived token in Meta's tooling against the same professional account, and
   note the minting time — that timestamp is the only thing that dates the next lapse.
2. `gh secret set IG_ACCESS_TOKEN --repo <owner>/Rascal-Marketing` (and `IG_USER_ID` if the
   account changed).
3. Update your local `.env`.
4. Only if the API-lane publisher has been armed by then:
   `flyctl secrets set -a rascal-api IG_ACCESS_TOKEN=… IG_USER_ID=…`. Setting secrets restarts the
   app machines; the scheduled machines in §4d's inventory pick the values up on their next wake.
5. **Confirm against the account, not against a green run.** `python -m rascal.jobs.social
   --account` prints which account the credentials control and its recent posts. A run that says
   *holding off* proves the credentials read; it does not prove they post.
6. Write the new date into `docs/blocked.md` §18. A written date is the whole mechanism here — the
   section says so itself, and a half-built refresher nobody checks would be worse.

---

### 4e. App Store Server Notifications V2 — the endpoint, and the file that is not a secret

**Nothing here has ever been exercised against Apple**, and none of it can be until
`docs/blocked.md` §10's errand puts a subscription product in App Store Connect. This section is
what to do when it does.

**The trust anchor is a repository file, not a secret.** `POST /v1/webhooks/app-store` verifies
Apple's `x5c` chain against roots bundled inside the image at `api/src/rascal/certs/appstore/`.
~~That directory ships **empty**. Every notification is refused with `401` until
`AppleRootCA-G3.cer` is committed into it — see `docs/blocked.md` §10a for the command and the
fingerprint check.~~ — **corrected Aug 22, 2026: `AppleRootCA-G3.cer` is committed, 583 bytes,
and `load_root_certificates()` returns one anchor.** The fingerprint check named there could not
be followed as written — Apple publishes no fingerprints beside the download — so the README in
that directory now documents the macOS system-keychain comparison that was actually used, and
says why the reference value cannot live in this repository. A root fetched at request time would
be a root whoever controls DNS at that moment gets to choose, which is why it is bundled and why
this is a deploy-time concern rather than a runtime one.

**Production still answers `401` regardless, for the other reason.** `APP_STORE_APP_APPLE_ID` is
absent from `flyctl secrets list -a rascal-api`, verified Aug 22, 2026, and Apple's library
refuses to build a `Environment.PRODUCTION` verifier without it. The **sandbox** verifier does
build now that the root is in place, so a first sandbox purchase is verifiable today and a
Production notification is not.

**Then set the endpoint URL in App Store Connect**, on the app's App Information page, for both
environments:

```
https://rascal-api.fly.dev/v1/webhooks/app-store
```

**Apple's own menu wording is not verified here** — the same rule `docs/blocked.md` §10 follows,
and for the same reason: App Store Connect's navigation changes and a stale click path is worse
than a described destination.

**Send a test notification from App Store Connect first.** It arrives as `notificationType: TEST`,
which this service records and deliberately does nothing with — a test that changes somebody's tier
would be the wrong kind of test. A `202` back is the whole success condition, and it proves the
chain verified, which is the part nothing in the test suite can prove.

**What to check afterwards**, in this order, because each failure looks like the next one from
outside:

| Symptom | Almost certainly |
|---|---|
| `401` on every notification | No root certificate in `api/src/rascal/certs/appstore/`, or `APP_STORE_APP_APPLE_ID` unset. Both log at `ERROR` on startup, naming themselves. **Since Aug 22, 2026 the root is present, so on Production this is the missing `APP_STORE_APP_APPLE_ID`** |
| `202` but no row in `app_store_transactions` | Nothing — a `202` always writes a row unless the payload carried no `originalTransactionId`. Check the `status` in the response body |
| Row written, `family_id` null | The purchase carried no `appAccountToken`. **This is the 37b obligation** and it is not recoverable server-side — see `docs/api-contract.md` |
| Row written, tier unchanged | Read the `status` field. `ignored:out-of-order`, `recorded:demotion-refused` and `ignored:environment-mismatch` are all deliberate, and all three log at `warning` with the reason |

**The one thing that would be alarming**: a `500`. Every deliberate outcome here is a `202` and
every verification failure is a `401`, so a `500` is a bug rather than a rejection — and Apple will
retry it, so it will not be a quiet one.

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

~~**Nothing else writes `tier`.**~~ ~~Until 37 ships, this statement is the only way a
household becomes subscribed and the only way one becomes free again.~~ — **struck Aug 20,
2026. Phase 37a shipped the writer**: `POST /v1/webhooks/app-store` sets `tier` from an App
Store Server Notification, and it is the only code that does.

**This statement is now the override rather than the only way in**, and it is still the lever
when you find a family on the wrong tier. ~~There is still no admin route that writes `tier`,
deliberately — phase 107 added one that writes `entitlements.trial_ends_at`, which is a different
column and cannot reach this one.~~ — **still exactly true, and worth restating with its subject
after phase 121, Aug 24, 2026.** There is still no admin route that writes **`tier`**, and there
are now *two* console levers that reach entitlement without touching it: phase 107's
`trial_ends_at`, and phase 121's `entitlement_grants` — a separate table, written by
`POST /v1/admin/grants`. **Nothing in this API can set a tier over HTTP except a payload Apple
signed**, the exactly-one-writer test still passes unmodified, and this statement is still the
only way to move the column by hand.

**If what you actually want is to make one household entitled, use a grant rather than this.**
It is auditable — who, why, when, and revocable — and it does not create a second household whose
`subscribed` has no receipt behind it. This statement stays for the case it was written for: your
*own* household, where the tier itself is what a reconciliation job would come for and the guard
in the webhook is what protects it.

**The reverse, which phase 107 made necessary.** The free tier now serves the daily question only,
and the console's trial lever cannot show it to you while this row says `subscribed` —
`subscribed` beats `trial`. To look at your own product the way a free household sees it:

```sql
UPDATE entitlements SET tier = 'free'
WHERE family_id = (SELECT family_id FROM users WHERE email = '<your email>');
```

Then use the console's Membership card to move between `trial` and `free`. **Run the statement at
the top of this section again afterwards** — on `free` you cannot mint a guardian invite.

**And check the Grants card while you are there, as of phase 121.** An active grant on your own
household reads `access: "subscribed"` exactly as the tier does, so it will hide the free tier from
you just as effectively — and the trial lever's own response now says which of the two is holding
it (`entitlement_source`) rather than sending you back to this section for a tier that was never
the reason. A trial does *not* let you mint an invite; a grant does.

**Your own household is subscribed by one of these and always will be.** There is no App Store
transaction behind the row §7a wrote on Aug 17, 2026, and there never will be — you did not
buy the subscription, you wrote the row. That makes it exactly the shape a reconciliation job
would "fix": notice a subscribed family with no receipt, set it free, and lock you out of your
own product.

**What protects it is a guard in the webhook, not the absence of one.** A notification that
would set a family `free` is refused unless `app_store_transactions` already holds a row
linking that family to that `originalTransactionId` — and a refused demotion does not record
the attribution it was refused for, so the guard does not degrade into a one-notification
delay. Your household has no such row, so no notification Apple could send can demote it.

**If you later subscribe for real from your own phone**, the `SUBSCRIBED` notification writes
the row, the tier stops being hand-maintained, and from then on the normal lifecycle applies —
including demotion. That is the intended path out of this state, and it needs nothing run here.

**That path exists in the app as of phase 37b, Aug 20, 2026** — Settings → Membership, or the
invite's paywall. The two paragraphs above were written by 37a and already said this statement is
the override rather than the only way in; **37b corrects neither, because both were right.** What
changes is only that *"if you later subscribe for real from your own phone"* is now something you
can do rather than something the client could not yet offer.

**Nothing above has been verified against Apple.** No product exists in App Store Connect yet;
see `docs/blocked.md` §10.

**So this statement is not merely the override today — it is still the only thing that can set a
tier at all**, and that takes three things rather than one. There is nothing to buy until
`docs/blocked.md` §10 steps 1–5 are done; and even then `POST /v1/webhooks/app-store` answers `401`
to every notification until Apple's root certificate and `APP_STORE_APP_APPLE_ID` are in place —
§10a, deployed per §4e. **A purchase made before those two would be charged, attributed on the
device, and land nowhere.**

**Sign in with Apple private relay caveat.** If you signed in with Apple and hid your email,
`users.email` is a relay address rather than the one you type. Find yourself by
`display_name` or by joining `credentials` instead of guessing the address.

---

## 8. Then

- Flip `FLY_DEPLOY_ENABLED` to `true` (GitHub → Settings → Secrets and variables → Actions →
  Variables) so merging to `main` deploys by itself.
- `docs/Infastructure/DEPLOY.md` §Rollback, §Backups, and §When something is wrong.

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
- **Anything Apple-billing, and this is the newest and the largest of these.** Phase 37a shipped
  `POST /v1/webhooks/app-store` on Aug 20, 2026 — the only writer of `entitlements.tier` — and
  **no product exists in App Store Connect, no sandbox transaction has ever been made, and no
  real Apple notification has ever reached this endpoint.** Every payload it has ever seen was
  minted by the test suite and signed by a locally-generated certificate chain. The verification
  logic is Apple's own library and the chain rules it enforces are real ones — the test stub was
  rejected until it carried Apple's marker OIDs — but **Apple's actual bytes have never been
  through it.** The endpoint currently answers `401` to everything for want of a root
  certificate, which is the designed fail-closed state rather than a fault. §4e is the sequence
  when the errand in `docs/blocked.md` §10 clears; §10a is the two items that gate it.
