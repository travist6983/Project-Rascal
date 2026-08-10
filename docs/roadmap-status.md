# RASCAL — where we are against the roadmap
Snapshot: **Aug 10, 2026**, written as the widget went up for review. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the app's own `openapi()`, the prompts table, `gh pr list` — rather than by reading a commit message. **Every number below was re-derived for this snapshot rather than edited.**

* * *
## The headline
**P0's scope list is complete, P3's headline feature is built, and P1's retention lever now exists.** On-device transcription merged as PR #26. Moments v2 merged as #30. **One pull request is outstanding — the widget, #32.** Every other branch that has ever been opened is merged into `main`.

**The widget is the first extension target this project has had**, and it is deliberately the dumbest thing that could work: the app writes a few hundred bytes into a shared App Group container whenever the Today board changes, and the extension renders that file. No networking, no keychain, nothing to refresh. The cost is staleness, which is why the largest single piece of the phase is refusing to draw a snapshot whose day is not today in the child's `family_timezone`. See `docs/reports/phase-11-widget.md`.

**Moments got its design pass, and the phase was mostly about a state the design could not have anticipated.** The archive is six days old, so `fallback: "random"` is what the screen returns on every date and will be for a year. The redirect was therefore built and tested as the primary state rather than the edge — same carousel, same section header, same cards, one eyebrow and one italic line different. See `docs/reports/phase-10-moments.md`.

**Two things ship switched off or unverified, and they are different kinds of unverified.**

- `syncPullEnabled` still defaults to false and gates every write the pull performs. Verified against fixtures — including a 736-entry one — and **never against the real archive**. The morning sequence is unchanged: Settings → dry run → read the report → flip the flag → pull to refresh.
- Transcription is **structurally verified and empirically unverified**. `SpeechAnalyzer` is iOS 26 and the app deploys to 18.6; `isAvailable` is false on every simulator and the model assets are a download no CI runner has. Everything below the protocol seam is asserted against a stub. **No real transcription has ever run**, so the one thing that matters most — how well it reads a four-year-old — is unknown rather than good. `docs/device-verification-transcription.md` is the way to find out.

**The scope gap that no phase ever owned is closed.** Sealed letters can now be written as well as read — see "The sealed letter, whole" below. What is left of it is a four-line server change, not a feature.

What is left is then the two things only you can unblock — Apple enrollment and Fly — and the exit test, which is you using it for fourteen days.

