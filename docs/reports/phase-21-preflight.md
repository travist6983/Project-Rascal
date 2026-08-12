# Phase 21 — Avatar durability: preflight evidence

Run 2026-08-11 on `ios/phase-21-avatar-durability`, branched from `origin/main` @ efd3238.

**All four preflight checks pass. The gate is open.** What follows is the evidence, plus four
findings about the *client* that the brief's premises did not anticipate. None of them is a
preflight failure — every one of them is about `ios/`, and preflight only gates `api/`.

---

## 0 — The server is the code under test

The phase-19 preflight earned this check and it is run first here. A long-running local server
can predate the code being tested and answer from a stale import.

```
$ lsof -ti :8000 -sTCP:LISTEN                       → 66951
$ ps -p 66951 -o lstart=,command=
  Tue Aug 11 19:23:20 2026  .venv/bin/uvicorn rascal.main:app --host 0.0.0.0 --port 8000
$ lsof -p 66951 -a -d cwd                           → /Users/travis/repos/personal/Project-Rascal/api

$ git log -1 --date=iso -- api/src/rascal/services/avatars.py
  7ef9b3d 2026-08-10 21:36:41 -0400 feat(api): close the five gaps the iOS lane was working around

$ git diff origin/main --stat -- routers/children.py services/avatars.py schemas/child.py services/s3.py
  (empty — identical to origin/main)
$ git status --short -- (same four files)
  (empty — clean)
```

Server start (Aug 11 19:23) postdates the route commit (Aug 10 21:36) and every source mtime.
The four avatar-path files are byte-identical to `origin/main`, which is what this branch is cut
from. No `--reload`, but nothing needed reloading.

One caveat recorded rather than waved off: the server runs out of the **primary checkout**, which
is mid-merge on `tmp/conflict-probe` and has uncommitted edits to *other* `api/` files
(`constants.py`, `routers/debug.py`, `services/pool_health.py`, `services/scheduler.py`). None of
them is on the avatar path, and the four files that are, are clean.

---

## 1 — Both routes exist and behave as documented

```
$ grep -n "avatar-upload-url" api/src/rascal/routers/children.py   → 117
$ grep -n "avatar-url"        api/src/rascal/routers/children.py   → 151
```

### Request and response shapes, as observed

`POST /v1/children/{child_id}/avatar-upload-url` — `child_access("parent")`

```
REQUEST   {"content_type": "image/jpeg", "bytes": 41234}
RESPONSE  200
{
  "upload_url": "https://rascal-media-dev.t3.storage.dev/children/9e41dc78-…/avatar/a478896c-….jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=…&X-Amz-Date=20260812T010639Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=content-type%3Bhost&X-Amz-Signature=…",
  "avatar_key": "children/9e41dc78-…/avatar/a478896c-….jpg",
  "expires_in": 3600
}
```

`GET /v1/children/{child_id}/avatar-url` — `child_access("viewer")`

```
RESPONSE  200
{ "url": "https://rascal-media-dev.t3.storage.dev/children/…/avatar/….jpg?X-Amz-…", "expires_in": 3600 }
```

### Divergence from `docs/blocked.md`

**None that matters, and one that does not.** The brief warned the built route might name things
differently. It does not: the presign response is `upload_url` · `avatar_key` · `expires_in`,
which is a presigned PUT, a key, and an expiry — the three the brief required.

The read route returns `url`, not `avatar_url`. `blocked.md` never named that field, so this is a
gap in the spec rather than a divergence from it. The client will use `url`.

Two facts the spec did not state and the client depends on:

- **`expires_in` is 3600** on both, from `settings.presign_ttl_seconds`. Long enough that the
  read URL does not need refreshing mid-screen; short enough that it must never be persisted.
- **The key carries a fresh UUID per presign**, not a stable `avatar.jpg` — `build_avatar_key`
  says so explicitly, so that a replaced avatar is distinguishable from a corrupted one. **The
  client therefore cannot derive the key and must store the one it was handed.**

---

## 2 — The read route 404s on no avatar

Against a child with `avatar_key` null:

```
$ curl -s -w "%{http_code}" .../avatar-url -H "Authorization: Bearer $TOKEN"
{"error":{"code":"not_found","message":"Avatar not found","field":null}}
404
```

**Required 404. Got 404.** Not a 200 with a null URL. The client is designed for what it actually
does: 404 is a normal, expected, non-error state — no surfacing, no retry, no log line.

The error body is the standard `RascalError` envelope, so the existing `APIError` decoding
handles it and `error.code == .notFound` is the discriminator the client branches on.

### The other 404, which is not this one

Asked later, while hardening the client, and it changes what the client has to handle:

```
$ curl -X PATCH .../children/{id} -d '{"avatar_key":"children/{id}/avatar/does-not-exist.jpg"}'
  → 200
$ curl .../children/{id}/avatar-url
  → 200   (a perfectly valid presigned URL)
$ curl "<that url>"
  → 404   (from storage)
```

