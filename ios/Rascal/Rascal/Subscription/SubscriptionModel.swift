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

    enum PurchasePhase: Equatable {
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
    /// A restore that found nothing to restore, said as a sentence rather than an alert.
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

    init(
        readHousehold: @escaping @Sendable () async throws -> FamilySummary,
        store: any SubscriptionPurchasing = SubscriptionStore(),
        confirmationSchedule: [Duration] = EntitlementConfirmation.schedule,
        confirmationSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        confirmationDeadline: Duration = .seconds(120),
        confirmationDeadlineSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        offerTimeout: Duration = .seconds(10),
        offerSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.readHousehold = readHousehold
        self.store = store
        self.confirmationSchedule = confirmationSchedule
        self.confirmationSleep = confirmationSleep
        self.confirmationDeadline = confirmationDeadline
        self.confirmationDeadlineSleep = confirmationDeadlineSleep
        self.offerTimeout = offerTimeout
        self.offerSleep = offerSleep
    }

    convenience init(api: APIClient, store: any SubscriptionPurchasing = SubscriptionStore()) {
        self.init(readHousehold: { try await api.family() }, store: store)
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
        if household?.isSubscribed == true { return false }
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
        notice = nil
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

    // MARK: Restore

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        notice = nil
        // Cleared with `notice`, for the same reason: a second tap must not read as a result
        // until this run has one. At most one of the two is set by the time this returns.
        restoreConfirmation = nil
        defer { isRestoring = false }

        do {
            try await store.restore()
        } catch let error as SubscriptionStoreError {
            notice = error.userMessage
            return
        } catch {
            notice = error.localizedDescription
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
            restoreConfirmation = Self.restoreFound
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
                restoreConfirmation = Self.restoreFound
            } else if household?.isSubscribed != true {
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
                notice = "Nothing has arrived yet. If you subscribed on another device, "
                    + "it can take a moment to appear."
            }
        }
    }

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

    func noticeDismissed() {
        notice = nil
        restoreConfirmation = nil
    }
}
