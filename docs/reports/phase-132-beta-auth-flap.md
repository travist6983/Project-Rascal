# Phase 132 — the beta auth flap, and the entry that said "Saving" and wasn't

**Part A. Read-only diagnosis. No behaviour was changed to produce this document.**
Written Aug 28, 2026 against `origin/main` at `c0cbae7`, on branch `ios/phase-132-beta-auth-flap`.

Every claim below carries a `file:line` that was opened and read. Six investigations were run
independently and every claim in each was then re-opened by a separate adversarial pass whose
instructions were to refute it; five came back `all_claims_hold`, one (A1) came back
`some_claims_wrong` and its two refutations are folded in and marked. Where the source could not
answer, the answer is *"unknown, and here is why"* rather than a plausible reconstruction.

---

## The verdict on the working hypothesis

> *An involuntary re-authentication runs the sign-out path, the sign-out path erases the local
> archive, and her unsynced entry died with it.*

**The middle link is false, and the hypothesis fails on it.** `localArchive.erase()` has exactly one
call site in the whole app target — `OnboardingGate.swift:776`, inside the deliberate,
parent-initiated `signOut()`. Every involuntary way a session ends routes to `forgetSession()`
(`OnboardingGate.swift:811`) or to `APIClient`'s own `tokens.clear()`, and **neither touches
SwiftData, the staging directory, the thumbnail cache or the share inbox.** A forced re-auth cannot
have deleted her entry.

**The first link is true, and it is worse than the hypothesis supposed.** The involuntary sign-out
is not confined to a genuine credential expiry: `APIClient.swift:275-276` calls `tokens.clear()` on
**every** status outside `200..<300` returned by `POST /v1/auth/refresh` — 429, 500, 502, 503, 504
included. An ordinary server wobble destroys the keychain session.

**And it is not bad luck — it is dated.** `docs/decisions.md:145` settles, on **Aug 24, 2026, four
days before this report**, that `GET /health` would stop running `SELECT 1` *precisely so that*
*"Neon's ~5-minute idle timer"* would fire and the compute would suspend. Phase 119 accepted in
writing, in the same row and in `api/fly.toml:76-81`, that a machine which cannot reach Postgres
*"stays in the load balancer and answers 500s"*. **A parent who opens the app twice a day is always
past five minutes idle.** That converts the finding above from an unlucky-server story into a
near-every-launch code path, and it is the single fact that explains *"most launches"*, *"sometimes
it recovers on its own"* and *"sometimes ends at sign-in"* from one cause. `api/src/rascal/db.py:26`
still carries a `pool_recycle=1800` comment describing the world before that change.

**The third link needs a different cause.** Four candidates are ranked below; the leading one is
not a deletion at all.

**And there is a real connection between the two symptoms that the hypothesis did not reach for.**
It is starvation, not erasure: **every outbound drain trigger in the app lives inside `RootView`**
(`RootView.swift:271, 295, 344, 391, 502, 513, 623`), and `RootView` is built only in the gate's
`.ready` branch (`OnboardingGate.swift:949`). The `EntrySync` instance itself is constructed inside
`RootView`'s `.task` (`RootView.swift:246`) and nowhere else outside tests. **A launch that lands on
"Can't reach the archive" does not merely fail to sweep — the queue object never exists.** There is
no timer, no reachability trigger and no background task to cover for it. So the launches that
produce symptom 1 are exactly the launches on which an unsynced entry makes no progress, and its
card reads "Saving" throughout.

---

## A1 — What can route a parent to a sign-in screen?

### The surfaces, which are three and are commonly confused

| Surface | Copy | Where | Reached when |
|---|---|---|---|
| Sign-in | `WelcomeScreen` | `OnboardingGate.swift:922-923` (`case .signedOut`) | `state == .signedOut` — the only presentation of sign-in in the app target |
| Gate-level load failure | **"Can't reach the archive"** | `OnboardingGate.swift:1142`, rendered at `:913-916` | `state == .loading && resolveFailed` — *before* `RootView` exists |
| In-session load failure | "Can't load today" | `TodayScreen.swift:334` | `TodayModel.State.failed`, inside a resolved session |

The tester's *"says it can't load the archive"* matches the second. It is **not** the sign-in screen,
and that distinction is what makes the sequence below legible.

### Every path that clears session state

| # | Path | Trigger | Clears | Transport failure can reach it? |
|---|---|---|---|---|
| 1 | `APIClient.sendRaw` retry exhausted | a second real 401 after a successful refresh | tokens (`APIClient.swift:137`) | **No** — narrowed by `isAuthChallenge(retryError)` at `:136` |
| 2 | **`claimRefreshTask`'s status guard** | **any non-2xx from `/auth/refresh`** | **tokens (`APIClient.swift:276`)** | **Yes — a 5xx, a 429, an edge 502** |
| 3 | `claimRefreshTask` pre-flight | keychain read returns nil | nothing | No |
| 4 | `resume()` keychain branch | `hasSession() == false` | widget snapshot (`:198`), membership record (`:209`), then `state = .signedOut` (`:210`) — **not** tokens, Apple subject, or `selected` | No — `hasSession()` is `tokens.load() != nil` (`APIClient.swift:389`), no network |
| 5 | `resolveChild` signed-out branch | `isSignedOut(error)` (`OnboardingGate.swift:277-279`) | `forgetSession()` — tokens, Apple subject, membership, selected child, `children`, widget | No — a `.transport` takes branch 6 |
| 6 | `resolveChild` other-error branch | any other `APIError`, or any untyped error | nothing; sets `notice`, `resolveFailed = true`, stays `.loading` | Yes, and **this is the correct behaviour** |
| 7 | Apple credential check | `.revoked` / `.notFound` | `forgetSession()` (`OnboardingGate.swift:217-226`) | Unknown — see gaps |
| 8 | `AppSession.signOut()` → `api.logout()` | deliberate tap | tokens (`APIClient.swift:409`) | n/a |
| 9 | `PushRegistrar` device-token store | device registration | device token only | n/a |

