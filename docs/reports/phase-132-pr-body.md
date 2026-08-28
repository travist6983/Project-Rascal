# Phase 132 — the beta auth flap, and the entry that said "Saving" and wasn't

iOS lane. Branch `ios/phase-132-beta-auth-flap`, cut from `origin/main` at `c0cbae7`.
Part A report: **[`docs/reports/phase-132-beta-auth-flap.md`](phase-132-beta-auth-flap.md)**.

## What the diagnosis found

**The working hypothesis is refuted as a chain, and its first link is real and worse than supposed.**

- `localArchive.erase()` has **one** call site (`OnboardingGate.swift:776`). No failure path reaches
  it. An involuntary re-auth cannot have deleted her entry *by the route the hypothesis named*.
- `APIClient.swift:275-276` cleared the keychain on **every** non-2xx from `POST /auth/refresh` —
  429, 500, 502, 503, 504. **And it is dated:** phase 119 (`decisions.md:145`, Aug 24 — four days
  before this report) deliberately let Neon's ~5-minute idle timer fire, accepting in writing that a
  machine which cannot reach Postgres *"stays in the load balancer and answers 500s"*. A parent who
  opens the app twice a day is always past five minutes idle. That is *"most launches"*, *"sometimes
  it recovers on its own"*, and *"sometimes ends at sign-in"* from one cause.
- The composer **is not** autosave-dependent. `try? context.save()` ran at `ComposerView.swift:782`
  before the only suspension point, so the "Saving" chip was not lying. The defect is the `try?`.
- **The two symptoms are connected — by starvation, not erasure.** Every drain trigger lives inside
  `RootView` (`RootView.swift:271,295,344,391,502,513,623`), and the only `EntrySync` instance is
  built in `RootView`'s `.task` (`RootView.swift:246`). A launch that lands on "Can't reach the
  archive" (`OnboardingGate.swift:1142`) does not construct the queue at all.

Ranked cause lists for both symptoms, a ready-to-paste block of production queries and log greps,
and two sub-two-minute reproductions are in the report.

## Verified by running something vs. reasoned about

**Verified by running:**
- Baseline before any change: **1242 tests in 150 suites, 0 failures, 8 skipped** — green.
- After: **1268 tests in 155 suites, 0 failures, 8 skipped, zero warnings** in `Rascal`,
  `RascalTests`, `RascalWidget`, `RascalShare` — run cold from a deleted `DerivedData`.
- **Eight break-tests**, each run individually (below).
- Every `file:line` in the report was opened with `sed -n`. Six independent investigations, each
  adversarially re-verified claim-by-claim by a separate pass instructed to refute; five came back
  `all_claims_hold`, A1 `some_claims_wrong` and both refutations are folded into the report and
  marked as corrections.
- The four phase-number commands, all four answering 131 unanimously.

**Reasoned about, not verified:**
- That the tester's failures were 5xx rather than transport errors. The client writes no telemetry
  for either. **This is a reading of the code plus a dated infrastructure decision, not a
  measurement of her device.**
- That `try? context.save()` throwing is what lost her entry. It produces zero evidence by design.
- Everything in the "Gaps" section, which is written as *"unknown, and here is why"* rather than
  reasoned to a plausible answer.

## What could not be verified without a device

**Neither symptom has been reproduced by anyone, so a green suite is not evidence that a parent's
phone behaves.** Specifically:

1. Whether the SwiftData store was quarantined on one of her launches. `RecoveryLog.last`
   (`AppEnvironment.swift:344`) is in-memory and **read by nothing outside the test suite**,
   contradicting its own doc comment at `:336-337`. Only her app container can answer — and if that
   is what happened, **her entry is still on the device** in
   `Application Support/unreadable-store-<timestamp>/`, recoverable until she reinstalls.
2. Whether her forced sign-outs are ever fixable by relaunching. This one question separates the
   5xx cause from the silent-keychain-write cause.
3. Whether she has ever signed in by emailed link. Settles symptom-2 cause 4 outright.
4. Whether "it happens" means a cold launch or a warm return. Only a cold launch re-resolves
   (`OnboardingGate.swift:1086-1094` never calls `resume()`), so a warm-return failure would
   invalidate every cause ranked in the report.
5. Whether `getCredentialState` yields `.notFound` when the call itself fails. Apple framework
   behaviour; `AppleSignIn.swift:141` discards the error.
6. Whether SwiftUI re-initialises the gate's `@State` more than once per process
   (`OnboardingGate.swift:833`) — the last route to two `APIClient`s over one keychain.

