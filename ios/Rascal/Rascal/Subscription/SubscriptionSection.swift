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
    @State private var showingPaywall = false
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Membership")

            SettingsCard {
                SettingsValueRow(label: "Household", value: statusValue)

                SettingsDivider()

                if isSubscribed {
                    SettingsActionRow(
                        label: "Manage subscription",
                        detail: "Change the plan or cancel, in the App Store."
                    ) {
                        showingManage = true
                    }
                } else {
                    SettingsActionRow(
                        label: "See the subscription",
                        detail: "One price for the whole household — both parents, every child."
                    ) {
                        showingPaywall = true
                    }
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
            PaywallSheet(model: model, context: .settings) { showingPaywall = false }
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

    private var isSubscribed: Bool { model.household?.isSubscribed == true }

    /// An em dash until the server has answered. **Not knowing is a different answer from `free`**,
    /// and this row saying "Free" on the strength of never having looked is the same defect the
    /// sync card was fixed for.
    private var statusValue: String {
        guard let household = model.household else { return "—" }
        return household.isSubscribed ? "Subscribed" : "Free"
    }
}
