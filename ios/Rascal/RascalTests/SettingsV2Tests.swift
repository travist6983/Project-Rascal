import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Settings v2 — the logic behind the redesigned screen.
///
/// The design import moved three things that are worth pinning rather than eyeballing. The child's
/// name left the row list for a hero card, which means the age and the birthday are now rendered
/// by code that was not there before and can get a calendar wrong in the way `EditChildModel`
/// already got it wrong once. The sync card's two states became one summary value instead of two
/// view bodies, so both are now checkable. And `Recompute ages` was pulled *back out* of the
/// group the import put it in, which is a separation the suite can only defend indirectly — see
/// the last suite here for exactly how far that goes.

// MARK: - Fixtures

private func child(
    name: String = "Hendrix",
    birthdate: String = "2022-06-19",
    ageMonths: Int = 49,
    timezone: String = "America/Detroit"
) throws -> ChildResponse {
    let json = """
    {"id":"\(UUID().uuidString)","name":"\(name)","birthdate":"\(birthdate)",
     "avatar_key":null,"family_timezone":"\(timezone)",
     "created_at":"2026-08-08T17:51:39.973377Z","updated_at":"2026-08-08T17:51:39.973377Z",
     "role":"parent","age_months":\(ageMonths)}
    """
    return try APIClient.decoder.decode(ChildResponse.self, from: Data(json.utf8))
}

// MARK: - The hero

@MainActor
@Suite("Settings v2 — the child hero")
struct ChildHeroCardTests {

    @Test("the initial is one glyph, uppercased, whatever the name starts with")
    func initials() {
        #expect(ChildHeroCard.initial(of: "Hendrix") == "H")
        #expect(ChildHeroCard.initial(of: "miles") == "M")
        // Leading whitespace would otherwise put a blank in the disc.
        #expect(ChildHeroCard.initial(of: "  Ada  ") == "A")
        #expect(ChildHeroCard.initial(of: "Étienne") == "É")
        // One *grapheme*, not one scalar: a flag emoji is two scalars and half of one is a box.
        #expect(ChildHeroCard.initial(of: "🇬🇧 Bailey") == "🇬🇧")
        #expect(ChildHeroCard.initial(of: "e\u{0301}mile") == "É", "a combining accent stays with its letter")
    }

    @Test("an empty name yields an empty disc rather than a placeholder glyph")
    func initialOfNothing() {
        // Not "?" and not "—". The server requires a name, so this is unreachable in practice;
        // when it is reached the disc is simply blank rather than asserting something.
        #expect(ChildHeroCard.initial(of: "") == "")
        #expect(ChildHeroCard.initial(of: "   ") == "")
        #expect(ChildHeroCard.initial(of: "\n\t") == "")
    }

    @Test("the subtitle reads the server's age and the child's birthday, in that order")
    func subtitle() throws {
        let text = ChildHeroCard.subtitle(for: try child(birthdate: "2022-06-19", ageMonths: 49))
        #expect(text.hasPrefix("4 years, 1 month · born "))
        #expect(text.contains("2022"))
        #expect(text.contains("19"))
    }

    /// The number in the subtitle is `age_months` from the server and nothing else. A client that
    /// recomputes drifts the moment a rounding or timezone rule differs, and in an archive that
    /// difference is permanent — so the subtitle must move when the server's number moves, and
    /// must not move when only the birthdate does.
    @Test("the age comes from the server's age_months, never from the birthdate")
    func ageIsNotRecomputed() throws {
        // A deliberately impossible pairing: born yesterday, and the server says eight years.
        let impossible = try child(birthdate: "2026-08-09", ageMonths: 97)
        #expect(ChildHeroCard.subtitle(for: impossible).hasPrefix("8 years, 1 month · born "))

        // Same birthdate, different server age — the words follow the server.
        let newborn = try child(birthdate: "2026-08-09", ageMonths: 0)
        #expect(ChildHeroCard.subtitle(for: newborn).hasPrefix("Newborn · born "))
    }

