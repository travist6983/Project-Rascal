# RASCAL iOS — Lane B, Phase 2 (Capture) report

**Aug 8, 2026.** Branch `ios/phase2-capture-build`, on top of the merged `main`.
Nothing under `api/` was touched in this phase; the one API change this phase needed —
`presign_get` — landed separately in PR #11 before C-1, exactly because it changed C-1's
design rather than adding to it.

**C-1 through C-5 shipped and green. C-6 (audio) dropped**, per your instruction to prefer the
device pass this week. `ios/device-session.md` is written and waiting.

**57 iOS tests in 6 suites, 277 API tests, zero warnings of mine.**

---

## What shipped

### C-1 — Staging store

Files are copied into `Application Support/staging` the moment they are picked, before the
entry exists. The staged path is derivable from `media_id` + extension, both on the row, so the
uploader reconstructs its work from disk alone after a cold launch.

A copy rather than a move: PHPicker may still own the source, and moving it out from under
PhotoKit is not ours to do.

`StagingSweeper` is the one place that arbitrates between the filesystem and SwiftData, rather
than that logic living in both the uploader and the composer. The rule is yours: **`complete`
AND a thumbnail, never a timer.** Also handles orphan files, media of deleted entries, and
complete rows whose local copies are gone — the last flagged for refetch rather than treated as
lost, which is only defensible because `presign_get` exists.

One judgement call: an **unrecognised filename** in the staging directory is left alone rather
than deleted. The directory is the app's, but guessing at a name we don't recognise is how real
data dies.

### C-2 — Image pipeline

HEIC → JPEG at 0.85, orientation baked into the pixels with no residual tag, EXIF
`DateTimeOriginal` carried through, original dimensions preserved, local thumbnail cached.

The orientation work is the part that can't be undone later, so it's asserted on dimensions and
pixel content rather than on metadata. A tag left on top of a baked rotation double-rotates in
viewers that honour both — that's how a photo ends up upside down in a way nobody notices until
the archive is large.

EXIF timestamps carry **no timezone**. They're read as wall-clock time in the current zone.
Treating them as UTC would shift every backfilled photo by hours and land some on the wrong day.

### C-3 — Background upload

Background `URLSession`, file-based tasks, one session/identifier/delegate per process,
`handleEventsForBackgroundURLSession` forwarded through an `AppDelegate` that exists for that
single method.

The delegate makes its own `ModelContext` from `LocalStore.shared` **as its first act**. That
required promoting the container to a process-wide singleton — a Phase 1 change, made
deliberately: two containers over one store file is a data-corruption bug, not a lifecycle
inconvenience.

Backoff is exponential, capped, **jittered**, and lives on the row as `nextAttemptAt` so it
survives relaunch. The sweep is ordered by **due time, not age**.

### C-4 — Composer: captured it

PhotosPicker and camera through one builder, so the two paths cannot produce different JPEGs.
Preview in a white inset frame, `+N` past four, remove before saving. Save returns immediately;
media rows are created alongside the entry before any request.

### C-5 — One sweep

`EntrySync` owns it. Entries drain, then media. One count on Today covering both, one **Try
now**, no badge and no red dot.

---

## What the first real uploads revealed that `moto` could not

**The ETag is not required, and the prompt says it is.**

> *"On a 200, read the `ETag` response header and pass it to `POST /media/{id}/complete`. It is
> required, and a missing one fails completion in a way that reads like a signature error."*

True for multipart, false here. `complete_upload` only requires `etags` when `s3_upload_id` is
set; the single-PUT path ignores them entirely. My preflight curl proved it accidentally — it
sent `{"etag": …}`, an unrecognised field, and returned 200.

Had I built completion to depend on the ETag, an upload whose header was absent would never
complete and would retry forever — the exact failure the sentence warns about, inverted. The
ETag is captured and stored (integrity value now, mechanism multipart needs) but nothing gates
on it. **`moto` would never have surfaced this**, because the question is what the *server*
requires, not what storage returns.

**Tigris returns the ETag with no CORS configuration at all**, confirming CORS is
browser-enforced and irrelevant to `URLSession`. `blocked.md` §2 previously described it as a
client blocker; it isn't, and that's now corrected there.

**The full read path round-trips byte-identically** — PUT, complete, `GET /url`, fetch, `cmp`.
That is the assertion `moto` structurally cannot make, since it never stores real bytes at a
real endpoint.

## Did `chunk_bytes` match expectations?

