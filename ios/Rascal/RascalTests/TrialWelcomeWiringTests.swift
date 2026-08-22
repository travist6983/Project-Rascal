import Foundation
import Testing

@testable import Rascal

/// Phase 110 — which `OnboardingGate` paths arm the two-weeks welcome.
///
/// **This exists because the fix for the worst defect of phase 108 was pinned by nothing.**
///
/// The original bug: `shouldShowTrialWelcome` was `!record.trialWelcomeShown` and nothing else, run
/// from a `.task` that fires on every launch, against a flag new in this build. So the first launch
/// after updating told **every existing install** — including subscribed households and invited
/// second guardians — *"Two weeks, everything open. No card, nothing to cancel."* A false statement
/// about money, made to people already paying.
///
/// It was fixed correctly, by arming the welcome only where a credential is actually exchanged. But
/// **re-introducing the exact bug — putting `oweTrialWelcome()` back into `resume()` — passed all
/// 1125 tests.** Verified by doing it. `MembershipTests` covers the record-level semantics
/// thoroughly (`owingWelcome`, `decliningWelcome`, `shouldShowTrialWelcome`) and those are right;
/// what nothing covered is **the wiring** — which method calls which. That is the whole of the
/// defect, and it is a one-line edit away from returning.
///
/// **These are source assertions, and that is a deliberate second choice.** The behavioural test
/// would drive `OnboardingGate.resume()` against a stubbed API and assert the record afterwards;
/// that is the better test and it belongs in `MembershipTests` beside the rest of the trial work,
/// which is phase 108's file. Written here rather than reaching into another branch's suite. If
/// that behavioural test is ever added, **delete this file** — it is a stand-in for a real one.
///
/// The known weakness, stated rather than hidden: a source assertion is pinned to a spelling, and
/// renaming `oweTrialWelcome()` fails these tests without any behaviour changing. That is a false
/// positive worth having, because the alternative is what happened — a defect that reads as
/// obviously wrong in review and is invisible to CI.
@Suite("Phase 110 — trial welcome wiring")
struct TrialWelcomeWiringTests {

    private static let gatePath = "Onboarding/OnboardingGate.swift"

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RascalTests
            .deletingLastPathComponent()      // Rascal
            .appendingPathComponent("Rascal")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: root, encoding: .utf8)
    }

    /// The body of one function, by brace matching from its declaration.
    ///
    /// Substring-searching the whole file would be useless here — `oweTrialWelcome()` is *supposed*
    /// to appear in it, four times. The question is only ever "does it appear **inside this
    /// function**", so the test has to know where the function ends.
    ///
    /// Comments are stripped first, so the paragraph in `resume()` explaining that it deliberately
    /// does not owe the welcome cannot itself fail the test that checks it doesn't.
    private func functionBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: declaration),
            "\(declaration) is not in the file — this test stopped looking at the real code"
        )

        var depth = 0
        var body = ""
        var started = false
        for character in source[start.lowerBound...] {
            if character == "{" { depth += 1; started = true }
            if started { body.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }

        return body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
            .joined(separator: "\n")
    }

    /// **The regression test for the defect itself.** Break-tested: adding `oweTrialWelcome()` to
    /// `resume()` failed 0 of 1125 tests before this existed, and fails this one now.
    ///
    /// `resume()` is every launch of an already-signed-in install. Treating that as a sign-in is
    /// exactly what showed the welcome to people who have been paying for months.
    @Test("resuming a persisted session never owes the two-weeks welcome")
    func resumeDoesNotOweTheWelcome() throws {
        let gate = try source(Self.gatePath)
        let body = try functionBody("func resume() async {", in: gate)

        let owes = body.contains("oweTrialWelcome()")
        #expect(
            !owes,
            """
            resume() calls oweTrialWelcome(). That is every launch of an existing install, so this \
            shows "Two weeks, everything open" to households that have been signed in for months — \
            including subscribed ones. The welcome is owed only where a credential is exchanged.
            """
        )
    }

    /// The other half: it must still be armed *somewhere*, or the screen silently never appears and
    /// no test notices that either. A guard that only checks the failure direction can be satisfied
    /// by deleting the feature.
    @Test("the welcome is still armed by the sign-in paths")
    func theWelcomeIsArmedSomewhere() throws {
        let gate = try source(Self.gatePath)
        let calls = gate.components(separatedBy: "oweTrialWelcome()").count - 1

        // Four call sites plus the declaration itself. Asserted as a floor rather than an equality:
        // a fifth sign-in path is a legitimate change, and a test that failed on one would be
        // noise. Zero, or only the declaration, is the failure that matters.
        #expect(
            calls >= 2,
            "oweTrialWelcome() is declared but never called — the welcome can no longer appear at all"
        )
    }

    /// An invited second guardian signs in through one of the same four ordinary paths, so being
    /// owed-on-sign-in is not enough on its own to keep the welcome away from them.
    ///
    /// The household is the unit (D4): its two weeks, if it ever had any, are not theirs.
    @Test("the invite path declines the welcome")
    func theInvitePathDeclinesTheWelcome() throws {
        let gate = try source(Self.gatePath)
        let declines = gate.contains("session.declineTrialWelcome()")

        #expect(
            declines,
            """
            Nothing calls declineTrialWelcome(). An invited second guardian signs in through the \
            same four paths as anybody else, so without this they are marked owed and told they \
            have two weeks on a household that may have been subscribed for a year.
            """
        )
    }
}