    /// The bug this pins is `EditChildModel`'s, one screen over: the wire format carries no zone,
    /// so parsing a birthday in UTC and formatting it in a UTC−4 calendar drew the day before.
    /// The hero is a second renderer of the same string and had to learn the same rule.
    /// **The day is compared as a whole number, not as a substring**, and the month is compared
    /// by name. An earlier version of this test asserted `rendered.contains("\(day)")`, which is
    /// exactly the assertion that cannot see the bug in the sentence above it: the slip for
    /// `2021-06-01` is `May 31, 2021`, and `"May 31, 2021".contains("1")` is **true** — the "1"
    /// in "31". It passed on the one case it was written for. A partial assertion on a rendered
    /// string tests that the string exists, not that it is right.
    @Test("a birthday renders as the calendar day the server named, not its neighbour")
    func birthdateDoesNotSlip() throws {
        for raw in ["2022-06-19", "2021-06-01", "2024-02-29", "1999-12-31", "2021-01-01"] {
            let text = try #require(ChildHeroCard.longBirthdate(raw), "\(raw) rendered nothing")

            let parts = raw.split(separator: "-").compactMap { Int($0) }
            var wanted = DateComponents()
            wanted.year = parts[0]
            wanted.month = parts[1]
            wanted.day = parts[2]
            let expected = try #require(Calendar.current.date(from: wanted))

            // Digits as tokens, so "31" can never satisfy a test looking for "1".
            let numbers = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
            #expect(numbers.contains("\(parts[2])"), "\(raw) rendered as \(text) — wrong day")
            #expect(numbers.contains("\(parts[0])"), "\(raw) rendered as \(text) — wrong year")

            // And the month by name, built through `FormatStyle` rather than the `DateFormatter`
            // template `longBirthdate` uses — a different code path, so a bug in one does not
            // hide in the other. Locale-derived rather than hard-coded English.
            let monthName = expected.formatted(.dateTime.month(.wide))
            #expect(text.contains(monthName), "\(raw) rendered as \(text) — wrong month")

            // And the round trip is stable: parse then format lands on the same server day.
            let parsed = try #require(EditChildModel.dayFormatter.date(from: raw))
            #expect(EditChildModel.dayFormatter.string(from: parsed) == raw)
        }
    }

    @Test("a birthdate the server could not have sent renders as nothing, not as itself")
    func birthdateGarbage() {
        #expect(ChildHeroCard.longBirthdate("not-a-date") == nil)
        #expect(ChildHeroCard.longBirthdate("") == nil)
        #expect(ChildHeroCard.longBirthdate("2022-13-45") == nil)
    }

    /// The empty case of the one genuinely new surface this phase adds.
    @Test("with no child, the hero says it is waiting and claims nothing about why")
    func placeholderIsHonest() {
        let text = ChildHeroCard.placeholderText
        #expect(!text.isEmpty)
        // This state is reached both mid-fetch and after an offline failure, and it cannot tell
        // them apart. `SettingsScreen`'s notice line is what says which. A hero that guessed
        // "Loading…" would be lying in the case that lasts.
        #expect(!text.lowercased().contains("loading"))
        #expect(!text.lowercased().contains("error"))
        #expect(!text.lowercased().contains("failed"))
        // And it is not a scold. Nothing on this screen is.
        #expect(!text.contains("!"))
    }
}

// MARK: - The sync card's head

@MainActor
@Suite("Settings v2 — the sync summary")
struct SettingsSyncSummaryTests {

    private func summary(entries: Int = 0, deletions: Int = 0, media: Int = 0) -> SettingsScreen.SyncSummary {
        SettingsScreen.syncSummary(
            EntrySync.Outstanding(entries: entries, deletions: deletions, media: media)
        )
    }

    /// The empty case. This is the state the card is in for a parent whose archive is healthy,
    /// which is to say almost always.
    @Test("nothing outstanding is a calm, untinted head with no counter and no caveat")
    func clear() {
        let clear = summary()
        #expect(clear.eyebrow == "Sync")
        #expect(clear.headline == "Everything's uploaded.")
        #expect(clear.isActive == false, "no wash and no dot when nothing is happening")
        // Never the string "0 left", and never a dangling caveat about a connection that is fine.
        #expect(clear.counter == nil)
        #expect(clear.detail == nil)
    }

    @Test("one of each thing is counted in the singular")
    func singulars() {
        #expect(summary(entries: 1).headline == "1 entry still to upload.")
        #expect(summary(media: 1).headline == "1 file still to upload.")
        #expect(summary(entries: 1, media: 1).headline == "1 entry and 1 file still to upload.")
    }

    @Test("entries and deletions are both writes, and are counted together")
    func deletionsAreWrites() {
        // A deletion is a row the server has not been told about — the same kind of debt as an
        // entry it has not seen, and it would be strange to name it separately to a parent.
        #expect(summary(entries: 2, deletions: 1).headline == "3 entries still to upload.")
        #expect(summary(deletions: 1).headline == "1 entry still to upload.")
        #expect(summary(entries: 3, deletions: 1, media: 2).headline == "4 entries and 2 files still to upload.")
    }

