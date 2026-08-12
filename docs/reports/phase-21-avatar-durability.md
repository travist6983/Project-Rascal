# Phase 21 — Avatar durability

The child's avatar reaches the archive. `LocalAvatarStore` stays exactly where it was and becomes
the cache in front of a server copy, which is the relationship SwiftData already has with the
server everywhere else in this app.

Branched from `origin/main` @ efd3238. Preflight evidence: `docs/reports/phase-21-preflight.md`.

---

## 1. The actual request and response shapes

Both routes exist and behave as `docs/blocked.md` described. Exercised against a local API with
real Tigris credentials — full transcripts in the preflight report.

**`POST /v1/children/{child_id}/avatar-upload-url`** — `child_access("parent")`

```
REQUEST   {"content_type": "image/jpeg", "bytes": 38577}
RESPONSE  200
{ "upload_url": "https://rascal-media-dev.t3.storage.dev/children/…/avatar/….jpg?X-Amz-…",
  "avatar_key": "children/9e41dc78-…/avatar/fbf628db-….jpg",
  "expires_in": 3600 }
```

**`GET /v1/children/{child_id}/avatar-url`** — `child_access("viewer")`

```
RESPONSE  200   { "url": "https://rascal-media-dev.t3.storage.dev/…?X-Amz-…", "expires_in": 3600 }
RESPONSE  404   {"error":{"code":"not_found","message":"Avatar not found","field":null}}
```

### Divergence from what `blocked.md` specified

**None on the presign.** It returns a presigned PUT, a key, and an expiry, named `upload_url` /
`avatar_key` / `expires_in`. The brief warned the built route might name them differently; it does
not.

**One gap rather than a divergence:** the read route's field is `url`, not `avatar_url`.
`blocked.md` never named that field, so there was nothing to diverge from. The client uses `url`.

Two facts the spec did not state and the client now depends on:

- **`expires_in` is 3600 on both**, from `settings.presign_ttl_seconds`.
- **The key carries a fresh UUID per presign**, not a stable `avatar.jpg` — deliberately, so that a
  replaced avatar is distinguishable from a corrupted one. **The client therefore cannot derive the
  key** and must store whichever one it was handed. It does.

### The Content-Type trap, found in curl before any Swift was written

The presigned URL carries `X-Amz-SignedHeaders=content-type;host`, so the header is inside the
signature:

```
PUT with Content-Type: image/jpeg          → 200
PUT with Content-Type: application/octet-stream → 403 SignatureDoesNotMatch
PUT with no Content-Type at all            → 403 SignatureDoesNotMatch
```

The XML never mentions `Content-Type`. `PendingAvatarUpload.contentType` therefore stores the exact
string that was presigned for and the PUT sends that same string, and a test asserts the two match
rather than trusting them to.

---

## 2. The hand-run round trip

Real bytes, real Tigris, before writing Swift. A 512-wide JPEG, 38 577 bytes.

| # | Step | Status |
|---|------|--------|
| 1 | `POST .../avatar-upload-url` `{"content_type":"image/jpeg","bytes":38577}` | **200** |
| 2 | `PUT` the bytes to `upload_url` with `Content-Type: image/jpeg` | **200** |
| 3 | `PATCH /v1/children/{id}` `{"avatar_key":"children/…/avatar/fbf628db-….jpg"}` | **200** |
| 4 | `GET .../avatar-url` | **200** |
| 5 | `GET` that presigned URL | **200** |

```
original: 582e21ea83c1a71bcde02a1bdfe6ff498be721c6f8677691c876c96dd119a89d  38577 bytes
returned: 582e21ea83c1a71bcde02a1bdfe6ff498be721c6f8677691c876c96dd119a89d  38577 bytes
cmp → identical
```

Also exercised: `image/gif` → 422 `validation_failed` (`content_type`); 6 MiB → 422
`validation_failed` (`bytes`); `bytes: 0` → 422, caught a layer earlier by Pydantic's `gt=0`.

---

## 3. What happens when each step fails

The invariant across all three: **the local copy is never removed, and the parent never sees an
error about it.** A parent who cropped an avatar on a train and watched it appear must not watch it
vanish when the network comes back wrong. Uploading is a durability concern; displaying is not, and
they are not allowed to share a failure.

