import Foundation

/// What the app leaves in the shared container for the widget to render.
///
/// **This is the entire channel between the app and the extension.** The widget makes no network
/// requests, holds no credential, and reads no database — it reads this file. A token refresh
/// running inside an extension, concurrently with the app, can invalidate the app's own session,
/// and that failure is intermittent and very hard to trace back to its cause. Giving the
/// extension no way to make one is cheaper than debugging it later.
///
/// **It carries prompts, and nothing a parent wrote.** There is no field here for an entry body,
/// a title, a transcript, a photo, or a sealed letter, and that is the guarantee rather than a
/// convention someone has to remember: this renders on a Lock Screen that other people in the
/// room can read over a shoulder. A prompt is the archive's question. An entry is the answer, and
/// the answer is nobody else's.
///
/// A few hundred bytes. It is not a cache of the archive.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {

    /// Bumped when a field's meaning changes. A snapshot written by an older app than the widget
    /// installed beside it — or the reverse, during an upgrade — resolves to the neutral state
    /// rather than being coerced into a shape it was never written in.
    static let currentVersion = 1

    let version: Int
    /// `YYYY-MM-DD`, exactly as the server computed it in `familyTimezone`. Never derived here.
    let assignedOn: String
    /// The IANA identifier the server used. Stored so the *reader* can ask whether `assignedOn`
    /// is still today without guessing at a zone — a phone in an airport is a real case.
    let familyTimezone: String
    /// First name only. It appears on a Lock Screen; a full name is more than the glass needs.
    let childFirstName: String
    let mission: Item?
    let question: Item?

    init(
        version: Int = WidgetSnapshot.currentVersion,
        assignedOn: String,
        familyTimezone: String,
        childFirstName: String,
        mission: Item?,
        question: Item?
    ) {
        self.version = version
        self.assignedOn = assignedOn
        self.familyTimezone = familyTimezone
        self.childFirstName = childFirstName
        self.mission = mission
        self.question = question
    }

    /// One prompt, and whether it is finished.
    ///
    /// `isDone` is a state, never a score. Nothing counts how many are outstanding.
    nonisolated struct Item: Codable, Equatable, Sendable {
        /// For the deep link. The app resolves it against the board it holds; an id it does not
        /// recognise lands on Today rather than opening a composer for nothing.
        let assignmentId: UUID
        /// The prompt's own words — the server's question, not the parent's answer.
        let body: String
        /// `PromptKind` raw value. Chooses the SF Symbol, which is how the Lock Screen tells a
        /// mission from a question once colour is gone.
        let kind: String
        let isDone: Bool

        init(assignmentId: UUID, body: String, kind: String, isDone: Bool) {
            self.assignmentId = assignmentId
            self.body = body
            self.kind = kind
            self.isDone = isDone
        }

        /// **How a mission is told from a question once colour is gone.**
        ///
        /// Lock Screen accessory widgets are rendered as a mask: everything becomes one tint, so
        /// terracotta-means-mission and periwinkle-means-question — which carry real meaning in
        /// this product — say nothing at all there. The symbol is the channel that survives, and
        /// it is the same one the `PromptCard` already uses, so the Lock Screen agrees with the
        /// app rather than inventing a second vocabulary.
        ///
        /// This mirrors `PromptKind.symbol` rather than calling it. `PromptKind` lives in the API
        /// wire model, and giving the extension that file would hand a target that makes no
        /// network requests the whole shape of the API's responses. Six cases duplicated is the
        /// smaller cost; the mapping is asserted against `PromptKind.symbol` in the tests, so the
        /// two cannot drift silently.
        var symbolName: String {
            switch kind {
            case "question": "text.bubble"
            case "photo": "camera"
            case "video": "video"
            case "audio": "waveform"
            case "activity": "figure.walk"
            case "letter": "envelope"
            default: "sparkles"
            }
        }
    }
}

/// What a reader is allowed to render.
///
/// Three cases rather than an optional, because "there is nothing" and "there is something and it
/// is not today's" are different things to a parent and are drawn differently.
nonisolated enum WidgetSnapshotState: Equatable, Sendable {
    /// The snapshot is for today, in the child's timezone. The only case carrying prompts.
    case current(WidgetSnapshot)

    /// There is a snapshot and it is not today's.
    ///
    /// **It deliberately carries the child's name and nothing else.** Yesterday's mission cannot
    /// be rendered from this case because it is not reachable from this case — the guarantee is
    /// structural rather than a rule a later view has to remember. Showing nothing is correct;
    /// showing the wrong day is a defect.
    case stale(childFirstName: String)

    /// Nothing readable: a fresh install, a signed-out phone, an unreadable or foreign-version
    /// file. Not an error, and never drawn as one.
    case absent
}