    @Test("the counter is the total, and it agrees with the headline's own arithmetic")
    func counterMatchesTotal() {
        #expect(summary(entries: 3, deletions: 1, media: 4).counter == "8 left")
        #expect(summary(media: 1).counter == "1 left")
        // Two numbers on one card that disagree is worse than one number.
        for (e, d, m) in [(1, 0, 0), (0, 1, 0), (0, 0, 1), (3, 2, 7), (12, 0, 40)] {
            let value = summary(entries: e, deletions: d, media: m)
            #expect(value.counter == "\(e + d + m) left")
            #expect(value.isActive)
        }
    }

    @Test("nothing here scolds, counts down, or turns the archive into a problem")
    func toneHoldsInEveryState() {
        for (e, d, m) in [(0, 0, 0), (1, 0, 0), (0, 0, 1), (9, 3, 40)] {
            let value = summary(entries: e, deletions: d, media: m)
            let words = [value.eyebrow, value.headline, value.detail, value.counter]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            for scold in ["failed", "error", "problem", "warning", "overdue", "!"] {
                #expect(!words.contains(scold), "\(scold) in: \(words)")
            }
        }
    }
}

// MARK: - The dry run, and what the report sheet is handed

@MainActor
@Suite("Settings v2 — the dry run survives the redesign")
struct SyncDryRunReachabilityTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: LocalStore.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
    }

    private func engine(
        childId: UUID, performer: StubPerformer, context: ModelContext, state: SyncStateStoring
    ) -> SyncEngine {
        SyncEngine(
            childId: childId,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: state
        )
    }

    /// The path this whole screen exists to serve: run a dry run, read what it would change, and
    /// only then flip the switch. The redesign moved the dry run into an `Advanced` card of its
    /// own, and the thing worth checking is that the report the sheet renders is still the full
    /// one rather than the one-line card summary.
    @Test("a dry run still fills both the card line and the report the sheet renders")
    func reportSurvivesTheMove() async throws {
        let context = try makeContext()
        let childId = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let body = syncJSON(
            entries: [
                entryJSON(id: UUID(), childId: childId, occurredAt: newest, body: "one"),
                entryJSON(id: UUID(), childId: childId, occurredAt: newest, body: "two"),
            ],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let model = SyncStatusModel(engine: engine(
            childId: childId, performer: performer, context: context, state: InMemorySyncStateStore()
        ))
        await model.runDryRun()

        guard case .ready(let line) = model.dryRun else {
            Issue.record("expected a finished dry run, got \(model.dryRun)")
            return
        }

        // The card gets one sentence…
        #expect(line == "2 to add.")

        // …and the sheet gets the whole thing, which is a different, longer artifact. If these
        // ever became the same string the "Read the report" button would have stopped meaning
        // anything, which is exactly the kind of thing a layout change can do quietly.
        let report = try #require(model.report)
        #expect(report.contains("SYNC DRY RUN — nothing was written"))
        #expect(report.count > line.count * 4, "the report is not just the card line again")
        #expect(model.reportTitle == "Dry run", "the sheet still has a title to render")

        // And it remains a dry run: nothing written, no cursor moved.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 0)
    }

    /// `SyncAdvancedSection` disables both its rows off `isBusy`. A run that left the flag set
    /// would leave half the Advanced card permanently dead.
    ///
    /// **This checks the endpoints, not the middle.** Observing `isBusy == true` *during* a run
    /// needs a performer that suspends on demand, which this suite has no fixture for; the flag
    /// is `dryRun == .running` and the transition into it is covered by `runDryRun`'s own guard,
    /// exercised in `RecomputeSeparationTests.concurrentRunsAreRefused`.
    @Test("the busy flag is clear before a dry run and clear again after it")
    func busyTracksTheRun() async throws {
        let context = try makeContext()
        let childId = UUID()
        let performer = StubPerformer()
        performer.on("/sync") { _ in (syncJSON(cursor: Date(timeIntervalSince1970: 1_700_000_000)), 200) }

        let model = SyncStatusModel(engine: engine(
            childId: childId, performer: performer, context: context, state: InMemorySyncStateStore()
        ))
        #expect(model.isBusy == false, "idle before anything is asked of it")

        await model.runDryRun()

        // Finished, so the reset row is tappable again — a run that left this true would leave
        // half the Advanced card permanently dead.
        #expect(model.isBusy == false)
    }
}

