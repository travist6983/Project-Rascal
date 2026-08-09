import SwiftUI

/// Who this archive is for, which account is holding it, and the way out.
///
/// Deliberately small. There is no preferences model, no toggles, no notification section, no
/// export button — none of those exist yet, and a settings screen full of controls that do
/// nothing is worse than a short one that is true.
///
/// The child's name, birthdate, and timezone are shown and **not edited here.** `PATCH
/// /children/{id}` exists, but a birthdate is the thing every stored `child_age_months` in the
/// archive was computed against, and offering to change it beside an app version number is not
/// the weight that decision deserves.
struct SettingsScreen: View {
    let childId: UUID
    let session: AppSession

    @State private var child: ChildResponse?
    @State private var notice: String?
    @State private var confirmingSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)

                if let child { childCard(child) }
                accountCard
                aboutCard

                if let notice {
                    Text(notice)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                }

                signOutButton
            }
            .padding(Layout.screenMargin)
            .padding(.bottom, 20)
        }
        .background(Color.canvas)
        .task { await loadChild() }
        .confirmationDialog(
            "Sign out?",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("The archive stays on the server. Anything still waiting to upload from this phone will finish after you sign back in.")
        }
    }

    // MARK: Cards

    private func childCard(_ child: ChildResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Archive")
            Text(child.name)
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            // The server's `age_months`, never recomputed from the birthdate here.
            Text(AgeText.greeting(child.ageMonths))
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)

            VStack(spacing: 8) {
                row("Born", birthdate(child.birthdate))
                row("Timezone", child.familyTimezone)
                row("You are", child.role.capitalized)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Account")
            VStack(spacing: 8) {
                row("Signed in as", session.user?.email ?? AppConfig.devLoginEmail)
                if let name = session.user?.displayName, !name.isEmpty {
                    row("Name", name)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("App")
            VStack(spacing: 8) {
                row("Version", Self.version)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
            Spacer(minLength: 12)
            Text(value)
                .typeRole(.metadata)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Terracotta is the primary action colour and signing out is not one. A bordered capsule
    /// in ink reads as available without reading as the thing to do — and nothing here is red,
    /// because red is an urgency state and this is a choice, not an alarm.
    private var signOutButton: some View {
        Button { confirmingSignOut = true } label: {
            Text("Sign out")
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        }
        .buttonStyle(TapScaleButtonStyle())
        .padding(.top, 4)
    }

    // MARK: Values

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "—"
        }
    }

    /// `YYYY-MM-DD` from the server, which is a calendar day rather than an instant. Parsed in
    /// UTC and formatted for reading; shown verbatim if it is ever something else, because a
    /// birthdate rendered as "1 January 1970" would be worse than a raw string.
    private func birthdate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }
        // Formatted in UTC too, or a birthdate would render as the day before for anyone west
        // of Greenwich — the same off-by-one that makes a calendar day and an instant different
        // things everywhere else in this app.
        let display = DateFormatter()
        display.locale = .autoupdatingCurrent
        display.timeZone = TimeZone(identifier: "UTC")
        display.dateStyle = .long
        display.timeStyle = .none
        return display.string(from: date)
    }

    private func loadChild() async {
        do {
            let children = try await session.api.children()
            child = children.first { $0.id == childId } ?? children.first
        } catch let error as APIError {
            // The screen still shows the account and the version. Offline is not a failure
            // worth an empty page.
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }
}
