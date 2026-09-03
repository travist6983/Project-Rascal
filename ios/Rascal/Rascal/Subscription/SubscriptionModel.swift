import Foundation

/// What the paywall and the Settings row are looking at.
///
/// **The household's tier is not this type's opinion.** Everything about entitlement on this
/// screen is `household`, which is a `FamilySummary` from `GET /v1/families/me` and nothing else.
/// The purchase machinery below can reach `.confirming` and `.late`; the only thing that can
/// reach `.subscribed` is the server having said so.
@MainActor
@Observable
final class SubscriptionModel {

    /// What can be offered. **`.ready` is the only case carrying a `familyID`, and that is the
    /// mechanism rather than a coincidence:** a purchase cannot be started from any other state,
    /// so there is no branch in which `appAccountToken` could be nil, substituted or invented.
    enum Phase: Equatable {
        case loading
        case ready(SubscriptionOffer, familyID: UUID)
        /// Products or the household did not arrive. **Never a blank paywall** — an empty product
        /// list looks exactly like a network failure and must not render as a screen with nothing
        /// on it.
        case unavailable(Unavailable)
    }

    /// **Why there is nothing to offer, because the two reasons are not the same thing.**
    ///
    /// This was one `String` and that collapsed a calm, permanent fact into the same shape as a
    /// transient failure. It matters now that phase 108 makes `.products` the *ordinary* state:
    /// `api-contract.md` §37a records that no subscription product exists in App Store Connect and
    /// no sandbox transaction has ever been made, so every device today lands on `.products`.
    ///
    /// Rendering the household failure with the same calm sentence — *"Membership isn't open yet"* —
    /// would be a lie told on one dropped request. They are separate cases so the sheet can say
    /// something true about each, and so a retry is offered only where retrying can help.
    enum Unavailable: Equatable {
        /// StoreKit returned fewer than both products, or could not be reached. **Expected.** Renders
        /// the copy file's `Notice` and hides the primary action; no retry, because there is nothing
        /// the parent can do and a button that changes nothing teaches them the screen is decorative.
        case products
        /// `GET /v1/families/me` did not answer. **A real failure**, and the one case that keeps a
        /// retry — without the household there is no `appAccountToken`, so a buy button here would
        /// mint a permanently unattributable receipt.
        case household(String)
    }

