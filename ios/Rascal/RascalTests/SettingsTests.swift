import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Settings: the two edit sheets, the correction, the export, and the sync status.

// MARK: - Fixtures

private func childJSON(
    id: UUID,
    name: String = "Rascal",
    birthdate: String = "2021-06-01",
    timezone: String = "America/Detroit",
    ageMonths: Int = 62,
    role: String = "parent"
) -> String {
    """
    {"id":"\(id.uuidString)","name":"\(name)","birthdate":"\(birthdate)",
     "avatar_key":null,"family_timezone":"\(timezone)",
     "created_at":"2026-08-08T17:51:39.973377Z","updated_at":"2026-08-08T17:51:39.973377Z",
     "role":"\(role)","age_months":\(ageMonths)}
    """
}

private func userJSON(email: String?, displayName: String?) -> String {
    """
    {"id":"\(UUID().uuidString)",
     "email":\(email.map { "\"\($0)\"" } ?? "null"),
     "display_name":\(displayName.map { "\"\($0)\"" } ?? "null"),
     "is_admin":false,"created_at":"2026-08-08T17:51:26.993996Z"}
    """
}

private func decodeChild(_ json: String) throws -> ChildResponse {
    try APIClient.decoder.decode(ChildResponse.self, from: Data(json.utf8))
}

private func decodeUser(_ json: String) throws -> UserResponse {
    try APIClient.decoder.decode(UserResponse.self, from: Data(json.utf8))
}

private func errorJSON(_ code: String, _ message: String, field: String? = nil) -> Data {
    Data("""
    {"error":{"code":"\(code)","message":"\(message)",
     "field":\(field.map { "\"\($0)\"" } ?? "null")}}
    """.utf8)
}

// MARK: - Edit child

@MainActor
@Suite("Settings — edit child")
struct EditChildModelTests {

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    private func model(_ performer: StubPerformer, child: ChildResponse? = nil) throws -> EditChildModel {
        EditChildModel(child: try child ?? decodeChild(childJSON(id: UUID())), api: client(performer))
    }

    @Test("save is disabled until something actually changes")
    func disabledWhileUnchanged() throws {
        let model = try model(StubPerformer())
        #expect(model.hasChanges == false)
        #expect(model.canSave == false)

        model.name = "Miles"
        #expect(model.hasChanges)
        #expect(model.canSave)
    }

    @Test("whitespace-only edits are not changes, and a blank name is not valid")
    func validation() throws {
        let model = try model(StubPerformer())
        // Trailing space is not an edit. Sending it would rename the child to itself and move
        // `updated_at` for nothing.
        model.name = "Rascal   "
        #expect(model.hasChanges == false)

        model.name = "   "
        #expect(model.isValid == false)
        #expect(model.canSave == false)
    }

    @Test("the birthdate goes over the wire as a calendar day, never as an instant")
    func sendsBirthdateAsADay() async throws {
        let performer = StubPerformer()
        let id = UUID()
        let ok = Data("""
        {"id":"\(id.uuidString)","name":"Rascal","birthdate":"2021-06-02","avatar_key":null,
         "family_timezone":"America/Detroit","created_at":"2026-08-08T17:51:39.973377Z",
         "updated_at":"2026-08-09T10:00:00.000000Z"}
        """.utf8)
        performer.on("/children/") { _ in (ok, 200) }

        let model = try model(performer, child: try decodeChild(childJSON(id: id)))
        model.birthdate = EditChildModel.dayFormatter.date(from: "2021-06-02")!
        _ = await model.save()

        let body = try #require(performer.requests.last?.httpBody)
        let json = try #require(String(data: body, encoding: .utf8))
        // A birthday has no time and no zone. Encoding one as a timestamp is how it lands a day
        // early for anyone west of Greenwich.
        #expect(json.contains("\"birthdate\":\"2021-06-02\""))
        #expect(!json.contains("T00:00"))
        #expect(json.contains("family_timezone"))
    }

