import Foundation

/// How the app says an age out loud.
///
/// Every number here comes from the server's `child_age_months`, computed from `occurred_at`
/// minus the birthdate and stored at write time. Nothing in this file calculates an age; it only
/// chooses words for one. A client that recomputes drifts the moment a rounding or timezone rule
/// differs, and in an archive that difference is permanent.
nonisolated enum AgeText {

    /// The greeting on the Today screen: "5 years old", "14 months old", "5y 2m".
    static func greeting(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if years == 0 { return "\(months) month\(months == 1 ? "" : "s") old" }
        if rest == 0 { return "\(years) year\(years == 1 ? "" : "s") old" }
        return "\(years)y \(rest)m"
    }

    /// The chip on a card — how old he was when this happened. Compact, because it sits beside
    /// the entry type and a tag or two: "5y 2m", "11 mo", "newborn".
    static func chip(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if months <= 0 { return "newborn" }
        if years == 0 { return "\(months) mo" }
        if rest == 0 { return "\(years)y" }
        return "\(years)y \(rest)m"
    }

    /// Spoken form, for VoiceOver, where "5y 2m" reads as noise.
    static func spoken(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if months <= 0 { return "Newborn" }
        if years == 0 { return "\(months) month\(months == 1 ? "" : "s") old" }
        let yearPart = "\(years) year\(years == 1 ? "" : "s")"
        if rest == 0 { return "\(yearPart) old" }
        return "\(yearPart) \(rest) month\(rest == 1 ? "" : "s") old"
    }
}

/// Durations, for a voice chip or a video badge. `1:04`, `12:30`.
nonisolated enum DurationText {
    static func clock(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return "\(safe / 60):" + String(format: "%02d", safe % 60)
    }

    static func spoken(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 60 { return "\(safe) second\(safe == 1 ? "" : "s")" }
        let minutes = safe / 60, rest = safe % 60
        let minutePart = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        return rest == 0 ? minutePart : "\(minutePart) \(rest) second\(rest == 1 ? "" : "s")"
    }
}

/// The date group header: **25** AUGUST 2026 · MON.
///
/// Split into its parts rather than one string, because the day number is set bold against a
/// lighter month — see `docs/design-system.md`, which asks for a small-caps label here and not
/// display type.
nonisolated enum DayHeaderText {
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day())
    }

    static func monthAndYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// One string, for VoiceOver and for the date line on Entry Detail.
    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
