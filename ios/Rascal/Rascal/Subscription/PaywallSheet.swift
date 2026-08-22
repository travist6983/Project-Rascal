import SwiftUI

/// The membership sheet, and **it is a door.**
///
/// Framed as what membership *adds*, never as what free lacks. No red, no countdown, no urgency,
/// nothing implying the parent has fallen short — `docs/design-system.md`'s copy rules forbid all
/// four, and the copy file's rule 3 is blunter: *"The archive is never the thing being sold."*
///
/// **Every price, period and trial on this screen comes from a `Product`.** There is no currency
/// literal in this file. D1's numbers are in `decisions.md` and in App Store Connect, which is the
/// only place they are correct in more than one country.
///
/// **Every string comes from `MembershipCopy`**, which transcribes the owner's `free-tier-copy.md`.
/// Nothing here is authored at the call site.
///
/// ## One sheet, one header
///
/// This used to carry a `Context` — `.secondParent` and `.settings` — with a different headline and
/// paragraph for each. **Phase 108 retired it**, because the copy file is explicit: *"Presented from
/// a locked card, from Settings, and from the guardian-invite surface. **Same sheet every time.**"*
/// A parameter that no longer changes anything is worse than no parameter, so it is gone rather than
/// left inert. The second-parent claim it used to make is not lost — it is the fifth row of *what
/// membership adds*.
///
/// ## The pronouns
///
/// This sheet renders its strings against `PromptSubject.unknown`, which is the they/them column.
/// **That is deliberate and it is not the same choice `LockedPromptCard` makes.** A locked card is
/// always about one child and reads that child's pronouns; this sheet is about a *household* — it is
/// reached from Settings and from the guardian invite, and its own footnote says *"every child, both
/// parents"* — so there is no child to key on, and in a household with a boy and a girl any choice
/// would be wrong for one of them. Rendering against no subject yields the neutral form of the
/// owner's own sentence rather than a sentence rewritten by hand.
struct PaywallSheet: View {
    @Bindable var model: SubscriptionModel
    var onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView { content }
            .background(Color.canvas)
            // Pinned rather than trailing the scroll, per the design: *"the sheet is never a page
            // you have to reach the end of to escape."* On a 667pt phone everything from the free
            // block down needs a scroll, and the way out must not be down there with it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                    .background(PinnedActionBackdrop())
            }
            .task { await model.load() }
            // An approval, a renewal or a refund arriving on `Transaction.updates` while this is on
            // screen. Without it the view sits correct-but-stale until it is dismissed.
            .onChange(of: SubscriptionCenter.shared.transactionRevision) { _, _ in
                Task { await model.transactionArrived() }
            }
            // Coming back to the app is **not** a transaction — it is a reason to re-read. Ask the
            // server and let it decide; a foreground must not rewrite a pending Ask-to-Buy into
            // "being confirmed", which is what one shared counter did.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshHousehold() }
            }
    }

    /// **Lifted out of the `ScrollView` on purpose, and not for tidiness.** `ImageRenderer` does not
    /// rasterize a scroll view's content — it renders the scroll view's ground and stops — so a
    /// screenshot harness pointed at the whole sheet produces an empty cream rectangle of the right
    /// height and passes. That is exactly the shape of check that reads as evidence and is not.
    var content: some View {
        // 22 between blocks, per the design's grouped-screen rule.
        VStack(alignment: .leading, spacing: 22) {
            header
            addsBlock
            freeBlock
            offerBlock
            footnote
            legalRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Content **and** the pinned actions, for the screenshot harness only.
    ///
    /// `content` alone would render a sheet with no buy button, which is the one thing a paywall
    /// screenshot exists to show. `body` cannot be rendered because of the `ScrollView`.
    var renderable: some View {
        VStack(alignment: .leading, spacing: 26) {
            content
            actions.padding(.horizontal, 24).padding(.bottom, 12)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(neutral(MembershipCopy.title))
                .typeRole(.detailTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(neutral(MembershipCopy.subtitle))
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What membership adds

    /// **No icons.** The copy file asks for a plain list — *"no icons competing with the
    /// terracotta"* — which also retires the sage tick the shipped `CoveredLine` drew. A tick beside
    /// a thing you do not have yet is a small lie.
    private var addsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(MembershipCopy.addsLabel)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MembershipCopy.adds, id: \.self) { line in
                    Text(neutral(line))
                        .typeRole(.body)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: What stays free

    /// **Real space, above the plan rows, at reading size.**
    ///
    /// Set in `body` rather than `metadata` — the design's words are *"the Field vocabulary, so it
    /// reads as a stated fact rather than a footnote"* — and placed before the prices rather than
    /// after them, which is where a paywall's fine print goes. This block is the reason the sheet is
    /// a door, and compressing it is the specific failure both the design and the phase brief call
    /// out.
    private var freeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(MembershipCopy.freeLabel)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MembershipCopy.stayFree, id: \.self) { line in
                    Text(neutral(line))
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.surface,
                in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
        }
    }

    // MARK: The offer, or the reason there isn't one

    @ViewBuilder
    private var offerBlock: some View {
        // **The purchase outcome outranks the offer.** This used to be emitted from inside the
        // `.ready` branch, so a background refresh resolving to `.unavailable` — one dropped
        // request — replaced "Your subscription is being confirmed" with a retry, for a parent who
        // had already been charged.
        if model.purchase == .idle {
            switch model.phase {
            case .loading:
                loading
            case .unavailable(.products):
                // The ordinary state on every device today. One `Notice`, no retry, and the primary
                // action is absent rather than disabled — see `actions`.
                Notice(text: MembershipCopy.productsUnavailable)
            case .unavailable(.household(let message)):
                householdUnavailable(message)
            case .ready(let offer, _):
                planPicker(offer)
            }
        } else {
            if case .ready(let offer, _) = model.phase { planPicker(offer) }
            purchaseState
        }
    }

    /// **Bounded.** `SubscriptionModel.loadOffer()` times out into `.unavailable(.products)`, so
    /// this never becomes a spinner with no terminal state.
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

    /// The one unavailable case that keeps a retry, because it is the one where retrying can work.
    private func householdUnavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Notice(text: message)
            Button("Try again") { Task { await model.load() } }
                .typeRole(.body)
                // `terracottaDeep`, not `terracotta`: the palette measures `terracotta` at 4.25:1 on
                // canvas, which fails AA for anything that is not large text. See `Notice`.
                .foregroundStyle(Color.terracottaDeep)
        }
    }

    @ViewBuilder
    private func planPicker(_ offer: SubscriptionOffer) -> some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            // **Locked once a purchase is in flight.** `buy()` captures the plan before it suspends,
            // so changing it here could not buy the wrong thing — but the selection moving under
            // "Finishing up" reads as though it could, and on a screen about money that is its own
            // defect.
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

    private var footnote: some View {
        Text(neutral(MembershipCopy.footnote))
            .typeRole(.metadata)
            // **`inkMuted`, not `inkFaint`.** The design draws this line in `inkFaint`, which
            // measures **2.13:1** on canvas and fails AA at every size. It is also a repeat: the
            // phase 37b review already found `inkFaint` at ~2.1:1 on the unselected plan row, a few
            // points up this same sheet. `inkMuted` is 5.16:1 and is what every other quiet line
            // here already uses.
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The action, and the confirmation gap

    /// The pinned pair at the bottom.
    ///
    /// **The primary is absent, not disabled, when there is nothing to buy.** A disabled button is a
    /// thing to keep tapping, and with `.products` now the ordinary state it would be the ordinary
    /// experience. `Not now` is always there, so the sheet always has a visible way out — phase 37b
    /// records losing that as a regression: *"A paywall with no visible way out is a wall, and the
    /// register here is a door."*
    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 4) {
            if model.purchase == .idle {
                if model.household?.isSubscribed == true {
                    // **The household became subscribed without this screen buying anything** — a
                    // restore, another guardian subscribing, or a purchase made on another device
                    // arriving through the listener.
                    Button("Done", action: onDismiss)
                        .buttonStyle(PrimaryButtonStyle())
                } else if canOffer {
                    Button(MembershipCopy.primaryAction) {
                        Task { await model.buy() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canBuy)
                }

                OnboardingSecondaryButton(title: MembershipCopy.notNow, action: onDismiss)
                    .accessibilityHint(MembershipCopy.notNowHint)
            } else {
                purchaseAction
            }
        }
    }

    /// Whether a buy button belongs on screen at all. False for both unavailable cases and while
    /// loading — there is no offer to act on, so there is no action.
    private var canOffer: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    /// What is happening to a purchase, in the body of the sheet.
    @ViewBuilder
    private var purchaseState: some View {
        switch model.purchase {
        case .idle:
            EmptyView()
        case .failed(let message):
            Text(message)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        case .purchasing:
            busy("Talking to the App Store")
        case .confirming:
            // The purchase went through and the server has not been told yet. Named for what is
            // happening rather than for the machinery.
            busy("Finishing up")
        case .subscribed:
            terminal("You're subscribed. Thank you.", detail: "Everything is shared with the household now.")
        case .late:
            // **Not an error, and it does not read as one.** The purchase succeeded; the
            // confirmation is late. Nothing further is asked of the parent and nothing retries.
            terminal(
                "Your membership is being confirmed.",
                detail: "There's nothing else you need to do — it'll appear here shortly."
            )
        case .awaitingApproval:
            terminal("This purchase needs approval.", detail: "Once it's approved, the app will notice on its own.")
        }
    }

    /// The pinned control during and after a purchase.
    @ViewBuilder
    private var purchaseAction: some View {
        switch model.purchase {
        case .purchasing, .confirming:
            EmptyView()
        case .failed:
            Button(MembershipCopy.primaryAction) { Task { await model.buy() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canBuy)
            OnboardingSecondaryButton(title: MembershipCopy.notNow, action: onDismiss)
        case .idle, .subscribed, .late, .awaitingApproval:
            Button("Done", action: onDismiss)
                .buttonStyle(PrimaryButtonStyle())
        }
    }

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

    private func terminal(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Restore and the links Review requires

    /// Kept from the shipped sheet, and deliberately below the free block rather than beside the
    /// action: Review requires Terms and Privacy on any paywall, and restore is a rare path that
    /// should not compete with the two things this screen is actually for.
    private var legalRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.restore() }
            } label: {
                HStack(spacing: 8) {
                    Text("Restore a purchase")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.terracottaDeep)
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

            // Review requires both on any paywall. They are absent rather than broken when the build
            // has no URL configured — a link to nowhere is worse than no link.
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
    }

    // MARK: Copy

    /// Render a copy string with **no child**, which the token table resolves to they/them.
    ///
    /// See this type's note on pronouns: the sheet is about a household, so it must not read one
    /// child's pronouns. `PromptSubject.unknown` is the environment's own default and is documented
    /// as *"Renders they/them"*.
    private func neutral(_ string: String) -> String {
        PromptTokens.render(string, for: .unknown)
    }
}

