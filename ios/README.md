# RASCAL — iOS

The client for the archive. SwiftUI, SwiftData, URLSession, and nothing else — no SPM packages,
no CocoaPods, no vendored source.

The rules that govern this lane are in [`ios/CLAUDE.md`](CLAUDE.md); the design system is
[`docs/design-system.md`](../docs/design-system.md) and it is the authority for writing SwiftUI;
the wire format is [`docs/api-contract.md`](../docs/api-contract.md). Read those before this.

## Running it

```bash
cp ios/Rascal/Config.xcconfig.example ios/Rascal/Config.xcconfig   # gitignored; set API_HOST
make up && make migrate && make seed && make dev                   # from the repo root
open ios/Rascal/Rascal.xcodeproj
```

`Config.xcconfig` must sit beside `Rascal.xcodeproj`. Point `API_HOST` at `localhost:8000` for a
simulator or at your Mac's LAN address for a device, and run the API with `--host 0.0.0.0` for
the latter. Values reach Swift through `Info.plist`; there is no base URL or UUID in source.

**Sign the simulator build.** Building with `CODE_SIGNING_ALLOWED=NO` produces an app that cannot
write to the keychain, so every request after sign-in comes back `401` and the app reports that
the account has no child. That is a build-flag artifact, not a bug — CI passes the flag because it
only runs tests, which never touch the keychain.

## Screens

| Screen | Where | What it does |
|---|---|---|
| **Today** | `Today/` | The board: today's assignments, what's waiting, what's done. Server-computed in the child's `family_timezone`. |
| **Timeline** | `Timeline/` | The archive, grouped by the day it happened, filtered by entry type, paged on scroll. The magnifier in the header swaps the filter row for a search field over `GET /entries?q=` — same cards, same day headers, its own cursor. |
| **Entry detail** | `Timeline/EntryDetailScreen.swift` | One entry in full: media, the prompt that caused it, transcripts, metadata. Edit routes into the composer; delete is a soft delete. |
| **Moments** | `Moments/` | This day in prior years, or a warm redirect when there is nothing. |
| **Composer** | `Composer/` | Writing and capture, including backdating and edit mode. |
| **Settings** | `Settings/` | Who the archive is for, which account holds it, the app version, and the way out. |
| **Share sheet** | `RascalShare/`, `Rascal/Share/` | Capture from Photos without opening the app. A separate target: it copies bytes and a versioned record into the App Group and exits, and `ShareDrain` files them on the app's next launch or foreground. See below. |

## Three targets, and what each is allowed to do

| Target | Networking | Reads the App Group | Writes the App Group |
|---|---|---|---|
| `Rascal` | Yes — it is the only one that holds a credential | Yes | Yes |
| `RascalWidget` | **Never** | `today.json` | Never |
| `RascalShare` | **Never** | Never | `share-inbox/` |

**No extension in this project makes a network request, and that is a rule rather than a
coincidence.** A token refresh running inside an extension, concurrently with the app, can
invalidate the app's own session — intermittently, and very hard to attribute. A share extension
has two further reasons: a hard memory ceiling that a 4K video exceeds, and the standing rule that
an entry is confirmed server-side before its media upload is attempted. See `docs/decisions.md`.

`Palette`, `Typography`, `Layout`, `Motion`, `Formatting`, `ImagePipeline` and everything in
`Rascal/Share/` are compiled into more than one target through explicit membership in the project's
`Shared` group. They compile into the app anyway through its synchronized `Rascal/` group, so
nothing is built twice into one binary. **A file added there has to compile under
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in every target that takes it**, which is why the
extension targets copy the app's Swift settings rather than using the template's.

## Patterns worth knowing before you change anything

**The server is the source of truth; SwiftData is a cache.** Nothing on device computes what was
assigned, whether something expired, what day it is, what `entry_type` an entry has, or how old
the child was. Those are all server answers that the client renders.

**Local-over-server, everywhere.** `EntryCache.upsert` folds server rows into the cache under one
rule: the server owns everything *except what the parent just did*. A row written here and not yet
pushed is newer than anything the server can say about it, so a reconcile leaves it alone until
`EntrySync` lands it. `TodayBoard.merge` is the same rule applied to the Today screen.

**Identity is client-generated.** Entry and media ids are minted on the phone before any request,
so a row saved offline and the same row fetched back are one row and never two.

**`occurred_at` and `created_at` are never conflated.** The timeline sorts and groups by
`occurred_at`; sync filters on `updated_at`. A photo from 2019 imported tonight appears in 2019.
`TimelineGrouping` cuts days with `Calendar.startOfDay` rather than arithmetic on seconds, because
a day is 23 hours long twice a year in most of the world.

**Deletions only ever go one way.** `EntryCache.markDeleted` marks the entry and its media and
removes neither; `EntrySync` carries the `DELETE` and retries it on the next foreground. A
response that still shows a deleted row is a response that predates the delete, and nothing may
bring it back.

**No N+1, ever.** `GET /entries` inlines media summaries. The timeline runs one `@Query` for
entries and one for media, groups them once per render, and never fetches per card.
`TimelineScaleTests` builds a 500-entry fixture and fails if that stops being true.