    /// `nonisolated` since phase 140: `MembershipPresentation` compares two of these in a pure,
    /// nonisolated function, and a main-actor-isolated `Equatable` is an error there in Swift 6.
    /// Every payload is `Sendable` (a `String` at most), so nothing is lost.
    nonisolated enum PurchasePhase: Equatable {
        case idle
        case purchasing
        /// Charged, and the server has not been told yet. See `EntitlementConfirmation`.
        case confirming
        /// The server reported `subscribed`. **The only state that means subscribed.**
        case subscribed
        /// The purchase succeeded and the confirmation window closed without it landing.
        /// **Not a failure. Nothing further is required of the parent, and nothing is retried.**
        case late
        /// Ask to Buy or an SCA challenge. Not a failure either.
        case awaitingApproval
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var purchase: PurchasePhase = .idle
    /// The server's answer about this household, and the only thing on this screen entitled to
    /// say whether it is subscribed. Nil until `GET /v1/families/me` has succeeded this session.
    private(set) var household: FamilySummary?
    /// Annual is preselected, per D1. Monthly is not hidden and not shamed.
    var plan: SubscriptionPlan = .annual
    private(set) var isRestoring = false
    /// A restore that found nothing to restore — or, since phase 143, a receipt the server says is
    /// another household's — said as a sentence rather than an alert. Rendered by both surfaces.
    private(set) var notice: String?

    /// A restore that **did** find one, said as a sentence rather than as nothing at all.
    ///
    /// **Deliberately not `notice`, and that is a shipped test rather than a preference.**
    /// `SubscriptionTests.aSuccessfulRestoreIsNotSilent` asserts `notice == nil` after a
    /// successful restore: `notice` is the channel for a run that came back empty or was refused.
    /// Writing a success into it would make one string mean two opposite things.
    ///
    /// **Rendered by the Membership card, and by nothing else.** The paywall answers a found
    /// entitlement by dismissing — there is no sheet left to put a sentence on. Settings
    /// deliberately stays where it is, which is the one difference between the two surfaces, and
    /// a row that spins and then silently stops is indistinguishable from one that failed.
    private(set) var restoreConfirmation: String?

    /// **`GET /v1/families/me`, and there is deliberately no second way to ask.**
    ///
    /// A closure rather than the `APIClient` itself so the confirmation window can be driven in a
    /// test — the server reporting `free` three times and then `subscribed` is the case that
    /// matters and it cannot be staged against a real client. The convenience `init(api:)` below
    /// is what every production call site uses, and it supplies `api.family()`: the same route,
    /// the same type, the same authority that phase 61 already reads.
    private let readHousehold: @Sendable () async throws -> FamilySummary
    /// **`POST /v1/families/me/transactions`, and the second door onto a subscribed household**
    /// (phase 140). Given the JWS the store holds for the current entitlement, the server verifies
    /// it and answers with the household — the same document `readHousehold` returns, which is
    /// the only thing that may settle `purchase` to `.subscribed`. A throw is not a verdict — a
    /// server that predates the route, a dropped connection and a refused JWS all leave the poll
    /// to do what it did before this existed — **with one exception since phase 143**: a
    /// `409 conflict`, which says the receipt is another household's. See `submitCurrentEntitlement`.
    private let submitTransaction: @Sendable (String) async throws -> FamilySummary
    private let store: any SubscriptionPurchasing
    /// Injected so the confirmation window can be exercised without waiting 63 seconds.
    private let confirmationSchedule: [Duration]
    private let confirmationSleep: @Sendable (Duration) async throws -> Void

    /// How long the whole confirmation window gets before the sheet stops spinning and says
    /// something true.
    ///
    /// **Two minutes, against a schedule that sums to 63 seconds.** The gap is deliberate: it is
    /// the read budget the schedule never had. Ten reads on a slow-but-working connection can
    /// legitimately cost twenty or thirty seconds between them, and cutting a confirmation off at
    /// 63s flat would turn "slow" into "late" for parents whose purchase was about to land. Two
    /// minutes is generous to that case and still bounded, which the current behaviour is not.
    private let confirmationDeadline: Duration

    /// **Its own sleeper, deliberately not `confirmationSleep` — the same trap `offerSleep`
    /// documents below, and it is the same one twice.**
    ///
    /// The suite stubs `confirmationSleep` to `{ _ in }` so a test is not waiting a minute for the
    /// schedule. A deadline routed through that clock resolves *instantly*, wins every race
    /// against the read, and settles every confirmation in the suite to `.late` — which is exactly
    /// what reusing that parameter for the offer timeout did, and why there are three clocks here
    /// rather than one.
    private let confirmationDeadlineSleep: @Sendable (Duration) async throws -> Void

    /// How long a restore may hold the Settings row before it stops spinning and says something
    /// true. **Shorter than a purchase's window**, because nobody has just been charged and a
    /// Settings row cannot spin for two minutes; **longer than the 15-second restore schedule**,
    /// because that schedule bounds its sleeps and never bounded its reads. Runs on
    /// `confirmationDeadlineSleep`, the clock the suite does not collapse.
    private let restoreDeadline: Duration

    /// How long `Product.products(for:)` gets before the sheet says there is nothing to offer.
    ///
    /// Ten seconds: long enough that a slow-but-working App Store call still lands, short enough
    /// that a parent who opened this to read what membership includes is not held on a spinner. See
    /// `loadOffer()` for why a bound exists at all.
    private let offerTimeout: Duration

    /// **Its own sleeper, deliberately not `confirmationSleep`.**
    ///
    /// Reusing that one was a real bug and it broke five existing tests: `makeModel` stubs
    /// `confirmationSleep` to `{ _ in }` so the confirmation window can be driven without waiting a
    /// minute — which made the timeout resolve *instantly*, win every race against the store, and
    /// turn every load in the suite into `.unavailable(.products)`. Two different clocks were being
    /// injected through one parameter, and the tests were right to notice.
    private let offerSleep: @Sendable (Duration) async throws -> Void
    /// True only for a preview-constructed model. Guards `load`, which the views call from a
    /// `.task` — without it the parked phase is replaced by whatever the machine's connectivity
    /// produced. Same shape as `GuardiansModel`.
    private var isPreview = false
    /// Guards `load` against re-entry.
    ///
    /// **Not hypothetical: it is the normal path.** `SubscriptionSection` and `PaywallSheet` both
    /// call `load()` from a `.task`, and the paywall is presented *by* the section — so with the
    /// sheet up, both are alive and both load. Without this, two concurrent loads race to assign
    /// `phase`, and a transient failure in the later one replaces a working paywall with a retry.
    private var isLoading = false

    /// Which `load()` is allowed to speak.
    ///
    /// **The mutex alone was not enough once the deadline existed.** `isLoading` is released by a
    /// `defer`, so a `load()` suspended on a hung store held it for the whole hang — the deadline
    /// freed the *screen* and left the *model* stuck, and every retry from a locked card or from
    /// Settings early-returned in silence. Any hang longer than the deadline opened a window where
    /// membership was unbuyable and nothing a parent did was even attempted.
    ///
    /// Releasing the mutex from the deadline fixes that and creates a second problem: the abandoned
    /// load is still running and will eventually assign `phase`, clobbering whatever a newer one
    /// found. This is what stops it — a late completion may only write if it is still the current
    /// one. That preserves phase 37b's reason for the mutex (two screens loading at once must not
    /// let a transient failure replace a working paywall) while making it impossible to wedge.
    private var loadGeneration = 0
    /// `restore()`'s counterpart to `loadGeneration`, for the same reason: the deadline below
    /// releases the row while the run is still out, a second tap may start a second run, and the
    /// first run's return must not clear a flag — or write a sentence — that now belongs to the
    /// second. Only the run whose number this still is may speak for the row.
    private var restoreGeneration = 0

    init(
        readHousehold: @escaping @Sendable () async throws -> FamilySummary,
        submitTransaction: @escaping @Sendable (String) async throws -> FamilySummary = { _ in
            throw CancellationError()
        },
        store: any SubscriptionPurchasing = SubscriptionStore(),
        confirmationSchedule: [Duration] = EntitlementConfirmation.schedule,
        confirmationSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        confirmationDeadline: Duration = .seconds(120),
        confirmationDeadlineSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        restoreDeadline: Duration = .seconds(45),
        offerTimeout: Duration = .seconds(10),
        offerSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.readHousehold = readHousehold
        self.submitTransaction = submitTransaction
        self.store = store
        self.confirmationSchedule = confirmationSchedule
        self.confirmationSleep = confirmationSleep
        self.confirmationDeadline = confirmationDeadline
        self.confirmationDeadlineSleep = confirmationDeadlineSleep
        self.restoreDeadline = restoreDeadline
        self.offerTimeout = offerTimeout
        self.offerSleep = offerSleep
    }

    convenience init(api: APIClient, store: any SubscriptionPurchasing = SubscriptionStore()) {
        self.init(
            readHousehold: { try await api.family() },
            submitTransaction: { try await api.submitTransaction($0) },
            store: store
        )
    }

    #if DEBUG
        /// A model parked in one state, for previews and for rendering.
        ///
        /// **Every state is reachable from here, including `.ready`** — which was not true when
        /// this was written and is the whole point of the change that made it true. A
        /// `SubscriptionOffer` used to hold two `Product`s, and nothing but StoreKit can make one,
        /// so the full paywall could only be seen with a working store. It now holds `OfferedPlan`
        /// values, so `SubscriptionScreenshotTests` builds the finished paywall — trial, computed
        /// saving and all — at every accessibility size, with no store, no session and no taps.
        /// `isRestoring` and `notice` are `private(set)` and are therefore unreachable from a
        /// preview or a screenshot test without this. Both are additive with defaults, so no
        /// existing call site changes — and they are what makes the **restore** sub-states
        /// renderable without a store, which is the same argument that put `household` here.
        convenience init(
            previewing phase: Phase,
            household: FamilySummary? = nil,
            purchase: PurchasePhase = .idle,
            isRestoring: Bool = false,
            notice: String? = nil,
            restoreConfirmation: String? = nil
        ) {
            self.init(readHousehold: { throw CancellationError() })
            self.isPreview = true
            self.phase = phase
            self.household = household
            self.purchase = purchase
            self.isRestoring = isRestoring
            self.notice = notice
            self.restoreConfirmation = restoreConfirmation
        }
    #endif

    // MARK: What the view asks

    var offer: SubscriptionOffer? {
        if case .ready(let offer, _) = phase { return offer }
        return nil
    }

    var selectedPlan: OfferedPlan? { offer?.plan(for: plan) }

    /// **False whenever there is no household to attribute a purchase to**, which is what makes
    /// "the button is disabled when `family_id` is unknown" structural rather than a check
    /// somebody has to remember to write at the call site.
    ///
    /// Also false during and after a purchase: a second `purchase()` for one intent is the worst
    /// outcome available on this screen, and a timeout is explicitly not grounds for another.
    var canBuy: Bool {
        guard case .ready = phase else { return false }
        // **A household the server already calls subscribed is not offered a purchase.** In one
        // subscription group a second buy is a plan change rather than a second subscription, so
        // this would not double-charge — but it would take a parent who is already paying through
        // a checkout they did not need, and nothing else on this screen was stopping it.
        //
        // **`isMember`, not `isSubscribed`, since phase 141.** A household entitled by an admin
        // grant reads `tier: "free"`, so keyed on `tier` this offered — and would have completed —
        // an Apple checkout for a membership the household already had in full.
        if household?.isMember == true { return false }
        switch purchase {
        case .idle, .failed: return true
        case .purchasing, .confirming, .subscribed, .late, .awaitingApproval: return false
        }
    }

    /// D1's saving, computed from the two prices. Nil when there are no products to compare, so
    /// a failed load renders neither this nor the trial rather than half a claim.
    var savingLine: String? { offer.flatMap(AnnualSaving.describe) }

    // MARK: Loading

    /// Both halves, concurrently, because they fail independently and the parent should be told
    /// which one is missing rather than "something went wrong".
    func load() async {
        if isPreview { return }
        guard !isLoading else { return }
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        // Only release the mutex if a newer load has not already taken it. Without the check, an
        // abandoned load returning after the deadline would clear a flag belonging to somebody else.
        defer { if generation == loadGeneration { isLoading = false } }
        // **`notice` is one string shared by the Membership card and the paywall sheet**, and
        // `noticeDismissed()` had no caller anywhere — so a restore's "nothing has arrived yet"
        // followed the parent onto the paywall and sat under the buy button indefinitely. Opening
        // either surface clears it. `restoreConfirmation` goes with it, for the same reason:
        // yesterday's "your membership is here" is not a statement about this visit.
        //
        // **Except the one sentence that is not about a past run** (phase 143). *Attached to a
        // different account* describes a standing fact about the receipt on this Apple Account,
        // true until the parent signs in elsewhere or buys under another one — and it has to
        // survive an appearance, because the visit that reads it *is* an appearance: one model is
        // shared by Today and Settings (`RootView`), a purchase from a locked card leaves the
        // parent on the board when the sheet dismisses itself, and the Membership card they then
        // open calls this from its `.task`. Clearing it here erased the explanation before it
        // rendered. It still goes when the household becomes a member (`refreshHousehold()`, the
        // publish below), when a purchase or restore starts, or on `noticeDismissed()`.
        if notice != Self.subscriptionOnAnotherAccount { notice = nil }
        restoreConfirmation = nil
        if case .ready = phase {} else { phase = .loading }

        // **The spinner's terminal state, and it is a deadline on the *screen* rather than a race
        // against the store.**
        //
        // `Product.products(for:)` has no timeout of its own, and the call under it —
        // `isEligibleForIntroOffer(for:)` — is `async` and **not throwing**, so it cannot report
        // cancellation and nothing can make it stop. A hung StoreKit call therefore cannot be
        // cancelled; it can only be stopped from holding the screen.
        //
        // Two racing implementations were tried and both were worse. `withTaskGroup` does not
        // return until every child finishes — `cancelAll()` only *requests* — so it bounded
        // nothing; measured, a 200ms sleeper racing a 3s non-cooperative child returned after
        // **3.20s**. Racing two unstructured tasks through a one-shot continuation worked in
        // isolation and could not be tested honestly: it depends on a `Task.sleep` continuation
        // winning against a `DispatchQueue` timer, which stops being true the moment the
        // cooperative pool is busy.
        //
        // This does the one thing the requirement actually asks for: **it moves `phase` off
        // `.loading` on a deadline**, so the sheet stops spinning and says something true. The
        // request is left alone to finish or not; if the products do arrive late, the `switch`
        // below is still ahead of it and renders them.
        let deadline = Task { [weak self, offerTimeout, offerSleep] in
            try? await offerSleep(offerTimeout)
            guard let self, generation == self.loadGeneration else { return }
            // **Frees the model, not only the screen.** Releasing this is what lets a parent who
            // reopens the sheet actually get another attempt instead of a silent no-op; the
            // generation guard below is what stops this abandoned load from overwriting it.
            self.isLoading = false
            if case .loading = self.phase { self.phase = .unavailable(.products) }
        }
        defer { deadline.cancel() }

        // Both halves start together and are awaited separately, so the household can be published
        // the moment it lands rather than waiting on the store.
        async let householdResult = loadHousehold()
        async let offerResult = loadOffer()

        let family = await householdResult
        // **Published here, not at the join, and that is what closes the stomp.**
        //
        // The store can hang for as long as it likes; `refreshHousehold()` and `restore()` can both
        // publish a newer household while it does — driven by `Transaction.updates` and by a
        // foreground, from two different screens. If this load held its `t=0` summary until the
        // offer arrived, it would then write that stale answer over the newer one, and `household`
        // is exactly what `canBuy` and the Settings row read.
        //
        // The generation check still applies: a load the deadline gave up on before the household
        // even arrived has nothing worth publishing.
        if generation == loadGeneration, let family {
            household = family
            // **Reconciled here as well as in the prologue, and the prologue is not enough.**
            // Both channels are cleared before the `await` above; this publish happens after it, so
            // a `restore()` that completes inside that window sets `restoreConfirmation` and then
            // has this line write a household read that began *before* the restore proved anything.
            // The card would render *Free* with "Found it. Your membership is active." underneath.
            //
            // Stated as the invariant rather than as a race fix, because that is what it is: **a
            // channel must never contradict the household published beside it.** Every other writer
            // enforces it — `refreshHousehold()` on each transition, `confirm()` unconditionally,
            // `restore()` in its prologue — and this was the one publish site that enforced nothing.
            if family.isSubscribed { notice = nil } else { restoreConfirmation = nil }

            // **A load must settle a purchase the server has since answered, exactly as
            // `refreshHousehold()` does.**
            //
            // Only `refreshHousehold()`, `restore()` and `confirm()` carried this repair, and
            // `load()` is the call the sheet makes on every `.task` — so reopening the sheet after
            // a failed purchase published a *subscribed* household while leaving `purchase` on
            // `.failed`. That pair is what let an enabled "Become a member" render for somebody who
            // already had one, with `buy()` returning at its own `guard canBuy`. Reconciling here
            // removes the state rather than guarding one rendering of it.
            //
            // `.failed` is in the list for the reason `refreshHousehold()` states: a purchase that
            // threw locally and turned out to have gone through must stop saying it failed the
            // moment the server disagrees.
            if family.isSubscribed, purchase != .idle, purchase != .subscribed {
                purchase = .subscribed
            }
        }

        let offer = await offerResult

        // **A load the deadline gave up on does not get to move the screen.** By the time a hung
        // store finally answers, a newer `load()` may have run and found the truth; last writer wins
        // would make that the stale one.
        guard generation == loadGeneration else { return }

        switch (family, offer) {
        case (let family?, let offer?):
            phase = .ready(offer, familyID: family.familyId)
        case (nil, _):
            // Without the household there is no `appAccountToken`, so there is nothing safe to
            // offer — a buy button here would mint an unattributable receipt.
            phase = .unavailable(
                .household("We couldn't reach your household just now, so there's nothing to show yet.")
            )
        case (_, nil):
            phase = .unavailable(.products)
        }
    }

    private func loadHousehold() async -> FamilySummary? {
        try? await readHousehold()
    }

    /// The store's answer, unbounded — see `load()` for the deadline that makes that safe.
    private func loadOffer() async -> SubscriptionOffer? {
        try? await store.loadOffer()
    }

    /// Re-read the household alone — the foreground re-check, and what the transaction listener
    /// calls. Never touches `purchase`, except to close a confirmation the server has since
    /// answered.
    /// Returns **whether the server actually answered.** A caller that draws a conclusion from
    /// `household` afterwards has to know the difference between *the read said this* and *the read
    /// failed and this is what we already had* — see `restore()`'s `.late` branch, where announcing
    /// a membership off a stale summary would tell a parent their lapsed subscription is active.
    @discardableResult
    func refreshHousehold() async -> Bool {
        if isPreview { return false }
        guard let family = try? await readHousehold() else { return false }
        let wasSubscribed = household?.isSubscribed == true
        household = family
        // **A confirmation is about the household it was written for.** `restoreConfirmation` says
        // *the membership is active*; if a later read says it is not — a refund arriving on
        // `Transaction.updates`, or a lapse picked up on foreground — leaving the sentence up
        // makes the card contradict itself, with the stale half being the reassuring one. Cleared
        // only on the transition, so an ordinary re-read that confirms the same membership does
        // not wipe a sentence the parent is still reading.
        //
        // **`load()` clears it unconditionally and that is the other half, deliberately.** Opening
        // either surface is a new visit, and this method's own retry branch below calls `load()`
        // when the household read had previously failed — so a confirmation can also disappear
        // there. Both are wanted; the guard here covers the case where no load happens at all,
        // which is the ordinary foreground.
        if wasSubscribed, !family.isSubscribed { restoreConfirmation = nil }
        // **And the mirror of it, which round 3 found after round 2 fixed only one direction.**
        // `notice` says *nothing has arrived yet*. If a later read says it has — the webhook landed
        // a moment after the window closed, which is the ordinary shape of a late confirmation —
        // then the card would render "Everything open" as its status with "Nothing has arrived yet"
        // underneath it. Same defect as above, same transition, opposite sign.
        if !wasSubscribed, family.isSubscribed { notice = nil }
        // Every non-idle state the server can settle. **`.failed` is in the list deliberately**:
        // a purchase that threw locally and then turned out to have gone through — the classic
        // shape being a timeout on Apple's side that still charged — must stop telling the parent
        // it failed the moment the server says otherwise.
        if family.isSubscribed, purchase != .idle, purchase != .subscribed {
            purchase = .subscribed
        }
        // **Only the household failure retries on foreground.**
        //
        // This was `if case .unavailable`, which was right while unavailable meant "something went
        // wrong just now". Since phase 108, `.products` is the *ordinary* state on every device —
        // no subscription product exists in App Store Connect — so that branch would re-run a full
        // `Product.products(for:)` every single time the app came to the foreground, for a result
        // that is not going to change until someone creates a product. `.household` is a genuine
        // transient failure and does retry.
        if case .unavailable(.household) = phase {
            await load()
        }
        return true
    }

    /// A verified transaction landed on `Transaction.updates` while this screen was open — see
    /// `SubscriptionCenter.revision`.
    ///
    /// **An Ask-to-Buy approval re-enters the confirmation window rather than jumping to
    /// subscribed**, because Apple has only just been told and the server has not been at all.
    /// It is the same gap a fresh purchase has, arriving by a different door.
    func transactionArrived() async {
        if purchase == .awaitingApproval {
            await confirm()
        } else {
            await refreshHousehold()
        }
    }

    // MARK: Buying

    func buy() async {
        guard canBuy, case .ready(_, let familyID) = phase else { return }
        let chosen = plan

        purchase = .purchasing
        notice = nil

        let outcome: PurchaseOutcome
        do {
            outcome = try await store.purchase(chosen, familyID: familyID)
        } catch let error as SubscriptionStoreError {
            settleFailure(error.userMessage)
            return
        } catch {
            settleFailure(error.localizedDescription)
            return
        }

        switch outcome {
        case .cancelled:
            // Silent. No error, no toast, no "are you sure?".
            purchase = .idle
        case .pending:
            purchase = .awaitingApproval
        case .purchased:
            await confirm()
        }
    }

    /// The confirmation gap. **The app does not become subscribed here — it asks until the server
    /// **A throw from the store never overwrites an entitlement the server has already granted.**
    ///
    /// `buy()` awaits `store.purchase` on the main actor, and that await is a suspension point
    /// other main-actor work interleaves with. The sheet's own `scenePhase` handler calls
    /// `refreshHousehold()` on every foreground — which is exactly what happens when the parent
    /// leaves the app for the App Store's payment sheet and comes back. If that read returns a
    /// subscribed household, it settles `purchase` to `.subscribed`; a moment later the awaited
    /// call throws, and the unguarded `purchase = .failed` wrote straight over it.
    ///
    /// The parent is then told the purchase failed, by a device that has already been told
    /// otherwise by the server — the exact inversion `refreshHousehold()`'s own comment forbids:
    /// *"a purchase that threw locally and then turned out to have gone through … must stop
    /// telling the parent it failed the moment the server says otherwise."* This is the same rule
    /// facing the other way, and it is the last of the four writers to `household` to learn it.
    private func settleFailure(_ message: String) {
        guard household?.isSubscribed != true else {
            purchase = .subscribed
            return
        }
        purchase = .failed(message)
    }

    /// says so, or stops asking and says something true.**
    /// Internal rather than private so the confirmation window can be driven directly in a test.
    /// It is not a call site any view has: `buy()` and `transactionArrived()` are the two doors.
    func confirm() async {
        // **Re-entry guard, and it is the normal path too.** `SubscriptionSection` and
        // `PaywallSheet` both watch `SubscriptionCenter.revision` and both call
        // `transactionArrived()`; with the sheet up, one Ask-to-Buy approval reaches the model
        // twice. Two polling loops against one `purchase` would race to a terminal state, and
        // which one won would decide whether the parent saw "subscribed" or "being confirmed".
        guard purchase != .confirming else { return }
        purchase = .confirming

        // **The spinner's terminal state, and it is a deadline on the *screen* rather than a bound
        // on the poll — the same shape as `load()`'s, for the same reason.**
        //
        // `EntitlementConfirmation.poll` describes itself as *"63 seconds across ten reads"* and
        // *"Only the schedule ends it."* That is true of its **sleeps** and false of its **reads**:
        // the loop awaits `read()` with no bound of its own, so the honest worst case is 63s plus
        // ten household reads at whatever `URLSession` allows — around eleven minutes with the
        // default request timeout, and unbounded if a read never answers at all. Every repair in
        // this model is downstream of a poll that has not returned, so none of them can reach a
        // `purchase` stuck on `.confirming`, and the parent sits under "Finishing up" indefinitely.
        //
        // This does not try to cancel the read. `load()` measured that approach and recorded the
        // result: `withTaskGroup` does not return until every child finishes, `cancelAll()` only
        // *requests*, and a read parked inside a non-cancellable continuation ignores both. So this
        // does the one thing the requirement actually asks for — **it moves `purchase` off
        // `.confirming` on a deadline**, and leaves the read to finish or not. If the server does
        // answer late, the `switch` below is still ahead of it and `.subscribed` still wins.
        let deadline = Task { [weak self, confirmationDeadline, confirmationDeadlineSleep] in
            try? await confirmationDeadlineSleep(confirmationDeadline)
            guard let self, self.purchase == .confirming else { return }
            self.purchase = .late
        }
        defer { deadline.cancel() }

        // **Tell the server first, then ask it** (phase 140). The device holds an Apple-signed
        // transaction for what it just bought; the server can verify that in one round trip and
        // answer with the household, which closes the gap the poll was written for in the common
        // case and closes it *at all* in the case Sep 2, 2026 found — a plan change on an Apple
        // Account already holding the group, which Apple announces as no tier change and which no
        // amount of polling would ever have confirmed. Nothing here decides entitlement: the
        // answer is the household document or it is nothing, and nothing falls through to the poll
        // exactly as before. Still under the deadline above, because a hung request is a hung
        // request whichever door it knocks on.
        switch await submitCurrentEntitlement() {
        case .subscribed(let family) where purchase == .confirming:
            household = family
            purchase = .subscribed
            notice = nil
            return
        case .otherHousehold:
            // **An answer, not a non-answer, and the poll does not run** (phase 143). The server
            // has said whose receipt this is; ten more reads of this household cannot change that,
            // and running them left the parent under "Finishing up" until the deadline with nothing
            // ever saying why.
            settleReceiptElsewhere()
            return
        case .subscribed, .inconclusive:
            break
        }

        let read = self.readHousehold
        let outcome = await EntitlementConfirmation.poll(
            schedule: confirmationSchedule,
            sleep: confirmationSleep,
            read: read
        )
        switch outcome {
        case .subscribed(let family):
            // **The household the poll already proved**, not a second read. Re-reading here could
            // fail and blank a household the app had just confirmed — leaving "You're subscribed"
            // above a Membership row showing an em dash.
            household = family
            purchase = .subscribed
            // **The fourth door onto a subscribed household, and the one the transition guards in
            // `refreshHousehold()` cannot see.** An Ask-to-Buy parent can tap Restore while the
            // approval is outstanding — neither restore control consults `purchase` — get
            // "Nothing has arrived yet", and then have the approval land here. Without this the
            // card renders *Subscribed* with *nothing has arrived* underneath it.
            //
            // Unconditional rather than guarded on a transition: this branch only ever publishes a
            // subscribed household, so any `notice` still standing is stale by construction. There
            // is no ordinary-re-read case here to protect a sentence the parent is still reading.
            notice = nil
        case .late:
            // **Deliberately terminal.** A spinner that never ends is worse than a sentence, and
            // re-running the purchase to fix a display problem would double-charge a parent.
            //
            // **Guarded on `.confirming` now that a deadline can settle this first.** The window
            // closing is not news if something already published a subscribed household — a
            // foreground `refreshHousehold()`, a `load()`, or the deadline above followed by a late
            // `.subscribed`. Writing `.late` unconditionally would take the parent from
            // "You're subscribed" back to "being confirmed", which is the inversion every other
            // writer in this model is guarded against.
            if purchase == .confirming { purchase = .late }
        }
    }

    /// What `POST /v1/families/me/transactions` said, reduced to the three things a caller does
    /// differently about it.
    private enum Submission {
        /// The server verified the receipt and now calls this household subscribed.
        case subscribed(FamilySummary)
        /// **`409 conflict`: the server will not attribute this receipt to the caller's household**
        /// (phase 143) — its `appAccountToken` names another household, or the ledger already holds
        /// it for one. Not a non-answer: the one refusal that names a reason the parent can act on,
        /// and the one the poll can never resolve, because no number of household reads changes
        /// whose receipt it is. (A receipt carrying no token at all is refused the same way on the
        /// server this was written against, and the client cannot tell the two apart — recorded in
        /// phase 143's PR as a contract question, not decided here.)
        case otherHousehold
        /// Everything else: no transaction on the device, a `404` from a server without the route, a
        /// `422`, a dropped connection, a `409` whose body was not the envelope, or a `200` whose
        /// household still reads `free`. *Carry on as before.*
        case inconclusive
    }

    /// Hand the server the transaction the store holds, and say what it made of it.
    ///
    /// **`.subscribed` only if the server now calls the household subscribed**; the route is an
    /// accelerator and a repair, never a dependency, and `.inconclusive` means *carry on as before*
    /// — exactly what every throw meant before phase 143. The one throw lifted out of that bucket is
    /// `APIError.api(code: .conflict)`: from Sep 3, 2026 in production, a parent whose Apple Account
    /// held a subscription bought under another household tapped Buy, Apple said *"You're currently
    /// subscribed to this"*, this returned `nil`, the poll ran to its deadline, and nothing ever said
    /// why. Matched on `code`, never on status or message — messages are copy and will change, and a
    /// `409` with no envelope carries no code and stays inconclusive.
    private func submitCurrentEntitlement() async -> Submission {
        guard let signed = await store.currentEntitlement() else { return .inconclusive }
        do {
            let family = try await submitTransaction(signed)
            return family.isSubscribed ? .subscribed(family) : .inconclusive
        } catch let error as APIError where error.code == .conflict {
            return .otherHousehold
        } catch {
            return .inconclusive
        }
    }

    /// The server said the receipt is another household's. **One writer for both doors** — the
    /// purchase's confirmation and a restore — so the two cannot drift into saying different things.
    ///
    /// **The wait ends on an answer, whatever the household says.** `.confirming` must not spin to
    /// the deadline once the server has answered, and `.late` (*"being confirmed"*) must not stand
    /// above a sentence saying it will not be. It moves to `.idle` rather than `.failed`: Apple did
    /// not refuse the purchase, and the sentence offers a purchase under a different Apple Account,
    /// so one must be possible. `.subscribed` is not touched — every writer that publishes a
    /// subscribed household settles `purchase` to it, and a refused receipt does not take that back.
    ///
    /// **The sentence, though, defers to the household**, as every channel here does: a foreground
    /// read can publish a member household while the submission is in flight — another guardian's
    /// purchase, a grant — and *attached to a different account* under a card reading *Subscribed*
    /// is the contradiction the restore branches already refuse to print. `notice` is the channel
    /// because it is the one both surfaces already render.
    private func settleReceiptElsewhere() {
        if purchase == .confirming || purchase == .late { purchase = .idle }
        guard household?.isMember != true else { return }
        notice = Self.subscriptionOnAnotherAccount
    }

    // MARK: Restore

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        restoreGeneration += 1
        let generation = restoreGeneration
        notice = nil
        // Cleared with `notice`, for the same reason: a second tap must not read as a result
        // until this run has one. At most one of the two is set by the time this returns.
        restoreConfirmation = nil
        // Only release the row if a newer run has not taken it — `load()`'s rule, for the same
        // reason: an abandoned run returning after the deadline would clear a flag belonging to
        // somebody else, and re-enable both restore controls under a run still in flight.
        defer { if generation == restoreGeneration { isRestoring = false } }

        // **The row's terminal state — a deadline on the screen, not a bound on the read.** The
        // same shape as `confirm()`'s, added by phase 141 for the reason phase 138 recorded and
        // left standing: `AppStore.sync()`, the four reads of the restore schedule and the fifth
        // in the `.late` branch below are all unbounded, and a read that never answers parks
        // `isRestoring` — which spins the Settings row and disables both restore controls — for
        // as long as that read takes. Nothing here cancels the read; this moves `isRestoring`
        // off `true` on a deadline and leaves the run to finish or not. A run that finishes late
        // still writes its answer, exactly as a late `.subscribed` still wins in `confirm()`, and
        // clears the sentence the deadline left.
        //
        // The sentence is the `.late` branch's own, reproduced rather than authored: the window
        // closing without an answer is the case it was written for — **and it carries that
        // branch's guard too.** A household the card already calls a member gets a released row
        // and silence, exactly as the `.late` branch decides: *nothing has arrived yet* under a
        // status row reading *Subscribed* is the same contradiction, inverted.
        let deadline = Task { [weak self, restoreDeadline, confirmationDeadlineSleep] in
            try? await confirmationDeadlineSleep(restoreDeadline)
            guard let self, generation == self.restoreGeneration, self.isRestoring else { return }
            self.isRestoring = false
            if self.restoreConfirmation == nil, self.notice == nil,
               self.household?.isMember != true {
                self.notice = Self.restoreNothingYet
            }
        }
        defer { deadline.cancel() }

        do {
            try await store.restore()
        } catch let error as SubscriptionStoreError {
            // A refusal that lands after the deadline released the row and a second run took it
            // is about a run the parent is no longer watching; it does not get to speak for the
            // one they are.
            if generation == restoreGeneration { notice = error.userMessage }
            return
        } catch {
            if generation == restoreGeneration { notice = error.localizedDescription }
            return
        }

        // **`AppStore.sync()` returning is not the server knowing.** It is the same gap a fresh
        // purchase has: Apple has been told, and `POST /v1/webhooks/app-store` is told separately
        // and asynchronously. Concluding from one immediate read would print "nothing to restore"
        // in precisely the case restore exists for — a household that *is* subscribed, on a
        // device that had not heard.
        //
        // A shorter window than a purchase's, because nobody has just been charged and a Settings
        // row cannot spin for a minute.
        //
        // **What a restore actually restores, since phase 140.** `AppStore.sync()` brings the
        // Apple Account's transactions to this device; handing the current one to the server is
        // what brings the *household* back. Before this, a restore could only re-read a server
        // that had never been told — which is why the sentence under the card said "nothing has
        // arrived yet" to a parent holding a paid-up receipt.
        switch await submitCurrentEntitlement() {
        case .subscribed(let family):
            household = family
            if purchase != .idle, purchase != .subscribed { purchase = .subscribed }
            settleRestoreFound()
            return
        case .otherHousehold:
            // **Something arrived, and the server said whose it is** (phase 143) — so neither the
            // poll nor its "nothing has arrived yet" is the right answer. Only the run the parent is
            // watching may say so; see `restoreGeneration`.
            if generation == restoreGeneration { settleReceiptElsewhere() }
            return
        case .inconclusive:
            break
        }

        let outcome = await EntitlementConfirmation.poll(
            schedule: confirmationSchedule.isEmpty
                ? [] : EntitlementConfirmation.restoreSchedule,
            sleep: confirmationSleep,
            read: readHousehold
        )
        switch outcome {
        case .subscribed(let family):
            household = family
            if purchase != .idle, purchase != .subscribed { purchase = .subscribed }
            settleRestoreFound()
        case .late:
            // **The answer has to come from a read that happened.** `refreshHousehold()` returns
            // early on a throwing read, leaving `household` holding whatever it held before — so
            // testing it without testing the read would announce "your membership is active" to a
            // household that lapsed, on the strength of a summary this restore never confirmed.
            let answered = await refreshHousehold()
            if answered, household?.isSubscribed == true {
                // **The window closed before the server said yes, and then it said yes.** The
                // parent gets the same sentence as the fast path: what matters to them is the
                // answer, not which read it arrived on.
                settleRestoreFound()
            } else if household?.isMember != true, generation == restoreGeneration {
                // **Guarded on the household as well as on the read, and both guards are load
                // bearing in opposite directions.** `answered` above stops a *failed* read
                // announcing a membership off a stale summary. This one stops the same failed read
                // announcing *nothing arrived* over a household the app already knows is
                // subscribed — which is what the first guard alone produced, and is the same
                // contradiction, inverted. When the read fails and the household is subscribed,
                // this restore proved nothing in either direction and says nothing.
                //
                // **Not a claim about the Apple Account.** The client cannot see what Apple holds;
                // it can only report that nothing has arrived here yet.
                //
                // `isMember` rather than `isSubscribed` since phase 141: a granted household has
                // no receipt to restore and its card already reads *Subscribed*, so this sentence
                // under it would be the same contradiction. And only the run the parent is
                // watching may say it — see `restoreGeneration`.
                //
                // **And only into an empty channel** (phase 143). The prologue cleared it, so
                // anything standing here was written while the poll was out: the deadline's own
                // copy of this sentence, or a purchase's 409 saying whose receipt it is — which is
                // the more specific answer, and the vaguer one must not overwrite it.
                if notice == nil { notice = Self.restoreNothingYet }
            }
        }
    }