**A stale key does not 404 from this route.** `presign_avatar_read` only checks whether
`avatar_key IS NULL`; it never asks storage whether the object is still there. So the route's 404
is the *narrow* case — the column is null — and the realistic staleness (key set, object gone)
surfaces as a 404 on the presigned GET instead.

That is not a defect in the route: checking existence would cost a HEAD on every read for a case
that should not happen. It does mean **a client that only handled the route's 404 would be handling
the rarer of the two**, so `AvatarSync` treats both, plus offline, as the same answer: no picture.

---

## 3 — A full round trip, by hand, outside the app

Real bytes against real Tigris storage (`https://t3.storage.dev`, bucket `rascal-media-dev`). A
512-wide JPEG produced with `sips`, 38 577 bytes.

| # | Step | Result |
|---|------|--------|
| 1 | `POST .../avatar-upload-url` `{"content_type":"image/jpeg","bytes":38577}` | **200** — `upload_url`, `avatar_key`, `expires_in: 3600` |
| 2 | `PUT` bytes to `upload_url` with `Content-Type: image/jpeg` | **200**, empty body |
| 3 | `PATCH /v1/children/{id}` `{"avatar_key":"children/…/avatar/fbf628db-….jpg"}` | **200** — `avatar_key` echoed, `updated_at` advanced |
| 4 | `GET .../avatar-url` | **200** — presigned GET, `expires_in: 3600` |
| 5 | `GET` that URL | **200** — bytes returned |

```
original: 582e21ea83c1a71bcde02a1bdfe6ff498be721c6f8677691c876c96dd119a89d  38577 bytes
returned: 582e21ea83c1a71bcde02a1bdfe6ff498be721c6f8677691c876c96dd119a89d  38577 bytes
$ cmp avatar.jpg roundtrip.jpg  → identical
```

Byte-for-byte. The archive gets back exactly what the phone sent.

### The Content-Type trap, found in curl as instructed

Step 2 did **not** fail on a signature mismatch, because the `Content-Type` matched. It was then
made to fail on purpose, because the brief asked where this breaks:

```
presigned for image/jpeg, PUT sent as application/octet-stream:
  403 <Code>SignatureDoesNotMatch</Code>
Content-Type omitted entirely (curl defaults to x-www-form-urlencoded):
  403 <Code>SignatureDoesNotMatch</Code>
```

The signature covers it: `X-Amz-SignedHeaders=content-type;host`. **The `Content-Type` sent to
the presign call and the one set on the PUT must be byte-identical**, and getting it wrong
produces a 403 whose XML never mentions the header. The client must set exactly the string it
presigned for, and never leave it to `URLSession` to infer.

Also probed, since the client needs to know which failures are worth a retry:

```
{"content_type":"image/gif","bytes":1000}      → 422 validation_failed, field "content_type"
                                                  "An avatar must be a JPEG, PNG, or HEIC image."
{"content_type":"image/jpeg","bytes":6291456}  → 422 validation_failed, field "bytes"
                                                  "An avatar must be between 1 byte and 5242880 bytes."
{"content_type":"image/jpeg","bytes":0}        → 422 validation_failed, field "bytes"
                                                  "Input should be greater than 0"
```

Worth noting that the last one is caught a layer earlier than the other two — `bytes` is
`Field(gt=0)` on `AvatarUploadUrlRequest`, so Pydantic refuses it before `plan_avatar_upload`'s
own ceiling check ever runs, which is why its message reads differently. It does not change the
client's branch: all three are `422` / `validation_failed` on the same envelope.

All three are **permanent refusals** — retrying cannot fix any of them, which is what decides
their branch in the sweep.

---

## 4 — Baseline

`DerivedData` deleted first, per the standing rule that a warm build reports zero warnings on
code that has plenty.

```
$ rm -rf ~/Library/Developer/Xcode/DerivedData
$ xcodebuild test -scheme Rascal \
    -destination 'platform=iOS Simulator,id=2F6BEC36-…' CODE_SIGNING_ALLOWED=NO
✔ Test run with 730 tests in 88 suites passed after 13.658 seconds.
** TEST SUCCEEDED **
```

| | Baseline |
|---|---|
| Tests | **730 passing, 0 failing** |
| Suites | **88** |
| Warnings | **21** in 3 files, all pre-existing |

**Destination divergence.** The brief names `iPhone 15 Pro Max`. No iPhone 15 simulator exists on
this machine — the installed runtimes are iPhone 16e and the 17 family. Used **iPhone 17 Pro Max**
(`2F6BEC36-8650-442B-9F23-E2A2F04A020F`), addressed by UDID because two simulators share that
name and a name-only destination is ambiguous.

