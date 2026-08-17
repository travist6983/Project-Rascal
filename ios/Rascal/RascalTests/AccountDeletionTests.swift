import Foundation
import Testing

@testable import Rascal

/// Deleting the account, from the phone.
///
/// **The copy is the feature here.** This is the last thing somebody reads before a choice with
/// no undo, and the sentence differs depending on whether another parent shares the household —
/// telling a parent their child's archive is about to be deleted when it is not would be a
/// frightening lie, and the reverse would be a reassuring one.
@MainActor
@Suite("Deleting the account")
struct AccountDeletionTests {

    // MARK: The wire

    @Test("the scheduled deletion decodes, and the date comes from the server")
    func scheduledDeletionDecodes() throws {
        // The client never computes this from a policy it would then have to keep in step with.
        let json = """
        {"requested_at": "2026-08-17T23:00:00Z", "execute_after": "2026-08-24T23:00:00Z"}
        """
        let scheduled = try APIClient.decoder.decode(
            ScheduledDeletion.self, from: Data(json.utf8)
        )

        #expect(scheduled.executeAfter.timeIntervalSince(scheduled.requestedAt) == 7 * 86_400)
    }

    // MARK: The states

    @Test("a fresh model offers the request rather than a scheduled date")
    func startsIdle() {
        #expect(AccountDeletionModel(previewing: .idle).scheduledDate == nil)
    }

    @Test("a scheduled model carries the date the confirmation reads back")
    func scheduledCarriesTheDate() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let model = AccountDeletionModel(previewing: .scheduled(executeAfter: when))

        #expect(model.scheduledDate == when)
    }

    @Test("dismissing a failure returns to idle rather than sticking")
    func failureIsDismissable() {
        let model = AccountDeletionModel(previewing: .failed("No connection."))
        model.dismissFailure()

        #expect(model.state == .idle)
    }

    @Test("dismissing does nothing to a scheduled deletion")
    func dismissDoesNotUnschedule() {
        // A stray dismiss must not make a requested deletion look un-requested.
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let model = AccountDeletionModel(previewing: .scheduled(executeAfter: when))
        model.dismissFailure()

        #expect(model.scheduledDate == when)
    }

    // MARK: The copy, which is the feature
    //
    // These exist because a break-test found nothing could catch them being wrong: making the
    // sheet always claim the archive would be deleted compiled cleanly and passed every test.

    @Test("a sole parent is told the archive goes, because it does")
    func soleParentIsToldTheTruth() {
        let lines = DeleteAccountCopy.consequences(hasOtherGuardian: false).joined(separator: " ")

        #expect(lines.contains("are deleted"))
        #expect(lines.contains("cannot be undone"))
        #expect(DeleteAccountCopy.confirmation(hasOtherGuardian: false).contains("gone for good"))
    }

    @Test("a household of two is never told the archive will be deleted, because it will not")
    func theOtherParentsArchiveIsNotThreatened() {
        // **The frightening lie this guards against.** With a second parent the children and
        // everything written about them stay; telling somebody otherwise would be false in the
        // one sentence they will remember.
        let lines = DeleteAccountCopy.consequences(hasOtherGuardian: true).joined(separator: " ")

        #expect(lines.contains("stay with the other parent"))
        #expect(!lines.contains("are deleted"))
        #expect(!lines.contains("cannot be undone"))
        #expect(
            !DeleteAccountCopy.confirmation(hasOtherGuardian: true).contains("gone for good")
        )
    }

    @Test("both shapes say they are signed out, and that signing in undoes it")
    func bothShapesCarryTheTwoFactsThatAlwaysHold() {
        for hasOther in [true, false] {
            let lines = DeleteAccountCopy.consequences(hasOtherGuardian: hasOther)
                .joined(separator: " ")
            #expect(lines.contains("signed out"), "missing sign-out line, hasOther=\(hasOther)")
            #expect(lines.contains("cancels it"), "missing cancel line, hasOther=\(hasOther)")
        }
    }

    @Test("no copy on this screen scolds or hurries")
    func theToneRulesHold() {
        // docs/design-system.md: no urgency, no guilt, nothing counting down at somebody.
        for hasOther in [true, false] {
            let all = DeleteAccountCopy.consequences(hasOtherGuardian: hasOther)
                .joined(separator: " ")
                + DeleteAccountCopy.confirmation(hasOtherGuardian: hasOther)
            for forbidden in ["!", "warning", "permanently lost", "hurry", "act now"] {
                #expect(!all.lowercased().contains(forbidden), "found \(forbidden)")
            }
        }
    }

    // MARK: The date a parent reads

    @Test("the deletion date is spelled out rather than numeric")
    func theDateIsUnambiguous() {
        // "08/09" is two different days depending on where you are, and this is the one
        // sentence in the app that cannot afford that.
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let text = DayHeaderText.dayAndMonth(when)

        #expect(!text.isEmpty)
        #expect(!text.contains("/"))
    }
}
