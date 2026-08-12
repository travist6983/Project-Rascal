import Foundation
import Testing

@testable import Rascal

/// The pronoun token contract, asserted rather than intended.
///
/// The table is `docs/api-contract.md`, *Prompt pronoun tokens — a wire-format contract*, settled
/// in `docs/decisions.md` on Aug 11 2026. Every cell below is transcribed from that table, not
/// from `PromptTokens`'s own dictionary: a test that reads the implementation's table and compares
/// it to itself would pass on any table at all.
@Suite("Prompt pronoun tokens")
struct PronounRenderingTests {

    // MARK: - The seeded library

    /// Every prompt body in the committed `today.json`, which is a real captured response and is
    /// where the seeded library actually reaches this client.
    ///
    /// Read from the fixture rather than retyped, so this grows when the fixture is re-captured
    /// with `make fixtures` and cannot drift into a set of invented strings that happen to agree.
    static func seededBodies() throws -> [String] {
        let today = try Fixtures.decode(TodayResponse.self, from: "today.json")
        let all = today.today + today.waiting + today.doneToday
        return Array(Set(all.map(\.body))).sorted()
    }

    /// The passthrough assertion is only worth anything if the corpus it runs on is real, big
    /// enough, and genuinely tokenless. All three are checked here so the next test cannot quietly
    /// become a tautology when somebody re-captures the fixture.
    @Test("the fixture supplies at least five real, brace-free seeded bodies")
    func corpusIsFitToAssertOn() throws {
        let bodies = try Self.seededBodies()

        #expect(bodies.count >= 5, "the spec asks for at least five real seeded bodies")
        for body in bodies {
            #expect(!body.isEmpty)
            // The 113 seeded prompts are literal he/him and contain no braces. If this ever
            // fails, the library has started carrying tokens and the passthrough test below is
            // no longer asserting what it claims to.
            #expect(!body.contains("{"), "seeded body unexpectedly contains a token: \(body)")
        }
    }

    /// **Invariant 1.** Text containing no tokens passes through byte-identical.
    ///
    /// This is what protects the 113 seeded prompts: they render exactly as they do today, in all
    /// four pronoun states, and nothing in this phase rewrites one of them.
    @Test("a tokenless seeded body is returned byte-identical in every pronoun state")
    func seededBodiesPassThroughUnchanged() throws {
        for body in try Self.seededBodies() {
            for pronouns in [PronounSet.heHim, .sheHer, .theyThem, nil] {
                let rendered = PromptTokens.render(
                    body, for: PromptSubject(name: "Hendrix", pronouns: pronouns)
                )
                #expect(rendered == body, "\(String(describing: pronouns)) changed: \(body)")
                // Byte-identical, not merely equal-looking. `==` on String is canonical
                // equivalence, which would forgive a normalisation pass silently rewriting
                // someone's apostrophe.
                #expect(Array(rendered.utf8) == Array(body.utf8))
            }
        }
    }

    /// **The passthrough test, broken on purpose.**
    ///
    /// The spec's standing pattern: a passthrough assertion that passes on tokenless input and
    /// would *also* pass on tokenised input is asserting nothing. So take a real seeded body,
    /// put a token in it, and require that the renderer changes it. If this test ever passes for
    /// the wrong reason — a renderer that returns its input — the test above is worthless and
    /// this one says so.
    @Test("the same assertion fails once a token is introduced into a seeded body")
    func passthroughAssertionHasTeeth() throws {
        let body = try #require(try Self.seededBodies().first)
        let tokenised = body.replacingOccurrences(of: "him", with: "{them}")
        try #require(tokenised != body, "pick a body that can carry a token")

        let rendered = PromptTokens.render(
            tokenised, for: PromptSubject(name: "Hendrix", pronouns: .sheHer)
        )

        #expect(rendered != tokenised, "the renderer did not substitute a token it knows")
        #expect(rendered.contains("her"))
        #expect(!rendered.contains("{them}"))
    }

    // MARK: - The table

