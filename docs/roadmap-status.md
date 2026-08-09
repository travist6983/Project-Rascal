# RASCAL — where we are against the roadmap
Snapshot: **Aug 9, 2026**, after the sync-pull branch. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the live API's `openapi.json`, the prompts table — rather than by reading a commit message.

* * *
## The headline
**The P0 scope list is complete, and the last build-order gap is now built.** The client's half of sync landed on `ios/phase-6-sync-pull`: `GET /sync` is read, applied, and tested, closing all three documented defects.

**It ships switched off.** `syncPullEnabled` defaults to false and gates every write the pull performs. It has been verified against fixtures — including a 736-entry one — and **never against the real archive**. The morning sequence it was built for is: Settings → dry run → read the report → flip the flag → pull to refresh. Until that has happened, treat this as built-but-unverified, not as done.

What is left is then the two things only you can unblock — Apple enrollment and Fly — and the exit test, which is you using it for fourteen days.

|     |     |
| --- | --- |
| Merged pull requests | **22** (+1 open: sync pull) |
| API tests | **302 passing**, 26 files |
| iOS tests | **270 passing**, 33 suites, zero warnings |
| Live API routes | 32 (incl. `/health` and 3 local-only debug routes) |
| Prompt library | **113 authored, 113 active** — nothing held back |
| Prompt candidates awaiting your review | **79** |
| Entries in the dev archive | 736 |

* * *
## Phases at a glance
| Phase | Roadmap window | Status |
| --- | --- | --- |
| **P0 — POC** | Aug 3–14 | **Scope complete, client sync built but unverified on device.** TestFlight blocked; exit test not started |
| **P1 — Daily driver** | Aug 17 – Sep 11 | **Partly pre-banked** — search backend, moments, backups, transcode policy all done early |
| **P2 — Family** | Sep 14 – Oct 9 | Not started. Authorization and the `guardians` table are built and tested; only the invite flow is missing |
| **P3 — Intelligence** | Oct 12 – Nov 6 | Not started, and **now unblocked** — audio exists to transcribe, and `PATCH /media/{id}/derived` is waiting for it |
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
| Full-text search over titles and bodies | ✅ **backend only** — `GET /entries?q=`, weighted, stemmed, keyset-paginated. **No client surface** |
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
  
5. **Device verification.** Two checklists are now outstanding: `docs/device-verification-settings.md` from PR #21, and the audio list in PR #22. The audio one matters more — the simulator has no microphone, so **nothing in the recording path has ever run against real audio input.**
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
### The client's half of sync
Now the highest-value unbuilt thing, and the only P0 build-order item left.

`GET /sync` since a cursor, upserting entries, media, assignments and tags by id, honouring the deliberate thirty-second overlap window the server documents. It closes the three defects listed above, and it is a **hard prerequisite for P2** — two parents on one child without it is a data-loss story rather than a feature.

Worth doing before P2 rather than as part of it, and worth doing with you awake: it touches the local cache everything else reads from.
### After that, either
- **P3's on-device transcription**, which audio has just unblocked. `SpeechAnalyzer` over the m4a files, written back through `PATCH /media/{id}/derived`. Search already weights transcripts at rank B and the client's `Media` model already has the column, so the landing zone is built on both sides.
  
- **P1's retention levers** — the widget especially, which the roadmap calls the reason the loop survives week four.
  

* * *
## Facts, if you want to check any of this
```bash
make test                                    # 302 API tests
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 270 iOS tests, zero warnings
curl -s localhost:8000/openapi.json | jq '.paths | keys'
docker exec rascal-postgres psql -U rascal -d rascal \
  -c "select kind, active, count(*) from prompts group by 1,2 order by 1;"
```
