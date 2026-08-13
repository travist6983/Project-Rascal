# RASCAL — where we are against the roadmap
Snapshot: **Aug 12, 2026**, written after phases 19 through 23 merged, after the forward queue (items 24–33 plus the auth bundle) was checked item by item against the code, and after a production investigation found that a shipped scheduler change has never once run. Measured against `docs/memory-app-roadmap.md`, not against memory.

Everything in this file was checked by running something — the test suites, the app's own `openapi()`, the prompts table, `gh pr list` — rather than by reading a commit message.

> **This file has a companion now: `docs/phase-queue.md`.** That one is the short list — what to do
> next, one line per item, **and you delete a line when it is done.** This one is the long form: the
> reasoning, the evidence and the greps. **Maintain both.** When something lands, delete its line
> there and correct the claim here. The two disagreeing is the failure mode this file has recorded
> six times; a queue you prune is the cheapest defence against it, because deleting a line is a
> smaller act than rewriting a paragraph and therefore actually gets done.
>
> **Aug 12, late — push notifications are delivered, and one claim below is now inverted.** The
> APNs key is minted, three Fly secrets are set, the notification job has its scheduled machine
> (`8900ddf6719058`), and a real notification reached a locked phone and deep-linked on tap:
> `HTTP/2 200` from `api.push.apple.com`, `delivered_count = 1`. Every sentence below that calls
> push "blocked", "undelivered" or "0 of 29" is stale in that direction. `docs/blocked.md` §1a has
> the evidence. **The device-verification total is no longer 0 of 409** — §0 through §3 of the push
> checklist are partly ticked, each with its evidence written in.
>
> **The scheduler finding is still live, and its symptom has moved.** `mission_b` rows now exist
> (Aug 11 and Aug 12), because `ensure_day_filled` repairs the day from the read path on current
> code. **The `mission` slot has still never once held a photo** — all-time `activity ×2, audio ×1`.
> So the visible half healed itself and the half that matters did not, which is a worse shape than
> the original finding, not a better one. **The next 5am Detroit run is the test: read the rows.**
>
> **And the flaw now has two instances rather than one.** `fly machine list` shows both non-grouped
> machines pinning their own image while the `app` group moved on:
> `185d762c643778` (scheduler) and `8900ddf6719058` (notify, created Aug 12) are both
> `grp=(none)`. The notify machine was created from the current image and is correct today; it will
> drift exactly the way the scheduler did. **Fixing one without the other buys a month.**

**What this revision is for.** The previous one closed with a two-item recommendation and a forward queue formed in conversation rather than against the tree. Every item on that queue has now been read against `main` — not against this file, and not against the PR titles — and the results are in **"The forward queue, verified"** below. **Four of the fifteen are already shipped and were still being carried as work; one is a request to reverse a decision `docs/decisions.md` settled on Aug 11; and one has a premise that a production run has since inverted.** The stale claims those findings falsify are corrected in place throughout, each with the line that was wrong quoted next to it.

**One thing here is not a code status and should be read first.** `docs/roadmap-status.md` has now been wrong in the same direction five revisions running: it reports work as outstanding after it landed. This revision found four more instances of it (§ "The four Lane A deletions"), all pointing at code deleted in PR #48 on Aug 11. **The fix is not more diligence, it is that a shipped-status claim in this file should carry the grep that proves it** — so the ones added below do.

**Every figure in this file was re-derived again, and this time the drift was on the other side.** The API figures — 480 tests in 34 files, 40 operations across 33 paths, 113 prompts — came back **identical**, because phases 20 through 23 were all iOS-lane. The iOS suite moved by 87 tests and 14 suites in a single day. The entry count went 759 → 763, and the checklist count went from a wrong 356 to a measured 409.

> **The two corrections the previous revisions existed to make, kept for the pattern they form.**
> **Aug 11:** this file reported Apple enrollment and Fly as blocking everything for a full day
> after `docs/blocked.md` had recorded both resolved, struck through, with evidence attached. Two
> documents disagreed and the older claim was the one being read.
> **Aug 12 (this one):** four Lane A workarounds were listed as needing deletion for a day after
> PR #48 deleted them, and Entry Detail v2 was described as "inventoried, not built" within an hour
> of merging as #54.
> **The pattern across both is one thing: this file trails `main` by about a day and always in the
> same direction — work reported as outstanding after it landed.** That is why every shipped claim
> below now carries its own grep.

* * *
## The headline
**The app is on TestFlight, against a deployed API.** Sign in with Apple runs against a real Apple-signed token, media uploads land in a production bucket from a phone in the world, and 55 pull requests have merged.

**~~Nothing is open.~~ One thing is open, and it is the most important sentence in this file.** PR **#57**, `investigation/missing-photo-slot`, is a read-only production investigation opened Aug 12, and its finding is that **the daily photo slot has never been served, not once, since Phase 19 shipped it.** The hourly Fly scheduler machine `185d762c643778` has **no process group**, so `fly deploy` has never updated it; it is still running the image from release v1 at `2026-08-11T00:20:22Z`, built about 22 hours before Phase 19's code existed. It creates two slots a day instead of three and fills `mission` from all five mission kinds. Production bears it out: the all-time contents of the `mission` slot are `activity ×2, audio ×1` — **zero photos, ever.**

**That is a new failure class and it deserves a name: a deploy that is green everywhere and still does not reach the machine that does the work.** `FLY_DEPLOY_ENABLED` is set, the Deploy runs are green, `/health` is green, the tests are green, and the API is genuinely serving the new code — from the app machines. The scheduler is a fourth machine outside the process group, and nothing in CI, in the runbook, or in this file could have told you it had gone stale, because every signal any of them reads was reporting on a different machine. **Verify a scheduled job by reading what it produced, not by reading the deploy that was supposed to update it.**

**A second, independent cause is live alongside it**, and fixing the scheduler will not fix it: the installed TestFlight build predates `3df6cd4`, so it decodes `mission_b` as an unknown slot and renders it grey and "Still open" (`ios/Rascal/Rascal/Models/TodayResponse.swift:90`). Two causes, one symptom, and each needs its own fix — an operational one and a build.

**The shape of the work has changed, and this is the sentence to carry out of this file.** For eight revisions the answer to "what next" was *deploy, because everything is behind it*. Deploying is done. **What is in front of you now is not a build queue, it is a verification backlog: eleven device checklists, 409 checkboxes, zero ticked.** Nothing on that list is a coding task, and all of it is runnable tonight.

**PR #57 is what that backlog looks like when it goes unrun.** A feature shipped, deployed green, and produced nothing for a day and a half, and it was found by someone looking at a screenshot rather than by any of the instruments this project has built. **The checklists are not paperwork behind the real work; they are the only instrument that reads the thing the tests cannot see.**