    /// A restore found a membership, by whichever read. **One writer for the sentence and the
    /// invariant beside it**: at most one of `restoreConfirmation` and `notice` stands, so a
    /// membership that lands after the deadline wrote *nothing has arrived yet* takes that
    /// sentence down with it — the same rule `confirm()` applies when a late `.subscribed` lands.
    ///
    /// **The channel, not one string, since phase 143.** This cleared only `restoreNothingYet`
    /// while that was the only sentence a run could find here; a purchase's submission can now
    /// write *attached to a different account* into `notice` while this run's poll is out, and
    /// *Found it* beside that is the contradiction — with the standing `notice` also keeping the
    /// paywall from dismissing on a restore that succeeded. This branch only ever runs on a proven
    /// membership, so any `notice` still standing is stale by construction.
    private func settleRestoreFound() {
        restoreConfirmation = Self.restoreFound
        notice = nil
    }

    /// **The `.late` branch's sentence, and since phase 141 the deadline's too** — one string, so
    /// the two ways a restore can end without an answer cannot drift into saying different things.
    /// Reproduced, not authored: it shipped inline in the `.late` branch with phase 37b.
    static let restoreNothingYet = "Nothing has arrived yet. If you subscribed on another device, "
        + "it can take a moment to appear."

    /// **The owner's sentence, chosen Aug 26, 2026, not an agent's.**
    ///
    /// `docs/design/free-tier-copy.md` forbids an agent authoring a user-visible string on the
    /// membership surface, and this surface is that one. A placeholder was written, the rule was
    /// raised rather than quietly broken, and the owner picked this from three candidates. It is
    /// recorded in the copy file as §7's fifth string.
    ///
    /// **States what happened and asks for nothing** — no urgency, no exclamation, nothing to act
    /// on. The copy rules apply to a success as much as to a refusal.
    static let restoreFound = "Found it. Your membership is active."

