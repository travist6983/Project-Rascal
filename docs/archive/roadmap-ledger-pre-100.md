# RASCAL — the roadmap ledger, phases 1–99 (archived detail)

**Archived Aug 25, 2026 by phase 123.** The ledger in `docs/roadmap-status.md` had grown to
**99 rows and 176 KB — 54% of that file** — because every row carries its full detail cell
forever. Those cells are the evidence a shipped-status claim is supposed to carry, so they are
**moved here whole and unedited rather than trimmed**; each row in the live ledger keeps its
number, its title and its status marker, and links to its entry below.

**The cut is phase 100.** Rows for phases **100 and up stay in the live file in full** — they are
the tree as it currently stands and they are what a reader is actually checking. Rows below 100
are history: shipped, verified, and consulted by grep rather than by reading down the table.

**What did not move.** Status markers, phase numbers and titles all stay in the live ledger, so
*"has phase N shipped, and against which PR"* is still answered without opening this file — which
is the question the ledger exists for, and the one the last ten revisions kept getting wrong. Only
the supporting detail moved.

**The collisions are preserved as collisions.** Phases 3, 11, 19, 20 and 103 are each spent twice;
where two rows share a number they appear here as two entries under the same heading, with their
distinct titles, exactly as `CLAUDE.md` requires. Nothing was renumbered.

* * *

## Phase 24 — Tokenize the prompt library
<a id="phase-24"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 13, 2026**

~~113 bodies, 0 tokens, 99 literal `he/him/his`~~ — all 113 now carry tokens, the four `his mom` bodies were rewritten household-neutral on the owner's call, and `seed_prompts` retires the seeded rows the file no longer contains, which is what stopped the literal set serving alongside the new one. Both corrections to the old framing held: the contract is **thirteen** tokens, and `PromptTokens.render` was already a real parser at nine call sites — so the iOS lane needed no change. **The cost the framing missed** was that thirteen tokens cannot express English question inversion (*"is he"* / *"are they"*), so eighteen bodies were rephrased rather than substituted. `export_viewer/assets/app.js` learned the table and the manifest gained `child.pronouns`. **Needs `make seed` against production to take effect**

## Phase 35 — Neutral theme slug (`his-words` → `their-words`)
<a id="phase-35"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 13, 2026**

**The last gendered string the library carried, and it outlived the bodies by a phase** — phase 24 swept the sentences and a theme is not a sentence, so it survived. Renamed in `mission-library.md`, `constants.THEMES`, `data-model.md` and the contract's examples. **Most of it needed no migration**: `theme` is in `MUTABLE_FIELDS` and is *not* part of `sha256(kind, cadence, body)`, so re-seeding rewrites live rows in place. `0009_neutral_theme_slug` exists for the rows re-seeding cannot reach — the 99 prompts phase 24 retired, which are absent from `prompts.yaml` forever. **Those rows are not inert**: `scheduler.py`'s `recent_themes` joins assignments to prompts with no `active` filter, so a half-applied rename would feed a stale slug into the two-day theme rotation guard and quietly stop it excluding anything. **Tags were deliberately not migrated**: nothing copies a theme to a tag, and a tag is a word a parent chose about one entry. **Needs `make migrate` against production**

## Phase 25 — Author photo prompts
<a id="phase-25"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 14, 2026**

Twenty new photo bodies, tokenised, taking the daily photo pool from 22 to 42 and the untagged-and-available-at-48mo count from 20 to 40 — roughly doubling the runway before the `mission` slot repeats. **The premise inverted twice**: this file called the pool thin, then corrected itself to say it was healthy-but-unreachable, and by Aug 14 it was reachable and genuinely thin. All 42 daily photo prompts were run through `generate_prompts.judge` and accepted, so the library still passes its own filters. **The copy is authored, not generated** — no LLM wrote these and the 79 candidates still contain zero photo prompts

## Phase 26 — Entry Detail v2
<a id="phase-26"></a>

**Status marker, as the live ledger carries it:** ✅

**Shipped as #54 and live from both Timeline and Moments.** The design answer came back — full-bleed permitted on this screen only (`design-system.md:607`), paper grain settled as rejected (`decisions.md:172`). **What is left is not code:** 0 of 28 checklist boxes, and the checklist's own premise was inverted — written 22:15, redesign merged 22:45 the same evening, so "run it before the redesign" never happened. It also still describes v1 and its header says 22 boxes when there are 28

## Phase 27 — Letter on any day
<a id="phase-27"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 14, 2026**

Freeform-plus-seal, and the API needed nothing exactly as this file said. **Editing a seal shipped with it**, because they are one predicate: 27 needed `SealSetting.isOffered` to stop requiring a `letter` assignment and seal-editing needed it to stop refusing while editing. The dead seam this file identified was real — `EntryChanges.unlockAtAge` existed and nothing set it, so a seal changed on the phone reached the archive by no path at all. Sealing is offered on **every** freeform verb, not just Write, because all four build the request as `mode: .text`. **One defect found later by audit and fixed**: the edit path reused `resolvedAge`, clamping the archive's committed value into the stepper's 10–21 window, so an entry sealed at 25 rendered "Opens at 21" and an untouched Save rewrote it

## Phase 28 — `GET /children/{id}/stats`
<a id="phase-28"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 14, 2026**

Route, service, schema, contract entry and eight tests. Counts live entries, the sealed subset, and media by kind through a join to a live entry — a delete takes the media with it, so counting media on its own `deleted_at` would report files belonging to an entry that is gone. `first_entry_on`/`last_entry_on` are calendar days in the child's `family_timezone`, which is the part a UTC `date()` gets wrong: an evening entry in Detroit is stored as the next day in UTC. **The consumer is still unbuilt** — D1 and D12 in `settings-v2-inventory.md` are now unblocked rather than done

## Phase 30 — Guardian invites + viewer role
<a id="phase-30"></a>

**Status marker, as the live ledger carries it:** 🧊 **iceboxed Aug 16, 2026 by the owner**

*Not for a while* — not rejected, and it comes back without relitigating anything. Authorization was always built and enforced; what never existed is a route that can create a `viewer` row. **Nothing has to be unwound**: `visibility` is specified in `data-model.md` and was never migrated, so there is no column on `entries`, no filter in `deps.py`, and no dead code. **The design survives intact** — the three answers are settled in `decisions.md` and the column is specified to its default, so a restart is a build against a finished spec rather than a fresh design. Per-entry visibility ices with it, having no other consumer. The `viewer` value stays in `guardians.role` where it has been since `0001`; that is the state this has always been in and nothing regresses by leaving it

## Phase 31 — Multi-kid
<a id="phase-31"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 13, 2026**

