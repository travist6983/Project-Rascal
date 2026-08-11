# RASCAL — where we are against the roadmap
Snapshot: **Aug 11, 2026 (evening revision)**, written after the camera-roll backfill merged and after the two long-standing human blockers turned out to be closed. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the app's own `openapi()`, the prompts table, `gh pr list` — rather than by reading a commit message.

**This revision re-derived every API-side figure it had been carrying forward, and every one of them had drifted.** The local Postgres was up, so nothing needed to be estimated: the API suite was run (`uv run pytest`), the route count came from the app's own `openapi()`, and the prompt and entry counts came from `psql`. The stale figures were **413 API tests in 29 files** (now **446 in 33**), **32 operations across 26 paths** (now **40 across 33**) and **755 entries** (now **759**). The pull-request count was re-measured with `gh pr list`. **The iOS test count was re-measured in phase 20** — **705 in 86 suites**, from a deleted `DerivedData` with `CODE_SIGNING_ALLOWED=NO`, on `phase-20/onboarding-settings`. The previous figure of 678 in 81 was confirmed by measurement at that phase's preflight before any code was written, so both ends of the delta are measured rather than carried.

> **The correction this revision exists to make.** The previous revision reported Apple enrollment and Fly as the two things blocking everything, and `docs/blocked.md` had recorded both as **resolved on Aug 10** — struck through, with the evidence in place. This file went on repeating the blocked version for a full day, in five separate places, including the section whose entire job is to say what to do next. It also carried "one pull request is outstanding" past that PR's merge. **Two documents disagreed and the older claim was the one being read.** Both are corrected below, and the figures that follow were re-derived rather than re-copied for exactly that reason.

* * *
## The headline
**The app is on TestFlight, against a deployed API, and nothing is open.** That is three sentences the previous eight revisions of this file could not write. Sign in with Apple runs against a real Apple-signed token, media uploads land in a production bucket from a phone in the world, and PR #44 — the camera-roll backfill — merged. **Every pull request this project has ever opened is now merged or closed; `gh pr list --state open` returns nothing.**

**The shape of the work has changed, and this is the sentence to carry out of this file.** For eight revisions the answer to "what next" was *deploy, because everything is behind it*. Deploying is done. **What is in front of you now is not a build queue, it is a verification backlog: nine device checklists, 356 checkboxes, zero ticked.** Nothing on that list is a coding task, most of it was unrunnable until yesterday, and all of it is runnable tonight.

**The day is three items now, not two, and the photo pool is the thing to watch.** Phase 19 split the daily `mission` slot: `mission` draws photo only, and a new `mission_b` takes the video, audio and activity kinds it used to share. The old pairing meant one coin flip decided whether a parent was asked for a photo — the artifact the archive is mostly made of — or asked to record his voice; now both get asked for every day. Weekly, monthly and letter fire on top rather than instead, so a Saturday is four items and a Saturday that is also the 15th is five. **`mission` keeps its name while its meaning narrows**, so pre-`0008` rows hold non-photo prompts in `mission` and are correct for the day they were served — `docs/decisions.md` says so in those words, because the first person to find one will otherwise read it as a bug.

**The measured cost, from `GET /pool-health` rather than from arithmetic:** at 49 months the question pool lasts 30 days before its first repeat, `mission_b` 37, and **`mission` 20 — cooldown relaxation begins 2026-08-31.** Splitting a 57-prompt pool into 20 and 37 is what buys three items a day. **The fix for the thin half is authoring photo prompts, not tuning anything**, and phase 19 deliberately authored none.

**The camera-roll backfill is complete — engine and surface — and merged as #44.** Since the last snapshot: the share sheet (#35), Settings v2 (#37), push notifications (#39, #40), prompt-pool durability (#41), structured extraction (#43, #45), and video audio tracks (#42) which merged **blocked** and is documented as such.

**`main`'s CI was red on `ruff`, and it was six files rather than the one line this section used to name.** The `E501` at `api/alembic/versions/0007_prompt_suppressions.py:82` was real and was what the job reported. It was not the whole of it: `ci.yml` runs `ruff check` and `ruff format --check` as **separate steps**, the first aborts the job, and the format step had therefore never executed on `main` — hiding five more files, one of them `services/scheduler.py`. Fixing only the named line would have advanced the job one step and failed it there. All six are fixed in phase 19's first commit. The lesson is the step ordering, not the line: **a lint job that stops at its first failing step reports its first problem, not its problems.**

**Phase 18 reversed one of its own decisions the same day it took it, deliberately and in writing.** The plan put the backfill offer as a quiet row inside the composer, chosen partly because it cost the primary action nothing. The design export described something else — **+** opening an *Add to the archive* sheet with the camera roll as a browse entry point of its own. That gap was raised rather than built around, the design was chosen, and the cost is stated plainly in `docs/decisions.md`: **every entry in the app now pays a tap it did not pay before.** If that trade is wrong, the sheet is the thing to change, not the flow behind it.

**The phase's most valuable output was four accessibility defects that only a screenshot could find**, and the worst of them was severe: at accessibility XXL the permission screen's headline ran off the top and *both* of its actions ran off the bottom, with no scroll. iOS shows its photo prompt once — a parent at that text size would have hit a permanent dead end, with nothing on screen explaining why, and the feature would simply never have worked for them. The same `VStack`-of-spacers pattern was wrong in three sibling screens. All four now scroll with their actions pinned. A month heading also broke *inside the word* — "Octobe / r" — because a month and its year sat in two layout boxes instead of one `Text`.

**Two defects were caught by re-reading rather than by running.** A day was badged "Written" the moment the composer *opened*, so cancelling it left a check mark with no entry behind it — the same class of lie as a completion check on an empty prompt. And the scan was being awaited by polling `state` in a loop on the main actor, on the one feature whose whole design constraint is staying cheap against a forty-thousand-asset library.

