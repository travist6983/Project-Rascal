# RASCAL iOS — Lane B, Phase 1 report

**Aug 8, 2026.** Branch `ios/phase1-spine`, off `main` at `a0b4ee4`. Four commits.
Nothing under `api/` was touched.

**The spine is closed and verified on a running simulator against the live API**, not only in
tests: launch → dev-login → Today loads three real assignments → complete one → the entry
persists server-side → the next fetch shows it under Done Today.

Preflight is a separate document: `ios/preflight-report.md`. Nine checks, six passed as found,
three were in-lane and fixed before any Swift was written.

**All 11 tests pass.** The suite caught a real concurrency bug in the refresh path — see below.

---

## What shipped, per story

### B-1 — Design system in code · `Rascal/DesignSystem/`

`Palette` (11 colours plus the emotional-beat gradient, exact hex), `Typography` (seven roles),
`Layout` (radius 20, media inset 14, margins 16/16/12, hairline border, y2/blur8/0.04 shadow),
`Motion` (completion spring 0.35/0.7, tap 0.98 over 0.12s, card→done 0.4s), and a
`DesignSystemCatalog` with two `#Preview`s — default and Accessibility XXL.

Two decisions worth naming:

- **Dynamic Type is real, not decorative.** `Font.system(size:)` returns a fixed size that
  refuses to scale, which would have quietly broken the spec's "nothing is a fixed point size".
  Each role carries a `Font.TextStyle` and is applied through `@ScaledMetric`, so the numbers in
  the spec are the values at the default setting and everything grows from there.
- **Reduce Motion still gives feedback.** The completion check fills, it just doesn't spring.
  Removing the animation entirely would be a different bug — the parent still needs to know the
  tap landed.

### B-2 — Networking + token storage · `Rascal/Networking/`

`APIClient` is an actor. `URLSession`, plain JSON, base URL from Info.plist, ISO 8601 **with**
fractional seconds (the stock `.iso8601` strategy rejects `…:00.481Z` outright).

`APIErrorCode` has a case per documented value plus `unknown(String)`. Call sites switch on the
code; nothing reads message text. The fallback exists for the same reason the server uses
`text` + `CHECK` instead of a Postgres enum — a code added server-side must degrade, not crash.

`KeychainTokenStore` uses `kSecAttrAccessibleAfterFirstUnlock`, never UserDefaults.

**Refresh** is the part the spec warned about, and it is built exactly as described:

- Single-flight through one actor-held `Task`. The first 401 refreshes; later callers `await`
  the same task. Two rotations would mean the second presents a token the first already
  revoked, taking `refresh_token_reused` and revoking the whole chain — a forced logout caused
  purely by concurrency.
- **Both** tokens persisted from every refresh response.
- Exactly one retry after a successful refresh, then sign out. No loop.
- `refresh_token_reused` is terminal: the store is cleared and it is never retried.

### B-3 — Models · `Rascal/Models/`

Wire types (`TodayResponse`, `AssignmentResponse`, `EntryResponse`) are deliberately **separate
types** from the SwiftData `Entry`. The API shape and the cache shape are different concerns
and will drift; collapsing them makes every server change a local migration.

Every server-constrained value is stored as `String` with a typed accessor carrying an
`unknown` case — `AssignmentStatus`, `Slot`, `PromptKind`, `CompletionMode`, `EntryType`,
`SyncState`.

On `Entry`, the non-negotiables are enforced by construction rather than by convention:
client-generated `id` before any network call; `occurredAt` and `createdAt` as separate stored
properties assigned from different sources; `deletedAt`/`updatedAt` from day one; `syncState`;
and `entryType` + `childAgeMonths` declared `private(set)`, writable only from
`applyServerResponse` — so a local guess is a compile error, not a code-review catch.

### B-4 — Auth + shell · `Rascal/App/`

Launch resolves a stored session or calls dev-login, then Today. `FloatingTabBar` is the
capsule with five slots and the raised terracotta centre. Timeline, Moments, and Settings say
plainly that they are a later phase rather than posing as empty states.

One thing I added beyond the brief: **the configured `DEV_CHILD_ID` is verified against
`GET /children` rather than trusted**, falling back to the first visible child. A stale UUID in
an xcconfig would otherwise 404 every request with nothing on screen explaining why — the exact
failure that cost time in the previous phase.

