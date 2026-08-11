# RASCAL — where we are against the roadmap
Snapshot: **Aug 10, 2026**, written as the share sheet went up for review. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the app's own `openapi()`, the prompts table, `gh pr list` — rather than by reading a commit message.

**This revision re-derived only the figures it could.** The pull-request count and the iOS test count were re-measured (`gh pr list`, and a cold `xcodebuild test` from a deleted `DerivedData`, with `CODE_SIGNING_ALLOWED=NO` for CI parity). **The API-side figures — API tests, live operations, prompt counts, entries in the dev archive — were carried forward unmeasured**, because this revision was written from the iOS lane and running them needs the local Postgres up. They were last re-derived at the widget snapshot and nothing in the API has changed since; treat them as two revisions stale rather than as freshly checked.

* * *
## The headline
**P0's scope list is complete, P3's headline feature is built, and both of P1's shippable retention levers now exist.** On-device transcription merged as PR #26; Moments v2 as #30; deploy readiness as #31; **the widget as #32**; the iOS CI cost fix as #33; **Today v2 as #34**. **One pull request is outstanding — the share sheet target.** Every other branch that has ever been opened is merged into `main`.

**The share sheet closes the last unblocked P1 item.** A photo now goes from Photos into an entry without opening the app, and the phase's real content is a date rather than a screen: a photo shared from the camera roll is almost never from today, so `occurred_at` is read from the file's own capture metadata and shown before Save. Defaulting it to now would have filed a 2019 photo under this week, and that error is invisible — the entry looks completely normal, on the wrong day, permanently. The architecture is the widget's, inverted: **the extension stages into the App Group container and exits; the app drains the queue through the pipeline the composer already uses.** No networking, no auth, and no second upload path in the extension. See `docs/reports/phase-12-share-extension.md`.

Of the two remaining P1 retention levers, **push notifications is the only one left, and it is blocked where TestFlight is** — on Apple enrollment, not on code.

**Today got its design pass, and the phase's most useful output was a stop rather than a screen.** The import tripped three of the four conditions the phase was told to halt on, so Phase 1 ended in `docs/today-v2-inventory.md` — a token reconciliation and eleven open questions — before any Swift existed. The finding that decided most of them: **the design prototype disagrees with its own design system.** It hardcodes a periwinkle, a sage ink and two hairlines that its own `tokens/colors.css` does not; that token file matches `Palette.swift` exactly. So one file disagreed with two, and the palette held — the same way the Moments export was resolved in Phase 10. Paper grain, the STORIES rail, the partner avatar and a second search affordance were all dropped rather than invented. See `docs/today-v2-inventory.md` §8 and the Aug 10 entry in `docs/decisions-log.md`.

**Two defects in that phase were regressions its own author introduced and an adversarial re-read caught**, and both are the kind that pass CI. Moving finished items onto a compact done card left `FailedUploadList` on a branch that cannot execute — a failed upload is terminal for the automatic sweep, so those photos would have sat on the phone permanently behind a completion check. And the skip's undo window cancelled its own task and then made the network request on it; `URLSession` honours cancellation and a stub performer does not, so every elapsed skip would have failed on a phone and passed in CI. Both are fixed, the second with a cancellation-aware performer written specifically to cover it.

**The widget is the first extension target this project has had**, and it is deliberately the dumbest thing that could work: the app writes a few hundred bytes into a shared App Group container whenever the Today board changes, and the extension renders that file. No networking, no keychain, nothing to refresh. The cost is staleness, which is why the largest single piece of the phase is refusing to draw a snapshot whose day is not today in the child's `family_timezone`. See `docs/reports/phase-11-widget.md`.

**Moments got its design pass, and the phase was mostly about a state the design could not have anticipated.** The archive is six days old, so `fallback: "random"` is what the screen returns on every date and will be for a year. The redirect was therefore built and tested as the primary state rather than the edge — same carousel, same section header, same cards, one eyebrow and one italic line different. See `docs/reports/phase-10-moments.md`.

**Two things ship switched off or unverified, and they are different kinds of unverified.**

- `syncPullEnabled` still defaults to false and gates every write the pull performs. Verified against fixtures — including a 736-entry one — and **never against the real archive**. The morning sequence is unchanged: Settings → dry run → read the report → flip the flag → pull to refresh.
- Transcription is **structurally verified and empirically unverified**. `SpeechAnalyzer` is iOS 26 and the app deploys to 18.6; `isAvailable` is false on every simulator and the model assets are a download no CI runner has. Everything below the protocol seam is asserted against a stub. **No real transcription has ever run**, so the one thing that matters most — how well it reads a four-year-old — is unknown rather than good. `docs/device-verification-transcription.md` is the way to find out.