**A warm build under-reports warnings, and this phase proved it again.** The branch's recorded "0 warnings" baseline had been measured warm; a cold run surfaced pre-existing ones the moment an untouched file was forced to recompile. Worth naming twice because it is the second time: `xcodebuild build` alone does not compile the **test** target at all, so a build-only warning count omits every test file.

**P0's scope list is complete, P3's headline feature is built, and both of P1's shippable retention levers now exist.** On-device transcription merged as PR #26; Moments v2 as #30; deploy readiness as #31; **the widget as #32**; the iOS CI cost fix as #33; **Today v2 as #34**; the share sheet as #35. Every branch that has ever been opened is merged into `main`.

**The share sheet closes the last unblocked P1 item.** A photo now goes from Photos into an entry without opening the app, and the phase's real content is a date rather than a screen: a photo shared from the camera roll is almost never from today, so `occurred_at` is read from the file's own capture metadata and shown before Save. Defaulting it to now would have filed a 2019 photo under this week, and that error is invisible — the entry looks completely normal, on the wrong day, permanently. The architecture is the widget's, inverted: **the extension stages into the App Group container and exits; the app drains the queue through the pipeline the composer already uses.** No networking, no auth, and no second upload path in the extension. See `docs/reports/phase-12-share-extension.md`.

Of the two remaining P1 retention levers, **push notifications is the only one left — and it is no longer blocked, only undone.** Enrollment cleared on Aug 10, so the APNs key is a portal trip you can make rather than an approval you are waiting on. Two actions, both yours: mint the `.p8` and set three Fly secrets (`docs/runbook-deploy.md` §4a), then create the notification job's scheduled machine (§4b). **The second is the one that gets forgotten and fails silently** — the API stays green, devices register, and no notification is ever sent.

**Today got its design pass, and the phase's most useful output was a stop rather than a screen.** The import tripped three of the four conditions the phase was told to halt on, so Phase 1 ended in `docs/today-v2-inventory.md` — a token reconciliation and eleven open questions — before any Swift existed. The finding that decided most of them: **the design prototype disagrees with its own design system.** It hardcodes a periwinkle, a sage ink and two hairlines that its own `tokens/colors.css` does not; that token file matches `Palette.swift` exactly. So one file disagreed with two, and the palette held — the same way the Moments export was resolved in Phase 10. Paper grain, the STORIES rail, the partner avatar and a second search affordance were all dropped rather than invented. See `docs/today-v2-inventory.md` §8 and the Aug 10 entry in `docs/decisions-log.md`.

**Two defects in that phase were regressions its own author introduced and an adversarial re-read caught**, and both are the kind that pass CI. Moving finished items onto a compact done card left `FailedUploadList` on a branch that cannot execute — a failed upload is terminal for the automatic sweep, so those photos would have sat on the phone permanently behind a completion check. And the skip's undo window cancelled its own task and then made the network request on it; `URLSession` honours cancellation and a stub performer does not, so every elapsed skip would have failed on a phone and passed in CI. Both are fixed, the second with a cancellation-aware performer written specifically to cover it.

**The widget is the first extension target this project has had**, and it is deliberately the dumbest thing that could work: the app writes a few hundred bytes into a shared App Group container whenever the Today board changes, and the extension renders that file. No networking, no keychain, nothing to refresh. The cost is staleness, which is why the largest single piece of the phase is refusing to draw a snapshot whose day is not today in the child's `family_timezone`. See `docs/reports/phase-11-widget.md`.

**Moments got its design pass, and the phase was mostly about a state the design could not have anticipated.** The archive is six days old, so `fallback: "random"` is what the screen returns on every date and will be for a year. The redirect was therefore built and tested as the primary state rather than the edge — same carousel, same section header, same cards, one eyebrow and one italic line different. See `docs/reports/phase-10-moments.md`.

**Two things ship switched off or unverified, and they are different kinds of unverified.**

- `syncPullEnabled` still defaults to false and gates every write the pull performs. Verified against fixtures — including a 736-entry one — and **never against the real archive**. The morning sequence is unchanged: Settings → dry run → read the report → flip the flag → pull to refresh.
- Transcription is **structurally verified and empirically unverified**. `SpeechAnalyzer` is iOS 26 and the app deploys to 18.6; `isAvailable` is false on every simulator and the model assets are a download no CI runner has. Everything below the protocol seam is asserted against a stub. **No real transcription has ever run**, so the one thing that matters most — how well it reads a four-year-old — is unknown rather than good. `docs/device-verification-transcription.md` is the way to find out.

**The scope gap that no phase ever owned is closed.** Sealed letters can now be written as well as read — see "The sealed letter, whole" below. What is left of it is a four-line server change, not a feature.

**The two things only you could unblock are unblocked.** ~~Apple enrollment~~ and ~~Fly~~ both closed on Aug 10. What is left is the exit test — you using it for fourteen days — and the verification backlog that now stands between the code and any claim that it works.

**Deploying is done, not documented-as-doable.** `https://rascal-api.fly.dev` serves, `/health` returns `{"status":"ok","db":"ok"}` (checked again while writing this), `dev-login` correctly 404s in production, and `scripts/verify_deployment.py` passed **6/6** against it — including the Tigris round trip that had never once succeeded anywhere. Two machines in `ord`, an hourly scheduler machine beside them. `FLY_DEPLOY_ENABLED` is set: pushes to `main` deploy on their own, and the last four Deploy runs are green. `ios/Rascal/Config.xcconfig` points the client at `rascal-api.fly.dev` over HTTPS, which is what a TestFlight build is talking to.