**The day is three items now, not two, and the photo pool is the thing to watch.** Phase 19 split the daily `mission` slot: `mission` draws photo only, and a new `mission_b` takes the video, audio and activity kinds it used to share. The old pairing meant one coin flip decided whether a parent was asked for a photo — the artifact the archive is mostly made of — or asked to record his voice; now both get asked for every day. Weekly, monthly and letter fire on top rather than instead, so a Saturday is four items and a Saturday that is also the 15th is five. **`mission` keeps its name while its meaning narrows**, so pre-`0008` rows hold non-photo prompts in `mission` and are correct for the day they were served — `docs/decisions.md` says so in those words, because the first person to find one will otherwise read it as a bug.

**~~The measured cost, from `GET /pool-health`:~~ at 49 months the question pool lasts 30 days, `mission_b` 37, and `mission` 20 — ~~cooldown relaxation begins 2026-08-31.~~** **The 20 is real; the date is not, and the priority it implied was backwards.** `_estimate_days` (`services/pool_health.py:138-146`) multiplies the available count by `SERVE_INTERVAL_DAYS["mission"] = 1`, i.e. it assumes the slot is served once a day. **It has been served zero times a day.** Production reads `served_within_cooldown=0` and `relaxation_active=False` for `mission`/`photo`: the countdown has not started, and nothing relaxes on Aug 31. The Aug 31 date was never a number from the API — it was this file adding 20 to its own snapshot date, which is exactly the arithmetic the sentence claimed not to be doing.

**So the photo pool is not the thin half. It is the healthiest daily pool in the archive** — 20 of 20 available, none on cooldown, `slots_exhausted: 0` in the scheduler's own logs. **The fix is operational, not editorial.** Authoring photo prompts changes nothing observable until the scheduler machine can see the photo-only narrowing at all. Once it can, the 20-day estimate starts counting from that day — so the authoring task is real, just not first, and not urgent yet.

**The camera-roll backfill is complete — engine and surface — and merged as #44.** Since the last snapshot: the share sheet (#35), Settings v2 (#37), push notifications (#39, #40), prompt-pool durability (#41), structured extraction (#43, #45), and video audio tracks (#42) which merged **blocked** and is documented as such.

**~~`main`'s CI is red right now, and it is one line.~~ Fixed, and it was six files rather than one.** The recorded `E501` at `api/alembic/versions/0007_prompt_suppressions.py:82` was real and was what the job reported. It was not the whole of it: wrapping it revealed **five more `ruff format` failures behind it** — `models/prompt.py`, `schemas/prompt.py`, `services/pool_health.py`, `services/scheduler.py` and `tests/test_entry_tag_source.py`. **Two branches found this independently, and the same structural cause sits in two places:** `make lint` runs `ruff check` before `ruff format --check` as two recipe lines, and `ci.yml` runs them as two separate steps — both abort at the first failure, so the format check had never executed on `main` at all. Fixing only the named line would have advanced the job one step and failed it there. All six landed in phase 19's first commit. **A recorded, deliberately-unfixed failure stops being a known quantity the moment it can mask another one** — and the lesson is the step ordering rather than the line: a lint job that stops at its first failing step reports its first problem, not its problems.

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

**The scope gap that no phase ever owned is closed.** Sealed letters can now be written as well as read — see "The sealed letter, whole" below. ~~What is left of it is a four-line server change.~~ **That server change landed on Aug 11** (`routers/entries.py:71`, `services/entries.py:431`), and so did the client deletion that followed it. What is left of the sealed letter is two *decisions* — writing one on a day that is not the 15th, and editing a seal after the fact — and neither is a server change.

**The two things only you could unblock are unblocked.** ~~Apple enrollment~~ and ~~Fly~~ both closed on Aug 10. What is left is the exit test — you using it for fourteen days — and the verification backlog that now stands between the code and any claim that it works.

**Deploying is done, not documented-as-doable.** `https://rascal-api.fly.dev` serves, `/health` returns `{"status":"ok","db":"ok"}` (checked again while writing this), `dev-login` correctly 404s in production, and `scripts/verify_deployment.py` passed **6/6** against it — including the Tigris round trip that had never once succeeded anywhere. Two machines in `ord`, an hourly scheduler machine beside them. `FLY_DEPLOY_ENABLED` is set: pushes to `main` deploy on their own, and the last four Deploy runs are green. `ios/Rascal/Config.xcconfig` points the client at `rascal-api.fly.dev` over HTTPS, which is what a TestFlight build is talking to.

