import Foundation

/// The wall-clock time the daily notification is sent, e.g. 19:00.
///
/// **A wall-clock time, not an instant, and that distinction is the whole type.** The server
/// resolves it in the child's `family_timezone` — never the device's — so a parent in a
/// different zone from their kid still gets the notification at the kid's seven in the evening.
/// Carrying this as a `Date` would drag a timezone along with it and make the client the thing
/// that decided when "seven" was, which is exactly the rule the archive is built to prevent.
///
/// Wire form is `"HH:mm:ss"`, which is what Pydantic's `time` emits and accepts.
nonisolated struct NotifyTime: Codable, Equatable, Hashable, Sendable {
    let hour: Int
    let minute: Int

    /// The server's `DEFAULT_NOTIFY_LOCAL_TIME`. Matched so a client that has never written a
    /// preference shows the same time the server would send at.
    static let `default` = NotifyTime(hour: 19, minute: 0)

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Parses `"19:00"` and `"19:00:00"` alike. **Seconds are read and discarded** — the server
    /// says seconds are ignored, and keeping them would let a round trip through this type
    /// produce a value the server never stores.
    init?(wire: String) {
        let parts = wire.split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        self.hour = hour
        self.minute = minute
    }

    var wire: String {
        String(format: "%02d:%02d:00", hour, minute)
    }

    // MARK: Codable

    /// Coded as the wire string rather than as two keys, so this type can sit directly in a
    /// request body and in `UserResponse` without an adapter at either end.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = NotifyTime(wire: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a HH:mm[:ss] time: \(raw)")
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }

    // MARK: Display

    /// Rendered in the device's locale, because this string is read by the parent holding the
    /// phone. The *meaning* stays the child's timezone, and every surface that shows this says
    /// so in words beside it — a bare "7:00 PM" with no zone named is what makes a travelling
    /// parent think the feature broke.
    func formatted(locale: Locale = .current) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return wire }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