nonisolated extension WidgetSnapshotState {

    /// Decode and classify. Never throws and never traps: every failure is `.absent`.
    static func resolve(data: Data?, now: Date) -> WidgetSnapshotState {
        guard let data, !data.isEmpty else { return .absent }
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .absent
        }
        return resolve(snapshot, now: now)
    }

    static func resolve(_ snapshot: WidgetSnapshot, now: Date) -> WidgetSnapshotState {
        guard snapshot.version == WidgetSnapshot.currentVersion else { return .absent }

        // An identifier this device's ICU data has never heard of. The snapshot is readable and
        // current, so it is not absent — but its day cannot be checked, and an unverifiable day
        // is treated exactly like a wrong one.
        guard let zone = TimeZone(identifier: snapshot.familyTimezone) else {
            return .stale(childFirstName: snapshot.childFirstName)
        }

        guard WidgetSnapshot.day(for: now, in: zone) == snapshot.assignedOn else {
            return .stale(childFirstName: snapshot.childFirstName)
        }
        return .current(snapshot)
    }
}

nonisolated extension WidgetSnapshot {

    /// One of the two prompts, with the word for which slot it came from.
    nonisolated struct Featured: Equatable, Sendable {
        let label: String
        let item: Item
    }

    var missionFeatured: Featured? { mission.map { Featured(label: "Mission", item: $0) } }
    var questionFeatured: Featured? { question.map { Featured(label: "Question", item: $0) } }

    /// What the smallest families lead with: the first unfinished prompt, mission before
    /// question. Nil when both are finished or neither exists.
    ///
    /// Mission first because it is the one that usually needs the room — a mission asks for a
    /// photo or an afternoon, and a question can be answered in a sentence from the queue at the
    /// supermarket.
    var nextUp: Featured? {
        [missionFeatured, questionFeatured]
            .compactMap { $0 }
            .first { !$0.item.isDone }
    }

    /// Both of today's prompts exist and both are finished. Drawn warm and quiet — there is no
    /// celebration graphic anywhere in this product.
    var isComplete: Bool {
        let items = [mission, question].compactMap { $0 }
        return !items.isEmpty && items.allSatisfy(\.isDone)
    }

    /// Today produced neither a mission nor a question. Rare, and not an error: a dismissed pair
    /// looks exactly like this, and so does a day the scheduler had nothing active to serve.
    var isEmpty: Bool { mission == nil && question == nil }

    /// The calendar day `date` falls on in `zone`, as `YYYY-MM-DD`.
    ///
    /// **This is a freshness check, not scheduling, and the distinction is the whole point.** The
    /// server owns what was assigned, when it expires, and what day it is; a client that decides
    /// "it is a new day" has broken the archive. What this does is narrower and only ever
    /// subtracts: it asks whether the day the server already named is still the current one, and
    /// if the answer is no — or unobtainable — the widget renders *less*. It can never promote a
    /// prompt, extend one, or invent a day. Being wrong here shows a parent nothing; not doing it
    /// at all shows them yesterday's mission as though it were today's.
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` deliberately: an explicitly
    /// Gregorian calendar and a zero-padded format cannot be reshaped by the device's locale, and
    /// a phone set to a non-Gregorian calendar would otherwise fail the comparison every day.
    static func day(for date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// The next midnight in `zone`, which is the moment a fresh snapshot becomes a stale one and
    /// the only thing this widget can change about itself without the app.
    ///
    /// Static, and taking the zone rather than reading it off a snapshot, because the timeline
    /// needs this **whether or not the snapshot is current** — a stale widget that instead polls
    /// on a fixed interval spends a limited refresh budget re-learning that it is still stale.
    /// `WidgetSnapshotStore.refreshZone()` supplies the zone without handing back anything
    /// renderable.
    static func nextMidnight(after date: Date, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // `matchNextTime` rather than adding 86,400 seconds: a DST day is 23 or 25 hours long,
        // and twice a year the arithmetic version fires an hour early or an hour late.
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