> **Correction from the verify pass, kept visible.** The first investigation described row 4 as
> "clears nothing". It clears the widget snapshot and resets the membership presentation record; it
> clears no *credentials*. The narrow statement is the one in the table.

> **A fifth token-clearing call site exists and is inert**: `AppSession.signOutAndRetry()`
> (`AppEnvironment.swift:178-182`) sits inside the `#if DEBUG` block spanning `:121-210` and a
> repo-wide grep finds no caller. Named here because the table above is presented as exhaustive.

### The answer to the question this was really asking: **yes, and at one specific line.**

`APIClient.swift:275-276`:

```swift
guard (200..<300).contains(response.statusCode) else {
    tokens.clear()
```

Every exit from the refresh task:

| Exit | Line | Clears tokens? | Throws |
|---|---|---|---|
| `performer.perform` throws — `URLError`, DNS, TLS, ATS, timeout | `:271-273` | **no** | `.transport(...)` |
| non-2xx, body **is** the error envelope | `:275-283` | **YES** | `.api(code:…, status:…)` |
| non-2xx, body is **not** the envelope | `:275-285` | **YES** | `.sessionExpired` |
| 2xx, body is not a `TokenPairResponse` | `:288` | no | a bare `DecodingError`, which escapes every `catch let error as APIError` and surfaces to the parent as `localizedDescription` |
| 2xx, decodes | `:288-293` | no — saves | returns |

**A transport failure is correctly kept away from the auth ladder. A server failure is not.** There
is no discrimination between *"the server says this credential is dead"* and *"the server is having
a bad minute"*.

This is not hypothetical for this deployment. `api/fly.toml:76-81` states the accepted trade in its
own words — *"a green check here no longer means the app can serve, so a machine that cannot reach
the database stays in the load balancer and answers 500s"* — and `errors.py:91` maps
`INTERNAL_ERROR` to 500, `:90` maps `DATABASE_UNREACHABLE` to 503. **The API lane deliberately
accepted answering 500s from a machine that cannot reach Neon. The client turns that into a forced
sign-out.**

The full chain, with the surface it produces:

```
resolveChild                       (OnboardingGate.swift:234)
 -> api.children() -> sendRaw -> execute      [401 token_expired, envelope]
 -> isAuthChallenge == true                   (APIClient.swift:148)
 -> refreshSession -> claimRefreshTask task
 -> perform                                    [500, well-formed envelope]
 -> tokens.clear()                             (APIClient.swift:276)   <-- keychain destroyed
 -> throw .api(.internalError, status: 500)    (APIClient.swift:278-283)
 -> resolveChild catch                         (OnboardingGate.swift:263)
    isSignedOut(.api(.internalError)) == false (OnboardingGate.swift:277-279)
 -> notice = "The server had trouble. Your work is saved on this phone."  (APIError.swift:149-150)
 -> resolveFailed = true; state = .loading     (OnboardingGate.swift:267-269)
 -> ResolveFailedView "Can't reach the archive"(OnboardingGate.swift:1142)
```

**The parent is shown a screen that says the session is fine, and the keychain is already empty.**
Tapping "Try again" (`:914`) calls `resume()`, which hits `guard await account.api.hasSession()`
(`:191`), gets `false`, and lands on `.signedOut` → `WelcomeScreen`. That is, verbatim, *"sometimes
it drops her at a sign-in screen and she has to authenticate again."*

If the same non-2xx body does **not** parse as the envelope — a Fly edge 502 during the
`strategy = "rolling"` deploy of an app with `min_machines_running = 1` (`fly.toml:31`, `:66`) — the
throw at `:285` is `.sessionExpired`, which `isSignedOut` *does* match, so it goes straight to
`forgetSession()` and the sign-in screen with no intermediate screen at all.

**Same failure, two destinations, chosen by whether an error page happened to parse as JSON.** Both
end at sign-in; one takes an extra tap to get there.

### The `refresh_token_reused` trap — **a server-lane finding, recorded and stopped on**

A `.transport` during refresh does not clear tokens, but it also does not undo a rotation the server
already committed. `api/src/rascal/services/tokens.py:140` sets `stored.revoked_at` before issuing
the new pair. **If that response is lost on the wire, the phone holds a refresh token the server has
already revoked.** The next refresh presents it, `tokens.py:127-135` revokes the entire chain and
returns `refresh_token_reused`, and `isAuthChallenge` returns `false` for that code
(`APIClient.swift:147`) so it is never retried. One dropped response on flaky cellular is a
permanent sign-out.

Client-side it is also mis-worded: `.refreshTokenReused` has no case in `APIError.userMessage`, so it
falls to `default: message` (`APIError.swift:161-162`) and the parent reads the server's raw
sentence — *"This refresh token was already used. All sessions have been revoked."* — under the
heading **"Can't reach the archive"**.

**Per this phase's hard stop 1, the server half stops here.** Rotating refresh tokens and chain
revocation on reuse are settled in `docs/decisions.md:100` and are not revised by this phase. The
remedy — a grace window in which the previously-issued pair is replayed rather than treated as
theft — is an API-lane phase and needs a number of its own.

---

## A2 — Is single-flight refresh actually single-flight?

**In-process: yes, and the mechanism is sound.** `claimRefreshTask` (`APIClient.swift:252-299`) is
synchronous and therefore has no suspension point at which two callers could both clear the nil
check; `refreshTask` is claimed and `refreshCount` incremented at `:296-297`, before the task body
runs, and only the owner clears the slot (`:246`). `RefreshTests.swift` covers two concurrent 401s
producing exactly one refresh.