| Step fails | What the parent sees | What is retried | When |
|---|---|---|---|
| **Presign** — offline / 5xx | Nothing. The avatar renders from disk. | The whole three-step sequence. | Next sweep, on `UploadBackoff` (~5s, doubling, ceiling 10min, jittered), up to 6 attempts. |
| **Presign** — 422 `validation_failed`, or 404/403 | Nothing. The avatar renders from disk. | **Nothing.** Retrying cannot fix a refused content type, an oversized file, or a child this phone cannot write to. | Never. The record is dropped; the picture stays. |
| **PUT** — offline, 5xx, or a 403 on a stale signature | Nothing. | The whole sequence, including a **fresh presign** — a signature that failed is not reused. | Same backoff. |
| **PATCH** — offline / 5xx | Nothing. | The whole sequence. The bucket keeps one orphaned object; the child is *not* pointed at it. | Same backoff. |

Two deliberate consequences:

- **The commit is last, never optimistic.** An abandoned upload leaves an unreferenced object in
  the bucket rather than a child record pointing at bytes that never arrived. Of the two, only the
  second is visible to a parent — which is `services/avatars.py`'s own argument, followed here.
- **Past 6 attempts the record stops being swept but is not discarded**, and the local copy is
  untouched. What stops is spending a request every foreground.

Failing loudly was considered and rejected: a parent cannot act on "the avatar presign was
refused", and putting that sentence on Settings would be an error message about a picture that is
visibly right there.

---

## 4. How pending-upload state is modelled

`PendingAvatarUpload` — `childId`, `contentType`, `byteCount`, `attemptCount`, `nextAttemptAt` —
held in `UserDefaults`, keyed by child, drained by `AvatarSync.sweep()` which
`EntrySync.sweep()` calls **last**, after entries and media.

### Why not the entry or media queue

Both were considered:

- **The entry queue** drains `Entry` rows by `syncState`. An avatar is not an entry and must never
  become one — filing a picture of the child in the archive as an entry's artifact is the exact
  outcome `services/avatars.py` exists to avoid.
- **The media queue** drains `Media` rows, and every one is gated on its entry existing
  server-side first, because `POST /media/upload-url` needs an `entry_id` it recognises. **An
  avatar hangs off a child**, and `avatar-upload-url` needs only a child that by definition already
  exists. There is nothing for it to wait behind.

So it is its own record, **modelled the same way a media row is**: durable facts plus
`attemptCount`/`nextAttemptAt` feeding the *same* `UploadBackoff` arithmetic, drained by the same
sweep. It is explicitly not a second retry policy — the schedule, the ceiling and the jitter are
shared, which is what "retry is the sync sweep's job" means here.

It goes **last** in the sweep because the archive outranks a decoration: an entry the parent wrote
and a photo they took should not queue behind a 40KB square on a thin connection.

### Why `UserDefaults` and not SwiftData

This is the one thing here with a `nextAttemptAt` that is not a SwiftData row, so the reason is
worth stating rather than leaving to be discovered.