**It is `null` on the single-PUT path, with `multipart: false`** — consistent, since it's the
multipart part size and there are no parts. It is read and stored on the row and never
consulted. Treating null as an error would have broken every photo upload in this phase; the
multipart phase will be the first thing to read it, and it will read the server's number rather
than assuming 8MB.

## Background session on device

**Unknown — not yet run.** Everything above is simulator and unit-test evidence. `device-session.md`
lists what to check and, more importantly, what a *silent* failure would look like: the
cold-launch-into-callback case completes the upload either way, and the tell is whether the
count is clear on arrival or clears a moment after you look at it. I'd rather name that than
report "works" from a simulator that cannot produce it.

---

## What I'm not sure about

**1. `isDiscretionary = false` is a product decision I made by default.** Uploads go promptly
rather than waiting for Wi-Fi and power, on the reasoning that a parent expects the photo to be
safe now. On cellular with five photos that is a real battery and data cost. One line to change,
and step 5 of the device session is where you'd notice.

**2. The `+N` overflow threshold is four.** Not in the design system, which specifies the tile
but not the count. Four fits a phone width at 84pt without faces becoming unrecognisable.

**3. Serial import, not parallel.** Peak memory stays at one decoded image. A five-photo import
is a few seconds either way; an eight-photo parallel import of 48MP HEICs is how a composer gets
killed mid-selection. If picking feels slow on device, concurrency with a small limit is the fix —
never a batch endpoint, which would be a schema change.

**4. The earliest EXIF date wins across a selection**, not the latest, not now. Three photos from
one afternoon file on that afternoon. Not specified anywhere; it's the reading that makes
backfill behave.

**5. Video cards still render and open**, and the composer says video arrives next phase while
offering photos and text. The alternative — hiding them — would make Today lie about what the
scheduler served. But it does mean a `video` mission cannot be completed as asked this phase.

**6. `MediaCoordinator.shared` is a static var — deliberately, and it stays.** I flagged this as
the weakest seam and it is, but the constraint is real rather than a shortcut, so the reason is
now recorded at the declaration too.

A background `URLSession` delegate is invoked by the system on a callback path the app does not
construct, so there is no injection point. Worse, the system may create the **process itself**
purely to deliver those callbacks after a force quit — `RascalApp`, `RootView`, and everything
they would have passed down do not exist yet when the delegate runs. There is nothing to inject
*from*. Something has to be reachable without an owner.

Two things follow, and both are written at the declaration so nobody has to re-derive them:
**there must be exactly one** (two coordinators means two sweeps racing the same rows and two
`complete` calls for one upload — the same constraint as the uploader's single-session rule,
seen from the other end), and **the obvious alternative is worse**: the delegate could write a
"needs completing" marker and let the next foreground sweep make the call, which trades the
global for a delay before the server learns the object landed. That is worse for the parent, so
it was not taken.

**7. Untested: two devices uploading for the same child concurrently.** Idempotency keys make
entry creation safe, and media ids are client-generated, so I believe it's fine — but "I believe"
is doing work there, and `GET /sync` is a later phase anyway.

---

## Shortest path to video and multipart

The pieces are placed; multipart is the only genuinely new machinery.

1. **`chunk_bytes` is already stored.** Read it, split the file at exactly that size. The server
   computed its part count from that number, so guessing produces the wrong count.
2. **`parts` in the upload-url response** carries a presigned URL per part. `Media` needs a
   child `MediaPart` row per part — number, URL, ETag, state — because part-level progress must
   survive a force quit exactly as file-level progress does now.
3. **This is where the ETag becomes mandatory.** `complete` requires `etags` for every part when
   `s3_upload_id` is set. The header capture already works; what's new is collecting them across
   parts and ordering them by part number.
4. **Video needs a `videoQuality`/export decision first.** A 4K minute is ~350MB, and transcode
   policy is explicitly an open decision. That's a product call before it's an engineering one.
5. **`AVAsset` for duration and a poster frame**, passed to `complete` as `duration_seconds`.

The ordering that matters: **multipart against a large photo first, before video.** It isolates
the part-splitting and ETag-collection machinery from the capture and transcode questions, and
lets it be tested against something the simulator can produce.

One thing to verify early rather than late: **Tigris multipart parity.** Presigned single PUT
works and is proven. Multipart is a different API surface, and a difference there would be
expensive to discover after the client machinery exists. A `curl`-level multipart round trip
against the real bucket is an hour, and it's the same lesson as the ETag — assume nothing about
what the server requires until it has said so.