**Across processes: it does not need to be, because the extensions cannot reach the tokens at all.**
This is the branch of the hypothesis that dies cleanly:

- `TokenStore.swift` is the only file in the tree that touches `SecItem*`, and it is not in either
  extension's Sources phase (`project.pbxproj:365`, `:387`).
- No entitlements file declares `keychain-access-groups`.
- The keychain service string is bundle-id-derived (`TokenStore.swift:33`), so the items would be
  distinct even if an access group existed.
- `ios/Rascal/RascalWidget/` and `ios/Rascal/RascalShare/` contain **zero** occurrences of
  `URLRequest`, `APIClient` or `URLSession`. Neither extension makes a network call of any kind.
- The background `URLSession` (`Uploader.swift:32`) is not an auth participant: it PUTs to presigned
  storage URLs with no `Authorization` header (`Uploader.swift:102-105`, `:138-144`) and its delegate
  never refreshes.

This matches `docs/decisions.md:166-167`, which settles it as design — *"no networking in any
extension, ever"* — and the code honours it.

**`POST /auth/refresh` has exactly one caller**, `claimRefreshTask` (`APIClient.swift:262`). The only
other occurrence of the path in the tree is a stub matcher in `OnboardingSessionTests.swift:84`.

**Three things were left as gaps rather than reasoned to**, and the first is the only remaining route
to two `APIClient`s in one process: `OnboardingGate.swift:833`'s `@State` default expression provably
re-runs `OnboardingSession.live()` on every struct init, and `live()` provably builds a new
`APIClient`. How often SwiftUI initialises the root of a `WindowGroup` is framework runtime
behaviour, not source. Settling it needs an instrumented run, not a reading.

### The silent keychain write — the one that needs no server error at all

`KeychainTokenStore.save()` (`TokenStore.swift:57-80` as shipped) compared `SecItemUpdate`'s
`OSStatus` against exactly one value and discarded `SecItemAdd`'s entirely, and returned `Void`. Any
other failure — `errSecInteractionNotAllowed` from a write before first unlock, `errSecDuplicateItem`,
a `-34018` keychain-daemon fault — was indistinguishable from success.

Rotation is destructive server-side: `tokens.py:140` revokes the presented token **before** issuing
the replacement. So the sequence is:

```
refresh succeeds -> server revokes R1, issues R2
 -> the keychain write no-ops, and nothing anywhere notices
 -> THIS launch works perfectly, off the pair still in memory
 -> the next launch presents R1
 -> rotate_refresh_token sees revoked_at is not None       (tokens.py:127)
 -> refresh_token_reused, and the ENTIRE CHAIN is revoked  (tokens.py:128-135)
 -> isAuthChallenge returns false for that code            (APIClient.swift:147)
 -> no retry, no recovery, and the parent's other devices go too
```

**This is the only mechanism found that produces a forced sign-out with a perfect network, no server
error, and a preceding launch that looked healthy** — and it is the shape A1 and A2 both had to
invoke a lost-response-on-the-wire to reach. The whole class was untested:
`grep -rn SecItem ios/Rascal/RascalTests/` was empty.

**One asymmetry found and left alone:** `ArchiveExport.swift:128-132` retries once after
`api.refreshSession()` but, unlike `APIClient.swift:137`, does not clear or raise `.sessionExpired`
when the retry also 401s. Harmless today; named so it is not discovered as a surprise.

---

## A3 — What does an involuntary re-auth erase?

**Nothing. This is the question the hypothesis rests on and the answer is no.**

`localArchive.erase()` — one call site: `OnboardingGate.swift:776`, inside `signOut()`.
`LocalStore.eraseContents()` — one call site: `AppEnvironment.swift:437`, inside
`LocalArchiveErasure.erase()`. `try context.delete(model:)` — three lines, all inside
`eraseContents()` (`AppEnvironment.swift:328-331`). The only other `context.delete` in the app target
is `MediaCoordinator.swift:136`, on a single `Media` row.

`signOut()`'s callers are four, and every one is a deliberate act:

| Caller | File:line | Deliberate? |
|---|---|---|
| Settings' Sign out confirmation | `SettingsScreen.swift:302`, `:313` via `OnboardingGate.swift:955` | yes — a tap in a destructive dialog |
| Setup flow's "Not you?" | `ChildSetupFlow.swift:31` | yes — a tap |
| Post-account-deletion | via the same `onSignOut` closure | yes |
| Magic link resolving to a different account | `OnboardingGate.swift:478` | yes — a tapped link |

The involuntary paths and what each actually clears:

| Involuntary path | Where | Erases archive? |
|---|---|---|
| Apple credential revoked / not found | `OnboardingGate.swift:217-226` → `forgetSession()` | **no** |
| 401 the refresh could not recover | `OnboardingGate.swift:260-262` → `forgetSession()` | **no** |
| Refresh rejected; `APIClient` drops the pair itself | `APIClient.swift:137`, `:276`; noticed at the next `resume()` early return (`OnboardingGate.swift:191-212`) | **no** — never even reaches `forgetSession` |

`forgetSession()` (`OnboardingGate.swift:811-827`) is six statements — `api.signOut()`,
`appleIDs.clear()`, `membership.save(...)`, `selected.clear()`, `children = []`,
`widget.publish(nil)`. None touches `localArchive`, `LocalStore` or `FileManager`.

**What the hypothesis got right:** the eraser, when it does run, bulk-deletes `Entry` rows
(`AppEnvironment.swift:328`) with **no check for unsynced work**. A parent with an unsynced entry who
taps Sign out loses it silently. That is a real hazard; it is simply not the one that happened here.

