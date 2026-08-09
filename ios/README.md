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
| **Timeline** | `Timeline/` | The archive, grouped by the day it happened, filtered by entry type, paged on scroll. |
| **Entry detail** | `Timeline/EntryDetailScreen.swift` | One entry in full: media, the prompt that caused it, transcripts, metadata. Edit routes into the composer; delete is a soft delete. |
| **Moments** | `Moments/` | This day in prior years, or a warm redirect when there is nothing. |
| **Composer** | `Composer/` | Writing and capture, including backdating and edit mode. |
| **Settings** | `Settings/` | Who the archive is for, which account holds it, the app version, and the way out. |

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

CI runs the same command and then fails the build on **any** warning in `ios/Rascal/Rascal` or
`ios/Rascal/RascalTests`. Warnings are errors here; do not merge red.

`RascalTests/TimelineFixtures.swift` holds server-shaped JSON builders mirroring
`api/src/rascal/schemas/entry.py`. If the two disagree, that file is right and the fixture is the
bug — regenerate real captures with `make fixtures` from the repo root.
