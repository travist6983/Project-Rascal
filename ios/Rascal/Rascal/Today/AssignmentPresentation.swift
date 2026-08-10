import SwiftUI

/// How an assignment presents itself on the Today board.
///
/// Lives in one place because three cards now render the same assignment — `PromptCard`,
/// `WaitingCard`, `DoneCard` — and a tint rule copied three times is a tint rule that drifts.
extension AssignmentResponse {

    /// An unrecognised slot or kind renders as a neutral surface card with its body intact: an
    /// unknown value from a future server release is never a crash, never a blank card, and never
    /// given a guessed tint either.
    var isRecognised: Bool {
        if case .unknown = slotKind { return false }
        if case .unknown = promptKind { return false }
        return true
    }

    /// Colour carries meaning. Periwinkle is questions and voice; terracotta is missions,
    /// photo/video, and the bigger slots. A question card tinted terracotta "because it's the
    /// brand colour" is a defect, not a style choice.
    var tint: Color {
        guard isRecognised else { return .inkMuted }
        return slotKind.isQuestion || promptKind == .question || promptKind == .audio
            ? .periwinkle
            : .terracotta
    }

    /// The tinted fill that pairs with `tint`.
    var softTint: Color {
        guard isRecognised else { return .surface }
        return tint == .periwinkle ? .periwinkleSoft : .terracottaSoft
    }

    /// A tinted card gets a tinted hairline — `docs/design-system.md`. `border` is tuned for cream
    /// and reads as grey dirt on a periwinkle fill. Terracotta keeps `border`, which is the pairing
    /// the palette actually names for it.
    var tintBorder: Color {
        guard isRecognised else { return .border }
        return tint == .periwinkle ? .periwinkleBorder : .border
    }

    /// The small tile that carries the kind's symbol, filled for a live card and washed for a
    /// compact row.
    var symbolName: String { promptKind.symbol }

    // MARK: Expiry

    /// Whole days from the child's today until this assignment expires, or nil if it never does.
    ///
    /// **Both ends of this measurement are the server's.** `expires_on` is computed in the child's
    /// `family_timezone`, and the day to count from is `TodayResponse.date` — not
    /// `Calendar.current`, which is the *device's* idea of today. A parent travelling, or simply
    /// living in a different zone from their child, was previously shown a day count that was off
    /// by one in whichever direction the phone happened to be. The client still does not decide
    /// what day it is; it only measures between two days the server named.
    func daysUntilExpiry(asOf today: String) -> Int? {
        guard let expiresOn,
              let expiry = CalendarDay.parse(expiresOn),
              let start = CalendarDay.parse(today)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.dateComponents([.day], from: start, to: expiry).day
    }

    /// "2 days left", and only within three days of expiry.
    ///
    /// Nothing counts down before that, nothing turns red at any point, and an expiry further out
    /// says nothing at all. An already-passed date says nothing either — the server decides what
    /// is expired, and a negative number here is a board mid-refresh, not a scolding.
    func expiryLabel(asOf today: String) -> String? {
        guard let days = daysUntilExpiry(asOf: today), (0...3).contains(days) else { return nil }
        switch days {
        case 0: return "Last day"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }
}

/// "2 days left" — the quiet expiry note.
///
/// `inkMuted` on a neutral chip. **Never red, never bold, never animated.** Expiry is stated
/// plainly and the app does not turn a slow week into an emergency.
struct ExpiryChip: View {
    let text: String

    var body: some View {
        Chip(text: text, foreground: .inkMuted, background: .chipPlain)
    }
}

#if DEBUG
#Preview("Expiry chip") {
    VStack(alignment: .leading, spacing: 10) {
        ExpiryChip(text: "Last day")
        ExpiryChip(text: "1 day left")
        ExpiryChip(text: "2 days left")
        ExpiryChip(text: "3 days left")
    }
    .padding()
    .background(Color.canvas)
}
#endif
