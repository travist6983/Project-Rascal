# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have — **and, as of
Aug 14, 2026, one that needs a platform.** §9 is the first entry here blocked by a missing API
rather than a missing secret, and it is filed here anyway because the effect is identical: the
work cannot proceed and no amount of engineering changes that. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: **Aug 16, 2026.** The Aug 11 pass is described below and its findings stand; what
Aug 16 changed is recorded in the paragraphs immediately after it.

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

**Aug 16, 2026 review — nothing in this file is blocked on a credential any more.** §0, §1, §2,
§2b and §3 are closed. §10 looked like a blocker and is not: its blocking decision was the price,
and D1 settled that on Aug 15, so what remains there is an **errand with steps**.

**One thing is blocked on a platform and cannot be engineered around: §9**, on-device photo
captioning. The grep that proves it lives in the section and is the thing to re-run when a new SDK
lands. Do not soften it and do not re-derive it from memory.

**Everything else on this list is unrecorded rather than blocked**, and that is a different
problem with a different fix. The device-verification checklists describe work that in at least one
case **has already been done in the world and was never written down**. Phase 16 is the example:
`SpeechAnalyzer` has produced a real, accurate transcription on a real device, and the checklist
that gates the phase still opens with *"Nothing in this feature has ever run."* The gate is shut on
evidence that exists. See the Phase 16 section — it is the sharpest thing in this file.

> **This paragraph said "two things" for about an hour, and the second one had already been
> fixed.** It named the `sandbox`/`production` description bug in `schemas/device.py` and
> `docs/api-contract.md`; commit `39fb97f` had corrected both earlier the same day. It was
> copied here from `roadmap-status.md` without a grep, which is the exact failure that file
> records five times over — and it propagated into two more documents before anyone checked.
> **The rule that would have caught it is already written down: a shipped-status claim carries
> the command that proves it.** One `git log -L` closed it.

