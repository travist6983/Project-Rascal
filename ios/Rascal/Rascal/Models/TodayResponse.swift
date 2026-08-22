import Foundation

/// The wire shape of `GET /v1/children/{id}/today`, mirroring `ios/Fixtures/today.json`.
///
/// Deliberately separate from the SwiftData models. The API shape and the local cache shape
/// are different concerns and will drift; collapsing them into one type means every server
/// change becomes a migration.
nonisolated struct TodayResponse: Decodable {
    /// The child's local date, computed server-side in `family_timezone`. Never derived here.
    let date: String
    let child: ChildSummary
    let today: [AssignmentResponse]
    /// Pending assignments from previous days, oldest first.
    let waiting: [AssignmentResponse]
    /// Anything completed with `occurred_at` today.
    let doneToday: [AssignmentResponse]

    // MARK: Entitlement — added by phase 107, decoded defensively by phase 108

    /// What the **server** says this household may be served today.
    ///
    /// **Absent means `.notReported`, and `.notReported` is entitled.** A build running against an
    /// API that predates phase 107 must render exactly as it did before that phase existed: no
    /// locked cards, no empty state, no crash.
    let access: Access

    /// When the trial ends, if there is one. Nullable on the wire, and **read by nothing.**
    ///
    /// It is decoded so that the shape is honest and so a later phase does not have to re-open the
    /// decoder to get at it — but no view, no model and no rule in this app consults it. The copy
    /// rules forbid a trial countdown outright, and entitlement is `access`'s job. If something
    /// ever starts computing from this field, that is the moment the device began deciding
    /// entitlement, which is the exact thing D5 exists to prevent.
    let trialEndsAt: Date?

    /// The slots this household was **not** served today, in the order the server sent them.
    ///
    /// **Absent decodes to `[]`.** The server states it always sends an array, so this tolerance is
    /// for the older build against the older server rather than for a healthy one.
    ///
    /// Each element is `{slot, kind_hint}` and carries **no body, title, theme or id** — a locked
    /// slot is the *shape* of the thing, not a teaser for it.
    let locked: [LockedSlot]

    /// Spelled out because the memberwise initialiser is gone the moment `init(from:)` is written,
    /// and the previews and tests need one. Defaults keep every existing construction site valid.
    init(
        date: String,
        child: ChildSummary,
        today: [AssignmentResponse],
        waiting: [AssignmentResponse],
        doneToday: [AssignmentResponse],
        access: Access = .notReported,
        trialEndsAt: Date? = nil,
        locked: [LockedSlot] = []
    ) {
        self.date = date
        self.child = child
        self.today = today
        self.waiting = waiting
        self.doneToday = doneToday
        self.access = access
        self.trialEndsAt = trialEndsAt
        self.locked = locked
    }

    /// **Hand-written so that three fields can be absent without the whole board failing to
    /// decode.** `decodeIfPresent` on each, with the defaults above.
    ///
    /// The keys are camelCase because `APIClient.decoder` runs `.convertFromSnakeCase`, which
    /// rewrites the JSON's keys before they are matched against these — `trial_ends_at` arrives
    /// here as `trialEndsAt`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        child = try container.decode(ChildSummary.self, forKey: .child)
        today = try container.decode([AssignmentResponse].self, forKey: .today)
        waiting = try container.decode([AssignmentResponse].self, forKey: .waiting)
        doneToday = try container.decode([AssignmentResponse].self, forKey: .doneToday)
        access = try container.decodeIfPresent(Access.self, forKey: .access) ?? .notReported
        trialEndsAt = try container.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        locked = try container.decodeIfPresent([LockedSlot].self, forKey: .locked) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case date, child, today, waiting, doneToday, access, trialEndsAt, locked
    }
}

