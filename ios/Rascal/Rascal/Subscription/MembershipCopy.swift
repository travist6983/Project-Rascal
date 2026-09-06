import Foundation

/// **Every user-visible string phase 108 introduced, in one file.**
///
/// The source is the owner's `free-tier-copy.md`, reproduced in `docs/design/free-tier-copy.md`.
/// The file itself has never existed on disk in either repository: both this phase's prompt and the
/// Claude Design prompt point at it, and it reached this phase as **two independent witnesses that
/// agree** — the phase 109 session's prompt carried its full text, and the human-approved design
/// bundle at `docs/App-Views/mobile-app-design-tiers-lock-cta/` renders the same strings, its header
/// stating *"Every string is verbatim from `free-tier-copy.md`"*. Where those two disagreed, the
/// difference is reported rather than resolved here.
///
/// **The file forbids agents authoring copy.** Nothing below is invented; every string is the
/// owner's, with **one deliberate, reported transformation** — see *Pronouns* — and one string
/// (`membershipMissingAction`) that is not shipped and exists only to name a gap.
///
/// ## Pronouns
///
/// **The owner's copy is written throughout for a boy** — *"A picture of him"*, *"His voice"*,
/// *"until he's old enough"*, *"His other parent"*. `CLAUDE.md` is explicit and overriding:
/// *"Never write copy that assumes a child's gender — client-side strings are neutral too and stay
/// that way."* Shipping it as written would tell a family with a daughter *"A picture of him"* on
/// the first screen of an app about their specific child.
///
/// So these strings carry the **same pronoun tokens the prompt library already uses**, rendered
/// through `PromptTokens` against the child on screen. This is not a rewrite and not a neutralising:
/// **for a `he/him` child every one of these renders byte-identical to the owner's sentence**, and
/// for every other child it renders correctly instead of wrongly. Two strings shift by one word —
/// *"until he's old enough"* becomes *"until he is old enough"* — because `{they_are}` is the
/// contract's token for verb agreement and there is no contracted form in the table; inventing one
/// is exactly what the file forbids.
///
/// It is recorded under *Proposed additions* in `docs/design/free-tier-copy.md` and is the first
/// item in the phase's PR. **If the owner wants the literal masculine copy, this is one file.**
///
/// ## Prices
///
/// **No price, cadence or trial length appears here.** They come off the StoreKit `Product` via
/// `PlanCopy` and `AnnualSaving`. The copy file's `{{PRICE_YEAR}}` / `{{PRICE_MONTH}}` exist so copy
/// can be *reviewed*; a build that renders one has a bug.
nonisolated enum MembershipCopy {

    // MARK: - 1 · The locked card on Today

    /// The eyebrow, above the body. Set through `.typeRole(.label)`, which uppercases it — so these
    /// are stored in sentence case and the copy file's `TODAY'S PHOTO MISSION` is what renders.
    ///
    /// **Keyed on `slot`, not on `kind_hint`** — see `LockedSlot.slotKind`.
    static func lockedEyebrow(_ slot: Slot) -> String {
        switch slot {
        case .mission: "Today's photo mission"
        case .missionB: "Today's second mission"
        case .weekly: "This week's mission"
        case .monthly: "This month's measurement"
        case .letter: "A letter to {them}"
        // `question` is never locked — the daily question is the free tier — and `unknown` is a
        // slot newer than this build. Neither is in the copy file, because neither can be drawn
        // from it. **This is the only authored string on the card**; it names the shape of the
        // thing without claiming to know which shape, the same contract every other unrecognised
        // value in this app honours.
        case .question, .unknown: "Another mission today"
        }
    }

    /// The body. **Never a prompt body** — the server deliberately sends none for a locked slot,
    /// and the copy file's rule 5 says the same thing from the product side: *"Show the shape, never
    /// blur the content… It never blurs or teases prompt text. Hidden content behind frosted glass
    /// is a dark pattern and off-register for this product."*
    static func lockedBody(_ slot: Slot) -> String {
        switch slot {
        case .mission: "A picture of {them}, and the reason you took it."
        case .missionB: "{Their} voice, a video, or something to do together."
        case .weekly: "A bigger one, once a week."
        case .monthly: "How much of {them} has changed since last month."
        case .letter: "Sealed until {they_are} old enough to read it."
        case .question, .unknown: "Something else to do together."
        }
    }

    /// The footer, on every locked card. Copy-file rule 4: *"The lock states inclusion, not
    /// deprivation."*
    static let lockedFooter = "Included with membership"

    /// Eyebrow, body, footer — assembled once so the card and its VoiceOver label cannot say
    /// different things.
    ///
    /// **What the tap does is deliberately not here.** It is the `accessibilityHint`, which is where
    /// VoiceOver expects it and which it reads immediately after the label. Carrying it in both
    /// announced the phrase twice on every card — four times on a Saturday-the-15th board.
    static func lockedAccessibilityLabel(_ slot: Slot, subject: PromptSubject) -> String {
        let eyebrow = PromptTokens.render(lockedEyebrow(slot), for: subject)
        let body = PromptTokens.render(lockedBody(slot), for: subject)
        // **No punctuation added after `body`.** Every body string already ends in a full stop, so
        // appending one produced "…and the reason you took it.. Included with membership." — a
        // doubled stop, which VoiceOver reads as a longer pause and a proofreader reads as a typo.
        return "\(eyebrow). \(body) \(lockedFooter)."
    }

    /// The hint on a locked card. Here rather than at the call site, because it is a string a
    /// parent hears and every one of those lives in this file.
    static let lockedHint = "Opens membership"


    // MARK: - 2 · The membership sheet

    /// **One sheet, one header, every entry point.** The copy file is explicit — *"Presented from a
    /// locked card, from Settings, and from the guardian-invite surface. **Same sheet every
    /// time.**"* That retires the per-context headers the shipped `PaywallSheet` carried.
    static let title = "The daily question is always free."
    static let subtitle = "Membership is what fills in the rest of the day."

    static let addsLabel = "What membership adds"

    /// In this order. *"no icons competing with the terracotta"*, per the copy file.
    static let adds = [
        "A mission every day — a photo, a video, {their} voice, or something to do together",
        "Three on Saturdays and Sundays",
        "The monthly measurement, and letters you seal until {they_are} old enough",
        "Video, and photographs without a limit",
        "{Their} other parent, on the same archive",
    ]

    static let freeLabel = "Yours either way"

    /// The block this sheet exists to be honest about. The design puts it in `surface` at **body
    /// 16, not metadata** — *"the Field vocabulary, so it reads as a stated fact rather than a
    /// footnote"* — which is the same instruction this phase's prompt gives in different words.
    static let stayFree = [
        "A new question every day, with no limit and no countdown.",
        "Everything you've already written and captured stays yours.",
        "Search the whole archive, and export all of it whenever you want.",
    ]

    /// The verb, per copy-file rule 2: *"A person **joins**; they do not upgrade."*
    static let primaryAction = "Become a member"

    /// **⚠️ Authored by phase 147 on Sep 6, 2026 and NOT approved by the owner.** Recorded under
    /// *Proposed additions* §10 in `docs/design/free-tier-copy.md` and named in the phase report so
    /// it can be kept or reworded in one place.
    ///
    /// The owner's call of Sep 6, 2026 stops a non-entitled household adding new media at all —
    /// photo, video and voice — while writing and did-it stay free and unlimited. That leaves the
    /// **+** sheet with three verbs it must not offer, and **no approved sentence says why.** §2's
    /// nearest bullet is *"Video, and photographs without a limit"*, which was written against D2's
    /// hundred-photo lifetime cap and now describes a difference from zero — using it here would
    /// tell a free parent they have photographs with a limit when they have none.
    ///
    /// So this is built out of the two approved fragments rather than written fresh: rule 4's
    /// *"Included with membership"* — the file's own words for a lock that states inclusion rather
    /// than deprivation — with the shapes named in front of it, the way §1's locked cards name the
    /// shape of what is missing without teasing its content.
    ///
    /// It states no count, no date and no consequence, and nothing about the archive: rule 3 is
    /// that the archive is never the thing being sold, and everything already captured stays
    /// readable, exportable and searchable whatever this says.
    static let mediaIncluded = "Photos, video and voice notes are included with membership."

    /// *"plain text, `inkMuted`, never smaller than the primary's label size and never greyed to
    /// near-invisibility."*
    static let notNow = "Not now"
    static let notNowHint = "Closes this and changes nothing"

    /// ~~*"One membership covers the whole family — every child, both parents."*~~ — **replaced
    /// Aug 26, 2026 by the owner's call, using the sentence he had already authored for the
    /// Settings action row in phase 125 §3.3.**
    ///
    /// **The reason is the same one that changed the Settings row**, and it is recorded because
    /// this string was deliberately *not* in phase 125's list and was left alone under that
    /// phase's match rule until the owner asked for it: *"both parents"* presumes a two-parent
    /// household. The only user today is one parent with one child.
    ///
    /// **Not an agent's wording.** It is the owner's approved §3.3 string applied to a second
    /// site, which is the same move phase 112 made with the free block — reuse an approved
    /// sentence rather than write a sibling for it.
    ///
    /// **One thing this puts out of step, flagged rather than fixed here:**
    /// `pocketchronicle.app/terms/` still reads *"One membership covers the household — every
    /// child, both parents."* — re-checked against the live page on Aug 27, 2026, after the
    /// domain moved with the Pocket Chronicle rename, so the mismatch is still real rather than
    /// inherited. ~~`getvellumapp.com/terms`~~ is the retired host and no longer the page the
    /// paywall links to. The marketing site is a different repository and a different lane.
    static let footnote = "One price covers everyone in the house — every parent, every child."

    /// **Guideline 3.1.2's renewal disclosure, and the one string here Apple asked for.**
    ///
    /// Verbatim from the phase 124 brief, so it is the owner's sentence rather than an agent's,
    /// which is what this file's own rule requires. Review wants the renewal terms on the purchase
    /// screen itself, not one tap away behind Terms of Use.
    ///
    /// **It is a statement, not a lever.** It says how the charge repeats and where to stop it, and
    /// nothing else: no countdown, no date, no *"before it renews"*, none of the eleven banned
    /// phrases. It is carried in `allUserVisibleStrings` so that guard covers it like every other
    /// string here, rather than being trusted because it is legal copy.
    ///
    /// **No price and no cadence**, per this file's *Prices* note — the plan rows above it carry
    /// both, formatted off the `Product`. A renewal sentence naming a figure would be a second
    /// place for the price to be wrong, and the wrong one in every storefront but ours.
    static let renewalTerms =
        "Membership renews automatically until cancelled. "
        + "Cancel any time in your Apple Account settings."

    /// Replaces the price rows when StoreKit has no products. **The primary action is hidden, not
    /// disabled**, and this is the ordinary state rather than an error: `api-contract.md` §37a
    /// records that no subscription product exists in App Store Connect and no sandbox transaction
    /// has ever been made.
    static let productsUnavailable =
        "Membership isn't open yet. The daily question is, and everything you write is yours "
        + "either way."

    // MARK: - 3 · The two weeks

    enum TrialWelcome {
        static let title = "Two weeks, everything open."
        static let body =
            "No card, nothing to cancel. After two weeks the daily question keeps going, free, "
            + "and the missions become part of membership."
        static let action = "Start"
    }

    /// The one notice, on the first Today after the trial ends. Shown once and never again.
    ///
    /// **Two actions, not one.** `design-system.md` specifies a `Notice` with a single terracotta
    /// Dismiss; the copy file and the approved design both give this one an opener as well. The
    /// design resolves the tension rather than ignoring it: *"I put the membership action first in
    /// `terracottaDeep` semibold and `Dismiss` beside it in plain `inkMuted` — so the row still has
    /// exactly one thing that looks like an action."*
    static let postTrialNotice =
        "Your two weeks are up. The daily question keeps going, free, forever. The missions are "
        + "part of membership whenever you want them."
    static let postTrialOpen = "See what's included"
    static let postTrialDismiss = "Dismiss"

    // MARK: - The Settings membership card (phase 144)

    /// **Every string the Membership card in Settings can put in front of a parent**, approved by
    /// the owner on Sep 3, 2026 from rendered mockups — `docs/design/membership-card-redesign.md`
    /// §4 is the table, and `free-tier-copy.md` Proposed additions §9 is the record.
    ///
    /// The card is a receipt: a `SettingsCardHeader` whose headline names what the household is
    /// on and whose detail carries the one dated fact the server sent, then only the rows that can
    /// change that answer. **The dated templates carry a literal `{date}`**, the trial's carries
    /// `{days}` too, and `render(_:date:days:)` substitutes them — a template is a `String` so it
    /// sits in `allUserVisibleStrings` and is scanned like every other, and no constant here holds
    /// a digit.
    ///
    /// **The day count is the owner overruling rule 1 for this one surface** — *"I like the date
    /// count but both is good idea"*, Sep 3, 2026 — and it is the server's number
    /// (`trial_days_left`), never arithmetic on this device. The date beside it is the server's
    /// instant formatted, never compared. `free-tier-copy.md` records the amendment.
    ///
    /// **Four of the phase-112 answers this replaces**: `Subscribed` (the headline is the plan
    /// now), `Everything open` (the owner's own complaint — it named neither the trial nor its
    /// end), and `Free` and `—`, which survive under the same names.
    enum Card {
        // The headline: what the household is on, in a noun.
        static let trial = "Free trial"
        static let free = "Free"
        static let annual = "Annual membership"
        static let monthly = "Monthly membership"
        /// `plan` null or unrecognised, or `access: subscribed` with no receipt and no grant behind
        /// it. Claims neither a cadence nor Apple's word.
        static let membership = "Membership"
        static let complimentary = "Complimentary membership"
        /// The server has not answered, or answered in a word this build does not know. Not
        /// knowing is a different answer from `Free`, and the detail under it says which.
        static let unknown = "—"

        // The detail under the headline.
        static let trialDetail = "{days} days left, until {date}. No card, nothing to cancel."
        /// Spelled out rather than `1 day left`, so no template carries a digit and the singular
        /// reads as a sentence rather than a counter reaching zero.
        static let trialDetailLastDay = "One day left, until {date}. No card, nothing to cancel."
        static let trialDetailDateOnly = "Until {date}. No card, nothing to cancel."
        static let trialDetailNoDate = "No card, nothing to cancel."
        /// §2's approved title, on a second surface.
        static let freeDetail = "The daily question is always free."
        static let renews = "Renews {date}"
        static let expires = "Expires {date}"
        /// `auto_renew` unknown — the neutral word, true whichever way renewal is set.
        static let paidThrough = "Paid through {date}"
        /// Appended to `paidThrough` when the Manage row is beneath to answer the question it
        /// leaves open.
        static let paidThroughPointer = "Whether it renews is set in the App Store."
        static let otherParent = "Managed by the other parent."
        static let billingRetry =
            "The App Store couldn't take the last payment and will try again. "
            + "Membership carries on in the meantime."
        static let complimentaryDetail =
            "Everything a member has, with nothing to pay and nothing to renew."
        static let complimentaryUntil =
            "Everything a member has, until {date}. After that the daily question keeps going, free."
        /// True while the first read is running and after it has failed — the pure function cannot
        /// tell those apart, so the sentence was written not to need to.
        static let noAnswerYet =
            "The app hasn't heard back from the server yet. It'll check again the next time you "
            + "open it."
        static let unreadable =
            "This version of the app can't read your membership yet. Nothing is held back; an "
            + "update will be able to show it."

        // The rows.
        /// §2's approved subtitle, under *Become a member* for every non-member but the trial.
        static let offerDetail = "Membership is what fills in the rest of the day."
        /// The trial's own, because the header two lines up says the household already has
        /// everything — and because Apple grants no introductory offer, so joining on day three
        /// charges on day three. The row that sends a parent into that charge says so.
        static let offerDetailTrial =
            "Keeps the missions going after the trial. You're charged when you join, not when it ends."
        static let manage = "Manage subscription"
        /// Names the Apple Account the sheet works from, for the invited parent whose sheet is
        /// empty: `is_payer` is null in exactly the two-guardian case, so the words are what carry
        /// it.
        static let manageDetail =
            "Change the plan or cancel in the App Store, from the Apple Account that pays for it."
        /// Apple's manage-subscriptions sheet does not reach a payment field, so the row names
        /// the second place rather than promising the sheet reaches it.
        static let manageDetailRetry = manageDetail + " The payment method is in that account's settings."
        static let restore = "Restore a purchase"
        static let restoreDetail = "If you've paid before and this phone doesn't know it yet."

        static let datePlaceholder = "{date}"
        static let daysPlaceholder = "{days}"

        /// Every constant above, for the guards.
        static var all: [String] {
            [
                trial, free, annual, monthly, membership, complimentary, unknown,
                trialDetail, trialDetailLastDay, trialDetailDateOnly, trialDetailNoDate, freeDetail,
                renews, expires, paidThrough, paidThroughPointer, otherParent, billingRetry,
                complimentaryDetail, complimentaryUntil, noAnswerYet, unreadable,
                offerDetail, offerDetailTrial, manage, manageDetail, manageDetailRetry,
                restore, restoreDetail,
            ]
        }

        /// The templates that carry a `{date}`, so a test can pin that each carries exactly one.
        static var dated: [String] {
            [trialDetail, trialDetailLastDay, trialDetailDateOnly, renews, expires, paidThrough, complimentaryUntil]
        }
    }

    /// `{date}` and `{days}` substituted. **The only place a rendered digit can enter this
    /// surface**, and both values are the server's: the date is its instant formatted, the count
    /// is its `trial_days_left`. Nothing here reads a clock.
    static func render(_ template: String, date: String? = nil, days: Int? = nil) -> String {
        var rendered = template
        if let date {
            rendered = rendered.replacingOccurrences(of: Card.datePlaceholder, with: date)
        }
        if let days {
            rendered = rendered.replacingOccurrences(of: Card.daysPlaceholder, with: String(days))
        }
        return rendered
    }

    // MARK: - 4 · Strings that must not appear anywhere

    /// The copy file keeps this list explicit *"so a review can grep for them"*, and
    /// `MembershipCopyTests` does exactly that.
    ///
    /// `Locked` is banned **as a user-visible label only** — the file says so in terms: *"the visual
    /// state may still be called locked in code"*, which is why `LockedPromptCard` and `LockedSlot`
    /// keep their names.
    static let bannedPhrases = [
        "Unlock", "Upgrade", "Premium", "Pro",
        "Free trial ending", "Don't lose", "You've missed",
        "Limited time", "Only X left", "Your archive will be", "Members only",
    ]

    /// Whether `string` contains `phrase`, by the rule the ban actually means.
    ///
    /// **Here rather than in the test, and that is the point.** The test previously carried its own
    /// copy of this matching logic *and* a break-test that planted phrases into strings — so the
    /// break-test proved the **test's** copy could match, not that the guard could. Two copies of a
    /// rule is one rule and one decoration.
    ///
    /// `Pro` is matched as a whole word so it does not fire on "**pro**mpt"; `Only X left` is a
    /// shape rather than a literal.
    static func contains(_ phrase: String, in string: String) -> Bool {
        // **Apostrophes are normalised before matching.** Half these phrases contain one — "Don't
        // lose", "You've missed" — and prose that reaches a screen may carry either the straight
        // `'` or the typographic `\u{2019}`. A ban that only recognises one spelling of the same
        // word is a ban somebody evades by accident.
        func flatten(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        }

        let haystack = flatten(string)
        switch flatten(phrase) {
        case "pro":
            return haystack.split(whereSeparator: { !$0.isLetter }).contains("pro")
        case "only x left":
            return haystack.contains("only") && haystack.contains("left")
        default:
            return haystack.contains(flatten(phrase))
        }
    }

    /// **Every string this phase can put in front of a parent**, so the guard has something to run
    /// against rather than a list a test happens to duplicate.
    ///
    /// A constant nothing reads is not a guard, it is cover — and a doc comment claiming enforcement
    /// that nobody runs is worse than no comment. `MembershipTests` iterates exactly this.
    static var allUserVisibleStrings: [String] {
        var strings = [
            lockedFooter, lockedHint,
            title, subtitle, addsLabel, freeLabel,
            primaryAction, mediaIncluded, notNow, notNowHint, footnote, renewalTerms,
            productsUnavailable,
            TrialWelcome.title, TrialWelcome.body, TrialWelcome.action,
            postTrialNotice, postTrialOpen, postTrialDismiss,
            membershipMissingAction,
        ]
        strings += Card.all
        strings += adds
        strings += stayFree
        for slot in [Slot.question, .mission, .missionB, .weekly, .monthly, .letter,
                     .unknown("seasonal")] {
            strings.append(lockedEyebrow(slot))
            strings.append(lockedBody(slot))
        }
        return strings
    }

    // MARK: - Not shipped

    /// **Deliberately unused, and kept to name a gap rather than fill it.**
    ///
    /// The design's artboard `1f` — the one-quiet-row alternative — needed a one-line form of the
    /// lock and had none, and flagged it: *"Both strings are verbatim (§1 footer, §3 notice
    /// action). Neither was written for this row. A one-line form belongs in the file — proposed,
    /// not drawn: `Missions are included with membership.`"*
    ///
    /// The owner then rejected `1f` outright — *"we want to show the locked missions always"* — so
    /// the row is not built and this string is not rendered anywhere. It is recorded here, and
    /// under *Proposed additions* in the copy file, because the next person to reach for a compact
    /// lock should find the proposal rather than write a second one.
    static let membershipMissingAction = "Missions are included with membership."
}