    @Test("avatar_key is never sent, so the server's exclude_unset leaves it alone")
    func doesNotTouchAvatar() async throws {
        let performer = StubPerformer()
        let id = UUID()
        let ok = Data("""
        {"id":"\(id.uuidString)","name":"Miles","birthdate":"2021-06-01","avatar_key":"k",
         "family_timezone":"America/Detroit","created_at":"2026-08-08T17:51:39.973377Z",
         "updated_at":"2026-08-09T10:00:00.000000Z"}
        """.utf8)
        performer.on("/children/") { _ in (ok, 200) }

        let model = try model(performer, child: try decodeChild(childJSON(id: id)))
        model.name = "Miles"
        _ = await model.save()

        let json = try #require(performer.requests.last?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!json.contains("avatar"))
    }

    @Test("a server error is mapped by code and the sheet keeps the input")
    func serverErrorKeepsInput() async throws {
        let performer = StubPerformer()
        performer.on("/children/") { _ in (errorJSON("not_authorized", "Only a parent."), 403) }

        let model = try model(performer)
        model.name = "Miles"
        let saved = await model.save()

        #expect(saved == nil, "a refused write returns nothing, so the sheet stays open")
        #expect(model.name == "Miles", "the parent's typing survives the failure")
        // Mapped from `code`, never from message text.
        #expect(model.notice == "Only a parent can change these.")
    }

    @Test("validation_failed surfaces the server's own sentence")
    func validationFailedUsesServerMessage() async throws {
        let performer = StubPerformer()
        performer.on("/children/") { _ in
            (errorJSON("validation_failed", "Unknown timezone: Mars/Olympus.", field: "family_timezone"), 422)
        }

        let model = try model(performer)
        model.timezone = "Mars/Olympus"
        _ = await model.save()

        #expect(model.notice == "Unknown timezone: Mars/Olympus.")
    }

    @Test("saving a changed birthdate issues no recompute call")
    func birthdateSaveDoesNotRecompute() async throws {
        // The decision this guards: `child_age_months` is computed at write and stored, so a
        // birthdate typo cannot silently reshape five hundred entries. The correction is a
        // separate, explicit action — and it must never be a side effect of this save.
        let performer = StubPerformer()
        let id = UUID()
        let ok = Data("""
        {"id":"\(id.uuidString)","name":"Rascal","birthdate":"2021-07-04","avatar_key":null,
         "family_timezone":"America/Detroit","created_at":"2026-08-08T17:51:39.973377Z",
         "updated_at":"2026-08-09T10:00:00.000000Z"}
        """.utf8)
        performer.on("/children/") { _ in (ok, 200) }

        let model = try model(performer, child: try decodeChild(childJSON(id: id)))
        model.birthdate = EditChildModel.dayFormatter.date(from: "2021-07-04")!
        #expect(model.birthdateChanged)
        _ = await model.save()

        #expect(performer.count(for: "/recompute-ages") == 0)
        #expect(!performer.requests.contains { $0.url?.path().contains("recompute") ?? false })
        // Exactly one request: the PATCH, and nothing behind it.
        #expect(performer.requests.count == 1)
        #expect(performer.requests.first?.httpMethod == "PATCH")
    }

    @Test("a birthdate survives the round trip to the picker and back, on the same day")
    func birthdateRoundTripIsStable() throws {
        // The bug this pins: the wire format carries no zone, `DatePicker` has none of its own
        // and always renders in `Calendar.current`, so parsing in UTC put midnight-UTC into a
        // UTC−4 calendar and drew the day before. A birthday of 2021-06-01 showed as 5/31/21.
        for raw in ["2021-06-01", "2024-02-29", "1999-12-31", "2021-01-01", "2026-07-04"] {
            let parsed = try #require(EditChildModel.dayFormatter.date(from: raw))
            #expect(EditChildModel.dayFormatter.string(from: parsed) == raw)

            // And the day the picker would draw is that same calendar day, not its neighbour.
            let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
            let drawn = String(
                format: "%04d-%02d-%02d",
                components.year ?? 0, components.month ?? 0, components.day ?? 0
            )
            #expect(drawn == raw, "the picker draws \(drawn) for \(raw)")
        }
    }

