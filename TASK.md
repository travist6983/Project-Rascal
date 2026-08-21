> **⚠️ FINISHED AND SUPERSEDED — this file is a completed review checklist from Aug 13, 2026, not
> current work. Marked Aug 18, 2026.** ~~All 40 of its boxes are ticked~~ — **42 as of Aug 21, 2026:
> a `/rascal-review` run on `ios/phase-37b-storekit` appended two, and both were applied in the same
> run rather than left open.** The rest of this notice stands. The phases it names are
> long merged; the figures below (879 iOS tests in 110 suites, 491 API tests) are five days and
> roughly twenty phases stale — the suites are now 995 in 121 and 757 in 47. **The live queue is
> `docs/phase-queue.md` and the live status is `docs/roadmap-status.md`.** Kept rather than deleted
> because `TASK.md` is where the review that produced it recorded its own outcome.
>
> All items below were applied on 2026-08-13 and are checked off. iOS fixes ship in the
> `ios/review-fixes` PR, API fixes in `api/review-fixes`. Verified green: 879 iOS tests in
> 110 suites, 491 API tests, `ruff check` and `ruff format --check` clean.

> Updated by rascal-review on 2026-08-12 · branch main (ios/ deep-dive audit) · 16 validated findings

## Critical
- [x] **TEST_COVERAGE** Make the store-quarantine test exercise the real recovery path (injectable store URL), asserting moved-not-deleted — `ios/Rascal/RascalTests/StoreMigrationTests.swift:166` (confidence: 95)

## High
- [x] **COPY** Replace "Rascal" with "Dogear" in NSPhotoLibraryUsageDescription in both plists — `ios/Rascal/Info.plist:86`, `ios/Rascal/Info-Debug.plist:88` (confidence: 96)
- [x] **CLIENT_SCHEDULE** Thread familyTimezone into the month picker; use BackfillCalendar.family for BackfillEntryPlan and load()'s day grouping — `ios/Rascal/Rascal/Backfill/BackfillMonthPickerScreen.swift:396` (confidence: 96)
- [x] **CONCURRENCY** Link cancellation to the detached PhotoKit walks with withTaskCancellationHandler — `ios/Rascal/Rascal/Backfill/BackfillScanner.swift:342,389` (confidence: 96)
- [x] **TEST_COVERAGE** Add MediaCoordinatorTests covering beginUpload/finishUpload durability branches — `ios/Rascal/Rascal/Media/MediaCoordinator.swift:73` (confidence: 96)
- [x] **DESIGN_SYSTEM** Tint the time-picker Done terracotta, add inkMuted Cancel, give AccentColor.colorset the terracotta value — `ios/Rascal/Rascal/Onboarding/NotificationStep.swift:152` (confidence: 96)
- [x] **DESIGN_SYSTEM** Replace the improvised Color(hex:) literals with palette tokens; name the wash-tail stop once — `ios/Rascal/Rascal/Backfill/BackfillFlowView.swift:456,487,564,688` (confidence: 95)
- [x] **PERFORMANCE** Move attached-thumbnail decode out of body into a child view with @State + .task(id:) — `ios/Rascal/Rascal/Composer/ComposerView.swift:544` (confidence: 95)
- [x] **TEST_COVERAGE** Add ArchiveExportTests: filename() traversal guard, 401-refresh-retry, error-envelope decode — `ios/Rascal/Rascal/Settings/ArchiveExport.swift:201` (confidence: 95)
- [x] **DESIGN_SYSTEM** Drop the inert raw Font.system(size: 20) stacked on .typeRole — `ios/Rascal/Rascal/Timeline/EntryDetailScreen.swift:755` (confidence: 95)
- [x] **CORRECTNESS** Derive edit-composer mode from attached media first (both call sites) — `ios/Rascal/Rascal/Today/TodayScreen.swift:343`, `ios/Rascal/Rascal/Timeline/EntryDetailScreen.swift:1195` (confidence: 95)
- [x] **ACCESSIBILITY** Use type roles for the Lock Screen widget prose and eyebrow — `ios/Rascal/RascalWidget/AccessoryFamilyViews.swift:33` (confidence: 95)
- [x] **ACCESSIBILITY** Remove the blanket 0.62 row opacity on logged months; quieten by token if at all — `ios/Rascal/Rascal/Backfill/BackfillSuggestionsScreen.swift:184` (confidence: 93)
- [x] **CONCURRENCY** Capture the AVPlayer weakly in the periodic time observer — `ios/Rascal/Rascal/Timeline/VideoPlayback.swift:117` (confidence: 93)
- [x] **CORRECTNESS** Show "Not provided" instead of AppConfig.devLoginEmail for a null email; drop the fallbackEmail argument — `ios/Rascal/Rascal/Settings/SettingsScreen.swift:266,194` (confidence: 92)
- [x] **TEST_COVERAGE** Delete or reroute the stub-echo extraction test through ExtractionQueue — `ios/Rascal/RascalTests/ExtractionTests.swift:343` (confidence: 90)