### And there is a fourth caller, which is the hypothesis's chain reassembled through a door nobody opened

Five independent traces agreed that `signOut()` has four deliberate callers and that no failure path
reaches it. **One of those four is not as deliberate as the list makes it look**, and it is reachable
*because* of an involuntary sign-out:

1. `forgetSession()` (`OnboardingGate.swift:811-827`) cleared tokens, the Apple subject, membership,
   the selected child and the widget. It called `account.api.signOut()` — `APIClient`'s, which is
   only `tokens.clear()` (`APIClient.swift:391`) — **not** `AppSession.signOut()`. So the stored
   **user record survived every involuntary sign-out.**
2. `AppSession.init` rehydrates `self.user = record.load()` on every cold launch
   (`AppEnvironment.swift:74`). The app is signed out and `account.user?.id` still answers. **A ghost
   identity.**
3. `completeEmailSignIn` captures `let signedInAs = account.user?.id` (`OnboardingGate.swift:459`)
   and, if the link resolves to a different user id, called `await signOut()` (`:478`) — **the
   erasing one**.

So: a parent signed out involuntarily, who then signs in by emailed link that resolves to a different
account, reaches `localArchive.erase()`. The tester is *"repeatedly dropped at a sign-in screen and
has to authenticate again"*, which is exactly the population this path is drawn from. Worse, the
guard is a **security** guard — it exists to refuse a login-CSRF — and it was doing an irreversible
deletion as its enforcement action, which means a stranger who knows a parent's address could mail a
link for their own account and destroy every unsynced entry on that phone from the outside.

**This is what B1 is for, and it is why B1 was not skipped.**

### The candidate the hypothesis did not mention, and it is the strongest one for symptom 2

`LocalStore.open(storeURL:)` (`AppEnvironment.swift:271-288`). If `ModelContainer(for: schema)`
throws, the store is **moved aside** by `quarantineStore(at:)` (`:299-316`) and the app opens a fresh
empty one. Every `Entry` row disappears at once with no `context.delete` anywhere.

Three things make this the leading candidate:

1. **It is on every launch and independent of auth.** The first touch of `LocalStore.shared` is
   `RascalApp.swift:92`, a stored property of the `App` struct — it runs during app construction,
   before any view or any auth state exists.
2. **The `catch` at `:277` is unconditional and does not inspect the error.** Whatever the failure,
   the quarantine runs.
3. **It leaves no trace anybody reads.** `RecoveryLog.record` stores the event at `:281`, and
   `RecoveryLog.last` (`:344`) is an in-memory, process-lifetime `var` that **no app code reads** — a
   repo-wide grep finds readers only in the test suite. Its own doc comment says it exists *"so the
   app can say so rather than pretending the device simply had no local data"* (`:336-337`). **The
   app pretends exactly that.** A doc comment and the code disagree, and the code is what shipped.

It is a **move, not a delete** (`:267-270`), so if this is what happened her entry is still on the
device in `Application Support/unreadable-store-<timestamp>/` and is recoverable. That is the single
most valuable thing in this report and it has an expiry date: a reinstall takes the container with it.

---

## A4 — Is a saved entry actually on disk when the UI says "Saving"?

**Yes, if the save succeeded — the composer is not autosave-dependent.**

`ComposerView.save()` (`:709`) sets `saving = true` at `:710`, builds the `Entry` at `:718`, calls
`context.insert(entry)` at `:757`, sets `committed = true` at `:760`, and calls **`try? context.save()`
explicitly at `:782`** — all on the MainActor with **no `await` anywhere between them**. An
`awk 'NR>=705 && NR<=815 && /await/'` over the file returns exactly two lines: `:714` (the edit branch,
which returns at `:715`) and `:785` (`try await api.createEntry`). The network call is the first
suspension point, and it is **after** the commit.

So the brief's premise is not what the code does: the chip is not lying, and this is not the
symptom-2 cause. **The narrow window that does exist is different and it matters.** `try?` at `:782`
discards the error with no `catch`, no `Logger` call, and no state change. If that save throws:

- `committed = true` was already set at `:760`;
- the POST at `:785` proceeds;
- `dismiss()` runs at `:789` (or `:812`/`:816` on the error paths);
- **the parent sees a composer close on a successful-looking save with nothing on disk, and nothing
  anywhere records that it happened.**

That is what B2 is for. It is a small window and the failure is silent, which is the worst
combination for a several-hundred-word entry.

**Two "Saving" surfaces exist and the report distinguishes them**, because the brief conflates them:
the composer's toolbar label (`ComposerView.swift:228`, driven by `@State saving` at `:145`) and the
timeline card's chip (`EntryCard.swift:142`, driven by a persisted row's sync state). Only the second
presupposes a row. **Which one she saw is unknown** and it is a question for her, not for the source
— if it was the chip, the composer had already dismissed and a row demonstrably existed.

**A third explanation the hypothesis does not consider: "gone" may mean "filtered out".** An entry
the server has never acknowledged has `entryType == nil` — the property is `private(set)`
(`Entry.swift:37`) and its only assignment is `Entry.swift:184`, inside `applyServerResponse`. The
timeline's type-chip predicate is `entry.entryType == wanted` (`TimelineScreen.swift:228`), so a
locally-created, never-synced entry is **invisible under every type chip** and visible only under
"All". The row can be on disk and unfindable. This is an access-control guarantee, not a call-graph
observation.

**There is no composer draft persistence anywhere.** `text` is plain `@State`
(`ComposerView.swift:143`) and a repo-wide grep for `SceneStorage` and `AppStorage` returns nothing.
If the write did not land, the typed text is unrecoverable.

---

## A5 — When does the push queue drain, and what does a 401 do to a queued record?

