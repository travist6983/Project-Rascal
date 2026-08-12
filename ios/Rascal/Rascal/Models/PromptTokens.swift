import SwiftUI

/// The three answers `children.pronouns` accepts.
///
/// The raw values are the wire values to the character — `docs/api-contract.md` and the named
/// CHECK behind `api/src/rascal/constants.py` both spell them `he/him`, `she/her`, `they/them`.
/// A slash, lowercase, no spaces. Sending `he_him` to that column is a 422, and inventing a
/// display form that differs from the stored form is how the two drift apart.
///
/// **There is no `unanswered` case, deliberately.** Unanswered is `nil`, because that is what the
/// column holds and what `ChildCreate`/`ChildUpdate` mean by absent. Modelling it as a fourth case
/// would let a picker preselect it and let a renderer forget which of the four is not a pronoun.
nonisolated enum PronounSet: String, CaseIterable, Codable, Sendable {
    case heHim = "he/him"
    case sheHer = "she/her"
    case theyThem = "they/them"

    /// Reads a value the server sent, and yields `nil` for anything this build does not know.
    ///
    /// **A value outside the three must never fail a decode.** `ChildResponse` arrives on the
    /// launch path, so a widened CHECK constraint shipped ahead of a client release would
    /// otherwise take out `GET /children` — and with it the whole app — rather than one row of
    /// Settings. An unrecognised set degrades to unanswered, which renders they/them, which is
    /// grammatical for every child.
    init?(wire: String?) {
        guard let wire, let known = PronounSet(rawValue: wire) else { return nil }
        self = known
    }

    /// Shown in the picker exactly as it is stored. The label *is* the wire value, so there is no
    /// mapping to get wrong and nothing to reconcile when someone reads the database by hand.
    var label: String { rawValue }
}

