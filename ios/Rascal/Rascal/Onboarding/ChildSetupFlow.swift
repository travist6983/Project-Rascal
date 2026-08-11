import SwiftUI

/// The four steps between signing in and Today: name, birthdate, timezone, avatar.
///
/// Every step writes the draft through on change, so a kill anywhere in here resumes on the same
/// screen with the same input. The child itself is created once, at the very end — see
/// `OnboardingSession.createChild`.
struct ChildSetupFlow: View {
    @Bindable var session: OnboardingSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressBar(step: session.draft.step)

            ZStack(alignment: .topLeading) {
                step
                    .transition(transition)

                if session.draft.step.previous != nil {
                    OnboardingBackButton { session.goBack() }
                        .padding(.leading, OnboardingLayout.margin - 12)
                        .padding(.top, 14)
                } else {
                    // **The way out of the first step.** Signing in with the wrong Apple ID is
                    // easy to do and, without this, impossible to undo: back goes nowhere, there
                    // is no Settings yet, and setup cannot be completed for an account that isn't
                    // yours. A state with no exit is a defect however tidy it looks.
                    Button("Not you?") { Task { await session.signOut() } }
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.leading, OnboardingLayout.margin)
                        .padding(.top, 24)
                        .accessibilityLabel("Sign out and use a different account")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.28), value: session.draft.step)
    }

    @ViewBuilder
    private var step: some View {
        switch session.draft.step {
        case .name: ChildNameStep(session: session)
        case .birthdate: BirthdateStep(session: session)
        case .timezone: TimezoneStep(session: session)
        case .avatar: AvatarStep(session: session)
        case .notifications: NotificationStep(session: session)
        }
    }

    /// Fade plus a slight rise — the design system's list-insert motion, reused because a step
    /// arriving is the same kind of event. Nothing slides sideways; this is not a page turn.
    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }
}

// MARK: - Name

private struct ChildNameStep: View {
    @Bindable var session: OnboardingSession
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingStepScaffold(
            title: "What's your kid's name?",
            subtitle: "First name is enough. You can change it later."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                TextField(
                    "",
                    text: $session.draft.name,
                    prompt: Text("First name").foregroundStyle(Color.inkFaint)
                )
                .typeRole(.display)
                .foregroundStyle(Color.ink)
                // The caret, which the export draws in terracotta.
                .tint(.terracotta)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focused)
                .accessibilityLabel("Your kid's first name")
                .onChange(of: session.draft.name) { _, value in
                    // The server enforces 200. Trimming at the keyboard means the parent never
                    // types into a field that is going to be refused on the next screen.
                    if value.count > OnboardingDraft.nameLimit {
                        session.draft.name = String(value.prefix(OnboardingDraft.nameLimit))
                    }
                    session.persist()
                }
                .onSubmit(advance)

                Rectangle()
                    .fill(Color.terracotta)
                    .frame(height: 2)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
            }
        } footer: {
            Button("Continue", action: advance)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!session.draft.isNameValid)
        }
        .task {
            // Focused on appear: the only thing this screen wants is one word, and making the
            // parent tap the field first is a step for nothing.
            focused = true
        }
    }

    private func advance() {
        guard session.draft.isNameValid else { return }
        focused = false
        session.advance()
    }
}

// MARK: - Birthdate

private struct BirthdateStep: View {
    @Bindable var session: OnboardingSession

    /// The wheel's own value. Mirrored into the draft as a `yyyy-MM-dd` string on change, which
    /// is the form that will be sent — see `OnboardingDraft.birthdate`.
    ///
    /// Today is the default because today is inside the picker's range. It is a placeholder a
    /// parent always moves, and the point is that it is *valid* while they do — the first real
    /// screen of the app must not open on an error nobody has made yet.
    @State private var date = Date()