    /// **Proposed Sep 3, 2026, awaiting owner approval.** Not yet in `docs/design/free-tier-copy.md`,
    /// and that file forbids an agent authoring a user-visible sentence on the membership surface —
    /// so this is one named constant, flagged in phase 143's PR, for the owner to keep or reword.
    /// Changing it here changes it on both surfaces at once.
    ///
    /// **What it is for.** `POST /v1/families/me/transactions` answers `409 conflict` when it will
    /// not attribute the receipt to the caller's household — its `appAccountToken` names a different
    /// one, because the account that bought it was since deleted or the same person signed in with a
    /// different provider and was given a new household. The API lane's own phase 143 lifts that
    /// refusal when the other household has nobody left in it; what remains is the case a parent can
    /// act on. Reproduced in production on Sep 3, 2026: Apple said *"You're currently subscribed to
    /// this"*, the card said *"being confirmed"*, and nothing ever said why. This is the why.
    /// **States what happened and what to do, and asks for nothing else** — no urgency, no
    /// exclamation, nothing red, nothing counting down.
    static let subscriptionOnAnotherAccount =
        "This App Store subscription is attached to a different Pocket Chronicle account. "
        + "Sign in with that account, or subscribe here with a different Apple Account."

    func noticeDismissed() {
        notice = nil
        restoreConfirmation = nil
    }

    /// A refused purchase the parent has read and closed the sheet on.
    ///
    /// `.failed` otherwise persists for the model's life — only a subscribed household clears it —
    /// and since phase 140 the Membership card renders it, so a sentence about a failure the
    /// parent already saw would follow them into Settings. Only `.failed` moves; every other
    /// state has its own writer and its own reason to stay.
    func dismissFailure() {
        if case .failed = purchase { purchase = .idle }
    }
}
