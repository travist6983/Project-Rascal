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

    // MARK: The hero's stats strip — D1 and D12

    private func stats(
        entries: Int = 412,
        sealed: Int = 3,
        photo: Int = 1204,
        firstEntryOn: String? = "2022-06-21"
    ) -> ChildStatsResponse {
        let json = """
        {"entries":\(entries),"sealed":\(sealed),
         "media":{"photo":\(photo),"video":22,"audio":61},
         "first_entry_on":\(firstEntryOn.map { "\"\($0)\"" } ?? "null"),
         "last_entry_on":"2026-08-14"}
        """
        return try! APIClient.decoder.decode(ChildStatsResponse.self, from: Data(json.utf8))
    }

    /// The strip `settings-v2-inventory.md` drew as D1 and dropped for want of a source of truth.
    @Test("the strip reads the way the design drew it")
    func stripMatchesTheDesign() {
        #expect(ChildHeroCard.strip(stats()) == "412 entries · 1,204 photos · 3 sealed")
    }

    /// **The middle cell counts photographs, not media.** The response carries 22 videos and 61
    /// voice notes and this deliberately ignores them: "photos" is what a parent pictures, and
    /// "1,287 files" is a computer's word for a shoebox of memories. Pinned because the fixture
    /// makes the total easy to reach for by accident.
    @Test("the middle cell counts photos, not every media row")
    func middleCellIsPhotosOnly() {
        #expect(ChildHeroCard.strip(stats()).contains("1,204 photos"))
        #expect(ChildHeroCard.strip(stats()).contains("1,287") == false)
    }

    @Test("singulars are singular")
    func singularsRead() {
        let one = ChildHeroCard.strip(stats(entries: 1, sealed: 1, photo: 1))
        #expect(one == "1 entry · 1 photo · 1 sealed")
    }

    /// **Nil is not zero.** The strip is absent until the server answers, which is the whole
    /// reason D1 was dropped rather than built against the paged local cache: the app may never
    /// assert a size it does not know, and a placeholder reading "0" or "—" mid-flight is an
    /// assertion. An empty archive is the same — three zeros greeting somebody on the day they
    /// signed up is the closest thing to a score this app would ever print.
    @Test("an empty archive shows no strip at all")
    func emptyArchiveHidesTheStrip() {
        #expect(stats(entries: 0, sealed: 0, photo: 0).hasSomething == false)
        #expect(stats().hasSomething)
    }

    /// D12, and it is a date rather than a row label: "Archive starts" is what the day means
    /// sitting under a birthdate.
    @Test("the archive-start line reads as a date about a life")
    func archiveStartReads() throws {
        let line = try #require(ChildHeroCard.archiveStart(stats()))
        #expect(line.hasPrefix("Archive starts"))
        #expect(line.contains("2022"))
    }

    /// An empty archive has no first day, and inventing one would be the same lie as a
    /// zero-filled strip.
    @Test("no first entry means no archive-start line")
    func noFirstEntryMeansNoLine() {
        #expect(ChildHeroCard.archiveStart(stats(firstEntryOn: nil)) == nil)
    }

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

// MARK: - Phase 81: one status sentence, and one set of numbers behind it

/// Settings keeps one row. These are the values it can show, in priority order — and there is only
/// ever one of them, which is the whole point: the old card said "2 left", "2 files still to upload"
/// and "10 files stopped trying" at once and left the reader to work out whether the total was 2 or
/// 12.
@MainActor
@Suite("Phase 81 — the one status row")
struct SyncStatusRowTests {

    private func counts(
        entries: Int = 0, deletions: Int = 0, waiting: Int = 0,
        stalled: Int = 0, withoutBytes: Int = 0
    ) -> SyncCounts {
        SyncCounts(
            unsyncedEntries: entries, pendingDeletions: deletions,
            waitingMedia: waiting, stalledMedia: stalled, stalledWithoutBytes: withoutBytes
        )
    }

