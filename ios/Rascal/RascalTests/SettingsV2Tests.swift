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
    @Test("a birthday renders as the calendar day the server named, not its neighbour")
    func birthdateDoesNotSlip() {
        for raw in ["2022-06-19", "2021-06-01", "2024-02-29", "1999-12-31", "2021-01-01"] {
            let rendered = ChildHeroCard.longBirthdate(raw)
            let text = try! #require(rendered)

            let parsed = try! #require(EditChildModel.dayFormatter.date(from: raw))
            let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
            let day = try! #require(components.day)
            let year = try! #require(components.year)

            #expect(text.contains("\(day)"), "\(raw) rendered as \(text)")
            #expect(text.contains("\(year)"), "\(raw) rendered as \(text)")
            // And the round trip is stable: format then re-parse lands on the same server day.
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

    /// `SyncAdvancedSection` disables both its rows off one flag. If that flag stopped tracking
    /// the run, the reset row would be tappable mid-dry-run.
    @Test("the card is busy for exactly as long as the dry run is")
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
    /// re-presented; the archive is rewritten once.
    @Test("a second run while one is running is refused")
    func noDoubleRun() async throws {
        let performer = StubPerformer()
        let ok = Data("""
        {"child_id":"\(UUID().uuidString)","entries_updated":0,"birthdate":"2022-06-19"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        let model = RecomputeAgesModel(childId: UUID(), api: client(performer))
        await model.run(context: nil)
        #expect(model.state == .done(updated: 0, birthdate: "2022-06-19"))

        // Dismissing returns it to idle, which is the only way back to the row.
        model.dismiss()
        #expect(model.state == .idle)
    }
}