### B-5 — Today screen · `Rascal/Today/`

Sections in order, small-caps `inkMuted` headers, cards tinted by kind. Expiry inside three
days shows a quiet `inkMuted` chip; nothing is red anywhere and there is no streak counter.
Waiting shows "N waiting" as a count. Refetch on appear, on foreground, and on pull-to-refresh
— the server owns what day it is, so a phone left open overnight must not keep yesterday's board.

`media` cards render and are tappable, as specified. Hiding them would make the screen lie
about what the scheduler served.

A refetch that fails over an already-loaded board shows a quiet notice instead of blanking it.

### B-6 — Composer · `Rascal/Composer/`

`DatePill` in the header with a graphical picker, capped at today. The originating prompt sits
above the input in a soft quoted block. did-it is a 96pt terracotta check plus an optional note
— reading as complete, not degraded.

Saving is local-first: the row is inserted into SwiftData with `syncState = pending` **before**
any request. A network failure leaves the entry on the phone with `syncState = failed` and
shows a quiet note, never a lost-work error.

`assignment_expired` is handled as the one real user-facing failure — the entry saves, its
`assignmentId` is cleared, and the copy says so without alarm.

---

## Verification

**Server contract, exercised directly with the request the composer builds:**

```
POST /v1/entries                    → 201
  entry_type        text            ← derived server-side; client sent none
  child_age_months  62              ← server-computed
  occurred_at       2026-08-08T18:00:00Z   ← backdated
  created_at        2026-08-08T18:58:28Z   ← distinct, not conflated
replay, same Idempotency-Key        → 201, byte-identical
GET /today after                    → today 2, done_today 1, status "done"
```

**In the simulator**, against that same API: the board rendered three real assignments with
correct semantic tinting, and after the completion the question card moved to Done Today in
sage with the terracotta check and a de-emphasized body.

**One defect found and fixed by looking at it.** The tab bar rendered "MOMENTS SETTINGS" run
together — five 12pt tracked uppercase labels plus a raised centre button do not fit a capsule.
Caught in a screenshot, not by a test.

---

## Fixture / contract discrepancies

**None.** Live and committed shapes compared recursively as `path:type` pairs: nothing in the
fixture only, nothing in the live response only.

One thing the contract under-specifies rather than gets wrong: `docs/api-contract.md` describes
`/auth/apple` as returning `{ access_token, refresh_token, user }`, but the actual
`SessionResponse` also carries `token_type` and `expires_in`. The fixture is right and the
client decodes all five. Flagged in the previous phase's report too.

---

## Unspecified decisions, and what I chose

The design system covers colour, type, shape, motion, layout, and copy. Where it was silent I
took the most restrained option consistent with it:

1. **Tab bar label type — 10pt, uppercase, tracking 0.3.** Not the 12pt `.label` role, because
   five labels plus the centre button collide at that width. The type scale does not specify a
   tab bar. Still uppercase, still `inkMuted`/terracotta, still scales.
2. **Button copy per completion mode** — "We did it" / "Write it" / "Capture it". The spec
   names a capsule primary button but not its words. These are plain and never instruct the app
   to do something it can't.
3. **Age rendering** — `5y 2m`, from the server's `age_months`. Never computed locally.
4. **Empty state** uses the gradient wash, which the spec reserves for emotional beats and
   names "all-caught-up" as one of them.
5. **Dismiss is a long-press context menu**, not a swipe. A swipe on a card inside a vertical
   scroll view is ambiguous, and "Not for us" as a menu item is harder to trigger by accident on
   something a parent might want.
6. **Error copy** written to the spec's voice — says what happened and what to do, never
   apologises, never vague. `APIError.userMessage` is the single place it lives.

---

## What I left out

**Deliberately, per scope:** media capture, Timeline, Moments, Settings, search, widgets,
notifications, real Sign in with Apple, multi-child UI, dark mode, `GET /sync`.

**Nothing else.** The test target now exists and the suite passes.

### The test target, and what it immediately caught