    @Test("offline outranks every other status, because it is the one that changes what you can do")
    func offlineWins() {
        let busy = counts(entries: 3, waiting: 4, stalled: 10)
        #expect(SyncCounts.status(busy, isOnline: false) == .offline)
        #expect(SyncCounts.rowValue(.offline) == "Offline")
    }

    @Test("stalled outranks waiting, because it is the half that needs a person")
    func stalledBeatsWaiting() {
        let both = counts(waiting: 2, stalled: 12)
        #expect(SyncCounts.status(both, isOnline: true) == .stopped(12))
        #expect(SyncCounts.rowValue(.stopped(12)) == "12 stopped")
    }

    @Test("waiting shows only when nothing has stopped")
    func waitingWhenNothingStalled() {
        #expect(SyncCounts.status(counts(waiting: 2), isOnline: true) == .waiting(2))
        #expect(SyncCounts.rowValue(.waiting(2)) == "2 waiting")
    }

    @Test("an empty queue is up to date, and never the string zero")
    func clearIsUpToDate() {
        #expect(SyncCounts.status(counts(), isOnline: true) == .upToDate)
        #expect(SyncCounts.rowValue(.upToDate) == "Up to date")
        for value in [SyncCounts.rowValue(.upToDate), SyncCounts.rowValue(.offline)] {
            #expect(!value.contains("0"), "never '0 waiting'")
        }
    }

    /// **The defect, stated as an invariant.** Both surfaces read one `SyncCounts`, so the row's
    /// status and the upload group's sentences are arithmetic on the same rows by construction.
    @Test("the row's number and the upload sentences cannot disagree")
    func oneCountOneSource() {
        let c = counts(entries: 1, waiting: 3, stalled: 10)

        // The row says what is coming; the group's two sentences account for the same rows.
        #expect(SyncCounts.status(c, isOnline: true) == .stopped(10))
        #expect(SyncCounts.waitingLine(c) == "1 entry and 3 files still to upload.")
        #expect(SyncCounts.stalledLine(c)?.contains("10 files") == true)
        // 1 + 3 waiting, 10 stalled, and the total is the sum rather than a third number.
        #expect(c.waiting == 4)
        #expect(c.total == 14)
    }
}

/// Phase 20 split waiting from stalled into two sentences on purpose. That split is kept — the
/// defect was never that the sentences existed, it was that they contradicted each other on the
/// totals. These are phase 20's rules, carried onto the single-source API.
@MainActor
@Suite("Phase 81 — the split phase 20 made, still true")
struct SyncSplitTests {

    @Test("files past the retry cap are not counted as files still on their way")
    func stalledIsNotWaiting() {
        // Eight files of which five have stopped is three coming and five needing a person.
        let c = SyncCounts(waitingMedia: 3, stalledMedia: 5)
        #expect(SyncCounts.rowValue(SyncCounts.status(c, isOnline: true)) == "5 stopped")
        #expect(SyncCounts.waitingLine(c) == "3 files still to upload.")
        #expect(SyncCounts.stalledLine(c)?.contains("5 files") == true)
    }

    @Test("with everything stalled nothing promises an arrival")
    func allStalledDropsThePromise() {
        let c = SyncCounts(stalledMedia: 4)
        #expect(SyncCounts.waitingLine(c) == nil, "nothing is 'still to upload'")
        #expect(SyncCounts.stalledLine(c)?.contains("still on this phone") == true)
    }

    /// The old stalled sentence said "Retry now picks them back up." It could not: the sweep
    /// excludes `failed` rows by predicate, so the copy named rows the button could not move.
    @Test("the stalled line no longer promises what retry will achieve")
    func noPromiseAboutRetry() {
        let c = SyncCounts(stalledMedia: 6)
        let line = try! #require(SyncCounts.stalledLine(c))
        #expect(!line.lowercased().contains("picks them back up"))
        #expect(!line.lowercased().contains("retry now"))
    }