**The outbound path for a text entry is `EntrySync`.** Media rides the same sweep rather than having
a queue of its own.

### Every drain trigger — and every one of them is inside `RootView`

| Trigger | File:line |
|---|---|
| `RootView` first appearance (`.task`) | `RootView.swift:271` |
| `scenePhase` → active | `RootView.swift:295` |
| after a composer dismiss | `RootView.swift:344` |
| after a backfill composer dismiss | `RootView.swift:391` |
| tab change / timeline appear | `RootView.swift:502`, `:513`, `:623` |
| Today's own appear | `TodayScreen.swift:275`, `:278` |
| Settings' "Retry now" | `SettingsScreen.swift:205` (direct to `EntrySync.sweep()`, still inside `RootView`'s settings tab) |

**Absent, and each absence is a finding:** no timer, no `NWPathMonitor`-driven drain, no
`BGTaskScheduler` task, no drain on push receipt. `NetworkReachability` exists
(`NetworkReachability.swift:35`) and does not trigger a sweep.

**`EntrySync` is constructed in exactly one non-test place: `RootView.swift:246`.** On a launch that
renders `ResolveFailedView`, the queue object is never built. That is the starvation link named at the
top of this report.

### What a failure does to a queued record

| Failure | Result | Line |
|---|---|---|
| **401** — recovered by refresh | the request succeeds transparently; the row is acknowledged | `APIClient.swift:128-135` |
| **401** — unrecoverable / `.sessionExpired` | `entry.sync = .failed`, row **retained** | `EntrySync.swift:227` (the `default:` arm), or `:229` for an untyped error |
| **5xx** | `entry.sync = .failed`, row **retained** | `EntrySync.swift:227` |
| **transport** | `entry.sync = .failed`, row **retained** | `EntrySync.swift:227` |

`failed` is inside the retry predicate alongside `pending` (`EntrySync.swift:51`), so a failed row is
re-pushed on the next sweep. **Nothing drops a record and there is no attempt cap for entries at
all.** No push failure of any kind deletes a local row.

**Two defects found here and deliberately not fixed by this phase:**

1. `validationFailed`, `notFound` and `notAuthorized` also park the row as `.failed`
   (`EntrySync.swift:220`) with the comment *"Retrying cannot fix any of these. Park it as failed so
   it surfaces in the UI instead of looping every time the app opens."* — but `failed` **is** in the
   retry predicate, so it loops every time the app opens anyway, forever, while its card reads
   "Saving". The comment describes an intent the predicate does not implement.
2. A text-only entry is handled correctly throughout: `StagingSweeper`'s `liveEntryIds` is built from
   all non-deleted entries regardless of sync state (`StagingSweeper.swift:53-57`), so nothing in the
   drain assumes an entry has media.

**Phase 81's territory, recorded and left alone as the brief requires:** Settings' "Retry now" does
act — it reaches `EntrySync.sweep()` directly via the closure at `SettingsScreen.swift:205`. It is
inside `RootView`, so it is unreachable on precisely the launches where it would be most useful.

**A second row-invisible-but-present mechanism**, alongside the `entryType` one in A4:
`SyncEngine.swift:484` and `:595` write `deletedAt` from an incoming `/sync` row, and every timeline
query filters `deletedAt == nil`. `pullEnabled` ships false, but `SyncPullSection.swift:50` renders a
`Toggle` bound to it, so a parent can turn it on. Not implicated here — a locally-created entry the
server has never seen cannot come back from `/sync` — but named because "the answer's dead code is a
user-facing toggle" is the kind of thing that is wrong later.

---

## A6 — Which build is she on, and could we have known?

**A Version row already exists, and it cannot distinguish one build from another.**

- `SettingsScreen.swift:580` — `SettingsValueRow(label: "Version", value: Self.version)`, placed
  unconditionally in the Settings scroll at `:162`. `Self.version` reads
  `CFBundleShortVersionString` and `CFBundleVersion` (`:687-688`) and renders `"1.0 (1)"`.
- **Those are the only two version-key reads in the entire tree.**
- `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` for **all eight** target/configuration
  pairs in `project.pbxproj`, and `git log -S` shows neither has been changed since the targets were
  created. Nothing in `.github/workflows/ios.yml` archives or bumps — the one job
  (`ios.yml:61`) is `workflow_dispatch:` only (`:32`) and runs `xcodebuild test` (`:148`).
- The plists that consume them are `ios/Rascal/Info.plist:75,77`, `Info-Debug.plist:43,45`,
  `RascalShare-Info.plist:47,49` and `RascalWidget-Info.plist:36,38`.

**No request header carries the build.** All eight `setValue(_:forHTTPHeaderField:)` sites in `ios/`
were read: `Accept`, `Content-Type`, `Authorization`, and nothing else. Neither extension can carry
one even in principle — zero occurrences of `URLRequest`, `APIClient` or `URLSession` in either.

**And the API would discard one if it were sent.** There is no request middleware
(only conditional CORS at `api/src/rascal/main.py:85`), and the only headers any handler reads are
`Idempotency-Key`, `x-forwarded-for`, `content-length` and the Fly client-IP header.

**Two things worth carrying forward.** The client does transmit `environment` in `POST /v1/devices`
(`PushEnvironment.swift:29-33`), which is `production` for TestFlight — useful for separating an
Xcode install from a distribution one, useless as a build discriminator. And the sign-out path has a
logger (`AppEnvironment.swift:381`, `category: "signout"`), so a device console log would carry
evidence that a deliberate sign-out ran — but it never leaves the phone and nothing exports it.

**One consequence stated plainly:** because the build number has never been bumped in the repository,
*"her build predates fix X"* is not a claim anyone can currently verify or falsify.

---

## Ranked causes — symptom 1 ("can't load the archive"; sometimes the sign-in screen)

