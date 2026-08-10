import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The seal control — the writer for a reader that shipped in Phase 4 and waited.
///
/// The round-trip test near the bottom is the one that matters most: it is the only assertion
/// that the thing this phase writes is the thing the archive already knows how to read.
@MainActor
@Suite("Seal control")
struct SealControlTests {

    private func assignment(kind: String, unlockAtAge: Int? = nil) throws -> AssignmentResponse {
        let json = """
        {"id":"\(UUID().uuidString)","prompt_id":"\(UUID().uuidString)","slot":"letter",
         "body":"Write him one thing about money you wish someone had told you at nineteen.",
         "kind":"\(kind)","completion_mode":"text","status":"open",
         "assigned_on":"2026-08-09","expires_on":"2026-08-16","is_custom":false,
         "unlock_at_age":\(unlockAtAge.map(String.init) ?? "null")}
        """
        return try APIClient.decoder.decode(AssignmentResponse.self, from: Data(json.utf8))
    }

    // MARK: Who gets the control

    @Test("a letter prompt offers the control and nothing else does")
    func onlyLettersOfferIt() throws {
        #expect(SealSetting.isOffered(for: try assignment(kind: "letter"), isEditing: false))

        for other in ["question", "photo", "video", "audio", "activity"] {
            #expect(
                SealSetting.isOffered(for: try assignment(kind: other), isEditing: false) == false,
                "\(other) must not offer sealing"
            )
        }