/// Prompt bodies, rendered for one particular child.
///
/// The contract is `docs/api-contract.md`, *Prompt pronoun tokens*, settled Aug 11 2026 in
/// `docs/decisions.md`. One dictionary, no logic, and **thirteen** tokens — those documents' prose
/// says fourteen while their table lists thirteen; `tokenSetMatchesTheContract` records which one
/// is implemented and why.
///
/// The server stores and serves bodies with tokens intact and never renders them; every client
/// renders at the last moment before a human sees the sentence, because a body pre-rendered
/// upstream could not be re-rendered when the answer changes — and the same body reaches a phone,
/// a browser client, an export and a printed book.
///
/// **This never touches `Entry.body`.** That property is one character away from
/// `Entry.promptBody` in the same model and reads identically at a glance, but it holds the
/// parent's own words. A parent who typed `{they}` literally, or wrote about a game with braces
/// in its name, must get their sentence back byte for byte. Only `Assignment.body` and
/// `Entry.promptBody` are prompts.
nonisolated enum PromptTokens {

    /// Substitute every known token. One pass, no regex, no grammar.
    ///
    /// Three properties, each pinned by an assertion in `PronounRenderingTests`:
    ///
    /// 1. **Text containing no tokens comes back byte-identical.** Structurally, not incidentally:
    ///    a body with no `{` returns the same `String` without a scan. This is what protects the
    ///    113 seeded prompts, which are literal he/him and contain no braces.
    /// 2. **A nil pronoun renders the they/them column.** Unanswered degrades to correct English
    ///    rather than to a placeholder or a guess at an answer nobody gave.
    /// 3. **An unknown token renders literally, braces included, and does not throw.** `{foo}`
    ///    stays `{foo}` on the card. In an archive meant to outlive the app, a visible `{foo}` is
    ///    a bug somebody can see and fix; a silently dropped one is a sentence that lost a word,
    ///    and nobody will ever know which word it was.
    static func render(_ body: String, for subject: PromptSubject) -> String {
        // Property 1, and the fast path, are the same line. Nothing below can run on a body that
        // has no brace in it, so "unchanged" is not a behaviour that has to be maintained.
        guard body.contains("{") else { return body }

        var out = ""
        out.reserveCapacity(body.count)
        var cursor = body.startIndex

        while let open = body[cursor...].firstIndex(of: "{") {
            out.append(contentsOf: body[cursor..<open])

            // An unclosed brace is not an error and not a token. The rest of the body, **from the
            // brace onwards**, is literal text — the same answer property 3 gives for `{foo}`.
            //
            // `cursor` has to move to `open` before breaking. The prefix before the brace has
            // already been appended, so leaving the cursor where it was would append it a second
            // time on the way out: `}{` came back as `}}{`, caught by the `}{` case in
            // `unknownTokensSurviveIntact`.
            guard let close = body[body.index(after: open)...].firstIndex(of: "}") else {
                cursor = open
                break
            }

            // Half-open on purpose: `{}` yields an empty name, which is unknown, which is
            // literal. A closed range would be `open+1 ... open` and would trap.
            let token = String(body[body.index(after: open)..<close])

            if let value = substitution(for: token, subject: subject) {
                out.append(value)
            } else {
                // Property 3. The braces go back on because they are part of what is wrong.
                out.append(contentsOf: body[open...close])
            }

            cursor = body.index(after: close)
        }

        out.append(contentsOf: body[cursor...])
        return out
    }

    /// Nil means "not a token this build knows", which the caller renders literally.
    private static func substitution(for token: String, subject: PromptSubject) -> String? {
        if token == "name" {
            // An empty name leaves `{name}` standing rather than deleting a word from the
            // sentence. The server requires `min_length=1`, so this is only reachable before the
            // child has been fetched — and a visible token during that beat is the honest failure.
            return subject.name.isEmpty ? nil : subject.name
        }
        // Property 2. `nil` is unanswered, and unanswered reads the they/them column.
        return forms[token]?.value(for: subject.pronouns ?? .theyThem)
    }

    /// The table, and the whole of the logic.
    ///
    /// **They-forms are the keys because they/them is the only English pronoun set whose five
    /// slots are five distinct words.** `{his}` as a key would be ambiguous between the
    /// determiner ("his favourite") and the possessive pronoun ("that one is his"), which
    /// they/them splits into "their" and "theirs" — so a he-keyed table cannot be substituted
    /// correctly, and the bug would stay invisible until someone set she/her.
    ///
    /// **Verb agreement is four explicit compound tokens, never conjugation.** A conjugator that
    /// inflected the word after `{they}` would be correct usually, and "usually" is not a property
    /// a permanent archive gets to have. The author decides at write time instead.
    ///
    /// **Capitalisation is explicit, never positional.** Nothing here capitalises a token because
    /// it starts a sentence: a prompt may legitimately begin mid-thought, and a positional rule
    /// would be wrong somewhere across eighteen years with nobody watching.
    private static let forms: [String: Forms] = [
        "they": Forms("he", "she", "they"),
        "them": Forms("him", "her", "them"),
        "their": Forms("his", "her", "their"),
        "theirs": Forms("his", "hers", "theirs"),
        "themself": Forms("himself", "herself", "themself"),
        "they_are": Forms("he is", "she is", "they are"),
        "they_were": Forms("he was", "she was", "they were"),
        "they_have": Forms("he has", "she has", "they have"),
        "they_do": Forms("he does", "she does", "they do"),
        "They": Forms("He", "She", "They"),
        "Them": Forms("Him", "Her", "Them"),
        "Their": Forms("His", "Her", "Their"),
    ]

    /// One row of the table. Twelve of these plus `{name}` is every token the contract lists.
    private struct Forms {
        let heHim: String
        let sheHer: String
        let theyThem: String

        init(_ heHim: String, _ sheHer: String, _ theyThem: String) {
            self.heHim = heHim
            self.sheHer = sheHer
            self.theyThem = theyThem
        }

        func value(for set: PronounSet) -> String {
            switch set {
            case .heHim: heHim
            case .sheHer: sheHer
            case .theyThem: theyThem
            }
        }
    }

    /// Every token the table answers to, `{name}` included. Test-facing: it is what lets the
    /// suite assert the token set against the contract rather than trusting a hand-kept count.
    static var knownTokens: [String] { forms.keys.sorted() + ["name"] }
}

/// The child a prompt is being rendered about: their name, and their pronouns if anyone said.
///
/// Carried through the SwiftUI environment rather than threaded as a parameter, because the
/// alternative is an argument on every card, every accessibility label and every preview — and a
/// site that forgets to pass it renders differently from the one beside it. `EnvironmentValues`
/// has one default, and the default is honest: no name, no answer.
nonisolated struct PromptSubject: Equatable, Sendable {
    var name: String
    /// Nil is unanswered, and stays distinguishable from they/them all the way to the renderer,
    /// which is what lets Settings show an empty row instead of claiming an answer.
    var pronouns: PronounSet?

    /// Before `GET /children` has answered. Renders they/them and leaves `{name}` visible.
    static let unknown = PromptSubject(name: "", pronouns: nil)
}

private struct PromptSubjectKey: EnvironmentKey {
    static let defaultValue = PromptSubject.unknown
}

extension EnvironmentValues {
    /// Passed through the environment rather than down five initialisers: a `PromptCard` on
    /// Today, an `EntryCard` inside a Moments carousel and the composer's quoted block are all
    /// showing the same library and must read it the same way.
    ///
    /// **A view that renders a prompt body and does not read this is the bug this phase exists to
    /// prevent** — the same sentence would read differently depending on which screen it was
    /// opened from.
    var promptSubject: PromptSubject {
        get { self[PromptSubjectKey.self] }
        set { self[PromptSubjectKey.self] = newValue }
    }
}

extension View {
    /// Sugar for the one call site in `RootView`, and for previews that need a specific child.
    func promptSubject(_ subject: PromptSubject) -> some View {
        environment(\.promptSubject, subject)
    }
}
