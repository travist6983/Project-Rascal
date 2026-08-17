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

    /// The long form for a labelled row — "5 years, 2 months".
    ///
    /// No trailing "old", unlike `spoken`: this sits opposite the words *Age at the time*, and
    /// "Age at the time — 5 years 2 months old" says age twice.
    static func long(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if months <= 0 { return "Newborn" }
        if years == 0 { return "\(months) month\(months == 1 ? "" : "s")" }
        let yearPart = "\(years) year\(years == 1 ? "" : "s")"
        if rest == 0 { return yearPart }
        return "\(yearPart), \(rest) month\(rest == 1 ? "" : "s")"
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

/// Small counts, spelled out, for copy that is a sentence rather than a statistic.
nonisolated enum CountText {

    /// "Six", for Moments' closing line. A numeral there reads as a score, and this app keeps
    /// score of nothing.
    ///
    /// **Pinned to English on purpose.** The sentence it lands in is hard-coded English — the app
    /// is not localized — so following the device's locale would spell the numeral in one language
    /// inside a sentence written in another: "Seis years of 9 August."
    static func spelled(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        guard let words = formatter.string(from: NSNumber(value: value)) else { return "\(value)" }
        return words.prefix(1).uppercased() + words.dropFirst()
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

    /// "24 Aug 2026" — a specific day, spelled out.
    ///
    /// Used where a date is a **commitment** rather than a heading: the day an account will be
    /// deleted, read back to the person who asked for it. Numeric-only would be ambiguous
    /// across locales in exactly the sentence that can least afford it.
    static func dayAndMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
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

    /// Short enough for a navigation bar: "8 Aug 2026".
    static func compact(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "Monday 10 August 2026" — the date under an entry, day before month and no comma.
    ///
    /// **Separate from `full`, which stays as it was.** `full` is the spoken form the timeline
    /// and the card hand to VoiceOver, and reordering it there would restyle two accessibility
    /// labels on screens this pass is not touching. This one is the printed date on Entry
    /// Detail and nothing else reads it.
    ///
    /// **The parts are joined by hand rather than ordered by a locale.** Asking `Date.FormatStyle`
    /// for weekday-day-month-year gives whatever punctuation the locale wants — `en_US` returns
    /// "Monday, August 10, 2026" and even `en_GB` keeps the comma after the weekday. The names
    /// still come from the device's locale; only the order and the spacing are ours, which is
    /// what the surrounding hard-coded English sentences already assume.
    static func entryDate(_ date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let day = date.formatted(.dateTime.day())
        let month = date.formatted(.dateTime.month(.wide))
        let year = date.formatted(.dateTime.year())
        return "\(weekday) \(day) \(month) \(year)"
    }

    /// The same date carrying the time it happened: "Monday 10 August 2026, 10:04am".
    ///
    /// A clock time is formatted at the use site in the device's zone, per
    /// `docs/design-system.md`: `occurred_at` is a genuine instant and the phone in the parent's
    /// hand is the right frame for one. **The device's 12/24-hour setting is honoured too** — a
    /// phone set to a 24-hour clock gets "17:20" rather than the design's "5:20pm", because a
    /// hard 12-hour format would print a time in a shape its owner has explicitly turned off.
    static func entryDateAndTime(_ date: Date) -> String {
        "\(entryDate(date)), \(entryTime(date))"
    }

    /// "10:04am", or "10:04" on a phone set to a 24-hour clock.
    ///
    /// The meridiem is closed up and lowercased, because the design sets it as part of the
    /// number rather than as a shout after it.
    static func entryTime(_ date: Date) -> String {
        date
            .formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

/// A calendar day the server named — `YYYY-MM-DD`, computed in the child's `family_timezone`.
///
/// It is a **day, not an instant**, and this enum never lets it become one. Both readers below
/// build the day at noon UTC and then format it *back* in UTC, so the day number printed is
/// always the day the server said, on a phone set to Kiribati as much as on one set to Nome.
/// Formatting it in the device's zone is the bug this exists to prevent: noon UTC read at UTC+14
/// is the following morning, and Moments would head a section with tomorrow.
///
/// The client still does not decide what day it is. It only chooses words for the day the server
/// already decided.
nonisolated enum CalendarDay {

    private static let zone = TimeZone(identifier: "UTC") ?? .gmt

    static func parse(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)
    }

    /// "Sunday 9 August" — the day, with no year on it, because in Moments the year is the thing
    /// each section supplies and the subtitle would otherwise say it twice.
    static func weekdayDayMonth(_ iso: String) -> String? {
        parse(iso).map {
            $0.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide).day().month(.wide))
        }
    }

    /// "9 August". The same day, mid-sentence.
    static func dayMonth(_ iso: String) -> String? {
        parse(iso).map {
            $0.formatted(Date.FormatStyle(timeZone: zone).day().month(.wide))
        }
    }
}
