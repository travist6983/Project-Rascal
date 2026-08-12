import Foundation
import Testing

@testable import Rascal

/// The shipped library, verbatim, so the guard can be measured against the real thing
/// rather than against invented sentences.
///
/// **113 prompts ship; 99 of them name the child with `he`, `him` or `his`, and 0 carry a
/// `{token}`.** That is the finding this phase is built on top of — see the PR.
let realLibraryBodies: [String] = [
    "What did he say this week that you want to remember exactly?",
    "What is he obsessed with right now?",
    "What does he call you? Write down every version.",
    "What food is he refusing this week?",
    "What did he do today that annoyed you and will be funny in ten years?",
    "Who is his best friend right now, and what do they do together?",
    "What word does he mispronounce that you don't want to correct?",
    "What is he afraid of right now?",
    "What did he teach himself this month?",
    "Describe his laugh.",
    "What does he want to be when he grows up — this week's version?",
    "What's the last thing he asked that you couldn't answer?",
    "What's the first thing he does when he wakes up?",
    "What are you worried about with him right now?",
    "What did you get wrong as a parent this week? Write it honestly — he'll need to know you were",
    "What does his room look like right now? Describe the mess.",
    "What's his favorite thing to do with his mom?",
    "What's a rule in your house he'd be surprised to learn isn't universal?",
    "What did he cry about today?",
    "What's the last thing he was proud of himself for?",
    "What toy has he not put down this month?",
    "What does he smell like right now?",
    "Who does he look like today?",
    "What phrase has he picked up from you that you wish he hadn't?",
    "What's the thing he does that nobody else would notice?",
    "How does he say goodbye?",
    "What's changed about him in the last three months?",
    "Photograph his hands. Just his hands.",
    "Get down to his eye level and take the photo from there.",
    "Photograph his shoes by the door.",
    "Take a picture of what he built today, however unimpressive.",
    "Photograph the mess he made. Don't clean it up first.",
    "Take a photo of him sleeping.",
    "Photograph his drawing or his handwriting, exactly as it is.",
    "Take a picture of him with whoever he's most attached to right now.",
    "Photograph his lunch, arranged the way he arranged it.",
    "Take a photo of him doing the thing he does every single day.",
    "Photograph his face mid-laugh. Burst mode. Take twenty, keep one.",
    "Take a picture of him in the same spot you photographed him a year ago.",
    "Photograph what he's wearing today, head to toe. In ten years this is a costume.",
    "Photograph his favorite toy alone, like a portrait.",
    "Take a picture of him outside doing nothing in particular.",
    "Take a photo of him with his grandparents.",
    "Photograph him next to something for scale — a doorway, the dog, your hand.",
    "Photograph him in the first snow.",
    "Take a photo of him on the first day of school.",
    "Photograph whatever he made out of leaves, pumpkins, or mud this month.",
    "Take a photo of what summer looks like for him this year.",
    "Film him telling you about his day. Don't prompt him.",
    "Ask him ten questions about his mom and film the answers. Don't correct anything.",
    "Film him doing the thing he's currently best at.",
    "Record thirty seconds of him just playing. No talking to the camera.",
    "Film him explaining how something works.",
    "Record him running toward you.",
    "Ask him what he'd say to himself at eighteen. Film it.",
    "Film him eating something for the first time.",
    "Record him dancing to whatever's playing.",
    "Film him on the last day of the school year.",
    "Record him telling you a story. Any story. Don't correct the words he says wrong.",
    "Record him singing. Whatever he's singing.",
    "Record him counting as high as he can go.",
    "Record him saying the alphabet.",
    "Record him saying his own full name.",
    "Record him describing you.",
    "Record him reading a page out loud.",
    "Record him telling a joke.",
    "Record him talking about his best friend.",
    "Record him answering \"what's the best thing that happened today?\"",
    "Record him making up a song about nothing.",
    "Never let go of the hug first today. Let him be the one to pull away.",
    "Carry him when he asks, even though he can walk fine.",
    "Use his baby nickname out loud today, while he still answers to it.",
    "Let him help with something, even though it triples the time.",
    "Let him choose dinner. Entirely.",
    "Ask him a question and let the silence sit until he answers it.",
    "Go outside with him with no plan and no phone.",
    "Apologize to him for something. Out loud.",
    "Let him win, and don't tell him you did.",
    "Tell him one specific thing you admire about him. Not \"good job.\"",
    "Do nothing next to him for fifteen minutes.",
    "Ask him to teach you something.",
    "Take him on a solo date and let him pick everything — where you go, what you eat, what you do.",
    "Build something with him that takes more than one sitting.",
    "Interview him with ten questions about his mom and film the whole thing.",
    "Spend an afternoon doing only what he suggests.",
    "Cook something from your own childhood and tell him where it came from.",
    "Show him where you grew up — go there, or go through the photos.",
    "Ask him to pick three songs and play them loud in the kitchen.",
    "Let him plan and \"cook\" one meal, whatever that means at his age.",
    "Measure his height and weight. Photograph him against the same wall, same spot as last time.",
    "Trace his hand on paper and photograph it.",
    "Write him something about money that you wish someone had told you at nineteen.",
    "Write him a letter about exactly who he is right now. He won't be this person next year.",
    "Write down what you were afraid of before he was born, and what actually happened.",
    "Write him about a mistake you made that he'll probably make too.",
    "Write down the story of the day he was born, in as much detail as you can still remember.",
    "Write him something about his mother he'd never think to ask about.",
    "Write down what you hope he keeps from being four years old.",
    "Write him what you'd want him to know if you weren't around to say it.",
]