> Updated by ios-security-sweep on 2026-08-12 · security addendum · 4 confirmed findings

## High
- [x] **SECURITY** Bind PendingShare records to the staging account and clear the App Group share inbox on sign-out — a prior account's shares otherwise upload into the next account's archive — `ios/Rascal/Rascal/Share/ShareDrain.swift:144`, `ios/Rascal/Rascal/Onboarding/OnboardingGate.swift:408` (confidence: 88)

## Medium
- [x] **SECURITY** Delete child data at rest on sign-out: SwiftData rows, StagingStore root + thumbnail cache, avatars, exports, share inbox — `ios/Rascal/Rascal/App/AppEnvironment.swift:146` (confidence: 90)
- [x] **SECURITY** Use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly for session tokens so they cannot migrate via backups — `ios/Rascal/Rascal/Networking/TokenStore.swift:60` (confidence: 85)
- [x] **SECURITY** Gate dev-login (button, signInWithDevLogin, APIClient.devLogin, DEV_* plist keys) behind #if DEBUG instead of server ENVIRONMENT — `ios/Rascal/Rascal/Onboarding/WelcomeScreen.swift:103` (confidence: 88)

> Updated by rascal-review on 2026-08-13 · branch chore/task-md-audit-and-prompt-tokenisation (api/ deep-dive audit, security in scope) · 20 validated findings

## Critical
- [x] **AUTHZ_SWEEP** Add avatar routes (POST avatar-upload-url, GET avatar-url) to _requests() in the authorization sweep — `api/tests/test_authorization_sweep.py` for `api/src/rascal/routers/children.py:116` (confidence: 95)
- [x] **AUTHZ_SWEEP** Add the three prompt-suppression routes to the authorization sweep — `api/tests/test_authorization_sweep.py` for `api/src/rascal/routers/children.py:200` (confidence: 95)
- [x] **AUTHZ_SWEEP** Add GET pool-health to the authorization sweep — `api/tests/test_authorization_sweep.py` for `api/src/rascal/routers/children.py:303` (confidence: 96)
- [x] **UNBOUNDED_READ** Page GET /sync (SYNC_PAGE_SIZE + .limit on all four queries, earliest-truncated cursor, has_more) — `api/src/rascal/routers/sync.py:31` + `api/src/rascal/services/sync.py:61` (one fix, both layers) (confidence: 88)
- [x] **UNBOUNDED_READ** Bound GET /today to pending + completed-today assignments (or_ status/id.in_, uses ix_assignments_child_id_status_assigned_on) — `api/src/rascal/services/today.py:47` (confidence: 92)

