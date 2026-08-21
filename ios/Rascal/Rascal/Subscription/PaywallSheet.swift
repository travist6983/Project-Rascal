import SwiftUI

/// The product's paywall, and **it is a door.**
///
/// Phase 61 set this register with `SecondParentUpgradeSheet` and this matches it rather than
/// diverging: framed as what the subscription **unlocks**, never as what free lacks. No red, no
/// countdown, no urgency, nothing that implies the parent has fallen short —
/// `docs/design-system.md`'s copy rules forbid all four outright, and a paywall for an eighteen-year
/// archive that implied the archive were hostage would be both untrue and repellent.
///
/// **Every price, period and trial on this screen comes from a `Product`.** There is no currency
/// literal anywhere in this file. D1's numbers are in `decisions.md` and in App Store Connect,
/// which is the only place they are correct in more than one country.
struct PaywallSheet: View {

    /// Where the parent came from. It changes the opening lines and nothing else — the offer, the
    /// prices and the free-tier statement are the same wherever this is presented from.
    enum Context {
        /// The guardian invite's 402, and the surface phase 61 built.
        ///
        /// **Its headline and its paragraph are verbatim** — they are the accurate thing to say to
        /// somebody who has just tried to add the other parent, and rewriting them would have been
        /// a second voice for one product. Its third line, *"One price covers the whole household,
        /// however many children there are"*, is **not** carried across as a sentence: it is one of
        /// the three `CoveredLine` bullets below, which every context shows. Same claim, said once.
        case secondParent
        case settings
    }