**Aug 11 second pass — the resolved sections were struck but not moved, and that was the defect.**
The four iOS sections below (Seal control, Onboarding, Timeline v3, Settings) were all correct at
the top of this file on Aug 11 and were still sitting under a heading that means "blocked",
describing workarounds as current. **A struck section is not a moved section**, and a file read for
"what is blocking me" gets skimmed by heading rather than read for strikethroughs. Two of them have
since been closed outright by phase 19 (PR #48); the remaining iOS follow-ups are named as such.

> **Standing habit this pass earns:** when a section resolves, it moves to
> `Resolved since the last review` in the *same pass* that strikes it, with the follow-on work
> stated as a phase rather than as a paragraph. The original entry can travel with it — the
> reasoning is usually why the fix is shaped the way it is, and that is worth keeping, just not at
> the top of the blocker list.

---

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

- **Onboarding does not ask for pronouns.** `ChildSetupFlow.swift` mentions them only in a comment.
  The reason this section gave for not asking — "asking and then discarding would be worse than not
  asking" — has expired, because there is now somewhere to put the answer. This is what
  `docs/decisions.md` open item 10 has been waiting on, and item 10 is the tracker for it now.
- **The avatar is still device-only.** `AvatarStore.swift`'s header comment still reads "nothing
  mints one", which was true when it was written and is not now. `LocalAvatarStore` is the seam
  this section named, and the crop and JPEG conversion already run. **A false comment in a file
  nobody has opened in a week is exactly the drift this file exists to catch** — correcting it is
  part of whichever phase takes the upload.

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

## iOS Settings — notes, not blockers. **Nothing in this section is open.**

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

**Status, Aug 16, 2026: the 79 candidates are still unreviewed, and the owner is reviewing them
tonight.** A second run with `--kind` — activity, photo, video and audio against the same four thin
themes — is wanted, and is **queued deliberately behind the review rather than beside it.**

**The reason is worth stating, because the efficient-looking order is the wrong one.** The review is
the only thing that calibrates the generator. If fifteen `outdoors` questions get cut for the same
reason, that reason belongs in `generate_prompts.py`'s filters or in `mission-library.md`'s
rejection rules **before** the next batch exists. Generating first means reading the same flaw twice
and paying for it twice.

**The pool arithmetic that makes this worth doing at all:** 113 seeded prompts, with repeats
beginning around day 31. Adding 79 questions pushes that out — but only for questions. The
activity, photo, video and audio sides of those four themes stay exactly as thin as they are today,
which is what the `--kind` run is for.

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
stopped being true** — three `##` sections further down are not closed: Phase 16 (unrecorded, and
runnable tonight), §9 (the one genuine platform block) and §10 (an errand). A reader skimming
headings after this line would have read all three as resolved, which is the exact defect this
file records against itself twice. Scoped to its list, Aug 16, 2026.

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

**Still unstarted, and not blocked:** onboarding does not ask for pronouns (tracked by
`docs/decisions.md` item 10) and the avatar is still device-only (§iOS Onboarding).

---

## ~~Phase 22 — Entry Detail v2: two design questions that are not the agent's to answer~~ — RESOLVED, all three, confirmed by the owner Aug 16, 2026

Owner, Aug 16: *"22 is long done and perfect in all of these."* The phase merged as **PR #54** —
`docs/roadmap-status.md:219`, *"Entry Detail v2 … Full-bleed media, the cream sheet, per-shape
backdrops | #54 | ✅ merged"*. Moved here rather than struck in place, per this file's standing
habit: **a struck section is not a moved section.**

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

**Nothing stands in front of this phase.** No credential, no platform gap, no design question. It
is unstarted, and the only thing holding it is a document that disagrees with the world.

**The transcriber works, and it has been seen working.** Owner, Aug 16, 2026: `SpeechAnalyzer` has
produced a real transcription on a real device, on a build from that day, and the output was
accurate enough to capture his son's actual pronunciation of words. That is precisely the question
`docs/Device-Verification/device-verification-transcription.md` §0 — per-recording word accuracy — exists to answer.

**So the blocker is the file, not the feature.** The checklist still records **0 of 45** and still
opens with *"Nothing in this feature has ever run."* Phase 16's preflight #1 reads that document
rather than the world, so it hard-stops — **correctly, given what the document says.** The gate is
doing its job on stale input.

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
- **Create the subscription products in App Store Connect** — the annual and the monthly, with the
  14-day trial and annual preselected per D1. Without product identifiers there is no StoreKit
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
5. **Set the annual as the preselected option**, and configure the **14-day free trial** as an
   introductory offer, per D1.
6. **Record the App Store Server Notifications V2 endpoint URL.** D5 holds that the server writes
   the entitlement and every gate reads the server, so this URL is what phase 37 is built against.

**Apple's exact menu wording is not verified here.** These steps name destinations rather than
click paths on purpose — App Store Connect's navigation changes, and a stale menu path in a runbook
is worse than a described destination. Nobody on this branch has an App Store Connect session.


---

## §11 — Apple's `sub` has never been observed across a revoke and re-authorize (Aug 16, 2026)

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

### The run

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

- [ ] **4.** Confirm `revoked_at` is set on the credential, and that every refresh token for
  that user is revoked. Re-run the query from step 1, and:
  ```bash
  fly ssh console -a rascal-api -C "python -c \"
  import asyncio
  from sqlalchemy import text
  from rascal.db import get_sessionmaker
  async def m():
      async with get_sessionmaker()() as s:
          print((await s.execute(text('''select count(*) from refresh_tokens
              where revoked_at is null'''))).scalar())
  asyncio.run(m())\""
  ```
  Expect `0`. Got: ______

- [ ] **5. Sign in again, and confirm you land on the same `users.id`.** **This is the box the
  phase turns on.** Compare against what you wrote in step 1.
  Same `users.id`? ______  Same `subject_id`? ______  `revoked_at` cleared? ______

- [ ] **6.** Confirm the archive is still there — open the timeline and check the entry count
  is what it was before step 2.

**If step 5 shows a different `subject_id`**, stop. Do not adjust anything. Record what you saw
here and raise it: the recoverability design needs rethinking, and until it is rethought,
nothing should tell a parent that removing the app is reversible.

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
§10 says it about StoreKit rather than as a warning. **The marketing send is downstream of the P0
behavioural gate — seven days of unforced daily use — which has not started.** The page and the
`POST /v1/subscribe` endpoint may be built before any of this exists; only the *marketing send*
waits on it. (Transactional mail is a separate question and is not gated on P0 — phase 57's
magic-link path already sends, or would if `MAIL_PROVIDER` were ever set.)
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
and the second half is where an errand stalls at a keyboard. **Nothing in the marketing or email
path works until these exist: none of `MAIL_API_KEY`, `RESEND_AUDIENCE_ID`, `TURNSTILE_SECRET_KEY`
or `MARKETING_EMAIL_ENABLED` is set on `rascal-api` as of Aug 18, 2026** — checked, not assumed.

**Turnstile is the one step with no prerequisite.** It needs no domain and no DNS, so it can be
done in isolation and it is what makes the signup form stop saying *"signups are not open yet."*

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
so that finishing the table above does not start mailing anybody. Open item 12: **no marketing
email before the P0 behavioural gate**, which is seven days of unforced daily use and has not
started. When it is time: `fly secrets set --app rascal-api MARKETING_EMAIL_ENABLED=true`.

**Two things to do before that flag, in this order.** Exercise `POST /v1/subscribe` once from the
real GitHub Pages origin, which is the first test of CORS and of a genuine Turnstile verification —
neither has ever run against the deployed API. Then run
`python -m rascal.jobs.broadcast --date <a day> ` against an audience containing **only your own
address**, because the Resend Broadcasts API has never been called by this service and its
two-step create-then-send shape is implemented from documentation rather than observation.

**One item on this page is still open and is not in the table:** the Resend key currently in the
local `.env` went through a chat transcript and **has not been rotated** — confirmed by the owner
Aug 18, 2026. It is inert (`MAIL_PROVIDER` is `console` and nothing reads it), but a key that has
been through a transcript is not a key. Rotate it before step 3 rather than after, so the key that
reaches Fly is the one that was never exposed.
