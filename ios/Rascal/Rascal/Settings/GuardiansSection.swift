import SwiftUI

/// **Guardians** — who shares this archive, and how a second parent is invited into it.
///
/// Removing a guardian is deliberately absent. It is a destructive action over shared history —
/// `entries.completed_by` records which parent answered — and nobody has decided what happens to
/// what they wrote. `docs/decisions.md` open item 13.
struct GuardiansSection: View {
    @Bindable var model: GuardiansModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Who shares this")
            SettingsCard {
                switch model.phase {
                case .idle, .loading:
                    loadingRow
                case .failed(let message):
                    failureRow(message)
                case .ready(let family):
                    guardianRows(family)
                    pendingRows(family)
                    inviteRow(family)
                }
                if let notice = model.notice {
                    SettingsDivider()
                    // A sentence, never an alert. Nothing here is the parent's mistake.
                    Text(notice)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { await model.load() }
        .sheet(
            isPresented: Binding(
                get: { model.pendingShareURL != nil },
                set: { if !$0 { model.shareSheetDismissed() } }
            )
        ) {
            if let url = model.pendingShareURL {
                ShareLinkSheet(url: url)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.showsUpgrade },
                set: { if !$0 { model.upgradeDismissed() } }
            )
        ) {
            SecondParentUpgradeSheet { model.upgradeDismissed() }
        }
    }

    private var loadingRow: some View {
        Text("Loading…")
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Loading the people who share this archive")
    }

    /// The section stays and offers a retry rather than disappearing. A household that vanishes
    /// reads as a household that was lost.
    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
            Button("Try again") { Task { await model.load() } }
                .typeRole(.body)
                .foregroundStyle(Color.terracotta)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func guardianRows(_ family: FamilySummary) -> some View {
        ForEach(Array(family.guardians.enumerated()), id: \.element.id) { index, guardian in
            if index > 0 { SettingsDivider() }
            // A member with no guardian row has no grant date, and the server sends null
            // rather than inventing one — so this says nothing there rather than a date it
            // does not have.
            SettingsValueRow(
                label: guardian.displayLabel,
                value: joinedLabel(guardian) ?? ""
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                guardian.isYou
                    ? "You, \(joinedLabel(guardian) ?? "in this household")"
                    : "\(guardian.displayLabel), \(joinedLabel(guardian) ?? "in this household")"
            )
        }
    }

    /// A count of zero is an absent row. Nothing outstanding renders nothing.
    @ViewBuilder
    private func pendingRows(_ family: FamilySummary) -> some View {
        ForEach(family.pendingInvites) { invite in
            SettingsDivider()
            SettingsActionRow(
                label: "Invitation sent",
                detail: invite.email ?? "Waiting for them to open the link",
                isBusy: model.isWorking,
                isEnabled: !model.isWorking
            ) {
                Task { await model.revoke(invite) }
            }
            .accessibilityLabel("Withdraw the invitation")
        }
    }

    /// The affordance disappears when the household is full — two adults *is* the household, and
    /// a third is a different product rather than a bigger bill, so there is nothing to offer.
    @ViewBuilder
    private func inviteRow(_ family: FamilySummary) -> some View {
        if !family.isFull {
            SettingsDivider()
            SettingsActionRow(
                label: "Invite the other parent",
                detail: "You'll get a link to send. It works once, so if you lose it just make another.",
                isBusy: model.isWorking,
                isEnabled: !model.isWorking
            ) {
                Task { await model.invite() }
            }
        }
    }

    private func joinedLabel(_ guardian: GuardianSummary) -> String? {
        guard let grantedAt = guardian.grantedAt else { return nil }
        return "Since \(DayHeaderText.monthAndYear(grantedAt))"
    }
}

/// The product's first paywall, and it is a door.
///
/// Framed as what the subscription **unlocks**, never as what free lacks. No red, no countdown,
/// no urgency, nothing that implies the parent has fallen short — `docs/design-system.md` copy
/// rules, which forbid all four outright.
///
/// **There is no purchase to route to.** StoreKit is phase 37, and a stubbed flow or a "coming
/// soon" would be furniture for months. The button explains and dismisses, which is the honest
/// shape until there is something to buy.
struct SecondParentUpgradeSheet: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Both of you, one archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)

            Text(
                "A subscription shares this archive with the other parent. "
                    + "You keep the same children, the same timeline and the same moments — "
                    + "and each of you gets your own prompts every day, so you are not answering "
                    + "the same question twice."
            )
            .typeRole(.body)
            .foregroundStyle(Color.ink)

            Text("One price covers the whole household, however many children there are.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)

            Spacer(minLength: 0)

            Button("Got it", action: onDismiss)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Closes this and returns to Settings")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas)
        .presentationDetents([.medium])
    }
}

/// The system share sheet, holding the one-time invite link.
struct ShareLinkSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