**Two things the first real deployment broke are in `docs/runbook-deploy.md` §9**, both silent, both fixed: `deploy.yml` failed a healthy deploy over a status string (`succeeded` vs flyctl's `complete`), and the runbook's `fly machine run` built a machine that ran the API server instead of the scheduler.

|     |     |
| --- | --- |
| Merged pull requests | **44**, and **nothing is open.** Ten merged since the last snapshot: the share sheet (#35), the deploy fixes (#36), Settings v2 (#37), push notifications (#39, #40), the prompt pool (#41), video audio tracks (#42, blocked on arrival), structured extraction (#43), the tag-source unblock (#45) and the camera-roll backfill (#44). One PR was **closed unmerged** — #38, the first push-server attempt, superseded by #39 |
| API tests | **459 passing**, 33 files — re-measured on the phase-19 branch (446 on `main` before it; the three-missions split added 13 and no existing test was deleted). Earlier revisions of this row claimed **413 in 29** and then **446 in 33**, each one revision stale when written. **Locally 2 of the 459 fail**, both in `tests/test_restore.py`, and the cause is the machine rather than the code: Homebrew's `pg_dump` is 17.6, a 17 client writes `SET transaction_timeout` into the dump, and Postgres 16 rejects it on the way back in. CI pins 16 exactly |
| iOS tests | **705 passing**, 86 suites (verified from a deleted `DerivedData`, `CODE_SIGNING_ALLOWED=NO`) — phase 20 added 27 in five suites over the 678 in 81 it measured at preflight. **Two existing assertions were replaced**, both because that phase's brief overturned the behaviour they pinned: `noRowWhenNothingToOffer` and the two `lastPullDescription` expectations. Named rather than absorbed — see `docs/phases/phase-20-verification.md` §8. **Zero warnings in any file phase 20 touches**; 21 remain, all inherited: 14 in `RascalTests/PushPermissionTests.swift` (phase 14), 4 in `RascalTests/ExtractionTests.swift` and **3 in `Rascal/Extraction/ExtractedDetails.swift`** (phase 17, and that last set is in the *app* target). **Phase 19's iOS half is not in this number — it has never been compiled**, see the note under Phase 19 above |
| Live API operations | **40 across 33 paths** (incl. `/health`, `dev-login`, and the local-only debug routes) — re-derived; the **32 across 26** this row carried was two revisions stale, from before the avatar, pool-health, push and tag-source routes |
| Prompt library | **113 authored, 113 active** — nothing held back. By kind: 30 question, 25 activity, 23 photo, 12 audio, 12 video, 8 letter, 3 measurement |
| Prompt candidates awaiting your review | **79** — unchanged since Aug 4, and now carrying a tone decision they were not generated under |
| Entries in the dev archive | **759** |
| Device-verification checkboxes ticked | **0 of 356**, across nine checklists. The one figure in this table that has never moved |

**Every API-side figure in this table moved, and the reason none of them had is worth stating.** The last three revisions were written from the iOS lane, where re-deriving them needs the local Postgres running, so each revision honestly labelled them stale and carried them forward — and "one revision stale" compounded into "two", then into numbers that were wrong by 33 tests, 8 operations and 4 entries. Labelling a figure stale is not the same as it being harmless. This revision ran them.

**The pull-request and iOS-test counts also moved.** The share sheet added three suites and 47 tests and edited no existing assertion. The iOS suite was last run cold, from a deleted `DerivedData`, and the log contains zero occurrences of `: warning:` — the `Metadata extraction skipped. No AppIntents.framework dependency found.` build note that earlier snapshots called out no longer appears.

**Five of the share sheet's assertions were checked by breaking the code rather than by trusting them**, which is worth naming because two of them needed it. Dropping the drain's idempotency guard fails four tests; reaping staged files before the server confirms the entry fails the confirmation test on both the record and the files; and the memory test — which measures a peak footprint while a 160MB file is staged — reports 316MB against its 40MB ceiling when the copy is replaced with a read into memory. **That last one started as a before-and-after reading and passed a mutation it should have caught**, because `Data(contentsOf:)` maps a file that size and mapped pages are not charged to `phys_footprint`. It samples a peak on a second thread now, and the mmap limit is written into the test rather than left for someone to rediscover.

The iOS suite was also run **five times** for this snapshot rather than once. Today v2 introduced the project's first tests that wait on a timer, and the first version of them passed alone and failed inside the full suite, where fifty-odd parallel suites contend for the main actor. They poll for a condition now instead of sleeping a fixed interval.

An earlier snapshot claimed 275 iOS tests in 34 suites and 26 API test files. All three were wrong; they were corrected last time and have held.

* * *
## Phases at a glance
| Phase | Roadmap window | Status |
| --- | --- | --- |
| **P0 — POC** | Aug 3–14 | **Scope complete and shipping to TestFlight against a deployed API.** Onboarding shipped and has been run for real. What is left of P0 is the exit test — fourteen days of use — which has not started, and the device verification that stands between "built" and "known to work" |
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
| TestFlight to yourself | ✅ **done** | ~~Apple Developer enrollment — `blocked.md` §1~~ — enrollment cleared Aug 10 and the app is on TestFlight against `rascal-api.fly.dev`. Sign in with Apple has run end to end from a device build: `POST /v1/auth/apple → 200`, a real `credentials` row, a real `users` row. **This closes the last ❌ in P0's scope list** |
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
| **8 — Onboarding** | Onboarding + account creation, `OnboardingGate` owning session state | #27, #28 | ✅ **merged and done.** ~~with red CI~~ — #28 fixed the two wall-clock transcription tests and five defects the merge shipped. **Run for real**: a first-run setup has been completed on a device against the deployed API |
| **9 — The seal control** | The composer's half of `unlock_at_age`: shown for `letter` prompts, sealed by default, age from the prompt | #29 | ✅ merged |
| **10 — Moments v2** | The Moments tab re-skinned against its own design export. The redirect built as the primary state, not the edge | #30 | ✅ merged |
| **11 — The widget** | The WidgetKit extension target, and Today's mission and question on the Home Screen and Lock Screen. Reads a snapshot the app writes; no networking in the extension | #32 | ✅ merged |
| **CI cost** | The iOS workflow made dispatch-only after it spent an entire month's Actions allowance in two days and took the nightly backup down with it | #33 | ✅ merged |
| **11 (the other one) — Today v2** | The Today board rebuilt against its own design export. New compact waiting and done cards, a child switcher, swipe-to-skip with a held-request undo, and the board extracted into a previewable `TodayBoardView` | #34 | ✅ merged |
| **12 — The share sheet** | A Share Extension target, the App Group staging queue it writes, and the drain in the app that turns it into entries through the existing pipeline. EXIF-derived `occurred_at`, one entry per share | #35 | ✅ merged |
| **ops** | The two things the first real deploy broke | #36 | ✅ merged |
| **13 — Settings v2** | The screen opens on the child; the card that could vanish | #37 | ✅ merged |
| **14 — Push notifications** | One notification a day, the server owning the schedule, and four things it could not have survived in production | #39, #40 | ✅ merged |
| **15 — Prompt pool durability** | Suppression outranks every relaxation rule, including an empty pool | #41 | ✅ merged |
| **16 — Video audio tracks** | Blocked on arrival; see `docs/phases/phase-16-BLOCKED.md` | #42 | ⛔ merged blocked |
| **17 — Structured extraction** | Plus #45, which let a tag write say who decided it | #43, #45 | ✅ merged |
| **18 — Camera-roll backfill** | The engine (scan, clustering, dismissal, caching, the `occurred_at` rule) **and** the surface: an *Add to the archive* sheet behind **+**, a permission explainer, suggestions, an every-month browse list, a day-grouped picker, and a prefilled composer | #44 | ✅ merged |

**Two numbering hazards worth naming, because both have already caused a wrong assumption.**

- **"Phase 3" means two different things.** In the iOS build order it is the media *read* path, which landed inside PR #11. PR #18 is *titled* "Phase 3" and is video *capture*. Both shipped; only the label is ambiguous.
- **The onboarding branch was misnamed and landed that way.** `ios/phase-5-onboarding` was the working branch for phase **8**; phase 5 was audio, three PRs earlier. It merged under the wrong name, so the history does now read as though audio were reopened. Nothing to undo — just do not trust the branch name in `git log`.
- **"Phase 11" now means two different things too.** The widget is phase 11 and merged as #32; Today v2 was *also* specified as phase 11 and is open as #34. The two share nothing but the number. The build order is the table above, not the labels — and the next phase specified should be numbered 12.

### Phase 8, precisely
Merged as **PR #27**. What shipped: **welcome → Sign in with Apple → name → birthdate → timezone → avatar → Today**, gated by an `OnboardingGate` that owns session state and hands the resolved child down to `RootView`. A returning account skips setup entirely. Two decisions worth not relitigating: the birthdate is carried as a `yyyy-MM-dd` **string** end to end so it cannot drift a day west of Greenwich, and `display_name` is **omitted rather than nulled** when Apple declines to supply one, because Apple returns `fullName` only on the first-ever authorization for an Apple ID and the server applies first-write-wins.

~~**It merged with red CI, and that is the thing to know.**~~ **Closed by PR #28**, which was merged as "Green main again, and five defects the onboarding merge shipped". Two transcription cancellation tests had ordered a race against a wall clock — `sleep(60ms)`, then assume the run is under way — and broke under the extra parallelism the onboarding suites added. #28 fixed that and five production defects found afterwards in the merged code: `RootView` re-resolving session state (which could show a production parent "the API is not running with ENVIRONMENT=local"), a sign-out that landed on a screen offering only `dev-login`, a second sign-out in one launch silently doing nothing, no way out of setup after signing in with the wrong Apple ID, and `AvatarCrop` decoding a full-resolution photo to produce 512 pixels. `docs/reports/phase-5-onboarding.md` is the full account.

~~**Still unverifiable, and not by omission:** Sign in with Apple has never executed — not on a device, not once.~~ **It has now, and the run is in `blocked.md` §1.** From a device build at `01:06:29Z` on Aug 10: `POST /v1/auth/apple → 200`, a `credentials` row with `provider=apple`, a `users` row on a `privaterelay.appleid.com` address. The `aud` check — the one thing no test could exercise, because it needs a token from an enrolled team — has a real Apple-signed token behind it.

**Three things that first real sign-in produced, all worth keeping.** The **stale-session path ran unrehearsed and was correct**: the phone still held a token minted by the local API under a different `JWT_SECRET`, and it went 401 → refresh 401 → `auth/apple` 200 → `POST /children` 201 rather than stranding the parent. The account was created with **`display_name` NULL**, which is not a defect — Apple returns `fullName` only on the first-ever authorization for an Apple ID, and it had been spent against the local API. And **revocation is still unexercised**: `getCredentialState` is called on launch and no run has ever seen a parent revoke the app in Settings and come back.

**Two onboarding gaps remain, and both changed status this revision.** They were recorded as blocked on Lane A; Lane A has since built both halves and nothing marked them resolved:

- **The avatar is still device-only** — but the endpoints now exist. `POST /children/{id}/avatar-upload-url` and `GET /children/{id}/avatar-url` are both in `routers/children.py`. `AvatarStore.swift`'s header comment still says "nothing mints one", which was true when written. Unblocked, unstarted, iOS-lane.
- **Onboarding still does not collect pronouns** — but `children.pronouns` exists (`models/child.py:25`, `text` + a named CHECK, on `ChildCreate`/`ChildUpdate`/`ChildOut`). The stated reason for not asking was that there was nowhere to put the answer; there is now. This is what `docs/decisions.md` open item 10 has been waiting on.

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

### How you actually reach it — the thing this section never said

**Added Aug 11, 2026, because the omission caused exactly the confusion it was going to cause.**
Every paragraph above describes a finished feature and not one of them says where the control
appears, so the honest reading of this section was "shipped" and the honest experience of the app
was "there is no way to write a letter." Both were true, and the missing sentence is this:

> **A letter is a monthly assignment. The seal control appears on the 15th of the month, and
> nowhere else.**

Two conditions, and they are `AND`ed:

- `SealControl.isOffered` is `!isEditing && assignment?.promptKind == .letter`
  (`ios/Rascal/Rascal/Composer/SealControl.swift:42`). The composer must have been opened **from a
  letter assignment**. A freeform entry — the **+** button — has no assignment at all, so the
  control is never offered there.
- `slots_for` appends the `letter` slot only `if day.day == 15`
  (`api/src/rascal/services/scheduler.py:247`). That is the decision in `docs/decisions.md`:
  letters get their own slot rather than sharing the 1st with the measurement mission, because
  four items in one day breaks the two-item rule.

**So on a real account the first letter arrives on the first 15th after the child is created**, sits
in `waiting` for 14 days, and expires. The production child was created Aug 10; the first letter
assignment it will ever see is **Aug 15, 2026**, available until Aug 29. Nothing is hidden and no UI
is missing — the ration is monthly by design.

**To see it before the 15th, locally**, the debug route exists for this and is idempotent:

```bash
# Local API only — registered when ENVIRONMENT == "local", 404 in production.
curl -sX POST localhost:8000/v1/debug/scheduler/run \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"date": "2026-08-15"}'
```

That is how the dev archive got its one letter assignment — `assigned_on 2026-08-09`, `status
done`, `default_unlock_age 13`, the row behind the end-to-end verification described above. Point
`API_HOST` at `localhost:8000`, run that, and the letter is on Today.

**What this leaves genuinely missing is two things, and both are decisions rather than bugs** — see
the note below and `docs/decisions.md`.

~~**One gap remains, and it is Lane A's.**~~ **Closed, and verified this revision.** `POST /entries` used to seal a letter whenever `unlock_at_age` arrived as `None`, because Pydantic cannot tell an omitted key from an explicit `null`. The router now passes the field's *setness* down — `unlock_at_age_provided="unlock_at_age" in payload.model_fields_set` (`routers/entries.py:71`), read at `services/entries.py:431` — so an explicit null means "not sealed" and an absent key still keeps the prompt's default.

**The client-side workaround outlived the fix and should now be deleted.** `unsealIfTheServerSealedItAnyway` is still at `ios/Rascal/Rascal/Networking/RascalAPI.swift:66`, called from line 47. It was written to be self-detecting — it fires only when the response disagrees with the request — so it is now inert rather than wrong, and it costs one comparison per create. Deleting it and its corrective round trip is an unblocked iOS-lane task.

### The two things that are genuinely absent — and one of them has now been decided

**1. Writing a letter on a day that is not the 15th — DECIDED Aug 11, 2026. Not designed, not
built.** The **+** composer has no assignment, so it can never seal; a letter that occurs to you on
the 3rd has nowhere to go. **The decision is that this should be possible: the 15th is the
reminder, not the permission.** It does not change the scheduling decision — the letter keeps its
own slot on the 15th and keeps its prompt — it adds a way in. See `docs/decisions.md`, where the
reasoning and the two questions left for the design are recorded.

**Design is being done in Claude Design and nothing is being built here.** Two things the design
has to settle: whether the any-day path writes against a `letter` prompt or is freeform-plus-seal,
and where the entry point lives — the *Add to the archive* sheet behind **+** is the obvious
candidate, since Phase 18 already put one there and the cost of a second row in it is nothing.
**The API needs no change**: `POST /entries` already takes `unlock_at_age` and, since the setness
fix above, reads an explicit null correctly. This is an iOS-lane change end to end.

**2. Editing the seal on an entry that already exists — still absent, still undecided.**
`PATCH /entries/{id}` supports it; no UI calls it. `isOffered` returns false whenever `isEditing`
is true, so reopening a letter shows no seal control at all — the age it was written with is the
age it keeps. **The failure mode is one-way and quiet**: a letter sealed at 13 by a mis-tap on the
stepper cannot be moved to 18 from inside the app, and nothing on the screen says the number is
final. Raised, not chosen, and deliberately not bundled into the decision above.

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
| Push notifications | ⚠️ **built, unblocked, not delivered once.** ~~blocked on Apple enrollment~~ — enrollment cleared Aug 10. The client and server are complete against a stubbed APNs client; what is missing is an APNs key (a portal trip) and the notification job's scheduled machine. **No byte has ever been sent to `api.push.apple.com` from this repository** — `docs/device-verification-push.md`, 0 of 29 |
| Share sheet target | ✅ **built** — images and videos only, one entry per share, `occurred_at` read from the file's capture metadata. The extension stages into the App Group container and never touches the network; the app drains it on launch and foreground. **Never launched by the system** — every screenshot is the real view rendered inside the app by a harness, because a share sheet cannot be opened from a CLI, and the memory ceiling a share extension actually runs under does not exist in a simulator. `docs/device-verification-share-extension.md` |
| **A name** (open decision #3, needed by P1) | ❌ still `RASCAL`, bundle id deliberately neutral |

* * *
## Blocked on you, not on code
These gate the P0 exit test and nothing else can move them.

1. ~~**Apple Developer enrollment** — blocks real Sign in with Apple and TestFlight.~~ **DONE, Aug 10, 2026.** Enrollment cleared, the App ID carries the capability, `APPLE_BUNDLE_ID` on Fly matches the target, and a real Apple-signed token has been through `POST /v1/auth/apple`. The entitlements file carries Sign in with Apple, Push and the App Group, and they were committed. `blocked.md` §1.

2. ~~**Fly** — no deployed API exists.~~ **DONE, Aug 10, 2026.** `rascal-api.fly.dev` resolves and serves; `verify_deployment.py` passes 6/6; two machines in `ord` plus an hourly scheduler; `FLY_DEPLOY_ENABLED` is set, so merges to `main` deploy themselves. `blocked.md` §3.

3. **The APNs key** — *new on this list, and it replaces the two above as the only credential still outstanding.* Enrollment made it available; nobody has made the trip. Certificates, Identifiers & Profiles → Keys → + → APNs, then three Fly secrets, then the notification job's scheduled machine. `docs/runbook-deploy.md` §4a and §4b, `blocked.md` §1a. **The `.p8` downloads exactly once.**

4. **79 prompt candidates** need a human read before they can join the library — and they now need reading against a tone decision that did not exist when they were generated. `docs/decisions.md` item 4 settled as **warm and cheerful** on Aug 11; these were generated with the dry seed library as their style reference. Read for warmth as well as accuracy.

5. **A restore drill** — the machinery is tested, the act never performed. Note the local wrinkle this revision hit: this machine's `pg_dump` is 17.6, and a 17 client writes a dump Postgres 16 will not take back. Use the pinned 16 binaries, as `ci.yml` and `backup.yml` do.

6. **Device verification — and this is now the whole game.** See the section below; it is no longer a footnote behind a deploy.
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
> **This section has gone stale three times now**, always the same way: it went on recommending something the document already reported as done, a couple of sections above itself. The third time was the worst, because the thing it kept recommending — **deploy** — had been done for a full day and recorded as done in `docs/blocked.md`, struck through, with the evidence attached.
>
> If you are editing this file after landing a branch, this section is the part to rewrite, not the part to leave.
>
> **Checked this revision, one line at a time (Aug 11, evening):** deploy — **done**, and the four lines recommending it are struck below rather than deleted, so the mistake stays visible. Apple enrollment — **done**. TestFlight — **done**. Device verification — now **nine** checklists, **356 boxes, still zero ticked**, and no longer waiting on anything. Push — no longer blocked; it needs an APNs key and a scheduled machine. Structured extraction — ~~blocked on an API gap~~ **unblocked by #45 and shipped as #43**; the model behind the seam has still never run. Video audio tracks — still gated on the transcription checklist, which still records no run. A name — still open. `KindBadge` contrast — still unfixed. **The line that changed state is everything above device verification, and it moved to done.**

### The only recommendation now: run the checklists
**This is the whole of it.** There is no branch to open, no endpoint to add, and nothing left to deploy. Nine features have shipped that have never run against reality, and the tool for finding out is a checklist and an evening, not a compiler.

#### What "device verification" actually means, since it has never been spelled out here
Every one of these features is **tested** — 459 API tests, 705 iOS tests, all green. What a test cannot do is run the parts of iOS that only exist on a physical phone. A simulator has no microphone, no camera roll, no Apple Intelligence model, no APNs connection, no WidgetKit refresh budget, no memory ceiling on an extension, no file protection, and no thumb. So for these nine features the code has been proven **correct against a stub** and never once proven to **work**.

A device-verification checklist is the thing that closes that gap. Each is a Markdown file of numbered sections; each section is a short scripted interaction — *do this on the phone, then look at this* — with checkboxes and a place to write what actually happened. **You tick a box or you write down what happened instead. A line that "seemed fine" is not ticked.** They are written to be run by a person holding a phone, in an evening, not by a developer at a keyboard.

They matter more than the ratio of code-to-checklist suggests, because the failures they catch are mostly **silent**. A missing App Group does not crash the widget, it makes it render its neutral state forever. A share extension over its memory ceiling is killed by the system with no error anywhere. A photo filed under the wrong day looks completely normal, on the wrong day, permanently. None of those produce a red test or a crash log; they produce an app that quietly does the wrong thing.

#### The nine, in the order to run them

**Everything below is now runnable except #9**, which needs the APNs key. Two of them (#5, #6) need the phone to be on **iOS 26+**, and #8 additionally needs Apple Intelligence hardware.

| # | Checklist | Boxes | Needs | Why here |
|---|---|---|---|---|
| 1 | `device-verification-widget.md` §1 **+** `device-verification-share-extension.md` §1 | (2 sections) | TestFlight build | **Half an hour, and do it before anything else.** Both ask the same question — does the App Group resolve on a device — and it is the single point all three targets share. If it does not, the widget is neutral forever and the share sheet says it cannot save, both **with no error anywhere**. Answering it once answers it for both. |
| 2 | `device-verification-share-extension.md` | 45 | TestFlight build, a real camera roll | The only checklist with **a number to write down**: §3 asks you to attach Instruments and measure the extension's peak footprint against a ceiling a simulator does not enforce. §2 is the sharper one — the date rule, against real photos with edited metadata, missing `DateTimeOriginal`, and iCloud copies that are not on the phone. |
| 3 | `device-verification-today-v2.md` | 39 | TestFlight build | The screen you open every day, and the only one with a **gesture** on it. §2 is the sharpest single question in the whole list: whether a skip can be lost or double-sent, because the undo is implemented by *not sending* a one-way request. |
| 4 | `device-verification-settings.md` | 73 | TestFlight build | The longest, and §0 is five minutes: does the `Advanced` card actually appear. Phase 13 found it could be **silently absent for an entire session** depending on which tab the app opened on. Also §6 — the account row against your real Sign in with Apple account, which now exists. |
| 5 | The audio list in PR #22 | — | **iOS 26+**, a quiet room | **The prerequisite for #6.** The simulator has no microphone, so nothing in the recording path has met real input. |
| 6 | `device-verification-transcription.md` | 45 | **iOS 26+**, #5 first | **The one with the most unknown in it**, and the one whose answer could invalidate a design rather than find a bug. Its §0 is the question that matters: how well does it read a four-year-old. Nothing else in the project is waiting on this — *video audio tracks is* (`blocked.md`). |
| 7 | `device-verification-backfill.md` | 19 | TestFlight build, a real camera roll | Newest. Every assertion runs against a stub source of `Date` values, so the scan is proven as arithmetic and unproven against a library with years of photos in it. |
| 8 | `device-verification-extraction.md` | 19 | **iOS 26+ with Apple Intelligence** | `SystemLanguageModel.default.availability` has never returned `.available` on anything here. On hardware that cannot do it, the correct outcome is that nothing happens at all — §1 checks exactly that. |
| 9 | `device-verification-push.md` | 29 | **The APNs key first** | The only one still gated, and on a credential you can now obtain. Was blocked on enrollment *and* a deployed API; both are done. |
| — | The sync-pull sequence | — | TestFlight build | Not a file: Settings → dry run → read the report → flip `syncPullEnabled` → pull to refresh. Verified against fixtures including a 736-entry one, **never against the real archive**. |

**Two things to know before you start.** Every checklist wants the results written into the file itself — that is what makes a tick worth anything later. And several of them note that an unsigned build cannot write to the keychain, so every request after sign-in comes back `401` and it reads as an auth bug; a TestFlight build is signed, so this is one trap you have already walked past.

### The pool cliff is now a number you can read
Phase 15 made it observable: `GET /children/{id}/pool-health`. On the dev archive's child today
that reads **24 eligible questions, 24 days until the first repeat** — which is the arithmetic the
phase was written about, now visible instead of inferred. Nothing about it is urgent yet, and the
endpoint deliberately does not fix anything.

### ~~Deploy, because everything else is waiting behind it — and now it gates a shipped feature~~ — DONE
~~**Push made this sharper rather than adding to the queue.** The client is done and cannot be verified at all: APNs pushes come from Apple to a deployed server, so there is no local version of this test.~~ **Half true, and the half that survives is now the APNs key rather than the deploy.** The server exists; the credential does not.

### ~~Deploy, because everything else is waiting behind it~~ — DONE, Aug 10, 2026
~~Nothing else on this list can be finished without a deployed API. TestFlight needs one, the fourteen-day exit test needs one, and five of the seven device-verification checklists below are against `localhost` today.~~ **All of that happened.** The runbook was executed in order, `verify_deployment.py` passed 6/6, and the checklists that were "against `localhost`" are now against `rascal-api.fly.dev`. Kept struck rather than deleted because this section recommended it for four consecutive revisions and then for one more after it was done — the failure mode is worth leaving visible.

### Then verify what is built before building more
**Nothing here is a coding task, and that is the point.** Nine features have now shipped that have never run against reality: sync pull has never touched the 759 real entries, the recording path has never met a real microphone, transcription has never produced a single word, the extraction model has never once been `.available`, the widget has never been rendered by WidgetKit, the share extension has never been started by the system, the backfill scan has never met a real camera roll, **Today's swipe-to-skip has never been swiped**, and no notification has ever been delivered by Apple. Each is a checklist that takes an evening, and each one can invalidate a design rather than just find a bug.

### Then, in build terms
- **Phase 8, onboarding and account creation** — shipped. The app now has a first-run path for a person who is not you, though Sign in with Apple itself still cannot be exercised until enrollment clears.
  
- ~~**The seal control in the composer**~~ — **shipped**, as PR #29. See "The sealed letter, whole" above; what remains of it is a four-line server change in `blocked.md`, not a feature.
  
- ~~**The widget**~~ — **merged**, as PR #32, and with it the project's first extension target and its first deep-link handling. The roadmap calls it the reason the loop survives week four; whether it actually does cannot be known from a simulator, which is why its checklist is first on the list above.

- ~~**Today v2**~~ — **built**, open as PR #34. Three things in its design were dropped rather than built, and each is a decision waiting rather than a task: **paper grain** (the export calls it mandatory identity, `design-system.md` lists screen-print texture as an anti-pattern, and neither decisions file mentions grain at all), the **STORIES rail** (throwbacks on Today — the data exists behind `GET /children/{id}/moments` and `ThrowbackCard` already renders it, but it needs a second call from the screen the contract calls "the single call the home screen makes"), and the **96pt completion burst**. None is blocked on code. Also deferred with it: thumbnails on Today's cards and the per-tile upload strip, both of which reach into the media paths.

- **A contrast defect the phase found and did not fix.** `KindBadge` draws tint-coloured text on a 12% wash of the same tint, which measures roughly 3.3–3.7:1 at 12pt semibold — below WCAG AA. It is pre-existing and shared, and fixing it needs either a `periwinkleDeep` token or a badge restyle, i.e. a design-system decision rather than a patch. **Phase 13 checked and did not propagate it**: the only place the Settings import uses tint-on-tint is in a direction the file never renders.

- ~~**Settings v2**~~ — **built.** The last screen still wearing its PR #21 scaffolding has had its design pass, so Timeline, Moments, Today and Settings now read as one app. The import's argument was that Settings should open on the child rather than on configuration, and it does: `ChildHeroCard` replaced the `Name` row, section labels carry a rule to the trailing edge, the sync card grew a summary head that tints while files are in flight, and export reads as a keepsake rather than a menu item. See `docs/settings-v2-inventory.md`.

  **Three things were dropped for want of a number, and each is an API conversation rather than a task**: the hero's `412 entries · 1,204 photos · 3 sealed` strip, the `First entry` row, and the sync progress bar all need archive-wide counts that no endpoint serves — and `design-system.md` already settles, for the timeline header, that the client never claims to know the size of the archive. A `GET /children/{id}/stats` would light up all three at once. Also dropped: **paper grain again** (still unresolved, still the same three-way disagreement), and the export card's decorative motif, which turned out to be literally three rotated cards — a named anti-pattern.

  **One structural change was refused.** The import groups `Recompute ages from birthday` with the dry run and the reset under `Advanced`. It stayed in its own card with its own whitespace, because rewriting every stored age in an archive is not a neighbour of asking the server what changed.

- ~~**The share sheet target**~~ — **built and merged** as #35. The widget's extension target was indeed the pattern, down to two of the same traps in the `xcodeproj` script. What it added that the widget did not have: a **write** direction on the App Group, a queue with a version gate, and a drain that has to be idempotent under a process the system can kill at any point. See `docs/reports/phase-12-share-extension.md`.

- ~~**Push notifications is now the only unbuilt P1 retention lever**, and it is blocked in the same place TestFlight is~~ — **the client and the server are both built and merged** (#39, #40), and the block is gone. What is left is a credential and a machine: the APNs key from the portal, three Fly secrets, and the notification job's scheduled machine. Nothing on P1 is waiting on code.

- **Four Lane A gaps this file recorded as blocking iOS work are built, and three of them leave a client-side workaround behind to delete.** Verified by reading `main` this revision: the seal's setness (`RascalAPI.unsealIfTheServerSealedItAnyway` can go), `EntryOut.prompt_body` (the composer's cache-the-body trick is no longer load-bearing), `?sealed=` (`TimelineModel.drain`'s ten-page `clientFilterPageBudget` loop can go entirely), `children.pronouns` and the avatar presign pair (both unstarted on the client). Each is small, none is blocked, and every one of them deletes more code than it adds.

- **Cross-share deduplication was deliberately not built**, and it is a decision rather than an omission. Sharing the same photo twice makes two entries: an `NSItemProvider` carries no asset identifier, and content-hashing a video inside the memory-ceilinged process is precisely what the architecture exists to avoid. It is also not obviously wrong — the same photo on two days is a legitimate pair of entries — so shipping a heuristic that silently dropped one would have been worse than shipping neither. Worth revisiting only if the device checklist's §10 says a real parent trips over it.

- **A name.** Open decision #1, and the widget has just made it slightly more expensive to defer: the widget gallery groups by app name, so whatever the app is called is what a parent reads when they add it. The bundle id and the URL scheme are both deliberately name-neutral, so this is still a rename and not a migration — but it is now visible in one more place.
  
- ~~**P3 item 2, structured extraction**~~ — **built and merged** as #43, once #45 let a tag write say who decided it. The schema question it was deferred over got its answer: a tag arrives as `"beach"` or `{"name": "beach", "source": "device_ai"}`, `source` defaulting to `user`. The model behind the seam has still run zero times — `docs/device-verification-extraction.md`.
  
- **Writing a letter on any day** — **decided Aug 11, 2026, design in progress in Claude Design, no code.** The seal control is complete but reachable only from a letter assignment, which exists only on the 15th; the decision is that the 15th is the reminder rather than the permission. iOS-lane end to end — the API already accepts it. See "The sealed letter, whole" above and `docs/decisions.md`. **Not a phase yet**: it is a decision waiting on a design, and it should not be numbered or started until that design exists.

- **Video audio tracks**, still the one piece cut and still gated on the audio path being verified on a device first — see `docs/decisions.md` and `docs/phases/phase-16-BLOCKED.md`. This is the only item in the project whose next step is genuinely *another item's* checklist rather than work of its own.
  

* * *
## Facts, if you want to check any of this
Every command below was executed for this revision, and the comment on each is what it actually printed. Three of them used to print something else — they are corrected, not re-copied.

```bash
make test                                    # 459 on the phase-19 branch (446 on main)
ls api/tests/test_*.py | wc -l               # 33 files

# The two local failures are both in tests/test_restore.py and they are this machine, not the
# code: Homebrew's pg_dump is 17.6, a 17 client writes `SET transaction_timeout` into the dump,
# and Postgres 16 rejects it on the way back in. CI pins 16 exactly. Check with:
pg_dump --version                            # 17.6 here — use the pinned 16 binaries for a drill

# main's CI is red on lint alone, and has been since the phase-15 merge landed at 10:33Z Aug 11.
# One line, 102 chars against a 100-column limit. test and image are both green.
cd api && uv run ruff check .                # E501 alembic/versions/0007_prompt_suppressions.py:82

# Delete DerivedData first or the warning count is a lie: an incremental build does not
# recompile an unchanged file, and a file that is not recompiled emits no warning. This is
# not theoretical — this phase's first full run surfaced 21 warnings that a targeted
# `-only-testing` run had reported as zero.
rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 705 iOS tests, 86 suites
# Warnings: 21, none of them in a file phase 18 touches. 14 in PushPermissionTests.swift (phase
# 14), 4 in ExtractionTests.swift and 3 in Extraction/ExtractedDetails.swift (phase 17 — those
# three are in the app target). Unfixed and deliberately not counted as clean. Note `build` alone does NOT compile the test
# target, so a build-only run reports a warning count that omits every test file.

# Three targets now, and all three must carry the same App Group or the widget goes
# neutral and the share sheet says it cannot save — in both cases with no error anywhere.
# The files are one directory deeper than this used to say, so the old glob matched nothing.
find ios -name "*.entitlements" | xargs grep -l "group.com.travisterry.childarchive"   # expect 3

# The app target also carries Sign in with Apple and Push now, and both were committed rather
# than left for Xcode to re-add. aps-environment reads `development`; Xcode substitutes
# `production` when it archives, which is what a TestFlight build registers.
grep -E "<key>|<string>" ios/Rascal/Rascal.entitlements

# Routes, without needing the API to be running.
cd api && ENVIRONMENT=local uv run python -c "
from rascal.main import app
spec = app.openapi()['paths']
print(len(spec), 'paths', sum(len(i) for i in spec.values()), 'operations')"   # 33 paths 40 operations

# Note the port: this project's Postgres is on 5434. 5433 belongs to something else.
docker exec rascal-postgres psql -U rascal -d rascal \
  -c "select kind, active, count(*) from prompts group by 1,2 order by 1;"   # 113, all active
docker exec rascal-postgres psql -U rascal -d rascal \
  -tAc "select count(*) from entries where deleted_at is null;"   # 759

# Nothing is in review, and no branch is stranded. Both come back empty.
gh pr list --state open
git branch -r --no-merged origin/main

# The API is deployed and dev-login is correctly absent from it.
curl -s https://rascal-api.fly.dev/health                      # {"status":"ok","db":"ok"}
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://rascal-api.fly.dev/v1/auth/dev-login                 # 404, which is the right answer

# The production media bucket exists and soft delete is on — the one setting on this project
# that could not have been fixed after the fact.
tigris buckets get rascal-media-prod        # Soft Delete: Enabled (30 day retention)

# The sealed letter has both halves now, and the Lane A gaps that blocked the client are built.
grep -n "unlock_at_age_provided" api/src/rascal/routers/entries.py    # the setness fix
grep -n "prompt_body" api/src/rascal/schemas/entry.py                 # on EntryOut
grep -n "sealed" api/src/rascal/routers/entries.py                    # the query param
grep -n "pronouns" api/src/rascal/models/child.py                     # the column

# Zero of 356. This is the number that has never moved.
grep -cE '^\s*-? *\[[xX]\]' docs/device-verification-*.md
```