**1. `APIClient.swift:275-276` clears the keychain on any non-2xx from `/auth/refresh`.**
Fits every clause, and **it is dated rather than speculative**: phase 119 (`decisions.md:145`,
Aug 24, 2026) stopped `/health` touching the database *so that* Neon's ~5-minute idle timer would
fire, and accepted that a machine which cannot reach Postgres stays in the load balancer and answers
500s (`fly.toml:76-81`). A parent opening the app twice a day is always past five minutes idle, so
this is a near-every-launch path, not an unlucky one. It is intermittent (depends whether the resume
is fast, slow or failed), self-healing (a warm API refreshes fine), and it ends at the sign-in screen
either immediately or one "Try again" later.
*Confirms it:* a 500 or 503 on `POST /v1/auth/refresh` in the Fly logs at a time she reports.
*Kills it:* zero non-2xx on that route across the beta window.

**2. Fly/Neon cold start exceeding the URLSession timeout at launch.**
`URLSessionPerformer` uses `.shared` (`APIClient.swift:11`) with the platform default 60s and no
`waitsForConnectivity`. A `.transport` is classified correctly and produces "Can't reach the archive"
with a working Retry — which is exactly *"sometimes it recovers on its own"* and *"sometimes closing
and reopening several times fixes it."* **This one is not a bug in classification.** It is the honest
surface for a slow server; what it costs is up to a minute of a blank launch.
*Confirms it:* `/health` versus `/health/db` cold-start timings in the tens of seconds.
*Kills it:* consistently fast cold starts.

**3. `KeychainTokenStore.save()` silently dropping the rotated pair.** (`TokenStore.swift:57-80`
as shipped.) Needs no server error at all, leaves the *preceding* launch looking healthy, and is
**unrecoverable** — the next refresh presents a revoked token, takes `refresh_token_reused`, and
revokes the parent's other devices with it. Fixed in this phase.
*Confirms it:* her forced sign-outs are never fixable by relaunching, and a `refresh_tokens` burst
revocation with no 5xx anywhere near it.
*Kills it:* a fresh sign-in always restores service and the bursts correlate with 5xx.

**4. The `refresh_token_reused` chain revocation after a lost response.** (`tokens.py:127-140`.)
Permanent rather than intermittent, so it fits *"she has to authenticate again"* but not *"sometimes
it recovers."* Probably a contributor, not the main event. **Server lane.**
*Confirms it:* a `refresh_tokens` row for her `user_id` with a whole chain revoked within one second.
*Kills it:* no clustered revocations.

**5. Keychain read before first unlock.** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
(`TokenStore.swift:71`); `load()` returns nil for any non-`errSecSuccess`, indistinguishable from "no
session" (`TokenStore.swift:46`). Clears nothing, so a later relaunch works — the right shape for
*"reopening fixes it"*, but it needs a launch between reboot and first unlock, which a parent opening
the app by hand does not produce. Low.
*Confirms it:* she reports it happening right after a restart, before unlocking.

**6. Two `APIClient` instances in one process.** `OnboardingGate.swift:833`'s `@State` default
re-runs `OnboardingSession.live()` on every struct init. Would make single-flight per-instance rather
than per-app. **Unknown, not ruled out** — needs an instrumented run.

---

## Ranked causes — symptom 2 (the lost text entry)

**1. The SwiftData store was quarantined on a later launch.** `AppEnvironment.swift:271-288`. Takes
everything at once, needs no sign-out and no throw at `:782`, runs before any auth state exists
(`RascalApp.swift:92`), and — decisively — **leaves no trace the app reads**: `RecoveryLog.last`
(`:344`) has no reader outside tests, contradicting its own doc comment at `:336-337`.
*Confirms it:* an `unreadable-store-*` folder in her app container.
*Kills it:* no such folder, and the rest of her archive intact.
**If this is it, her entry still exists on the device.**

**2. `try? context.save()` at `ComposerView.swift:782` threw and was swallowed.** Would lose exactly
one entry while leaving everything else intact, and produce zero evidence anywhere. The `committed`
flag is already true, so the composer dismisses looking successful.
*Confirms it:* the rest of her archive is intact and only this entry is missing.
*Kills it:* other entries from the same period are also missing.

**3. The row is on disk and she cannot see it.** `entryType == nil` on a never-synced entry makes it
invisible under every timeline type chip (`Entry.swift:37`, `:184`, `TimelineScreen.swift:228`).
*Confirms it:* it appears under "All" — **ask her to check this first; it costs ten seconds.**

**4. A magic-link sign-in after an involuntary sign-out reached the erasing path.**
The chain in A3's last section: `forgetSession` left the user record, the next launch rehydrated a
ghost identity, and a link resolving to a different account ran `signOut()` and erased. Requires her
to have two accounts — an Apple private-relay address and a direct one is the ordinary way that
happens. Fixed in this phase.
*Confirms it:* she has signed in by emailed link, and the whole local archive was empty afterwards
rather than one entry.
*Kills it:* she has never used an email link.

**5. SwiftData's silent upsert on `@Attribute(.unique) Entry.id`.**
`Entry.swift:13` is unique-constrained and `ShareDrain.swift:48-56` documents, from a **measured**
incident, that a colliding insert *replaces* the row rather than erroring. Every enumeration that
proved "nothing deletes an `Entry`" did so by grepping `context.delete` — a query that cannot see a
replace. A composer-typed entry would not normally collide, but "gone" is what a replaced row looks
like and nothing established that it cannot happen.
*Confirms it:* a blank or duplicate entry at the same `occurred_at`.