## The fixes

| | |
|---|---|
| **B1** — an involuntary re-auth must never destroy local data | **Real, and only the completeness pass found it.** See below. |
| **B2** — a saved entry is on disk before the UI claims anything | Commit moved to `EntryCache.commit`, which **throws**; a failure rolls back, keeps the sheet open with her words in the field, and never sets `committed`. |
| **B3** — a transport failure is not an auth failure | `APIClient.refusesCredential(status:code:)` is the one classifier. Only 401/403 with a credential-refusing code — or no envelope at all — may end a session. A non-envelope non-2xx now raises `.unexpectedStatus`, not `.sessionExpired`. |
| **B4** — make "which build is she on" answerable | `X-Client-Build: ios/1.0 (1)` on every request including the refresh. The Settings Version row **already existed** (`SettingsScreen.swift:580`) and was not touched. |
| **A fifth** — `TokenStore` | `save()` returns `Bool` and reads both `OSStatus` values; a refresh whose write did not land drops the stale pair. |

### B1 was not skipped, and that is the most important line in this PR

Six independent read-only traces all concluded B1 was already correct — one call site, four
deliberate callers. **The completeness critic found the seam all six walked past:**

1. `forgetSession()` called `account.api.signOut()` (tokens only), **not** `AppSession.signOut()`,
   so the stored **user record survived every involuntary sign-out**.
2. `AppSession.init` rehydrates `user = record.load()` on every cold launch
   (`AppEnvironment.swift:74`). The app is signed out and `account.user?.id` still answers — **a
   ghost identity**.
3. `completeEmailSignIn` compares a magic link's account against exactly that value
   (`OnboardingGate.swift:459`) and, on a mismatch, called **the erasing `signOut()`** (`:478`).

So a parent signed out involuntarily who then signs in by emailed link resolving to a different
account reached `localArchive.erase()` — **the hypothesis's own chain, through a door nobody
opened**. And because the trigger is an inbound link, a stranger who knew a parent's address could
mail one for their own account and destroy every unsynced entry on that phone. A security guard
should not have an irreversible delete as its enforcement action.

Both halves are fixed: `forgetSession` clears the record, and `endSession(erasingArchive:)` makes the
erase an argument spelled at every call site rather than something you get by omission.

### The fifth fix, and why it is inside the brief's boundary list

The brief puts *"the refresh path"* in scope. `KeychainTokenStore.save()` compared one `OSStatus`
against one value, discarded `SecItemAdd`'s entirely, and returned `Void`. Rotation is destructive
server-side (`tokens.py:140` revokes before issuing), so a silently-refused write left the phone
holding a dead token; the next launch presents it, takes `refresh_token_reused`, and **revokes the
parent's other devices with it**. It is the only mechanism found that produces a forced sign-out with
a perfect network and a preceding launch that looked healthy. `grep -rn SecItem ios/Rascal/RascalTests/`
was empty.

## Break-test results — eight breaks, **one survived**

| # | Break | Result |
|---|---|---|
| 1 | a `URLError` during refresh classifies as a credential refusal | ✅ failed — *"a transport failure during refresh leaves the session alone"* |
| 2 | restore the unconditional `tokens.clear()` on any non-2xx | ✅ failed — 11 issues across the 5xx, 429 and edge-page tests |
| 3 | remove the explicit `save()` from `EntryCache.commit` | ✅ failed — all 4 durability tests, 7 issues |
| 4 | make the involuntary path call `localArchive.erase()` | ✅ failed — the rejected-refresh and revoked-credential tests |
| 5 | the magic-link foreign-account branch erases again | ✅ failed — *"a sign-in link for a different account signs out and erases nothing"* |
| 6 | `forgetSession` leaves the ghost identity behind | ✅ failed — both user-record tests |
| 7 | treat a failed keychain write as a success | ❌ **SURVIVED — see below** |
| 8 | stop sending the build header | ✅ failed — *"an authenticated request carries the build header"* |

**Break 7 survived, and the test was wrong rather than the code.** The stub made `/today` return 401
on *every* call, so `sendRaw`'s retry-exhausted `tokens.clear()` (`APIClient.swift:137`) emptied the
store regardless of whether the new code ran. The test passed for a reason that had nothing to do
with what it claimed to assert. **The test was corrected** — the retry now succeeds, and an added
`#expect(performer.count(for: "today") == 2)` pins that the ladder is not what emptied the store —
and break 7 was re-run: it now fails as it should. **No production code was changed to make a test
pass.**

## Adversarial re-read

