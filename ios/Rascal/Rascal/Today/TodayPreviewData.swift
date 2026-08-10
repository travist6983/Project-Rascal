#if DEBUG
import Foundation

/// Fixtures for the preview canvas, and for nothing else.
///
/// `#if DEBUG` on purpose: this is sample content, and sample content that can reach a release
/// build is one careless reference away from being shown to a parent as if it were their child's.
///
/// The dates are literals rather than anything derived from `Date()`. A preview whose expiry chip
/// changes depending on the day you open it is a preview that cannot be reviewed.
enum TodayPreview {

    /// The child's today, as the server would have computed it in `family_timezone`.
    static let today = "2026-08-11"

    static let child = ChildSummary(
        id: id("child"),
        name: "Hendrix",
        ageMonths: 62
    )

    static let longNameChild = ChildSummary(
        id: id("child-long"),
        name: "Wilhelmina Constanza Ortiz",
        ageMonths: 17
    )

    enum Sample: String {
        case photo, video, question, audio, didIt, letter
        case weekly, monthly
        case unknownKind
        case longBody
        case expiringToday, expiringTomorrow, expiringSoon
    }

    static func assignment(_ sample: Sample) -> AssignmentResponse {
        switch sample {
        case .photo:
            make(sample, slot: "mission", kind: "photo", mode: "media",
                 body: "Take a photo of what summer looks like for him this year.")
        case .video:
            make(sample, slot: "mission", kind: "video", mode: "media",
                 body: "Ask him what he'd say at eighteen.")
        case .question:
            make(sample, slot: "question", kind: "question", mode: "text",
                 body: "What did he say this week that you want to remember exactly?")
        case .audio:
            make(sample, slot: "mission", kind: "audio", mode: "media",
                 body: "Record him telling you a story. Don't correct the words he says wrong.")
        case .didIt:
            make(sample, slot: "mission", kind: "activity", mode: "did_it",
                 body: "Get on the floor for ten minutes. That's the whole mission.")
        case .letter:
            make(sample, slot: "letter", kind: "letter", mode: "text",
                 body: "Write him something about money you wish someone had told you at nineteen.")
        case .weekly:
            make(sample, slot: "weekly", kind: "activity", mode: "did_it",
                 body: "Take him somewhere he picks. Where you go, what you eat, all of it.",
                 expiresOn: "2026-08-16")
        case .monthly:
            make(sample, slot: "monthly", kind: "photo", mode: "media",
                 body: "Stand him against the door frame and mark it. Photograph the mark.",
                 expiresOn: "2026-09-01")
        case .unknownKind:
            // A value from a future server release. Renders neutral, never blank, never a crash.
            make(sample, slot: "seasonal", kind: "hologram", mode: "capture",
                 body: "Something this build has never heard of, rendered without a guessed tint.")
        case .longBody:
            make(sample, slot: "mission", kind: "photo", mode: "media",
                 body: """
                 Photograph the corner of the room where he keeps the things he has decided are \
                 his, exactly as he has arranged them, before anyone tidies it and before he \
                 changes his mind about which things belong there and which ones do not.
                 """)
        case .expiringToday:
            make(sample, slot: "mission", kind: "photo", mode: "media",
                 body: "Photograph the mess he made. Don't clean it up first.",
                 expiresOn: today)
        case .expiringTomorrow:
            make(sample, slot: "question", kind: "question", mode: "text",
                 body: "What is he frightened of this month?",
                 expiresOn: "2026-08-12")
        case .expiringSoon:
            make(sample, slot: "mission", kind: "audio", mode: "media",
                 body: "Record the song he has been singing wrong all week.",
                 expiresOn: "2026-08-13")
        }
    }

    static func item(
        _ sample: Sample,
        done: Bool = false,
        progress: TodayBoard.MediaProgress? = nil
    ) -> TodayBoard.BoardItem {
        TodayBoard.BoardItem(
            assignment: assignment(sample),
            localEntryId: done ? id("entry-" + sample.rawValue) : nil,
            mediaProgress: progress
        )
    }