**Paging is seeded from the cache, then carried by the cursor.** Both halves are load bearing.
A remembered page-one cursor cannot *start* — it asks for page two of a cache fifteen pages deep,
which is rows you already have, so no new card appears and nothing triggers again. `before` alone
cannot *continue* — it is exclusive and compares only `occurred_at`, so a page landing entirely
inside the overlap window returns nothing new and the floor never moves, which is what a bulk
import of photos with no EXIF date looks like. So the first request of a run asks for everything
older than the oldest row on screen, and every request after it follows `next_cursor`. The second
of overlap on the seed is deliberate: overlap rather than skip, upsert by id.

**A transcript is a pending local change until it is pushed.** Transcription writes the words to
the `Media` row first and pushes them to `PATCH /media/{id}/derived` second, so a crash between the
two loses nothing and the retry is idempotent. Until that push lands the row is the *only* copy in
existence, so `Media.applyServerSummary` refuses to overwrite it — that is where the guard lives,
because all three pull paths funnel through it and `syncPullEnabled` still ships false. `failed`
counts as pending here and deliberately does not on the upload path: bytes past the cap are safe in
storage, words past the cap are not anywhere else.

**The model may simply not be there, and that is not an error.** `SpeechAnalyzer` is iOS 26 and
this app deploys to 18.6. Every entry point checks availability first and a device that cannot
transcribe produces an app identical to the one before the feature existed — no banner, no
placeholder, no empty Transcript heading. Nothing in the suite exercises the real analyzer; the
protocol in `Media/Transcription.swift` is the only abstraction this feature adds, and it exists
because CI has neither iOS 26 nor the model assets.

**Thumbnails are the client's problem.** `thumb_key` is null on every media row — that pipeline
was cut from P0 — so `ThumbnailStore` fetches the original once through the presigned read URL,
downsamples to 400px with ImageIO without ever decoding the full image, and writes the result
beside the composer's own staged thumbnails so there is one cache rather than two. Video is never
downloaded for a poster frame and audio has no thumbnail by design.

**Never store a presigned URL.** It outlives its signature and then fails in a way that reads like
the archive lost the file. Cache the bytes; refetch the URL.

**Nothing assumes an entry has media.** Written and did-it entries are complete entries and render
with no thumbnail slot at all — not an empty frame, not a grey square, not a gap.

**A picture at `scaledToFill` must never be a stack child.** It is deliberately larger than its
frame, and a `ZStack` sizes itself to its children — so the photo decides the layout and bleeds
past the inset the design system asks for. Use `.overlay`, which does not participate in layout.
This only shows on media that is not 4:3, which is to say most photographs.

**Absence is information, but only where the response is complete.** Every response carrying an
entry carries all of its live media, so a cached media row missing from that list was deleted
elsewhere and is marked. Entries are different — `GET /entries` is paginated, so an entry absent
from a page might just be on another one. An entry deleted on another device is only discovered
when it is opened and `GET /entries/{id}` answers 404. The general case needs `/sync`.

## Adding a property to an `@Model`

Give it a default **at the declaration** (`var count: Int = 0`) or make it optional. Migration
rewrites rows that already exist and never calls `init`, so a mandatory attribute it cannot infer
means the store refuses to open and the app crashes on every launch with no way back in.

Nothing in the suite or CI catches this: every test uses `isStoredInMemoryOnly: true`, and a
simulator run after a fresh install also starts from nothing. **Upgrade a build in place before
shipping one** — `xcrun simctl install` over the existing app, without uninstalling — and check
that `Library/Application Support/` has no `unreadable-store-*` folder afterwards.

## Tests

```bash
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=$(xcrun simctl list devices available | grep -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | tail -1 | grep -oE '[0-9A-F-]{36}')" \
  CODE_SIGNING_ALLOWED=NO
```

CI runs the same command and then fails the build on **any** warning in `ios/Rascal/Rascal`,
`ios/Rascal/RascalTests`, `ios/Rascal/RascalWidget` or `ios/Rascal/RascalShare`. Warnings are errors
here; do not merge red. **A new target means a new branch in that alternation** — the pattern
requires a `/` immediately after the branch, so a directory that is not named is not covered by the
branch it happens to share a prefix with. `RascalWidget/` shipped ungated for exactly as long as it
took to notice.

**Run it from a deleted `DerivedData` before believing a warning count.** An incremental build does
not recompile an unchanged file, and a file that is not recompiled emits no warning. A phase once
saw 21 warnings in a full run that a targeted `-only-testing` run had reported as zero.

Nothing in `RascalShare/` is reachable from the test target: it is its own module and the test host
is the app. That is why everything the share sheet's correctness rests on — the record, the
container, the date rule, and every sentence it says — lives in `Rascal/Share/` instead, and why
`RascalShare-Info.plist` is a **resource of the test bundle** so the shipped activation rule can be
asserted rather than a second copy of the claim.

`RascalTests/TimelineFixtures.swift` holds server-shaped JSON builders mirroring
`api/src/rascal/schemas/entry.py`. If the two disagree, that file is right and the fixture is the
bug — regenerate real captures with `make fixtures` from the repo root.