// MARK: - Pieces

/// One duration, selectable.
///
/// **Stacked vertically rather than side by side, and that is a Dynamic Type decision.** The annual
/// row carries a price, a cadence and a computed saving; at accessibility sizes three strings on one
/// line is exactly where a price comparison truncates, and a truncated price is the one rendering
/// fault on this screen that costs money to get wrong.
///
/// **No radio, no check mark**, per the approved design. Selection is carried by the fill and a
/// 1.5pt terracotta border — which also retires the `inkFaint` radio the phase 37b review found at
/// ~2.1:1. A control whose only selected-state signal fails contrast is not a control. VoiceOver is
/// told through `.isSelected`, which is where that information actually belongs.
private struct PlanRow: View {
    let plan: OfferedPlan
    let selected: Bool
    let saving: String?
    var isEnabled: Bool = true
    let select: () -> Void

    /// 18 — the compact-row radius, one step in from a card. The design draws these smaller than
    /// `Layout.cardRadius` so two of them stacked do not read as two more cards.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                // **The product's own title, and it is a Review requirement rather than a
                // decoration.**
                //
                // The approved design's plan row is price-and-period only, with no title. That is
                // the artboard drawing content and stopping; Guideline 3.1.2 requires the
                // subscription's *name* alongside its length and price, and a Review requirement is
                // not something a mockup can design away. Restyling this row into the mockup's exact
                // shape would have deleted it.
                Text(plan.displayName)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Price, cadence and trial on one line; the saving on its own. Every one of these
                // strings came off the product — see `PlanCopy`.
                Text(PlanCopy.priceLine(plan))
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let saving {
                    Text(saving)
                        .typeRole(.metadata)
                        // `terracottaDeep` on a 12% terracotta wash measures 5.73:1. Plain
                        // `terracotta` would be 4.25:1 and fail AA at 13pt — the same substitution
                        // `KindBadge` already makes, for the same reason.
                        .foregroundStyle(Color.terracottaDeep)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.terracotta.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.terracottaSoft : Color.surface, in: shape)
            .overlay(
                shape.strokeBorder(
                    selected ? Color.terracotta : Color.border,
                    lineWidth: selected ? 1.5 : Layout.borderWidth
                )
            )
            .contentShape(shape)
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
        // accepts. Without this check the very failure that comment warns about ships as a link to
        // nowhere rather than as an absent link, and a dead Terms link on a paywall is a Review
        // rejection rather than a cosmetic bug.
        guard let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

#if DEBUG
/// Two plans for the canvas.
///
/// **Not a claim about price, and it contains no currency literal.** `displayPrice` is *formatted*
/// from the amount rather than written out, which is the same rule the shipped code follows and
/// which `SubscriptionTests.noCurrencyLiterals` enforces across this whole directory — a source scan
/// that a hardcoded `"$59.99"` here would have failed, correctly. The amounts are D1's, so a
/// reviewer looking at a screenshot is not misled about the plan.
///
/// `SubscriptionTests` has its own `SubscriptionOffer.double` and this deliberately does not reach
/// for it: a test fixture is not in the app target, and a preview that borrowed one would tie the
/// canvas to the test suite.
extension SubscriptionOffer {
    static var preview: SubscriptionOffer {
        let format = Decimal.FormatStyle.Currency(code: "USD")
        func plan(
            _ plan: SubscriptionPlan,
            id: String,
            name: String,
            amount: Decimal,
            unit: SubscriptionPeriodValue.Unit
        ) -> OfferedPlan {
            OfferedPlan(
                id: id,
                plan: plan,
                displayName: name,
                displayPrice: amount.formatted(format),
                price: amount,
                priceFormat: format,
                period: SubscriptionPeriodValue(value: 1, unit: unit),
                trial: SubscriptionPeriodValue(value: 2, unit: .week)
            )
        }

        return SubscriptionOffer(
            annual: plan(
                .annual, id: SubscriptionProducts.annual, name: "Yearly",
                amount: 59.99, unit: .year
            ),
            monthly: plan(
                .monthly, id: SubscriptionProducts.monthly, name: "Monthly",
                amount: 5.99, unit: .month
            )
        )
    }
}

#Preview("Membership sheet — annual") {
    PaywallSheet(model: SubscriptionModel(previewing: .ready(.preview, familyID: UUID()))) {}
}

#Preview("Membership sheet — products unavailable") {
    PaywallSheet(model: SubscriptionModel(previewing: .unavailable(.products))) {}
}

#Preview("Membership sheet — household unreachable") {
    PaywallSheet(
        model: SubscriptionModel(
            previewing: .unavailable(
                .household("We couldn't reach your household just now, so there's nothing to show yet.")
            )
        )
    ) {}
}

#Preview("Membership sheet — unavailable, XXL") {
    PaywallSheet(model: SubscriptionModel(previewing: .unavailable(.products))) {}
        .environment(\.dynamicTypeSize, .xxLarge)
}

#Preview("Membership sheet — annual, AX3") {
    PaywallSheet(model: SubscriptionModel(previewing: .ready(.preview, familyID: UUID()))) {}
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