The stated cost was right that it is entirely iOS and wrong about what it is. `.first` was three lines; the phase is **where the switch is expressed**. `OnboardingGate` renders `RootView` with `.id(child.id)`, so a switch has to be a new `SessionState.ready(child)` — every child-bound object (`TodayModel`, `SyncEngine`, `ShareDrain`, `TimelineModel`, `MomentsModel`, the Timeline's `@Query` predicates) captures its child once at init and never re-reads it, so a mutable `childId` would have shown a sibling's entries under the wrong name and advanced the wrong cursor. **Six local reads were unscoped** and are now child-filtered: Today's board merge, the widget snapshot, the backfill's month and day coverage, the notification re-offer, extraction's queue, and Settings' `?? children.first`. Sync needed nothing — cursors have been per-child since `SyncCursorStore`. Selection persists in `UserDefaults` and is cleared on both sign-out paths. 888 tests pass

## Phase 32 — Year One book
<a id="phase-32"></a>

**Status marker, as the live ledger carries it:** ○

The export is the shared half. **One of the book's five own problems closed on Aug 16** — year scoping, by phase 43; `GET /export` now takes `from` and `to` as days in `family_timezone`. **The remaining four are untouched and all four are the same shape**: print layout, PDF generation, QR substitution for A/V, and the public playback surface those QRs resolve to — which is a web surface this API has never had. That is the real gate on 32, and scoping did not move it

## Phase 33 — Photo captioning
<a id="phase-33"></a>

**Status marker, as the live ledger carries it:** ◐ **server done; device half blocked, and now being measured rather than waited on**

**Re-verified Aug 16, 2026 — the block is unchanged**, same SDK, `Transcript.Segment` still text-or-structure, image-type grep still 0. Phase 46 shipped a **measurement instead of the feature**: `MAImageCaptioning` reads a description a human already wrote into a file's XMP, which invents nothing and so carries no permanent-lie hazard, but nobody has ever counted how many real photos have that field. `CaptionProbe` counts it. **No writer, no state ladder and no clobber guard shipped with it** — all three would be premature, and the clobber's deferral now points at the measurement rather than at a phase that may never land. **A near-zero result closes this phase and deletes the probe**, which is a real possible outcome and is written down as one. The server half is complete — route, schema, persistence, FTS weighting, sync wire and export all carry `caption`. **The device half has no API to call**, verified against iPhoneOS26.4 on Aug 14, 2026: `FoundationModels`' entire input vocabulary is `Transcript.Segment` (text or structure), and a grep of its interface for `CGImage

## Phase 40 — Competitor facts corrected, and the numbering policy
<a id="phase-40"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 15, 2026 — docs only, no code**

A stated *reason* inside D3 was false: it claimed no competitor in this category deletes, and **Tinybeans deletes after 12 months of inactivity**. The conclusion is untouched — the $0.20/month arithmetic always carried the rejection alone. The correction is the interesting part: Tinybeans' trigger is inactivity, which is `last_sign_in_at + 12 months`, one of D3's own two clocks, so this product converged with the incumbent and then took the kinder version. The `decisions-log.md` paragraph that rested on the same premise is replaced with sourced facts, URLs and check dates, and two 2025-vintage claims are carried forward **labelled unverified**. Also settles that **phase numbers are identifiers, not an execution order**

## Phase 41 — The caption clobber, retired into 33
<a id="phase-41"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026 — docs only, no code**

Closes the queue line the owner decided on Aug 15 to leave alone. **Re-verified against the tree rather than trusting the line**, and the line named the wrong method: it said `Media.applyServerResponse`, which does not exist — `applyServerResponse` is on `Entry` and never touches a caption. The write is `Media.applyServerSummary` at `Media.swift:210`. **The "inert" premise is confirmed**: `Media.caption` has exactly one writer in the entire app and it is that server-fold, and `RascalAPI.writeDerived` sends transcript alone with an explicit comment saying caption is deliberately not sent. **Not filed as a review false positive** — `.claude/review-history/README.md` reserves that file for findings that were *wrong*, and this one is right and deferred, so it stays discoverable. The defect now lives on 33's row and in `blocked.md` §9, which is what a builder of 33 actually opens

## Phase 42 — Guardian invites iceboxed, and 34's false blocker removed
<a id="phase-42"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026 — docs only, no code**

Two pieces of queue hygiene from one sitting. **The icebox**: the owner's call that 30 and per-entry visibility are not for a while, recorded as a deferral rather than a rejection — `phase-queue.md` gained an `Iceboxed` section for the distinction, because "Deliberately not doing" is for settled no's and filing a *not yet* there would lose the difference. Nothing unwinds; `visibility` was spec-only and never migrated. **The correction**: 34's line claimed two open questions blocked it and *"nothing should be built until those two are answered"* — **both were answered in `decisions.md` the same day the line was written**, by D2 (export always free and complete; the cap is 100 photos lifetime, i.e. media) and D3a (a free export link inside every deletion warning). Its "then deletion" summary was superseded by D3 on the same day. **The line was blocking a phase that was not blocked**, and the real gate is `blocked.md` §10, an account action

## Phase 43 — Date-scoped export
<a id="phase-43"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

`GET /children/{id}/export` takes `from` and `to` — inclusive, either alone, omit both for the whole archive, so no existing caller changed. **The days are resolved in the child's `family_timezone`, which is the entire difficulty**: an entry logged at 8pm Dec 31 in Detroit is stored as Jan 1 UTC, and a naive range files it in the wrong year — for a book printed once a year, a mistake nobody catches until it is on paper. The window is half-open UTC instants derived from local midnights, so it stays sargable on `(child_id, occurred_at desc)` and is DST-correct; the helper is `dates.local_day_window`, beside the one definition of "today". **Selection is by `occurred_at`, never `created_at`** — a December photo uploaded in January is December's. **The correctness work is the manifest, not the filter**: `manifest.scope` records what the zip is a copy of, `manifest.notes` leads with a partial-archive warning instead of "contains every entry", and the viewer banners it, because a partial archive that reads as a whole one turns a gap in a download into a gap in a childhood. `scope` is absent from older archives and **absent means whole**. 15 tests, including a mutation-checked timezone boundary. Closes one of 32's five problems

## Phase 44 — The verification backlog, reconciled with what shipped
<a id="phase-44"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026 — docs only, no code**

**The backlog was stale against the app and would have produced false results.** Three findings, each verified against the Swift rather than against a design document. **Entry Detail asked twice about a navigation bar v2 removed** — `EntryDetailScreen` has no `navigationTitle` and no `toolbar` anywhere in it, so a tester would have failed a correct build or skipped the box confused; both are re-aimed and §7 is new, covering what v2 actually changed (the bottom-anchored sheet, the self-scrolling cap at accessibility sizes, Edit and Delete moving into the overflow, and a sealed letter still being deletable without unsealing it). Its header also claimed 22 against 28 — the defect the previous revision named in this file and left standing — and now says 36. **The share sheet checklist looked for "Rascal" in four places**; the sheet shows `CFBundleDisplayName`, which is Dogear. The `RascalShare` target and `Rascal.entitlements` are build identifiers nobody sees and deliberately did **not** move, which the file now says so nobody "fixes" them. **Settings had no boxes for its two newest features**: the stats strip, whose three owner decisions are each only checkable on a device (the middle cell counts photographs not media; nil is not zero; an empty archive shows nothing), and adding a child, which is multi-kid's only entry point. **431 boxes now, 9 ticked** — a denominator that grew on a day nobody ran anything, which is the honest direction

## Phase 45 — Multi-kid device coverage
<a id="phase-45"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026 — docs only, no code**

**Multi-kid shipped Aug 13 and had no device coverage anywhere.** Phase 31's own record names six local reads that were unscoped and are now child-filtered; **five of the six had not one box between them**, and phase 44 had covered only the sixth. Every one fails *silently* — a wrong child's data looks completely normal. Boxes added against each specific read, each verified in the Swift: **Today's board merge** (`TodayScreen.swift:311`), **the widget snapshot** (`WidgetSnapshotSync.swift:60` — filtered in memory because a `@Query` predicate is fixed at init, and the file it writes is what the Lock Screen renders), **the backfill's month coverage** (the worst of them: a month the *sibling* wrote in counted as covered, so this child's empty months were never offered — *"a prompt that never appears is not a bug anyone can see"*), **the notification re-offer** (spent once and never returning, so a second child inherited an offer their sibling had used up), and **extraction's queue**. **451 boxes now, 9 ticked.** Two table defects closed on the way: row 10 still carried Entry Detail at 28 after 44 raised it to 36, and **the widget's boxes had never been in the table's column at all** — row 1 pointed at its §1 as a pre-flight, which read as though the file were accounted for. The table now sums to 451, which is the first time adding it up has been a check that works

## Phase 46 — The caption probe — measure before building 33
<a id="phase-46"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

**The platform block was re-verified rather than trusted**: same SDK, `Transcript.Segment` still exactly `text` and `structure`, the `CGImage\|CVPixelBuffer\|UIImage\|CIImage` grep still 0. So 33's device half still cannot be built as the roadmap describes it. **What ships instead is the measurement the decision rests on.** `MAImageCaptioningCopyCaption` reads the XMP field `Iptc4xmpExt:AOContentDescription` — a description a human already wrote, not a model's guess — and the whole question is what fraction of a real camera roll has one. `CaptionProbe` walks the newest 500 on-device photos and counts, writing nothing, uploading nothing and never pulling an iCloud original. **The reader was proven, not assumed**: the suite writes a caption into a real JPEG with `MAImageCaptioningSetCaption` and reads it back through the same call. **Three things deliberately did not ship** — a writer, the caption state ladder, and a clobber guard, which would have guarded a writer that does not exist; `applyServerSummary` and `differs(_:from:)` agree today, so there is no live defect. Provenance is settled in `decisions.md` (a source distinction, on `entry_tags.source`'s precedent) and **the column is deliberately not specified**, because a migration for a feature that may be deleted is the cost this project keeps refusing. 11 tests, 918 passing. **A near-zero result deletes the probe and closes 33**

## Phase 47 — The app icon
<a id="phase-47"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

**The last item the Dogear rename left that was not a listing or a filename**, and the owner settled it by naming the file: `rascal-icon-fan.svg`, the third of three explorations, *"no matter what name we land on."* That caveat is the interesting part — **the mark carries no word**, so it was decidable before the name and would not have moved after it, which means it was never really a rename item at all. **One PNG is the entire change**: `AppIcon-1024.png`, 1024², no alpha, sRGB. There is no 60pt or 76pt asset to keep in step because `actool` derives every home-screen size from that one file — verified by compiling the catalogue and reading `AppIcon60x60@2x.png` back out. **The icon was a build product with no build.** It is now `render-appicon.mjs`: the SVG through headless Chrome at 2048 and halved, because this art puts `feDropShadow` on five separate `clip-path` groups and the lighter rasterisers either drop the filter or resolve the clip in the wrong user space — either of which flattens the fan to one card, quietly and only at render time. The script asserts the two things App Store Connect rejects on upload and nothing before it mentions: the dimensions, and **the absence of an alpha channel**. Re-running it reproduces the committed PNG byte for byte. **The neighbouring generator was a live trap and is now guarded** — see below. **`docs/` prose still says RASCAL throughout and that is deliberate**, per the rename's own decision not to sweep it

## Phase 48 — The iOS concurrency warnings
<a id="phase-48"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

**Backfilled Aug 16 — this row did not exist for a day, and its absence broke the numbering rule.** PR #95, `ios/phase-48-concurrency-warnings`. Cleared the 21 warnings this file had reported "unchanged for four phases" — and the mapping is exact rather than approximate: 3 in `Extraction/ExtractedDetails.swift` (a `nonisolated` on a private `String` extension), 14 in `PushPermissionTests.swift` and 4 in `ExtractionTests.swift` (lock/unlock pairs rewritten to `withLock`). 3 + 14 + 4 = 21. **The 21 was already stale in the flattering direction** when it was cleared: phase 46 had added 5 in `CaptionProbe.swift` that nobody counted, so the true cold figure was 26. Measured from a deleted `DerivedData` with `build-for-testing` across all four targets — `xcodebuild build` alone never compiles the test target, which is the trap the previous commit fell into. **918 tests, 113 suites.** The author skipped the docs deliberately, to avoid sweeping up another session's uncommitted phase 47 work, and promised the row "once 47 lands"; 47 landed and the row was never written, which is how `roadmap-status.md` came to be three phases behind `main`

## Phase 49 — The activity clock, and the two consent lanes
<a id="phase-49"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

**Backfilled Aug 16.** PR #96, migration `0010_activity_and_consent`. `users.last_sign_in_at`, `marketing_consent`, `transactional_consent`. **`last_sign_in_at` landed ahead of the phase that consumes it because it cannot be backfilled**: a lapse date is reconstructable from the payment rail, *when a parent last opened the app* exists nowhere else, and every day the column did not exist is a day of the record simply gone. A **token refresh counts** — an app in daily use rotates and never signs in afresh, so recording only `/auth/apple` would make the most engaged households look dormant against a twelve-month deletion clock. The consent lanes are two fields from day one because splitting one `emails` boolean after both meanings have been written into it, under a GDPR request, is the failure the shape exists to avoid

## Phase 50 — `pool-health` estimates from the observed rate
<a id="phase-50"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

**Backfilled Aug 16.** PR #97. `_estimate_days` multiplied by `SERVE_INTERVAL_DAYS`, i.e. it assumed a slot is served once a day — and the `mission` slot had been served **zero** times a day for weeks, which is what made this file's "20 days until repeat" arithmetic wrong in the first place. It now measures what the slot actually served. Also corrected `api-contract.md:699` and `mission-library.md:263`, which described the nominal rate

## Phase 51 — The `aud` allowlist, and unbundling the APNs topic
<a id="phase-51"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

`APPLE_BUNDLE_ID` is a comma-separated list and **keeps its name** — renaming it would rotate a Fly secret on a live app for nothing. `services/apple.py` needed **no code change**: it already passed the setting straight to PyJWT, whose `audience=` takes an iterable with any-match semantics, so changing the setting's type changed the check's behaviour. **The trap was `resolved_apns_topic`, and the setting the plan called for already existed** (`config.py:102`, since phase 14) — what was missing was the rule. Two audiences with no `APNS_TOPIC` now **fails at startup**: guessing `[0]` would be right today and wrong the day somebody reorders a secret, and the only symptom is that no push is ever delivered. An empty audience list also refuses to start, because `audience=[]` rejects every token Apple has ever signed. **Unblocks the web client**, which `roadmap-status.md` records as the far end of the printed book's dependency chain

## Phase 52 — Credential linking, revocation, and dev-login's second lock
<a id="phase-52"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

Migration `0011`: `credentials.revoked_at`, `credentials.updated_at` + trigger, `email` in the CHECK, and `password` → `email` for existing rows. **The unique constraint deliberately did not change**, and that is the decision the phase rests on — a revoked credential keeps its `(provider, subject_id)` so a later sign-in matches the same row and the same archive. `GET/POST/DELETE /me/credentials`, `409 credential_in_use`, `409 last_credential`. **No email matching anywhere.** dev-login moved to `provider = "email"` and gained a **domain guard**, which closes a different hole from its local-only gating: a local API pointed at a real database handing back an `is_admin` session for a real account. **The production claim was measured rather than asserted** — one `users` row, one `apple` credential, zero `password` rows — before the migration was written. A pre-existing uncaught `IntegrityError` on the sign-in create path was fixed rather than inherited

## Phase 53 — Apple server-to-server notifications
<a id="phase-53"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026 — and not verifiable without a device**

`POST /webhooks/apple-signin`, signature-verified against the same cached JWKS, designed beside the specified-but-unbuilt `POST /webhooks/app-store`. Migration `0012`: `users.email_deliverable`. **`account-delete` is identical to `consent-revoked` and that is a decision, not a copy-paste** — it is in `decisions.md` precisely because the duplication will read as a mistake to whoever finds it, and "fixing" it would delete an archive on a third party's say-so. Three claim-set traps, each of which rejects every real notification if missed: `sub` is inside `events` rather than top-level, there is no `exp`, and `events` is a JSON **string**. `event_time` is milliseconds. **`docs/blocked.md` §11 is the run that has not happened**: nobody has ever observed Apple's `sub` across a revoke-and-reauthorize cycle, and if it changes, the design is wrong rather than buggy

## Phase 54 — Google sign-in, server half
<a id="phase-54"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

`POST /auth/google`, and **no schema change** — the CHECK has permitted `google` since `0001`. The JWKS machinery was **extracted into `services/oidc.py` and shared with Apple** rather than copied: two hand-maintained signature checks drift, and the copy that misses a fix keeps returning 200s. Apple's 76 tests passed unchanged through that refactor, which is what makes the shared base safe. Two valid issuers, a **separate** `GOOGLE_CLIENT_IDS`, and `email_verified` required. **A break-test caught a decorative test here**: the Apple-token-to-Google-route case rejects on the *signature*, so it passed happily against a verifier that pooled both audience lists — a second test now signs with Google's key and Apple's audience, where only the audience check can reject it

## Phase 55 — Google sign-in, client half
<a id="phase-55"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026** — ~~blocked on an account action~~

iOS lane. **The blocker closed the same day it was recorded**: the owner created the Google Cloud project and the iOS OAuth client, and `GOOGLE_CLIENT_IDS` is set on Fly — verified in production by `POST /v1/auth/google` answering `401 unauthenticated` rather than `422 … GOOGLE_CLIENT_IDS is unset`, which is the check `blocked.md` §12 was written around. `ASWebAuthenticationSession` + PKCE, no SPM dependency; rule 4 made that the only permitted option rather than the preferred one. **Never run against real Google** — see the verification note below

## Phase 56 — The mailer
<a id="phase-56"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

`services/mail.py`, one function, and it **knows nothing about lifecycle notices, auth or consent** — a test greps the file to keep it that way. Its own phase on purpose: phase 38 and phase 57 both need it, and building it inside either would have shaped it around that one. `console` is the default and that is a **safety property**, not a convenience: it never opens a socket, so a local run cannot send real mail to a real parent about deleting their child's archive. One provider adapter behind a protocol, a timeout, and exactly one retry — never on a 4xx, because the message is malformed and sending it again produces the same answer more slowly

## Phase 57 — Magic-link email sign-in, server half
<a id="phase-57"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

Migration `0013`: `email_sign_in_tokens` and `rate_limit_events`. **`POST /auth/email/start` never creates a user**, which is the restriction that makes the whole phase small — it kills the orphan-account trap, enumeration-as-signup, and every argument about password reset at once. Always `202`. **An address is proved by the click, never by the field it was typed into**: `POST /me/credentials/email` creates the credential *inactive*, so a typo costs nothing. A token carries a `purpose`, because a sign-in link that could reactivate a removed address would make Remove a suggestion. **Rate limiting is in Postgres, not in memory** — there is more than one Fly machine, and an in-process counter passes every test while being N times looser than it reads. This phase changes `CLAUDE.md`'s rate-limiting scope line; the diff is **proposed, not applied**

## Phase 59 — The association file and the landing pages
<a id="phase-59"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 16, 2026**

API lane, and **this row did not exist until Aug 18, 2026** — the ledger jumped 58 → 60 while phase 58's own row cited *"phase 59 serves the association file"*, so the file referenced a phase it had never listed. `routers/wellknown.py` serves `/.well-known/apple-app-site-association` plus the `/invite/{token}` and `/signin` landing pages. **Mounted with no prefix, which is forced rather than chosen**: Apple fetches the association file from the root of the domain and will not follow a redirect to find it, so `/v1` was never available to these. Verified live — the AASA returns `application/json`, which Apple is strict about and which fails silently when wrong. **The router is `include_in_schema=False`, and that has a consequence worth recording**: phase 72's false-claims sweep took its route list from the app's own OpenAPI, so **these three routes are structurally invisible to that method** — a sweep that reads the schema cannot audit what is deliberately kept out of the schema

## Phase 36 — Guardian invite flow
<a id="phase-36"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

PR **#105**, migration `0014_families_and_invites`. **Deployed and verified against production the same hour**: head at `0014`, 29 daily assignments attributed to their sole guardian, **0 orphaned**, 28 live entries untouched. `families`, `entitlements` and `guardian_invites` exist; five routes; daily slots are per guardian and `weekly`/`monthly`/`letter` stay one per child. **`entitlements` was pulled forward from 37 and 37 is not therefore done** — nothing in the codebase writes `tier`, D5 reserves that for App Store Server Notifications V2, and `runbook-deploy.md` §7a is the hand-run statement in the meantime. ~~The owner's own household is still `free`, so the invite route returns 402 until §7a is run~~ — **§7a was run against production on Aug 17, 2026 and the household is `subscribed`.** One row updated, and `updated_at` moved, which incidentally proved the `set_updated_at` trigger fires on the new table. **The email in §7a's statement would not have matched**: the account is on a `privaterelay.appleid.com` address, exactly the caveat that section records, so the update targeted `family_id` directly. The gate now reads open — `is_subscribed` true, one adult of two — and the paywall's first exercise was the person who built it, which is the point of documenting the statement rather than adding a flag. **The subtle part is two partial unique indexes rather than one wide one**: Postgres treats NULLs as distinct, so a single `UNIQUE (child_id, user_id, assigned_on, slot)` would have let the scheduler write unlimited weekly rows for one child and day — silently, on the slots nobody checks. Break-tested, and it failed exactly as predicted when widened. **A review pass caught the defect that would have made the phase pointless**: the scheduler wrote per-guardian rows and `/today`, `/sync` and the daily push all still read them child-wide, so every parent saw both boards. `viewer_id` is a required argument on those reads now. Open item 11 is answered in code — cooldown per parent, daily per parent, shared per child. 30 was *grandparents as read-only viewers* and is iced; this is a **second parent** becoming a full guardian, which is what D4's one-price-per-household is sold on. Different need, different consumer, and keeping them separate is what let this ship while 30 stayed iced. A signed expiring invite link; the second guardian signs in and a `guardians` row is created, with **entitlement resolved from the family** so the invitee is covered the moment they arrive — per D4, the household is the unit. **Depends on Google sign-in**, which is already in the auth bundle below: the second parent may not have an Apple device, and an invite they cannot accept is not an invite. **Apple Family Sharing is not used** and this phase must not reach for it — D4 records why: it creates a second, Apple-owned opinion about who is entitled

## Phase 37 — Entitlement and StoreKit
<a id="phase-37"></a>

**Status marker, as the live ledger carries it:** ✅ **both halves shipped Aug 20, 2026** — ~~*37b is not built*~~; the client half is the **37b** row below

**Split, and the order is D5's argument rather than convenience.** The device never decides whether a household is subscribed, so the *writer* has to exist before the *buyer* does — built the other way round, a successful purchase is a client-side boolean for however long the gap lasts. **37a is the server half and it is done**: migration `0019_app_store_transactions` (head was `0018_social_assets`), `POST /v1/webhooks/app-store` verifying Apple's `x5c` chain through Apple's own `app-store-server-library` — the one dependency this phase adds — and `GET /v1/families/{id}/entitlement` computing `eligible_at` off both of D3's clocks per request. **`entitlements.tier` now has exactly one writer and a test pins it there**, the way phase 60 pinned the absence of a `subscribers` table; `runbook-deploy.md` §7a is demoted from *the only way in* to *the override*, and ~~there is still no admin route~~ — **corrected Aug 24, 2026 by phase 121, and the correction is one word: there is still no admin route that writes `tier`.** Phase 107 added one that writes `entitlements.trial_ends_at` and phase 121 added three that write `entitlement_grants`; both are sources of *entitlement* beside the column rather than into it, the exactly-one-writer test this row is about passes unmodified, and nothing in this API can set a tier over HTTP except a payload Apple signed. **Three guards matter more than the notification table**, and each is break-tested: `signedDate` ordering, because Apple's retries interleave with new notifications and an `EXPIRED` arriving after a `RESUBSCRIBE` sets a paying household free while every unit test passes; sandbox isolation, because a free tester account would otherwise subscribe production households; and **the refusal to demote a family with no transaction record, which is what stops the webhook undoing §7a's hand-written row and locking the owner out of his own product** — a refused demotion deliberately does not record the attribution it was refused for, or the guard is a one-notification delay rather than a guard. **Re-reading the diff found five real defects and the two most expensive were found by checking the code against Apple's vocabulary rather than against the phase's description of it.** *(i)* A nested `signedTransactionInfo` that failed verification raised the library's exception past the router's one narrow `except`, turning a forged inner transaction into a 500 where the answer is 401. *(ii)* **A demotion carrying no `appAccountToken` never landed** — the token is attached at purchase and the `EXPIRED` two years later is furthest from it, so a household that stopped paying kept `subscribed` forever; attribution now falls back to the ledger row, which *is* the transaction record the guard asks for. *(iii)* **A Sandbox payload could advance a Production row's `latest_signed_date`**, after which every legitimate Production notification looks stale and the tier freezes silently — one `originalTransactionId` now belongs to one environment and a mismatched payload is refused rather than recorded, because the transaction id is the primary key and the choice is refuse or corrupt. *(iv)* A notification carrying no `expiresDate` erased a known one, which phase 38 schedules against. *(v)* **`AUTO_RENEW_OFF` and `AUTO_RENEW_ON` are not values Apple sends** — the real subtypes are `AUTO_RENEW_DISABLED` and `AUTO_RENEW_ENABLED`, and two tests were asserting the right outcome for a value that does not exist. The behaviour was already right, so nothing failed; a test now pins every notification string this service branches on against `appstoreserverlibrary`'s own enums. **And one fix was worse than its bug**: requiring `APP_STORE_BUNDLE_ID` at startup when `APPLE_BUNDLE_ID` names two audiences broke four `test_auth` cases and would have taken the whole API down the day a web Services ID was added, for a webhook already answering 401 for want of a root certificate. It fails closed at the verifier instead. **Two things it could not do, and both are honest gaps rather than shortcuts.** Apple's real root certificate is **not in the repository** — `www.apple.com` is refused by the build environment's egress policy and the root is in neither `certifi` nor the system CA bundle — so the endpoint **fails closed with 401 on every notification** until one `curl` is run; `api/src/rascal/certs/appstore/README.md` is that command. And `APP_STORE_APP_APPLE_ID` is unset, without which Apple's library refuses to build a Production verifier at all. **Nothing here has ever been exercised against Apple**: no product exists in App Store Connect, no sandbox transaction has ever been made, and no real Apple notification has ever reached this endpoint — every payload in the 75 new tests is synthetic, signed by a locally-minted chain that carries Apple's marker OIDs — the first stub was rejected by Apple's verifier until it did. Suite **986**, from 911. **`REFUND_REVERSED` is a known gap, pinned by a test rather than discovered later**: a refund Apple later reverses leaves the household `free`, because 37a implements the table it was given. The row is recorded, so it is recoverable by hand. **37b is the StoreKit half** — `Product.products(for:)`, the paywall, the purchase flow, restore — and it carries one obligation this phase cannot enforce from here: **`appAccountToken` must be the purchasing user's `family_id` on every purchase**, because it is the only channel Apple has for carrying one, and transactions made without it are unattributable permanently

## Phase 37b — StoreKit, the paywall and the purchase flow
<a id="phase-37b"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 20, 2026**

iOS lane, and **nothing has been bought.** The client half of 37: `Product.products(for:)`, the paywall, the purchase, restore, the `Transaction.updates` listener and a Membership card in Settings. **Suite 1084 in 137 suites, from a measured 1029 in 129** — the 957/117 phase 61 reported was eleven phases stale and was not used. **`appAccountToken` is the household's `family_id`, made structural rather than remembered**: the argument is non-optional and the only state carrying one is `Phase.ready(_, familyID:)`, so no branch can start a purchase without a household to attribute it to — the paywall shows a retry instead of a buy button. **The confirmation gap is the part that took the design.** A verified purchase does not make the app subscribed, per D5; it polls `GET /v1/families/me` on a named schedule — 1s, 2s, 4s then 8s, ten reads, 63 seconds — and on timeout says *the subscription is being confirmed*, which is terminal, reassuring and explicitly **not** another purchase. **The paywall renders from values rather than from `Product`**, which was forced twice over: `OfferedPlan` copies price, period and trial off the product at the boundary and nothing above it imports StoreKit. That is what let the purchase flow be proven against a fake **and** let Dynamic Type screenshots exist at all — fifteen of them, at `xxLarge`, `accessibility3` and `accessibility5`, committed under `RascalTests/__Screenshots__`. **The harness first produced blank cream and passed**: `ImageRenderer` does not rasterise a `ScrollView`'s content and a height assertion could not tell the difference. Caught by *looking at the PNG*; the fix is a content view outside the scroll plus an ink-fraction assertion. **A review pass of every line raised 47 findings and eleven were real**, of which three would have reached a paying parent. *(i)* **Any app foreground was indistinguishable from an Ask-to-Buy approval** — one `revision` counter served both the transaction drain and the foreground re-check, so a parent who started an Ask-to-Buy, backgrounded the app to go and ask, and came back was told *"Your subscription is being confirmed — there's nothing else you need to do"* while nobody had approved anything, terminally. The counter is now bumped only by the drain. *(ii)* **Restore delivered its verdict on one immediate read**, so it said *"nothing to restore"* in precisely the case restore exists for; it now runs a shorter confirmation window and no longer makes a claim about what the Apple Account holds, which the client cannot see. *(iii)* **`confirm()` threw away the household the poll had just proved and read again**, so a failed second read left the app subscribed with an em dash where the household goes; the outcome carries the value now. Also: the paywall had **no way out before buying** — phase 61 had a *Got it* and losing it was a regression, so *Not just now* is back; a **configured trial was promised to accounts Apple would not grant one to**, now gated on `isEligibleForIntroOffer`; a load failure could **erase the post-purchase copy from somebody already charged**; `Product.PurchaseError` reached parents as `localizedDescription`; the unselected plan's radio was `inkFaint` at ~2.1:1; and the covered-line checkmark was a fixed 12pt glyph beside text that scales to 53pt. **The one `critical` finding was false** — the buy button was reported as truncating at accessibility5 and it wraps; it was refuted by reading the committed screenshot rather than the claim. **Two things it could not do.** `SKTestSession` **cannot install a configuration on this machine** — `SKInternalErrorDomain Code=3` on every configuration shape (six tried, down to a minimal one), both signing modes, iOS 26.3 and 26.4, an erased device and a fresh one, with `storekitd` running and `StoreKitTest.framework` present in the runtime. `SubscriptionStoreKitTests` is written, committed and `.disabled` with that reason in the trait; `Vellum.storekit` is committed so it runs the moment the environment does. And **nothing has run against Apple**: no product exists in App Store Connect per `docs/blocked.md` §10, so **the `appAccountToken` round trip to 37a's webhook has never been observed end to end** — the assumption the phase rests on, and no local test can exercise it. **A `/rascal-review` pass on the finished branch then found two more**, and the first is the sharper of the two: **the guard for the foreground bug was pinned by nothing.** `theListenerIsWired` greps for two substrings that both survive the single edit that reintroduces it — moving `transactionDelivered()` inside `refresh()` — and the behavioural test sat at the model layer, never through `SubscriptionCenter`. That edit failed **0** tests before and fails **4** now. The second: a restore that *succeeded* left a greyed-out buy button and no sentence, because `notice` is cleared on entry and `purchase` stays `.idle` while `canBuy` goes false — the failure path got a sentence and the success path got silence. Fixed in the view rather than in restore, so it also covers the entitlement landing while the sheet is open from another guardian or another device. **A third finding was rejected on the artifact**: two independent reviewers read `PrimaryButtonStyle`'s missing `lineLimit` as truncation of the buy label at accessibility5, and the committed screenshot shows it wrapping to two lines — it is now in `.claude/review-history/false-positives.json`, because two reviewers finding it independently means a third will. **Break-tests, on the final tree: 1, 4, 1, 3.** Break-test 3 originally failed *nothing* — the tests that would catch a deleted listener are in the disabled suite — so a source assertion now fails on it, honest about being one; and break-test 4 fails three, so a hardcoded price does not pass unnoticed. **Nothing has run on a device.** `CFBundleDisplayName` is still unset — phase 82 — and the StoreKit purchase sheet is one of the system dialogs that leaks `Rascal`, which makes 82 blocking for anything customer-facing rather than cosmetic

## Phase 38 — Lifecycle notices
<a id="phase-38"></a>

**Status marker, as the live ledger carries it:** ○ **new, Aug 15, 2026**

**The phase D3 actually requires, and it is not part of 37.** The win-back and deletion-warning pipeline, the two consent lanes as separate fields, per-channel delivery records, and the job that moves original media to the Archive tier at 90 days lapsed. Deletion may not fire unless a notice was confirmed delivered on some channel, and any sign-in in the warning window cancels it outright. Shipping 37 without this gives a product that can lapse a family and never tell them

## Phase 39 — Print partner evaluation
<a id="phase-39"></a>

**Status marker, as the live ledger carries it:** ○ **new, Aug 15, 2026**

**A research task, not an implementation.** Scored against the D6 constraints with **margin retained as the primary criterion** — not sticker price, because consumer photo-book brands keep the retail margin while wholesale print-on-demand APIs charge print-and-ship with no service fee. A public self-serve API is required; contact-sales is disqualifying for a solo developer. No partner is chosen in D6 and none may be chosen without this

## Phase 60 — `POST /v1/subscribe`, and Resend replaces Postmark
<a id="phase-60"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

Built to the merged design and not the sprint's, which contradicted it on all four points. **`TURNSTILE_SECRET_KEY` unset refuses rather than skipping** — the defect this row named, now break-tested: making it skip fails exactly one test. Cloudflare unreachable is a `503` for the same reason, since failing open would let an outage at their end open ours. **No `subscribers` table**, and a test asserts the absence so the day somebody adds one they argue with the decision rather than around it. The `stream` argument is on the **existing** `services/mail.py` port and `PostmarkProvider` is **deleted, not disabled**, with `auth.py` and `me.py` repointed to `transactional`. CORS is allowlisted to `MARKETING_ORIGINS` and an empty list means *no* origin rather than `*`. **720 tests.** What is not done: no template beyond the minimum, ~~no scheduled send, and **nothing has actually sent** — `MAIL_PROVIDER` is still `console` everywhere, so this is a working endpoint whose provider has never been switched on~~ — **struck Aug 22, 2026 by phase 111. The provider is switched on**: `MAIL_PROVIDER`, `MAIL_FROM`, `MAIL_API_KEY` and `RESEND_AUDIENCE_ID` are Deployed secrets, there **is** a scheduled send (Fly machine `683e1eea463d28`, created Aug 19), and four broadcasts have gone out. **The clause worth keeping is the one about the swap being cheap only while there is no history** — that stopped being true on Aug 19, 2026, so a provider change from here carries a warmed domain and a suppression list. Owner actions remain `blocked.md` §13

## Phase 61 — Guardians on the phone
<a id="phase-61"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

iOS lane, PR **#107**. The client half of 36: a **Who shares this** section in Settings — the household, any outstanding invitation, and a way to send one. **The find was that the paywall was unreachable code**: `subscription_required` was absent from `APIErrorCode`, so the server's 402 arrived as `.unknown(…)` and no branch could ever match it, however carefully the model was written. Break-tested — removing the mapping again fails exactly one test. Per D4 the second guardian is what one-price-per-household is sold on, so this is the upgrade surface rather than a refusal: framed as what the subscription unlocks, no red, no countdown, and **no StoreKit stub** because 37 owns that and a "coming soon" would be furniture for months. The error copy is the server's own words, not a client paraphrase. **Removing a guardian is deliberately absent** — open item 13. **957 tests in 117 suites.** Two things it could not do: no Dynamic Type XXL screenshots yet, and **nothing has run on a device**

## Phase 62 — The invite link opens the app
<a id="phase-62"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

API lane. 61 built the link and **it landed in Safari**, because the association file claimed `/signin` alone — a cross-lane dependency 61 named and correctly refused to patch from the iOS side (`ios/CLAUDE.md`: a screen needing something the API does not serve is a conversation, not a patch to the backend). `/invite/*` is now a **second explicit path, never `*`** — claiming the host would make the app intercept `/health` and every presigned media URL, and the test pins the exact list so a third claim has to be justified. **The token is in the path, so the claim carries no `?` clause**; copying `/signin`'s query form onto it is a near-miss that fails silently, and there is a break-test for exactly that. `GET /invite/{token}` serves a browser page that, unlike `/signin`'s, **does not assume the app is installed** — the other parent may be meeting Dogear for the first time on a laptop. It discloses nothing about the household and never echoes the token

## Phase 63 — Tapping the invitation
<a id="phase-63"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

iOS lane, PR **#109**. The screen the second parent sees: preview, sign in through the path that already exists, join. **Every failure gets its own sentence, and that is the phase rather than a nicety** — whoever taps this may never have heard of Dogear, cannot retry their way out of an expired invitation, and *"something went wrong"* makes the other parent debug it. The four states the server folds into one `404` stay folded, because telling them apart would say whether a token ever existed. **Only the unreachable state offers a retry**, the one where the identical request could plausibly succeed. **The token is held on the gate, not in the screen** — whoever taps it is usually signed out, and a token living in a sheet would be gone the moment they went to the welcome screen. Break-tested: dropping the host check, and matching `/invite` without its trailing separator, each fail exactly one test. **967 tests in 118 suites**

## Phase 64 — The XXL previews the two client phases owed
<a id="phase-64"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

iOS lane. 61 and 63 both shipped saying Dynamic Type XXL screenshots were owed and not done; this is that debt, paid in the form the codebase actually uses — an Accessibility XXL preview beside the default one, which is what `design-system.md` asks of the catalog. **17 previews across the two new surfaces, 5 of them at `.accessibility4`**, and every *failure* state has one rather than only the happy path: those are the longest sentences in the flow and the ones nobody opens the canvas to look at. Both models gained a `DEBUG`-only `previewing:` initializer whose `load` is a no-op — without it each preview would replace its parked state with whatever the machine's connectivity produced, and the states worth seeing would be the ones impossible to see. **These are previews, not PNGs**: nothing here renders an image, and a device pass still owes the screenshots a reviewer can look at without Xcode

## Phase 65 — In-app account deletion — investigated, and it blocks submission
<a id="phase-65"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026 — docs only, no code**

Answers `decisions.md` open item 14, which was filed the day before as *unanswered rather than a known gap* because the sprint story that would have covered it halted on a missing tool. **The cheap outcome is ruled out:** five `DELETE` routes and none deletes an account, the phrase appears nowhere in `api/`, `ios/` or the contract, and **there is no `delete_object` call anywhere in the service** — nothing has ever removed a byte from object storage. **That last one is phase 38's problem too**: D3 already promises lapsed media is deleted and no code could carry it out. **D3 does not cover this** — it fires on lapse and inactivity and is *media only, text never*, where a person asking to leave is a different trigger with a different scope. Left as a spec rather than a PR **because the operation is irreversible over a child's archive** and three product questions are genuinely open, chief among them what deletion means in a two-guardian household — which is item 13 from the other direction. Evidence in `docs/investigations/account-deletion.md`; recommendations for all three are in the item

## Phase 16 — Video audio tracks
<a id="phase-16"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

iOS lane, and **it needed less than it was specified around.** Story 6 and this phase's own first implementation assumed `AVAudioFile(forReading:)` could not open an mp4, so a video's audio had to be exported to a separate m4a first. **A diagnostic says otherwise**: handed a real H.264 + AAC mp4 it opens it and reads *22050 frames at 44.1 kHz mono* — the exact audio written in. Core Audio reads the track straight out of the container, so the export was machinery for a problem that does not exist and it is gone. **What the premise had been hiding is the part that matters**: a video with *no* audio track fails to open, which `SpeechTranscription` reports as `bytesUnreachable` — so a silent clip would have burned its whole six-attempt retry budget over hours against a video that never had sound. Silent clips are ordinary: screen recordings, a covered mic, a moment trimmed to no sound. They now take the same path as a recording of a child who would not talk — done, attempts reset, nothing written. A ten-minute cap survives, and is the one case an export still earns. **982 tests in 120 suites.** Unblocked by phase 68 correcting the checklist sentence its preflight read; **§0 is still 0 of 45 and still wants running**

## Phase 66 — Account deletion, the server half
<a id="phase-66"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

API lane. Builds what 65 found missing, to the answers settled the same day. `POST`/`DELETE /v1/me/deletion`, a `deletion_requests` table, a `jobs/delete` scheduled job with a `--dry-run`, and **the first code in this service that deletes a byte from storage** — `s3.delete_objects`, batched, which **phase 38 also needed and did not have**. **The spec met the schema and the schema gave:** `entries.author_id` was `NOT NULL ON DELETE RESTRICT`, so a departing parent whose entries survive would have made the user delete fail outright. Item 14 says the entry survives and item 13 says the attribution is kept; both cannot hold once the person is erased, so the key is now `SET NULL` — null meaning *"written by somebody no longer here"*, which is true, where reassigning to the remaining parent would be a false claim about who wrote a sentence. **There is no `completed_at`**: a completed deletion has no row, so the column could never hold a value. **The one place in the service that hard-deletes user data**, stated as a deliberate exception to rule 5 rather than left to look like an oversight. Break-tested on the two that matter — ignoring other guardians, and reading object keys after the rows are gone — each fails exactly one test. **732 tests.** The client half is phase 67; until it ships, the App Store requirement is **not** satisfied, because Apple's rule is about a surface a parent can reach

## Phase 67 — Account deletion, the client half — and the blocker closes
<a id="phase-67"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

iOS lane. The Settings surface 66 needed, which is what Apple's rule is actually about — an endpoint that exists satisfies nothing. **Its own card at the bottom with whitespace above it**, terracotta like any other action, because `design-system.md` says there is no destructive colour here and weight comes from placement; the one red is the system's, in the `role: .destructive` confirmation, which the design system already allows. **A break-test found the real gap and it was in the copy**: the sheet tells a parent with a second guardian that the children *stay*, and a sole parent that the archive *goes* — and making it always claim deletion compiled cleanly and passed every test. The words are `DeleteAccountCopy` now, asserted in both shapes, because copy that decides whether a sentence is true belongs where a test can read it. **Requesting signs you out, so the explicit cancel endpoint is not the route anybody takes** — signing back in is, and the server does it. **977 tests in 119 suites**, and five previews including two at XXL. Still unrun on a device

## Phase 68 — Unblock everything, and stop calling my own deferrals owner errands
<a id="phase-68"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 17, 2026**

Docs lane. Cleared the blockers the overnight sprint had generated against itself, moved the owner-reviewed email copy into `docs/marketing/`, and applied `proposed-claude-md-diff.md` rather than leaving it pending. **The correction worth keeping is the framing one**: several things filed as *owner errands* were an agent's own deferrals wearing a costume, which is how a night's work produces a morning of homework nobody asked for.

## Phase 69 — The daily prompt broadcast, with the send withheld
<a id="phase-69"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — ~~*PR #118, open*~~, merged 10:37 UTC. **Armed Aug 19, 2026 and sending since**, which this row did not say until phase 111 read production on Aug 22

API lane, and ~~**nothing has been emailed to anybody.**~~ — **struck Aug 22, 2026. It has been emailing people for four consecutive days.** `MARKETING_EMAIL_ENABLED`, `MAIL_PROVIDER`, `MAIL_FROM`, `MAIL_API_KEY` and `RESEND_AUDIENCE_ID` are all **Deployed** secrets on `rascal-api`; Fly machine `683e1eea463d28` / `late-fire-837` was created **2026-08-19T02:15:36Z** with command `["python","-m","rascal.jobs.broadcast"]` and `grp=(none)`; and `email_broadcasts` holds **four rows, all `status='sent'`** — Aug 19 (pool 8), Aug 20 (9), Aug 21 (10) and Aug 22 (11) — **none failed and none skipped.** The machine wakes hourly and the job's own hour check is what keeps that safe: today's 13:15Z run logged *"broadcast: not the send hour — it is 09:15 EDT, sending at 08:00."* ⚠️ **Who received them is not recorded anywhere and is deliberately left blank rather than estimated**: `MAIL_API_KEY` is send-scoped and `GET /audiences/{id}/contacts` answers **403** from inside the production machine, so the recipient count exists only in the Resend dashboard. **The four sends went out with no rehearsal** — `phase-queue.md` had asked for one run with `--date` against an audience of one first, and the first real send was the first send. The job picks the prompt, renders both bodies, writes its ledger row and logs the whole rendered mail, then stops before the network call — one environment variable, `MARKETING_EMAIL_ENABLED`, kept deliberately **separate from the credentials** so that setting `MAIL_API_KEY` to make the subscribe route work does not also start mailing strangers. ~~Open item 12's *no marketing email before the P0 behavioural gate* is unbroken.~~ — **the holding was struck by the owner on Aug 22, 2026, not broken by this job**: the P0 behavioural gate no longer gates marketing email, and the separation this phase built is what let the arming be a single deliberate secret rather than a side effect of making the subscribe route work. **That design is the reason the reversal was one decision instead of an incident**, and it is worth keeping the sentence to say so. **Story 4's gate 2 could not pass and should not have**: it requires story 1's `subscribers` table and webhook, and phase 60 shipped the settled design where the list is provider-held. **Two forced departures.** The ledger holds no recipient — a per-subscriber table would be the mailing list in our database under another name, and the privacy page published the same day says we hold no copy; a test asserts no column here is ever named for a person. And the copy is generated to YAML rather than parsed at runtime, because **`docs/` is not in the Docker image** — Fly builds from `api/` and the Dockerfile copies `src`, `alembic`, `seeds`, so a loader pointed at `../docs/` passes every test on a laptop and raises `FileNotFoundError` on the first scheduled run. **The welcome sequence is not built and cannot be from here**: it drips off each subscriber's `confirmed_at`, which lives at Resend. ~~**Unverified: the Resend Broadcasts API has never been called.**~~ — **it has now been called four times, Aug 19–22, 2026, and every call succeeded.** Four `resend_id`s are on the ledger rows. 23 tests; suite 753

## Phase 70 — The Vellum wordmark, the logo kit, and the app icon
<a id="phase-70"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026**

Docs lane, `docs/app-icon/`. **The fan survives the rename**, which phase 47 predicted it would: the mark carries no word, so the icon is that mark plus exactly one change — the front card's entry title, a 138×15 bar standing in for a line of type, becomes the line of type it was standing in for. Chosen by the owner over a wordless V-fan and a monogram, **both kept in the tree**, because a candidate nobody can look at again is a decision nobody can revisit. **The wordmark is drawn, not set** — a monolinear skeleton stroked with round terminals, every curve a true circular arc — so there is no font file to ship, no licence to honour, and nothing to render differently on a stranger's machine. Owner picked build 5 of 8 (short ascenders) and lowercase; **the chosen metrics are the generator's defaults**, so the lockups and the icon are the chosen build by construction rather than by a number copied across three files. **Two finds, both invisible until the ground changed.** The colour lockups painted the gap between cards in canvas cream — correct on the app's cream, and a warm halo on the marketing site's white, where the mark read soft-edged rather than cut. They knock the gap out of the card behind now and are ground-independent, byte-identical on cream. The one-colour lockup could not take depth from translucency for the same class of reason: overlapping sheets compound and go muddy the moment the ground is dark. ~~**The hover component deliberately goes the other way** — it strokes in white, trading ground-independence for motion, which is the right trade in a header with one known background~~ — **struck by 70a: that was not a trade, it was a static mask.** The mask's shapes now carry the card class, so one rule moves both and the knockout tracks the card without knowing its ground. **The site would have caught the stroked version in production**: its masthead is `color-mix(canvas 88%, transparent)` over a `backdrop-filter`, so content scrolls underneath and tints it — no solid stroke colour is right at every scroll position, and the halo would have appeared only once somebody scrolled. **Nothing has shipped to a phone**: `render-appicon.mjs` still reads `rascal-icon-fan.svg`, which was not modified — repointing it is an iOS-lane change and takes its own number. `index.html` is hand-kept and no script writes it, per `generate.mjs`'s own header

## Phase 71 — Dogear becomes Vellum, the API half
<a id="phase-71"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — ~~*PR #119, open*~~, merged 10:45 UTC

API lane. The owner settled the name Aug 17: *"Our name is officially Vellum."* 21 occurrences across 9 files — sign-in and confirm-address email subjects and bodies, `wellknown.py`'s public HTML page, `mail_from`, and the export viewer. **The trademark risk was on the table and he proceeded knowingly**: *Vellum by 180g* is a live software trademark in a publishing-adjacent category and no clearance search has been run. Recorded as open rather than cleared, because outbound email cannot be recalled once sent. **The last rename's precedent held verbatim** — display strings move, identifiers do not: `manifest.format` stays `rascal-export` through a second rename, and its comment now names both, so the next reader sees a string that has held twice rather than one that happened to survive. **`docs/marketing/email-sequence.md` was deliberately not touched** — its header forbids an agent editing that copy, so its 5 occurrences and the 4 in the generated `seeds/email_copy.yaml` are the owner's, in that order. D5a's subscription group moved to `Vellum Membership`, which was free only because nothing exists in App Store Connect yet

## Phase 72 — The false-claims sweep
<a id="phase-72"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — ~~*PR #120, open*~~, merged 10:45 UTC

Docs lane, commissioned after story 5 fixed two pages and missed six. **Mechanical rather than a reading**: served routes taken from the app's own OpenAPI schema, every `__tablename__` checked against `data-model.md`, and the docs and iOS strings swept for absolutes. Three findings in `api-contract.md`, which `CLAUDE.md` names authoritative. *"Nothing is deleted in this system"* has been false since phase 66. **`POST /children/{id}/guardians` is documented in the present indicative and has never existed** — guardians are invited through `POST /families/me/invites` — and that is worse than a stale sentence, because story 3b's own gate says to build against this file, so a client written from it would call a 404. `POST /debug/board` was served and undocumented, the only route in the service missing. **What was sound is recorded too**: all 21 tables documented, and three of four documented-but-unserved routes were already honest — two subjunctive, one explicitly negated — which is why every hit was read before being called a finding. **A diff of route names cannot tell a lie from a plan.** The route diff now comes back clean in both directions

## Phase 73 — Dogear becomes Vellum, on the phone
<a id="phase-73"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — ~~*PR #121, open*~~, merged 10:46 UTC

iOS lane, the other half of 71. 34 occurrences across 16 files. **The four bundle display names are the part that matters** — app, debug variant, share extension and widget all carry `CFBundleDisplayName` explicitly and have to agree, because iOS groups the widget gallery by the app's display name. **One string is wrong rather than stale if the bundle does not move**: *"Settings → Vellum → Notifications"* tells a parent where to go in iOS Settings, and iOS labels that row with the display name. **It also unblocks something outside this repo**: the marketing site's onboarding screenshot has the old wordmark baked into its pixels and had been rated three stars for *correct branding*, which is the kind of note that walks somebody into publishing a dead name — it needs this build and a fresh capture. **982 tests in 120 suites, 0 warnings** under CI's own gate

## Phase 74 — Story 7 — the sprint reconciled against the tree
<a id="phase-74"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026 — docs only, no code**

Docs lane, and the phase exists because the two status files belong to this story alone. **Gate 1 was not satisfiable as written and was met in substance**: it wants every other story merged, while the runbook forbids a story merging its own PR — taken literally, story 7 can never run unattended, which is the trap that produced a night of halts and nothing to review. Open PRs were filed as *PR open*, never as shipped. **Story 7's own instructions were partly false, and its gate 3 is what settled them**: if a report and the tree disagree, the tree wins and you write down the discrepancy. **Five claims it asked to be written into open item 12 do not survive contact with `main`** — a `subscribers` table as the source of truth for consent, a welcome sequence sending through the Emails API, a consent webhook, a rate-limit exception the owner had declined, and a numbering disagreement thirteen phases stale. The discrepancies are recorded; the claims are not. Written: the queue's high-water mark 68 → 73 with the staleness recorded rather than quietly fixed, six ledger rows for 68–73, open question 11 closed with the reason idempotency needed two partial indexes rather than one wide one — **Postgres treats NULLs as distinct, so a single index would silently accept a duplicate shared slot** — open question 12 updated with what phase 69 actually built, 36 un-iceboxed in the owner's framing that he had been reading *guardian* as grandparents when he wanted a second parent, two new open questions, nine follow-ups and a log entry. **Gate 4: no device box was ticked. Section 0 is still 0 of 45**

## Phase 75 — Stop a test asking the machine what day it is
<a id="phase-75"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026**

API lane. Phase 71 fixed one instance; **this is the guard, so the next one fails at the assertion rather than four hours a day in CI.** The defect: `test_guardians.py` fetched a board with `?date=dt.date.today()` — the runner's local date — while `routers/today.py` computes `local_today` in the child's `family_timezone` and only calls `ensure_day_filled` when the two agree, because `?date=` is a debugging override and **a read endpoint must not mint rows for an arbitrary day.** Between 00:00 and about 04:00 UTC those disagree: UTC is already tomorrow while America/Detroit is still yesterday. The board came back empty, **the suite failed for four hours a day and passed the other twenty**, and every developer here runs US-Eastern where the two never disagree — so it was invisible locally and got blamed on whatever had landed most recently, in this case a rename that touched no scheduling code at all. It sits in `test_fixture_dates.py` beside the future-date guard because it is the same argument: **a green run says nothing about which branch it took.** **AST rather than text**, so the comment in `test_guardians.py` explaining why the call was removed is invisible to it — grepping the source would flag the explanation as the defect. Escape hatch `# machine-clock: <why>`, because a test genuinely about the runner's clock is legitimate. Break-tested: reintroducing the exact line fails the guard and names it, and nothing else. No other offenders today, including no naive `datetime.now()`

## Phase 76 — The last of the dead name, and the errand in one place
<a id="phase-76"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026 — docs only, no code**

Docs lane. **The owner authorised the email-copy edit explicitly, as a name swap and nothing else**, so that is exactly what it is: five words in `docs/marketing/email-sequence.md`, verified by word-level diff, no sentence rewritten and no subject touched. That file's header forbids an agent *authoring or improving* the copy, and swapping a product name the owner has already settled is neither. The generator was then re-run so `seeds/email_copy.yaml` **follows rather than being edited** — a direct edit there is discarded on the next regeneration. **That was the last place `Dogear` survived in this repo outside deliberate historical records.** `blocked.md` §13 gains what it was missing: its steps said what to create and stopped short of where the result lands, **and the second half is where an errand stalls at a keyboard.** There is now a row per value with its exact destination — which file, or which `fly secrets set` — including that the setting is `MAIL_API_KEY` and **nothing reads `RESEND_API_KEY`**, that the Resend key must be full access rather than `sending_access`, and that Enforce HTTPS has to be verified by eye because it cannot be enabled until the certificate issues. **`MARKETING_EMAIL_ENABLED` is deliberately not in that table**: it is the switch that sends, it defaults false, and it is separate from the credentials precisely so that completing the table cannot start mailing anybody

## Phase 77 — The wordmark is drawn, not set in caps
<a id="phase-77"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026**

iOS lane. The welcome screen said `Text("VELLUM")` — the word typed in capitals with 2.6pt of tracking standing in for a logo. It is the only place in the app where the name is a **mark** rather than a sentence, and **it is also the one string a case-sensitive rename could not see**, which is what surfaced it: the Dogear → Vellum pass swept 34 occurrences and walked straight past the first screen anybody sees. It is now the drawn wordmark from phase 70, ported from `docs/app-icon/vellum-wordmark.svg` with the coordinates unchanged. **Ported rather than imported, and that is why it was cheap** — the word is geometry, not set type, so there is no font file to embed and no licence to honour; it needs no asset-catalog entry and no vector format, so rule 4 is satisfied without argument. **The SVG arcs are flattened to cubic Béziers rather than handed to `addArc`**: SVG arcs are endpoint-parameterised and `addArc` is centre-parameterised, and the clockwise flag's meaning depends on the coordinate system it is read in — exactly the kind of thing that renders mirrored and passes every test. **Second change, a copy defect rather than a rendering one**: the line under the buttons read *"Your archive is tied to your Apple ID. There's nothing else to set up."* That stopped being true when Google sign-in shipped in phases 55 and 58 — anybody taking the Google row does not have an archive tied to an Apple ID. The option was added and the sentence justifying the old single option was never revisited

## Phase 70a — Teach the knockout mask to move, and drop the trade it was working around
<a id="phase-70a"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026 — docs only, no code**

Docs lane, and it exists to strike a law phase 70 had just written. Phase 70 shipped the hover component stroking its card gaps in the page colour, reasoning that a knockout mask is built from where the cards *are*, so a rotating card leaves its notch behind and the mark tears. **That is true of a static mask, and a static mask was the only kind that had been tried.** Give the mask's shapes the same class and the same custom properties as the cards they mirror and one CSS rule moves both. **So the documented trade between motion and ground-independence was not a trade — it was a static mask**, and the write-up had promoted an untested limit to a law. **Applying it to the marketing site is what surfaced it, and that site would have caught the stroked version in production**: its masthead is `color-mix(in srgb, canvas 88%, transparent)` over a `backdrop-filter`, so page content scrolls underneath and tints it continuously — no solid stroke colour stays right at every scroll position, and cream would have painted a visible halo over a photograph twenty pixels down. **A defect that appears only once somebody scrolls, which is the kind that ships.** Also corrected: the component and the contact sheet were both written for *"a white background"* and the site is not white — canvas is `#FDFAF4`, the footer sits on `#FFFDF9`. `hoverComponent()` now takes `cls`, `id`, `anchorClass`, `label` and `href`, because **two inlined copies on one page sharing a mask id means the second silently borrows the first's** — which lives in the other's subtree and never sees the second's `:hover`, so that mark tears the moment it opens. **The general form is worth more than the fix**, and it is recorded in `decisions-log.md`: a limit found while building one thing is a property of that build until it has been attacked separately

## Phase 70b — Strike the trade phase 70 recorded as a law
<a id="phase-70b"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026 — docs only, no code**

Docs lane, merged 22:59 UTC as PR #128. **70a fixed the mask; this struck the law the write-up had made of it**, in `roadmap-status.md` and `decisions-log.md`, keeping the wrong paragraph rather than deleting it because *the mistake in it is the useful part*. **The general form is what it exists to record**: a limit found while building one thing is a property of that build until it has been attacked separately, and writing it down as a law makes it permanent. **It propagated** — another agent recorded the false trade in the marketing repo's brand notes on the strength of that paragraph, and a reciprocal invented reason about the Markdown twins travelled the other way into this repo's `footer.html`. **Neither agent caught its own; each caught the other's.** Both are struck in both repositories now, independently. **The tell both shared is the reusable part: each explained why something was impossible** — the class of statement that closes a question instead of opening one, which is why nobody re-derives it

## Phase 78 — The name is never set in capitals
<a id="phase-78"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — ~~*PR #129, open*~~, merged 22:59 UTC, **nineteen minutes after this row was written calling it open.** Recorded rather than silently corrected, because it is the smallest possible instance of this file's standing failure and it happened *to the fix for that failure*: a status written as a state rather than as a state on a date goes stale at whatever speed the tree moves, and tonight that was minutes

iOS lane, and the rule phase 77 earned. **Owner's rule, Aug 18, 2026, with no exceptions: the name is never set in capitals.** `docs/design-system.md` gains a *The wordmark* section stating where the name is a **mark** — `WordmarkView`, drawn geometry, one place on purpose, the welcome screen — and where it is a **word in a sentence**, written sentence case, because *a mark dropped into running copy reads as a brand intrusion.* `.textCase(.uppercase)` survives in exactly one place, the tab bar's own generic chrome, **and the section says it must stay that way** — any uppercasing modifier that could reach the name reintroduces the closed failure by a different route. **Filed here as open and not as shipped**, per phase 74's rule; it is also the reason a genuinely new phase today takes **79**, since 78 is taken and is not on `main`. Its Swift half is `DesignSystem/Wordmark.swift`

## Phase 79 — Recording survives the screen going dark
<a id="phase-79"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — merged 23:03 UTC as PR #130; ~~*built and green, not merged*~~ **was true for roughly twenty minutes.** The third state this ledger had no word for turned out to be the shortest-lived one, and the row naming it went stale faster than the two it was written to distinguish

iOS lane. **Deliberately not marked shipped**: the code is committed on `ios/phase-79-recording-durability` (`1bed443`) and unmerged, and phase 74 set the rule this file now follows — *open PRs are filed as PR open and never as shipped*. **Built and unmerged is a third state and this ledger had no word for it**; it is not *unstarted*, which would be false, and not *shipped*, which would be the exact overclaim this file has made six revisions running. `isIdleTimerDisabled` ownership scoped to capture only, and the `AVAudioSession` interruption path proved to finalise the m4a. **The defect it closed is the interesting one and it is a class, not an instance**: `AudioPipeline` promised *"recorded bytes are never lost"* and kept that promise, then `StagingSweeper` deleted the finalised file on the next foreground because a take gets no `Media` row until the composer saves and the sweep had no age guard. **A correct guarantee in one type, voided by an unrelated sweep in another, with neither file wrong on its own terms.** 24-hour grace window; **995 tests in 121 suites**, five break-tests. Its device coverage is `device-verification-transcription.md` §4a

## Phase 80 — An entry with unsynced media never reads as "Nothing was recorded"
<a id="phase-80"></a>

**Status marker, as the live ledger carries it:** 🔵 **PR #131, open** — opened Aug 18, 2026; ~~*built, not committed*~~

iOS lane. `EntryDetailScreen` prefers local staged bytes over an API URL resolution, so a take that has not synced still plays. **The specification was the defect**: `design-system.md:496` said playback *"resolves its media through the API"*, and `voiceCanvas` was already passing `localFile:` correctly — the routing one layer above it consulted server truth alone, so the sentence read as accurate to anyone checking the layer it named. Corrected there. **It also ruled out a hypothesis rather than confirming one**: `POST /media/{id}/complete` *does* recompute `entry_type` — ~~`services/media.py:175`, asserted at `tests/test_media.py:345`~~ — **both corrected Aug 22, 2026 by phase 111, and cited by name rather than by line because these two moved once already.** The recompute is `complete_upload` calling `retype_owning_entry` in `services/media.py`, which is the function it was in when this row was written and is not `:175` — that line is inside `complete_upload`'s own signature. The assertion is `test_completing_an_upload_turns_a_did_it_entry_into_a_media_entry` in `tests/test_media.py`, whose `assert entry.entry_type == "audio"` is the claim; `:345` is a `PATCH /media/{id}/derived` idempotency assertion about a transcript and says nothing about `entry_type`. So the mistyping is a window, not a permanent state — **except for an upload that never completes**, which is filed as `blocked.md` §14 and ~~is an API-lane contract question nobody has taken~~ — **struck Aug 22, 2026 by phase 111: somebody took it four days after this row was written, and nothing said so.** **Phase 86 resolved it** (`a1b25b8`, merged as PR #137 on Aug 18, 2026, branch `api/phase-86-entry-type-follows-the-media`), the owner ruling for recompute *at plan time* rather than at completion — so an upload that never completes no longer leaves a permanent mistyping, because the row's existence is what counts. `retype_owning_entry` is called from **both** `plan_upload` return paths (`api/src/rascal/services/media.py:130` and `:158`), again at `:208` on completion, and once more from `services/sync.py`. **The bookkeeping is what went missing rather than the work**: 86 had no row in this ledger until Aug 22 — it is backfilled above — `data-model.md:363` kept describing `entry_type` as *"denormalized from the prompt for filtering"* for four days, and no `decisions-log.md` line recorded the ruling. **The `data-model.md` sentence was the dangerous one**, because `CLAUDE.md` says the code is wrong when the two disagree, so a stale line there is a standing authorisation to break working code. **1006 tests in 122 suites**, four break-tests

## Phase 83 — The server renders pronoun tokens for the APNs alert body
<a id="phase-83"></a>

**Status marker, as the live ledger carries it:** ○ **allocated Aug 18, 2026 — not started**

API lane, and **the other half of 82 by subject but deliberately not by phase**. A lock screen currently reads *"Take a photo of {them} eating something {they} said {they} hated."* — raw tokens, on the one surface a parent cannot dismiss without reading. **Split from 82 because `CLAUDE.md`'s two-lane rule is not a style preference**: an agent in `ios/` never edits `api/`, and CI is path-scoped, so a single phase spanning both lanes is one whose CI can only ever half-run. **Alert body only** — the durable prompt text stays tokenised on the wire, per the pronoun contract

## Phase 86 — `entry_type` follows the media, not the bytes
<a id="phase-86"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 18, 2026** — `a1b25b8`, merged as PR **#137**, branch `api/phase-86-entry-type-follows-the-media`. **Backfilled Aug 22, 2026 by phase 111: this row did not exist for four days**, and its absence is why `blocked.md` §14 was still being carried as open work — in this file's own phase 80 row and in ~~`phase-queue.md`~~ **`docs/api-contract.md`** — after it had been resolved. **The second document was named wrong and is corrected Aug 22, 2026 in the same pass: the queue never mentioned §14 at all.** `git grep -n '§14\|entry_type\|provisional' 6c93c39 -- docs/phase-queue.md` returns nothing, and `git log --all -S'§14' -- docs/phase-queue.md` names only this phase's own commit — so the queue's single mention of §14 is the line phase 111 wrote saying it was struck. **The document that did carry it is `api-contract.md`**, whose `entry_type` derivation section pointed a reader at §14 for four days after §14 was resolved; `git grep -n '§14' 6c93c39 -- docs/` finds exactly three places, and they are `api-contract.md:757`, `blocked.md:1952` and this file's `:628`. **Naming an innocent document is the same defect as leaving a stale one uncorrected** — it sends the next reader to grep a file that never had the problem

API lane, and it closed `blocked.md` §14, *"`entry_type` is provisional for as long as an upload is, and permanent if the upload dies"*. **The owner ruled for shape 1: recompute at plan time**, not at completion, so a `media` row counts from the moment it exists rather than from the moment its bytes land. That is what makes an abandoned upload harmless — the entry is typed `photo` or `video` when the upload is *planned* and stays typed, instead of sitting permanently as `text` because a phone died mid-PUT. `retype_owning_entry` is called from **both** `plan_upload` return paths (`api/src/rascal/services/media.py:130` and `:158`), again at `:208` on completion, and once more from `services/sync.py`. **§14's central factual claim — that `plan_upload` does not call the recompute — has been false since the day after it was written.** **Three pieces of bookkeeping were never done, and phase 111 did them, which is the part worth carrying:** this ledger had no row; `docs/data-model.md:363` still read *"denormalized from the prompt for filtering"*, which is the load-bearing one because `CLAUDE.md` says the **code** is wrong when the code and `data-model.md` disagree — so a stale sentence there is a standing authorisation to "fix" correct code; and `docs/decisions-log.md` recorded no ruling. **A phase can ship, merge, deploy and be right, and still leave every document that describes it wrong**

## Phase 95 — Settle the Aug 18 decisions proposal — dismissal strikes, and a seal editable until it opens
<a id="phase-95"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 19, 2026 — docs only, no code**

Docs lane. Two of the three proposed rows added to `decisions.md` Settled; open item 14 struck as built by 65–67. The account-deletion row was **not** applied: it was drafted against a stale tree and would have re-opened a settled item and called deployed code unbuilt. Its one live finding survives — **there is no Sign in with Apple REST token-revocation call anywhere in `api/`**, which Apple requires as part of account deletion, and it needs a phase. **This ledger stops at 83 while 84–94 have merged**, so the number came from `git log --all`, the branch list and `gh pr list` as `phase-queue.md`'s own recipe says, not from this table.

## Phase 96 — The admin console — snapshot, library, ops and costs
<a id="phase-96"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 19, 2026**

API lane. `/admin` served from the API itself (see `decisions.md` on why that is not a D7 reversal), four panels behind a bearer token, and the cost panel's five vendor cards. Admin routes return **counts and never archive content**, enforced by a test that plants distinctive strings in an archive and greps every admin response for them. Library edits go through `prompt_library_overrides` rather than an `UPDATE`, because `seed_prompts` runs as the release command and reconciles `prompts` against `prompts.yaml` totally — a plain edit is undone within minutes of the next deploy

## Phase 97 — The Studio tab, and cards drawn on a canvas
<a id="phase-97"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 19, 2026**

API lane. Claude does art direction, copy, captions, alt text, image briefs and shot lists; **pixels come from a canvas template that needs no vendor**, because no Anthropic model has an image endpoint and a "generate image" button wired to the Anthropic key would have been a spinner attached to nothing. The mission library is capped, counted and kept out of the model's context — D7 calls it the one asset a competitor would want, and a social generator that features prompts produces exactly the public slices it forbids. **Nothing in the studio posts anything**

## Phase 98 — Let the console read Neon, without letting anything else near it
<a id="phase-98"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 20, 2026 — PR #147**

API lane. `ADMIN_READ_DATABASE_URL`, a second connection for the console's read routes and nothing else. **Repointing `DATABASE_URL` was rejected outright**: it is read by `make migrate`, `make seed`, `make test` and `make reset-db` — which runs `alembic downgrade base` — so aiming it at Neon turns four Makefile targets into commands that destroy the archive. The connection is read-only at the server, console writes refuse while it is set, and **the console now names its database on every screen**, in the ordinary case too. The trigger: six local fixture rows were mistaken for production, and the data was never mocked — it was the wrong database

## Phase 99 — Make signing in to the deployed console possible
<a id="phase-99"></a>

**Status marker, as the live ledger carries it:** ✅ **shipped Aug 20, 2026 — PR #148**

API lane. The console kept only the fifteen-minute access token, and in production re-authenticating is a magic link rather than a button, so a session was a demo. It now keeps the refresh token and rotates on a 401, **single-flight** — several requests per tab switch each starting their own refresh would present a token just revoked, which the API correctly reads as a reuse attack. The sign-in screen does the magic-link exchange itself; `/signin` is deliberately left telling parents to use their phone. Second commit: **an individual Anthropic account cannot have an admin key at all**, so the cost card's copy stopped sending people to a Console section that is not there