/// What the household may be served, **as decided by the server and by nothing else.**
///
/// D5: *"the device never decides whether a household is subscribed"* — the same rule as *"the
/// server owns the schedule"*. There is no case here that a receipt, a cached flag or a date
/// comparison can produce. The only writer is `GET /children/{id}/today`.
///
/// **Two absent-ish cases, deliberately distinct**, because they mean different things to the one
/// piece of logic that has to tell them apart — see `TodayModel.observe(_:)`. `.unrecognised` is a
/// value from a server newer than this build; `.notReported` is the field not being there at all.
nonisolated enum Access: Decodable, Equatable, Sendable {
    case subscribed
    case trial
    case free
    /// A value this build does not know. A future server release, never a crash.
    case unrecognised(String)
    /// The field was absent — an API predating phase 107. **Never produced by decoding a string.**
    case notReported

    init(rawValue: String) {
        switch rawValue {
        case "subscribed": self = .subscribed
        case "trial": self = .trial
        case "free": self = .free
        default: self = .unrecognised(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// **The load-bearing line of this phase.**
    ///
    /// Everything except an explicit `free` is entitled, and that asymmetry is the whole design:
    /// the failure direction has to be *"you can see everything"*, never *"here is a paywall"*. A
    /// parent in a tunnel, on an old build, or talking to a server that has learned a fourth word
    /// gets the full board.
    ///
    /// Inverting this — making the unknown cases lock — would compile, pass every test written
    /// against known values, and show a paywall to somebody who had paid.
    var isEntitled: Bool {
        switch self {
        case .subscribed, .trial, .unrecognised, .notReported: true
        case .free: false
        }
    }

    /// Whether the server actually told us. `.notReported` is not an observation and must never be
    /// recorded as one — see `MembershipPresentation.shouldShowPostTrialNotice`.
    var wasReported: Bool { self != .notReported }

    /// The wire value, when there was one, for persisting what this device last actually saw.
    ///
    /// **Nil for `.notReported` on purpose**, so that "the server did not say" cannot be written
    /// down as though it had. A stored `nil` and a stored `"free"` mean different things and the
    /// one-time notice depends on the difference.
    var reportedRawValue: String? {
        switch self {
        case .subscribed: "subscribed"
        case .trial: "trial"
        case .free: "free"
        case .unrecognised(let raw): raw
        case .notReported: nil
        }
    }
}

/// One slot the household was not served today.
///
/// **Two strings and nothing else, which is the API's deliberate design and is right.** Serving the
/// prompt body behind a lock would leak the library and burn its 180-day cooldown on a prompt
/// nobody can answer, so there is no headline here to render — the copy is keyed on `kindHint` and
/// names the *shape* of what is missing.
nonisolated struct LockedSlot: Decodable, Equatable, Sendable, Identifiable {
    /// `mission` · `mission_b` · `weekly` · `monthly` · `letter`. **`question` is never locked** —
    /// the daily question is the free tier.
    let slot: String
    /// `photo` · `mission` · `weekly` · `monthly` · `letter`.
    ///
    /// **Not a `PromptKind`.** Three of its values — `mission`, `weekly`, `monthly` — are not
    /// members of that enum, so reusing it here would send them all to `.unknown` and draw three
    /// different locked slots as the same grey card.
    let kindHint: String

    /// The slot names one row on one board on one day, so it identifies the card.
    var id: String { slot }

    /// **What the words are keyed on.** The copy file is organised by slot, and `mission` and
    /// `mission_b` need different sentences.
    ///
    /// `kind_hint` happens to be one-to-one with `slot` in the contract as it stands — `mission`
    /// hints `photo`, `mission_b` hints `mission` — so either would work today. Slot is used anyway
    /// because it is what the copy is written against, and because a later slot reusing an existing
    /// hint would silently give two rows the same sentence.
    var slotKind: Slot { Slot(rawValue: slot) }

    /// **What the colour and the glyph are keyed on**, which is what the hint is for.
    var kind: LockedKind { LockedKind(rawValue: kindHint) }
}

/// How a locked row presents itself.
///
/// Separate from `PromptKind` for the reason stated on `LockedSlot.kindHint`, and separate from
/// `Slot` because the server sends a *hint about what it would have been*, not the slot's own name.
nonisolated enum LockedKind: RawRepresentable, Equatable, Sendable {
    case photo, mission, weekly, monthly, letter
    /// A hint newer than this build. Renders as a neutral card — never a crash, never a blank, and
    /// never a guessed tint. The same contract every other constrained value here carries.
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "photo": self = .photo
        case "mission": self = .mission
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "letter": self = .letter
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .photo: "photo"
        case .mission: "mission"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .letter: "letter"
        case .other(let raw): raw
        }
    }

    /// Recognised hints get their kind's colour; an unrecognised one gets none. Same rule, and the
    /// same reasoning, as `AssignmentResponse.isRecognised`.
    var isRecognised: Bool {
        if case .other = self { return false }
        return true
    }

    /// The SF Symbol, drawn from the vocabulary `PromptCard`'s glyph tile already uses so that a
    /// locked photo mission and a live one are recognisably the same kind of thing.
    var symbolName: String {
        switch self {
        case .photo: "camera"
        // **`video`, not `figure.walk`, and the design settles it.** `mission_b` genuinely spans
        // voice, video and activity, so a walking figure is a defensible reading of the slot — but
        // the artboards draw a play triangle beside the camera, and distinguishing the two locked
        // missions *by glyph* is the job this tile is doing. The copy agrees on the ordering:
        // "{Their} voice, a video, or something to do together" puts activity last, and it was the
        // one the walking figure had picked.
        case .mission: "video"
        case .weekly, .monthly: "calendar"
        case .letter: "envelope"
        case .other: "sparkles"
        }
    }
}

nonisolated struct ChildSummary: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Computed and stored server-side from `occurred_at` minus birthdate. Displayed, never
    /// recalculated here — a client that recomputes it drifts the moment a rounding or
    /// timezone rule differs.
    let ageMonths: Int
}