## High
- [x] **AUTHZ** Validate avatar_key against the children/{id}/avatar/ prefix before setattr (presign-anything IDOR; validator calls it effectively critical) — `api/src/rascal/routers/children.py:109` (confidence: 85)
- [x] **AUTHZ** Route POST /debug/scheduler/run through require_child_access("parent"); check Guardian.role — `api/src/rascal/routers/debug.py:65` (confidence: 92)
- [x] **PROMPT_TOKENS** Replace the generator's "write in he/him" instruction with the pronoun-token contract; add a gender rejection rule to judge() — `api/scripts/generate_prompts.py:335` (confidence: 95)
- [x] **CONTRACT_DRIFT** Fix the dead candidate filter (source=='generated' → 'llm'; reconcile with the worksheet generator) — `api/scripts/review_candidates.py:97` (confidence: 97)
- [x] **TRANSACTION_SPAN** Commit before the S3 download in export (router + service) — `api/src/rascal/routers/export.py:52`, `api/src/rascal/services/export.py:355` (confidence: 95)
- [x] **TRANSACTION_SPAN** Commit before S3 multipart complete/create (plan_upload half needs explicit commit) — `api/src/rascal/services/media.py:141` (confidence: 92)
- [x] **UNBOUNDED_READ** Cap /sync/push entries and media lists (max_length=200); document the ceiling — `api/src/rascal/schemas/sync.py:76` (confidence: 90)
- [x] **REDUNDANT_QUERY** Add reload=False to create_entry and use it on the push path — `api/src/rascal/services/sync.py:158` (confidence: 96)
- [x] **CONTRACT** Lag the /sync/push cursor by CURSOR_OVERLAP_SECONDS (or drop the field) — `api/src/rascal/services/sync.py:281` (confidence: 87)
- [x] **ERROR_SHAPE** Reject explicit null for name/birthdate/family_timezone (422 not 500); run the tz validator on any set value — `api/src/rascal/schemas/child.py:32` (confidence: 92)
- [x] **MISSING_INDEX** Rewrite the Today completed-today predicate as a UTC half-open range (sargable, DST-correct) — `api/src/rascal/services/today.py:62` (confidence: 78)
- [x] **MIGRATION_TEST** Add a data-present downgrade test for 0003 (insert a letter row, downgrade past 0003, assert it's gone) — `api/alembic/versions/0003_letter_slot_and_admin.py:45` (confidence: 92)
- [x] **CLOCK_DEPENDENT** Capture now before the HTTP call in the Today self-healing tests (lines 89 and 208) — `api/tests/test_today_self_healing.py:89` (confidence: 88)

* * *

> Updated by rascal-review on 2026-08-21 · branch `ios/phase-37b-storekit` · 2 validated findings
>
> **Both were fixed in the same run**, so they are appended ticked rather than open — this file's
> convention. One finding was rejected in validation and is recorded in
> `.claude/review-history/false-positives.json` rather than here, per that file's own rule: a
> suppression is for a finding that was *wrong*, never for a real defect being deferred.
>
> Verified green after both fixes: **1084 iOS tests in 137 suites**, cold build, zero warnings in
> the new code. Report: `.claude/reviews/ios-phase-37b-storekit/report.md`.

## High
- [x] **TEST_COVERAGE** Pin the `refresh()` / `transactionDelivered()` split behaviourally — a `SubscriptionCenterTests` suite over `StubPerformer`, plus a `#if DEBUG init(testing:)` seam so no test opens a process-lifetime drain on `Transaction.updates`. The source-grep guard could not see the one edit that reintroduces the foreground bug — `ios/Rascal/Rascal/Subscription/SubscriptionCenter.swift:46` (confidence: 88) — break-tested: that edit failed 0 tests before, 4 now
- [x] **DESIGN_SYSTEM** Render the "You're subscribed." terminal state instead of a dead greyed-out buy button when the entitlement lands while the paywall is open — covers restore, another guardian subscribing, and a purchase arriving from another device, not just the restore path that surfaced it — `ios/Rascal/Rascal/Subscription/PaywallSheet.swift:196` (confidence: 85)
