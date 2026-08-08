# RASCAL iOS — Phase 2 (Capture) preflight, revised prompt

**Aug 8, 2026.** Branch `ios/phase2-capture-build`.

## Verdict: PASSED. Building.

All five checks pass. One thing about the branch base needs stating plainly before the rest,
because the prompt's check 1 and check 4 cannot both be satisfied as written today.

| # | Check | Result |
|---|---|---|
| 1 | Branch and baseline | **PASS**, with a base correction — see below |
| 2 | Permissions | **PASS** |
| 3 | Storage round trip | **PASS** — all six assertions |
| 4 | `EntrySync` read before extending | **PASS** |
| 5 | Device | **PASS** |

---

### 1. Branch and baseline — PASS, branched from `ios/phase2-foundations` rather than `main`

**`main` does not yet contain `presign_get` or `EntrySync`.** Both were built in the previous
turn and live on `ios/phase2-foundations`, which is exactly `main` plus two commits. So:

- Check 1 says branch from updated `main`.
- Check 4 says `EntrySync.sweep()` already exists and must be extended, not duplicated.

On `main` alone, check 4 would fail. Branching from `foundations` satisfies the *intent* of
both — a base strictly newer than `main` that contains everything this phase depends on — and
is the only base on which the phase is buildable at all. Opened **PR #11** so it lands; once
merged, this branch's base is `main` by another name.

The prompt's baseline figures mix the two states. Actual counts:

| | API | iOS |
|---|---|---|
| `main` | 270 | 11 |
| this branch (`main` + foundations) | **277** | **18** |

Measured on this branch, not quoted:

```
clean xcodebuild from an empty derived-data path  →  0 errors
iOS:  ✔ Test run with 18 tests in 3 suites passed
API:  277 passed
```

`ios/lane-b-phase1-report.md` read. **Carried forward, not rediscovered:** the recorded
discrepancy is that `docs/api-contract.md` describes `/auth/apple` as returning
`{ access_token, refresh_token, user }` while the real `SessionResponse` also carries
`token_type` and `expires_in`. The fixture is correct and the client already decodes all five.

Also carried: `thumb_key` is null server-side, which is exactly why C-2 caches a local
thumbnail and why C-1's sweep waits for it.

### 2. Permissions — PASS

All three usage strings present in **both** `Info.plist` and `Info-Debug.plist` (the plists are
swapped per configuration by `INFOPLIST_FILE[config=Debug]`, so a key in only one ships in only
one build). Verified present in the built bundle previously; unchanged since.

### 3. Storage round trip — PASS

Re-proved from this machine against the real bucket. Every assertion the prompt lists:

```
POST /entries                 -> 201
POST /media/upload-url        -> 200
  keys: chunk_bytes, expires_in, media_id, multipart, parts, s3_key, upload_url
  HOST: rascal-media-dev.t3.storage.dev        ← real Tigris, not localhost, not moto
GET  /url BEFORE complete     -> 409 upload_incomplete
PUT  <presigned>              -> 200
  ETag: "4edd3122d08ca94fe65916ddf54008f0"     ← present on the response
POST /complete                -> 200
GET  /url AFTER complete      -> 200
fetch that URL                -> 200, 146 bytes
BYTE-IDENTICAL: yes
```

**`chunk_bytes` is `null`** on the single-PUT path, with `multipart: false`. Consistent — it is
the multipart part size and there are no parts. C-3 reads and stores the field and must tolerate
null; it must not hardcode 8MB and must not treat null as an error.

### 4. `EntrySync` — PASS, read before writing

Existing surface that C-5 extends rather than replaces:

```
static func unsyncedDescriptor() -> FetchDescriptor<Entry>
func unsyncedCount() -> Int
func sweep() async -> Int
```

Driven from `RootView`: on `.task`, on `scenePhase == .active`, on composer dismiss, and from
the Today row's **Try now**. C-5 folds media into this — one sweep, one count, one affordance.

### 5. Device — PASS

`travis's iPhone`, iPhone 15 Pro Max (iPhone16,2), available and paired. Device work is batched
into one session at the end per the prompt; `ios/device-session.md` will be written when C-1
through C-5 are green.

---

## Settled decisions, acknowledged

- **One `Media` row per file.** Three photos is three sequential `upload-url` calls. No batch
  shape exists in the contract and inventing one is a schema change.
- **Staged originals are deleted only when `complete` returned 200 *and* a local thumbnail
  exists.** Never on a timer. Deleting on `complete` alone makes the first timeline render
  refetch every photo just uploaded.