nonisolated struct AssignmentResponse: Decodable, Identifiable, Equatable {
    let id: UUID
    let slot: String
    let body: String
    let kind: String
    let completionMode: String
    let theme: String?
    let status: AssignmentStatus
    let assignedOn: String
    let expiresOn: String?
    let promptId: UUID?
    let isCustom: Bool
    let unlockAtAge: Int?

    var slotKind: Slot { Slot(rawValue: slot) }
    var promptKind: PromptKind { PromptKind(rawValue: kind) }
    var completion: CompletionMode { CompletionMode(rawValue: completionMode) }
}

/// Server-constrained values arrive as `text` + CHECK rather than an enum, specifically so a
/// value can be added without a migration. Every one of these therefore carries an `unknown`
/// case: a future server release must render as a neutral card, never crash and never blank.
nonisolated enum AssignmentStatus: RawRepresentable, Decodable, Equatable, Sendable {
    case pending, done, dismissed, expired
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "done": self = .done
        case "dismissed": self = .dismissed
        case "expired": self = .expired
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .pending: "pending"
        case .done: "done"
        case .dismissed: "dismissed"
        case .expired: "expired"
        case .unknown(let raw): raw
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// `question` · `mission` · `mission_b` · `weekly` · `monthly` · `letter`. Letters land on the
/// 15th.
///
/// **Three daily slots, not two.** `mission` is the photo mission; `mission_b` is the second
/// daily one, drawing video, audio and activity. The server narrowed `mission` without renaming
/// it, so an older assignment can carry a non-photo prompt in `mission` and is not a bug — see
/// `docs/decisions.md`.
///
/// `mission_b` has to be a real case rather than falling through to `.unknown`. An unrecognised
/// slot deliberately renders as a neutral grey card with no tint, which is right for a value
/// from a future server release and wrong for one of the three cards a parent sees every day.
nonisolated enum Slot: RawRepresentable, Equatable, Sendable {
    case question, mission, missionB, weekly, monthly, letter
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "question": self = .question
        case "mission": self = .mission
        case "mission_b": self = .missionB
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "letter": self = .letter
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .question: "question"
        case .mission: "mission"
        case .missionB: "mission_b"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .letter: "letter"
        case .unknown(let raw): raw
        }
    }

    /// Both daily missions read "Mission". The parent is not told there is an A and a B — they
    /// are two things to do today, and numbering them would invite the idea that one is optional
    /// or that the pair is a checklist to clear.
    var displayName: String {
        switch self {
        case .question: "Question"
        case .mission, .missionB: "Mission"
        case .weekly: "This week"
        case .monthly: "This month"
        case .letter: "Letter"
        case .unknown(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Colour carries meaning. Questions are periwinkle; missions and the bigger slots are
    /// terracotta. An unrecognised slot gets no tint at all rather than a guessed one.
    var isQuestion: Bool { self == .question }
}

nonisolated enum PromptKind: RawRepresentable, Equatable, Sendable {
    case question, photo, video, audio, activity, letter
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "question": self = .question
        case "photo": self = .photo
        case "video": self = .video
        case "audio": self = .audio
        case "activity": self = .activity
        case "letter": self = .letter
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .question: "question"
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .activity: "activity"
        case .letter: "letter"
        case .unknown(let raw): raw
        }
    }

    /// The small caps badge on a PromptCard.
    var badgeText: String {
        switch self {
        case .question: "Question"
        case .photo: "Photo"
        case .video: "Video"
        case .audio: "Voice"
        case .activity: "Activity"
        case .letter: "Letter"
        case .unknown(let raw): raw.isEmpty ? "Prompt" : raw
        }
    }

    var symbol: String {
        switch self {
        case .question: "text.bubble"
        case .photo: "camera"
        case .video: "video"
        case .audio: "waveform"
        case .activity: "figure.walk"
        case .letter: "envelope"
        case .unknown: "sparkles"
        }
    }
}

/// The three completion shapes. Nothing may assume an entry has media — "get on the floor for
/// ten minutes" is a complete, legitimate entry with no artifact.
nonisolated enum CompletionMode: RawRepresentable, Equatable, Sendable {
    case didIt, media, text
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "did_it": self = .didIt
        case "media": self = .media
        case "text": self = .text
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .didIt: "did_it"
        case .media: "media"
        case .text: "text"
        case .unknown(let raw): raw
        }
    }

    /// The capsule button copy. Never an instruction the app can't honour.
    var actionText: String {
        switch self {
        case .didIt: "We did it"
        case .text: "Write it"
        case .media: "Capture it"
        case .unknown: "Open"
        }
    }
}
