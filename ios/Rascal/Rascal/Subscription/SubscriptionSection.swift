import StoreKit
import SwiftUI

/// The membership card in Settings: what the household is on, and the one thing they can do
/// about it.
///
/// **A receipt, since phase 144.** The header names the state in a noun — *Free trial*, *Free*,
/// *Annual membership*, *Complimentary membership* — with the one dated fact the server sent under
/// it, formatted and never counted here. Beneath it there are only the rows that can change that
/// answer: *Become a member* for a household nobody is paying for, *Manage subscription* for one
/// somebody is, *Restore a purchase* only where a restore could find something. The three-line
/// reassurance block that used to close the card is gone at the owner's call; the paywall still
/// renders it.
///
/// **Cancelling is not hidden and not discouraged.** No interstitial, no "are you sure you want to
/// lose your memories", no retention offer. Per D3 a lapsed household drops to the free tier and
/// nothing it wrote is ever locked, so there is nothing frightening to say here and saying
/// something frightening would be false.
///
/// The state on this card is **the server's**, always: `model.household` is a `FamilySummary` from
/// `GET /v1/families/me`, and every row's presence is a pure function of it in
/// `MembershipPresentation`. Nothing here reads a local transaction or a clock.
struct SubscriptionSection: View {
    @Bindable var model: SubscriptionModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var showingPaywall = false
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Membership")

            SettingsCard {
                // **The first call site of `SettingsCardHeader`.** Eyebrow, the state at card
                // title, and one or two `metadata` sentences — never a paragraph. The eyebrow is
                // the owner's §7 label, unchanged; the headline is the state the old value row
                // could not name.
                let header = MembershipPresentation.settingsHeader(for: model.household)
                SettingsCardHeader(
                    eyebrow: "Your household",
                    headline: header.headline,
                    detail: header.detail
                )

                // **Each case carries its own leading rule** rather than the card carrying one
                // between every pair. `hidden` emits no row, and a fixed divider above it would
                // leave two rules stacked against each other with nothing in between.
                switch MembershipPresentation.settingsAction(
                    for: model.household, purchase: model.purchase
                ) {
                case .finishing(let label):
                    // **The purchase, reported where the parent lands** (phase 140). The sheet
                    // dismissed itself the moment Apple took the money; this row is what it was
                    // showing, in the slot that would otherwise sell them something. The same
                    // treatment as the sheet's busy row — a `terracotta` spinner and `inkMuted`
                    // body — and not a `SettingsActionRow`, because there is nothing to tap.
                    SettingsDivider()
                    HStack(spacing: 10) {
                        ProgressView().tint(.terracotta)
                        Text(label)
                            .typeRole(.body)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(Layout.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                case .reported(let sentence):
                    // The busy row without its spinner (phase 144): Apple has the money, or is
                    // waiting for a family organiser, and the server has not caught up. Nothing
                    // to tap, and no *Become a member* above a line saying they already did.
                    SettingsDivider()
                    Text(sentence)
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Layout.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .manage:
                    SettingsDivider()
                    SettingsActionRow(
                        label: MembershipCopy.Card.manage,
                        detail: MembershipPresentation.manageDetail(for: model.household)
                    ) {
                        showingManage = true
                    }
                case .offer:
                    // §2's verb, per copy-file rule 2: a person **joins**. The detail is the
                    // trial's own on a trial, and the sheet's subtitle everywhere else.
                    SettingsDivider()
                    SettingsActionRow(
                        label: MembershipCopy.primaryAction,
                        detail: MembershipPresentation.offerDetail(for: model.household)
                    ) {
                        showingPaywall = true
                    }
                case .hidden:
                    // A subscriber who is explicitly not the payer, or a household on an admin
                    // grant (phase 141). Nothing to manage and nothing to sell either of them;
                    // the header has already said everything the card knows.
                    EmptyView()
                }

                // **Restore, only where a restore could find something** (phase 144). Below the
                // CTA rather than above it: a parent who has never paid must not meet *Restore*
                // before *Become a member*. Disabled while a purchase is in flight so two StoreKit
                // operations cannot overlap; hidden for every member state.
                switch MembershipPresentation.settingsRestore(
                    for: model.household, purchase: model.purchase
                ) {
                case .offered:
                    SettingsDivider()
                    SettingsActionRow(
                        label: MembershipCopy.Card.restore,
                        // The honest framing. The entitlement follows the household rather than
                        // the device, so a new phone signed into the same account already works
                        // — this exists for the case where it did not.
                        detail: MembershipCopy.Card.restoreDetail,
                        isBusy: model.isRestoring,
                        isEnabled: !model.isRestoring
                    ) {
                        Task { await model.restore() }
                    }
                case .waiting:
                    SettingsDivider()
                    SettingsActionRow(
                        label: MembershipCopy.Card.restore,
                        detail: MembershipCopy.Card.restoreDetail,
                        isEnabled: false
                    ) {}
                case .hidden:
                    EmptyView()
                }
            }

            // **One line, three channels, in priority order — and at most one of the first two
            // stands.** `restore()` clears both before it starts: a run that found a membership
            // sets `restoreConfirmation` and a run that did not sets `notice`. Since phase 143 a
            // purchase's confirmation can write `notice` too — a receipt the server says is another
            // household's — so `notice` is no longer only a statement about a restore, and a found
            // membership clears the whole channel rather than one string. They render identically
            // because none is an alarm — `inkMuted` metadata under the card, never an alert, never
            // red.
            //
            // Coalesced rather than stacked so the two can never appear together and read as a
            // contradiction. The confirmation wins the ordering because it is the state a parent
            // is looking at the card to see.
            //
            // **The third channel carries only a refusal since phase 144**: the store's own
            // sentence for a purchase the parent swiped past unread. The late and Ask-to-Buy
            // sentences moved into the card as the reported row, and a sentence rendered in the
            // card must not also render under it.
            if let line = model.restoreConfirmation ?? model.notice
                ?? MembershipPresentation.purchaseLine(for: model.purchase)
            {
                Text(line)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .task { await model.load() }
        // An approval, a renewal or a refund arriving on `Transaction.updates` while this is on
        // screen. Without this the view sits correct-but-stale until it is dismissed and reopened.
        .onChange(of: SubscriptionCenter.shared.transactionRevision) { _, _ in
            Task { await model.transactionArrived() }
        }
        // A foreground is a reason to re-read, not a transaction. See `transactionRevision`.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshHousehold() }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallSheet(model: model) { showingPaywall = false }
        }
        // **The system sheet, not a link to a Safari URL.** A parent cancelling should be doing it
        // in the place Apple already keeps their subscriptions, and a web page here would be one
        // more thing standing between them and leaving.
        .manageSubscriptionsSheet(isPresented: $showingManage)
        // A cancellation made in that sheet does not tell the app anything directly — Apple tells
        // the server, and the server is what this row reads. Re-reading on dismissal is what makes
        // the row catch up without claiming to know why.
        .onChange(of: showingManage) { _, presented in
            if !presented { Task { await model.refreshHousehold() } }
        }
    }
}

#if DEBUG

