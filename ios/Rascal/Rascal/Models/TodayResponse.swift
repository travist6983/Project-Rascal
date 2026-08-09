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

/// `question` · `mission` · `weekly` · `monthly` · `letter`. Letters land on the 15th.
nonisolated enum Slot: RawRepresentable, Equatable, Sendable {
    case question, mission, weekly, monthly, letter
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "question": self = .question
        case "mission": self = .mission
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
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .letter: "letter"
        case .unknown(let raw): raw
        }
    }

    var displayName: String {
        switch self {
        case .question: "Question"
        case .mission: "Mission"
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