    /// Every cell of the fourteen-token table, transcribed from `docs/api-contract.md`.
    ///
    /// `(token, he/him, she/her, they/them)`. The null column is not listed because it is not a
    /// fourth set of values — it is the they/them column, which is invariant 2 and is asserted
    /// against this same table below.
    static let table: [(token: String, heHim: String, sheHer: String, theyThem: String)] = [
        ("{they}", "he", "she", "they"),
        ("{them}", "him", "her", "them"),
        ("{their}", "his", "her", "their"),
        ("{theirs}", "his", "hers", "theirs"),
        ("{themself}", "himself", "herself", "themself"),
        ("{they_are}", "he is", "she is", "they are"),
        ("{they_were}", "he was", "she was", "they were"),
        ("{they_have}", "he has", "she has", "they have"),
        ("{they_do}", "he does", "she does", "they do"),
        ("{They}", "He", "She", "They"),
        ("{Them}", "Him", "Her", "Them"),
        ("{Their}", "His", "Her", "Their"),
    ]

    @Test("every token renders its own column")
    func tableIsHonoured() {
        for row in Self.table {
            let expected: [(PronounSet, String)] = [
                (.heHim, row.heHim), (.sheHer, row.sheHer), (.theyThem, row.theyThem),
            ]
            for (set, want) in expected {
                let got = PromptTokens.render(row.token, for: PromptSubject(name: "Hendrix", pronouns: set))
                #expect(got == want, "\(row.token) under \(set.rawValue) gave \(got), wanted \(want)")
            }
        }
    }

    /// **Invariant 2.** A null pronoun renders the they/them column.
    ///
    /// Not "renders something reasonable" — renders *that column*, cell for cell. An unanswered
    /// question degrades to correct English rather than to a placeholder, a guess, or a default
    /// that implies an answer nobody gave.
    @Test("a null pronoun renders the they/them column exactly")
    func nullRendersTheyThem() {
        for row in Self.table {
            let unanswered = PromptTokens.render(row.token, for: PromptSubject(name: "Hendrix", pronouns: nil))
            #expect(unanswered == row.theyThem, "\(row.token) unanswered gave \(unanswered)")
            // And it is the same string the explicit they/them answer produces, which is the
            // property that stops the two drifting apart in a later edit.
            let explicit = PromptTokens.render(row.token, for: PromptSubject(name: "Hendrix", pronouns: .theyThem))
            #expect(unanswered == explicit)
        }
    }

    /// **The contract's prose and its table disagree, and the table wins.**
    ///
    /// `docs/api-contract.md` says "Fourteen tokens, one dictionary, no logic" — and then lists
    /// **thirteen** rows: nine lowercase forms, three capitalised (`{They}`, `{Them}`, `{Their}`)
    /// and `{name}`. `docs/decisions.md` repeats the same sentence over the same table. Counted by
    /// hand twice and by this test once.
    ///
    /// Thirteen is what is implemented, because the table is the substance and "fourteen" is a
    /// description of it. Inventing a fourteenth to satisfy the sentence would be a client adding
    /// a token to a wire-format contract three other consumers have to honour — and the two
    /// obvious candidates, `{Theirs}` and `{Themself}`, are precisely the capitalised forms the
    /// table appears to have left out deliberately, since neither plausibly opens a sentence.
    ///
    /// The count is derived from the transcription above rather than written as a literal, so the
    /// two cannot drift apart.
    @Test("the implementation knows exactly the tokens the contract's table lists")
    func tokenSetMatchesTheContract() {
        let declared = Set(Self.table.map { $0.token.dropFirst().dropLast() }.map(String.init) + ["name"])
        #expect(declared.count == Self.table.count + 1)
        #expect(declared.count == 13, "the contract's table lists thirteen rows, whatever its prose says")
        #expect(Set(PromptTokens.knownTokens) == declared, "implementation and contract disagree on the token set")
    }

    // MARK: - `{name}`

    @Test("{name} is the child's given name, identical in every column")
    func nameIsTheSameInEveryColumn() {
        for pronouns in [PronounSet.heHim, .sheHer, .theyThem, nil] {
            let rendered = PromptTokens.render(
                "What made {name} laugh today?",
                for: PromptSubject(name: "Hendrix", pronouns: pronouns)
            )
            #expect(rendered == "What made Hendrix laugh today?")
        }
    }

    /// Before `GET /children` answers there is no name, and a substituted empty string would
    /// produce "What made  laugh today?" — a sentence that lost a word. A visible `{name}` is the
    /// honest failure, and it is the same answer invariant 3 gives.
    @Test("{name} with no name yet stays visible rather than deleting a word")
    func emptyNameLeavesTheTokenStanding() {
        let rendered = PromptTokens.render("What made {name} laugh today?", for: .unknown)
        #expect(rendered == "What made {name} laugh today?")
    }

    // MARK: - Unknown tokens

