import Foundation
import SwiftData

/// Editing the child: name, birthdate, and the timezone the scheduler runs in.
///
/// **Nothing here recomputes a stored age.** `entries.child_age_months` is computed at write and
/// kept, which is what stops a birthdate typo silently reshaping five hundred entries — see
/// `docs/decisions.md`. That makes the typo otherwise permanent, so the correction exists as its
/// own explicit action and it is the parent's to pull. A save that quietly rewrote the archive
/// as a side effect would be the exact failure the storage decision was made to prevent.
@MainActor
@Observable
final class EditChildModel {

    /// `yyyy-MM-dd` ↔ `Date`, **in the device's own calendar**.
    ///
    /// A birthdate is a calendar day and the wire format carries no zone, so the only thing that
    /// matters is that parsing and formatting agree. They must use the *local* calendar, because
    /// the third participant does: `DatePicker` has no timezone of its own and always renders in
    /// `Calendar.current`. Parsing in UTC and handing the result to the picker put midnight UTC
    /// into a UTC−4 calendar and drew the day before — a birthday of 2021-06-01 rendered as
    /// 5/31/21, which a screenshot caught and no round-trip test would have.
    ///
    /// Same zone on both sides means the round trip is the identity in every timezone, which is
    /// the property `birthdateRoundTripIsStable` pins.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var name: String
    var birthdate: Date
    var timezone: String

    private(set) var isSaving = false
    /// The server's own words when a write is refused. Nil until something is refused.
    private(set) var notice: String?

    private let childId: UUID
    private let api: APIClient
    private let original: (name: String, birthdate: String, timezone: String)

    init(child: ChildResponse, api: APIClient) {
        self.childId = child.id
        self.api = api
        self.name = child.name
        self.timezone = child.familyTimezone
        self.birthdate = Self.dayFormatter.date(from: child.birthdate) ?? Date()
        self.original = (child.name, child.birthdate, child.familyTimezone)
    }

    var birthdateString: String { Self.dayFormatter.string(from: birthdate) }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something actually differs from what the server last told us.
    var hasChanges: Bool {
        trimmedName != original.name
            || birthdateString != original.birthdate
            || timezone != original.timezone
    }

    /// A name is required — the server enforces `min_length=1` and a blank one is not a name.
    var isValid: Bool { !trimmedName.isEmpty }

    /// Disabled while unchanged and while a write is in flight, so a double tap cannot send the
    /// same edit twice.
    var canSave: Bool { hasChanges && isValid && !isSaving }

    /// True when the birthdate specifically moved, which is what the "ages are not recomputed"
    /// line on the sheet is conditioned on. Saying it when only the name changed would be noise.
    var birthdateChanged: Bool { birthdateString != original.birthdate }

    // MARK: Saving

    /// Returns the updated child on success, nil on failure — the sheet stays open on nil, with
    /// the parent's input untouched.
    func save(into context: ModelContext? = nil) async -> ChildUpdateResponse? {
        guard canSave else { return nil }
        isSaving = true
        notice = nil
        defer { isSaving = false }

        do {
            return try await api.updateChild(
                id: childId,
                name: trimmedName,
                birthdate: birthdateString,
                familyTimezone: timezone
            )
        } catch let error as APIError {
            // Switched on `code`, never on message text — messages are copy and will change.
            notice = Self.explain(error)
            return nil
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    private static func explain(_ error: APIError) -> String {
        switch error.code {
        case .notAuthorized:
            "Only a parent can change these."
        case .notFound:
            "That archive is no longer here."
        case .validationFailed:
            // The server names the field and says what is wrong with it, and it says it better
            // than a generic string would.
            error.userMessage
        default:
            error.userMessage
        }
    }
}

/// The IANA zones a parent can pick from, and the search over them.
///
/// The list is `TimeZone.knownTimeZoneIdentifiers` rather than a curated one: the server accepts
/// any zone `zoneinfo` knows, and shipping a shortlist would mean someone in a zone I did not
/// think of cannot set it at all.
nonisolated enum TimeZoneCatalog {

    static var all: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }

    /// The device's own zone, which is the right default for a parent setting this up — and is
    /// only a default. The value that matters is where the *child* lives, which is why the sheet
    /// says what the setting does rather than assuming the two are the same.
    static var deviceZone: String { TimeZone.current.identifier }

    /// Matches on the whole identifier and on the city half, so "detroit" finds
    /// `America/Detroit` and "america" finds all of them.
    static func matching(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter { identifier in
            identifier.lowercased().contains(trimmed)
                || identifier.split(separator: "/").last?.lowercased()
                    .replacingOccurrences(of: "_", with: " ").contains(trimmed) == true
        }
    }

    /// `America/Detroit` reads as "Detroit" in a list where every row is a zone.
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    static func region(_ identifier: String) -> String? {
        let parts = identifier.split(separator: "/")
        return parts.count > 1 ? String(parts[0]).replacingOccurrences(of: "_", with: " ") : nil
    }

    /// "GMT−4" beside the name, so a parent can tell two similarly-named zones apart.
    static func offsetLabel(_ identifier: String, now: Date = Date()) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let seconds = zone.secondsFromGMT(for: now)
        if seconds == 0 { return "GMT" }
        let hours = abs(seconds) / 3_600
        let minutes = (abs(seconds) % 3_600) / 60
        let sign = seconds < 0 ? "−" : "+"
        return minutes == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}