|     |     |
| --- | --- |
| Merged pull requests | **30** — Moments v2 (#30) merged since the last snapshot. The widget is **open as #32** at this snapshot |
| API tests | **302 passing**, 23 files — unchanged this phase, no `api/` code was touched |
| iOS tests | **490 passing**, 50 suites, zero warnings (verified from a deleted `DerivedData`) |
| Live API operations | 32 across 26 paths (incl. `/health`, `dev-login`, and 3 local-only debug routes) |
| Prompt library | **113 authored, 113 active** — nothing held back |
| Prompt candidates awaiting your review | **79** |
| Entries in the dev archive | 755 |

Every figure above was re-measured for this snapshot. **The pull-request and iOS-test counts moved** — the previous snapshot was written before Moments v2 merged and before the widget existed; the API figures did not, because no `api/` code has been touched since PR #20. The iOS suite was run cold, from a deleted `DerivedData`, and the sole warning in the log is `Metadata extraction skipped. No AppIntents.framework dependency found.`, which is a build note and not a warning in any of our code.

An earlier snapshot claimed 275 iOS tests in 34 suites and 26 API test files. All three were wrong; they were corrected last time and have held.

* * *
## Phases at a glance
| Phase | Roadmap window | Status |
| --- | --- | --- |
| **P0 — POC** | Aug 3–14 | **Scope complete, client sync built but unverified on device.** TestFlight blocked; exit test not started. Onboarding shipped |
| **P1 — Daily driver** | Aug 17 – Sep 11 | **Partly pre-banked** — search now has a client surface, plus moments, backups, transcode policy all done early |
| **P2 — Family** | Sep 14 – Oct 9 | Not started. Authorization and the `guardians` table are built and tested; only the invite flow is missing |
| **P3 — Intelligence** | Oct 12 – Nov 6 | **Item 1 built, unverified on device.** Transcription runs, persists, and survives sync. Items 2–5 not started |
| **P4 — The artifact** | Nov 9 – Dec 18 | Not started. Full archive export ships already, which is the hard half |
| **P5 — Public** | 2027 | Not started, conditional |

* * *
## P0, item by item
Against the roadmap's own **In scope** list in §3.

| Roadmap item | Status | Where |
| --- | --- | --- |
| Single parent account, single child | ✅   | Apple + dev-login, `guardians` with roles |
| ~60 hand-authored prompts across all types | ✅ **113** | `docs/mission-library.md` → `seeds/prompts.yaml` |
| Server-side daily scheduler, 1 question + 1 mission, weekly Saturday | ✅   | Runs hourly, filters on each child's local hour |
| Stacking inbox, expiry at 14 days | ✅   | `waiting` section on Today, server-side expiry |
| Composer: **text** | ✅   |     |
| Composer: **photo** | ✅   | HEIC→JPEG, EXIF orientation baked, EXIF date → `occurred_at` |
| Composer: **video** | ✅   | 1080p H.264/MP4, multipart upload, original preserved to the roll |
| Composer: **audio** | ✅ **new** | AAC/m4a 44.1 kHz mono 96 kbps, single PUT, `duration_seconds` read off the finished asset |
| Backdating | ✅   | First-class; `occurred_at` never conflated with `created_at` |
| Auto-computed child age | ✅   | Server-computed and stored, with an explicit recompute escape hatch |
| Timeline: reverse-chron, year dividers, type filter | ✅   | PR #19 |
| "On this day" | ✅   | Moments, incl. the warm random fallback — re-skinned against its own design in #30, with the fallback built as the primary state |
| TestFlight to yourself | ❌ **blocked** | Apple Developer enrollment — `blocked.md` §1 |
### The build-order item that was outstanding — now built
**Days 3–4 called for a sync engine: "pull-since-**`updated_at`**, push queue".** The push queue was already solid. **The pull now exists**, in `ios/Rascal/Rascal/Sync/`, and all three documented defects have a test that fails without it:

- ✅ An entry deleted on another device now disappears here, arriving as a row with `deleted_at` set. It does not resurrect on a later pull that no longer mentions it.
  
- ✅ `POST /children/{id}/recompute-ages` now reaches the whole archive. Tested against a 130-entry fixture spanning three pages — the oldest row, which no page-one refetch would ever have reached, is asserted by name.
  
- ✅ Media deleted elsewhere still leaves through the entry's live media list, and entries now have their own path. Both are tested; the old one was not broken to add the new one.
  

**The caveat that matters.** All of that is verified against fixtures. The flag is off, so none of it has run against the 736 real entries in the dev archive. The dry run exists precisely so that can be inspected before the flag moves.

Single-device, single-parent, none of this bites. **It becomes correctness-critical the moment P2 puts a second parent on the same child.**

* * *
## The iOS build, phase by phase
The client was built in numbered phases that are **not** the roadmap's phases, and the two numbering schemes have been confused more than once. This is the ledger, checked against `gh pr list` and against the files on `main`.

| Phase | What it was | PR | State |
| --- | --- | --- | --- |
| **1 — Spine** | Design system, networking with single-flight refresh, SwiftData models, app shell, Today, composer (wrote-it + did-it) | #10 | ✅ merged |
| **2 — Capture** | Staging store, HEIC→JPEG, background uploader, photo entries | #11, #12 | ✅ merged |
| **2.5 — Device polish** | Local-state-first Today, upload progress ring, completion motion, Done cards tappable and tinted | #13 | ✅ merged |
| **3 — Media read path** | Presigned GET, thumbnails render | #11 | ✅ merged |
| **3 (the other one) — Video** | Video capture, multipart upload, and the slowness it caused | #18 | ✅ merged |
| **4 — Archive** | Timeline, Entry Detail, Moments | #19 | ✅ merged; Timeline re-skinned by #25, Moments by #30 |
| **5 — Audio** | `AVAudioRecorder`, AAC/m4a, audio back on the debug board | #22, #23 | ✅ merged |
| **6 — Sync pull** | Built, tested, dry-run mode, shipped with `syncPullEnabled` **off** | #24 | ✅ merged, flag off |
| **7 — Transcription** | On-device `SpeechAnalyzer` + the search surface on Timeline | #26 | ✅ merged |
| **Settings rebuild** | Editable child, display name, export, sync status | #20 (API), #21 (client) | ✅ merged |
| **8 — Onboarding** | Onboarding + account creation, `OnboardingGate` owning session state | #27 | ✅ merged, **with red CI** — see below |
| **9 — The seal control** | The composer's half of `unlock_at_age`: shown for `letter` prompts, sealed by default, age from the prompt | #29 | ✅ merged |
| **10 — Moments v2** | The Moments tab re-skinned against its own design export. The redirect built as the primary state, not the edge | #30 | ✅ merged |
| **11 — The widget** | The WidgetKit extension target, and Today's mission and question on the Home Screen and Lock Screen. Reads a snapshot the app writes; no networking in the extension | #32 | **open at this snapshot** |

**Two numbering hazards worth naming, because both have already caused a wrong assumption.**

- **"Phase 3" means two different things.** In the iOS build order it is the media *read* path, which landed inside PR #11. PR #18 is *titled* "Phase 3" and is video *capture*. Both shipped; only the label is ambiguous.
- **The onboarding branch was misnamed and landed that way.** `ios/phase-5-onboarding` was the working branch for phase **8**; phase 5 was audio, three PRs earlier. It merged under the wrong name, so the history does now read as though audio were reopened. Nothing to undo — just do not trust the branch name in `git log`.

### Phase 8, precisely
Merged as **PR #27**. What shipped: **welcome → Sign in with Apple → name → birthdate → timezone → avatar → Today**, gated by an `OnboardingGate` that owns session state and hands the resolved child down to `RootView`. A returning account skips setup entirely. Two decisions worth not relitigating: the birthdate is carried as a `yyyy-MM-dd` **string** end to end so it cannot drift a day west of Greenwich, and `display_name` is **omitted rather than nulled** when Apple declines to supply one, because Apple returns `fullName` only on the first-ever authorization for an Apple ID and the server applies first-write-wins.

**It merged with red CI, and that is the thing to know.** Two transcription cancellation tests ordered a race against a wall clock — `sleep(60ms)`, then assume the run is under way — and broke under the extra parallelism the onboarding suites added. The follow-up PR fixes that and five production defects found afterwards in the merged code: `RootView` re-resolving session state (which could show a production parent "the API is not running with ENVIRONMENT=local"), a sign-out that landed on a screen offering only `dev-login`, a second sign-out in one launch silently doing nothing, no way out of setup after signing in with the wrong Apple ID, and `AvatarCrop` decoding a full-resolution photo to produce 512 pixels. `docs/reports/phase-5-onboarding.md` is the full account.

**Still unverifiable, and not by omission:** Sign in with Apple has never executed — not on a device, not once — because enrollment has not cleared (`blocked.md` §1). Everything below the credential seam is tested; the real `ASAuthorization` path is not. Separately, the avatar is captured, cropped and stored **on the device only** — there is no endpoint to upload it to, and nothing in the app renders it yet.

* * *
## The sealed letter, whole

**Closed Aug 10.** `unlock_at_age` was in the schema, the design system and the mission library,
and **8 active `letter` prompts were being served** against a client with no way to set it. Phase 4
built the reader — `EntryDetailScreen.sealedCard`, the `EntryCard` sealed skin, the Sealed filter,
five test files — and no phase owned the writer, because the roadmap's P0 **In scope** list names
the composer as "text, photo, video, audio" and never names sealing.

The writer is one control in `ComposerView`, shown when the assignment's `PromptKind` is `.letter`:
sealed by default, an age stepper over 10–21 defaulting to the prompt's own `default_unlock_age`,
and a toggle to turn it off. Verified end to end against the local API — a real letter assignment
(`default_unlock_age` 13) written through the client's create path came back and rendered on the
timeline as a wash-skinned card reading "Opens at 13." with no preview.

**One gap remains, and it is Lane A's.** `POST /entries` seals a letter whenever `unlock_at_age`
arrives as `None`, and Pydantic cannot tell an omitted key from an explicit `null` — so turning
sealing *off* cannot be expressed on create. The client sends an explicit null regardless and
follows it with a `PATCH`, which *can* distinguish them because it dumps with `exclude_unset`. See
`docs/blocked.md`; the fix is four lines and it deletes the workaround.

Still absent by choice: **editing the seal on an entry that already exists.** `PATCH` supports it,
no UI calls it.

* * *
## What P1 has already banked
Work that landed early, mostly as a side effect of doing P0 properly. Worth knowing so P1 is not re-scoped from scratch.

| P1 item | Status |
| --- | --- |
| Full-text search over titles and bodies | ✅ **both halves now** — `GET /entries?q=` weighted, stemmed, keyset-paginated, and a client surface on Timeline: a magnifier in the header, a debounced field, results as ordinary `EntryCard`s. Deliberately minimal — no filters-with-search, no history, no highlighting |
| Random memory resurfacing | ✅ Moments' fallback branch does exactly this |
| Backups you actually trust | ⚠️ nightly dump workflow + `test_restore.py` in CI. **A real restore drill has never been performed** |
| Prompt library to ~200 | ⚠️ 113 authored, **79 candidates generated and waiting on your read** |
| Transcode policy (a P1 _risk_, not an item) | ✅ settled in P0 — 1080p H.264/AAC video, AAC/m4a audio, originals preserved |
| Full export before you need it (a standing risk, "P2 at the latest") | ✅ shipped in P0 — zip with manifest, entries, and media |
| Home Screen / Lock Screen widget | ✅ **built** — five families, five states, deep-linking into the composer. Reads a snapshot from a shared App Group container and never calls the API. **Never run by WidgetKit on a device**, which is where refresh budget and file protection are decided — `docs/device-verification-widget.md` |
| Push notifications | ❌   |
| Share sheet target | ❌   |
| **A name** (open decision #3, needed by P1) | ❌ still `RASCAL`, bundle id deliberately neutral |

* * *
## Blocked on you, not on code
These gate the P0 exit test and nothing else can move them.

1. **Apple Developer enrollment** — blocks real Sign in with Apple and TestFlight. Everything else is built and tested against a local RSA keypair. `blocked.md` §1.
  
2. **Fly** — no deployed API exists. `rascal-api.fly.dev` does not resolve and every Deploy run has skipped, waiting on `FLY_API_TOKEN` and `FLY_DEPLOY_ENABLED`. `blocked.md` §3.
  
3. **79 prompt candidates** need a human read before they can join the library.
  
4. **A restore drill** — the machinery is tested, the act never performed.
  
5. **Device verification.** Five checklists are now outstanding: `docs/device-verification-widget.md` from PR #32, `docs/device-verification-transcription.md` from PR #26, the audio list in PR #22, `docs/device-verification-settings.md` from PR #21, and `docs/device-verification-moments.md` from PR #30. The transcription one matters most and the audio one is its prerequisite — the simulator has no microphone and no speech model, so **neither recording nor transcription has ever run against anything real.** The Moments one is cheapest and has the sharpest single question in it: a sealed letter is surfaced by that screen at random, and only a device can show you what is actually on the glass.
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
> **This section has gone stale twice**, and both times the same way: it went on recommending something the document already reported as built, a couple of sections above itself. Re-derived again below from what is actually outstanding, and the widget entry has been removed because the widget now exists.
>
> If you are editing this file after landing a branch, this section is the part to rewrite, not the part to leave.

### Verify what is built before building more
**Nothing here is a coding task, and that is the point.** Three features have now shipped that have never run against reality: sync pull has never touched the 755 real entries, the recording path has never met a real microphone, and transcription has never produced a single word. Each is a checklist that takes an evening, and each one can invalidate a design rather than just find a bug.

**The list has grown by one, and the new one is now the top of it.** In the order they cost you least to discover something in:

1. `docs/device-verification-widget.md` — new, and it has displaced transcription at the top for a structural reason rather than an urgency one. Four things the widget depends on **cannot be observed in a simulator at all**: the refresh budget, file protection on the Lock Screen, the monochrome accessory render, and whether the App Group even resolves on a device. It is also the shortest of the five to run.
2. `docs/device-verification-transcription.md` — the one with the most unknown in it.
3. The audio checklist from PR #22 — the simulator has no microphone, so **nothing in the recording path has run against real input.**
4. `docs/device-verification-settings.md` from PR #21.
5. The sync-pull sequence: dry run, read the report, then flip the flag.
6. `docs/device-verification-moments.md` from PR #30 — the cheapest, and the one with the sharpest single question: a sealed letter is surfaced by that screen at random, and only a device shows you what is actually on the glass.

### Then, in build terms
- **Phase 8, onboarding and account creation** — shipped. The app now has a first-run path for a person who is not you, though Sign in with Apple itself still cannot be exercised until enrollment clears.
  
- ~~**The seal control in the composer**~~ — **shipped**, as PR #29. See "The sealed letter, whole" above; what remains of it is a four-line server change in `blocked.md`, not a feature.
  
- ~~**The widget**~~ — **built**, as PR #32, and with it the project's first extension target and its first deep-link handling. The roadmap calls it the reason the loop survives week four; whether it actually does cannot be known from a simulator, which is why its checklist is first on the list above.

- **The remaining P1 retention levers are push notifications and the share sheet target**, and they are now the largest unbuilt things. Push is blocked in the same place TestFlight is — it needs the Apple enrollment that `blocked.md` has been waiting on. The share sheet target is not blocked on anything, and the extension target created this phase is the pattern for it.

- **A name.** Open decision #1, and the widget has just made it slightly more expensive to defer: the widget gallery groups by app name, so whatever the app is called is what a parent reads when they add it. The bundle id and the URL scheme are both deliberately name-neutral, so this is still a rename and not a migration — but it is now visible in one more place.
  
- **P3 item 2, structured extraction** (`@Generable` over the transcripts that now exist). Deliberately not done in this phase — it is a separate feature with its own schema question, and stacking it on an unverified transcriber would mean two unknowns in one branch.
  
- **Video audio tracks**, the one piece of this phase that was cut. Gated on the audio path being verified on a device first — see `docs/decisions.md`.
  

* * *
## Facts, if you want to check any of this
```bash
make test                                    # 302 API tests
ls api/tests/test_*.py | wc -l               # 23 files

# Delete DerivedData first or the warning count is a lie: an incremental build does not
# recompile an unchanged file, and a file that is not recompiled emits no warning. This is
# not theoretical — this phase's first full run surfaced 21 warnings that a targeted
# `-only-testing` run had reported as zero.
rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 490 iOS tests, 50 suites, zero warnings

# Routes, without needing the API to be running.
cd api && ENVIRONMENT=local uv run python -c "
from rascal.main import app
spec = app.openapi()['paths']
print(len(spec), 'paths', sum(len(i) for i in spec.values()), 'operations')"

docker exec rascal-postgres psql -U rascal -d rascal \
  -c "select kind, active, count(*) from prompts group by 1,2 order by 1;"
docker exec rascal-postgres psql -U rascal -d rascal \
  -tAc "select count(*) from entries where deleted_at is null;"   # 755

# Nothing is in review, and no branch is stranded. Both come back empty.
gh pr list --state open
git branch -r --no-merged origin/main

# The sealed letter has a reader and no writer. First returns hits, second returns nothing.
grep -rn "unlockAtAge" ios/Rascal/Rascal/Timeline --include="*.swift"
grep -rn "unlockAtAge" ios/Rascal/Rascal/Composer ios/Rascal/Rascal/Today --include="*.swift"
```