    /// **Invariant 3.** An unknown token renders literally, braces included, and does not throw.
    ///
    /// In an archive meant to outlive this app, a visible `{foo}` is a bug somebody can see and
    /// fix. A silently dropped one is a sentence missing a word, and nobody will ever know which
    /// word it was.
    @Test(
        "an unknown token renders literally, braces included",
        arguments: [
            "{foo}",
            "{his}",          // the he-keyed table that was rejected — must not half-work
            "{THEY}",         // capitalisation is explicit, so this is not `{They}`
            "{they_will}",    // a compound nobody added
            "{}",
            "{ they }",       // spaces are part of the token name, and no token has them
            "{name",          // unclosed
            "}{",
        ]
    )
    func unknownTokensSurviveIntact(_ input: String) {
        for pronouns in [PronounSet.heHim, .sheHer, .theyThem, nil] {
            let rendered = PromptTokens.render(input, for: PromptSubject(name: "Hendrix", pronouns: pronouns))
            #expect(rendered == input, "\(input) under \(String(describing: pronouns)) became \(rendered)")
        }
    }

    @Test("an unknown token beside a known one leaves the known one working")
    func unknownDoesNotPoisonTheRestOfTheSentence() {
        let rendered = PromptTokens.render(
            "{They} said {foo} to {their} mum.",
            for: PromptSubject(name: "Hendrix", pronouns: .sheHer)
        )
        #expect(rendered == "She said {foo} to her mum.")
    }

    // MARK: - Substitution mechanics

    @Test("adjacent and repeated tokens all substitute")
    func adjacentTokens() {
        let rendered = PromptTokens.render(
            "{They}{They} {they} {they}",
            for: PromptSubject(name: "Hendrix", pronouns: .heHim)
        )
        #expect(rendered == "HeHe he he")
    }

    @Test("a sentence using every token reads correctly in every column")
    func wholeSentence() {
        let body = "{They} said {they_are} tired, so {name} took {their} bear and {they_do} it {themself}."

        #expect(
            PromptTokens.render(body, for: PromptSubject(name: "Hendrix", pronouns: .heHim))
                == "He said he is tired, so Hendrix took his bear and he does it himself."
        )
        #expect(
            PromptTokens.render(body, for: PromptSubject(name: "Ada", pronouns: .sheHer))
                == "She said she is tired, so Ada took her bear and she does it herself."
        )
        #expect(
            PromptTokens.render(body, for: PromptSubject(name: "Sam", pronouns: nil))
                == "They said they are tired, so Sam took their bear and they do it themself."
        )
    }

    /// A replacement that itself looked like a token must not be substituted a second time. None
    /// of the fourteen values contains a brace, so this holds structurally — but it holds because
    /// the renderer makes one pass, not because the values happen to be safe today.
    @Test("substituted output is not rescanned")
    func outputIsNotRescanned() {
        let rendered = PromptTokens.render(
            "{name} likes {their} things",
            for: PromptSubject(name: "{they}", pronouns: .heHim)
        )
        #expect(rendered == "{they} likes his things")
    }

    // MARK: - The wire values

    /// The picker may only ever send these three strings. The named CHECK constraint behind
    /// `children.pronouns` accepts nothing else, and a client sending `he_him` gets a 422 with no
    /// useful place to show it.
    @Test("the wire values are exactly the three the API accepts")
    func wireValues() {
        #expect(PronounSet.heHim.rawValue == "he/him")
        #expect(PronounSet.sheHer.rawValue == "she/her")
        #expect(PronounSet.theyThem.rawValue == "they/them")
        #expect(PronounSet.allCases.count == 3)
        // The label shown in the picker is the value that gets sent. No mapping, nothing to
        // reconcile against the database by hand.
        for set in PronounSet.allCases { #expect(set.label == set.rawValue) }
    }

    @Test(
        "an unrecognised or absent wire value reads as unanswered rather than failing",
        arguments: [nil, "", "he_him", "He/Him", "it/its", "unspecified"] as [String?]
    )
    func unknownWireValuesDegradeToNil(_ wire: String?) {
        #expect(PronounSet(wire: wire) == nil)
    }

    @Test("the three known wire values round-trip")
    func knownWireValuesParse() {
        #expect(PronounSet(wire: "he/him") == .heHim)
        #expect(PronounSet(wire: "she/her") == .sheHer)
        #expect(PronounSet(wire: "they/them") == .theyThem)
    }
}
