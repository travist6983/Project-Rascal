#if DEBUG
import SwiftUI

/// The required state matrix, one preview per row.
///
/// Kept in its own file so `TodayBoardView` stays readable, and written against `TodayPreview`
/// fixtures so every one of these opens without a server, a login, or a seeded database. A state
/// that can only be reached by flying somewhere with a bad signal is a state nobody ever checks.
enum TodayBoardPreviews {}

// 1 — both of today's items still pending.
#Preview("1 · Both pending") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.photo), TodayPreview.item(.question)]
    ))
}

// 2 — one finished, one still asking.
#Preview("2 · One done, one pending") {
    TodayBoardView(
        board: TodayPreview.board(
            today: [TodayPreview.item(.question)],
            done: [TodayPreview.item(.photo, done: true, progress: TodayPreview.finished)]
        ),
        completedAt: { _ in CalendarDay.parse("2026-08-11") }
    )
}

// 3 — everything done, nothing waiting.
#Preview("3 · All caught up") {
    TodayBoardView(
        board: TodayPreview.board(done: [
            TodayPreview.item(.photo, done: true, progress: TodayPreview.finished),
            TodayPreview.item(.audio, done: true),
            TodayPreview.item(.didIt, done: true),
        ]),
        completedAt: { _ in CalendarDay.parse("2026-08-11") }
    )
}

// 4 — a single carried-over item.
#Preview("4 · Waiting, one item") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.photo)],
        waiting: [TodayPreview.item(.question)]
    ))
}

// 5 — a long backlog. Scrolls, and stays quiet about it: no total, no "you are behind".
#Preview("5 · Waiting, nine items") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.photo)],
        waiting: TodayPreview.manyWaiting(9)
    ))
}

// 6 — inside the three-day window. Chip present, grey, unbolded, unanimated.
#Preview("6 · Expiring in three days") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.expiringSoon)],
        waiting: [TodayPreview.item(.expiringSoon)]
    ))
}

// 7 — expiring tomorrow, and deliberately indistinguishable from row 6 apart from the number.
// Nothing escalates. There is no red state to arrive at.
#Preview("7 · Expiring tomorrow / today") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.expiringTomorrow), TodayPreview.item(.expiringToday)]
    ))
}

// 8 — Saturday: the weekly slot sits alongside the daily items.
#Preview("8 · Saturday weekly") {
    TodayBoardView(board: TodayPreview.board(
        today: [
            TodayPreview.item(.weekly),
            TodayPreview.item(.photo),
            TodayPreview.item(.question),
        ]
    ))
}

// 9 — first of the month: the measurement slot.
#Preview("9 · Monthly measurement") {
    TodayBoardView(board: TodayPreview.board(
        today: [
            TodayPreview.item(.monthly),
            TodayPreview.item(.question),
        ]
    ))
}

// 10 — a brand-new account. Nothing assigned, nothing ever finished.
#Preview("10 · First run") {
    TodayBoardView(board: TodayPreview.board())
}

// 11 — no avatar. This is the only avatar treatment there is: `/today` returns name and age and
// no image, so the initial is the design, not a fallback.
#Preview("11 · No avatar") {
    TodayBoardView(
        board: TodayPreview.board(today: [TodayPreview.item(.photo)]),
        onSwitchChild: {}
    )
}

// 12 — a 26-character name beside a switcher chevron.
#Preview("12 · Long child name") {
    TodayBoardView(
        board: TodayPreview.board(
            today: [TodayPreview.item(.photo)],
            child: TodayPreview.longNameChild
        ),
        onSwitchChild: {}
    )
}

// 13 — a prompt body long enough to wrap well past four lines, on all three cards.
#Preview("13 · Long prompt body") {
    TodayBoardView(
        board: TodayPreview.board(
            today: [TodayPreview.item(.longBody)],
            waiting: [TodayPreview.item(.longBody)],
            done: [TodayPreview.item(.longBody, done: true)]
        ),
        completedAt: { _ in CalendarDay.parse("2026-08-11") }
    )
}

// 14 — offline over a cached board. The last-known Today renders in full; the failure is one
// quiet line, not an error screen. An entry saved locally is never presented as a loss.
#Preview("14 · Offline over a stale board") {
    TodayBoardView(
        board: TodayPreview.board(
            today: [TodayPreview.item(.photo)],
            waiting: [TodayPreview.item(.question)],
            done: [TodayPreview.item(.didIt, done: true)]
        ),
        notice: "Can't reach the server. Showing what's saved on this phone."
    )
}

// 15 — accessibility XXL. Nothing truncates that carries meaning, and no button clips.
#Preview("15 · Accessibility XXL") {
    TodayBoardView(board: TodayPreview.board(
        today: [TodayPreview.item(.photo), TodayPreview.item(.longBody)],
        waiting: [TodayPreview.item(.question)],
        done: [TodayPreview.item(.didIt, done: true)]
    ))
    .environment(\.dynamicTypeSize, .accessibility5)
}

// The skip toast, which is the reason the swipe is allowed to exist.
#Preview("Skip · toast and undo") {
    TodayBoardView(
        board: TodayPreview.board(
            today: [TodayPreview.item(.photo)],
            waiting: [TodayPreview.item(.audio), TodayPreview.item(.didIt)]
        ),
        pendingSkip: "Skipped “One photo of his hands doing something”"
    )
}
#endif