    private var name: String {
        let trimmed = session.draft.trimmedName
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingStepScaffold(
            title: "When was \(name) born?",
            // Neutral on purpose. The seeded prompt library is he/him deliberately — see
            // `docs/decisions.md` open item 10 — but client strings are neutral and stay that
            // way, so this says "an exact age" rather than picking a pronoun.
            subtitle: "It's what stamps every entry with an exact age, forever."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // **Bounded at today, which is what removed the error state.** This was unbounded
                // on the theory that a picker which cannot express a wrong answer cannot tell the
                // parent they gave one — but the wrong answer it allowed was also *persisted*, so
                // the screen could open already refusing to continue. A bound the parent cannot
                // cross needs no sentence underneath it.
                //
                // `.environment(\.colorScheme, .light)` is the contrast fix, and it is the same
                // one `EditChildSheet` and `ComposerView` already carry on their pickers. The
                // palette is fixed light-mode ink on cream with no dark variant and the app pins
                // no scheme, so on a phone in Dark Mode `UIDatePicker` resolved *system* label
                // and fill colours for dark appearance and drew near-white rows on the cream
                // canvas — measured at 1.03:1. Everything else on this screen was legible because
                // everything else on this screen is an explicit `Palette` colour.
                //
                // Deliberately **no** `.foregroundStyle` here, unlike those two siblings: it is a
                // no-op on `.wheel`. Bisected in the harness — foreground style alone left the
                // rows at 1.03:1, the colour scheme alone fixed them, and the two together were
                // indistinguishable from the colour scheme alone.
                DatePicker(
                    "Birthdate",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .environment(\.colorScheme, .light)
                .onChange(of: date) { _, _ in write() }

                ageEcho
            }
        } footer: {
            Button("Continue") { session.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
        }
        .task {
            // A draft written by the build that had no bound can hold a future date, and that is
            // exactly the state a phone in TestFlight is in. Clamping on restore corrects it
            // rather than handing an out-of-range value to a picker that can no longer show it —
            // and `write()` puts the corrected value back, so the bad draft does not survive.
            if let stored = session.draft.birthdate,
               let restored = EditChildModel.dayFormatter.date(from: stored) {
                date = BirthdateRule.clamped(restored)
            }
            write()
        }
    }

    /// The confirmation line, and now the only thing under the wheel.
    ///
    /// It always renders: with the picker bounded there is no invalid state left for it to
    /// report, and this was always the better catch anyway — "17 years, 3 months" under a date is
    /// unmissable in a way that a valid-looking 2008 is not.
    private var ageEcho: some View {
        HStack(spacing: 8) {
            Text("Today")
                .typeRole(.label)
                .foregroundStyle(Color.inkMuted)
            Chip(
                text: DraftAge.label(from: date),
                foreground: .periwinkle,
                background: .periwinkleSoft
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today, \(DraftAge.spoken(from: date))")
    }

    private func write() {
        session.draft.birthdate = EditChildModel.dayFormatter.string(from: date)
        session.persist()
    }
}

// MARK: - Timezone

private struct TimezoneStep: View {
    @Bindable var session: OnboardingSession
    @State private var showingPicker = false

    private var zone: String { session.draft.timezone }

    var body: some View {
        OnboardingStepScaffold(
            title: "Where does \(session.draft.trimmedName.isEmpty ? "your kid" : session.draft.trimmedName) wake up?",
            // Said plainly, because this is the field a parent is most likely to wave past and
            // the one the whole schedule is built on. The server computes "what day is it" in
            // this zone; the phone never does.
            subtitle: "It decides when a new prompt arrives and when today ends."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("We'll use \(zone) for daily prompts.")
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    // The offset and nothing else. The sentence above already carries the whole
                    // identifier, so repeating the region under it just says "America" beneath
                    // "America/Detroit" — which a screenshot at XXL made obvious.
                    Chip(text: TimeZoneCatalog.offsetLabel(zone), background: .chipPlain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .accessibilityElement(children: .combine)

                Button("Change") { showingPicker = true }
                    .typeRole(.body)
                    .foregroundStyle(Color.terracotta)
                    .accessibilityHint("Pick a different timezone")
            }
        } footer: {
            Button("Continue") { session.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
        }
        .sheet(isPresented: $showingPicker) {
            // The same searchable list Settings uses. Every zone `zoneinfo` knows, so a parent
            // in a zone nobody shortlisted can still set it.
            TimeZonePickerSheet(selection: $session.draft.timezone)
        }
        .onChange(of: session.draft.timezone) { _, _ in session.persist() }
    }
}
