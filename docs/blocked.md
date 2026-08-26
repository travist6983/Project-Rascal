# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have — **and, as of
Aug 14, 2026, one that needs a platform.** §9 is the first entry here blocked by a missing API
rather than a missing secret, and it is filed here anyway because the effect is identical: the
work cannot proceed and no amount of engineering changes that. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: ~~**Aug 22, 2026.**~~ **Aug 25, 2026.** The Aug 11 pass is described below and its
findings stand; what Aug 16 changed is recorded in the paragraphs immediately after it.

**Aug 25, 2026 — phase 122, a docs sweep, and it touched three things here.** **New: §22**, the
three `GEMINI_*` Fly secrets that phase 120 orphaned on Aug 25 — the only genuinely owner-only act
that phase produced, and it was written into a phase report rather than onto this page, which is
the same failure §20 was filed for three days earlier. **§17 gains a note under its heading**: its
subject — `services/social/gemini.py`, `stitch.py` and the three settings — was deleted out from
under it, so a section that reads as a closed billing errand is now explicit that there is no
billing left to check, and its surviving *"Omni Flash stays reachable by setting
`GEMINI_VIDEO_MODEL`"* is struck because that setting no longer exists. **And the unstruck-section
count went ~~eleven~~ → thirteen**, twelve of which were already there when this pass opened the
file: the Aug 22 recount was stale within three days, for the exact reason its own note gives.

