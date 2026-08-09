# RASCAL — where we are against the roadmap
Snapshot: **Aug 9, 2026**, after the transcription branch. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the app's own `openapi()`, the prompts table — rather than by reading a commit message. **Every number below was re-derived for this snapshot rather than edited**; several of them had drifted.

* * *
## The headline
**P0's scope list is complete, and P3's headline feature is now built.** On-device transcription landed on `ios/phase-7-transcription`: `SpeechAnalyzer` over the recorder's m4a files, written back through `PATCH /media/{id}/derived`, with the minimal search surface needed to see that it worked.

**Two things ship switched off or unverified, and they are different kinds of unverified.**

- `syncPullEnabled` still defaults to false and gates every write the pull performs. Verified against fixtures — including a 736-entry one — and **never against the real archive**. The morning sequence is unchanged: Settings → dry run → read the report → flip the flag → pull to refresh.
- Transcription is **structurally verified and empirically unverified**. `SpeechAnalyzer` is iOS 26 and the app deploys to 18.6; `isAvailable` is false on every simulator and the model assets are a download no CI runner has. Everything below the protocol seam is asserted against a stub. **No real transcription has ever run**, so the one thing that matters most — how well it reads a four-year-old — is unknown rather than good. `docs/device-verification-transcription.md` is the way to find out.

What is left is then the two things only you can unblock — Apple enrollment and Fly — and the exit test, which is you using it for fourteen days.

|     |     |
| --- | --- |
| Merged pull requests | **25** (+1 open: transcription) |
| API tests | **302 passing**, 23 files — unchanged this phase, no `api/` code was touched |
| iOS tests | **343 passing**, 41 suites, zero warnings (verified from a deleted `DerivedData`) |
| Live API operations | 32 across 26 paths (incl. `/health`, `dev-login`, and 3 local-only debug routes) |
| Prompt library | **113 authored, 113 active** — nothing held back |
| Prompt candidates awaiting your review | **79** |
| Entries in the dev archive | 755 |

The previous snapshot claimed 275 iOS tests in 34 suites and 26 API test files. The iOS figure was two branches stale — `main` was already at **295 in 37 suites** before this phase began — and the file count was simply wrong. Both are re-measured above.

* * *
## Phases at a glance
| Phase | Roadmap window | Status |
| --- | --- | --- |
| **P0 — POC** | Aug 3–14 | **Scope complete, client sync built but unverified on device.** TestFlight blocked; exit test not started |
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
| "On this day" | ✅   | Moments, incl. the warm random fallback |
| TestFlight to yourself | ❌ **blocked** | Apple Developer enrollment — `blocked.md` §1 |
### The build-order item that was outstanding — now built
**Days 3–4 called for a sync engine: "pull-since-**`updated_at`**, push queue".** The push queue was already solid. **The pull now exists**, in `ios/Rascal/Rascal/Sync/`, and all three documented defects have a test that fails without it:

- ✅ An entry deleted on another device now disappears here, arriving as a row with `deleted_at` set. It does not resurrect on a later pull that no longer mentions it.
  
- ✅ `POST /children/{id}/recompute-ages` now reaches the whole archive. Tested against a 130-entry fixture spanning three pages — the oldest row, which no page-one refetch would ever have reached, is asserted by name.
  
- ✅ Media deleted elsewhere still leaves through the entry's live media list, and entries now have their own path. Both are tested; the old one was not broken to add the new one.
  

**The caveat that matters.** All of that is verified against fixtures. The flag is off, so none of it has run against the 736 real entries in the dev archive. The dry run exists precisely so that can be inspected before the flag moves.

Single-device, single-parent, none of this bites. **It becomes correctness-critical the moment P2 puts a second parent on the same child.**

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
| Home Screen / Lock Screen widget | ❌ no extension target exists |
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
  
5. **Device verification.** Three checklists are now outstanding: `docs/device-verification-transcription.md` from this branch, the audio list in PR #22, and `docs/device-verification-settings.md` from PR #21. The transcription one matters most and the audio one is its prerequisite — the simulator has no microphone and no speech model, so **neither recording nor transcription has ever run against anything real.**
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
> This section previously recommended building the client's half of sync — which the same document already reported as built, two sections above it. It had been stale for a branch and a half. Re-derived below from what is actually outstanding.

### Verify what is built before building more
**Nothing here is a coding task, and that is the point.** Three features have now shipped that have never run against reality: sync pull has never touched the 755 real entries, the recording path has never met a real microphone, and transcription has never produced a single word. Each is a checklist that takes an evening, and each one can invalidate a design rather than just find a bug.

In the order they cost you least to discover something in:

1. `docs/device-verification-transcription.md` — new, and the one with the most unknown in it.
2. The audio checklist from PR #22 — the simulator has no microphone, so **nothing in the recording path has run against real input.**
3. `docs/device-verification-settings.md` from PR #21.
4. The sync-pull sequence: dry run, read the report, then flip the flag.

### Then, in build terms
- **P1's retention levers** — the widget especially, which the roadmap calls the reason the loop survives week four. It is also the largest genuinely-unbuilt thing left: there is no extension target at all.
  
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
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 343 iOS tests, 41 suites, zero warnings

# Routes, without needing the API to be running.
cd api && ENVIRONMENT=local uv run python -c "
from rascal.main import app
spec = app.openapi()['paths']
print(len(spec), 'paths', sum(len(i) for i in spec.values()), 'operations')"

docker exec rascal-postgres psql -U rascal -d rascal \
  -c "select kind, active, count(*) from prompts group by 1,2 order by 1;"
docker exec rascal-postgres psql -U rascal -d rascal \
  -tAc "select count(*) from entries where deleted_at is null;"   # 755
```