@Suite("Personalization — measured against the shipped library")
struct PersonalizationLibraryTests {

    /// A mechanical he/him → name substitution. **Not what the model does** — it is the *ideal*
    /// output, the best case any model could return for this library. Running the guard over it
    /// measures the guard's own false-rejection rate, with model quality held out of it.
    private func idealSubstitution(_ body: String, name: String) -> String {
        var out = body
        for (pattern, replacement) in [
            ("\\bhis\\b", "\(name)'s"),
            ("\\bhim\\b", name),
            ("\\bhe\\b", name),
        ] {
            out = out.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    /// **The number the phase brief asks for, as honestly as a simulator can produce it.**
    ///
    /// Every personalization in this suite is a stub — the model has never returned `.available`
    /// on any hardware this project owns — so this is not "how often the model is wrong". It is
    /// the ceiling: how much of the real library survives validation when substitution is perfect.
    /// A low number here would mean the guard is unusable regardless of model quality.
    @Test("the guard accepts an ideal substitution across the shipped library")
    func guardAcceptsIdealSubstitution() {
        let subject = PromptSubject(name: "Sam", pronouns: .heHim)
        var rejected: [PersonalizationGuard.Rejection: Int] = [:]
        var accepted = 0

        for body in realLibraryBodies {
            let ideal = idealSubstitution(body, name: subject.name)
            if let reason = PersonalizationGuard.rejection(
                personalized: ideal, canonical: body, subject: subject
            ) {
                rejected[reason, default: 0] += 1
            } else {
                accepted += 1
            }
        }

        let total = realLibraryBodies.count
        let rate = Double(total - accepted) / Double(total)

        #expect(total == 99, "the shipped library's personalizable half")
        // **Measured, not hoped for: 99 of 99 survive, a 0% false-rejection rate.** Pinned as an
        // equality rather than a bound so that tightening a rule shows up here as a number that
        // moved, with the breakdown naming which rule started firing.
        #expect(accepted == 99, "rejected \(total - accepted) of \(total): \(rejected)")
        #expect(rate == 0.0, "false-rejection rate moved to \(rate): \(rejected)")
    }
}
