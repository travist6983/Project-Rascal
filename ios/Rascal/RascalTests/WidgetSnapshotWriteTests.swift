import Foundation
import Testing

@testable import Rascal

/// Building the snapshot from the board, writing it, and what must never end up inside it.
@MainActor
@Suite("Widget snapshot writing")
struct WidgetSnapshotWriteTests {

    // MARK: Fixtures

    private let today = "2026-08-10"

    private func assignment(
        id: UUID = UUID(),
        slot: String = "mission",
        kind: String = "photo",
        body: String = "Photograph the thing he carries everywhere right now.",
        status: AssignmentStatus = .pending,
        assignedOn: String? = nil
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: id, slot: slot, body: body, kind: kind, completionMode: "media",
            theme: nil, status: status, assignedOn: assignedOn ?? today, expiresOn: "2026-08-24",
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    private func response(
        today items: [AssignmentResponse] = [],
        waiting: [AssignmentResponse] = [],
        done: [AssignmentResponse] = [],
        name: String = "Sam Terry"
    ) -> TodayResponse {
        TodayResponse(
            date: today,
            child: ChildSummary(id: UUID(), name: name, ageMonths: 62),
            today: items, waiting: waiting, doneToday: done
        )
    }

    private func board(
        today items: [AssignmentResponse] = [],
        waiting: [AssignmentResponse] = [],
        done: [AssignmentResponse] = [],
        entries: [Entry] = [],
        media: [Media] = [],
        name: String = "Sam Terry"
    ) -> TodayBoard {
        TodayBoard.merge(
            response: response(today: items, waiting: waiting, done: done, name: name),
            entries: entries,
            media: media
        )
    }

    /// A store pointed at a throwaway directory. The real one needs an App Group entitlement,
    /// which the test runner does not have and must not be made to depend on.
    private func temporaryStore() -> WidgetSnapshotStore {
        let directory = URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)")
        return WidgetSnapshotStore(directory: directory)
    }

    /// Counts reload requests. A reference type with a lock rather than a captured `var`, because
    /// the publisher's reload closure is `@Sendable` and mutating a local from inside one is an
    /// error under the Swift 6 language mode.
    private final class ReloadSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func record() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: Selection