The project had a single target, so I authored a `PBXNativeTarget` for `RascalTests` into
`project.pbxproj` — synchronized folder group (so new test files need no further pbxproj
edit), `TEST_HOST`/`BUNDLE_LOADER` against the app, and `GENERATE_INFOPLIST_FILE` forced back
on because the project-level xcconfig turns it off and points at the app's plist. Also added a
**shared** scheme with a test action, so `xcodebuild test` does not depend on gitignored
`xcuserdata`.

```
✔ Test run with 11 tests in 2 suites passed after 0.149 seconds.
```

**The single-flight refresh test failed on the first run, and it was a real bug, not a bad
test.** Two concurrent 401s produced *two* refreshes:

```
today | today | refresh | refresh | today | today     refreshCount: 2
```

**Mechanism, since the first version of this report asserted one it had not proven.** The
guard and the assignment looked atomic:

```swift
if let existing = refreshTask { return try await existing.value }
…
refreshTask = task
```

There is no `await` between them, so I had assumed the actor made that sequence indivisible.
It does not. Instrumenting the real client recorded this:

```
A:sawNil -> A:afterLoad -> B:sawNil -> B:afterLoad -> A:assigned
```

Both callers cleared the nil check before either stored a task. Actors are reentrant and
guarantee exclusivity only *between* suspension points; an `async` function may suspend where
no `await` is visible.

Two things stated precisely, because the first version of this paragraph asserted a mechanism
it had not measured. Restoring the old implementation reproduces the fault exactly
(`refreshCount == 2`), so the fix is necessary and sufficient — that part is measured. But an
isolated model of the same *shape* does **not** reproduce it, so the interleaving depends on
the surrounding call path rather than on the check/assign pair in the abstract. "It reads as
atomic" is not evidence of anything, which is the real lesson: the synchronous claim is safe
by construction rather than by inspection.

The fix splits it — claiming the slot happens in a **synchronous** actor method, which has no
suspension points at all, and only the awaiting is `async`:

```
today | today | refresh | today | today               refreshCount: 1
```

This is exactly the failure the brief warned about, and in production it would have been a
forced logout: the second rotation presents a refresh token the first already revoked, takes
`refresh_token_reused`, and the server revokes the whole chain. It is also invisible in normal
use and would have surfaced as "the app randomly signs me out". Worth stating plainly — I
would not have found it by reading the code, because I had already read it and concluded it
was correct.

A second failure was my own bad assertion: `#expect(interval == 0.481)` on a value that parses
to `0.4809999465942383`. Now a tolerance check.

### Two other things fixed along the way

- **`Config.xcconfig` was being copied into the app bundle** as a resource by the template's
  Resources build phase. An xcconfig is a build input; shipping it put `DEV_CHILD_ID` inside
  the product for no reason. Removed, and verified absent from the built `.app`.
- The app rebuilds clean afterwards with **zero warnings** of mine, and still renders and
  completes correctly in the simulator.

The device pass remains yours to run — `ios/device-test.md` lists the ten checks and why the
simulator cannot substitute for any of them.

---

## Shortest path to the first photo entry

The media flow is already three-quarters specified by the API and the models handle it.

1. **`PhotosPicker` in the composer's `media` branch** — replaces `captureComingSoon`. SwiftUI
   native, no dependency.
2. **`POST /v1/media`** to register the file and get a presigned PUT. Add a `Media` SwiftData
   model alongside `Entry`; `entryId`, `key`, `kind`, `syncState`, and a local file URL so an
   upload survives a force quit.
3. **Background `URLSession` upload** (`.background` configuration) direct to S3. The server
   never proxies bytes, and video on cellular makes this non-optional rather than a refinement.
4. **`POST /v1/media/{id}/complete`** — the server recomputes `entry_type` here, since media
   lands after the entry exists. The client just refetches; it must not derive the new type.
5. **Show the entry immediately with a local thumbnail.** `thumb_key` is null server-side —
   thumbnails are deferred out of P0 — so every card must already lay out with no thumbnail.

The ordering that matters: **entry first, media second.** The entry row exists and syncs before
any byte is uploaded, so a failed upload is a retriable attachment rather than lost writing.
`Entry.applyServerResponse` is already the single place server truth lands, and it will carry
the recomputed `entry_type` without a change.

Worth settling before that phase starts: whether a multi-photo entry is in scope for the first
pass, since it changes `Media` from a to-one to a to-many and the timeline card from a
thumbnail to a row with a `+8` overflow tile.