**Aug 22, 2026 — this pass closed a section whose stated blocker was environment-specific rather
than universal, and struck one that had been resolved for four days.** §10a item 1 said Apple Root
CA - G3 could not be fetched because `www.apple.com` is refused at an egress proxy. That was true
of the environment phase 37a was built in, and the section wrote it as though it were true
everywhere. One `curl` from this machine returned the 583 bytes; the anchor is committed at
`api/src/rascal/certs/appstore/AppleRootCA-G3.cer` and the loader returns it. **§14 was struck
outright**: phase 86 answered its question on Aug 18 (commit `a1b25b8`, PR #137) and its central
factual claim — that `plan_upload` does not recompute `entry_type` — has been false against `main`
ever since. **The lesson is the one this file keeps re-learning from a new direction: a blocker
states a reason, and the reason has a scope.** *"Refused by an egress policy"* and *"refused by
**this** egress policy"* are different sentences, and only one of them is still true when the file
is read on a different machine. A blocker inherits the environment it was written in; say which
one.

**Everything else this pass changed, in one place.** §13's *no marketing email before the P0
behavioural gate* is struck — the broadcast has been armed since Aug 19 and has sent on four
consecutive days (owner's call, Aug 22, 2026). §10 step 5's 14-day introductory offer is corrected
to **no introductory offer**, because the server already grants the free fortnight and Apple would
stack a second one. §9 was re-verified against the same and only installed SDK and has not moved;
the owner will run the measurement this week. §11's runbook is rewritten so a wrong answer is
repairable and so its step 4 stops misreporting a correct system as a failure. §16 gains the
upload-only App Store Connect key it never mentioned. §18 is downgraded — the Instagram credential
is not in this service at all. And the four resolved iOS sections that had sat at the top of a file
titled "blocked" since Aug 11 are finally **moved**, which is the habit this file wrote down for
itself in the Aug 11 second pass and then did not follow for eleven days.

**And a second sweep of this pass, after the first was audited, added one section and corrected
four counts.** **New: §20**, the deletion job that has no Fly machine — the only entry on this page
where a promise is actively being broken rather than deferred, and it is blocked on nobody. The
counts: the unstruck-section number went ~~nine~~ → **eleven** and is now stated as a command
rather than a figure; §4's *"79 candidates"* → **139** across nine worksheets and four kinds; §4's
*"the four thinnest themes"* is scoped to Aug 4, 2026 with the current bottom five named; and
Phase 16's copy of *"Nothing in this feature has ever run"* is struck, five days after the sentence
it quotes was corrected and **an hour after this same pass struck the identical quote at the top of
this file without grepping for its siblings**.

**Aug 21, 2026 — §17 is closed, and closing it is the argument for reading this file sceptically.**
Gemini video billing was enabled and the render path saw its first 200. **The errand was correctly
diagnosed and was not the last thing in the way**: the first successful render was refused by Omni
Flash's safety filter over a shot of a photograph, so the default model moved to Veo 3.1 Lite —
which is also half the price — and two response-shape errors surfaced that only a live call could
find. §17 has the evidence. **Also closed here: the second §17**, which was a numbering collision
one day old and is now §18.

Previously reviewed: **Aug 11, 2026** — and this was the review where most of the file stopped being
true. Apple enrollment (§1), Fly (§3), object storage (§2) and Actions billing (§0) were already
struck. What this pass found is that **every Lane A gap the iOS lane had recorded here has since
been built** — the seal's setness, `children.pronouns`, the avatar presign pair, `prompt_body` on
`EntryOut`, `?sealed=`, and the tag source that gated Phase 17 — and none of them had been marked
resolved. They were checked by reading the merged code on `main`, one grep each, and the greps are
in each section.

**Aug 12, 2026 — §1a is closed. Push notifications work in production.** The APNs key is minted
and set as Fly secrets, the notification job has its scheduled machine, and a real notification
was delivered to a locked phone and deep-linked on tap. Details and the evidence are in §1a.

~~**Aug 16, 2026 review — nothing in this file is blocked on a credential any more.**~~ — **that
stopped being true on Aug 20, 2026, and §10a is why.** §0, §1, §2, §2b and §3 are still closed, and
§10 is still an errand rather than a blocker: its blocking decision was the price, and D1 settled
that on Aug 15.

**What changed is that phase 37a built the thing §10 was waiting for, and building it produced two
blockers of its own** — one file and one number, both in §10a. Neither needed a decision and neither
could be done from the branch that found them. ~~**`POST /v1/webhooks/app-store` answers `401` to
every notification until both are done**~~ — **the file half closed on Aug 22, 2026, so it now
answers `401` to Production notifications only; Sandbox verifies.** The design is unchanged and is
deliberate: it fails closed rather than
accepting an unverified payload, so the failure is loud rather than a billing hole.

**One thing is blocked on a platform and cannot be engineered around: §9**, on-device photo
captioning. The grep that proves it lives in the section and is the thing to re-run when a new SDK
lands. Do not soften it and do not re-derive it from memory.

**Everything else on this list is unrecorded rather than blocked**, and that is a different
problem with a different fix. The device-verification checklists describe work that in at least one
case **has already been done in the world and was never written down**. Phase 16 is the example:
`SpeechAnalyzer` has produced a real, accurate transcription on a real device, and ~~the checklist
that gates the phase still opens with *"Nothing in this feature has ever run."* The gate is shut on
evidence that exists.~~ — **the checklist was corrected on Aug 17, 2026 and this paragraph went on
citing the dead sentence until Aug 22.**
`docs/Device-Verification/device-verification-transcription.md:3` reads
`~~**Nothing in this feature has ever run.**~~ — **corrected Aug 17, 2026**`, with the owner's
account of the run quoted directly underneath it. **The example survives the correction, and is
sharper for it**: the gap between the world and the written record closed after two days, and the
gap between the written record and the page citing it took another five. See the Phase 16 section.

> **This paragraph said "two things" for about an hour, and the second one had already been
> fixed.** It named the `sandbox`/`production` description bug in `schemas/device.py` and
> `docs/api-contract.md`; commit `39fb97f` had corrected both earlier the same day. It was
> copied here from `roadmap-status.md` without a grep, which is the exact failure that file
> records five times over — and it propagated into two more documents before anyone checked.
> **The rule that would have caught it is already written down: a shipped-status claim carries
> the command that proves it.** One `git log -L` closed it.

**Aug 11 second pass — the resolved sections were struck but not moved, and that was the defect.**
~~The four iOS sections below (Seal control, Onboarding, Timeline v3, Settings)~~ — **they are no
longer below; phase 111 moved all four into *Resolved since the last review* on Aug 22, 2026** —
were all correct at
the top of this file on Aug 11 and were still sitting under a heading that means "blocked",
describing workarounds as current. **A struck section is not a moved section**, and a file read for
"what is blocking me" gets skimmed by heading rather than read for strikethroughs. Two of them have
since been closed outright by phase 19 (PR #48); the remaining iOS follow-ups are named as such.

> **Standing habit this pass earns:** when a section resolves, it moves to
> `Resolved since the last review` in the *same pass* that strikes it, with the follow-on work
> stated as a phase rather than as a paragraph. The original entry can travel with it — the
> reasoning is usually why the fix is shaped the way it is, and that is worth keeping, just not at
> the top of the blocker list.

> **And the habit was not followed for eleven days.** It was written on Aug 11, 2026, in the same
> pass that diagnosed the defect it was meant to prevent, and the four sections it was written
> about stayed exactly where they were until **Aug 22, 2026**. Every reader in between opened a
> file called "blocked" and met four resolved iOS sections before the first real blocker. **A habit
> recorded in the same document it governs is not a process**, and this is the second time this
> page has caught itself that way — the first was the *"a shipped-status claim carries the command
> that proves it"* rule two paragraphs up, which was also written down before it was applied. What
> would actually have caught it is a rule with a place to run: the move belongs in the checklist of
> whatever phase strikes the section, not in a blockquote near the top of the thing being struck.

---

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

## 2b. ~~The production media bucket does not exist yet~~ — IT EXISTS, AND THE UNRECOVERABLE HALF IS DONE. Verified Aug 11, 2026

**The bucket was created Aug 10, 2026 at 20:14, and soft delete is on.** This was the one item on
this page that could not be fixed after the fact, so it was checked by reading the bucket's own
configuration rather than by trusting the runbook:

```
$ tigris buckets get rascal-media-prod
Name                 rascal-media-prod
Soft Delete          Enabled (30 day retention)      <- the one that mattered
Delete Protection    No
Snapshots Enabled    No
CORS Rules           (none)
```

`rascal-backups` reads identically on the line that counts (`Enabled (30 day retention)`), and
`rascal-media-dev` still reads `Disabled`, which is the deliberate dev-bucket choice this section
described. So the configuration is exactly what this section asked for, on all three buckets. **The
window in which a mis-set production bucket could have quietly lost a photo is closed**, and it
closed before any real media went in.

### Two Tigris items, promoted out of prose. Neither blocks anything.

**7a — Delete Protection: wanted on prod and backups, and the flag is deprecated.**
`Delete Protection` reads `No` on all three buckets. Soft delete protects *objects*; delete
protection protects the *bucket* from one `tigris buckets delete` on the wrong name, and 30-day
retention on objects inside a bucket that no longer exists is not obviously a rescue. Owner,
Aug 16: turn it on for **`rascal-media-prod` and `rascal-backups`**, and **not** on
`rascal-media-dev`.

**The CLI does not straightforwardly support what that asks for, and this was checked rather than
guessed.** `tigris buckets set --help`, run Aug 16, 2026, lists:

```
--enable-delete-protection [value]   (deprecated) Enable delete protection Use
                                     --soft-delete instead.
```

It is the **only** delete-protection flag in `tigris buckets set`, it is marked deprecated, and the
CLI's own advice is to use `--soft-delete` — which is **already enabled with 30-day retention on
both of the buckets in question.** So either the control has been folded into soft delete and the
`No` in the bucket listing above is now vestigial, or it still exists and is reachable only through
a deprecated flag or the dashboard.

**Do not run either of these until that is settled** — the second uses a flag its own tool says not
to use:

```bash
# <verify> — deprecated per `tigris buckets set --help`, Aug 16 2026.
tigris buckets set rascal-media-prod --enable-delete-protection true
tigris buckets set rascal-backups    --enable-delete-protection true
```

The question to answer first is whether `Delete Protection: No` alongside `Soft Delete: Enabled`
still means anything on a current Tigris bucket. That is a dashboard or support question, not a
CLI one.

**7b — `rascal-media-dev` CORS `AllowedOrigins: ["*"]`: left as-is, and now it has an owner.**
Harmless while the only client is native: CORS is browser-enforced and `URLSession` ignores it
entirely. **This belongs to the web client phase** rather than sitting here as a loose note — the
entire risk is that nothing prompts it on the day a browser first loads a photo, and a note nobody
owns is exactly how that day arrives unprepared. `rascal-media-prod` has no CORS rules at all,
which is correct today and needs a real origin added by that same phase.

The original entry follows, because the reasoning is why the bucket was set up correctly, and
because the `access-keys assign` warning still catches people.

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

## Deferred by decision — not blocked, and not waiting on you

These were left out on purpose. Each is a small piece of work if you decide otherwise.

- **`POST /prompts/batch-review`.** Not deferred any more — **cut**, and removed from
  `docs/api-contract.md` rather than left in it as a promise. The review queue it approved
  candidates from is a pull request now: `scripts/generate_prompts.py` writes batches into
  `docs/prompt-candidates/` and the *Prompt candidates* workflow opens a PR with them. A
  branch with a diff is already an accept/reject interface with a comment thread, an audit
  trail, and an undo. — **Half of this was overtaken Aug 20, 2026 by phase 103, and the half
  that matters here still holds.** The endpoint under this name is still not built and still
  not planned: approving a candidate is `PUT /prompts/{id}/active`, one prompt at a time, read
  by a person. What stopped being true is the reasoning — there *is* a review queue now, in the
  console's Library tab, writing `source='llm'`, `active=false` rows that
  `scripts/review_candidates.py` reads. The PR flow above is unchanged and is still the batch
  path. Left rather than struck, because the conclusion is still correct and only its argument
  moved.
- ~~**`POST /children/{id}/guardians`.** P2 in the contract, and the guardian invite flow is
  out of scope. … Only the invite mechanism is missing.~~ — **struck Aug 18, 2026. Phase 36 built
  the invite mechanism on Aug 17, and the route named here never existed at all.** Guardians are
  invited through **`POST /families/me/invites`**, because an invite belongs to the *household*
  rather than to one child: a second parent joins a family and gets every child in it. Phase 72
  struck the child-scoped route from `api-contract.md` for the same reason. The rest of this bullet
  was accurate and is now simply history.
- **Thumbnails and poster frames.** `POST /media/{id}/complete` marks the row and leaves
  `thumb_key` null. The column exists and clients already handle it being null, so the
  pipeline slots in later with no schema or contract change.
- **The `ORDER BY random()` scan in the moments fallback.** Fine at 100 entries, worth
  revisiting at P1.
- ~~**Transcribing the audio track of a video.** Cut from the transcription phase rather than
  shipped shaky.~~ — **struck Aug 18, 2026: phase 16 shipped it on Aug 17**, and it did not need the
  device checklist run first. **The premise below was false and that is the interesting part**: a
  diagnostic handed `AVAudioFile(forReading:)` a real H.264 + AAC mp4 and it opened it, reading
  22050 frames at 44.1 kHz mono — Core Audio reads the track straight out of the container, so the
  separate-export machinery this bullet anticipated was built for a problem that does not exist. What
  the premise *had* been hiding: a video with **no** audio track fails to open, which would have
  burned a silent clip's whole six-attempt retry budget over hours. Original text kept below. The roadmap asks for it and `AVAudioFile` plausibly opens an MPEG-4
  container's audio track — but *plausibly* is the whole problem: nothing in this environment
  can run a single real transcription, so a second input path would be unverifiable on top of
  an already unverified first one. It is also the expensive one, because a backlog video has
  to be fetched to be read at roughly 70MB a minute. **What it needs:** the audio path
  confirmed on a device via `docs/Device-Verification/device-verification-transcription.md`. After that it is one
  clause in `TranscriptionQueue.isTranscribable` plus a rule about not doing it on cellular.
  **Aug 16, 2026: that prerequisite is now a runnable action rather than an unrun one.** The
  transcriber has produced real, accurate output on a real device — see the Phase 16 section — so
  what stands between this and being buildable is somebody running the checklist and writing the
  results down, not a question about whether the transcriber works.
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

## Phase 16 (video audio tracks) — **not blocked. Unrecorded.** (rewritten Aug 16, 2026)

**Nothing stands in front of this phase.** No credential, no platform gap, no design question.
~~It is unstarted~~ — **and as of Aug 17, 2026 it is shipped**: phase 16 landed as `b5eaa1c` (PR
#116), `ios/Rascal/Rascal/Media/VideoAudioTrack.swift`. **This section is kept because its diagnosis
was right and its premise was wrong**, which is a more useful record than a deleted heading: the
thing holding the phase really was *a document that disagrees with the world*, and when somebody
finally ran the code, the document was wrong in the other direction too — the separate audio export
everyone had specified around turned out to be unnecessary.

**The transcriber works, and it has been seen working.** Owner, Aug 16, 2026: `SpeechAnalyzer` has
produced a real transcription on a real device, on a build from that day, and the output was
accurate enough to capture his son's actual pronunciation of words. That is precisely the question
`docs/Device-Verification/device-verification-transcription.md` §0 — per-recording word accuracy — exists to answer.

~~**So the blocker is the file, not the feature.** The checklist still records **0 of 45** and still
opens with *"Nothing in this feature has ever run."* Phase 16's preflight #1 reads that document
rather than the world, so it hard-stops — **correctly, given what the document says.** The gate is
doing its job on stale input.~~ — **struck Aug 22, 2026. Both halves of that sentence are wrong,
and the same false quote was struck sixteen hundred lines further up in this very pass while this
copy went on repeating it.**

**The opening sentence was corrected on Aug 17, 2026, five days before this page stopped citing
it.** `docs/Device-Verification/device-verification-transcription.md` §0's opening now reads
`~~**Nothing in this feature has ever run.**~~ — **corrected Aug 17, 2026**`, with the owner's
account of the run quoted directly beneath it. So the gate is no longer shut on that sentence.

**And the count was stale in the other direction: it is `0 of ~~45~~ 52`, not 0 of 45.** Phase 79
added §4a's seven boxes on Aug 18, 2026 and the checklist says so on its own line 13. Counted
today: `grep -c '^- \[ \]'` returns **52** and `grep -c '^- \[x\]'` returns **0**, so *nothing has
been ticked* remains true and *how much there is to tick* grew by seven. **The 45 is not only
here** — `docs/roadmap-status.md`, `docs/phase-queue.md` and two files under `docs/sprint-aug16/`
carry it too, and they belong to other lanes and other phases; this page corrects only itself and
says where the rest are.

**The lesson is the narrow one, and it is about this document rather than that one.** The
correcting sentence at the top of this file — *"the checklist was corrected on Aug 17, 2026 and
this paragraph went on citing the dead sentence until Aug 22"* — was written in this same pass, and
**the author fixed the instance they were looking at and did not grep for the others.** A quotation
is a copy, and a copy has siblings: when a quoted sentence turns out to be dead, the fix is
`grep -rn` for the quote across `docs/`, not an edit at the cursor.

**The single action:** run `docs/Device-Verification/device-verification-transcription.md` on the current build and
record results, dates and device names. Start with §0, which is now largely **retrospective** — it
is writing down something that has already happened. Run the PR #22 audio checklist in the same
sitting; it is the stated prerequisite and it needs the same quiet room and the same device.

**Nobody but the owner may tick those boxes.** This section was written by an agent that has not
run the checklist, cannot run it, and must not record a result it did not observe. The whole value
of that file is that a ticked box means somebody watched it happen.

> **This is the file's recurring failure mode wearing a new face, and it is worth naming.** Every
> previous instance was a *claim copied forward without a grep* — something asserted as true that
> had stopped being true. This one runs the other way: **a verified real-world result was never
> copied *into* the document**, and a gate stayed shut on evidence that already existed. The
> standing rule — *a shipped-status claim carries the command that proves it* — only defends
> against the first kind. The second needs the opposite habit: when something is proven in the
> world, write it down where the gate will read it, in the same sitting.

The original reasoning, which was sound on the day and is why the gate exists at all: building video
transcription on an unverified transcriber stacks two unknowns in one branch, and if the output were
poor nothing would distinguish a bad extraction from a model that cannot read a four-year-old. That
argument has not been refuted — **it has been satisfied**, and the checklist is where that gets
recorded.

---

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

## §9 — Photo captioning has no on-device API to call (Aug 14, 2026)

**Phase 33's server half is complete and its device half cannot be written.** Not "is hard", not
"needs design" — there is no public, on-device, no-network API in the installed SDK that turns
pixels into prose, so the one function at the centre of the phase has nothing to call. Everything
downstream of it — a queue, a Settings row, a backoff ladder, a wire field — is scaffolding for a
body that cannot be filled in.

**The evidence, so nobody re-derives it.** Against iPhoneOS26.4 (Xcode 26.4.1), the only SDK
installed here:

```
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
FM=$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface
grep -n "public enum Segment" -A 3 "$FM"        # -> case text(...) / case structure(...), and nothing else
grep -ciE "CGImage|CVPixelBuffer|UIImage|CIImage" "$FM"   # -> 0
```

`Transcript.Segment` is the entire input vocabulary of the on-device model, and it has exactly two
cases, neither of which is an image. **That single grep is the whole answer**, and it is the one to
re-run when a new SDK lands.

**The near misses are worse than nothing, and each is a trap worth naming:**

- `Vision.ClassifyImageRequest` returns `ClassificationObservation { identifier, confidence }` — a
  taxonomy label, not a sentence. Composing prose out of labels invents the specifics, and a
  caption is durable data the server never regenerates. A permanent plausible lie about somebody's
  child is worse than an empty field.
- `VisionKit`'s `ImageAnalysis.transcript` is OCR of text *inside* the picture.
- `AnalysisTypes.visualLookUp` is **server-backed**. Reaching for it would send a child's
  photograph to a third party. That is forbidden by the product's own promise that nothing leaves
  the device — `docs/memory-app-roadmap.md`'s on-device guardrails and rule 7's "on-device AI
  output is durable data" premise. **Not rule 4**, which an earlier draft of this cited: rule 4 is
  "no third-party dependencies", about SPM and CocoaPods, and it has nothing to say about where
  bytes go.
- `ImagePlayground` runs the other way: text in, image out.
- `MediaAccessibility`'s `MAImageCaptioningCopyCaption` exists and has since iOS 13, but it is a
  *metadata accessor* — it reads an XMP field a human or another tool already embedded. It runs no
  model. (Worth a measurement spike as a different, smaller feature; see below.)

**The roadmap's scheduling claim is unverified and has been corrected.** It read *"on-device image
input landed in the iOS 27 wave"*, in the past tense, about a release whose SDK is not installed
here — and `docs/phases/phase-17.md` already quotes it forward as settled. The half that is
confirmed is *not available now*. When it arrives is not something this repo has checked.

**One shippable alternative, if it is ever wanted:** `MAImageCaptioning` covers the entire 18.6
install base, needs no model, no Apple Intelligence hardware, no battery and no network — and
because the text is human-authored rather than machine-invented, it sidesteps the permanent-lie
hazard entirely. The hit rate on photos straight from an iPhone camera is unknown and probably
low, so it is worth a measurement before it is worth a phase. It is a different feature from the
one the roadmap describes, so it is the owner's call.

### Re-verified Aug 16, 2026, and the measurement now exists (phase 46)

**The grep above was re-run and the block is unchanged.** Same SDK — iPhoneOS26.4, Xcode 26.4.1.
`Transcript.Segment` is still exactly `case text` and `case structure`, and the interface grep for
`CGImage|CVPixelBuffer|UIImage|CIImage` still returns **0**. Nothing about the platform half of
this section has moved.

**`MAImageCaptioning` was verified to work rather than assumed to.** `CaptionProbeTests` writes a
caption into a real JPEG with `MAImageCaptioningSetCaption` and reads it back through the same
`MAImageCaptioningCopyCaption` call the probe uses. The round trip passes, so **the reader is not
in question — only the population is.** The header confirms what it reads:
*"This checks for XMP metadata field: `Iptc4xmpExt:AOContentDescription`."*

**The owner's call was: measure first.** `CaptionProbe` and its Settings row ship as a
**diagnostic, not a feature** — it walks the newest 500 on-device photos, counts how many carry
that field, and reports a rate plus a few examples. It writes nothing, uploads nothing, persists
nothing, and never pulls an iCloud original.

**Aug 16, 2026: the measurement is runnable now, and is no longer waiting on a build.** This
section previously said it needed a TestFlight build. The owner has a current device build from
Aug 16 carrying `CaptionProbe` and its Settings row, so the only remaining input is a real camera
roll and an evening. Run it with `docs/Device-Verification/device-verification-captions.md`.

### Re-verified Aug 22, 2026. The platform block has not moved, and the owner will measure this week

**Owner's call, Aug 22, 2026: keep the probe, run the measurement this week.** No code changes.
The threshold table immediately below already decides the outcome the moment the number exists, so
there is nothing to design and nothing to argue about — there is a number to go and get.

**The section's own re-check command was re-run today, against the same and only installed SDK.**
iPhoneOS26.4, Xcode 26.4.1 (17E202). `Transcript.Segment` is still exactly `case text` and
`case structure`, and the `CGImage|CVPixelBuffer|UIImage|CIImage` count against the
FoundationModels swiftinterface is still **0**. **Eight days on, nothing about the platform half of
this section has changed** — so §9's factual core is *re-verified, not stale*, and the right
treatment is this note rather than a rewrite. That distinction is the reason for running the grep
instead of trusting the paragraph: a section that turns out to be correct should be marked correct
with a date, so the next reader knows how old the last look was rather than how old the prose is.

**The checklist itself was carrying a dead prerequisite until today, and that is fixed.**
`docs/Device-Verification/device-verification-captions.md:3` opened *"Needs a TestFlight build and
a real camera roll"* — superseded on Aug 16, 2026, when the owner took a device build carrying
`CaptionProbe` and its Settings row. **The paragraph directly above recorded that six days ago and
the checklist never heard.** That matters more than an ordinary stale line because **the checklist
is the instrument somebody opens in order to do this**: its first sentence named the thing that had
stopped it, so the reader most likely to run the measurement was the reader most likely to be told
not to bother. Phase 111 struck it; the real remaining input is a real camera roll, years of it,
which a simulator cannot supply. **The historical entry in `docs/decisions-log.md` was deliberately
left alone** — it was true on the day it was written, and a log is not a status page.

### The decision rule, set before the number is known

This section already warns that a disappointing result can be quietly reinterpreted later as a
reason to build anyway. **The defence against that is a threshold agreed in advance**, so here it
is, as the owner's rule, Aug 16, 2026:

| Measured rate | Outcome |
|---|---|
| **Under 20%** | Delete `CaptionProbe` and `CaptionProbeScreen`. **Close phase 33.** A caption writer costs a SwiftData migration over every media row plus the clobber guard; four photos in five with an empty field does not justify it, and an inconsistently populated caption makes a search result unexplainable — the parent cannot tell why one photo matched and its neighbour did not. |
| **20–50%** | Keep the probe as recorded evidence. **Do not build the writer.** Revisit only if an SDK ships real on-device captioning. |
| **Over 50%** | The writer earns a phase — and it lands with the clobber guard in `Media.applyServerSummary` and `SyncEngine.differs(_:from:)` **in the same commit**, exactly as this section already specifies below. |

**A rate is only as good as the library it was measured against.** One phone is one data point, and
a photographer's roll and a parent's roll are not the same population; if the number lands near a
boundary, run it on a second phone before applying the rule.

**Two things deliberately did not ship with it, and both would have been premature:**

- **No caption writer, and therefore no caption state ladder.** The ladder is a SwiftData
  migration on every media row, and committing to it before the number is known is exactly the
  mistake this section warned against.
- **No clobber guard.** `Media.applyServerSummary` and `SyncEngine.differs(_:from:)` both handle
  `caption` unguarded, so **they agree with each other and there is no live defect**. A guard now
  would guard a writer that does not exist. The clobber's deferral, recorded by phase 41, now
  points at this measurement rather than at a phase that may never land.

**If the number comes back near zero, the honest outcome is that `CaptionProbe` and
`CaptionProbeScreen` are deleted and 33 closes.** That is a real possible result of this work and
it is written down here so it is not quietly reinterpreted later as a reason to build anyway.

**One thing to fix on the way in, whenever this unblocks.** The pull path already clobbers
captions, and it has since before there was anything to clobber. `Media.applyServerSummary`
(`Media.swift:210`) writes `caption = summary.caption ?? caption` **outside** the
`!hasUnpushedTranscript` guard directly above it, and `SyncEngine.hasUnpushedChanges(_ media:)`
(`SyncEngine.swift:660`) tests transcripts and upload state and nothing else. It is the Aug 9
transcript defect, pre-installed on the caption field.

**It is inert today and that is not luck** — `Media.caption` has exactly one writer in the whole
app and it is that same server-fold line, and `RascalAPI.writeDerived` sends the transcript alone,
saying so in a comment at `RascalAPI.swift:267`. Nothing produces a caption, so nothing can be
overwritten. **It stops being inert the moment this phase writes the first one.**

The fix is not separable from the phase. A guard needs a caption sync state to read, and that
state is the same SwiftData migration over every media row that the phase needs anyway — which is
why it was never worth doing alone. Whoever builds the writer extends `hasUnpushedChanges(_ media:)`
and moves the caption line inside a guard **in the same commit**, and mirrors it in
`differs(_:from:)` at `SyncEngine.swift:633`, whose doc comment promises it matches
`applyServerSummary` exactly. Owner's call, Aug 15; carried here by phase 41 on Aug 16.

---

## §10 — Monetization: a prerequisite **errand**, not a blocker (reclassified Aug 16, 2026)

Phase 37 (entitlement and StoreKit) cannot be written against nothing. Two account actions come
first, and both are yours — this file's original terms exactly: a credential or an account only you
have.

- **Enrol in the App Store Small Business Program.** D5 assumes 15%, and enrollment is what makes
  that true in year one. Subscriptions fall to 15% in year two regardless, so this is a year-one
  difference of 15 percentage points on every payment.
- **Create the subscription products in App Store Connect** — the annual and the monthly, ~~with the
  14-day trial and~~ **with no introductory offer** (corrected Aug 22, 2026 — the fourteen days are
  granted server-side and an Apple offer would stack a second fourteen on top; see step 5 below) and
  annual preselected per D1. Without product identifiers there is no StoreKit
  transaction to receive, no sandbox to test against, and nothing for the webhook to be sent about.

**Nothing else in D1–D6 is blocked.** 38 (lifecycle notices) needs no Apple account at all — it is a
job, two tables and three channels, and it can be built and tested before a single payment exists.
39 is a research task. And the print partner (D6) needs an account only once one is chosen, which
D6 explicitly does not do.

~~**This is recorded rather than acted on**: creating products and choosing price tiers were named
out of scope for the phase that wrote this, and doing either from here would be picking a price.~~

### That last line went stale the day it was written

**D1 settled the price on Aug 15** — $59.99/year or $5.99/month, annual exactly two months free,
annual preselected, a 14-day trial, and a permanent free tier. Creating these products no longer
requires a decision from anybody. What is left is data entry.

> **One word of that needed amending, Aug 22, 2026: *where* the 14-day trial lives.** D1 says
> "a 14-day trial" and does not say who grants it, and the runbook below read that as *an Apple
> introductory offer*. It is **server-side** — `constants.TRIAL_DAYS` and
> `entitlements.trial_ends_at`, written at family INSERT — and Apple is configured with none. The
> owner's call, today. `docs/decisions.md` carries the amendment against D1 with the same date;
> this is a note, not the record. **The reason it matters here is that this section is the runbook
> somebody types from**, and a decision that is ambiguous about implementation gets disambiguated
> by whoever writes the runbook, silently and once.

**This section blocks nothing currently in the queue.** Phase 37 sits downstream of the P0
behavioural gate — seven days of unforced use — which has nothing to do with money. Building
StoreKit before that gate passes is building a checkout for a shop that may not open.

**One part is time-sensitive anyway, and it is not the products.** Small Business Program
enrollment is reviewed by Apple, and the 15% rate applies from the start of the **next fiscal month
after approval**. Left until launch week it costs 30% for a month. The form is worth filing early
even though the products are not.

### The product identifiers, chosen Aug 16 and permanent once created

```
Subscription group:  Vellum Membership
Annual:              com.travisterry.childarchive.subscription.annual
Monthly:             com.travisterry.childarchive.subscription.monthly
```

**One group containing both durations**, so they are mutually exclusive and StoreKit treats
monthly → annual as a *plan change* rather than two live subscriptions. The `.subscription.`
segment keeps the namespace clear for a future non-renewing product — the printed book, per D6.
**App Store product identifiers cannot be renamed after creation**, which is why these were chosen
at a desk rather than mid-phase. Recorded as **D5a** in `docs/decisions.md`.

### The errand, in order. Each step gates the next.

1. **App Store Connect → Agreements, Tax, and Banking.** The Paid Applications agreement must be
   **active**: complete the banking details and the tax forms. Nothing else on this list is
   possible until it shows active.
2. **Enrol in the App Store Small Business Program.** Requires step 1. Note the fiscal-month lag
   above — this is the one worth doing now.
3. **Create the subscription group** `Vellum Membership`. **Renamed from `Dogear Membership` on
   Aug 17, 2026 with the product, and this line was the urgent half of that rename**: a
   subscription group name is **permanent on first save**, so working this runbook before it was
   corrected would have carried the dead name for the life of the listing. Nothing has been
   created yet, which is the only reason this edit was still possible.
4. **Create the two products** with the identifiers above, at **$5.99/month** and **$59.99/year**.
5. **Set the annual as the preselected option**, and create both products with **no introductory
   offer at all.** ~~configure the **14-day free trial** as an introductory offer, per D1.~~ —
   **corrected Aug 22, 2026 by the owner's call. This step would have given away twenty-eight free
   days, not fourteen.**

   The trial is **server-side and already granted**. A family row gets `entitlements.trial_ends_at`
   at INSERT from `constants.TRIAL_DAYS` (`models/family.py`), so day 0–14 is full membership for
   free before Apple is involved at all; on day 15 the board locks to the daily question and shows
   a CTA, and **when the parent taps Join, Apple charges immediately.** An Apple introductory offer
   on top of that is a *second* free fortnight: **Apple's introductory-offer eligibility is per
   Apple ID and per subscription group, and it cannot see `trial_ends_at`** — there is no field to
   tell it the fourteen days were already spent. The two clocks stack, and fourteen becomes
   twenty-eight.

   **This is the step where a wrong line costs money rather than time.** Nothing has been created
   yet, which is the only reason this is an edit and not an incident; a configured introductory
   offer is visible to every purchaser from the moment the product goes live.
6. **Record the App Store Server Notifications V2 endpoint URL.** D5 holds that the server writes
   the entitlement and every gate reads the server, so this URL is what phase 37 is built against.

**`ios/Rascal/RascalTests/Vellum.storekit` is now inconsistent with step 5, and it is iOS-lane
work.** The local StoreKit configuration phase 37b was written against carries two
`introductoryOffer` blocks — one per product — so the simulator's purchase flow currently rehearses
a free trial that App Store Connect will not be configured to offer. **Nobody working from this
file may edit it**: `CLAUDE.md` is explicit that an agent working in `api/` never edits `ios/`.
It is recorded here, and in `docs/phase-queue.md`, so that the inconsistency is owned rather than
discovered during the first sandbox purchase — where the symptom would be a paywall that offers a
trial in the simulator and charges immediately in sandbox, which reads as a StoreKit bug and is not
one.

**Apple's exact menu wording is not verified here.** These steps name destinations rather than
click paths on purpose — App Store Connect's navigation changes, and a stale menu path in a runbook
is worse than a described destination. Nobody on this branch has an App Store Connect session.

**Phase 37b shipped against a `.storekit` file and has never been exercised against Apple** (Aug 20,
2026). The client half — products, paywall, purchase, restore, the `Transaction.updates` listener —
is built and merged, and `ios/Rascal/RascalTests/Vellum.storekit` is the local configuration it was
written against. The errand above is unchanged and still gates the first real transaction: until
steps 1–5 are done there is no sandbox purchase to make, and **the `appAccountToken` round trip to
37a's webhook has never been observed end to end.**


---

## §10a — The webhook is built; ~~and cannot verify anything yet~~ **it verifies Sandbox today and still cannot verify Production** (Aug 20, 2026; item 1 closed Aug 22, 2026)

**Phase 37a shipped `POST /v1/webhooks/app-store`, the only code that writes
`entitlements.tier`.** It is tested, reviewed twice, and ~~**refuses every notification with
`401`** until the two items below are done~~ — **that was true until Aug 22, 2026. Item 1 is now
closed and only Production is still blocked.** The fail-closed design is unchanged and is still the
point: the signature is the
only thing standing between a stranger and somebody's billing state, so there is no branch that
accepts an unverified payload and no local bypass.

**Neither of these was the errand in §10, and neither waited on it.** §10 needs the Paid
Applications agreement before anything else can happen. These two did not: the app record already
exists, and the certificate was a public download — **which is how item 1 came to be closed on a
day when nothing about §10 had moved at all.**

### ~~1. Apple Root CA - G3 is not in the repository~~ — **CLOSED Aug 22, 2026. It is in the repository.**

**Fetched, verified twice, and committed.** `https://www.apple.com/certificateauthority/AppleRootCA-G3.cer`
answered **HTTP 200** with **583 bytes**, now at `api/src/rascal/certs/appstore/AppleRootCA-G3.cer`.

What the file is, read out of the file itself:

- `subject` and `issuer` are both `CN=Apple Root CA - G3, OU=Apple Certification Authority,
  O=Apple Inc., C=US` — self-signed, as a root must be.
- Valid `Apr 30 18:19:06 2014 GMT` → `Apr 30 18:19:06 2039 GMT`.
- SHA-256 `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`.

And what the code does with it: `rascal.services.app_store.load_root_certificates(CERTS_DIR)`
returns **1** anchor of 583 bytes, where it returned none, and the startup `ERROR` this item
described is gone. `pytest -k "app_store or webhook"` → **96 passed**.

**Why the blocker was real and why it was still stale, which are both true at once.** This section
said `www.apple.com` is refused at the egress proxy and that the root is carried by neither
`certifi` nor the container's system CA bundle. **All of that was correct — of the environment
phase 37a was built in.** What went stale is not the observation, it is the scope the sentence
implied. Written as *"the environment refuses it"* it reads as a property of the work; it was a
property of one machine, and the very next machine to open the file had ordinary internet access.
**A blocker inherits the environment it was written in, and the environment is part of the claim.**
The correct form was *"cannot be done from the branch that found it"*, which the top of this file
happens to say and this section did not.

**The documented verification step could not be followed as written, and replacing it was the real
work.** Both this item and `api/src/rascal/certs/appstore/README.md` said to compare the SHA-256
against *"the fingerprint Apple publishes beside the download"* on
<https://www.apple.com/certificateauthority/>. **That page was fetched on Aug 22, 2026 and contains
no fingerprints at all** — zero occurrences of *"fingerprint"* or *"SHA-256"*; it is a bare list of
download links. So the one instruction standing between a downloaded root and a trusted root was
unfollowable, and had been for however long. **An unfollowable verification step is worse than no
step**, because the next person either skips it or invents a substitute under time pressure.

**The substitute, and why it is a genuine second source rather than a file checked against
itself.** Apple Root CA - G3 also ships inside macOS, in the system keychain, put there by Apple
through an entirely different distribution channel:

```sh
security find-certificate -a -c "Apple Root CA - G3" -Z \
  /System/Library/Keychains/SystemRootCertificates.keychain
#  -> SHA-256 hash: 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179
cmp downloaded.der keychain.der
#  -> identical
```

Two Apple-controlled channels, byte for byte identical. **This is macOS-specific and that is a real
limitation**: a Linux checker cannot run `security` and needs a different second source. **The
method replaced the dead instruction in `api/src/rascal/certs/appstore/README.md` in the same
phase**, along with the macOS caveat — that file sits next to the code and is where somebody stands
when they need it, so a verification step that lives only on this page is a step that will not be
run.

### 2. `APP_STORE_APP_APPLE_ID` is unset

The app's **numeric** Apple ID from App Store Connect — not the bundle id. Apple's own library
refuses to construct a Production verifier without it, because a bundle id alone does not pin which
app a signed payload is about, so a Production notification cannot verify while it is missing.

It is on the app's page in App Store Connect and takes a minute to read off. Set it as a Fly secret;
`docs/runbook-deploy.md` §4 has the row.

**This does not wait on the Paid Applications agreement.** The app record has existed since
TestFlight, so unlike everything in §10 this one is available today.

**Still open, confirmed Aug 22, 2026.** `flyctl secrets list -a rascal-api` was read in full and
`APP_STORE_APP_APPLE_ID` is **absent**.

**What closing item 1 changed about this one, precisely.** Apple's library refuses to construct a
verifier without the app's numeric Apple ID **only for `Environment.PRODUCTION`** — a Sandbox
verifier needs the root and the bundle id and nothing else. So as of today **the Sandbox verifier
builds and Production does not.** Two consequences follow and they point in opposite directions:

- **The first sandbox purchase in §10 is now verifiable end to end.** The `appAccountToken` round
  trip that §10's closing paragraph calls never-observed is observable the moment steps 1–5 of that
  errand are done — the webhook will accept a Sandbox notification, and there is no longer a second
  thing to fix before the evidence exists.
- **Production is still blocked, and it fails the same way it always did**: `401`, loudly, on every
  Production notification. That is one secret away, and it is a minute at a keyboard rather than a
  decision.

### What is *not* blocked

Everything else in phase 37a. The table, the four guards, the ordering and sandbox isolation, the
entitlement read route and 986 passing tests are all in `main`'s history and need nothing from
anybody. **And nothing here blocks the app**: the webhook is the only route affected, no client
calls it, and the existing paywall reads `entitlements` exactly as it did before.

---

## §11 — Apple's `sub` has never been observed across a revoke and re-authorize (Aug 16, 2026)

> ~~**Owner, Aug 19, 2026: deferred — "not today, but remind me about it."**~~ — **the reminder was
> delivered on Aug 22, 2026 and the owner's answer was to run it, with a pre-step. See *Rewritten
> Aug 22, 2026* below; this note is kept because the deferral is why the experiment is three days
> older than the code it tests.** So this stayed open by
> decision rather than by neglect, and the reminder is this paragraph: it is a five-minute errand on a
> device, and it is the last unobserved assumption underneath account recoverability.
>
> **What changed while it waited:** phase 93 added two tests that assert the *failure* mode rather
> than the feature — a changed `sub` after a revoke produces a second, empty archive with the first
> still in the database owned by a user nobody can sign in as, and nothing links the two by email.
> `services/auth.py:44-52` already described that consequence in its own docstring; the suite did not.
>
> That does **not** narrow this item. It means the cost of the wrong answer is now executable instead
> of prose, so whoever runs the experiment can see immediately which branch they landed in. The
> experiment itself still needs a real Apple ID, because the suite mints its own tokens and can only
> assert what it chose to simulate.

**Phase 53 is built and tested and may not be called complete on that.** The route, the four
event behaviours, the signature verification and nineteen tests are on `main`. What has never
happened is the thing the design rests on, and it needs your phone.

**The assumption.** `credentials.subject_id` is Apple's `sub`, and the whole recoverability
story — revoke, come back, land on the same archive — depends on that `sub` being **the same
value** after a parent removes the app from their Apple ID and signs in again. Apple documents
it as stable per Apple ID per developer team. It has never been observed here, not once, and
no test can observe it: the suite signs its own tokens, so it can only prove that the code does
the right thing *given* a stable `sub`.

**If the `sub` changes, the design is wrong rather than buggy.** A returning parent would get a
brand-new empty account, their archive would sit behind a `users` row nothing can reach, and
every one of the nineteen passing tests would still pass. **Stop and say so rather than
patching it** — the fix would be a redesign, and it would need to happen before anybody relies
on revocation being recoverable.

### Rewritten Aug 22, 2026 — two pre-steps, and one query that would have misreported

**Owner's call, Aug 22, 2026: run it for real, but attach an email credential first.** What makes
that possible today and not on Aug 19 is that **Resend is live** — `MAIL_PROVIDER`, `MAIL_API_KEY`
and `MAIL_FROM` are all `Deployed` on `rascal-api` and this service has sent real mail (§13). The
magic link actually arrives now. Before that it was a route that returned `202` into a `console`
provider, which is not a way back into an account.

**Pre-step A — attach an email credential to the account before revoking anything.**

```
POST /v1/me/credentials/email        { "email": "<an inbox you control>" }
```

Then open the link it mails, which completes through `POST /auth/email/complete`; the credential is
created inactive and **the click is what activates it**, so nothing is proved until the mail lands.
Confirm with `GET /v1/me/credentials` that the row is there and live.

**This is not belt-and-braces, it is what makes the bad branch survivable.** If step 5 comes back
with a different `subject_id`, the failure this section describes is *a production archive sitting
behind a `users` row nobody can sign in as* — and with an email credential attached, that stops
being true: sign in by magic link, land on the same `users` row, and the new Apple subject attaches
to the account that already owns the archive. **The repair uses only shipped code.** Without the
pre-step, discovering the answer and losing the archive are the same event.

**Pre-step B — confirm Apple is actually configured to call us.** Step 3 below reads the log for a
server-to-server notification, and **nothing in this repository records that the Sign in with Apple
notification endpoint was ever registered with Apple** — it is a field on the Services ID / primary
App ID configuration in the Apple Developer portal, and it is set by hand. Check it before the run.
If it is unregistered, step 3 prints nothing, and **an unregistered webhook and a broken handler
look identical from the log side** — the experiment would report a code defect that does not exist.
`services/auth.py` and phase 53's nineteen tests all exercise the handler given a delivered
notification; none of them can tell you that Apple was told where to deliver it.

### The run

- [ ] **0.** Do pre-steps A and B above. Neither is optional: A is what makes a wrong answer
  survivable, B is what stops step 3 misreporting.

- [ ] **1.** Sign in on the device. Record `users.id` and `credentials.subject_id`:
  ```bash
  fly ssh console -a rascal-api -C "python -c \"
  import asyncio
  from sqlalchemy import text
  from rascal.db import get_sessionmaker
  async def m():
      async with get_sessionmaker()() as s:
          for r in (await s.execute(text('''select c.id, c.user_id, c.provider, c.subject_id,
              c.revoked_at from credentials c'''))).all():
              print(r)
  asyncio.run(m())\""
  ```
  `users.id` = ______________________  `subject_id` = ______________________

- [ ] **2.** Settings → Apple ID → Sign-In & Security → Sign in with Apple → find Vellum →
  **Stop Using Apple ID**.

- [ ] **3.** Confirm the webhook arrived. **Read it from the logs, not from the app UI** — the
  app cannot tell you whether the server heard anything.
  ```bash
  fly logs --app rascal-api | grep -i "apple credential revoked\|apple notification"
  ```
  What it printed: ______________________

  **If this prints nothing, do not conclude anything about the code until pre-step B is
  confirmed.** An endpoint Apple was never told about and a handler that does not run produce the
  identical silence here.

- [ ] **4.** Confirm `revoked_at` is set on the credential, and that every refresh token **for that
  user** is revoked. Re-run the query from step 1, and — **substituting the `users.id` you wrote
  down in step 1** — run:
  ```bash
  fly ssh console -a rascal-api -C "python -c \"
  import asyncio
  from sqlalchemy import text
  from rascal.db import get_sessionmaker
  USER_ID = 'PASTE_USER_ID_FROM_STEP_1'
  async def m():
      async with get_sessionmaker()() as s:
          print((await s.execute(text('''select count(*) from refresh_tokens
              where user_id = :u and revoked_at is null'''), {'u': USER_ID})).scalar())
  asyncio.run(m())\""
  ```
  Expect `0`. Got: ______

  > **The query was unscoped until Aug 22, 2026, and it would have failed a correct system.** It
  > read `select count(*) from refresh_tokens where revoked_at is null` across **every user**, but
  > `revoke_all_refresh_tokens` (`api/src/rascal/services/tokens.py:99-110`) revokes
  > `where RefreshToken.user_id == user_id` — per user, by design, because Apple told us about one
  > parent's consent and not about anybody else's. Any other live session in production makes the
  > count non-zero, **including the session belonging to whoever is running this checklist**, and
  > the step would then read as *"revocation did not work"* on a system where it worked perfectly.
  >
  > **The general shape: a verification query has to be scoped exactly as tightly as the behaviour
  > it verifies.** Wider is not safer — it is a different assertion, and here it is one the code
  > never promised and should never satisfy. `PASTE_USER_ID_FROM_STEP_1` is deliberately not valid
  > input: pasting this command unedited fails loudly rather than deploying a blank, which is the
  > rule §13 wrote down after a placeholder ellipsis reached Fly as a real secret value.

- [ ] **5. Sign in again, and confirm you land on the same `users.id`.** **This is the box the
  phase turns on.** Compare against what you wrote in step 1.
  Same `users.id`? ______  Same `subject_id`? ______  `revoked_at` cleared? ______

- [ ] **6.** Confirm the archive is still there — open the timeline and check the entry count
  is what it was before step 2.

**If step 5 shows a different `subject_id`**, stop. Do not adjust anything. Record what you saw
here and raise it: the recoverability design needs rethinking, and until it is rethought,
nothing should tell a parent that removing the app is reversible.

**"Stop" no longer means "and lose the archive", which is the whole point of pre-step A.** With an
email credential attached, sign in by magic link: that lands on the same `users` row, and the new
Apple subject attaches beside the email credential rather than founding a second account. The
archive is reachable again with shipped code and no migration. **Do that as recovery, not as
investigation** — write down both `subject_id` values first, because they are the finding, and the
repair overwrites the state that proves it.

**Not blocked on a credential.** This is on the list because it needs a physical device and a
real Apple ID, which is the same reason the twelve device-verification checklists are.

---

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

## §13 — The marketing site and the email provider: an **errand**, not a blocker (Aug 16, 2026)

D7, D8 and D8a settle where the landing page lives and who sends the mail. What they cannot settle
is a domain purchase, three vendor accounts and a repository audit — this file's original terms
exactly: a credential or an account only you have.

**None of this blocks anything currently in the queue**, and it is filed here for the same reason
§10 says it about StoreKit rather than as a warning. ~~**The marketing send is downstream of the P0
behavioural gate — seven days of unforced daily use — which has not started.** The page and the
`POST /v1/subscribe` endpoint may be built before any of this exists; only the *marketing send*
waits on it.~~ — **struck Aug 22, 2026 on the owner's call. The gate no longer gates marketing
email: the broadcast has been armed since Aug 19, 2026 and has sent on four consecutive days.** The
evidence is in *The broadcast is live* below. (Transactional mail is a separate question and was
never gated on P0 — phase 57's
magic-link path already sends, ~~or would if `MAIL_PROVIDER` were ever set~~ — **`MAIL_PROVIDER` is
`Deployed` and it does send**.)
Phase 60 is buildable today against a Turnstile test key and a Resend test key, and nothing about
it needs a domain.

### The errand, in order. Each step gates the next.

1. **Clear the name, then buy the domain.** Three checks before money changes hands, none of which
   exists anywhere in this repo today — **`decisions.md` open item 1 settled `Dogear` on Aug 12,
   2026 and recorded no clearance work at all, and the Aug 17, 2026 rename to `Vellum` recorded
   none either** (open item 15). **The rename made this step more urgent rather than resetting
   it**: *Vellum by 180g* is a live software trademark in a publishing-adjacent category, which
   is a nearer neighbour than anything Dogear had. Treat this as the first pass rather than a
   re-verification: the **social handle**, an **App Store search-collision check** for apps
   shipping under a similar name, and a **trademark search** in the classes an app would fall in.
   A name that fails any of these is cheaper to change now than after a domain, an App Store
   listing and a sending reputation are attached to it.
2. **Point DNS, then turn on the GitHub Pages custom domain and *Enforce HTTPS*.** Both settings
   live on the `Rascal-Marketing` repository. **Enforce HTTPS is the one to verify by eye rather
   than assume** — it cannot be enabled until the certificate is issued, so a domain pointed and
   configured in one sitting will often leave it off, and the page then serves happily over plain
   HTTP with nothing failing to draw attention to it. D7 already accepts that HSTS is unavailable
   on this host; this checkbox is the only transport protection left, and it is the whole of it.
3. **Create a free Cloudflare account and a Turnstile widget.** It yields a **site key** (public,
   goes in the page) and a **secret key** (server-side, becomes `TURNSTILE_SECRET_KEY`). Turnstile
   is host-independent, so this is unaffected by the site living on GitHub Pages. No paid plan and
   no DNS migration is involved — Cloudflare is not the CDN here, only the widget's issuer.
4. **Create the Resend account and authenticate a *sending subdomain*, never the apex**, then
   publish **SPF, DKIM and DMARC** on it. Sending from the apex ties the deliverability of a
   marketing send to every other use of the root domain, which is the failure a subdomain exists to
   contain. Resend issues the API key, and **it is filed as `MAIL_API_KEY`, not `RESEND_API_KEY`** —
   the setting is provider-agnostic because the port is (D8a), and `config.py` has carried that
   name since phase 56. **There is no `RESEND_API_KEY` and nothing reads one.** The secrets table
   in `runbook-deploy.md` is the authority on the name, and it records that phase 60 may rename it
   at no cost if you would rather it said Resend.
   - **The key currently in the local `.env` was pasted into a chat transcript and must be
     rotated.** It is inert either way until phase 60 builds the Resend provider — nothing reads
     it, and `MAIL_PROVIDER` remains `console` — but a key that has been through a transcript is
     not a key, and rotating it costs one click.
5. **Audit the `Rascal-Marketing` repository before it is public in earnest.** Three things, and
   the first is the one with a wrong instinct attached: **read the git history for anything ever
   committed and later deleted** — a deletion commit does not remove the object, and **a credential
   found this way is rotated, not rewritten out of history.** Then set the commit author to the
   GitHub **`noreply`** address, and check that no workflow runs with secrets on a pull request
   from a fork.
   - **`api/seeds/prompts.yaml` and `docs/mission-library.md` never enter that repository**, whole
     or in generated slices, per D7. A prompt sampler on the page is a hand-picked handful, typed
     in by hand. It is the one asset in this project a competitor would actually want, and a
     generated slice is how it would leave.

**Vendor menu wording is not verified here.** These steps name destinations rather than click
paths, on purpose and for the same reason §10 does it: vendor navigation changes, and a stale menu
path in a runbook is worse than a described destination. Nobody on this branch has a session with
Cloudflare, Resend, or a registrar.

### Every value this errand produces, and exactly where it goes (Aug 18, 2026)

Written because the steps above say *what to create* and stop short of *where the result lands*,
and the second half is where an errand stalls at a keyboard.

> ### ~~None of these is set~~ — **the errand ran on the evening of Aug 18, 2026. Six of seven values are deployed.**
>
> `fly secrets list --app rascal-api`, run Aug 19, 2026, shows all six marketing values **Deployed**:
> `MAIL_PROVIDER`, `MAIL_API_KEY`, `MAIL_FROM`, `TURNSTILE_SECRET_KEY`, `RESEND_AUDIENCE_ID` and
> `MARKETING_ORIGINS`. `MARKETING_EMAIL_ENABLED` is **absent, deliberately** — see below. Verified
> against the platform, not inferred from a commit.
>
> The domain is `getvellumapp.com`: registered, on GitHub Pages, HTTPS enforced, apex not project
> path. `mail.getvellumapp.com` is verified at Resend — a subdomain, never the apex, as step 5
> required. **The first real email this service has ever sent reached the owner's inbox**, not spam.
>
> So the paragraph this note replaces was true when written and became false within about two
> hours. The steps below are kept rather than struck, because the *order* is still the record of how
> it is done — and a future domain move repeats it.
>
> **`MARKETING_ORIGINS` was missing from the table entirely**, and it became load-bearing the moment
> the site moved to the apex: its default was the `github.io` origin, and the browser now sends
> `https://getvellumapp.com`. It holds both. A value-and-destination table that omits the one value
> CORS depends on is the table's own failure mode, not an oversight in the errand.
>
> **The site key is public by design and its being committed is correct, not a leak.** Cloudflare
> issues two: the *site* key belongs in markup where the browser can read it, and the *secret* key
> is the one `rascal-api` holds. `Rascal-Marketing`'s `site.js` already carries that explanation in
> a comment above the constant — read it there rather than re-deriving it, so the file and this page
> cannot drift into disagreeing about whether a committed key is a problem. Written here because a
> key visible in a public repo is exactly the shape that gets a security issue filed against a
> correct configuration.
>
> **The one thing that actually went wrong, and it was this file's fault.** Two of those secrets were
> set to placeholder text: `TURNSTILE_SECRET_KEY` held a literal ellipsis, and `RESEND_AUDIENCE_ID`
> held `…`, which surfaced as `/audiences/%E2%80%A6/contacts → 422` in a Fly log. The commands in the
> table below are written to be copy-pasteable **and** contain fill-in-the-blanks that are also valid
> shell, so pasting one verbatim succeeds and deploys the blank. Both are corrected.
>
> **The rule that follows, and it generalises past this page:** a runbook command meant to be pasted
> must not contain a placeholder that the shell will accept. Use an obviously-invalid marker that
> fails loudly — `PASTE_KEY_HERE` — or a `$VARIABLE` the shell refuses when unset. A quiet 422 in a
> log is the expensive version of a syntax error.

**Turnstile was the one step with no prerequisite.** It needed no domain and no DNS, which is why it
could be done in isolation — and it is what made the signup form stop saying *"signups are not open
yet."* Done: site key `0x4AAAAAAEUwlZkn4ah9zsvA` committed and deployed.

| # | What you create | Where the value goes |
|---|---|---|
| 1 | Cloudflare Turnstile widget → **site key** (public) | `Rascal-Marketing`, `src/assets/site.js`, `SIGNUP.TURNSTILE_SITE_KEY`. Then `npm run build && npm run check` and push |
| 2 | The same widget's **secret key** | `fly secrets set --app rascal-api TURNSTILE_SECRET_KEY='…'` |
| 3 | Resend API key — **full access, not `sending_access`**, because the contacts upsert needs more than send | `fly secrets set --app rascal-api MAIL_API_KEY='re_…'` — **the setting is `MAIL_API_KEY`, not `RESEND_API_KEY`; nothing reads the latter** |
| 4 | Resend **Audience** → its id | `fly secrets set --app rascal-api RESEND_AUDIENCE_ID='…'` |
| 5 | A verified **sending subdomain**, never the apex, with SPF/DKIM/DMARC | `fly secrets set --app rascal-api MAIL_FROM='Vellum <hello@mail.yourdomain>'` and `MAIL_PROVIDER=resend` |
| 6 | The domain itself | `Rascal-Marketing`, `site.config.json` → `DOMAIN` and `ORIGIN`. **`ORIGIN` is empty on purpose**; the moment it holds a real `https://` origin the build starts emitting canonicals, absolute OG URLs and `sitemap.xml` |
| 7 | GitHub Pages custom domain + **Enforce HTTPS** | Repository settings. **Verify the checkbox by eye** — it cannot be enabled until the certificate issues, so a domain configured in one sitting usually leaves it off, and the page then serves over plain HTTP with nothing drawing attention to it |

**Deliberately not in that table: `MARKETING_EMAIL_ENABLED`.** It is the switch that lets the daily
broadcast actually send, it defaults false, and it is kept separate from the credentials precisely
so that finishing the table above does not start mailing anybody. ~~Open item 12: **no marketing
email before the P0 behavioural gate**, which is seven days of unforced daily use and has not
started. When it is time: `fly secrets set --app rascal-api MARKETING_EMAIL_ENABLED=true`.~~ —
**that time came on Aug 19, 2026. The switch is on and the design worked exactly as written**: the
credentials landed on Aug 18 and mailed nobody, and a separate deliberate act armed the send a day
later. Keeping the flag out of the credentials table is why "the errand finished" and "we started
emailing people" were two events rather than one. **The evidence is in *The broadcast is live* at
the end of this section**; everything between here and there is the history of getting to it.

~~**Two things to do before that flag, in this order.** Exercise `POST /v1/subscribe` once from the
real GitHub Pages origin, which is the first test of CORS and of a genuine Turnstile verification —
neither has ever run against the deployed API. Then run
`python -m rascal.jobs.broadcast --date <a day> ` against an audience containing **only your own
address**, because the Resend Broadcasts API has never been called by this service and its
two-step create-then-send shape is implemented from documentation rather than observation.~~

**Struck Aug 22, 2026: this is history, not an instruction, and it was reading as one.** *"Before
that flag"* names a moment that passed on **Aug 19, 2026**, when `MARKETING_EMAIL_ENABLED` was set —
and its second half rests on a premise the paragraphs below it demolish: the Resend Broadcasts API
**has** been called by this service, four times, and its two-step create-then-send shape is observed
rather than documented — the four `resend_id`s in *The broadcast is live* are what came back. It is
kept in place because what each half was worth is the record of how the send was armed, and because
the second half's caution turned out to be unfalsifiable after the fact, which is its own lesson.
**With this struck, the one thing §13 still owes is at the end of this section: revoke the exposed
Resend key at Resend** — a click, no deploy, no code. (The contacts-scope question in *The broadcast
is live* is a diagnostic to run before anyone widens that key, not a thing owed.)

**Of those two, the first is done.** `POST /v1/subscribe` has now been exercised from the real origin
— that signup is what revealed that Resend's contacts API does **not** do double opt-in, which phase
88 then fixed. So CORS and a genuine Turnstile verification have both run against the deployed API
for the first time.

~~**The second has not, and the machine for it does not exist.** `fly machine list --app rascal-api`,
Aug 19, 2026, returns four: two `app` running uvicorn, one running `python -m rascal.jobs.scheduler`,
one running `python -m rascal.jobs.notify`. **There is no broadcast machine**, so §4d of
`runbook-deploy.md` is still accurate that it was never created. The broadcast dry run against an
audience containing only the owner's own address is therefore still ahead, and it remains the right
first call: the Resend Broadcasts API has never been invoked by this service, and its two-step
create-then-send shape is implemented from documentation rather than from observation.~~

**Struck Aug 22, 2026: the machine exists, and it was created on Aug 19 — the same day this
paragraph was written.** `683e1eea463d28` / `late-fire-837`, created **2026-08-19T02:15:36Z**,
running `python -m rascal.jobs.broadcast`. There are **five** machines now, not four. The Resend
Broadcasts API has been invoked four times and its two-step create-then-send shape is observed
rather than documented — the four `resend_id`s in *The broadcast is live* are what came back.

**Whether the dry run against a one-address audience actually happened first is not recorded
anywhere**, and this file cannot recover it: the earliest row in `email_broadcasts` is
`2026-08-19`, hours after the machine was created, and a dry run would have produced a row exactly
like a real one. **So the advice was taken or it was skipped, and the evidence does not
distinguish.** That is the cost of a caution written in prose with no artifact behind it, and it is
the reason to prefer a check that leaves a trace.

**One item on this page is still open, is not in the table, and got worse rather than better:** the
Resend key that went through a chat transcript and **has not been rotated** — confirmed by the owner
Aug 18, 2026.

The original entry excused it: *"It is inert (`MAIL_PROVIDER` is `console` and nothing reads it), but
a key that has been through a transcript is not a key. Rotate it before step 3 rather than after, so
the key that reaches Fly is the one that was never exposed."*

**That mitigation has expired.** `MAIL_PROVIDER` and `MAIL_API_KEY` are both `Deployed` on
`rascal-api` as of Aug 19, and the service has sent a real email through Resend — so the provider is
no longer `console`, something does read the key, and step 3 has already happened. The advice was
"rotate before step 3"; step 3 ran first.

**Answered by the owner, Aug 19, 2026: the key deployed on Fly is a new one.** It was minted during
the errand, so the exposed key never reached production. That was the question, and it was one only
the owner could answer — `fly secrets list` shows a digest and the value is write-only by design,
which is correct and also why this had to be asked rather than checked.

**One thing remains, and it is smaller than it was.** The exposed key is not in use anywhere, but it
is presumably still *valid* at Resend, and a valid key sitting in a chat transcript is a credential
with no owner. **Revoke it at Resend** — not because anything reads it, but because nothing should be
able to. No deploy, no secret to set, no code: it is a click in the Resend dashboard, and it closes
this item completely.

**The general shape is worth keeping even after this is closed.** A risk note that carries its own
mitigation — *"it is inert, so this is not urgent yet"* — has a shelf life measured by whether the
mitigation still holds, and nothing re-reads it on the day it stops holding. This one was written
about a `console` provider roughly two hours before the provider became `resend`.

### The broadcast is live, and that is intended (Aug 22, 2026)

**Owner's call, Aug 22, 2026: the P0 behavioural gate no longer gates marketing email.** Read from
Fly and from the production database rather than inferred from a commit:

- The machine exists. `683e1eea463d28` / `late-fire-837`, created **2026-08-19T02:15:36Z**, command
  `["python","-m","rascal.jobs.broadcast"]`, process group `(none)`.
- `MARKETING_EMAIL_ENABLED`, `MAIL_PROVIDER`, `MAIL_FROM` and `RESEND_AUDIENCE_ID` are all
  **Deployed** secrets on `rascal-api`.
- `email_broadcasts` holds **four rows, every one `status='sent'`** — none failed, none skipped:

  | send_date | pool_index | resend_id | sent_at |
  |---|---|---|---|
  | 2026-08-22 | 11 | `d9e6b965-c54c-406a-9fa0-b89fd5f5a512` | 12:15:05Z |
  | 2026-08-21 | 10 | `f3e802d5-f091-43e5-a66b-4772adae4223` | 12:15:06Z |
  | 2026-08-20 | 9  | `6f8ab6f3-e217-45bc-bbea-c4fe02ead438` | 12:15:07Z |
  | 2026-08-19 | 8  | `c4a32683-7972-4658-9710-300be51e407c` | 12:15:08Z |

- **The hourly wake is safe because the job checks its own hour, not because the machine is
  scheduled precisely.** Today's 13:15Z run logged
  `broadcast: not the send hour — it is 09:15 EDT, sending at 08:00.` and did nothing.

**One thing is not known, and it is written down as unknown rather than estimated.** `MAIL_API_KEY`
is send-scoped: `GET /audiences/{id}/contacts` answers **403** from inside the production machine.
So **how many people received those four emails, and who they are, cannot be determined from this
repository, from Fly, or from the production database.** Only the Resend dashboard can answer it.
**No recipient count appears anywhere in this file on purpose** — a plausible number written here
would be indistinguishable from a measured one a week from now, and this is the first thing this
service has ever sent to people who are not the owner.

**That the key cannot read the audience is worth noticing rather than quietly fixing.** Row 3 of
the table above specifies a **full-access** Resend key, *"not `sending_access`, because the contacts
upsert needs more than send"* — and the key actually deployed answers `403` to a contacts read. Two
readings fit and this phase settled neither: it may be a narrower key that still covers every call
the service makes, or a latent failure that the next contacts call will find. **Do not widen the
key on the strength of this paragraph.** The check that would decide it is one `POST /v1/subscribe`
against the deployed API and a look at whether the contact appears — cheap, and nobody has run it
since the key was deployed.

---

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

## §15 — The GitHub billing token: an **errand**, not a blocker (Aug 20, 2026)

`GITHUB_BILLING_TOKEN` is unset, so the Actions cost card renders `unconfigured` with a setup
sentence. **That is a working state and nothing is broken while it lasts** — which is why this is
an errand rather than a blocker. The other six cards are unaffected.

**What is needed:** a **fine-grained** personal access token on github.com → Settings → Developer
settings → Fine-grained tokens, with Account permissions → **Plan → Read-only** and nothing else.
Only the account owner can mint it. Then `flyctl secrets set -a rascal-api GITHUB_BILLING_TOKEN=…`.

**Two things make this easy to get wrong**, both documented in `runbook-admin-console.md`:

- The repo-scoped classic token CI already holds **will not work.** This endpoint reads the
  *account's plan*, which no amount of `repo` scope grants.
- **A token missing `Plan: read` answers 404, not 403.** A bare "not found" reads as a mistyped
  username and sends you checking `GITHUB_ACCOUNT`, which will not be the problem. The card says
  so on its face for this reason.

**Why this card exists at all:** §0 and §0a above are both *"GitHub Actions is not running —
account billing"*, and the second one recurred a day after the first was resolved. Neither was
visible anywhere until CI simply stopped. This is the instrument that was missing. **It cannot
warn before a halt** — the API exposes no budget or quota, and the card says that too — but a
dollar figure that moves is better than the nothing there was before.

**Re-verified Aug 22, 2026: unchanged and still correct.** `GITHUB_BILLING_TOKEN` is confirmed
absent from `flyctl secrets list -a rascal-api`. The code path is built, tested, and degrades to an
`unconfigured` card, so nothing here needs writing — this note exists to record that somebody
looked, and when. **A section marked correct with a date is more useful than a section nobody has
touched**, because "unchanged" and "unread" are indistinguishable otherwise.

**When it is minted, read the second bullet above before reading anything else.** A token missing
`Plan: read` answers **404, not 403** — a bare "not found" reads as a mistyped account name and
sends you checking `GITHUB_ACCOUNT`, which will not be the problem. **That line was already in this
section and needed no addition**, which is worth saying rather than quietly adding a duplicate: the
phase 111 review flagged it as missing, and it was not.

---

## §16 — App Store Connect: **deferred**, and deliberately not requested yet (Aug 20, 2026)

~~Not blocked, because nothing is waiting on it.~~ — **true of the reporting key and only the
reporting key. Qualified Aug 22, 2026**: a second App Store Connect key, for uploading builds, is
owed now and a CI-driven TestFlight upload is waiting on it. See *Two different App Store Connect
keys* below. Recorded here so the credential requirement lives
where credential requirements live, and so the next person costing this out does not rediscover it.

> **`docs/phase-queue.md` said phase 37b's purchase proof "waits on §10a and §16", and it did
> not.** It waits on §10 — the Paid Applications agreement and the two products — and on a
> TestFlight build. §10a's remaining item gates *Production* notification verification, not a
> sandbox purchase, and this section's reporting key gated nothing at all. **Corrected in
> `phase-queue.md` on Aug 22, 2026 by phase 111**, and noted here because the wrong pointer was
> aimed at *this* section: a section whose own first line said nothing was waiting on it was named
> as a blocker by another document for two days, and neither page could see the other.

**Nothing App Store Connect can report before launch is a cost.** Revenue, proceeds, downloads,
impressions and conversion are all built from public App Store activity, and an app that has
never been released has none. `GET /v1/salesReports` requires at least one unit sold and answers
404 on an empty period. App Analytics needs an Admin-role `POST /v1/analyticsReportRequests` and
then one to two days before the first report exists — there is no same-day answer even after
launch. The API is free to call and publishes no billing endpoint at all, so the Apple card
carries the Developer Program membership and an honest sentence instead.

**What a future phase would need**, when TestFlight build state and tester counts go on the *Ops*
panel rather than this one:

- A `.p8` EC private key, its key id, and the issuer id — three new secrets.
- A **team** key. Individual keys cannot reach Sales and Finance.
- ES256 JWT signing with `aud: "appstoreconnect-v1"` and a ≤20-minute lifetime. **No new
  dependency:** `pyjwt[crypto]` is already installed and `services/push.py` already signs an
  ES256 provider token from a `.p8`, cached against its expiry. That is the pattern to copy.

**Not worth requesting until there is an app on the store**, since the data would be empty.

### Two different App Store Connect keys, and only one of them is deferred (Aug 22, 2026)

**This section was about a reporting key and said so nowhere.** Everything above concerns a **team**
key with **Sales and Finance** access, for revenue reporting — and that deferral stands exactly as
written: `GET /v1/salesReports` 404s on an empty period, App Analytics needs one to two days after
launch before a first report exists, and there is nothing to read until an app is on the store.

**A second, different key is owed now, for an unrelated reason, and this section never mentioned
it.** `.github/workflows/ios.yml` is **test-only** — it selects an Xcode, picks a simulator, runs
`xcodebuild test`, greps the log for new warnings, and uploads the log as an artifact. There is no
`archive` step and no upload step, so **CI cannot ship a TestFlight build at all.** That needs a
**build-upload** key, which is a completely different grant from Sales and Finance.

**Owner's call, Aug 22, 2026: mint the upload-only key now, defer the Sales and Finance key until
after launch.**

**The reason it is two keys rather than one wide one is that a key's access is fixed at
generation.** App Store Connect does not let you narrow or widen an existing key — changing access
means revoke and regenerate, and a revoke breaks whatever is already signing with it. So the
choices are one broad key today, minted for a reporting job that has no data to report and would
sit in CI holding Sales and Finance access for months, or two narrow keys minted when each is
actually needed. **This is the least-privilege choice and it costs a second errand during launch
week** — that cost is real and is accepted deliberately, not overlooked.

**What the upload key needs** is the same three-secret shape the reporting key would: a `.p8` EC
private key, its key id, and the issuer id. The ES256 signing pattern above is unchanged and is
still `services/push.py`'s. **Which role to pick is not settled here** — pick the narrowest one App
Store Connect offers that can upload a build, read it off Apple's own access list at generation
time rather than from this page, and **write down which one was chosen**, because it cannot be
changed afterwards and the next person will need to know what the key can and cannot do.

---

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

## §18 — the Instagram token expires, and ~~two repositories hold a copy~~ **only one does** — the clause struck Aug 22, 2026 so the heading says what the body already says

> **Renumbered from §17 on Aug 21, 2026.** It was filed as a second §17 on Aug 20 — two sections
> on this page carried the same number for a day. ~~Nothing anywhere referenced this one, so the
> collision was cheap to close by moving it~~ — **that was wrong, and it was wrong on the day it
> was written. Corrected Aug 22, 2026.** `.env.example` referenced it, in a comment added by the
> *same commit* that created the section; the renumbering in `a94d6f7` moved the heading and left
> the pointer aimed at §17, which by then was the resolved Gemini section. So for a day the one
> cross-reference that existed pointed a reader at the wrong entry. It reads §18 now.
>
> **The renumbering itself was correct and is not being undone** — the Gemini §17 above keeps its
> number because `roadmap-status.md` points at it, and one inbound link beats none. What was wrong
> was the *justification*: "nothing references this" was asserted rather than grepped, and the
> reference was two files away in the same commit. **A claim about inbound links is a `grep -rn`,
> and it takes about four seconds.**
>
> This is not the phase-number rule in `CLAUDE.md` — collisions
> at 3, 11, 19 and 20 stay exactly as they are, because those are identifiers with history
> attached. A section heading a day old with no inbound links is not.

**Blocked on nobody; this is a diary entry with a date on it.** `IG_ACCESS_TOKEN` is a
long-lived Instagram token, which Meta issues for about sixty days. The only real timestamp
either repository has is the creation time of the `Rascal-Marketing` Actions secret —
**2026-08-20T00:57:19Z** — which puts the lapse at roughly **2026-10-19**.

**Nothing refreshes it and nothing warns.** The first sign will be a failed publish with an auth
error: `OAuthException 190`. On this side that surfaces as `publish_failed` carrying Meta's own
sentence; on the marketing side it is a red workflow run.

~~**Two stores hold the same credential and both must be updated in one sitting** — this service's
Fly secrets and `.env`, and the marketing repository's Actions secrets. Refreshing one leaves the
other posting to the same account with a dead token.~~ — **wrong about this service, corrected
Aug 22, 2026. It is a one-store errand.**

**The complete production secret list on `rascal-api`, read today**, is:

```
ANTHROPIC_API_KEY APNS_KEY_ID APNS_PRIVATE_KEY APNS_TEAM_ID APPLE_BUNDLE_ID
AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DATABASE_URL DIRECT_DATABASE_URL FLY_API_TOKEN
GOOGLE_CLIENT_IDS JWT_SECRET MAIL_API_KEY MAIL_FROM MAIL_PROVIDER MARKETING_EMAIL_ENABLED
MARKETING_ORIGINS NAME NEON_API_KEY NEON_PROJECT_ID RESEND_AUDIENCE_ID S3_BUCKET
TURNSTILE_SECRET_KEY
```

**No `IG_ACCESS_TOKEN`, no `IG_USER_ID`, no `SOCIAL_PUBLISH_ENABLED`**, and none of the five
machines on `rascal-api` is a social publisher. So the API-lane publisher — `routers/social.py`,
`jobs/social.py`, `services/social/publishing.py`, `services/social/instagram.py` — **has never
been armed in production**. Only the marketing repository's Actions secrets hold a live copy.

**That lowers this section's urgency, and it is the honest reading rather than a technicality.**
The refresh around **2026-10-19** is one store, not two, and the failure it prevents is one red
workflow run rather than two pipelines posting with a dead token. **If the API-lane publisher is
ever armed, this becomes a two-store errand again and this paragraph is the thing to un-strike** —
which is the reason it is struck in place rather than deleted.

What would close this: a refresh, and a note here with the new date. Automating it is worth its
own phase and is not this one — a calendar reminder and a written date beat a half-built
refresher that nobody checks.

**Where else this needed saying, and one of them is the document somebody would have open at the
time.** `.env.example:307` pointed at "§17" until Aug 22, 2026 and now points here. And
`docs/runbook-deploy.md` — **the one page a person reads while doing a deploy or a secret
rotation** — described a scheduled social machine that is not deployed and did not mention
`IG_ACCESS_TOKEN` at all, so the lapse date and the `OAuthException 190` symptom lived only on this
page. Both are being corrected in phase 111. **A credential with an expiry date belongs in the
runbook, not only in the blocked list**, because the blocked list is read when somebody is looking
for what is stuck and the runbook is read when somebody is holding the keyboard.

**Not yet known: which permission the token actually carries.** `docs/social-setup-checklist.md`
in the marketing repository records that scopes were confirmed in Meta's Access Token Debugger
but never names them, and neither session can read them from here. The Debugger at
`developers.facebook.com/tools/debug/accesstoken/` shows the list in seconds; whether the Meta
app needed review is a question only the owner can answer.

**Also unverified: whether `alt_text` lands.** Both pipelines send it on the container and Meta
accepts it without complaint, but nobody has opened the Instagram app and looked at a post's
accessibility info. Meta ignores that field on some flows. Worth checking on the first real post
from here, and telling the marketing session either way — it has been shipping the field for a
day with no evidence it does anything.

## §19 — The paywall has no Terms and no Privacy link, and it is **two lines in a gitignored file** (Aug 22, 2026)

**An errand, not an engineering problem — and the one entry here that is a Review rejection rather
than a delay.** Found by phase 108 and independently confirmed by phase 110.

`Info.plist:154-157` and `Info-Debug.plist:136-139` both map `$(TERMS_URL)` and `$(PRIVACY_URL)`
through to the bundle. **`ios/Rascal/Config.xcconfig` defines neither key.** Not empty — absent. So
both expand to the empty string, `LegalLinks` returns `nil` at its `!trimmed.isEmpty` guard, and the
paywall renders **no Terms of Use link and no Privacy Policy link at all.**

**App Review Guideline 3.1.2 requires both on any screen selling a subscription.** A submission today
is rejected.

**Why nothing caught it, which is the part worth carrying:**

- The behaviour is *correct*. `LegalLinks` is written to render an absent link rather than a dead one
  — the xcconfig `//` trap truncates `https://getvellumapp.com/terms` to `https:`, which
  `URL(string:)` happily accepts, so the host check exists on purpose and **must not be relaxed.**
  Nothing crashes and nothing looks broken.
- `SubscriptionTests.swift:938-946` pins the half that is in the repository — both `Info.plist` files
  carry the keys — and **says in terms that it cannot detect this half**, because `Config.xcconfig`
  is gitignored and no test can see whether a developer copied the keys across.
- It is visible in the committed renders as blank space under *"Restore a purchase"*. Nobody looked
  until phase 110 read the PNGs rather than the code.

**What is needed, and it is yours because the file is gitignored and machine-local:**

```
TERMS_URL = https:$()/$()/getvellumapp.com/terms
PRIVACY_URL = https:$()/$()/getvellumapp.com/privacy
```

**The `$()` split is not decoration** — `//` starts a comment in xcconfig, so a literal `https://`
written inline is silently truncated. `Config.xcconfig.example:93-94` already carries both keys with
the right values; copying them across is the whole task.

**Depends on §16** only in that the pages must exist at those URLs before submission; the marketing
site is building them. **Nothing in either lane's code changes.** Recorded here rather than fixed
because setting build variables is a signing-and-config change, which every phase this week has been
explicitly scoped out of.

---

## §20 — The deletion job has no machine, so nobody who asks to be forgotten is (Aug 22, 2026)

**Blocked on nobody.** No credential, no vendor account, no decision. It is one `fly machine run`
that has not been typed, and it is filed here because it is the only entry on this page where the
gap is a **promise the service is currently breaking** rather than work not yet started.

**What is built, and it is all of it.** `api/src/rascal/jobs/delete.py` exists and is finished —
`python -m rascal.jobs.delete`, with a `--dry-run` that lists what is due and touches nothing,
delegating to `services/deletion.py`'s `run_due_deletions`. `api/tests/test_deletion.py` covers it.
`POST` and `DELETE /v1/me/deletion` are live, the `deletion_requests` table is migrated, and
phase 67 shipped the Settings card and `DeleteAccountSheet` that reach them. The runbook has a
section for the machine — `docs/runbook-deploy.md` §4c — with the exact invocation, added Aug 18,
2026.

**What is not deployed: the machine.** Read today, Aug 22, 2026, `flyctl machines list -a
rascal-api` returns **five**, and none of them is it:

| Name | Schedule | Command |
|---|---|---|
| `patient-wood-1946` | *(none)* | the API itself |
| `delicate-wind-1252` | *(none)* | the API itself |
| `divine-hill-1816` | hourly | `python -m rascal.jobs.scheduler` |
| `throbbing-water-1063` | hourly | `python -m rascal.jobs.notify` |
| `late-fire-837` | hourly | `python -m rascal.jobs.broadcast` |

**So a `deletion_requests` row sits out its seven days and then sits there.** `execute_after`
passes, the request stays pending because nothing wakes up to read it, and **the API stays green
throughout** — there is no failing check, no error rate, no log line, because the failure is the
absence of a process rather than a fault in one. That is why it has gone unnoticed on this page
since the job shipped: phase 66 landed `jobs/delete.py` on Aug 17, 2026 — **five days ago as this
is written** — and every artifact since has described a system that is not running.

**Why this one is worse than a missed notification, and it is not a matter of degree.** `CLAUDE.md`
rule 5 makes account deletion **the single deliberate exception** to soft-delete in this entire
service — *"account deletion hard-deletes … because a soft delete on an erasure would be the
service keeping exactly what it was asked to stop keeping."* The exception was argued for and
written down **so that the data would actually be destroyed.** With no machine, the erasure never
runs, and the exception buys nothing: the row is neither soft-deleted nor hard-deleted, it is
pending. **The one rule this service broke on purpose is currently not being kept either way.**
Apple's in-app-deletion requirement (decisions.md item 14) is satisfied by a button that files a
request; it is not satisfied by a request nobody executes.

**What to do, and it is the whole task:** run `docs/runbook-deploy.md` §4c's command against the
currently deployed image, then `python -m rascal.jobs.delete --dry-run` once on the machine to see
what is already due before anything is destroyed. **`--schedule daily` is sufficient** — the job
takes its deadline from each row's `execute_after`, so a late run deletes what was due and an early
one deletes nothing, and every run is idempotent because a completed request has no row left.

**Two things to know before running it.** `--dry-run` first is not ceremony: this is the only job
in the service that destroys user data, and anything that has been waiting since Aug 17 will go on
the first real pass. And §5 of the runbook applies the moment the machine exists — a scheduled
machine is **not** updated by `fly deploy`, so it will keep running whatever image it was created
against until somebody moves it, which is the trap §4b was written about.

**Not a new finding, and that is the part worth recording.** `docs/runbook-deploy.md` §4d's machine
inventory already says in terms that there is *"no `python -m rascal.jobs.delete` machine"*, and
`docs/phase-queue.md` carries it as a follow-up. **It has never been on this page**, which is the
page whose job is to be read for what is not done — so the one document an operator opens to ask
*"what is outstanding"* was the one document that did not say it. Filed here now; the other two
already have it and neither is this lane's to edit.

---

## §21 — `is_payer` is unknown in exactly the households where the question means something (Aug 22, 2026)

**Blocked on a client change, not on a credential, a vendor or a decision.** Filed by phase 113,
which shipped `is_payer` on `FamilyOut` and can answer it honestly for one-guardian households and
not at all for two-guardian ones.

**The shape of the gap.** `entitlements.payer_user_id` exists and reaches the wire as
`is_payer: bool | null`, computed for the calling user by `services/guardians.is_payer_for`.
`services/app_store_events._set_payer` writes the column **only when the household has exactly one
guardian at the moment of purchase** — and that is correct rather than lazy. Apple's notification
carries `appAccountToken`, the client obligation pins it to the purchasing user's **`family_id`**
(`api-contract.md`, *The client obligation*), and a family id does not name a person. With one
guardian there is only one candidate. With two there is no way to tell from anything Apple sends,
and a wrong payer is worse than a null one: D3a's win-back writes to the payer, so a guess means
emailing the wrong parent about the other one's cancelled card.

**So the field is null in precisely the case it exists for.** A one-guardian household trivially
has a payer and does not need to be told; a two-guardian household is the only one where "are you
the one paying for this" is a real question, and that is the one the server cannot answer.

**Two extensions were considered and both are unsound. Recording them so they are not re-proposed:**

1. **Call `_set_payer` on `DID_RENEW` too, when the household now has one guardian.** Guardians A
   and B; B purchases, so the column is correctly null; B later leaves; a year on `DID_RENEW`
   arrives and this rule writes **A**, who has never paid for anything. `is_payer` then reads
   `true` for A and the win-back emails A about B's card — the exact failure `_set_payer` exists to
   prevent, arriving through a different door.
2. **Restrict that to households that have only *ever* had one member.** **Not expressible in this
   schema.** `guardians` is keyed `(user_id, child_id)` and has no `family_id`; household
   membership is `users.family_id`, and a user who leaves simply has that column point elsewhere.
   There is no membership history and no tombstone, so "has this family ever had a second member"
   cannot be asked. The one-guardian inference is sound *only* at purchase time, which is exactly
   where it is already applied.

Also worth stating: a resubscribe does **not** arrive as `DID_RENEW` — Apple sends `SUBSCRIBED`
with subtype `RESUBSCRIBE`, so that path already reaches `_set_payer` (`constants.py` says so on
`PROMOTING_NOTIFICATIONS`). And the household `runbook-deploy.md` §7a wrote `subscribed` by hand
can never be fixed by webhook code at all, because no notification exists for it.

**The only real fix, and it is an iOS-lane phase with a contract change.** The client knows who is
tapping Purchase; the server never will. It would need a request field carrying the purchasing
**user** id — or an `appAccountToken` scheme that encodes a user rather than a household, which
would break the existing attribution path and is the worse of the two. Either is a new field in
`api-contract.md` plus a change to `SubscriptionStore.purchase(_:familyID:)`, whose `familyID`
argument is currently non-optional and pinned by two tests. **It is not a drive-by**, it fixes
nothing retroactively for purchases already made, and nobody has asked for it.

**Nothing is broken while it stays null, and that is why this is filed rather than fixed.** Phase
112 treats `null` as *don't know, show the control*, so a paying parent always reaches Apple's
subscription-management sheet. The failure direction is deliberate and matches standing rule D9:
**`is_payer` must never be `false` on a null.** Shipping `false` on a guess would hide the
management control from somebody who is paying, which is the one outcome worse than saying nothing.

---

## §22 — three Fly secrets nothing reads, and only you can unset them (Aug 25, 2026)

**Blocked on you, and it is the shortest errand on this page.** Phase 120 (`01318be`, PR #170)
deleted every reader of `GEMINI_API_KEY`, `GEMINI_VIDEO_MODEL` and `GEMINI_VIDEO_CENTS_PER_SECOND`:
`config.py` no longer declares them (`grep -n -i gemini api/src/rascal/config.py` returns nothing),
`.env.example` no longer lists them, and `services/social/gemini.py` is gone. **Removing them from
Fly is a separate manual act and this lane cannot do it:**

```bash
flyctl secrets unset GEMINI_API_KEY GEMINI_VIDEO_MODEL GEMINI_VIDEO_CENTS_PER_SECOND -a rascal-api
```

**Nothing breaks either way, which is exactly why it will be forgotten.** A secret no process reads
is not an outage; it is a live Google API key sitting in a production machine's environment for no
reason, and the only two records that it is dead are a comment in `.env.example` (:183-185) and a
paragraph in `docs/reports/phase-120-canvas-video.md` (:179-181). **Phase 120 named the act in its
own report rather than filing it here**, which is the same failure §20 was filed for three days
earlier: the one document an operator opens to ask *what is outstanding* was the one document that
did not say it.

**Read before you unset, because this page already contains evidence it may be a no-op.** §18's
complete production secret list on `rascal-api`, read in full on Aug 22, 2026 and reproduced there
verbatim, contains **no `GEMINI_*` name at all**. So either the key was never a Fly secret on
`rascal-api` — in which case this closes on one `flyctl secrets list -a rascal-api` and never
needed the unset — or §18's list was incomplete, which is worth knowing about **§18** as much as
about this. Run the list first and record which of the two it was; `CLAUDE.md` puts anything
blocked on a credential on this page, and *"we checked and there was nothing there"* is a result
this page should carry rather than a reason to have written nothing.