    @Test("today's mission and question become the two lines")
    func picksMissionAndQuestion() {
        let mission = assignment(slot: "mission", kind: "photo")
        let question = assignment(slot: "question", kind: "question", body: "What made him laugh?")

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission, question]),
            familyTimezone: "America/New_York"
        )

        #expect(snapshot.assignedOn == today)
        #expect(snapshot.familyTimezone == "America/New_York")
        #expect(snapshot.mission?.assignmentId == mission.id)
        #expect(snapshot.question?.assignmentId == question.id)
        #expect(snapshot.question?.body == "What made him laugh?")
    }

    @Test("only the first name travels")
    func firstNameOnly() {
        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(name: "Sam Terry"),
            familyTimezone: "UTC"
        )
        #expect(snapshot.childFirstName == "Sam")
    }

    @Test("a name with no surname, and no name at all, both survive")
    func nameEdges() {
        #expect(WidgetSnapshotBuilder.firstName(of: "Sam") == "Sam")
        #expect(WidgetSnapshotBuilder.firstName(of: "  Sam  Terry ") == "Sam")
        #expect(WidgetSnapshotBuilder.firstName(of: "") == "")
        #expect(WidgetSnapshotBuilder.firstName(of: "   ") == "")
    }

    /// **The backlog never reaches the Home Screen.** `waiting` holds previous days' prompts, and
    /// there is no count of them anywhere in this product — a number of outstanding items, parked
    /// where a parent cannot look away from it, is the guilt engine the tone rules exist to
    /// prevent.
    @Test("waiting items are not carried onto the widget")
    func waitingIsNotCarried() {
        let old = assignment(slot: "mission", assignedOn: "2026-08-04")
        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(waiting: [old]),
            familyTimezone: "UTC"
        )
        #expect(snapshot.mission == nil)
        #expect(snapshot.isEmpty)
    }

    /// **The assertion above passes for the wrong reason on its own**, and this is the one that
    /// pins the rule. A backlog item is dated a previous day, so the `assignedOn == board.date`
    /// filter excludes it whether or not `waiting` is consulted — the test would still pass if the
    /// builder read the backlog. Dating a waiting item *today* removes the date filter from the
    /// question and leaves only the rule: `waiting` is never read.
    @Test("a waiting item dated today is still not carried, so the rule is the exclusion")
    func waitingIsExcludedByRuleNotByDate() {
        let sameDay = assignment(slot: "mission", assignedOn: today)
        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(waiting: [sameDay]),
            familyTimezone: "UTC"
        )

        #expect(snapshot.mission == nil, "the backlog reached the widget")
        #expect(snapshot.isEmpty)

        // And the same assignment on today's board *is* carried, so the fixture is not simply
        // being rejected for some other reason.
        let onToday = WidgetSnapshotBuilder.snapshot(
            from: board(today: [sameDay]),
            familyTimezone: "UTC"
        )
        #expect(onToday.mission?.assignmentId == sameDay.id)
    }

    /// A prompt assigned on Tuesday and finished on Wednesday belongs to Tuesday. The server puts
    /// it in `done_today` because it was *completed* today, which is a different question.
    @Test("an older assignment completed today is not shown as today's")
    func doneTodayFromAnotherDayIsNotToday() {
        let old = assignment(slot: "mission", status: .done, assignedOn: "2026-08-08")
        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(done: [old]),
            familyTimezone: "UTC"
        )
        #expect(snapshot.mission == nil)
    }

    @Test("a dismissed or expired prompt is nothing to show rather than something to report")
    func dismissedAndExpiredAreOmitted() {
        for status in [AssignmentStatus.dismissed, .expired] {
            let snapshot = WidgetSnapshotBuilder.snapshot(
                from: board(today: [assignment(slot: "mission", status: status)]),
                familyTimezone: "UTC"
            )
            #expect(snapshot.mission == nil, "a \(status.rawValue) assignment reached the widget")
        }
    }

    // MARK: Completion

    /// The mechanism the whole feature rests on: `TodayBoard.merge` folds a local entry over the
    /// server's board, so a completion is true on the widget before the upload has landed.
    @Test("completing an assignment updates the snapshot and requests a widget reload")
    func completionUpdatesSnapshotAndReloads() throws {
        let mission = assignment(slot: "mission")
        let store = temporaryStore()

        let spy = ReloadSpy()
        let publisher = WidgetSnapshotPublisher(store: store, reload: { spy.record() })

        // Before: the server says pending and nothing local disagrees.
        let before = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission]),
            familyTimezone: "UTC"
        )
        publisher.publish(before)

        #expect(before.mission?.isDone == false)
        #expect(spy.count == 1)

        // After: an entry completes it, and has not synced.
        let entry = Entry(childId: UUID(), assignmentId: mission.id, occurredAt: Date())
        entry.sync = .pending
        let after = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission], entries: [entry]),
            familyTimezone: "UTC"
        )
        publisher.publish(after)

        #expect(after.mission?.isDone == true, "the widget must agree with the screen, not the network")
        #expect(spy.count == 2)

        // And the file on disk says so too. Decoded directly rather than through `resolve`,
        // because the fixture's day is a fixed date and would classify stale on every day except
        // one — what this assertion is about is the bytes, not the calendar.
        let data = try #require(store.readData(), "nothing was written to the store")
        let onDisk = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(onDisk.mission?.isDone == true)
    }

    /// The timeline needs a zone even when the snapshot it came from is stale, so that a stale
    /// widget wakes at midnight rather than polling. What it must *not* get back is anything it
    /// could render.
    @Test("the refresh zone is readable, and is the only thing that comes back")
    func refreshZoneIsAvailableWithoutTheSnapshot() {
        let store = temporaryStore()
        store.write(WidgetSnapshotBuilder.snapshot(
            from: board(today: [assignment(slot: "mission")]),
            familyTimezone: "Pacific/Auckland"
        ))

        #expect(store.refreshZone() == TimeZone(identifier: "Pacific/Auckland"))
    }

    @Test("no snapshot, an unreadable one, or a foreign version yields no refresh zone")
    func refreshZoneDegrades() {
        #expect(temporaryStore().refreshZone() == nil)
        #expect(WidgetSnapshotStore(directory: nil).refreshZone() == nil)

        let store = temporaryStore()
        store.write(WidgetSnapshot(
            version: WidgetSnapshot.currentVersion + 1,
            assignedOn: "2026-08-10", familyTimezone: "UTC",
            childFirstName: "Sam", mission: nil, question: nil
        ))
        #expect(store.refreshZone() == nil, "a version this build cannot read must not be trusted")
    }

    /// Today is destroyed and rebuilt on every tab switch, so `initial: true` re-publishes an
    /// identical snapshot each time the parent comes back from Timeline. Widget refresh budget is
    /// finite and out of the app's control; spending it on a redraw that cannot change a pixel is
    /// how there is none left when a completion needs one.
    @Test("republishing an unchanged snapshot neither writes nor asks for a redraw")
    func unchangedSnapshotIsNotRepublished() throws {
        let store = temporaryStore()
        let spy = ReloadSpy()
        let publisher = WidgetSnapshotPublisher(store: store, reload: { spy.record() })
        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(today: [assignment(slot: "mission")]),
            familyTimezone: "UTC"
        )

        publisher.publish(snapshot)
        #expect(spy.count == 1)

        let written = try #require(store.fileURL.map { try? Data(contentsOf: $0) })
        let firstWrite = try #require(store.fileURL?.path)
        let stamp = try FileManager.default.attributesOfItem(atPath: firstWrite)[.modificationDate] as? Date

        publisher.publish(snapshot)
        publisher.publish(snapshot)

        #expect(spy.count == 1, "an identical snapshot asked WidgetKit to redraw")
        #expect(store.readData() == written)
        let after = try FileManager.default.attributesOfItem(atPath: firstWrite)[.modificationDate] as? Date
        #expect(after == stamp, "an identical snapshot rewrote the file")
    }

    @Test("a real change is still published after an unchanged one")
    func changeAfterNoChangeStillPublishes() {
        let mission = assignment(slot: "mission")
        let store = temporaryStore()
        let spy = ReloadSpy()
        let publisher = WidgetSnapshotPublisher(store: store, reload: { spy.record() })

        let pending = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission]), familyTimezone: "UTC"
        )
        publisher.publish(pending)
        publisher.publish(pending)
        #expect(spy.count == 1)

        let entry = Entry(childId: UUID(), assignmentId: mission.id, occurredAt: Date())
        let done = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission], entries: [entry]), familyTimezone: "UTC"
        )
        publisher.publish(done)

        #expect(spy.count == 2, "a completion must still reach the widget")
    }

    @Test("clearing an already-cleared snapshot does not ask for a redraw")
    func clearingTwiceIsQuiet() {
        let store = temporaryStore()
        let spy = ReloadSpy()
        let publisher = WidgetSnapshotPublisher(store: store, reload: { spy.record() })

        publisher.publish(nil)
        #expect(spy.count == 0, "there was nothing there to clear")

        publisher.publish(WidgetSnapshotBuilder.snapshot(from: board(), familyTimezone: "UTC"))
        publisher.publish(nil)
        publisher.publish(nil)
        #expect(spy.count == 2, "sign-out must clear exactly once, and not repeat")
    }

    @Test("a reload is requested even when the write cannot happen")
    func reloadHappensWithoutAContainer() {
        let spy = ReloadSpy()
        // No container: what a build with entitlements stripped looks like.
        let publisher = WidgetSnapshotPublisher(
            store: WidgetSnapshotStore(directory: nil),
            reload: { spy.record() }
        )

        publisher.publish(WidgetSnapshotBuilder.snapshot(from: board(), familyTimezone: "UTC"))

        // Asking for a redraw lets the widget re-run its own staleness check and fall back to the
        // neutral state. Staying quiet would leave the previous day on the glass.
        #expect(spy.count == 1)
    }

    @Test("publishing nothing clears the file")
    func publishingNilClears() {
        let store = temporaryStore()
        let publisher = WidgetSnapshotPublisher(store: store, reload: {})

        publisher.publish(WidgetSnapshotBuilder.snapshot(from: board(), familyTimezone: "UTC"))
        #expect(store.readData() != nil)

        publisher.publish(nil)
        #expect(store.readData() == nil)
        #expect(store.state(now: .now) == .absent)
    }

    @Test("clearing a snapshot that was never written is not a failure")
    func clearingNothingSucceeds() {
        #expect(temporaryStore().clear() == true)
    }

    @Test("a store with no container degrades to doing nothing")
    func noContainerIsSilent() {
        let store = WidgetSnapshotStore(directory: nil)
        #expect(store.fileURL == nil)
        #expect(store.readData() == nil)
        #expect(store.write(WidgetSnapshot(
            assignedOn: "2026-08-10", familyTimezone: "UTC",
            childFirstName: "Sam", mission: nil, question: nil
        )) == false)
        #expect(store.state(now: .now) == .absent)
    }

    // MARK: What must never be in it

    /// **The privacy assertion, against a fixture that includes a sealed letter.**
    ///
    /// A sealed entry is the sharpest case: it is written to be unreadable until the child is old
    /// enough, and the one surface in this product that other people can read over a shoulder is
    /// a Lock Screen. Nothing a parent wrote may reach it — not a body, not a title, not an entry
    /// or media id, and least of all a letter that is under seal inside the app itself.
    ///
    /// Asserted against the encoded bytes rather than the fields, because the bytes are what
    /// leaves the app.
    @Test("no entry content, no media, and nothing sealed reaches the snapshot")
    func snapshotCarriesNoEntryContent() throws {
        let secret = "He fell asleep on my chest and I did not want to move for an hour."
        let sealedSecret = "If you are reading this you are sixteen and I am so proud of you."

        let mission = assignment(slot: "mission")
        let letter = assignment(slot: "question", kind: "letter", body: "Write him a letter.")

        let entry = Entry(
            childId: UUID(),
            assignmentId: mission.id,
            occurredAt: Date(),
            title: "The nap",
            body: secret
        )
        // A sealed letter: `unlock_at_age` set is what makes it sealed.
        let sealed = Entry(
            childId: UUID(),
            assignmentId: letter.id,
            occurredAt: Date(),
            title: "For sixteen",
            body: sealedSecret,
            unlockAtAge: 16
        )
        let photo = Media(
            id: UUID(),
            entryId: entry.id,
            kind: "photo",
            contentType: "image/jpeg",
            byteCount: 2_400_000,
            stagedExtension: "jpg"
        )

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(today: [mission, letter], entries: [entry, sealed], media: [photo]),
            familyTimezone: "America/New_York"
        )

        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(!json.contains(secret))
        #expect(!json.contains(sealedSecret))
        #expect(!json.contains("The nap"))
        #expect(!json.contains("For sixteen"))
        #expect(!json.contains(entry.id.uuidString.lowercased()))
        #expect(!json.contains(sealed.id.uuidString.lowercased()))
        #expect(!json.contains(photo.id.uuidString.lowercased()))
        #expect(!json.lowercased().contains("unlockatage"))

        // What it *does* carry: the prompts, which are the archive's own questions.
        #expect(json.contains("Photograph the thing he carries everywhere right now."))
        #expect(snapshot.mission?.isDone == true)
        #expect(snapshot.question?.isDone == true)
    }

    @Test("the sealed letter's completion is a boolean and nothing more")
    func sealedCompletionIsJustAFlag() {
        let letter = assignment(slot: "mission", kind: "letter", body: "Write him a letter.")
        let sealed = Entry(
            childId: UUID(), assignmentId: letter.id, occurredAt: Date(),
            title: "For sixteen", body: "Private.", unlockAtAge: 16
        )

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board(today: [letter], entries: [sealed]),
            familyTimezone: "UTC"
        )

        let item = snapshot.mission
        #expect(item?.isDone == true)
        #expect(item?.body == "Write him a letter.", "the prompt, not the letter")
    }
}