**The 21 warnings, so the "zero warnings in files this phase touches" rule can be checked
honestly.** None is in a file this phase touches:

- `Rascal/Extraction/ExtractedDetails.swift` — 3 × main-actor isolation on `nilIfEmpty`
- `RascalTests/PushPermissionTests.swift` — 15 × `NSLock.lock`/`unlock` in async contexts
- `RascalTests/ExtractionTests.swift` — 3 × the same lock warning

(A 22nd line, `Metadata extraction skipped. No AppIntents.framework dependency found.`, is a
toolchain note rather than a source warning.)

---

## Findings the brief's premises did not anticipate

All four are `ios/`. None gates the preflight. All four change what the implementation has to be,
so they are recorded here rather than discovered halfway through the diff.

### F1 — The avatar is write-only today. Nothing reads it back, anywhere.

The brief says the local copy is what "the UI shows immediately" and that a 404 falls back to
"whatever `ChildHeroCard` and onboarding already show". Both presuppose a display that exists.

`LocalAvatarStore` is written in exactly one place — `OnboardingGate.swift:378`, inside
`finish(with:)` — and `avatars.load(for:)` is **called by nothing outside the test target**:

```
$ grep -rn "\.load(for:" Rascal RascalTests --include="*.swift"
RascalTests/OnboardingSessionTests.swift:580
RascalTests/OnboardingSessionTests.swift:600
```

The one avatar that renders is `AvatarStep.swift:124`, and it renders `session.avatar` — the
in-memory `Data?` held during setup — not the stored file. So a parent crops a photo, sees it on
that one setup screen, and **never sees it again on any screen in the app.** It is saved to disk
and read by nothing.

`ChildHeroCard` renders an initials disc *unconditionally*: it has no avatar branch to fall back
from. There is no no-avatar state to "render on 404", because there is no avatar state at all.

**Consequence for this phase:** §3 "Reading it back" has no consumer unless one is wired. The
minimum that makes §3 mean anything is to give `ChildHeroCard` an avatar branch with the initials
disc as its fallback — which is what the brief's own 404 sentence describes.

### F2 — The out-of-scope justification for skipping backfill rests on a feature that does not exist

The brief rules backfill out with: *"re-picking the avatar in Settings achieves the same thing
with the parent's knowledge."*

**Settings has no avatar re-pick.** The only `avatar` in `Rascal/Settings/` is `ChildHeroCard`'s
private initials-disc helper. `EditChildSheet` edits name, birthday, pronouns and timezone;
`updateChild` in `SettingsAPI.swift:25` documents `avatar_key` as *deliberately absent*.

So with backfill out of scope and no re-pick, the only path that can ever put an avatar on the
server is **onboarding, which each parent passes through once**. Every parent already on
TestFlight has an avatar on their phone that this phase cannot move, and no way to ask for it to
move. That is a real gap, it is the user's call rather than mine, and it is flagged rather than
quietly closed.

### F3 — `ChildResponse` drops `avatar_key`, though the server sends it

The brief asks that the client persist "the fact that an avatar exists (`avatar_key` on the
cached child)". Two things about that:

**There is no cached child.** No SwiftData `@Model` for a child exists. `ChildResponse` is
fetched by `GET /children` on every launch and held in `OnboardingSession.state`.

**But the fact is already on the launch path, unread.** `GET /children` returns `avatar_key` —
verified live:

```json
{ "id": "9e41dc78-…", "name": "Preflight Kid", "pronouns": null,
  "avatar_key": "children/9e41dc78-…/avatar/fbf628db-….jpg",
  "family_timezone": "America/Denver", "role": "parent", "age_months": 64 }
```

`ChildResponse` (`RascalAPI.swift:68`) simply declares no `avatarKey` property, so the field is
decoded and discarded. Adding it is one line and costs no request — the gate already holds the
whole `ChildResponse` and already passes pieces of it down to `RootView`.

### F4 — Phase 20 is merged, so the `ChildSetupFlow.swift` collision is not live

The brief says this phase and phase 20 must not run concurrently because both edit
`ChildSetupFlow.swift`.

`ios/phase-20-pronouns` merged to `main` as **PR #52** (`efd3238`), which is what this branch is
cut from — so phase 20's `ChildSetupFlow.swift` edits are already in the base. `gh pr list` shows
no open PRs. There is no concurrent run. Its worktree at `../Project-Rascal-pronouns` is clean
and matches origin.

**A note on where this branch lives.** The primary checkout is mid-merge on `tmp/conflict-probe`
(conflicts in `docs/decisions-log.md` and `docs/roadmap-status.md`) with a large staged diff
across both lanes. Rather than disturb it, this phase runs in a **worktree** at
`../Project-Rascal-avatar`, the same arrangement phase 20 used. The conflict probe is untouched.
`ios/Rascal/Config.xcconfig` is gitignored and was copied in, matching the pronouns worktree.