**Two things the first real deployment broke are in `docs/runbook-deploy.md` §9**, both silent, both fixed: `deploy.yml` failed a healthy deploy over a status string (`succeeded` vs flyctl's `complete`), and the runbook's `fly machine run` built a machine that ran the API server instead of the scheduler.

|     |     |
| --- | --- |
| Merged pull requests | **55**, and **one is open** — #57, the photo-slot investigation, which is read-only and merges no code. Eleven merged since the last snapshot: Phase 19's three missions (#46) and its Lane A cleanup (#48), Phase 20's TestFlight defects (#47) and its pronouns (#52), the docs close-out (#50), the export HTML viewer (#49), the push investigation (#51), Phase 21 avatar durability (#53), Phase 22 Entry Detail v2 (#54), the seal assertion (#55) and Phase 23 personalization (#56). One PR remains **closed unmerged** — #38, the first push-server attempt, superseded by #39 |
| API tests | **480 collected, 478 passing**, 34 files — re-run for this revision against the local Postgres on 5434. The two failures are both `tests/test_restore.py` and they are **this machine, not the code**: Homebrew's `pg_dump` is 17.6 and a 17 client writes a dump Postgres 16 refuses. CI pins 16 and is green. Unchanged from the last snapshot, which is itself worth noting — phases 20 through 23 were all iOS-lane and touched no API test |
| iOS tests | **860 passing, 108 suites**, green, re-measured Aug 12 after PR #59 merged. **The 801/101 in the previous revision was already stale when written** — five of the 59 new tests are the `prompt_body` decode added Aug 12; the other 54 landed with phase 22's fidelity work and were never counted. **The warning count is deliberately not restated here**: this run was warm, and a warm build does not recompile an unchanged file, so it reported 0 against a tree the last cold run measured at 21. Delete `DerivedData` before quoting that number — it is wrong in the flattering direction, which is the direction nobody checks |
| Live API operations | **40 across 33 paths** (incl. `/health`, `dev-login`, and the local-only debug routes) — **re-derived and unchanged.** Four consecutive iOS-lane phases added no route |
| Prompt library | **113 authored, 113 active** — unchanged since Aug 9. By kind: 30 question, 25 activity, 23 photo, 12 audio, 12 video, 8 letter, 3 measurement. **0 of the 113 bodies carry a `{token}`; 99 say `he`, `him` or `his` literally.** That is by decision, not by omission — see item 24 below |
| Prompt candidates awaiting your review | **79** — unchanged since Aug 4, carrying a tone decision they were not generated under, and **all 79 are `question` kind.** There are zero photo candidates, so the authoring backlog cannot help the photo slot even after it is fixed |
| Entries in the dev archive | **763** |
| Device-verification checkboxes ticked | **9 of 409**, across **eleven** checklists — re-counted Aug 12 with the greps at the foot of this file. **This is the first time this figure has ever moved**, and all nine are `device-verification-push.md` §0–§3, each with its evidence written into the line. The 409 is unchanged: phase 22 added Entry Detail (28) and phase 23 added personalization (25), and the old ten-checklist figure had never counted Moments (44) or the whole widget list (43) |

**This time the API-side figures held and the iOS ones moved, which is the mirror of last revision.** Four consecutive phases (20, 21, 22, 23) were iOS-lane, so the route count, the test count and the prompt library are all unchanged — re-derived rather than assumed, and they came back identical. The iOS suite moved by 87 tests and 14 suites in a day. The lesson from last time still applies in reverse: **a figure is not stale because time passed, it is stale because something touched it**, and the only way to tell which is to run it.

**Two figures in this table are new kinds of number, not new values.** The prompt-library row now carries the token count, because "113 active" was true and uninformative while every one of those bodies misgenders a she/her child. The candidates row now carries the kind breakdown, because "79 waiting" read like a reserve that could be drawn on for the photo slot, and it cannot be — they are all questions.

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
| **P2 — Family** | Sep 14 – Oct 9 | **Corrected this revision — it was wrong in both directions.** Authorization is genuinely built: `deps.py:106-125` enforces a two-role `guardians` table on every route. But ~~"only the invite flow is missing"~~ is false — **per-entry visibility is also missing, and unlike the invite flow it is not even designed** (`docs/data-model.md`'s `entries` spec has no visibility column). And the tested `viewer` role is unreachable: **no route anywhere writes `role="viewer"`** (`routers/children.py:85` writes only `parent`), so it is enforced code that nothing can enter. Multi-kid, meanwhile, is further along than "not started" — see item 31 |
| **P3 — Intelligence** | Oct 12 – Nov 6 | **Corrected this revision; the old line was wrong on three counts and contradicted this same file.** ~~"Item 1 built, items 2–5 not started"~~ → **items 1, 2, 3 and 4 are built and none has run on real hardware.** 1 transcription (#26), 2 structured extraction (#43), 3 the camera-roll backfill (#44), 4 device-side personalization (#56). **Item 5, photo captioning, is server-side only**: `PATCH /media/{id}/derived` accepts and persists `caption`, it is in the FTS vector and it travels in the export — the client has no generator, no queue, no UI, and `RascalAPI.writeDerived` sends transcript only, by explicit design comment |
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
| **11 (the other one) — Today v2** | The Today board rebuilt against its own design export. New compact waiting and done cards, ~~a child switcher~~ **a child switcher *pill*** — see below — swipe-to-skip with a held-request undo, and the board extracted into a previewable `TodayBoardView` | #34 | ✅ merged |
| **12 — The share sheet** | A Share Extension target, the App Group staging queue it writes, and the drain in the app that turns it into entries through the existing pipeline. EXIF-derived `occurred_at`, one entry per share | #35 | ✅ merged |
| **ops** | The two things the first real deploy broke | #36 | ✅ merged |
| **13 — Settings v2** | The screen opens on the child; the card that could vanish | #37 | ✅ merged |
| **14 — Push notifications** | One notification a day, the server owning the schedule, and four things it could not have survived in production | #39, #40 | ✅ merged |
| **15 — Prompt pool durability** | Suppression outranks every relaxation rule, including an empty pool | #41 | ✅ merged |
| **16 — Video audio tracks** | Blocked on arrival; see `docs/phases/phase-16-BLOCKED.md` | #42 | ⛔ merged blocked |
| **17 — Structured extraction** | Plus #45, which let a tag write say who decided it | #43, #45 | ✅ merged |
| **18 — Camera-roll backfill** | The engine (scan, clustering, dismissal, caching, the `occurred_at` rule) **and** the surface: an *Add to the archive* sheet behind **+**, a permission explainer, suggestions, an every-month browse list, a day-grouped picker, and a prefilled composer | #44 | ✅ merged |
| **19 — Three missions a day** | The daily `mission` slot split: `mission` narrows to photo only, `mission_b` takes video, audio and activity. Lane A | #46 | ✅ merged — **and never once executed in production**, see the headline |
| **19 (the other one) — Lane A cleanup** | Deleted three client workarounds the server had made unnecessary: the unseal round trip, the ten-page sealed filter loop, and one prompt-body lookup | #48 | ✅ merged |
| **20 — TestFlight defects** | Nine defects from the first two days of real use | #47 | ✅ merged |
| **20 (the other one) — Pronouns** | `children.pronouns` collected in onboarding and editable in Settings, plus `PromptTokens` — a thirteen-token substituting renderer wired at nine call sites | #52 | ✅ merged |
| **21 — Avatar durability** | The avatar reaches the archive: the child-scoped presign pair the client had been blocked on | #53 | ✅ merged |
| **22 — Entry Detail v2** | The screen rebuilt against its own design export. Full-bleed media, the cream sheet, per-shape backdrops | #54 | ✅ merged |
| **22 (addendum) — The seal assertion** | Tests only: a sealed fixture carrying a body, a photo, a transcript and tags, asserted against all six places the card model branches on `sealed`, plus a negative control | #55 | ✅ merged |
| **23 — Device-side personalization** | One `PersonalizationCenter` above every tab; canonical text synchronous and immediate, the model requested in a `.task` no board waits on; six validation rules; never persisted, structurally | #56 | ✅ merged |

**The child switcher shipped as a label, and the ledger said "switcher" for a day.** `ChildSwitcherPill` renders its chevron and its tap target only when `onSelect` is non-nil, and `onSwitchChild` is supplied **only in `TodayBoardPreviews.swift`** — the real construction at `TodayScreen.swift:259-286` passes thirteen closures and not that one. So the component is correct and the app has no switching. This is not a defect: `ChildSwitcherPill.swift:11-13` says so out loud — *"One child and a chevron is a control that lies"* — and `ios/CLAUDE.md` scopes multi-kid UI out. **It is a ledger problem**, and it is the same shape as the four Lane A deletions: a row that describes the component rather than what a parent can do.

**Two numbering hazards worth naming, because both have already caused a wrong assumption.**

- **"Phase 3" means two different things.** In the iOS build order it is the media *read* path, which landed inside PR #11. PR #18 is *titled* "Phase 3" and is video *capture*. Both shipped; only the label is ambiguous.
- **The onboarding branch was misnamed and landed that way.** `ios/phase-5-onboarding` was the working branch for phase **8**; phase 5 was audio, three PRs earlier. It merged under the wrong name, so the history does now read as though audio were reopened. Nothing to undo — just do not trust the branch name in `git log`.
- **"Phase 11" now means two different things too.** The widget is phase 11 and merged as #32; Today v2 was *also* specified as phase 11 and is open as #34. The two share nothing but the number. The build order is the table above, not the labels — **and the next phase specified takes the number after the highest already merged, which is 20 as of Aug 11, 2026, so the next is 21.**

  > **This sentence has now gone stale twice, which is the actual lesson.** It said "should be numbered 12" while phases 12 through 20 merged underneath it, so anyone reading the file as context — a person or an agent — would have minted `phase-12` and collided with seven merged phases. Re-stating it with a new absolute number only resets the clock. **A phase prompt should measure `main` directly rather than quote a status document's count**, and the number above is a convenience that is expected to rot.

  > **The existing collisions are not being renumbered.** Phase 3 means both the media read path and video capture; phase 11 means both the widget and Today v2; phase 19 means both the three-missions split and the Lane A cleanup; phase 20 means both the nine TestFlight defects and pronouns. Those PRs are merged and the history is written — renaming a merged phase would produce a ledger that disagrees with every PR title and commit message in the repo. The ledger stays the disambiguator.

  > **The highest merged phase is 23 (PR #56), so the next specified phase is 24 — measured from `main` on Aug 12, 2026, and expected to rot.** The paragraph above already went stale twice by quoting a number; this is the third quotation of it and it will go stale the same way. **Measure `main` rather than trusting this line.**

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

~~**The client-side workaround outlived the fix and should now be deleted.** `unsealIfTheServerSealedItAnyway` is still at `RascalAPI.swift:66`, called from line 47.~~ **Deleted in PR #48 on Aug 11 — before the revision that wrote this paragraph as outstanding work.** `POST /v1/entries` is a single request again. The claim is cheap to check, which is the point: `grep -rn "unsealIfTheServerSealedItAnyway" ios/` returns exactly **one** hit, `ios/Rascal/Rascal/Models/Entry.swift:270`, and it is inside a `///` doc comment describing the history.

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
| Push notifications | ✅ **delivered, Aug 12, 2026.** ~~blocked on Apple enrollment~~, ~~built but never delivered~~ — the key is minted, the three Fly secrets are set, the job has its scheduled machine, and a real notification reached a locked phone and deep-linked on tap. `HTTP/2 200` from `api.push.apple.com`, `delivered_count = 1`. **The sandbox/production split is confirmed correct as a side effect** — a sandbox token on the production host would have been rejected. `docs/device-verification-push.md` §0–§3 partly ticked; §4–§7 unrun |
| Share sheet target | ✅ **built** — images and videos only, one entry per share, `occurred_at` read from the file's capture metadata. The extension stages into the App Group container and never touches the network; the app drains it on launch and foreground. **Never launched by the system** — every screenshot is the real view rendered inside the app by a harness, because a share sheet cannot be opened from a CLI, and the memory ceiling a share extension actually runs under does not exist in a simulator. `docs/device-verification-share-extension.md` |
| **A name** (open decision #1, needed by P1) | ✅ **`Dogear`, decided Aug 12, 2026.** ~~still `RASCAL`~~ — the placeholder is retired and this was the last open item in `decisions.md`. The bundle id was chosen name-neutral for exactly this, so it is a rename and not a migration; **none of the rename is done yet**, and the display name and the widget gallery are the two that a parent actually reads |

* * *
## Blocked on you, not on code
These gate the P0 exit test and nothing else can move them.

1. ~~**Apple Developer enrollment** — blocks real Sign in with Apple and TestFlight.~~ **DONE, Aug 10, 2026.** Enrollment cleared, the App ID carries the capability, `APPLE_BUNDLE_ID` on Fly matches the target, and a real Apple-signed token has been through `POST /v1/auth/apple`. The entitlements file carries Sign in with Apple, Push and the App Group, and they were committed. `blocked.md` §1.

2. ~~**Fly** — no deployed API exists.~~ **DONE, Aug 10, 2026, with one thing this line got wrong for two days.** `rascal-api.fly.dev` resolves and serves; `verify_deployment.py` passes 6/6; `FLY_DEPLOY_ENABLED` is set, so merges to `main` deploy themselves. **But "two machines in `ord` plus an hourly scheduler" reads as three machines that deploy together, and they do not** — the scheduler has no process group, so `fly deploy` has never touched it. See the headline and PR #57. **The credential is not the blocker here; the machine topology is**, and it needs `flyctl` in your hands. `blocked.md` §3.

3. ~~**The APNs key**~~ — **DONE, Aug 12, 2026, and it was two things rather than one.** The key was minted and the secrets set, *and* the notification job's scheduled machine was created — and **either one missing produces the identical symptom**: every phone silent, API green, nothing in any log. The app had run for over a day with the scheduler machine present and the notify machine absent, and no signal anywhere said half the pair was missing. **`notification_sends` being empty rather than full of `delivered_count = 0` rows is what distinguishes the two causes.** `blocked.md` §1a.

4. **79 prompt candidates** need a human read before they can join the library — and they now need reading against a tone decision that did not exist when they were generated. `docs/decisions.md` item 4 settled as **warm and cheerful** on Aug 11; these were generated with the dry seed library as their style reference. Read for warmth as well as accuracy.

5. **A restore drill** — the machinery is tested, the act never performed. Note the local wrinkle this revision hit: this machine's `pg_dump` is 17.6, and a 17 client writes a dump Postgres 16 will not take back. Use the pinned 16 binaries, as `ci.yml` and `backup.yml` do.

6. **Device verification — and this is now the whole game.** See the section below; it is no longer a footnote behind a deploy.

7. **The scheduler machine** — *new on this list, Aug 12, and it is the only one here where something is actively going wrong every morning.* It needs an authenticated `flyctl`, which is why it is on this list rather than in a phase: either recreate machine `185d762c643778` inside the app's machine set, or give `api/fly.toml` a `scheduler` process group so deploys reach it. **Then check what it produced, not that the deploy went green** — that distinction is the whole finding. PR #57 §6 has the fix and deliberately stops short of applying it. **Ship an iOS build in the same pass**, or `mission_b` keeps rendering as an unknown slot regardless.

8. **Item 24 is a decision, not a task** — whether to reverse `decisions.md`'s "the 113 seeded prompts are not rewritten." Nobody but you can make that call, and until it is made the highest-consequence item on the queue cannot be scheduled either way. See the section below for both sides and the three costs the framing hides.
  

~~One small ask for whoever next touches `api/`: **there is no** `GET /me`.~~ **Done.** `GET /me` exists, the client persists the user record between launches, and it refreshes on every launch that has a network. A force quit no longer loses your own name.

* * *
## Recommended next phase
> **This section has gone stale three times now**, always the same way: it went on recommending something the document already reported as done, a couple of sections above itself. The third time was the worst, because the thing it kept recommending — **deploy** — had been done for a full day and recorded as done in `docs/blocked.md`, struck through, with the evidence attached.
>
> If you are editing this file after landing a branch, this section is the part to rewrite, not the part to leave.
>
> **Checked this revision, one line at a time (Aug 12):** deploy — **done for the app machines and never once done for the scheduler**, which is the headline. Apple enrollment — **done**. TestFlight — **done**, and the installed build is now old enough to render `mission_b` as unknown. Device verification — now **eleven** checklists, ~~409 boxes, still zero ticked~~ **9 of 409, moved for the first time on Aug 12**. Push — ~~still needs an APNs key and a scheduled machine~~ **both done, and a real notification was delivered**. A name — ~~still open~~ **`Dogear`, and it was the last open decision**. `KindBadge` contrast — ~~still unfixed~~ **fixed, along with the two chip pairings that shared the defect; sage is a recorded exception**. **Entry Detail v2 — ~~inventoried, not built~~ built and merged as #54, and its design answer came back**; that line was wrong on both counts within an hour of being written.

### The forward queue, verified

**Every item below was read against `main` rather than against this file, by an agent per item with
an adversarial second pass over every "shipped" claim. Fifteen items; four turned out to be already
done, one contradicts a settled decision, one has an inverted premise.** Verdicts are: **✅ shipped**,
**◐ partial** (one half exists, the other is named), **○ not started**, **◇ decided, no code**.

| # | Item | ? | Where it actually stands |
|---|---|:-:|---|
| **24** | Tokenize the prompt library | ○ | **Confirmed exactly as stated — 113 bodies, 0 tokens, 99 literal `he/him/his` — but read the next section before starting it.** Two corrections to the framing: the contract is **thirteen** tokens, not fourteen, and `PromptTokens.render` is **not** an identity function — it is a real substituting parser wired at **nine** production call sites (`PromptTokens.swift:67-107`). It is an identity function only *in effect*, because no seeded body contains a brace |
| **25** | Author photo prompts | ○ | **Nothing authored — the seed file has not changed since Aug 9 — and the premise is inverted.** The photo pool is the *healthiest* daily pool in the archive (20 of 20 available, 0 on cooldown). It is not thin; it is **unreachable**, because the scheduler machine cannot see the photo-only narrowing. Fix PR #57 first, then this becomes real. Note also there are **zero photo candidates** among the 79 |
| **26** | Entry Detail v2 | ✅ | **Shipped as #54 and live from both Timeline and Moments.** The design answer came back — full-bleed permitted on this screen only (`design-system.md:607`), paper grain settled as rejected (`decisions.md:172`). **What is left is not code:** 0 of 28 checklist boxes, and the checklist's own premise was inverted — written 22:15, redesign merged 22:45 the same evening, so "run it before the redesign" never happened. It also still describes v1 and its header says 22 boxes when there are 28 |
| **27** | Letter on any day | ◇ | **Decided, still no code, and "the API needs nothing" holds.** `SealControl.isOffered` still requires a `letter` assignment; `slots_for` still mints that slot only on the 15th. The two design questions from `decisions.md:95` are still the blockers. **The companion gap is one field further along than this file said**: `EntryChanges.unlockAtAge` already exists at `TimelineAPI.swift:118` and is simply never set, so editing a seal is a dead seam rather than a missing type |
| **28** | `GET /children/{id}/stats` | ○ | **Nothing exists** — no route, schema, service, contract entry or consumer. `grep stats api/src/rascal/routers/*.py` hits only export headers. The three Settings surfaces are still dropped for want of it. Model it on `pool-health` (`routers/children.py:303`), which is the same shape behind the same `child_access("viewer")` |
| **29** | Lane A cleanup deletions | ✅◐ | **Three of the four are already done — see below.** This was the single largest source of stale work in the file |
| **30** | Guardian invites + viewer role | ◐ | Authorization built and enforced; **no route can create a `viewer` row**, no invite mechanism of any kind exists, and **per-entry visibility is undesigned**, not merely unbuilt. Design it before scheduling it |
| **31** | Multi-kid | ◐ | **The stated cost is wrong.** Per-child scheduling was paid in migration `0001` and has been the implementation ever since — `scheduler.py:433-450` loops every child in their own timezone, proven with two children at `test_scheduler.py:225`. **The real cost is entirely iOS**: the child is hardcoded to `.first` in three places, and the shipped switcher pill is **a label** — `onSwitchChild` is supplied only in previews, so what went to TestFlight has no chevron and no tap target. Also needs `ios/CLAUDE.md`'s scope rule changed first |
| **32** | Year One book | ○ | Nothing. The export is the shared half, but **all five of the book's own problems are untouched** — year scoping (the export endpoint takes no date), print layout, PDF generation, QR substitution for A/V, and the public playback surface those QRs resolve to, which would be a web surface this API has never had |
| **33** | Photo captioning | ◐ | **The server half is complete and was being carried as "not started."** Route, schema, persistence, FTS weighting, sync wire and export all carry `caption`. The device half is absent entirely, and the two existing on-device seams **take text, not pixels** — so it needs a third protocol, not a widened one |
| **auth** | Credential linking | ○ | No route, no service function. The schema has always supported N credentials per user; the one code path that writes one **always mints a new user** instead of attaching |
| **auth** | `aud` allowlist | ○ | Still a single string compared for equality. **Setting a comma-separated value today would reject every real Apple token.** One line at `services/apple.py:89` once `config.py:70` parses — but note `resolved_apns_topic` falls back to that same field |
| **auth** | Google sign-in | ○ | Zero code in either lane. The CHECK constraint has permitted `google` since `0001`. **The milestone framing is misleading**: without linking first, Google produces second, disconnected `users` rows |
| **auth** | Apple revocation | ◐ | **The client half shipped and is genuinely wired** — `getCredentialState` runs on every launch and signs out on `.revoked`, with three tests. **The server-to-server endpoint does not exist in any form**, so "not registered" follows from "no route." Consequence: revoke while the app is closed and the server session lives until the refresh token expires |
| **auth** | Facebook/Meta | ✅ **written down Aug 12, 2026** | ~~The rejection is written down nowhere~~ — it is now a row in `decisions.md`'s "Rejected — do not revisit", in the terms the decision actually rests on: the product's, not the protocol's. Routing a private record of a child through an ad-tech company contradicts the thing being sold; Apple is primary and Google is the planned second because it is the credential a non-Apple household already has, and neither argument extends to Meta. **Reversible at no schema cost** — the `credentials` CHECK has never listed `meta`, and rule 2 means adding it would need no migration |

#### Item 24 contradicts a decision this project settled on Aug 11, and that needs deciding before it is scheduled

**`docs/decisions.md:56` settles the opposite of item 24, in these words:** *"Tokenised and literal
prompts coexist permanently. The 113 seeded prompts are not rewritten — settled Aug 11, 2026."*
The same rule is restated at `docs/mission-library.md:265` (**"Do not bulk-rewrite the library;
write new prompts with tokens"**) and again in the repo's own `CLAUDE.md`. `CLAUDE.md` also says
`decisions.md` is settled and is not to be relitigated.

**Both positions are defensible and this file is not the place to pick.** The decision's reasoning
is that a bulk edit of serving content is large, risky and low-value, and that `test_seeding.py`
pins a coverage table a sweeping edit would have to be reconciled with by hand. **The counter-argument
is the one phase 23 raised and it is not weak**: the decision's premise is that the library renders
"exactly as it does today, forever" — which is true, and what it renders today is `he/him` to a
she/her child, on every screen, permanently. Byte-identical is the goal only if the bytes are right.

**Three costs the item as written does not mention**, all of which belong in whatever decides this:

- **The yaml is generated.** `api/seeds/prompts.yaml:1-3` says so — the authoring surface is
  `docs/mission-library.md`, regenerated through `scripts/mission_library_to_yaml.py`. "One pass over
  `prompts.yaml`" edits the wrong file.
- **Re-seeding rewritten bodies does not update rows, it inserts new ones.** `services/seeding.py:62-69`
  keys idempotency on `sha256(kind, cadence, body)` and the loader **never deletes**. Changing 113
  bodies inserts 113 new prompts and leaves the 113 literal ones `active`, so the pool serves both
  until someone deactivates the old set by hand.
- **The export viewer would print raw braces.** `export_viewer/assets/app.js:487` renders
  `prompt.body` with no substitution and notes the manifest carries no pronouns, so a tokenized
  library shows literal `{their}` in every exported archive until the viewer implements the table.
  The rendering contract says *every client renders* — there are currently two clients and one of
  them does not.

**A narrower option exists that no one has costed**: tokenize only the 30-odd bodies whose
misgendering is most visible (Today's three daily slots), leave the rest, and let the coexistence
decision stand as written. It is not obviously right — but it is the option the binary framing hides.

#### The four Lane A deletions — three are done, and this file asked for them anyway

**This is the fifth revision in a row to carry work that had already landed, and the cause is the
same every time**: PRs #48 and #52 merged on Aug 11 and no document was updated to match them. Each
verdict below is one grep, so the next reader does not have to trust this paragraph either.

| # | Deletion | ? | Proof |
|---|---|:-:|---|
| 29a | `unsealIfTheServerSealedItAnyway` | ✅ **gone** | `grep -rn "unsealIfTheServerSealedItAnyway" ios/` → 1 hit, `Models/Entry.swift:270`, inside a `///` comment |
| 29b | The composer's cache-the-body trick | ✅ **closed Aug 12, both halves** | **The decode landed and the composer write is deliberately kept.** `EntryResponse` now decodes `prompt_body`, `applyServerResponse` writes it conditionally so a list response cannot blank what the detail fetch cached, and the detail `prompt` wins where both arrive so body and kind never come off different responses. Five tests, three of which fail if the decode line is removed — verified by removing it. **The composer write stays**: the decode covers rows the server has answered for, and the composer covers the unbounded gap between Save and the first successful list fetch. **The finding underneath this is the one to keep** — PR #48 deleted the assignment-lookup fallback on the grounds that `EntryOut` carries `prompt_body`, which it did, but nothing decoded it, so for a day the server sent the sentence and the client dropped it. *The server carrying a value is half of an answer* |
| 29c | The ten-page client filter loop | ✅ **gone** | `grep -rn "clientFilterPageBudget" ios/` → **zero hits**. The Sealed chip sends `?sealed=true` on the wire |
| 29d | Pronouns in onboarding | ✅ **shipped, all three halves** | Collected in `Onboarding/ChildSetupFlow.swift`, edited in `Settings/EditChildSheet.swift` with an explicit-null clear, and fed to both the token renderer and the personalizer. **One gap worth naming**: no test asserts the `pronouns` key actually appears in the `POST /children` body — that wiring is verified by reading, not by an assertion |

#### So, three recommendations

**1. Fix the scheduler machine.** It is the only item here where a shipped feature is silently not
running in production, and every day it stays broken is a day of the archive with no photo prompt
in it — unrecoverable, because the day passes. PR #57 has the diagnosis and stops short of the fix
on purpose. **Ship an iOS build alongside it**, or `mission_b` keeps rendering grey.

**2. Run the checklists.** Unchanged, still the larger body of work, and now **eleven** of them —
409 boxes, none ticked. Entry Detail's is the newest and the one whose window has already been
missed once.

**3. Decide item 24 rather than scheduling it.** It is the highest-consequence item on the queue
and it is currently a contradiction, not a task. The section above lays out both sides.

> **A note for whoever rewrites this next.** The failure mode has now repeated five times and it is
> always the same: **this file reports work as outstanding after it landed.** The countermeasure this
> revision adopted is in the tables above — **every shipped claim carries the grep that proves it.**
> A claim you cannot check in one command is a claim that will go stale without anyone noticing. If
> you add an item here, add its check with it.

#### What "device verification" actually means, since it has never been spelled out here
Every one of these features is **tested** — 480 API tests, 801 iOS tests, all green. What a test cannot do is run the parts of iOS that only exist on a physical phone. A simulator has no microphone, no camera roll, no Apple Intelligence model, no APNs connection, no WidgetKit refresh budget, no memory ceiling on an extension, no file protection, and no thumb. So for these eleven features the code has been proven **correct against a stub** and never once proven to **work**.

**The photo-slot investigation is the argument for this section, made in production rather than in the abstract.** Phase 19 was tested, reviewed, merged and deployed, and it has produced nothing. No test could have caught it, because the defect is not in the code — it is in which machine runs the code. **A checklist would have caught it on day one**, because the first thing anyone holding the phone would notice is that no photo prompt ever appears.

A device-verification checklist is the thing that closes that gap. Each is a Markdown file of numbered sections; each section is a short scripted interaction — *do this on the phone, then look at this* — with checkboxes and a place to write what actually happened. **You tick a box or you write down what happened instead. A line that "seemed fine" is not ticked.** They are written to be run by a person holding a phone, in an evening, not by a developer at a keyboard.

They matter more than the ratio of code-to-checklist suggests, because the failures they catch are mostly **silent**. A missing App Group does not crash the widget, it makes it render its neutral state forever. A share extension over its memory ceiling is killed by the system with no error anywhere. A photo filed under the wrong day looks completely normal, on the wrong day, permanently. None of those produce a red test or a crash log; they produce an app that quietly does the wrong thing.

#### The eleven, in the order to run them

**Everything below is now runnable except #9**, which needs the APNs key. Two of them (#5, #6) need the phone to be on **iOS 26+**, and #8 and #11 additionally need Apple Intelligence hardware.

**The totals in this table did not add up before and now they do: eleven files, 409 boxes, 0 ticked.** The old figure of "ten checklists, 356 boxes" undercounted two ways — it left Moments out of the table entirely, and it carried Entry Detail at the 22 its own header still claims rather than the 28 it contains.

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
| 9 | `device-verification-push.md` | 29 | ~~The APNs key first~~ — **ungated** | **The first checklist with ticks in it.** §0–§3 were run on Aug 12: registration, delivery to a locked phone, the production/sandbox split, and the tap deep-link. **Left: the force-quit case, the sandbox row alongside production, and all of §4–§7.** |
| 10 | `device-verification-entry-detail.md` | **28** | TestFlight build | Added by phase 22, and the only one whose §1 is about something that must *not* appear. **Two things changed under it the same evening it was written, and neither was recorded.** ~~It wants doing before any redesign lands~~ — the redesign merged **30 minutes later**, so that window closed unrun and this now verifies v2 against a checklist written for v1. And ~~the primary seal assertion holds whether or not the seal does anything~~ — PR #55 fixed exactly that for the timeline **card** (a sealed fixture with a body, a photo, a transcript and tags, against all six branches, plus a negative control). **The card's evidence is now solid; the detail screen's own seal gate at `EntryDetailScreen.swift:115` still has no assertion of any kind**, and there is no view-hosting harness in this project, so §1 remains its only evidence path. Fix the header (it says 22) and add the v2 checks before running it. |
| 11 | `device-verification-personalization.md` | 25 | **iOS 26+ with Apple Intelligence** | Added by phase 23. Same gate as #8 and the same unknown: `SystemLanguageModel.default.availability` has never returned `.available` on any hardware this project owns, so **every personalization in the suite is a stub**. Two accepted risks are recorded here rather than in code because only a device can answer them — a personalized string is longer, so truncation at large Dynamic Type is the likeliest defect, and a mid-read VoiceOver swap could re-announce. |
| — | `device-verification-moments.md` | 44 | TestFlight build | **Not new — it was simply never in this table**, which is part of why the box count in this file was wrong. |
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
**Nothing here is a coding task, and that is the point.** Eleven features have now shipped that have never run against reality: sync pull has never touched the 763 real entries, the recording path has never met a real microphone, transcription has never produced a single word, the extraction model has never once been `.available`, **the personalization model has never once been `.available` either**, the widget has never been rendered by WidgetKit, the share extension has never been started by the system, the backfill scan has never met a real camera roll, **Today's swipe-to-skip has never been swiped**, **Entry Detail v2 has never been looked at**, and no notification has ever been delivered by Apple. Each is a checklist that takes an evening, and each one can invalidate a design rather than just find a bug.

### Then, in build terms
- **Phase 8, onboarding and account creation** — shipped. The app now has a first-run path for a person who is not you, though Sign in with Apple itself still cannot be exercised until enrollment clears.
  
- ~~**The seal control in the composer**~~ — **shipped**, as PR #29, ~~and what remains is a four-line server change~~ **and that change is on `main` too.** What remains is items 27's two decisions, not code.
  
- ~~**The widget**~~ — **merged**, as PR #32, and with it the project's first extension target and its first deep-link handling. The roadmap calls it the reason the loop survives week four; whether it actually does cannot be known from a simulator, which is why its checklist is first on the list above.

- ~~**Today v2**~~ — **built**, open as PR #34. Three things in its design were dropped rather than built, and each is a decision waiting rather than a task: **paper grain** (the export calls it mandatory identity, `design-system.md` lists screen-print texture as an anti-pattern, and neither decisions file mentions grain at all), the **STORIES rail** (throwbacks on Today — the data exists behind `GET /children/{id}/moments` and `ThrowbackCard` already renders it, but it needs a second call from the screen the contract calls "the single call the home screen makes"), and the **96pt completion burst**. None is blocked on code. Also deferred with it: thumbnails on Today's cards and the per-tile upload strip, both of which reach into the media paths.

- **A contrast defect the phase found and did not fix.** `KindBadge` draws tint-coloured text on a 12% wash of the same tint, which measures roughly 3.3–3.7:1 at 12pt semibold — below WCAG AA. It is pre-existing and shared, and fixing it needs either a `periwinkleDeep` token or a badge restyle, i.e. a design-system decision rather than a patch. **Phase 13 checked and did not propagate it**: the only place the Settings import uses tint-on-tint is in a direction the file never renders.

- ~~**Settings v2**~~ — **built.** The last screen still wearing its PR #21 scaffolding has had its design pass, so Timeline, Moments, Today and Settings now read as one app. The import's argument was that Settings should open on the child rather than on configuration, and it does: `ChildHeroCard` replaced the `Name` row, section labels carry a rule to the trailing edge, the sync card grew a summary head that tints while files are in flight, and export reads as a keepsake rather than a menu item. See `docs/settings-v2-inventory.md`.

  **Three things were dropped for want of a number, and each is an API conversation rather than a task**: the hero's `412 entries · 1,204 photos · 3 sealed` strip, the `First entry` row, and the sync progress bar all need archive-wide counts that no endpoint serves — and `design-system.md` already settles, for the timeline header, that the client never claims to know the size of the archive. A `GET /children/{id}/stats` would light up all three at once. Also dropped: **paper grain again** (still unresolved, still the same three-way disagreement), and the export card's decorative motif, which turned out to be literally three rotated cards — a named anti-pattern.

  **One structural change was refused.** The import groups `Recompute ages from birthday` with the dry run and the reset under `Advanced`. It stayed in its own card with its own whitespace, because rewriting every stored age in an archive is not a neighbour of asking the server what changed.

- ~~**The share sheet target**~~ — **built and merged** as #35. The widget's extension target was indeed the pattern, down to two of the same traps in the `xcodeproj` script. What it added that the widget did not have: a **write** direction on the App Group, a queue with a version gate, and a drain that has to be idempotent under a process the system can kill at any point. See `docs/reports/phase-12-share-extension.md`.

- ~~**Push notifications is now the only unbuilt P1 retention lever**, and it is blocked in the same place TestFlight is~~ — **the client and the server are both built and merged** (#39, #40), and the block is gone. What is left is a credential and a machine: the APNs key from the portal, three Fly secrets, and the notification job's scheduled machine. Nothing on P1 is waiting on code.

- ~~**Four Lane A gaps this file recorded as blocking iOS work are built, and three of them leave a client-side workaround behind to delete.**~~ **All but one of those deletions has happened, and this bullet was the last place still asking for them.** See "The four Lane A deletions" below — **all four are now closed.** 29a, 29c and 29d shipped in PR #48; 29b closed on Aug 12, and its remaining half turned out not to be a deletion but a missing decode.

- **Cross-share deduplication was deliberately not built**, and it is a decision rather than an omission. Sharing the same photo twice makes two entries: an `NSItemProvider` carries no asset identifier, and content-hashing a video inside the memory-ceilinged process is precisely what the architecture exists to avoid. It is also not obviously wrong — the same photo on two days is a legitimate pair of entries — so shipping a heuristic that silently dropped one would have been worse than shipping neither. Worth revisiting only if the device checklist's §10 says a real parent trips over it.

- ~~**A name.** Open decision #1~~ — **decided Aug 12, 2026: the app is `Dogear`.** A dogear is the corner you fold to come back to something, which is the product in one word: an archive is not a feed, and nothing in it is meant to be read once and scrolled past. **This closed the last open item in `docs/decisions.md`.** The rename itself is not started. It is a rename and not a migration — the bundle id and URL scheme were chosen name-neutral for exactly this day, so signing, the Apple registration and `APPLE_BUNDLE_ID` are untouched. What it does touch: the display name, the widget gallery (which groups by app name and is what made deferring expensive), the icon, the TestFlight listing, `Config.xcconfig`, the export viewer's title, `docs/` prose and the repo name.
  
- ~~**P3 item 2, structured extraction**~~ — **built and merged** as #43, once #45 let a tag write say who decided it. The schema question it was deferred over got its answer: a tag arrives as `"beach"` or `{"name": "beach", "source": "device_ai"}`, `source` defaulting to `user`. The model behind the seam has still run zero times — `docs/device-verification-extraction.md`.
  
- **Writing a letter on any day** — **decided Aug 11, 2026, design in progress in Claude Design, no code.** The seal control is complete but reachable only from a letter assignment, which exists only on the 15th; the decision is that the 15th is the reminder rather than the permission. iOS-lane end to end — the API already accepts it. See "The sealed letter, whole" above and `docs/decisions.md`. **Not a phase yet**: it is a decision waiting on a design, and it should not be numbered or started until that design exists.

- **Video audio tracks**, still the one piece cut and still gated on the audio path being verified on a device first — see `docs/decisions.md` and `docs/phases/phase-16-BLOCKED.md`. This is the only item in the project whose next step is genuinely *another item's* checklist rather than work of its own.
  

* * *
## Facts, if you want to check any of this
Every command below was executed for this revision, and the comment on each is what it actually printed. The ones that used to print something else are corrected, not re-copied. **The block has grown a section per stale claim this revision found** — if a sentence above asserts something shipped, the command that proves it is here.

```bash
cd api && uv run pytest -q                   # 478 passed, 2 failed — both tests/test_restore.py
ls api/tests/test_*.py | wc -l               # 34 files

# The two failures are this machine, not the code: Homebrew's pg_dump is 17.6, a 17 client writes
# `SET transaction_timeout` into the dump, and Postgres 16 rejects it on the way back in. CI pins
# 16 exactly and is green. Check with:
pg_dump --version                            # 17.6 here — use the pinned 16 binaries for a drill

# main's CI lint is green. It went red once on E501 and the fix was six files rather than one,
# because `make lint` aborts at the first failing step, so `ruff format --check` had never run.
cd api && uv run ruff check . && uv run ruff format --check .

# Delete DerivedData first or the warning count is a lie: an incremental build does not
# recompile an unchanged file, and a file that is not recompiled emits no warning.
rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<sim>" CODE_SIGNING_ALLOWED=NO   # 801 tests, 101 suites, TEST SUCCEEDED
# Swift Testing reports the total, not XCTest — grep for "Test run with", because the XCTest
# summary line in the same log says "Executed 0 tests" and is not the number you want.
# Warnings: 21, unchanged for four phases. 14 in PushPermissionTests.swift (phase 14), 4 in
# ExtractionTests.swift and 3 in Extraction/ExtractedDetails.swift (phase 17 — those three are in
# the app target). Note `build` alone does NOT compile the test target, so a build-only run
# reports a warning count that omits every test file.

# The prompt library, in the two numbers that matter. 113 bodies, 0 tokens, 99 literal he/him/his.
python3 -c "
import re; t=open('api/seeds/prompts.yaml').read()
b=re.findall(r'^  body: (.*)$', t, re.M)
print(len(b), sum('{' in x for x in b), sum(bool(re.search(r'\b(he|him|his)\b', x, re.I)) for x in b))"

# The four Lane A deletions PR #48 shipped, which this file kept listing as outstanding.
grep -rn "unsealIfTheServerSealedItAnyway" ios/    # 1 hit, and it is inside a /// comment
grep -rn "clientFilterPageBudget" ios/             # zero hits
grep -rln "pronoun" ios/Rascal/Rascal/Onboarding/  # ChildSetupFlow, OnboardingGate, Draft, API

# There is no stats endpoint. This returns only export headers.
grep -rn "stats" api/src/rascal/routers/*.py

# The scheduler machine is the one that matters, and it is not in the app's process group.
# NOT RUN FOR THIS REVISION — this reading is PR #57's, from an authenticated flyctl on Aug 12.
# It is the one figure in this file sourced from another document rather than from a command
# executed here, and it is flagged rather than absorbed. Re-run it before acting on it.
fly machines list -a rascal-api    # 185d762c643778: no process group, image from release v1

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
  -tAc "select count(*) from entries where deleted_at is null;"   # 763

# One PR is open — #57, the photo-slot investigation, which merges no code.
gh pr list --state open                     # 1: investigation/missing-photo-slot
git branch -r --no-merged origin/main       # 4, incl. that one

# Eleven checklists, 409 boxes, 9 ticked — the second number moved for the first time on Aug 12.
# Use -ch and sum $1: with a single matching file `grep -c` prints no filename and the -F: form
# silently sums nothing, which is how this block could have read 0 forever.
grep -chE '^\s*-? *\[[ xX]\]' docs/device-verification-*.md | awk '{s+=$1} END {print s}'   # 409
grep -chE '^\s*-? *\[[xX]\]'  docs/device-verification-*.md | awk '{s+=$1} END {print s}'   # 9

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

# Nine of 409, all in the push checklist. Per-file, so you can see which one moved.
grep -cE '^\s*-? *\[[xX]\]' docs/device-verification-*.md

# Push is delivered. The scheduler drift is the live one, and it now has two instances:
# both non-grouped machines pin their own image while the `app` group moves on.
fly machine list -a rascal-api --json | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    c=m['config']
    print(m['id'], c.get('env',{}).get('FLY_PROCESS_GROUP','(none)'),
          c['image'].split(':')[-1][:20], ' '.join(c.get('init',{}).get('cmd') or []))"

# What the scheduler actually produced — the only check that matters. `mission` has never
# once held a photo, all-time, despite the deployed image narrowing it to photo-only.
fly ssh console -a rascal-api -C "python -c \"
import asyncio
from sqlalchemy import text
from rascal.db import get_sessionmaker
async def m():
    async with get_sessionmaker()() as s:
        for r in (await s.execute(text('''select a.slot, p.kind, count(*) from assignments a
            left join prompts p on p.id=a.prompt_id group by 1,2 order by 1,2'''))).all():
            print(r)
asyncio.run(m())\""    # mission/activity 2, mission/audio 1, mission_b/activity 2, question 3
```