    /// **Every preview date is a parsed literal**, never `Date()` or a `Calendar` — the source scan
    /// in `SettingsMembershipTests.theRowDoesNoArithmetic` reads this file previews included, and
    /// the constraint travels with it.
    private let previewDate = ISO8601Formatters.parse("2026-09-17T00:00:00Z")!
    private let previewRenewal = ISO8601Formatters.parse("2027-09-17T00:00:00Z")!

    private extension FamilySummary {
        /// A household in one membership state and nothing else. Guardians and invites are empty
        /// because this card never reads them — `GuardiansSection` is the surface that does.
        static func previewing(
            tier: String,
            access: Access?,
            isPayer: Bool? = nil,
            billingRetry: Bool? = nil,
            plan: String? = nil,
            lapsedAt: Date? = nil,
            entitlementSource: String? = nil,
            trialEndsAt: Date? = nil,
            trialDaysLeft: Int? = nil,
            grantExpiresAt: Date? = nil,
            expiresAt: Date? = nil,
            autoRenew: Bool? = nil
        ) -> FamilySummary {
            var household = FamilySummary(
                familyId: UUID(),
                tier: tier,
                access: access,
                lapsedAt: lapsedAt,
                plan: plan,
                billingRetry: billingRetry,
                isPayer: isPayer,
                entitled: nil,
                entitlementSource: entitlementSource,
                guardians: [],
                pendingInvites: []
            )
            household.trialEndsAt = trialEndsAt
            household.trialDaysLeft = trialDaysLeft
            household.grantExpiresAt = grantExpiresAt
            household.expiresAt = expiresAt
            household.autoRenew = autoRenew
            return household
        }
    }

    /// The card on the ground it actually sits on, so contrast is judged against `canvas` and
    /// `surface` rather than against a preview's default white.
    private struct MembershipCardPreview: View {
        let model: SubscriptionModel

