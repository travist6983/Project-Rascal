import Foundation

/// Every sentence the share sheet says.
///
/// **Here rather than inside the extension's views so the suite can read it.** The extension is
/// its own module and the test target hosts the app, so a string built inside `ShareComposer` can
/// only ever be checked by looking at a screenshot. What this screen says about a date is the most
/// consequential copy in the phase — it is the only warning a parent gets before a 2019 photo is
/// filed under this week — and "verified by looking at it" is not good enough for that.
///
/// Takes counts and kinds rather than the extension's view models, so it depends on nothing above
/// it.
nonisolated enum ShareCopy {

    /// The composer's `DatePill` label.
    ///
    /// `DatePill` itself lives in `ComposerView.swift` and cannot be reached from the extension —
    /// compiling the composer into a share extension would drag SwiftData, the API client and the
    /// seal control in with it. So the *vocabulary* is shared and the control is not: the same
    /// "Today"-or-the-full-date wording, in the same surface-on-cream capsule.
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? "Today"
            : date.formatted(.dateTime.day().month(.wide).year())
    }

    /// The heading above the preview tiles: "1 photo", "3 photos", "2 photos and 1 video".
    ///
    /// Spelled out rather than "3 items", because the archive is made of photographs and films of
    /// a child, and those are the words a parent uses for them.
    static func heading(photos: Int, videos: Int) -> String {
        func phrase(_ count: Int, _ singular: String) -> String? {
            switch count {
            case 0: nil
            case 1: "1 \(singular)"
            default: "\(count) \(singular)s"
            }
        }
        let parts = [phrase(photos, "photo"), phrase(videos, "video")].compactMap { $0 }
        return parts.isEmpty ? "Nothing to save" : parts.joined(separator: " and ")
    }

    /// What VoiceOver reads for one preview tile.
    ///
    /// A thumbnail says nothing to a screen reader, so the position and the count have to carry
    /// what a sighted parent gets from the row itself: how many things are about to be filed, and
    /// which one this is.
    static func mediaLabel(
        kind: ShareMediaKind,
        position: Int,
        of total: Int,
        durationSeconds: Int?
    ) -> String {
        let noun = kind == .video ? "Video" : "Photo"
        let duration = durationSeconds.map { ", \(DurationText.spoken($0))" } ?? ""
        return total <= 1 ? "\(noun)\(duration)" : "\(noun) \(position) of \(total)\(duration)"
    }

    /// Why the date says what it says.
    ///
    /// **The fallback case is the one this exists for.** A parent reading "Today" under a photo of
    /// a two-year-old should be told that today is standing in, not left to assume the app knows
    /// something it does not — and told where to fix it, because this screen deliberately does not
    /// offer a picker.
    static func dateExplanation(source: PendingShare.DateSource, kinds: [ShareMediaKind]) -> String {
        let plural = kinds.count > 1
        let allVideo = !kinds.isEmpty && kinds.allSatisfy { $0 == .video }
        let noun = allVideo ? (plural ? "videos" : "video") : (plural ? "files" : "photo")

        switch source {
        case .captureMetadata:
            return plural ? "The earliest date on these \(noun)." : "Read from the \(noun)."
        case .shareTime:
            // The number has to carry all the way through the sentence. The first version of this
            // built a plural subject and then finished with a singular "when it was taken" —
            // "These files don't say when it was taken" — which the tests passed over because they
            // asserted a prefix and a substring rather than the sentence. A screenshot caught it.
            let subject = plural
                ? "These \(noun) don't say when they were taken"
                : "This \(noun) doesn't say when it was taken"
            return "\(subject), so today is standing in. You can change it in Dogear."
        }
    }

    /// The hint under the primary action, which is where the one-entry-per-share rule gets said
    /// out loud. A parent sharing five photos should know they are making one entry, not five.
    static func saveHint(mediaCount: Int) -> String {
        mediaCount == 1
            ? "Files one entry"
            : "Files one entry holding all \(mediaCount)"
    }

    /// Nothing in the share is something this app can hold.
    static let unusableKind = "Dogear can only take photos and videos."
    /// The container is unreachable, or the record could not be written. Never phrased as though
    /// it saved.
    static let unusableContainer = "This can't be saved right now. Open Dogear and add it from there."
}
