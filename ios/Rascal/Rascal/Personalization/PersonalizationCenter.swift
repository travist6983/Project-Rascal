import Foundation
import OSLog
import SwiftUI

/// The one place a personalized prompt is asked for, cached, and handed out.
///
/// ## Never persisted, by construction rather than by care
///
/// **The cache is a dictionary in memory on a `@MainActor` class and nothing writes it anywhere.**
/// No `UserDefaults`, no SwiftData model, no file in the container, no App Group. That is the
/// enforcement: there is no code path from a personalized string to disk, so there is none to the
/// server either. It dies with the process, which is correct — it is derived data whose source of
/// truth is one `GET` away.
///
/// The widget follows from the same rule. `WidgetSnapshotBuilder` writes a **file** the extension
/// reads, so a personalized snapshot would be a personalized string on disk — the precise thing
/// rule one forbids. The Home Screen therefore shows canonical text, and it is not a compromise:
/// the extension has no model, cannot personalize what it reads, and a snapshot that disagreed
/// with Today would be worse than one that reads like the library.
///
/// ## Never blocks
///
/// `text(for:canonical:)` is **synchronous and always returns immediately** — the personalized
/// string if one is already cached, the canonical one otherwise. Nothing awaits a model to draw a
/// board. `request(...)` is the separate, fire-and-forget half, and a caller that never calls it
/// still renders a correct screen forever.
@MainActor
@Observable
final class PersonalizationCenter {

    private static let log = Logger(subsystem: "app.rascal", category: "personalization")

    /// **The canonical body is part of the key, not just the assignment id.** A prompt whose text
    /// the library changed is a different prompt, and reusing yesterday's personalization for it
    /// would render a sentence the server no longer serves. Hashing rather than storing the body
    /// keeps the key small; a collision renders canonical, which is the safe direction.
    private struct Key: Hashable {
        let assignmentId: UUID
        let canonicalHash: Int
    }

    private var cache: [Key: String] = [:]
    /// Assignments with a call already out. **This is what makes it once per assignment rather
    /// than once per render** — a SwiftUI body can run many times for one board.
    private var inFlight: Set<Key> = []

    /// Counted only, never the strings themselves. Reported in debug builds so the rejection rate
    /// against the real library is observable.
    private(set) var rejections: [PersonalizationGuard.Rejection: Int] = [:]
    private(set) var accepted = 0

    private let personalizer: any PromptPersonalizing
    /// Resolved once. The availability check is cheap but it is not free, and it cannot change
    /// while the app is running in any way that matters here.
    private var availability: PersonalizationAvailability?

    init(personalizer: any PromptPersonalizing = DevicePromptPersonalizer()) {
        self.personalizer = personalizer
    }

    // MARK: Reading — synchronous, always

    /// What to draw right now. Never nil, never a wait.
    func text(for assignmentId: UUID, canonical: String) -> String {
        cache[Key(assignmentId: assignmentId, canonicalHash: canonical.hashValue)] ?? canonical
    }

    /// Whether this assignment has already been personalized, for tests and for the debug board.
    func isPersonalized(_ assignmentId: UUID, canonical: String) -> Bool {
        cache[Key(assignmentId: assignmentId, canonicalHash: canonical.hashValue)] != nil
    }

    // MARK: Requesting — the other half, and it may take as long as it likes

    /// Personalize one assignment, once.
    ///
    /// Returns without doing anything when the model is unavailable, when this assignment is
    /// already cached, when a call is already out for it, or when there is no name to substitute —
    /// **each of which is an ordinary outcome and none of which is reported.**
    func request(
        assignmentId: UUID,
        canonical: String,
        subject: PromptSubject,
        ageMonths: Int?
    ) async {
        let key = Key(assignmentId: assignmentId, canonicalHash: canonical.hashValue)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        // Nothing to substitute. The model would return the canonical sentence and the guard
        // would reject it for exactly that, so the round trip is skipped rather than spent.
        guard !subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if availability == nil { availability = await personalizer.availability() }
        guard availability == .available else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let raw = try await personalizer.personalize(
                canonical, for: subject, ageMonths: ageMonths
            )
            let verdict = PersonalizationGuard.rejection(
                personalized: raw, canonical: canonical, subject: subject
            )
            if let verdict {
                rejections[verdict, default: 0] += 1
                #if DEBUG
                // The rejected string is never logged — it is model output about a real child and
                // this is the one place it would be easy to leave on disk in a device log.
                Self.log.debug("personalization rejected: \(verdict.rawValue, privacy: .public)")
                #endif
                return
            }
            accepted += 1
            cache[key] = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Model failure, timeout, cancellation. Canonical text is already on screen and stays
            // there. There is no error state for this feature.
            return
        }
    }

    /// What the debug board reports. **A high rejection rate is information**, not something to
    /// suppress — it says the instructions need work, or that this library resists substitution.
    var rejectionRate: Double {
        let rejected = rejections.values.reduce(0, +)
        let total = rejected + accepted
        return total == 0 ? 0 : Double(rejected) / Double(total)
    }

    /// Drop everything. The session ended, or the child changed.
    func clear() {
        cache.removeAll()
        inFlight.removeAll()
        rejections.removeAll()
        accepted = 0
    }
}

// MARK: - Reaching it from a view

/// Passed through the environment for the same reason `promptSubject` is, one file over: a
/// `PromptCard` on Today and the composer's quoted header are showing the same library and must
/// read it the same way.
///
/// **The default does nothing at all.** A view that never had one injected renders canonical text
/// forever, which is exactly the behaviour on a device with no model — so a missed injection is
/// invisible rather than a crash or an empty string.
private struct PersonalizationKey: EnvironmentKey {
    @MainActor static let defaultValue = PersonalizationCenter(personalizer: InertPersonalizer())
}

extension EnvironmentValues {
    var personalization: PersonalizationCenter {
        get { self[PersonalizationKey.self] }
        set { self[PersonalizationKey.self] = newValue }
    }
}

/// The do-nothing personalizer behind the environment default, and the one every preview and
/// most tests get for free. Reports unavailable, which is the honest answer for a view that was
/// never wired to a real one.
nonisolated struct InertPersonalizer: PromptPersonalizing {
    func availability() async -> PersonalizationAvailability { .unavailable }
    func personalize(
        _ canonical: String,
        for subject: PromptSubject,
        ageMonths: Int?
    ) async throws -> String {
        canonical
    }
}

/// The child's age in months, **as the server computed it**.
///
/// A separate environment value rather than a field on `PromptSubject`, which is a settled wire
/// contract shared with the widget, the composer and four cards — widening it for one consumer
/// would make every one of them carry a number they do not render.
///
/// Nil until `GET /children` answers, and nil is fine: the model is simply told nothing about age,
/// which is better than being told a number this device worked out for itself.
private struct ChildAgeMonthsKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var childAgeMonths: Int? {
        get { self[ChildAgeMonthsKey.self] }
        set { self[ChildAgeMonthsKey.self] = newValue }
    }
}