    @Test("the model round-trips an unedited birthdate without moving it")
    func unchangedBirthdateIsNotAnEdit() throws {
        // If parse and format disagreed by a day, simply opening the sheet would look like an
        // edit and Save would light up with nothing typed.
        let model = try model(StubPerformer(), child: try decodeChild(childJSON(id: UUID(), birthdate: "2021-06-01")))
        #expect(model.birthdateString == "2021-06-01")
        #expect(model.birthdateChanged == false)
        #expect(model.hasChanges == false)
    }

    @Test("the timezone catalogue finds a city and labels its offset")
    func timezoneSearch() {
        #expect(TimeZoneCatalog.matching("detroit").contains("America/Detroit"))
        #expect(TimeZoneCatalog.matching("").count == TimeZoneCatalog.all.count)
        #expect(TimeZoneCatalog.city("America/New_York") == "New York")
        #expect(TimeZoneCatalog.region("America/New_York") == "America")
        #expect(TimeZoneCatalog.offsetLabel("UTC") == "GMT")
        // Every identifier the picker offers is one the server will accept.
        #expect(TimeZoneCatalog.all.allSatisfy { TimeZone(identifier: $0) != nil })
    }
}

// MARK: - Edit profile

@MainActor
@Suite("Settings — edit profile")
struct EditProfileModelTests {

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    @Test("a nil email renders as words, not as a blank and not as a crash")
    func nilEmailIsSafe() throws {
        // Apple's relay addresses are unreliable and `users.email` is nullable for exactly that
        // reason. This is the row that has to survive it.
        let user = try decodeUser(userJSON(email: nil, displayName: "Travis"))
        let model = EditProfileModel(user: user, fallbackEmail: nil, api: client(StubPerformer()))

        #expect(model.email == nil)
        #expect(model.emailIsMissing)
        #expect(model.emailDisplay == "Not provided")
        #expect(!model.emailDisplay.isEmpty)
    }

    @Test("an email that exists is shown as itself")
    func emailShown() throws {
        let user = try decodeUser(userJSON(email: "travis@example.com", displayName: nil))
        let model = EditProfileModel(user: user, fallbackEmail: nil, api: client(StubPerformer()))

        #expect(model.emailDisplay == "travis@example.com")
        #expect(model.emailIsMissing == false)
        // A null display_name starts the field empty rather than with the word "null" in it.
        #expect(model.displayName.isEmpty)
    }

    @Test("with no user record at all, the configured account stands in")
    func warmStartFallback() {
        // A warm start has a token and no user: the record arrived with the sign-in response
        // and there is no `GET /me` to ask again.
        let model = EditProfileModel(user: nil, fallbackEmail: "dev@rascal.local", api: client(StubPerformer()))
        #expect(model.emailDisplay == "dev@rascal.local")

        let blind = EditProfileModel(user: nil, fallbackEmail: nil, api: client(StubPerformer()))
        #expect(blind.emailDisplay == "Not provided")
    }

    @Test("save is disabled while unchanged, blank, over-length, or in flight")
    func disabledStates() throws {
        let user = try decodeUser(userJSON(email: "t@example.com", displayName: "Travis"))
        let model = EditProfileModel(user: user, fallbackEmail: nil, api: client(StubPerformer()))

        #expect(model.canSave == false, "unchanged")

        model.displayName = "   "
        #expect(model.isValid == false)
        #expect(model.canSave == false, "blank after trimming")

        model.displayName = String(repeating: "a", count: EditProfileModel.maxDisplayNameLength + 1)
        #expect(model.isValid == false)
        #expect(model.lengthWarning != nil, "the bound is stated before the write, not after it")

        model.displayName = "Travis T"
        #expect(model.canSave)
    }