    /// A done item the server acknowledged, with no local entry behind it — the shape a card takes
    /// when the other parent completed it, or when it was completed before this install.
    static func serverDone(_ sample: Sample) -> TodayBoard.BoardItem {
        var response = assignment(sample)
        response = AssignmentResponse(
            id: response.id, slot: response.slot, body: response.body, kind: response.kind,
            completionMode: response.completionMode, theme: response.theme, status: .done,
            assignedOn: response.assignedOn, expiresOn: response.expiresOn,
            promptId: response.promptId, isCustom: response.isCustom,
            unlockAtAge: response.unlockAtAge
        )
        return TodayBoard.BoardItem(assignment: response, localEntryId: nil, mediaProgress: nil)
    }

    static func board(
        today todayItems: [TodayBoard.BoardItem] = [],
        waiting: [TodayBoard.BoardItem] = [],
        done: [TodayBoard.BoardItem] = [],
        child: ChildSummary = TodayPreview.child
    ) -> TodayBoard {
        TodayBoard(
            date: today,
            child: child,
            today: todayItems,
            waiting: waiting,
            doneToday: done
        )
    }

    /// Eight-plus waiting items, for the scroll case. Each gets its own id so `ForEach` is stable.
    static func manyWaiting(_ count: Int = 9) -> [TodayBoard.BoardItem] {
        let rotation: [Sample] = [.question, .photo, .audio, .didIt, .video]
        return (0..<count).map { index in
            let sample = rotation[index % rotation.count]
            var assignment = self.assignment(sample)
            assignment = AssignmentResponse(
                id: id("waiting-\(index)"), slot: assignment.slot, body: assignment.body,
                kind: assignment.kind, completionMode: assignment.completionMode,
                theme: assignment.theme, status: .pending,
                assignedOn: assignedDaysAgo(index + 1), expiresOn: assignment.expiresOn,
                promptId: assignment.promptId, isCustom: false, unlockAtAge: nil
            )
            return TodayBoard.BoardItem(assignment: assignment, localEntryId: nil, mediaProgress: nil)
        }
    }

    static let uploading = TodayBoard.MediaProgress(total: 3, complete: 1, failed: 0, fraction: 0.42)
    static let finished = TodayBoard.MediaProgress(total: 3, complete: 3, failed: 0, fraction: 1)

    // MARK: Building blocks

    private static func make(
        _ sample: Sample,
        slot: String,
        kind: String,
        mode: String,
        body: String,
        assignedOn: String = TodayPreview.today,
        expiresOn: String? = "2026-08-25"
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: id(sample.rawValue),
            slot: slot,
            body: body,
            kind: kind,
            completionMode: mode,
            theme: nil,
            status: .pending,
            assignedOn: assignedOn,
            expiresOn: expiresOn,
            promptId: nil,
            isCustom: false,
            unlockAtAge: nil
        )
    }

    /// A stable UUID per name, so a preview does not reshuffle every time it redraws.
    ///
    /// Every byte of the seed feeds the digest. Taking the first sixteen would have been enough for
    /// most of these names and wrong for two of them: `entry-expiringToday` and
    /// `entry-expiringTomorrow` share a sixteen-byte prefix, so they would have collided into one
    /// id — and two rows with the same id in a `ForEach` is a preview that silently drops a card.
    private static func id(_ seed: String) -> UUID {
        var hash = UInt64(0xcbf2_9ce4_8422_2325)
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        var second = hash ^ 0x9E37_79B9_7F4A_7C15
        second = (second ^ (second >> 30)) &* 0xBF58_476D_1CE4_E5B9

        func byte(_ value: UInt64, _ index: Int) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> (UInt64(index) * 8))
        }
        return UUID(uuid: (
            byte(hash, 0), byte(hash, 1), byte(hash, 2), byte(hash, 3),
            byte(hash, 4), byte(hash, 5), byte(hash, 6), byte(hash, 7),
            byte(second, 0), byte(second, 1), byte(second, 2), byte(second, 3),
            byte(second, 4), byte(second, 5), byte(second, 6), byte(second, 7)
        ))
    }

    private static func assignedDaysAgo(_ days: Int) -> String {
        guard let day = CalendarDay.parse(today) else { return today }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = isoZone
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: day) else { return today }
        return isoDay.string(from: shifted)
    }

    private static let isoZone = TimeZone(identifier: "UTC") ?? .gmt

    /// `yyyy-MM-dd` in UTC — the wire shape, not a display format. `Date.FormatStyle` would order
    /// the components by locale and hand back `08/10/2026` on an `en_US` phone.
    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = isoZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
#endif
