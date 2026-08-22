import StoreKit
import SwiftUI

/// The membership card in Settings: what the household is on, and — when it is subscribed — the
/// way out.
///
/// **Cancelling is not hidden and not discouraged.** No interstitial, no "are you sure you want to
/// lose your memories", no retention offer. Per D3 a lapsed household drops to the free tier and
/// nothing is ever locked behind payment, so there is nothing frightening to say here and saying
/// something frightening would be false.
///
/// The state on this card is **the server's**, always: `model.household` is a `FamilySummary` from
/// `GET /v1/families/me`. Nothing here reads a local transaction.
struct SubscriptionSection: View {
    @Bindable var model: SubscriptionModel

    @Environment(\.scenePhase) private var scenePhase

    /// **The gap between the three reassurance lines, scaled with Dynamic Type.**
    ///
    /// A fixed spacing is wrong here and looked fine until it was rendered: at XXL the *leading*
    /// inside a wrapped line grows while a constant gap does not, so "Everything you've already
    /// written / or captured" separated by 3pt read as two items rather than one wrapped one —
    /// three statements looking like five. `PaywallSheet.ListRow` already solves this for the same
    /// block with `base * gap`; this is that treatment, so the two surfaces stay in step.
    @ScaledMetric(relativeTo: .body) private var reassuranceGap: CGFloat = 1
    @State private var showingPaywall = false
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Membership")

            SettingsCard {
                SettingsValueRow(label: "Household", value: statusValue)

                // **Each case carries its own leading rule** rather than the card carrying one
                // between every pair. `hidden` emits no row, and a fixed divider above it would
                // leave two rules stacked against each other with nothing in between.
                switch MembershipPresentation.settingsAction(for: model.household) {
                case .manage:
                    SettingsDivider()
                    SettingsActionRow(
                        label: "Manage subscription",
                        detail: "Change the plan or cancel, in the App Store."
                    ) {
                        showingManage = true
                    }
                case .offer:
                    SettingsDivider()
                    SettingsActionRow(
                        label: "See the subscription",
                        detail: "One price for the whole household — both parents, every child."
                    ) {
                        showingPaywall = true
                    }
                case .hidden:
                    // A subscriber who is explicitly not the payer. Nothing to manage and nothing
                    // to sell them; the copy file has no sentence for it, so the card is silent.
                    EmptyView()
                }

                SettingsDivider()

                SettingsActionRow(
                    label: "Restore a purchase",
                    // The honest framing. The entitlement follows the household rather than the
                    // device, so a new phone signed into the same account already works — this
                    // exists for the case where it did not, and because Review requires it.
                    detail: "Rarely needed — your subscription follows the household, not the phone.",
                    isBusy: model.isRestoring,
                    isEnabled: !model.isRestoring
                ) {
                    Task { await model.restore() }
                }

                SettingsDivider()

                reassurance
            }