**6. She tapped Sign out at some point and the eraser took an unsynced row.** `AppEnvironment.swift:328`
bulk-deletes `Entry` with no unsynced check. A real hazard, and it requires her to have signed out
deliberately.
*Confirms it:* she recalls signing out; the whole local archive was empty afterwards.

**7. The hypothesis as written — an involuntary re-auth erased it *by the route it named*. Ruled out**,
though cause 4 is the same destination reached through a door the hypothesis did not know about. `localArchive.erase()`
has one call site (`OnboardingGate.swift:776`) and no failure path reaches it.

---

## Production queries and log greps — for the owner to run. **None of these were run.**

`flyctl` is not assumed to be authenticated; run `fly auth whoami` first.

```bash
# 0. Her user_id. Substitute the address she signs in with.
fly ssh console -a rascal-api -C "python -c \"
import asyncio
from sqlalchemy import text
from rascal.db import get_sessionmaker
async def m():
    async with get_sessionmaker()() as s:
        for r in (await s.execute(text('''
            select u.id, u.created_at, c.provider, c.revoked_at
            from users u join credentials c on c.user_id = u.id
            where lower(u.email) = lower(:e)'''), {'e': 'HER@EMAIL'})).all():
            print(r)
asyncio.run(m())\""

# 1. Refresh-token state for that user. The tell for the chain-revocation trap is a run of
#    rows whose revoked_at values fall inside the same second.
fly ssh console -a rascal-api -C "python -c \"
import asyncio
from sqlalchemy import text
from rascal.db import get_sessionmaker
async def m():
    async with get_sessionmaker()() as s:
        for r in (await s.execute(text('''
            select id, created_at, expires_at, revoked_at,
                   revoked_at is null as live
            from refresh_tokens
            where user_id = :u
            order by created_at desc limit 60'''), {'u': 'HER_USER_ID'})).all():
            print(r)
asyncio.run(m())\""

# 1b. The same thing as one number: chains revoked in a burst.
fly ssh console -a rascal-api -C "python -c \"
import asyncio
from sqlalchemy import text
from rascal.db import get_sessionmaker
async def m():
    async with get_sessionmaker()() as s:
        for r in (await s.execute(text('''
            select date_trunc('second', revoked_at) sec, count(*)
            from refresh_tokens
            where user_id = :u and revoked_at is not null
            group by 1 having count(*) > 1 order by 1 desc'''), {'u': 'HER_USER_ID'})).all():
            print(r)
asyncio.run(m())\""

# 2. refresh_token_reused in the logs.
#    EXPECT NOTHING, AND THAT IS NOT EVIDENCE OF ABSENCE. errors.py's `_rascal` handler
#    (api/src/rascal/errors.py:149-151) renders a RascalError with no log call at all, so this
#    code never reaches a log line. Query 1b is the real instrument. Run this only to confirm.
fly logs -a rascal-api --no-tail | grep -i refresh_token_reused

# 3. What the refresh route has actually been answering. This is the query for cause 1.
#    uvicorn's default access log is on (no --no-access-log in api/Dockerfile:72 or
#    api/fly.toml:57), so non-2xx on this path should be visible.
fly logs -a rascal-api --no-tail | grep "auth/refresh" | grep -vE '" 20[0-9] ' | tail -50
fly logs -a rascal-api --no-tail | grep -cE 'auth/refresh.*" 5[0-9][0-9] '
fly logs -a rascal-api --no-tail | grep -E '"(message|level)":' | grep -iE 'database error|unhandled error' | tail -30

# 4. Cold-start timings: /health opens no connection, /health/db does. The gap is the Neon wake.
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "health     %{http_code}  %{time_total}s\n" https://rascal-api.fly.dev/health
  curl -s -o /dev/null -w "health/db  %{http_code}  %{time_total}s\n" https://rascal-api.fly.dev/health/db
  sleep 60
done

# 5. Did her entry ever reach the server? If it did, symptom 2 is a display problem, not a loss.
fly ssh console -a rascal-api -C "python -c \"
import asyncio
from sqlalchemy import text
from rascal.db import get_sessionmaker
async def m():
    async with get_sessionmaker()() as s:
        for r in (await s.execute(text('''
            select e.id, e.entry_type, e.occurred_at, e.created_at, e.deleted_at,
                   length(coalesce(e.body, '')) as body_len
            from entries e join children c on c.id = e.child_id
            where c.family_id = (select family_id from children where id = :ch)
            order by e.created_at desc limit 40'''), {'ch': 'HER_CHILD_ID'})).all():
            print(r)
asyncio.run(m())\""
```

---

## Two reproductions, each under two minutes on the owner's own phone

**Symptom 1 — the refresh path clearing on a server error.** This is the top candidate and it
reproduces without waiting for a real outage.

1. Sign in on a device build. Confirm Today loads.
2. Point the build at a local API (`Config.xcconfig`, `API_BASE_URL`) and run it with
   `ENVIRONMENT=local`.
3. Make `POST /v1/auth/refresh` answer 500 — stop Postgres with the API still up is the closest
   thing to production, since `fly.toml:76-81` says that is exactly the shape production takes.
4. Wait past the 15-minute access-token life, or delete the access token half, and cold-launch.
5. **Expected on current code:** "Can't reach the archive", then tapping "Try again" lands on the
   sign-in screen — with no 401 ever having been returned.

**The one question to ask her before anything else, because it separates the whole field.**
*"When it happens — had you swiped the app away and reopened it, or just switched to another app and
come back?"* The gate's only `scenePhase` observer (`OnboardingGate.swift:1086-1094`) calls
`notifications.refresh()` and `SubscriptionCenter.shared.refresh()` and **never `resume()`**, so only
a cold launch re-resolves and only a cold launch can land on "Can't reach the archive". If she says
it happens on a warm return too, every cause ranked above is wrong and the failure is elsewhere.