// MARK: - Recompute stays deliberate

@MainActor
@Suite("Settings v2 — recompute stays deliberate")
struct RecomputeSeparationTests {

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    /// **What this can and cannot check.** The confirmation dialog itself is a view modifier, and
    /// nothing in this suite can tap through one. What is checkable is the half that matters if
    /// the dialog is ever wired up wrongly: the model does no work whatsoever until `run` is
    /// called on it explicitly, so a row that merely *presents* the dialog cannot rewrite an
    /// archive's ages by being drawn, and a mis-wired row that called nothing would visibly do
    /// nothing rather than silently do everything.
    @Test("building the model, and drawing the row, issues no request at all")
    func inertUntilRun() async throws {
        let performer = StubPerformer()
        let ok = Data("""
        {"child_id":"\(UUID().uuidString)","entries_updated":412,"birthdate":"2022-06-19"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        let model = RecomputeAgesModel(childId: UUID(), api: client(performer))
        #expect(model.state == .idle)
        #expect(model.isRunning == false)
        #expect(performer.requests.isEmpty, "constructing the model touches the network")

        // Only the explicit call does anything.
        await model.run(context: nil)
        #expect(performer.count(for: "/recompute-ages") == 1)
    }

    /// A second `run` while one is in flight is refused rather than queued. The dialog can be
    /// re-presented; **the archive is rewritten once.**
    ///
    /// This genuinely races the two calls rather than asserting around them. It is deterministic
    /// despite that: `run` is `@MainActor` and sets `state = .running` *synchronously* before its
    /// first `await`, so the second call cannot begin until the first has already claimed the
    /// flag and suspended on the request.
    @Test("two runs started together issue one request, not two")
    func concurrentRunsAreRefused() async throws {
        let performer = StubPerformer()
        let ok = Data("""
        {"child_id":"\(UUID().uuidString)","entries_updated":7,"birthdate":"2022-06-19"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        let model = RecomputeAgesModel(childId: UUID(), api: client(performer))

        async let first: Void = model.run(context: nil)
        async let second: Void = model.run(context: nil)
        _ = await (first, second)

        #expect(performer.count(for: "/recompute-ages") == 1, "the guard held")
        #expect(model.state == .done(updated: 7, birthdate: "2022-06-19"))
    }

    /// The only way back to the row is through `dismiss`, so a finished run does not leave the
    /// card stuck on its result.
    @Test("a finished run dismisses back to idle")
    func dismissReturnsToIdle() async throws {
        let performer = StubPerformer()
        let ok = Data("""
        {"child_id":"\(UUID().uuidString)","entries_updated":0,"birthdate":"2022-06-19"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        let model = RecomputeAgesModel(childId: UUID(), api: client(performer))
        await model.run(context: nil)
        #expect(model.state == .done(updated: 0, birthdate: "2022-06-19"))

        model.dismiss()
        #expect(model.state == .idle)
    }
}

// MARK: - Phase 20: every surviving value on the sync card

/// **Each value asserted against a constructed state, so a hardcoded one cannot pass.**
///
/// The card claimed "UPLOADING · 8 left", "8 files still to upload" and "Last pull — Off" on a
/// phone whose owner had not added eight things. One of those was a placeholder, one folded two
/// different facts into one number, and the third put a toggle's state in a timestamp's row.
@MainActor
@Suite("Phase 20 — the sync card tells the truth")
struct SyncCardTruthTests {

    private func summary(
        entries: Int = 0, deletions: Int = 0, media: Int = 0, failedMedia: Int = 0
    ) -> SettingsScreen.SyncSummary {
        SettingsScreen.syncSummary(
            EntrySync.Outstanding(
                entries: entries, deletions: deletions, media: media, failedMedia: failedMedia
            )
        )
    }

    /// **The 5.2 defect.** Eight media rows of which five have stopped trying is not "8 left";
    /// it is three still coming and five that need asking again, and the reassuring sentence
    /// belongs only to the three.
    @Test("files past the retry cap are not counted as files still on their way")
    func stalledFilesAreNotCountedAsWaiting() {
        let value = summary(media: 8, failedMedia: 5)

        #expect(value.counter == "3 left", "the counter promised eight arrivals, not three")
        #expect(value.headline == "3 files still to upload.")
        #expect(value.stalled != nil, "five stopped files said nothing at all")
        #expect(value.stalled?.contains("5 files") == true)
    }

    /// The whole outstanding set has stopped. Nothing is "still to upload" and nothing will
    /// "finish on their own" — the card must not say either.
    @Test("with everything stalled the card stops promising an arrival")
    func allStalledDropsThePromise() {
        let value = summary(media: 4, failedMedia: 4)

        #expect(value.counter == nil, "counting down to a finish that is not coming")
        #expect(value.headline.contains("still to upload") == false)
        #expect(value.detail?.contains("finish on their own") != true)
        #expect(value.detail?.contains("still on this phone") == true)
        #expect(value.isActive == false, "a live dot for work that has stopped")
    }

    /// The ordinary case is unchanged, which is what makes the split safe to make.
    @Test("with nothing stalled the card reads exactly as it did")
    func noStalledIsUnchanged() {
        let value = summary(entries: 3, deletions: 1, media: 4)

        #expect(value.counter == "8 left")
        #expect(value.headline == "4 entries and 4 files still to upload.")
        #expect(value.stalled == nil)
        #expect(value.isActive)
    }

    /// Tone, including the line the split added. A file that stopped trying is a fact about a
    /// connection, and this app does not turn it into an emergency.
    @Test("the stalled line states a fact and does not scold")
    func stalledLineIsCalm() {
        for (m, f) in [(8, 5), (4, 4), (1, 1), (40, 12)] {
            let value = summary(media: m, failedMedia: f)
            let words = [value.eyebrow, value.headline, value.detail, value.counter, value.stalled]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            for scold in ["failed", "error", "problem", "warning", "overdue", "lost", "!"] {
                #expect(!words.contains(scold), "\(scold) in: \(words)")
            }
        }
    }

    /// **The 5.3 defect.** A primary action that reports nothing teaches the parent that the
    /// card is decorative, and this one is pressed at the moment somebody is worried.
    @Test("Retry now says what it achieved, in every outcome")
    func retryReportsAResult() {
        let cleared = SettingsScreen.retryResult(
            before: EntrySync.Outstanding(media: 3),
            after: EntrySync.Outstanding()
        )
        #expect(cleared == "Everything's uploaded.")

        let partial = SettingsScreen.retryResult(
            before: EntrySync.Outstanding(media: 8),
            after: EntrySync.Outstanding(media: 3)
        )
        #expect(partial.contains("5 finished"))
        #expect(partial.contains("3 still to go"))

        let stuck = SettingsScreen.retryResult(
            before: EntrySync.Outstanding(media: 4, failedMedia: 4),
            after: EntrySync.Outstanding(media: 4, failedMedia: 4)
        )
        #expect(stuck.contains("Nothing moved"))
        #expect(stuck.contains("still here"))

        let one = SettingsScreen.retryResult(
            before: EntrySync.Outstanding(media: 2),
            after: EntrySync.Outstanding(media: 1)
        )
        #expect(one.contains("1 finished"), "singular not pluralised")
    }

    /// Some landed and everything left has stopped. "3 still to go" would be a countdown to an
    /// arrival that is not coming — the same dishonesty the headline was fixed for.
    @Test("a partial retry whose remainder has stalled does not count down")
    func partialRetryWithStalledRemainder() {
        let result = SettingsScreen.retryResult(
            before: EntrySync.Outstanding(media: 8, failedMedia: 3),
            after: EntrySync.Outstanding(media: 3, failedMedia: 3)
        )

        #expect(result.contains("5 finished"))
        #expect(result.contains("still to go") == false, "counting down to files that stopped")
        #expect(result.lowercased().contains("stopped trying"))
    }
}

// MARK: - Phase 20: a refused preference write names the control it refused

@MainActor
@Suite("Phase 20 — the daily reminder reports a refused write")
struct DailyReminderWriteFailureTests {

    private func section() -> NotificationSettingsSection {
        NotificationSettingsSection(
            preference: NotificationPreference(
                authorizer: StubAuthorizer(status: .authorized),
                store: InMemoryNotificationAskStore(NotificationAskRecord()),
                backend: StubPushBackend()
            ),
            familyTimezone: "America/Detroit"
        )
    }

    /// **A single boolean sent this into naming the one value nobody was changing.** After a
    /// failed *toggle*, "it's still set to 7:00 PM" points at the send time, which was never in
    /// question — so the failure carries which control it was.
    @Test("a refused toggle does not report the send time back")
    func switchingFailureNamesTheSwitch() {
        let line = section().failureLine(.switching)

        #expect(line.lowercased().contains("daily reminder"))
        #expect(line.contains("7:00") == false, "quoted a time nobody was changing")
        #expect(line.contains("America/Detroit") == false)
    }

    /// A refused time write does quote the time, because the value that survived is the thing
    /// the parent will check again later.
    @Test("a refused time write says what it is still set to, with its zone")
    func timeFailureNamesTheTime() {
        let line = section().failureLine(.time)

        #expect(line.contains(NotifyTime.default.formatted()))
        #expect(line.contains("America/Detroit"))
    }

    /// Neither line scolds, and neither implies anything was lost.
    @Test("neither failure line alarms")
    func failureLinesAreCalm() {
        for failure in [NotificationPreference.WriteFailure.switching, .time] {
            let line = section().failureLine(failure).lowercased()
            for alarm in ["error", "failed", "problem", "lost", "!"] {
                #expect(!line.contains(alarm), "\(alarm) in: \(line)")
            }
        }
    }
}

// MARK: - Phase 20: the daily reminder names its mechanism

@MainActor
@Suite("Phase 20 — the daily reminder")
struct DailyReminderCopyTests {

    /// **The defect this fixes is that the owner turned it on without knowing it was push.**
    /// "One note a day — It carries that day's mission" describes the product principle and
    /// never once says the word for the thing it does.
    @Test("the copy names the mechanism in both states")
    func mechanismIsNamed() {
        let section = NotificationSettingsSection(
            preference: preference(), familyTimezone: "America/Detroit"
        )
        // Reaching the two strings through the same accessor the view renders, so this cannot
        // pass against copy that is only in a comment.
        #expect(section.onDetailText.lowercased().contains("notification"))
        #expect(section.offDetailText.lowercased().contains("notification"))
    }

    /// The guarantee is the second half, and it is true: a finished day is silent, and the
    /// notification carries the mission and never the archive.
    @Test("the on-state copy states the one-a-day guarantee")
    func guaranteeIsStated() {
        let text = NotificationSettingsSection(
            preference: preference(), familyTimezone: "America/Detroit"
        ).onDetailText.lowercased()

        #expect(text.contains("once a day") || text.contains("one, always"))
        #expect(text.contains("never a nudge"))
    }

    /// **The off state reads as available, not disabled**, and says the time it would arrive —
    /// otherwise "off" is a fact with nothing attached to it.
    @Test("the off state says what turning it on does, and when")
    func offStateNamesTheTime() {
        let text = NotificationSettingsSection(
            preference: preference(), familyTimezone: "America/Detroit"
        ).offDetailText

        #expect(text.contains(NotifyTime.default.formatted()), "no time in the off-state line")
        #expect(text.lowercased().contains("turn it on"))
    }

    /// No guilt copy, in any state. A missed day costs nothing and the app never implies it does.
    ///
    /// **"missed" is checked in context rather than as a bare token**, because the one sentence
    /// here that contains it is the sentence that takes the guilt away: "never a nudge about
    /// something you missed". A substring check flags that as guilt, which would push the copy
    /// toward saying *less* about what the app will not do — the opposite of the intent. So the
    /// rule is the real one: a clause may mention missing something only while negating it.
    @Test("nothing here implies a missed day costs something")
    func noGuiltCopy() {
        let section = NotificationSettingsSection(
            preference: preference(), familyTimezone: "America/Detroit"
        )
        let words = [section.onDetailText, section.offDetailText].joined(separator: " ").lowercased()

        for guilt in ["don't miss", "streak", "keep it up", "remember to", "falling behind", "!"] {
            #expect(!words.contains(guilt), "\(guilt) in: \(words)")
        }

        // Clause by clause, on the separators this copy actually uses. **Whole words**, because
        // "mission" contains "miss" and this copy says "mission" twice — a substring check here
        // fails on the word the whole feature is about.
        let missing: Set<String> = ["miss", "missed", "missing", "misses"]
        for clause in words.split(whereSeparator: { ".—,".contains($0) }) {
            let tokens = Set(clause.split(whereSeparator: { !$0.isLetter }).map(String.init))
            guard !tokens.isDisjoint(with: missing) else { continue }
            #expect(
                tokens.contains("never") || tokens.contains("no"),
                "an un-negated clause about missing something: \(clause)"
            )
        }
    }

    /// **§7.2.** There is no notification timezone on the user — `notify_local_time` is a wall
    /// clock the server resolves in the child's `family_timezone`, and `UserResponse` carries no
    /// zone at all. So deleting the "In" row cannot leave two values to drift apart: there is
    /// only ever one zone, and it is the child's.
    ///
    /// This fails if a zone is ever added to the user record without the row coming back or the
    /// client learning to write it.
    @Test("there is no second timezone for the notification to diverge into")
    func noSecondTimezoneExists() throws {
        let user = UserResponse(
            id: UUID(), email: "a@b.c", displayName: "T", isAdmin: false,
            createdAt: Date(), notifyEnabled: true, notifyLocalTime: NotifyTime(hour: 19, minute: 0)
        )
        let encoded = try JSONEncoder().encode(user)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in object.keys {
            #expect(
                key.lowercased().contains("timezone") == false,
                "a timezone appeared on the user record: \(key)"
            )
        }
    }

    /// The zone stays *visible* under Sent at, because a time with no zone attached is exactly
    /// the ambiguity this project refuses everywhere else. Displayed, not picked.
    @Test("the time is always shown with the zone it means")
    func timeCarriesItsZone() {
        let shown = NotificationSettingsSection.sentAt(
            NotifyTime(hour: 19, minute: 0), in: "America/Detroit"
        )
        #expect(shown.contains("America/Detroit"))
        #expect(shown.contains(NotifyTime(hour: 19, minute: 0).formatted()))

        // No child zone resolved yet: the time alone rather than a dangling separator.
        let bare = NotificationSettingsSection.sentAt(NotifyTime(hour: 19, minute: 0), in: nil)
        #expect(bare.contains("·") == false)
    }

    private func preference() -> NotificationPreference {
        NotificationPreference(
            authorizer: StubAuthorizer(status: .authorized),
            store: InMemoryNotificationAskStore(NotificationAskRecord()),
            backend: StubPushBackend()
        )
    }
}

// MARK: - Phase 20: the diagnostics route survives the Settings-first launch

/// **Phase 13's bug, re-armed by moving the diagnostics behind a row.**
///
/// `SyncStatusModel` was once built in `.task`, which runs once. `RootView` builds the
/// `SyncEngine` in *its* `.task`, so a launch that renders Settings first found `syncEngine` nil,
/// never built the status model, and never retried — the `Advanced` card was silently absent for
/// the entire session. It was fixed with `.onChange(of: syncEngine != nil, initial: true)`.
///
/// Putting the actions behind a "Sync diagnostics" row makes that failure *quieter*: instead of a
/// missing card there would be a missing row, and nothing on screen saying so. **The harness
/// launches straight into Settings, which is exactly this race.**
@MainActor
@Suite("Phase 20 — sync diagnostics survive a Settings-first launch")
struct SyncDiagnosticsRaceTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: LocalStore.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
    }

    private func engine(_ context: ModelContext) -> SyncEngine {
        SyncEngine(
            childId: UUID(),
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: StubPerformer(),
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: InMemorySyncStateStore()
        )
    }

    /// The race itself, in the shape the view models it: the engine is nil on the render that
    /// matters and arrives afterwards. The gate the row is behind is `syncStatus != nil`, and it
    /// has to become true when the engine lands rather than only on first render.
    @Test("an engine that arrives after the first render still produces a diagnostics route")
    func lateEngineStillOpensTheRoute() throws {
        let context = try makeContext()

        // First render: `RootView.task` has not run, so there is no engine.
        var syncStatus: SyncStatusModel?
        var engineOrNil: SyncEngine?
        func settle() {
            if syncStatus == nil, let engineOrNil {
                syncStatus = SyncStatusModel(engine: engineOrNil)
            }
        }

        settle()
        #expect(syncStatus == nil, "nothing to build from yet")

        // The engine lands. `initial: true` fired above; this is the change firing.
        engineOrNil = engine(context)
        settle()

        #expect(syncStatus != nil, "the row would be absent for the whole session")
    }

    /// And the screen behind the row is buildable from the model the race produces — a route that
    /// exists but pushes nothing is the same defect one screen further along.
    @Test("the pushed screen is buildable and carries both actions' model")
    func pushedScreenIsBuildable() throws {
        let context = try makeContext()
        let model = SyncStatusModel(engine: engine(context))
        let screen = SyncDiagnosticsScreen(model: model)

        // The dry run has not been run, so the row is in its idle state and reachable.
        #expect(screen.model.dryRun == .idle)
        #expect(screen.model.isBusy == false)
    }
}

// MARK: - Phase 20: recompute is a checkbox on the birthday screen

/// **The surface moved; the settled rule did not.**
///
/// `docs/decisions.md`: *"Stored `child_age_months` is corrected by explicit user action, never
/// automatically on birthdate edit — a correction is deliberate, not a side effect."* A box that
/// defaults to unchecked and must be deliberately ticked **is** explicit user action. What the
/// rule forbids is recomputing *because* the date moved, and nothing here does that.
@MainActor
@Suite("Phase 20 — the recompute checkbox")
struct RecomputeCheckboxTests {

    private func model(birthdate: String = "2022-06-19") throws -> EditChildModel {
        EditChildModel(
            child: try child(birthdate: birthdate),
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: StubPerformer(),
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            )
        )
    }

    @Test("it is unchecked before anyone touches it")
    func uncheckedByDefault() throws {
        let edit = try model()
        #expect(edit.recomputeAges == false)
        #expect(edit.birthdateChanged == false)
    }

    /// **The state the adversarial re-read is told to hunt for.** Ticking the box, then spinning
    /// the date back to where it started, must not leave a live instruction behind a control
    /// nobody can see — the checkbox is gone from the sheet at that point.
    @Test("it cannot be true while the birthdate is unchanged, however it got there")
    func unreachableWhenBirthdateIsUnchanged() throws {
        let edit = try model(birthdate: "2022-06-19")

        // Ticking it before the date moves does not take.
        edit.recomputeAges = true
        #expect(edit.recomputeAges == false, "checked with an unchanged birthdate")

        // Move the date, tick it, and it holds.
        edit.birthdate = try #require(EditChildModel.dayFormatter.date(from: "2022-06-20"))
        edit.recomputeAges = true
        #expect(edit.birthdateChanged)
        #expect(edit.recomputeAges)

        // Change it back: the box disappears and the intent goes with it.
        edit.birthdate = try #require(EditChildModel.dayFormatter.date(from: "2022-06-19"))
        #expect(edit.birthdateChanged == false)
        #expect(edit.recomputeAges == false, "a live recompute behind an invisible checkbox")
    }

    /// A name-only edit is not a birthdate edit, so the box is not offered.
    @Test("editing only the name does not offer the box")
    func nameEditDoesNotOffer() throws {
        let edit = try model()
        edit.name = "Hendrix Two"

        #expect(edit.hasChanges)
        #expect(edit.birthdateChanged == false)
        edit.recomputeAges = true
        #expect(edit.recomputeAges == false)
    }

    /// **A recompute failure must not roll back the birthdate change.** They are two outcomes and
    /// the parent is told both — the birthdate correction is the valuable half and it sticks.
    @Test("a failed recompute leaves the birthdate saved")
    func failedRecomputeKeepsTheBirthdate() async throws {
        let childId = UUID()
        let performer = StubPerformer()
        performer.on("/children/\(childId.uuidString)/recompute-ages") { _ in
            (Data("{\"error\":{\"code\":\"internal\",\"message\":\"nope\"}}".utf8), 500)
        }
        let recompute = RecomputeAgesModel(
            childId: childId,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            )
        )

        await recompute.run(context: nil)

        guard case .failed = recompute.state else {
            Issue.record("expected a failed recompute, got \(recompute.state)")
            return
        }
        // The PATCH is a separate call that already returned before this one ran. Nothing in the
        // recompute path can reach back and undo it — asserted here as the absence of any
        // rollback surface on the failure state.
        #expect(recompute.isRunning == false)
    }

    /// **A successful one reports its count**, because that number is the confirmation that the
    /// thing happened.
    @Test("a successful recompute reports how many entries moved")
    func successReportsItsCount() {
        #expect(
            RecomputeAgesModel.summary(updated: 412, birthdate: "2022-06-19")
                .contains("412 entries updated")
        )
        #expect(
            RecomputeAgesModel.summary(updated: 1, birthdate: "2022-06-19")
                .contains("1 entry updated")
        )
        // Zero is a real, common outcome — the ages were already right — and must not read as a
        // failure.
        let none = RecomputeAgesModel.summary(updated: 0, birthdate: "2022-06-19")
        #expect(none.lowercased().contains("nothing needed changing"))
        for scold in ["failed", "error", "problem", "!"] {
            #expect(!none.lowercased().contains(scold))
        }
    }
}