            if let notice = model.notice {
                Text(notice)
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

    /// **The whole decision is `MembershipPresentation.settingsStatus(for:)`** — a pure function,
    /// so the case that matters (a household three days into its trial, which read "Free" here
    /// from phase 37a until now) is asserted without rendering anything. It reads `access`, never
    /// `tier`, and it never does arithmetic.
    private var statusValue: String {
        MembershipPresentation.settingsStatus(for: model.household)
    }

    /// **The archive-scoped reassurance, on the card in every state.**
    ///
    /// The words are `free-tier-copy.md` §2's *"What stays free, always"* block — verbatim, in its
    /// order, already carried in `MembershipCopy` and already rendered by `PaywallSheet`. **Nothing
    /// here is authored.** The copy file forbids an agent writing strings into a view, and this is
    /// the one approved block that is true in every membership state, so a second surface can show
    /// it without anything new being written.
    ///
    /// **Including when the household is subscribed**, which is the case worth stating: a member
    /// reading this is not being sold anything. Rule 3 — *"the archive is never the thing being
    /// sold"* — is a promise to everybody, and a reassurance that appeared only on the free tier
    /// would read as a sales argument rather than a standing fact.
    ///
    /// Rendered through `PromptTokens` against no child, exactly as the sheet does. None of these
    /// three strings carries a token today and `render` has a fast path for that — it is here so a
    /// token added to the copy file later cannot surface as a literal `{them}` on this card.
    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(MembershipCopy.freeLabel)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MembershipCopy.stayFree.enumerated()), id: \.offset) { index, line in
                    Text(PromptTokens.render(line, for: .unknown))
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The same 14 the sheet uses, scaled. See `reassuranceGap`.
                        .padding(.top, index == 0 ? 0 : 14 * reassuranceGap)
                }
            }
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One statement, so VoiceOver reads it as one rather than as four stops.
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG

    private extension FamilySummary {
        /// A household in one membership state and nothing else. Guardians and invites are empty
        /// because this card never reads them — `GuardiansSection` is the surface that does.
        static func previewing(
            tier: String,
            access: Access?,
            isPayer: Bool? = nil,
            billingRetry: Bool? = nil,
            plan: String? = nil,
            lapsedAt: Date? = nil
        ) -> FamilySummary {
            FamilySummary(
                familyId: UUID(),
                tier: tier,
                access: access,
                lapsedAt: lapsedAt,
                plan: plan,
                billingRetry: billingRetry,
                isPayer: isPayer,
                guardians: [],
                pendingInvites: []
            )
        }
    }

    /// The card on the ground it actually sits on, so the 4.36:1 finding is judged against `canvas`
    /// and `surface` rather than against a preview's default white.
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

    // MARK: The four states the server can express

    /// **The state this phase exists for.** Before phase 112 this rendered "Free".
    #Preview("Membership — inside the trial") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .trial)
            )
        )
    }

    #Preview("Membership — subscribed") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed)
            )
        )
    }

    #Preview("Membership — free") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .free)
            )
        )
    }

    // MARK: The three ways of not knowing, which are not the same way

    /// The server has not answered yet. **An em dash, never "Free".**
    #Preview("Membership — no household yet") {
        MembershipCardPreview(model: SubscriptionModel(previewing: .loading, household: nil))
    }

    /// A server predating phase 107 sends no `access` at all, and `tier` is the whole truth there.
    #Preview("Membership — a server with no access field") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: nil)
            )
        )
    }

    /// A word this build cannot read. Claims no membership — and under D9 still entitles.
    #Preview("Membership — an access value this build cannot read") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .unrecognised("founding_member"))
            )
        )
    }

    // MARK: Phase 113's wire — the one field that moves a control

    /// **A subscriber who is explicitly not the payer.** No Manage row and no paywall row — there is
    /// no approved sentence naming the other parent, so the card is silent rather than inventing one.
    #Preview("Membership — subscribed, explicitly not the payer") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed, isPayer: false)
            )
        )
    }

    /// **Unknown payer keeps the control.** `is_payer` is null in exactly the two-guardian case, and
    /// hiding Apple's sheet on a null would strip it from a parent who is paying.
    #Preview("Membership — subscribed, payer unknown") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed, isPayer: nil)
            )
        )
    }

    /// **A household in grace renders exactly as a healthy subscriber**, because it *is* one — the
    /// archive stays open while Apple retries. `billing_retry` moves no gate and, for want of
    /// approved copy, says nothing either.
    #Preview("Membership — billing retry (renders as subscribed, deliberately)") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(
                    tier: "subscribed", access: .subscribed, isPayer: true, billingRetry: true
                )
            )
        )
    }

    // MARK: Restore — the three sub-states

    #Preview("Restore — idle") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed)
            )
        )
    }

    #Preview("Restore — in progress") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "subscribed", access: .subscribed),
                isRestoring: true
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
                notice: "Nothing has arrived yet. If you subscribed on another device, "
                    + "it can take a moment to appear."
            )
        )
    }

    // MARK: Dynamic Type

    /// XXL is the floor this card has to survive, per the phase's checks.
    #Preview("Membership — trial, XXL") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .trial)
            )
        )
        .environment(\.dynamicTypeSize, .xxLarge)
    }

    #Preview("Membership — trial, AX3") {
        MembershipCardPreview(
            model: SubscriptionModel(
                previewing: .loading,
                household: .previewing(tier: "free", access: .trial)
            )
        )
        .environment(\.dynamicTypeSize, .accessibility3)
    }

#endif