    @Test("invalid_display_name comes back as the server's own sentence")
    func mapsInvalidDisplayName() async throws {
        let performer = StubPerformer()
        performer.on("/me") { _ in
            (errorJSON("invalid_display_name", "A display name cannot be blank.", field: "display_name"), 400)
        }

        let user = try decodeUser(userJSON(email: "t@example.com", displayName: "Travis"))
        let model = EditProfileModel(user: user, fallbackEmail: nil, api: client(performer))
        model.displayName = "Someone Else"
        let saved = await model.save()

        #expect(saved == nil)
        #expect(model.displayName == "Someone Else", "the sheet keeps what was typed")
        #expect(model.notice == "A display name cannot be blank.")
    }

    @Test("a successful save sends the trimmed name and returns the user")
    func savesTrimmed() async throws {
        let performer = StubPerformer()
        let ok = Data(userJSON(email: "t@example.com", displayName: "Travis T").utf8)
        performer.on("/me") { _ in (ok, 200) }

        let user = try decodeUser(userJSON(email: "t@example.com", displayName: "Travis"))
        let model = EditProfileModel(user: user, fallbackEmail: nil, api: client(performer))
        model.displayName = "  Travis T  "
        let saved = await model.save()

        #expect(saved?.displayName == "Travis T")
        let json = try #require(performer.requests.last?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(json.contains("\"display_name\":\"Travis T\""))
        // Email is not the user's to retype, so it is never sent.
        #expect(!json.contains("email"))
    }
}

// MARK: - Recompute ages