    @Bindable var model: SubscriptionModel
    var context: Context = .settings
    var onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView { content }
            .background(Color.canvas)
            .task { await model.load() }
            // An approval, a renewal or a refund arriving on `Transaction.updates` while this
            // is on screen. Without it the view sits correct-but-stale until it is dismissed.
            .onChange(of: SubscriptionCenter.shared.transactionRevision) { _, _ in
                Task { await model.transactionArrived() }
            }
            // Coming back to the app is **not** a transaction — it is a reason to re-read. Ask
            // the server and let it decide; a foreground must not rewrite a pending Ask-to-Buy
            // into "being confirmed", which is what one shared counter did.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshHousehold() }
            }
    }

    /// **Lifted out of the `ScrollView` on purpose, and not for tidiness.** `ImageRenderer` does
    /// not rasterize a `ScrollView`'s content — it renders the scroll view's ground and stops — so
    /// a screenshot harness pointed at the whole sheet produces an empty cream rectangle of the
    /// right height and passes. That is exactly the shape of check that reads as evidence and is
    /// not, which is why `SubscriptionScreenshotTests` renders this and the height assertion alone
    /// was not enough to catch it.
    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            // **The purchase outcome outranks the offer.** `purchaseArea` used to be emitted
            // from inside the `.ready` branch, so a background refresh that resolved to
            // `.unavailable` — one dropped request — replaced "Your subscription is being
            // confirmed" with a retry, for a parent who had already been charged.
            if model.purchase == .idle {
                switch model.phase {
                case .loading:
                    loading
                case .unavailable(let message):
                    unavailable(message)
                case .ready(let offer, _):
                    planPicker(offer)
                    purchaseArea
                }
            } else {
                if case .ready(let offer, _) = model.phase { planPicker(offer) }
                purchaseArea
            }

            freeTierNote
            legalRow
            dismissRow
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        switch context {
        case .secondParent:
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
            .fixedSize(horizontal: false, vertical: true)

        case .settings:
            Text("A subscription for the household")
                .typeRole(.title)
                .foregroundStyle(Color.ink)

            Text(
                "One subscription covers everyone who keeps this archive — both parents, "
                    + "every child, one price."
            )
            .typeRole(.body)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
        }

        // D4: the household is the unit, and this is what it is sold on.
        VStack(alignment: .leading, spacing: 8) {
            CoveredLine("Both parents, each with their own daily prompts")
            CoveredLine("Every child you add, at the same price")
            CoveredLine("One subscription for the whole household")
        }
        .padding(.top, 2)
    }

    // MARK: States

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.terracotta)
            Text("Loading the options")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    /// **A retry, never a blank paywall.** An empty `Product.products(for:)` result and a dropped
    /// connection look identical from here, so this says what can be done rather than guessing at
    /// which one happened.
    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func planPicker(_ offer: SubscriptionOffer) -> some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            // **Locked once a purchase is in flight.** `buy()` captures the plan before it
            // suspends, so changing it here could not buy the wrong thing — but the selection
            // moving under "Finishing up" reads as though it could, and on a screen about money
            // that is its own defect.
            PlanRow(
                plan: offer.annual,
                selected: model.plan == .annual,
                saving: model.savingLine,
                isEnabled: model.canBuy
            ) { model.plan = .annual }

            PlanRow(
                plan: offer.monthly,
                selected: model.plan == .monthly,
                saving: nil,
                isEnabled: model.canBuy
            ) { model.plan = .monthly }
        }
    }

    // MARK: The action, and the confirmation gap

    @ViewBuilder
    private var purchaseArea: some View {
        switch model.purchase {
        case .idle, .failed:
            // **The household became subscribed without this screen buying anything** — a restore
            // that found something, another guardian subscribing, a purchase completed on another
            // device arriving through the listener. `canBuy` correctly goes false, and without
            // this branch the parent is left looking at a greyed-out **Start the free trial** with
            // no sentence saying why it stopped working. A primary action that disables itself and
            // reports nothing teaches somebody the screen is decorative.
            if model.household?.isSubscribed == true {
                terminal(
                    "You're subscribed.",
                    detail: "Everything is shared with the household now.",
                    action: "Done"
                )
            } else {
                if case .failed(let message) = model.purchase {
                    Text(message)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(buyLabel) {
                    Task { await model.buy() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canBuy)
            }

        case .purchasing:
            busy("Talking to the App Store")

        case .confirming:
            // The purchase went through and the server has not been told yet. Named for what is
            // happening rather than for the machinery.
            busy("Finishing up")

        case .subscribed:
            terminal(
                "You're subscribed. Thank you.",
                detail: "Everything is shared with the household now.",
                action: "Done"
            )

        case .late:
            // **Not an error, and it does not read as one.** The purchase succeeded; the
            // confirmation is late. Nothing further is asked of the parent and nothing retries.
            terminal(
                "Your subscription is being confirmed.",
                detail: "There's nothing else you need to do — it'll appear here shortly.",
                action: "Done"
            )

        case .awaitingApproval:
            terminal(
                "This purchase needs approval.",
                detail: "Once it's approved, the app will notice on its own.",
                action: "Done"
            )
        }
    }

    private var buyLabel: String { PlanCopy.buyLabel(model.selectedPlan) }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(.terracotta)
            Text(label)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func terminal(_ title: String, detail: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: onDismiss)
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    /// A way out that does not involve buying anything.
    ///
    /// **Phase 61's sheet had one — a "Got it" button — and losing it was a regression.** In
    /// `.loading`, `.unavailable` and `.idle` the only exit was the sheet's drag, which is
    /// invisible, is the gesture a parent scrolling a long paywall will fight, and is not
    /// available at all to somebody navigating by VoiceOver or Switch Control. A paywall with no
    /// visible way out is a wall, and the register here is a door.
    ///
    /// Absent once a purchase is under way, where the terminal states carry their own **Done**.
    @ViewBuilder
    private var dismissRow: some View {
        if model.purchase == .idle {
            Button("Not just now", action: onDismiss)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .accessibilityHint("Closes this and changes nothing")
        }
    }

    // MARK: The free tier, stated plainly

    /// **Not fine print**, per D2. The generosity of this product is on the prompts, and a parent
    /// who does not subscribe has done nothing wrong and loses nothing they wrote.
    private var freeTierNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Free, always")
            Text(
                "Every daily question and mission, forever. Unlimited writing. "
                    + "And a full export of everything you've kept, always free and always complete."
            )
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    // MARK: Restore and the links Review requires

    private var legalRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.restore() }
            } label: {
                HStack(spacing: 8) {
                    Text("Restore a purchase")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.terracotta)
                    if model.isRestoring { ProgressView().tint(.terracotta) }
                }
            }
            .disabled(model.isRestoring)

            if let notice = model.notice {
                Text(notice)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Review requires both on any paywall. They are absent rather than broken when the
            // build has no URL configured — a link to nowhere is worse than no link.
            FlowRow(spacing: 14) {
                if let terms = LegalLinks.terms {
                    Link("Terms of Use", destination: terms)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                }
                if let privacy = LegalLinks.privacy {
                    Link("Privacy Policy", destination: privacy)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Pieces

/// One thing the subscription covers. A tick rather than a bullet, in sage — the colour this
/// design system already uses for "done", and never red or a warning glyph.
private struct CoveredLine: View {
    let text: String
    @ScaledMetric(relativeTo: .body) private var checkSize: CGFloat = 12

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            // **Scaled, not fixed.** At a hardcoded 12pt beside `body` text that grows to about
            // 53pt at accessibility5, this glyph stayed a dot — the one element on the screen
            // that did not respond to Dynamic Type at all.
            Image(systemName: "checkmark")
                .font(.system(size: checkSize, weight: .semibold))
                .foregroundStyle(Color.sageInk)
            Text(text)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One duration, selectable.
///
/// **Stacked vertically rather than side by side, and that is a Dynamic Type decision.** The
/// annual row carries a price, a cadence and a computed saving; at accessibility sizes three
/// strings on one line is exactly where a price comparison truncates, and a truncated price is
/// the one rendering fault on this screen that costs money to get wrong.
private struct PlanRow: View {
    let plan: OfferedPlan
    let selected: Bool
    let saving: String?
    var isEnabled: Bool = true
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(plan.displayName)
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        // `inkMuted`, not `inkFaint`. The palette records `inkFaint` at 2.13:1
                        // on the canvas and reserves it for "text that is present but is never
                        // the thing being read" — a control saying which plan you are buying is
                        // the opposite of that.
                        .foregroundStyle(selected ? Color.terracotta : Color.inkMuted)
                        .accessibilityHidden(true)
                }

                // Price, cadence and trial on their own line; the saving on its own. Every one of
                // these strings came off the product.
                Text(PlanCopy.priceLine(plan))
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let saving {
                    Text(saving)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.terracottaDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(
                fill: selected ? .terracottaSoft : .surface,
                border: selected ? .terracotta : .border
            )
        }
        .buttonStyle(TapScaleButtonStyle())
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Terms and privacy, from `Config.xcconfig` via Info.plist per rule 5 — no URL in Swift source.
///
/// Nil when the build has no value, and the links are then absent rather than dead. **Review
/// requires both on a paywall**, so an absent one is a release blocker rather than a cosmetic gap;
/// it is written this way so that a missing value cannot ship as a link to nowhere.
enum LegalLinks {
    static var terms: URL? { url("TERMS_URL") }
    static var privacy: URL? { url("PRIVACY_URL") }

    private static func url(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        // **A host, not merely a parseable string.** The xcconfig `//` trap this key documents
        // truncates `https://getvellumapp.com/terms` to `https:` — which `URL(string:)` happily
        // accepts. Without this check the very failure that comment warns about ships as a link
        // to nowhere rather than as an absent link, and a dead Terms link on a paywall is a
        // Review rejection rather than a cosmetic bug.
        guard let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}
