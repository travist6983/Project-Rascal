import SwiftUI

/// **Guardians** — who shares this archive, and how a second parent is invited into it.
///
/// Removing a guardian is deliberately absent. It is a destructive action over shared history —
/// `entries.completed_by` records which parent answered — and nobody has decided what happens to
/// what they wrote. `docs/decisions.md` open item 13.
struct GuardiansSection: View {
    @Bindable var model: GuardiansModel
    /// The paywall's model, owned by `SettingsScreen` so this section and the Membership card
    /// share one — two `SubscriptionModel`s would be two `GET /v1/families/me` readers and two
    /// opinions about which plan is selected.
    @Bindable var subscription: SubscriptionModel

    /// The address the invite is emailed to. Held here rather than in the model because it is
    /// keystrokes in a field, not household state — it is gone the moment either button is
    /// pressed, and nothing outside this view has any business reading a half-typed address.
    @State private var address = ""
    @State private var isAsking = false

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
        // **The same `.alert`-with-a-field shape `CredentialsSheet` already uses for adding an
        // address**, rather than a new sheet: one thing is being asked for, and a sheet for one
        // text field is furniture. Two ways out besides Cancel, because both are real — email
        // it, or take the link and hand it over yourself. Sending with the field left empty
        // takes the link route rather than refusing: the model treats a blank address as no
        // address, and a parent who meant the other button gets what they meant.
        .alert("Invite the other parent", isPresented: $isAsking) {
            TextField("them@example.com", text: $address)
                .textInputAutocapitalization(.never)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
            Button("Cancel", role: .cancel) { address = "" }
            Button("Send the invitation") {
                let typed = address
                address = ""
                Task { await model.invite(email: typed) }
            }
            Button("Get a link instead") {
                address = ""
                Task { await model.invite() }
            }
        } message: {
            Text(
                "We'll email them a link that adds them to this household. "
                + "Or take the link and send it yourself."
            )
        }
        // **The household turning over is what makes the invite row true again** (phase 140).
        // The sheet now dismisses before the server has answered, so the closure below re-reads
        // a household that still says `free`; this is the re-read that catches the `subscribed`
        // when it lands. The same pure transition rule Today uses, for the same D5 reason.
        .onChange(of: subscription.household?.isSubscribed) { old, new in
            if MembershipPresentation.boardNeedsReload(wasSubscribed: old, isSubscribed: new) {
                Task { await model.load() }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.showsUpgrade },
                set: { if !$0 { model.upgradeDismissed() } }
            )
        ) {
            // **Phase 37b: this is a purchase now.** Phase 61 shipped the same surface with no
            // StoreKit behind it deliberately — 37 owned that and a "coming soon" would have been
            // furniture for months. Phase 108 retired the per-context copy: the copy file specifies one
            // sheet, and the second-parent claim is now a row in *what membership adds*.
            PaywallSheet(model: subscription) {
                model.upgradeDismissed()
                // The household may be subscribed now, and this section is showing the tier it
                // had when it loaded. Re-read rather than leave the invite row refusing on a
                // stale answer.
                Task { await model.load() }
            }
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
                .foregroundStyle(Color.terracottaDeep)
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
                detail: "We'll email them a link, or you can send one yourself. "
                    + "It works once, so if it goes astray just make another.",
                isBusy: model.isWorking,
                isEnabled: !model.isWorking
            ) {
                address = ""
                isAsking = true
            }
        }
    }

    private func joinedLabel(_ guardian: GuardianSummary) -> String? {
        guard let grantedAt = guardian.grantedAt else { return nil }
        return "Since \(DayHeaderText.monthAndYear(grantedAt))"
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

#if DEBUG
private let _you = GuardianSummary(
    userId: UUID(), displayName: "Travis", role: "parent",
    grantedAt: .now.addingTimeInterval(-90 * 86_400), isYou: true
)
private let _them = GuardianSummary(
    userId: UUID(), displayName: "Anna", role: "parent",
    grantedAt: .now.addingTimeInterval(-2 * 86_400), isYou: false
)
private let _pending = InviteSummary(
    id: UUID(), email: "anna@example.com", role: "parent",
    expiresAt: .now.addingTimeInterval(7 * 86_400), createdAt: .now
)

/// Parked in `.loading`: a preview has no StoreKit session, so the paywall it presents would
/// spin either way. The sheet is not what these previews are of.
private let _subscription = SubscriptionModel(previewing: .loading)

private func _family(
    tier: String, guardians: [GuardianSummary], invites: [InviteSummary] = []
) -> FamilySummary {
    FamilySummary(
        familyId: UUID(),
        tier: tier,
        access: tier == "subscribed" ? .subscribed : .free,
        // This row reads none of phase 113's membership fields; unset is what it means.
        lapsedAt: nil,
        plan: nil,
        billingRetry: nil,
        isPayer: nil,
        guardians: guardians,
        pendingInvites: invites
    )
}

#Preview("Guardians — solo, free") {
    GuardiansSection(
        model: GuardiansModel(previewing: .ready(_family(tier: "free", guardians: [_you]))),
        subscription: _subscription
    )
    .padding(Layout.screenMargin)
    .background(Color.canvas)
}

#Preview("Guardians — invitation outstanding") {
    GuardiansSection(
        model: GuardiansModel(
            previewing: .ready(
                _family(tier: "subscribed", guardians: [_you], invites: [_pending])
            )
        ),
        subscription: _subscription
    )
    .padding(Layout.screenMargin)
    .background(Color.canvas)
}

#Preview("Guardians — both parents") {
    // The invite row is absent, not disabled: two adults *is* the household.
    GuardiansSection(
        model: GuardiansModel(
            previewing: .ready(_family(tier: "subscribed", guardians: [_you, _them]))
        ),
        subscription: _subscription
    )
    .padding(Layout.screenMargin)
    .background(Color.canvas)
}

#Preview("Guardians — load failed") {
    GuardiansSection(
        model: GuardiansModel(
            previewing: .failed("No connection. Saved here, and it'll sync when you're back.")
        ),
        subscription: _subscription
    )
    .padding(Layout.screenMargin)
    .background(Color.canvas)
}

#Preview("Guardians — solo, free, AX XXL") {
    ScrollView {
        GuardiansSection(
            model: GuardiansModel(previewing: .ready(_family(tier: "free", guardians: [_you]))),
            subscription: _subscription
        )
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility4)
}

#Preview("Guardians — outstanding, AX XXL") {
    ScrollView {
        GuardiansSection(
            model: GuardiansModel(
                previewing: .ready(
                    _family(tier: "subscribed", guardians: [_you], invites: [_pending])
                )
            ),
            subscription: _subscription
        )
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility4)
}
#endif