`AppEnvironment.schema` is a plain `Schema([Entry, Media, MediaPart, Assignment])` — **no
`VersionedSchema`, no `SchemaMigrationPlan`**, only a recovery path that rebuilds the store when it
cannot be opened. Adding a `@Model` changes the store for every existing install, and this repo has
already shipped one fix for exactly that ("the app could not launch on any device that had the
previous build"). Risking the launch path of every phone on TestFlight to hold one small row per
child is not a trade worth making.

The bytes are not in this record in any case — they are already on disk in `LocalAvatarStore`,
backed up and surviving relaunch. The record holds only *that* they are owed and *how* to send
them, which is the same class of thing `OnboardingDraft` and the Apple subject already keep there.

---

## 5. Test delta

Both runs from a deleted `~/Library/Developer/Xcode/DerivedData`.

| | Before | After |
|---|---|---|
| Tests passing | **730** | **756** (+26) |
| Suites | **88** | **95** (+7) |
| Failing | 0 | 0 |
| Warnings | **21** | **21** — unchanged |

**Zero warnings in any file this phase touches.** All 21 are pre-existing, in
`Rascal/Extraction/ExtractedDetails.swift` (3), `RascalTests/PushPermissionTests.swift` and
`RascalTests/ExtractionTests.swift` (18 lock-in-async warnings). None is in a file this diff
changes. The new stub deliberately confines its locking to synchronous helpers — the shape
`StubPerformer` already uses — so it adds none of that class.

**Destination:** the brief names `iPhone 15 Pro Max`; no iPhone 15 simulator exists on this machine
(installed runtimes are 16e and the 17 family). Used **iPhone 17 Pro Max**, addressed by UDID
because two simulators share the name.

### Breaking the assertions, as instructed

A test that passes whether or not the cleanup happens asserts nothing, so the three survival tests
were each made to fail on purpose:

```
sabotage 1 — store.remove(for:) added to the transient-failure path (`defer_`):
  ✘ "a failed commit leaves the local copy alone"
  ✘ "a failed PUT leaves the local copy alone"
sabotage 2 — store.remove(for:) added to the permanent-refusal path (`giveUp`):
  ✘ "a refused presign leaves the local copy alone"
```

Each failed with `(store.load(for: child) → nil) == (Data("jpeg".utf8) → 4 bytes)`. Both sabotages
reverted; the final run above is clean. Note the two paths are genuinely separate — sabotage 1 does
not break the presign test — which is why there are three tests and not one.

---

## 6. Least confident, ranked

1. **The upload does not use a background `URLSession`, and the brief asked for
   `isDiscretionary = false`.** That property only exists on background configurations. Reusing
   `MediaUploader`'s session is wrong — its delegate routes every callback by `taskDescription` to
   a `Media` row, and an avatar has none — and standing up a second background session means a
   second identifier, a second delegate and a second launch-events path for one ~40KB PUT. Since
   retry is the sweep's job, a plain session with `waitsForConnectivity = false` keeps the intent
   (never defer, cellular allowed) and loses only the ability to finish while suspended. **The cost
   is real:** an app backgrounded mid-PUT waits for the next foreground. I judged that acceptable
   at 40KB and did not measure it. **This is now the only substantial unverified decision.**
2. **`ChildHeroCard` is the only place an avatar renders.** Not Today, Timeline, the composer, or
   the widget. A product call I made, not one the brief made — see the scope note below.
3. **The Settings card can say "Everything's uploaded." while an avatar is still owed.**
   `EntrySync.Outstanding` counts entries, deletions and media; a pending avatar is deliberately
   not counted, so it does not appear in that headline or in Today's "still to go". Left that way
   on the grounds that the card is about the *archive's* durability and an avatar is profile
   decoration whose original is still in the parent's photo library — and that surfacing a number
   a parent cannot act on is what the brief's "no error, no retry, no log line" rules out. It is a
   real inaccuracy in a specific sentence, and it is a decision rather than an oversight.
4. **`UserDefaults` versus SwiftData for the pending record.** The migration-brick reasoning is
   sound, but the result is that one retry-scheduled thing lives somewhere different from every
   other retry-scheduled thing. If a future phase adds a `VersionedSchema`, this should move.
   (The persistence itself is now tested, including the `[UUID: …]` encoding — see below.)
5. **Whether "no local copy" should really clear the record.** If the bytes are missing the record
   is dropped, on the grounds that there is nothing to upload. A container rebuild that loses the
   file therefore also loses the intent to upload. Keeping a record that can never succeed seemed
   worse.

### Resolved since the first draft of this report

Five things that were listed as reasoned-about have since been verified, and two were wrong:

- **The shipping transport now has real network evidence.** `URLSessionAvatarTransfer` was compiled
  verbatim into a standalone harness and run against the live API and real Tigris: `put()` moved
  38 577 bytes, `get()` returned them byte-identical, and a deliberately mismatched `Content-Type`
  made `check()` throw exactly `.status(403)`. **The error mapping is verified against a genuine
  403, not a stub.**
- **A stale key does not 404 the way the client was originally documented to expect.**
  `presign_avatar_read` only checks `avatar_key IS NULL` and never asks storage, so a child
  pointing at a deleted object gets **200 and a valid URL**, and the 404 arrives from storage.
  Verified live. Both paths are handled and there is now a test for the realistic one.
- **`LocalAvatarStore` never set the backup flag its own header claimed.** `StagingStore.prepare`
  actively sets `isExcludedFromBackup = true`; `LocalAvatarStore.prepare` set nothing and inherited
  the default. The behaviour was right by accident. It now sets `false` explicitly — which is the
  same class of false-comment defect this phase exists to fix, found in the file it exists to fix.
- **`[UUID: PendingAvatarUpload]` round-trips through `UserDefaults`.** `UUID` is not
  `CodingKeyRepresentable`, so `JSONEncoder` writes a flat array rather than a keyed object. It
  round-trips symmetrically, but it would have failed silently and taken every pending avatar with
  it, so it is now tested — including two children not colliding.
- **The avatar actually draws.** This project has no snapshot harness, so `ImageRenderer` is used
  to produce real pixels: a card given a solid-green avatar is measurably green, and one given nil
  or undecodable bytes is not. Sabotaged (`if false`) to confirm it fails — it did, `drawn → 0.0`.

---

## 7. What was not verified empirically

**What did run against the real thing**, so the boundary is exact:

- The **five-step round trip in curl**, against the live API and real Tigris, byte-identical.
- **The shipping Swift transport itself.** `URLSessionAvatarTransfer` was extracted verbatim,
  compiled into a standalone harness, and run against the same API and bucket:

```
1. presign            → 200
2. transfer.put()     → succeeded, 38577 bytes to Tigris
2b. mismatched type   → threw status(403)   ← check() verified against a real 403
3. commit avatar_key  → 200
4. avatar-url         → 200
5. transfer.get()     → 38577 bytes, BYTES IDENTICAL
```

- **Stale-key behaviour**, by pointing a child at a nonexistent object: our route 200s, storage
  404s.
- **The rendering branch**, as pixels, via `ImageRenderer` in the test target.
- **Persistence of the pending record** across store instances, including the `[UUID: …]` encoding.

**What is still reasoned about, not observed:**

- **The full app, on a device or simulator, end to end.** No signed build was produced, so nothing
  here exercised `AvatarSync` *inside the running app* — the wiring between `OnboardingSession`,
  `RootView`, `EntrySync.sweep()` and `SettingsScreen` is verified by tests and by reading, not by
  watching an avatar upload during real onboarding. The brief anticipated this limit.
- **Backgrounding mid-upload** — confidence item 1. The claim that a 40KB PUT rarely needs to
  survive suspension is judgement, not measurement.
- **`ChildHeroCard` on a real screen.** `ImageRenderer` proves the image reaches the disc; it does
  not prove the result looks right at Dynamic Type sizes or against the peach card in daylight.
- **A real HEIC avatar.** `AvatarCrop` always emits JPEG, so `contentType` is `image/jpeg` in every
  shipping path; the HEIC branch is covered by a unit test only.
- **Two children.** Multi-kid is out of scope; the per-child keying is tested at the store level
  but never exercised by the app, which resolves `children.first`.

---

## Scope notes

**Two premises in the brief were false, and both changed the work.** Full evidence in the preflight
report.

- **The avatar was write-only.** `LocalAvatarStore` was written in one place and read by nothing
  outside the test target; the only avatar that rendered was the in-memory crop on the setup screen
  itself. So "the UI shows the new avatar immediately" and "404 renders the existing no-avatar
  state" both described a display that did not exist. Giving `ChildHeroCard` an avatar branch —
  with its existing initials disc as the fallback — is the minimum that makes §3 mean anything, and
  it is the surface the brief itself named. **This is the one place this diff goes beyond the
  letter of the brief, and it is flagged rather than smuggled.**
- **`ChildResponse` was dropping `avatar_key`.** The server has always sent it on `GET /children`;
  the Swift type simply declared no property for it. Adding it costs one line and no request, and
  it is what lets a child with no avatar render initials without a round trip that 404s.

**Backfilling the existing device-only avatar stays out of scope**, as instructed — it would fire a
network write from app start for one row. **But the brief's stated alternative does not exist:**
"re-picking the avatar in Settings" is not a thing the app can do. `EditChildSheet` edits name,
birthday, pronouns and timezone, and `updateChild` documents `avatar_key` as deliberately absent.

So for every parent already on TestFlight, the avatar on their phone has no path to the server at
all — onboarding is the only producer and they have already passed through it. **This is recorded
as a decision rather than an omission, and it wants a follow-up phase**: either a Settings re-pick
(which also gives the "change the photo" affordance the app has never had) or a one-time backfill.

**One piece of copy was corrected.** `AvatarStep`'s subtitle read *"Optional. It stays on this
phone for now."* — the same false-sentence problem as `AvatarStore`'s header comment, in the one
place a parent actually reads it. A promise about where a picture of someone's child is kept is not
a detail to leave stale.

**Also out of scope and untouched:** `api/` (no changes), parent avatars, the child switcher,
`ChildSetupFlow`'s question sequence, and `AvatarCrop`, which was fixed in PR #28 and is unchanged
here.

### On the phase-20 collision

The brief says this phase and phase 20 must not run concurrently because both edit
`ChildSetupFlow.swift`. **Phase 20 merged as PR #52** (`efd3238`), which is what this branch is cut
from, and `gh pr list` shows no open PRs — so there is no concurrent run and phase 20's edits are
already in the base.

### Where this branch lives

The primary checkout was mid-merge on `tmp/conflict-probe` with conflicts in
`docs/decisions-log.md` and `docs/roadmap-status.md` and a large staged diff across both lanes.
Rather than disturb it, this phase ran in a **worktree** at `../Project-Rascal-avatar` — the same
arrangement phase 20 used. The conflict probe is untouched.