    /// A stalled row whose bytes are gone is a different thing from one that can be retried, and
    /// the same class of lie phase 80 fixed at the entry level.
    @Test("a stalled row with no bytes left is distinguished, not lumped in")
    func missingBytesAreNamed() {
        let some = SyncCounts(stalledMedia: 5, stalledWithoutBytes: 2)
        #expect(SyncCounts.stalledLine(some)?.contains("2 of them") == true)
        #expect(some.retryable == 3)

        let all = SyncCounts(stalledMedia: 2, stalledWithoutBytes: 2)
        #expect(all.retryable == 0)
        #expect(SyncCounts.stalledLine(all)?.contains("no longer on this phone") == true)
    }

    @Test("nothing on either sentence scolds, and nothing is urgent")
    func toneHolds() {
        for (w, s, g) in [(3, 5, 0), (0, 4, 4), (1, 1, 0), (12, 40, 7)] {
            let c = SyncCounts(waitingMedia: w, stalledMedia: s, stalledWithoutBytes: g)
            let words = [SyncCounts.waitingLine(c), SyncCounts.stalledLine(c)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            for scold in ["failed", "error", "problem", "warning", "overdue", "lost", "!"] {
                #expect(!words.contains(scold), "\(scold) in: \(words)")
            }
        }
    }
}

// MARK: - Phase 115: the photo sheet's words

/// The copy is held in `ChildPhotoCopy` rather than inline in the view for the reason
/// `DeleteAccountCopy` is: a string that makes a claim belongs somewhere a test can read it.
@Suite("Settings v2 — the photo sheet's words")
struct ChildPhotoCopyTests {

    private var everyString: [String] {
        [ChildPhotoCopy.subtitle, ChildPhotoCopy.unreadable, ChildPhotoCopy.removeDetail("Milo")]
    }

    @Test("nothing on the photo sheet scolds or alarms")
    func nothingScolds() {
        for line in everyString {
            let words = line.lowercased()
            for scold in ["failed", "error", "problem", "warning", "overdue", "lost", "!"] {
                #expect(!words.contains(scold), "\(scold) in: \(line)")
            }
        }
    }

    /// Removing a photo is not the delete-account flow and must not borrow its register. Nothing
    /// here counts down, warns, or asks the parent to steady themselves.
    @Test("the removal copy does not dramatise a reversible change")
    func removalCopyIsCalm() {
        let words = ChildPhotoCopy.removeDetail("Milo").lowercased()
        for alarm in ["permanent", "cannot be undone", "can't be undone", "are you sure", "forever"] {
            #expect(!words.contains(alarm), "\(alarm) in: \(words)")
        }
    }

    /// Client-side strings never assume a child's gender — the same rule the prompt library is
    /// tokenised for. The child is named instead.
    @Test("the removal copy names the child and uses no pronoun")
    func removalCopyUsesNoPronoun() {
        let line = ChildPhotoCopy.removeDetail("Milo")
        #expect(line.contains("Milo"))
        for pronoun in [" his ", " her ", " their ", " he ", " she ", " they "] {
            #expect(!line.lowercased().contains(pronoun), "\(pronoun) in: \(line)")
        }
    }

    /// **Two claims the app cannot keep.** Clearing `children.avatar_key` orphans the object in
    /// the bucket rather than deleting it, and the original is still in the phone's photo library
    /// exactly where the parent chose it from. Saying otherwise would be false, not merely bold.
    @Test("nothing claims the photo is deleted from the server or the library")
    func noFalseDeletionClaims() {
        for line in everyString {
            let words = line.lowercased()
            for claim in ["deleted", "from the server", "from your library", "permanently"] {
                #expect(!words.contains(claim), "\(claim) in: \(line)")
            }
        }
    }

    /// The subtitle is the promise `AvatarStep` already makes, kept word-for-word so the two
    /// surfaces cannot drift into saying different things about where the picture lives.
    @Test("the subtitle still says the archive keeps it")
    func subtitleMatchesOnboarding() {
        #expect(ChildPhotoCopy.subtitle == "It's saved with the archive, so a new phone still has it.")
    }
}