**The scope gap that no phase ever owned is closed.** Sealed letters can now be written as well as read — see "The sealed letter, whole" below. What is left of it is a four-line server change, not a feature.

What is left is then the two things only you can unblock — Apple enrollment and Fly — and the exit test, which is you using it for fourteen days.

**Deploying is now one command plus a documented set of secrets**, and the archive no longer depends on the scheduler having woken up. `docs/runbook-deploy.md` is the ordered zero-to-verified procedure and `api/scripts/verify_deployment.py` is a program that proves a deployment works rather than a checklist that says it should. Nothing has been deployed — the agent that wrote this has no Fly token and must not have one — so every Fly command in that runbook is still unexecuted, and its §9 says so precisely.

|     |     |
| --- | --- |
| Merged pull requests | **34** — Today v2 (#34) merged since the last snapshot. The share sheet is **open** at this snapshot |
| API tests | **315 passing**, 24 files — unchanged; the share sheet is an iOS-lane change and touched nothing under `api/`. Carried forward, not re-measured |
| iOS tests | **571 passing**, 56 suites, zero warnings (verified from a deleted `DerivedData`, `CODE_SIGNING_ALLOWED=NO`) — up 47 with the share sheet, in three new suites. No existing test was modified |
| Live API operations | 32 across 26 paths (incl. `/health`, `dev-login`, and 3 local-only debug routes) |
| Prompt library | **113 authored, 113 active** — nothing held back |
| Prompt candidates awaiting your review | **79** |
| Entries in the dev archive | 755 |

**The pull-request and iOS-test counts moved; nothing in the API lane did.** The share sheet added three suites and 47 tests and edited no existing assertion. The iOS suite was run cold, from a deleted `DerivedData`, and the log contains zero occurrences of `: warning:` — the `Metadata extraction skipped. No AppIntents.framework dependency found.` build note that earlier snapshots called out no longer appears.

**Five of the share sheet's assertions were checked by breaking the code rather than by trusting them**, which is worth naming because two of them needed it. Dropping the drain's idempotency guard fails four tests; reaping staged files before the server confirms the entry fails the confirmation test on both the record and the files; and the memory test — which measures a peak footprint while a 160MB file is staged — reports 316MB against its 40MB ceiling when the copy is replaced with a read into memory. **That last one started as a before-and-after reading and passed a mutation it should have caught**, because `Data(contentsOf:)` maps a file that size and mapped pages are not charged to `phys_footprint`. It samples a peak on a second thread now, and the mmap limit is written into the test rather than left for someone to rediscover.

The iOS suite was also run **five times** for this snapshot rather than once. Today v2 introduced the project's first tests that wait on a timer, and the first version of them passed alone and failed inside the full suite, where fifty-odd parallel suites contend for the main actor. They poll for a condition now instead of sleeping a fixed interval.

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
| **11 — The widget** | The WidgetKit extension target, and Today's mission and question on the Home Screen and Lock Screen. Reads a snapshot the app writes; no networking in the extension | #32 | ✅ merged |
| **CI cost** | The iOS workflow made dispatch-only after it spent an entire month's Actions allowance in two days and took the nightly backup down with it | #33 | ✅ merged |
| **11 (the other one) — Today v2** | The Today board rebuilt against its own design export. New compact waiting and done cards, a child switcher, swipe-to-skip with a held-request undo, and the board extracted into a previewable `TodayBoardView` | #34 | ✅ merged |
| **12 — The share sheet** | A Share Extension target, the App Group staging queue it writes, and the drain in the app that turns it into entries through the existing pipeline. EXIF-derived `occurred_at`, one entry per share | — | **open at this snapshot** |

**Two numbering hazards worth naming, because both have already caused a wrong assumption.**

- **"Phase 3" means two different things.** In the iOS build order it is the media *read* path, which landed inside PR #11. PR #18 is *titled* "Phase 3" and is video *capture*. Both shipped; only the label is ambiguous.
- **The onboarding branch was misnamed and landed that way.** `ios/phase-5-onboarding` was the working branch for phase **8**; phase 5 was audio, three PRs earlier. It merged under the wrong name, so the history does now read as though audio were reopened. Nothing to undo — just do not trust the branch name in `git log`.
- **"Phase 11" now means two different things too.** The widget is phase 11 and merged as #32; Today v2 was *also* specified as phase 11 and is open as #34. The two share nothing but the number. The build order is the table above, not the labels — and the next phase specified should be numbered 12.

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
| Push notifications | ❌ blocked on Apple enrollment, in the same place TestFlight is |
| Share sheet target | ✅ **built** — images and videos only, one entry per share, `occurred_at` read from the file's capture metadata. The extension stages into the App Group container and never touches the network; the app drains it on launch and foreground. **Never launched by the system** — every screenshot is the real view rendered inside the app by a harness, because a share sheet cannot be opened from a CLI, and the memory ceiling a share extension actually runs under does not exist in a simulator. `docs/device-verification-share-extension.md` |
| **A name** (open decision #3, needed by P1) | ❌ still `RASCAL`, bundle id deliberately neutral |

* * *
## Blocked on you, not on code
These gate the P0 exit test and nothing else can move them.

1. **Apple Developer enrollment** — blocks real Sign in with Apple and TestFlight. Everything else is built and tested against a local RSA keypair. `blocked.md` §1.
  
2. **Fly** — no deployed API exists. `rascal-api.fly.dev` does not resolve and every Deploy run has skipped, waiting on `FLY_API_TOKEN` and `FLY_DEPLOY_ENABLED`. `blocked.md` §3.
  
3. **79 prompt candidates** need a human read before they can join the library.
  
4. **A restore drill** — the machinery is tested, the act never performed.
  
5. **Device verification.** **Seven** checklists are now outstanding: `docs/device-verification-share-extension.md` (new), `docs/device-verification-widget.md` from PR #32, `docs/device-verification-today-v2.md` from PR #34, `docs/device-verification-transcription.md` from PR #26, the audio list in PR #22, `docs/device-verification-settings.md` from PR #21, and `docs/device-verification-moments.md` from PR #30. The transcription one matters most and the audio one is its prerequisite — the simulator has no microphone and no speech model, so **neither recording nor transcription has ever run against anything real.** The share-sheet one is new and is the only one with a number to write down in it: a share extension's memory ceiling is not enforced on a simulator, so the architecture built to respect it has never been tested against it.
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
> **This section has gone stale twice**, both times the same way: it went on recommending something the document already reported as built, a couple of sections above itself. Re-derived again from what is actually outstanding — re-checked against `main` after deploy readiness landed, again after the widget did, again once the share sheet existed, and again now that Settings has had its design pass. **Deploying is still first.**
>
> If you are editing this file after landing a branch, this section is the part to rewrite, not the part to leave.
>
> **Checked this revision, one line at a time (after Phase 14):** deploy — still not done, still first. Device verification — now **eight** checklists, still none run; `docs/device-verification-push.md` is new and is the first one blocked on *both* enrollment and a deployed API. Push notifications — **the client is built**; what remains is not code but a credential and a deploy, and the server half is still sitting in open PR #38. A name — still open. Structured extraction — **now blocked on an API gap**: `PATCH /v1/entries/{id}` cannot write a tag with `source = device_ai`, so the phase cannot start without an endpoint change. Video audio tracks — still gated on the transcription checklist, which still records no run. `KindBadge` contrast — still unfixed. **The line that changed state is push, and it moved from "not built" to "built and unverifiable until enrollment clears."**
>
> **Previously checked, retained:** deploy — still not done, still first. Device verification — still seven checklists, still none run, but the Settings one has been **rewritten rather than merely re-listed**, because Phase 13 changed what is on that glass and found a bug that only a device ordering can produce. Push notifications — still blocked on enrollment. A name — still open. Structured extraction — still deliberately deferred. Video audio tracks — still gated on the audio checklist. `KindBadge` contrast — still unfixed, still a design-system decision. **The only line that changed state is Settings, and it moved to re-skinned.**
>
> **One entry moved up.** The Settings checklist was 5th of seven and is now 3rd. Not because the redesign is risky, but because the phase found that `Advanced` — the dry run, the reset, the pull toggle — could be **silently absent for an entire session** depending on which tab the app opened on. That is fixed, and the fix is exactly the kind that wants a device to confirm: it depends on view-construction ordering that a simulator launching straight into Settings reproduces and a test does not.

### Deploy, because everything else is waiting behind it — and now it gates a shipped feature
**Push made this sharper rather than adding to the queue.** The client is done and cannot be
verified at all: APNs pushes come from Apple to a deployed server, so there is no local version
of this test. Every day the deploy waits is a day the newest feature stays entirely unproven.

### Deploy, because everything else is waiting behind it
Nothing else on this list can be finished without a deployed API. TestFlight needs one, the fourteen-day exit test needs one, and five of the seven device-verification checklists below are against `localhost` today. It is now one command plus a set of secrets — `docs/runbook-deploy.md`, roughly twenty minutes — and `api/scripts/verify_deployment.py` tells you whether it worked instead of leaving you to guess. Do this first because it unblocks the rest, not because it is the most interesting thing here.

### Then verify what is built before building more
**Nothing here is a coding task, and that is the point.** Five features have now shipped that have never run against reality: sync pull has never touched the 755 real entries, the recording path has never met a real microphone, transcription has never produced a single word, the widget has never been rendered by WidgetKit, and **Today's swipe-to-skip has never been swiped.** Each is a checklist that takes an evening, and each one can invalidate a design rather than just find a bug.

**The list has grown by one again — to seven.** In the order they cost you least to discover something in:

0. `docs/device-verification-share-extension.md` — **new, and it goes above the widget for a reason the widget's own entry explains.** The widget's four unobservables are all about rendering; the share sheet's first one is whether the process survives. **A share extension runs under a hard memory ceiling that a simulator does not enforce**, the entire stage-don't-upload architecture exists to respect it, and the number has never been measured. Its §3 asks you to attach Instruments and write one down — it would be the only real figure this feature has. Its §2 is the sharper question though: a photo filed under the wrong day looks completely normal forever, and only a real camera roll has photos with edited metadata, missing `DateTimeOriginal`, and iCloud copies that are not on the phone.

1. `docs/device-verification-widget.md` — held the top until now for a structural reason rather than an urgency one. Four things the widget depends on **cannot be observed in a simulator at all**: the refresh budget, file protection on the Lock Screen, the monochrome accessory render, and whether the App Group even resolves on a device. It is also the shortest to run — and it now shares its App Group with a third target, so its §1 answers half of the share sheet's §1 for free.
2. `docs/device-verification-today-v2.md` — new. The screen a parent opens every day now has a **gesture** on it, and a gesture is the one interaction class a simulator answers dishonestly: a trackpad swipe is not a thumb, and the full-swipe threshold, the eight-second undo window and the VoiceOver rotor action were all verified by reading rather than by touch. Its §2 is the sharpest single question in the list — whether a skip can be lost or double-sent — because the undo is implemented by *not sending* a one-way request.
3. `docs/device-verification-settings.md` — **rewritten for Phase 13, and moved up from 5th.** It was the PR #21 checklist that had never been run; it now also covers what the design pass changed, and its §1 is the one to run first. Phase 13 found that `SyncStatusModel` was built once in `.task` and never retried, so launching straight into Settings left the whole `Advanced` card — dry run, reset, pull toggle — **absent for the life of the session with nothing saying so.** Fixed, but the fix turns on view-construction ordering, and the ordering that broke it is a real launch path rather than a contrived one.
4. `docs/device-verification-transcription.md` — the one with the most unknown in it.
5. The audio checklist from PR #22 — the simulator has no microphone, so **nothing in the recording path has run against real input.**
6. The sync-pull sequence: dry run, read the report, then flip the flag. **Now one card rather than a run of rows** — the dry run and the reset live under `Advanced`, the switch stayed with the status it gates.
7. `docs/device-verification-moments.md` from PR #30 — the cheapest of the seven, and the one with the sharpest question about content rather than mechanics: a sealed letter is surfaced by that screen at random, and only a device shows you what is actually on the glass.

### Then, in build terms
- **Phase 8, onboarding and account creation** — shipped. The app now has a first-run path for a person who is not you, though Sign in with Apple itself still cannot be exercised until enrollment clears.
  
- ~~**The seal control in the composer**~~ — **shipped**, as PR #29. See "The sealed letter, whole" above; what remains of it is a four-line server change in `blocked.md`, not a feature.
  
- ~~**The widget**~~ — **merged**, as PR #32, and with it the project's first extension target and its first deep-link handling. The roadmap calls it the reason the loop survives week four; whether it actually does cannot be known from a simulator, which is why its checklist is first on the list above.

- ~~**Today v2**~~ — **built**, open as PR #34. Three things in its design were dropped rather than built, and each is a decision waiting rather than a task: **paper grain** (the export calls it mandatory identity, `design-system.md` lists screen-print texture as an anti-pattern, and neither decisions file mentions grain at all), the **STORIES rail** (throwbacks on Today — the data exists behind `GET /children/{id}/moments` and `ThrowbackCard` already renders it, but it needs a second call from the screen the contract calls "the single call the home screen makes"), and the **96pt completion burst**. None is blocked on code. Also deferred with it: thumbnails on Today's cards and the per-tile upload strip, both of which reach into the media paths.

- **A contrast defect the phase found and did not fix.** `KindBadge` draws tint-coloured text on a 12% wash of the same tint, which measures roughly 3.3–3.7:1 at 12pt semibold — below WCAG AA. It is pre-existing and shared, and fixing it needs either a `periwinkleDeep` token or a badge restyle, i.e. a design-system decision rather than a patch. **Phase 13 checked and did not propagate it**: the only place the Settings import uses tint-on-tint is in a direction the file never renders.

- ~~**Settings v2**~~ — **built.** The last screen still wearing its PR #21 scaffolding has had its design pass, so Timeline, Moments, Today and Settings now read as one app. The import's argument was that Settings should open on the child rather than on configuration, and it does: `ChildHeroCard` replaced the `Name` row, section labels carry a rule to the trailing edge, the sync card grew a summary head that tints while files are in flight, and export reads as a keepsake rather than a menu item. See `docs/settings-v2-inventory.md`.

  **Three things were dropped for want of a number, and each is an API conversation rather than a task**: the hero's `412 entries · 1,204 photos · 3 sealed` strip, the `First entry` row, and the sync progress bar all need archive-wide counts that no endpoint serves — and `design-system.md` already settles, for the timeline header, that the client never claims to know the size of the archive. A `GET /children/{id}/stats` would light up all three at once. Also dropped: **paper grain again** (still unresolved, still the same three-way disagreement), and the export card's decorative motif, which turned out to be literally three rotated cards — a named anti-pattern.

  **One structural change was refused.** The import groups `Recompute ages from birthday` with the dry run and the reset under `Advanced`. It stayed in its own card with its own whitespace, because rewriting every stored age in an archive is not a neighbour of asking the server what changed.

- ~~**The share sheet target**~~ — **built**, and open for review at this snapshot. The widget's extension target was indeed the pattern, down to two of the same traps in the `xcodeproj` script. What it added that the widget did not have: a **write** direction on the App Group, a queue with a version gate, and a drain that has to be idempotent under a process the system can kill at any point. See `docs/reports/phase-12-share-extension.md`.

- **Push notifications is now the only unbuilt P1 retention lever**, and it is blocked in the same place TestFlight is — it needs the Apple enrollment that `blocked.md` has been waiting on. Nothing else on P1 is waiting on code.

- **Cross-share deduplication was deliberately not built**, and it is a decision rather than an omission. Sharing the same photo twice makes two entries: an `NSItemProvider` carries no asset identifier, and content-hashing a video inside the memory-ceilinged process is precisely what the architecture exists to avoid. It is also not obviously wrong — the same photo on two days is a legitimate pair of entries — so shipping a heuristic that silently dropped one would have been worse than shipping neither. Worth revisiting only if the device checklist's §10 says a real parent trips over it.

- **A name.** Open decision #1, and the widget has just made it slightly more expensive to defer: the widget gallery groups by app name, so whatever the app is called is what a parent reads when they add it. The bundle id and the URL scheme are both deliberately name-neutral, so this is still a rename and not a migration — but it is now visible in one more place.
  
- **P3 item 2, structured extraction** (`@Generable` over the transcripts that now exist). Deliberately not done in this phase — it is a separate feature with its own schema question, and stacking it on an unverified transcriber would mean two unknowns in one branch.
  
- **Video audio tracks**, the one piece of this phase that was cut. Gated on the audio path being verified on a device first — see `docs/decisions.md`.
  

* * *
## Facts, if you want to check any of this
```bash
make test                                    # 315 API tests
ls api/tests/test_*.py | wc -l               # 24 files

# Delete DerivedData first or the warning count is a lie: an incremental build does not
# recompile an unchanged file, and a file that is not recompiled emits no warning. This is
# not theoretical — this phase's first full run surfaced 21 warnings that a targeted
# `-only-testing` run had reported as zero.
rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 571 iOS tests, 56 suites, zero warnings

# Three targets now, and all three must carry the same App Group or the widget goes
# neutral and the share sheet says it cannot save — in both cases with no error anywhere.
grep -l "group.com.travisterry.childarchive" ios/Rascal/*.entitlements   # expect 3

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