        var body: some View {
            ScrollView {
                SubscriptionSection(model: model)
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.vertical, 24)
            }
            .background(Color.canvas)
        }
    }

    // MARK: Non-members

    /// **The state the owner opened the brief with**: the count and the date, both the server's.
    #Preview("Trial — days and date") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .trial, trialEndsAt: previewDate, trialDaysLeft: 13
                )
            )
        )
    }

    #Preview("Trial — last day") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .trial, trialEndsAt: previewDate, trialDaysLeft: 1
                )
            )
        )
    }

    /// A server that sends the date and not the count.
    #Preview("Trial — date only") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .trial, trialEndsAt: previewDate)
            )
        )
    }

    #Preview("Free") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free)
            )
        )
    }

    /// Renders byte-identical to *Free*, deliberately: the free tier is the same tier either way.
    #Preview("Free — lapsed") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free, lapsedAt: previewDate)
            )
        )
    }

    // MARK: Members

    #Preview("Annual — renews") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, plan: "annual",
                    expiresAt: previewRenewal, autoRenew: true
                )
            )
        )
    }

    #Preview("Monthly — renewal turned off") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, plan: "monthly",
                    expiresAt: previewDate, autoRenew: false
                )
            )
        )
    }

    /// Apple's word unknown — a receipt the app submitted itself, until the first notification.
    #Preview("Annual — paid through") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, plan: "annual",
                    expiresAt: previewRenewal
                )
            )
        )
    }

    /// A server that predates phase 144: no date line, the plan alone.
    #Preview("Annual — older server") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed, plan: "annual")
            )
        )
    }

    /// No plan on the wire: the hand-written household. The plain noun, never a guess.
    #Preview("Subscribed — no receipt behind it") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed)
            )
        )
    }

    /// Nothing to tap: Apple's sheet on this device would not list the subscription.
    #Preview("Not the payer") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, isPayer: false, plan: "annual",
                    expiresAt: previewRenewal, autoRenew: true
                )
            )
        )
    }

    /// Fully entitled, no wash, no red, no date. The Manage row names where the card lives.
    #Preview("Billing retry") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, billingRetry: true, plan: "monthly"
                )
            )
        )
    }

    #Preview("Complimentary — perpetual") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .subscribed, entitlementSource: "grant"
                )
            )
        )
    }

    #Preview("Complimentary — until a date") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .subscribed, entitlementSource: "grant",
                    grantExpiresAt: previewRenewal
                )
            )
        )
    }

    // MARK: Not knowing, which is not the same as free

    /// The server has not answered. **An em dash, never "Free"**, and a sentence saying so.
    #Preview("No household yet") {
        MembershipCardPreview(model: SubscriptionModel(previewing: .loading, household: nil))
    }

    /// A word this build cannot read. D9: the board stays open; the card says why it cannot name
    /// the membership.
    #Preview("Access this build cannot read") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .unrecognised("founding_member"))
            )
        )
    }

    // MARK: A purchase, reported on the card

    /// The sheet has just dismissed itself; the server is being told. Restore is disabled.
    #Preview("Purchase — finishing up") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .trial, trialEndsAt: previewDate, trialDaysLeft: 13
                ),
                purchase: .confirming
            )
        )
    }

    /// The window closed with the server still saying `free`. The sentence is in the card, the
    /// offer row is gone, Restore is back.
    #Preview("Purchase — late") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .trial, trialEndsAt: previewDate, trialDaysLeft: 13
                ),
                purchase: .late
            )
        )
    }

    #Preview("Purchase — awaiting approval") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free),
                purchase: .awaitingApproval
            )
        )
    }

    /// The store's own sentence, for a refusal the parent swiped past unread.
    #Preview("Purchase — refused, sheet swiped away") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free),
                purchase: .failed(SubscriptionStoreError.productsUnavailable.userMessage)
            )
        )
    }

    // MARK: Restore — the three sub-states, on a household restore exists for

    #Preview("Restore — in progress") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free),
                isRestoring: true
            )
        )
    }

    /// **The other outcome, which the card is the only surface that can report.** The card has
    /// become the member's card; the sentence under it is the news.
    #Preview("Restore — found a membership") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, plan: "annual",
                    expiresAt: previewRenewal, autoRenew: true
                ),
                // The string `restore()` actually sets, not one written for a preview.
                restoreConfirmation: SubscriptionModel.restoreFound
            )
        )
    }

    /// **"Nothing to restore" is a normal outcome after a reinstall and must not read as an error.**
    #Preview("Restore — nothing arrived") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free),
                // The string `restore()` actually sets, not one written for a preview.
                notice: SubscriptionModel.restoreNothingYet
            )
        )
    }

    // MARK: Dynamic Type

    #Preview("Trial, XXL") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "free", access: .trial, trialEndsAt: previewDate, trialDaysLeft: 13
                )
            )
        )
        .environment(\.dynamicTypeSize, .xxLarge)
    }

    #Preview("Billing retry, AX3") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, billingRetry: true, plan: "monthly"
                )
            )
        )
        .environment(\.dynamicTypeSize, .accessibility3)
    }

#endif