1. **Did Part A change any behaviour?** No. Part A ran as read-only investigations; the working tree
   was diffed afterwards and every hunk in this PR is one I wrote deliberately.
2. **Is every claim backed by a `file:line` I actually read?** Yes — and the two places where the
   first pass got it wrong are corrected in the report and labelled as corrections, including one
   where a doc comment was *not* contradicted in the way first claimed.
3. **Did I write anything into `docs/decisions.md`?** No. `git status --short docs/decisions.md`
   returns nothing. Judgment calls went to `docs/decisions-log.md`.
4. **Did I edit a test to agree with the code?** Once, and it is break 7 above — a test that passed
   against broken code because it was asserting the wrong thing. Reported rather than quietly fixed.
   No existing assertion anywhere in the suite was changed; the only edit to an existing test file is
   an additive defaulted parameter on the shared `onboardingSession` helper.
5. **Did I touch `api/`?** No. `git status --short api/` returns nothing. The server-lane finding —
   the `refresh_token_reused` grace window — is written down and stopped on, per hard stop 1.
6. **Did this become an upload phase, a Settings-sync phase, or a phase-80 phase?** No. Media upload
   is untouched. Phase 81's *"Retry now"* was checked, found to **work**, and recorded as unreachable
   on the launches that need it — recorded, not fixed.
7. **Does anything assume an entry has media?** No. `EntryCache.commit` takes media as a defaulted
   empty array, and there are explicit tests for the **text-only** and **did-it** shapes.
8. **Did I conflate `occurred_at` and `created_at`?** No, and there is a test asserting the commit
   preserves a backdated `occurredAt` and leaves `createdAt` distinct from it.
9. **Is there a change I made because it seemed correct rather than because Part A found it?**
   No. Naming each one and where it came from: the classifier and the `.unexpectedStatus` throw are
   A1's exit table; the `APIError.decoding` wrap is the fourth row of that table; `EntryCache.commit`
   is A4; both B1 fixes and the `TokenStore` fix are the completeness critic's. **The one thing I
   would flag as judgment rather than finding** is the choice to *clear* the stale pair when a
   keychain write fails rather than to carry on — that is a trade (one sign-in here versus revoking
   the parent's other devices), and it is argued in the code comment and in `decisions-log.md`.

## Least confident, ranked

1. **That the 5xx-on-refresh path is what she actually hit**, rather than a plain transport timeout
   on a slow Neon resume. Both produce "Can't reach the archive"; only one ends at sign-in. **What
   would resolve it:** query 3 in the report — the 5xx rate on `POST /v1/auth/refresh` in `fly logs`.
2. **That symptom 2 is the swallowed `try?` rather than the store quarantine.** These are different
   bugs with different fixes and the evidence does not separate them. **What would resolve it:** her
   app container — an `unreadable-store-*` folder, and whether the *rest* of her archive survived.
3. **That there is only one `APIClient` per process.** If `OnboardingGate`'s `@State` initialiser
   runs more than once, single-flight refresh is per-instance and the concurrency logout the code's
   own comment forbids is live. **What would resolve it:** an `os_log` in `AppSession.live()` and one
   launch. `refreshCount` (`APIClient.swift:37`) is already the seam.

## Found and deliberately left alone

| Finding | Belongs to |
|---|---|
| `refresh_token_reused` needs a grace window for a lost rotation response | **API lane**, its own number (hard stop 1) |
| `RecoveryLog` is written and read by nothing — a quarantine is silent | a store-recovery phase |
| `EntrySync.swift:220` parks permanent failures as `.failed`, which **is** in the retry predicate, so they loop forever while the card says "Saving" | the retry-policy question |
| *"Retry now"* works but lives inside `RootView`, so it is unreachable on the launches that need it | **phase 81** |
| A deliberate Sign out bulk-deletes `Entry` with no unsynced check (`AppEnvironment.swift:328`) | its own phase |
| No request timeout anywhere — `URLSession.shared` defaults, so a slow Neon resume is an unbounded blank launch | its own phase |
| `ArchiveExport.swift:128-132`'s asymmetric 401 retry | a cleanup |
| `PushCenter.attach` assigns unconditionally where `MediaCoordinator` guards on nil | the two-`APIClient` question |
| SwiftData's silent upsert on `@Attribute(.unique) Entry.id` as a row-loss mechanism outside `ShareDrain` | its own sweep |
| `roadmap-status.md` has **no row** for phases 128, 130 or 131 | a docs phase — backfilling three other lanes' rows from commit subjects is the failure that file records |