        // Freeform — no assignment at all. Sealing one is a separate decision.
        #expect(SealSetting.isOffered(for: nil, isEditing: false) == false)
    }

    /// `PATCH` supports changing a seal; no UI does this phase. Offering the control while
    /// editing would imply an edit that never gets sent.
    @Test("editing an existing entry does not offer the control")
    func editingDoesNotOfferIt() throws {
        #expect(SealSetting.isOffered(for: try assignment(kind: "letter"), isEditing: true) == false)
    }

    // MARK: The default

    @Test("sealing is on by default for a letter, and off for everything else")
    func sealedByDefaultForLetters() throws {
        #expect(SealSetting.initial(for: try assignment(kind: "letter")).isSealed)
        #expect(SealSetting.initial(for: try assignment(kind: "question")).isSealed == false)
        #expect(SealSetting.initial(for: nil).isSealed == false)
    }

    /// `GET /today` already carries the prompt's `default_unlock_age` on the assignment —
    /// `schemas/today.py` sets it from `prompt.default_unlock_age` — so this reads a real field
    /// rather than guessing.
    @Test("the age comes from the prompt's default_unlock_age when there is one")
    func defaultComesFromThePrompt() throws {
        #expect(SealSetting.initial(for: try assignment(kind: "letter", unlockAtAge: 16)).age == 16)
        #expect(SealSetting.initial(for: try assignment(kind: "letter", unlockAtAge: 21)).age == 21)
    }

    @Test("and falls back to 18 when the prompt does not say")
    func fallsBackToEighteen() throws {
        #expect(SealSetting.initial(for: try assignment(kind: "letter", unlockAtAge: nil)).age == 18)
        #expect(SealSetting.fallbackAge == 18)
    }

    /// The server accepts 0–120, so the library is free to carry an age the stepper cannot show.
    /// Clamping beats starting outside the range the control can reach.
    @Test("a prompt default outside the stepper's range is clamped into it")
    func outOfRangeDefaultsAreClamped() {
        #expect(SealSetting.resolvedAge(25) == 21)
        #expect(SealSetting.resolvedAge(4) == 10)
        #expect(SealSetting.resolvedAge(0) == 10)
        #expect(SealSetting.resolvedAge(120) == 21)
    }

    @Test("the stepper's bounds are 10 and 21")
    func stepperBounds() {
        #expect(SealSetting.range.lowerBound == 10)
        #expect(SealSetting.range.upperBound == 21)
        // A `Stepper(value:in:)` cannot leave its range, so the bounds are the assertion — but
        // the resolver has to agree with them or the control opens on a value it forbids.
        #expect(SealSetting.range.contains(SealSetting.resolvedAge(nil)))
        for candidate in [nil, 0, 9, 10, 18, 21, 22, 120] as [Int?] {
            #expect(SealSetting.range.contains(SealSetting.resolvedAge(candidate)))
        }
    }

    // MARK: What goes on the wire

    private func createBody(unlockAtAge: Int?) throws -> [String: Any] {
        let request = EntryCreateRequest(
            id: UUID(), childId: UUID(), assignmentId: UUID(),
            occurredAt: Date(timeIntervalSince1970: 1_786_000_000),
            title: nil, body: "for when you are older", unlockAtAge: unlockAtAge, tags: []
        )
        let data = try APIClient.encoder.encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a sealed letter sends its age")
    func sealedSendsTheAge() throws {
        #expect(try createBody(unlockAtAge: 18)["unlock_at_age"] as? Int == 18)
    }

    /// **Null, not zero and not absent.** Zero is a value, and every reader in this app decides a
    /// row is sealed by `unlock_at_age IS NOT NULL` — a zero would render "Opens at 0." forever.
    /// An absent key is worse in a subtler way: it reads as "no opinion", and the parent had one.
    @Test("turning sealing off sends an explicit null, not zero and not an omitted key")
    func unsealedSendsExplicitNull() throws {
        let body = try createBody(unlockAtAge: nil)

        #expect(body.keys.contains("unlock_at_age"), "the key must be present")
        #expect(body["unlock_at_age"] is NSNull, "and its value must be null")
        #expect(body["unlock_at_age"] as? Int != 0)

        // Belt and braces on the bytes, because `JSONSerialization` maps a JSON null to NSNull
        // and an absent key to nil, and those read alike at a glance.
        let raw = try APIClient.encoder.encode(
            EntryCreateRequest(
                id: UUID(), childId: UUID(), assignmentId: nil,
                occurredAt: Date(timeIntervalSince1970: 1_786_000_000),
                title: nil, body: nil, unlockAtAge: nil, tags: []
            )
        )
        #expect(String(decoding: raw, as: UTF8.self).contains("\"unlock_at_age\":null"))
    }

    @Test("the setting turns into the field the wire wants")
    func settingMapsToTheWire() {
        #expect(SealSetting(isSealed: true, age: 18).unlockAtAge == 18)
        #expect(SealSetting(isSealed: false, age: 18).unlockAtAge == nil, "not 0, and not 18")
    }

    // MARK: The reader and the writer meeting

    /// **The test this phase exists for.** An entry written with a seal has to come back out of
    /// the archive as a sealed one, through the reader Phase 4 built and this run did not touch.
    @Test("an entry created sealed renders with the sealed skin and no preview")
    func sealedEntryRendersSealed() throws {
        let seal = SealSetting(isSealed: true, age: 18)
        let entry = try cachedEntry(
            type: "text",
            body: "Money is mostly patience, and nobody tells you that at nineteen.",
            unlockAtAge: seal.unlockAtAge
        )

        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.isSealed)
        #expect(card.unlockAtAge == 18)
        // The words are in the row and the card is deliberately not showing them.
        #expect(card.preview == nil)
        // No title either, which is what makes `EntryCard` fall through to "A letter". That
        // string lives in the view rather than the model, so this asserts the condition that
        // produces it rather than the string itself.
        #expect(card.title == nil)
        #expect(card.typeLabel == "Written", "the entry_type is still what it is")
        // And what Entry Detail gates its sealed card on.
        #expect(entry.unlockAtAge != nil)
    }

    @Test("an unsealed letter renders as an ordinary entry")
    func unsealedEntryRendersOrdinary() throws {
        let entry = try cachedEntry(
            type: "text",
            body: "Money is mostly patience.",
            unlockAtAge: SealSetting(isSealed: false, age: 18).unlockAtAge
        )
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.isSealed == false)
        #expect(card.preview == "Money is mostly patience.")
        #expect(entry.unlockAtAge == nil)
    }

    /// The writer's copy and the reader's are the same sentence about the same object. The card
    /// says "Opens at 18."; so does the control.
    /// `EntryCard` writes "Opens at 18." on a sealed row and `EntryDetailScreen` writes "Sealed
    /// until 18."; the writer says "Opens at 18" over the stepper. Same words, same object, both
    /// ends of its life. If someone rewords one of these, this is what should stop them.
    @Test("the control's copy agrees with the reader's")
    func copyAgreesWithTheReader() {
        #expect(SealSetting(isSealed: true, age: 18).openingLine == "Opens at 18")
        #expect(SealSetting(isSealed: true, age: 13).openingLine == "Opens at 13")
        // The age is stated once, by the stepper. The sentence beneath must not repeat it.
        #expect(SealSetting(isSealed: true, age: 18).explanation.contains("18") == false)
        #expect(SealSetting(isSealed: false, age: 18).explanation.contains("readable straight away"))
    }

    // MARK: Surviving sync

    /// A sealed letter written on this phone and not yet pushed must not lose its seal to a pull.
    /// The conflict rule already protects unpushed rows; this pins that it covers this field.
    @Test("a locally created sealed entry survives a pull that has not seen it yet")
    func localSealSurvivesAPull() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entryId = UUID()
        let occurred = Date(timeIntervalSince1970: 1_700_000_000)

        // Written here, sealed, and never pushed.
        let local = Entry(
            id: entryId, childId: child, occurredAt: occurred,
            body: "for when you are older", unlockAtAge: 18
        )
        local.sync = .pending
        context.insert(local)
        try context.save()

        // The server has an older, unsealed copy — which is what it would have if the create
        // had not landed yet.
        let performer = sealPerformer(syncJSON(
            entries: [entryJSON(
                id: entryId, childId: child, occurredAt: occurred,
                body: "for when you are older", unlockAtAge: nil,
                updatedAt: occurred
            )],
            cursor: laggedCursor(newest: occurred)
        ))
        await sealEngine(childId: child, performer: performer, context: context).pull()

        let stored = try #require(
            try context.fetch(FetchDescriptor<Entry>()).first { $0.id == entryId }
        )
        #expect(stored.unlockAtAge == 18, "an unpushed seal is the parent's most recent intent")
    }

    @Test("a sealed entry arriving from the server lands sealed")
    func serverSealArrivesIntact() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entryId = UUID()
        let occurred = Date(timeIntervalSince1970: 1_700_000_000)

        let performer = sealPerformer(syncJSON(
            entries: [entryJSON(
                id: entryId, childId: child, occurredAt: occurred,
                body: "for when you are older", unlockAtAge: 18
            )],
            cursor: laggedCursor(newest: occurred)
        ))
        await sealEngine(childId: child, performer: performer, context: context).pull()

        let stored = try #require(
            try context.fetch(FetchDescriptor<Entry>()).first { $0.id == entryId }
        )
        #expect(stored.unlockAtAge == 18)
        #expect(EntryCardModel(entry: stored, media: []).isSealed)
    }
}

/// Local to this suite. `SyncEngineTests` keeps equivalents private, and one shared helper across
/// two suites is a thing to keep in step for no benefit.

/// Answers every `/sync` poll with the same page.
func sealPerformer(_ page: Data) -> StubPerformer {
    let performer = StubPerformer()
    performer.on("/sync") { _ in (page, 200) }
    return performer
}
@MainActor
func sealEngine(
    childId: UUID,
    performer: StubPerformer,
    context: ModelContext
) -> SyncEngine {
    SyncEngine(
        childId: childId,
        api: APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        ),
        context: context,
        state: InMemorySyncStateStore(pullEnabled: true)
    )
}