**Symptom 2 — the swallowed local save.** The brief's suggested airplane-mode reproduction will
*not* reproduce it, and that is worth saying: `try? context.save()` at `ComposerView.swift:782` runs
before any network call, so an offline entry survives a switcher kill. Run it anyway as the control
— **the entry should still be there on relaunch** — and then run the one that matters:

1. Ask her, first, to open Timeline and tap the **All** chip. If the entry appears, this is A4's
   third explanation and nothing was lost.
2. If it does not: get the app container off her device (Xcode → Devices → the app → Download
   Container) and look for `Library/Application Support/unreadable-store-<timestamp>/`. **If it is
   there, her entry is inside it and is recoverable.**
3. Ask whether the rest of her archive is intact or empty. That single answer separates cause 1
   (everything gone) from cause 2 (only this entry gone).

---

## What Part B does, and what it deliberately does not

| | Verdict |
|---|---|
| **B1** — gate bulk erase on explicit Sign out | **Real, and only the completeness pass found it.** Five traces called it already-correct; the fourth caller of `signOut()` is reachable from an involuntary sign-out via a ghost identity. Two fixes: the foreign-link branch no longer erases, and `forgetSession` no longer leaves an identity behind. |
| **B2** — a saved entry is on disk before the UI claims anything | **Real.** `try?` at `ComposerView.swift:782` must become a handled `try` that surfaces to the parent instead of dismissing into a success-looking screen. |
| **B3** — a transport failure is not an auth failure | **Real, and it is the headline.** `APIClient.swift:275-276` must clear only for a status that genuinely says the credential is dead. |
| **B4** — make "which build is she on" answerable | **Half already shipped.** The Settings row exists (`SettingsScreen.swift:580`) and was not touched; the header did not, and now does. **The version has still never been bumped**, so it reports `ios/1.0 (1)` until somebody moves `CURRENT_PROJECT_VERSION` — the header makes the question answerable, it does not answer it. |
| **A fifth, in scope by the brief's own boundary list** — "the refresh path" | `KeychainTokenStore.save()` read one `OSStatus` out of two and returned `Void`. It now reports failure, and a refresh whose write did not land drops the stale pair rather than stranding a revoked token that would revoke the parent's other devices. |

**Recorded and left alone, with the phase each belongs to:**

- The `refresh_token_reused` grace window — **API lane, needs its own number.** Hard stop 1.
- **Neon's idle-suspend cost at the client** (`decisions.md:145`): nothing in the app sets a request
  timeout — `URLSessionPerformer` uses `.shared` (`APIClient.swift:11`) — so a slow resume is an
  unbounded blank launch. A timeout-and-retry policy is a phase, not a line.
- The SwiftData unique-id upsert (`ShareDrain.swift:48-56`) as a row-loss mechanism nobody has swept
  for outside `ShareDrain`.
- `PushCenter.attach` assigning unconditionally (`PushCenter.swift:37-38`) where `MediaCoordinator`
  guards on nil — the second leg of A2's two-`APIClient` gap.
- `RecoveryLog` written and never read — a store-recovery surface, its own phase.
- `EntrySync.swift:220`'s permanent-failure arm looping forever — the retry-policy question.
- "Retry now" being unreachable on the launches that need it — **phase 81**.
- A deliberate Sign out silently discarding unsynced work (`AppEnvironment.swift:328`) — its own phase.
- `ArchiveExport.swift:128-132`'s asymmetric 401 retry.

---

## Gaps — what the source could not answer

1. **Whether the quarantine path fired on her device.** `RecoveryLog.last` is in-memory and
   process-lifetime (`AppEnvironment.swift:344`); nothing persists or exports it. Only the device's
   container can answer.
2. **Whether `try? context.save()` at `ComposerView.swift:782` succeeded.** The error is discarded
   with no logger and no state change. A local-save failure produces zero on-device evidence.
3. **Which "Saving" she saw** — the composer's toolbar label or the timeline card's chip. Nothing in
   the source distinguishes them from a report that says only "the Saving state".
4. **What `getCredentialState` passes when the call itself fails** (offline, Apple ID server error).
   `AppleSignIn.swift:141` discards the `Error`, and all four documented `CredentialState` values map
   away from `.unknown` (`:149-152`), so `.unknown` is reachable only via `@unknown default` (`:153`).
   Whether a failed check yields `.notFound` — which would make row 7 of A1's table a live
   involuntary sign-out — is Apple framework behaviour, not repository source.
5. **Whether SwiftUI re-initialises the gate's `@State` more than once per process**
   (`OnboardingGate.swift:833`). The only remaining route to two `APIClient`s. Needs an instrumented
   run.
6. **Whether `await task.value` resumes when the awaiting task is cancelled** (`APIClient.swift:248`).
   If it does not, the owner's `defer` never runs and the slot stays occupied by a completed task.
   Swift runtime semantics; no test exercises cancellation mid-refresh.
7. **Whether her TestFlight binary carries `1.0 (1)`.** The tree says it should and `git log -S` shows
   the value has never changed, but an uncommitted local bump before Archive would leave no trace here.
8. **What URLSession's default `User-Agent` actually contains.** No code in `ios/` sets it. Asserting
   Apple's documented format would be inference, not evidence — and the API discards the header anyway.
9. **Whether the tester's forced sign-outs are recoverable by relaunching.** This is the one
   question that separates the 5xx cause from the silent-keychain-write cause, and it is a question
   for her rather than for the source.
10. **Whether she has ever signed in by emailed link, and whether that address resolves to the same
   account as her Apple sign-in.** Settles symptom-2 cause 4 outright.
11. **Whether the two symptoms happened on the same build.** Nothing the client sends and nothing the
   API logs carries a build identifier. This is precisely what B4 exists to change.