@MainActor
@Suite("Settings — recompute ages")
struct RecomputeAgesModelTests {

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: LocalStore.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
    }

    @Test("a run reports the server's count and then pulls")
    func runsAndPulls() async throws {
        let performer = StubPerformer()
        let child = UUID()
        let ok = Data("""
        {"child_id":"\(child.uuidString)","entries_updated":412,"birthdate":"2021-06-01"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        // The newest page is re-read afterwards so the entries a parent looks at straight
        // after this are correct immediately. Not a full sync — see the model's own note.
        let page = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (page, 200) }

        let context = try makeContext()
        let model = RecomputeAgesModel(childId: child, api: client(performer))
        await model.run(context: context)

        #expect(model.state == .done(updated: 412, birthdate: "2021-06-01"))
        #expect(performer.count(for: "/recompute-ages") == 1)
        #expect(performer.count(for: "/entries") == 1, "one page, not the whole archive")
    }

    @Test("zero updated is a real outcome and does not read as a failure")
    func zeroIsFine() async throws {
        let performer = StubPerformer()
        let child = UUID()
        let ok = Data("""
        {"child_id":"\(child.uuidString)","entries_updated":0,"birthdate":"2021-06-01"}
        """.utf8)
        performer.on("/recompute-ages") { _ in (ok, 200) }

        let model = RecomputeAgesModel(childId: child, api: client(performer))
        await model.run(context: nil)

        #expect(model.state == .done(updated: 0, birthdate: "2021-06-01"))
        #expect(RecomputeAgesModel.summary(updated: 0, birthdate: "2021-06-01")
            == "Nothing needed changing. Every age already matched 2021-06-01.")
    }

    @Test("the summary counts in words a person would use")
    func summaryReadsWell() {
        #expect(RecomputeAgesModel.summary(updated: 1, birthdate: "2021-06-01")
            == "1 entry updated to match 2021-06-01.")
        #expect(RecomputeAgesModel.summary(updated: 412, birthdate: "2021-06-01")
            == "412 entries updated to match 2021-06-01.")
        // Neutral and factual. It is a repair tool, not a warning.
        for updated in [0, 1, 412] {
            let text = RecomputeAgesModel.summary(updated: updated, birthdate: "2021-06-01")
            #expect(!text.lowercased().contains("failed"))
            #expect(!text.contains("!"))
        }
    }

    @Test("a refusal is mapped by code")
    func mapsError() async throws {
        let performer = StubPerformer()
        performer.on("/recompute-ages") { _ in (errorJSON("not_authorized", "Parent only."), 403) }

        let model = RecomputeAgesModel(childId: UUID(), api: client(performer))
        await model.run(context: nil)

        #expect(model.state == .failed("Only a parent on this archive can do this."))
        #expect(performer.count(for: "/entries") == 0, "a refused correction refreshes nothing")
    }
}

// MARK: - Sync status

@MainActor
@Suite("Settings — sync status")
struct SyncStatusTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: LocalStore.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
    }

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    @Test("an empty store reports zero, and reports it as clear")
    func zeroIsClear() throws {
        let context = try makeContext()
        let sync = EntrySync(api: client(StubPerformer()), context: context)

        let outstanding = sync.outstanding()
        #expect(outstanding == EntrySync.Outstanding())
        #expect(outstanding.total == 0)
        #expect(outstanding.isClear)
    }

    @Test("the counts come from the same descriptors the sweep acts on")
    func readsTheExistingStore() throws {
        // Not a second source of truth for upload state: `outstanding()` and `unsyncedCount()`
        // read the same descriptors, so the number on screen is the number the sweep will act on.
        let context = try makeContext()

        let pending = Entry(childId: UUID(), occurredAt: Date(), body: "written offline")
        context.insert(pending)

        let deleted = Entry(childId: UUID(), occurredAt: Date(), body: "binned offline")
        deleted.existsOnServer = true
        deleted.sync = .synced
        context.insert(deleted)
        try context.save()
        EntryCache.markDeleted(deleted, in: context)

        let media = Media(entryId: pending.id, kind: "photo", contentType: "image/jpeg", byteCount: 10)
        context.insert(media)
        try context.save()

        let sync = EntrySync(api: client(StubPerformer()), context: context)
        let outstanding = sync.outstanding()

        #expect(outstanding.entries == 1)
        #expect(outstanding.deletions == 1)
        #expect(outstanding.media == 1)
        #expect(outstanding.total == 3)
        #expect(outstanding.isClear == false)
        // One number, two callers, no drift.
        #expect(sync.unsyncedCount() == outstanding.total)
    }

    @Test("a complete upload stops counting")
    func completeMediaIsNotOutstanding() throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "done")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        let media = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 10)
        media.state = .complete
        context.insert(media)
        try context.save()

        #expect(EntrySync(api: client(StubPerformer()), context: context).outstanding().isClear)
    }

    @Test("retry goes through the one sweep, so entries drain before media")
    func retryUsesTheExistingSweep() async throws {
        // A media-only retry path would spend an attempt on a file whose entry the server has
        // never seen — a guaranteed 404 that pushes that file's backoff out for nothing.
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written offline")
        context.insert(entry)
        let media = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 10)
        context.insert(media)
        try context.save()

        let performer = StubPerformer()
        let created = Data("""
        {"id":"\(entry.id.uuidString)","child_id":"\(entry.childId.uuidString)",
         "assignment_id":null,"occurred_at":"2026-08-09T10:00:00.000Z",
         "created_at":"2026-08-09T10:00:00.000Z","updated_at":"2026-08-09T10:00:00.000Z",
         "deleted_at":null,"title":null,"body":"written offline","entry_type":"text",
         "child_age_months":62,"unlock_at_age":null}
        """.utf8)
        performer.on("/entries") { _ in (created, 201) }

        let sync = EntrySync(api: client(performer), context: context)
        await sync.sweep()

        #expect(entry.sync == .synced)
        // The entry landed first. Its media is now eligible, which is the whole ordering rule.
        #expect(sync.outstanding().entries == 0)
    }
}
