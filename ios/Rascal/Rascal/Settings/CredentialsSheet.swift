import SwiftUI

/// The ways into this account, and how to add or remove one.
///
/// **The copy rules are the hard part of this screen, not the list.** Removing a sign-in method
/// is the one action in the app that could lock a parent out of their child's archive, and the
/// server refuses to let it happen — so the refusal has to read as the app looking after them
/// rather than as an error they caused. No red, no alarm, no "failed". A sentence that says why
/// and what to do instead.
@MainActor
@Observable
final class CredentialsModel {
    private(set) var credentials: [CredentialSummary] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    /// Plain sentences shown inline. Never an error dialog — see the type's doc comment.
    private(set) var notice: String?
    /// Set after an address is added, and cleared when the list is next loaded.
    private(set) var pendingAddress: String?

    private let api: APIClient

    init(api: APIClient) { self.api = api }

    var activeCount: Int { credentials.filter(\.isActive).count }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            credentials = try await api.credentials()
            notice = nil
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Add an address. **Typed by the parent, never prefilled from `users.email`** — the
    /// production account is on an Apple private relay, and Apple can stop forwarding one
    /// silently, so a prefilled field would offer the address most likely to be dead.
    func add(email: String) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await api.addEmailCredential(address)
            pendingAddress = address.lowercased()
            notice = nil
            await load()
        } catch let error as APIError {
            notice = Self.explainAdd(error)
        } catch {
            notice = error.localizedDescription
        }
    }

    func remove(_ credential: CredentialSummary) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await api.removeCredential(id: credential.id)
            notice = nil
            await load()
        } catch let error as APIError {
            notice = Self.explainRemove(error)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// **`last_credential` is not an error state and must not read as one.**
    ///
    /// It is the server declining to let somebody lock themselves out of eighteen years of
    /// their child's life. The sentence says what is true and what to do — nothing about
    /// failure, nothing to dismiss.
    nonisolated static func explainRemove(_ error: APIError) -> String {
        if case .api(let code, _, _, _) = error, code == .lastCredential {
            return "This is the only way to sign in to your archive right now. "
                + "Add another one first, and then this can come off."
        }
        return error.userMessage
    }

    nonisolated static func explainAdd(_ error: APIError) -> String {
        if case .api(let code, _, _, _) = error, code == .credentialInUse {
            return "That address already signs in to a different account."
        }
        return error.userMessage
    }
}

struct CredentialsSheet: View {
    @Bindable var model: CredentialsModel
    @Environment(\.dismiss) private var dismiss

    @State private var newAddress = ""
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.credentials) { credential in
                        row(credential)
                    }
                } header: {
                    Text("Ways to sign in")
                } footer: {
                    Text(
                        "Sign in with Apple is how this archive was made. "
                        + "Anything else you add here is another way into the same archive."
                    )
                }

                Section {
                    Button("Add an email address") { showingAdd = true }
                        .disabled(model.isWorking)
                } footer: {
                    Text(
                        "We'll send a link to that address. Opening it is what turns it on, "
                        + "so a typo costs nothing."
                    )
                }

                if let notice = model.notice {
                    Section {
                        // Inline and quiet. `inkMuted` rather than any alert colour: nothing
                        // here is an emergency, including the refusal to remove the last one.
                        Text(notice)
                            .typeRole(.body)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
            }
            .navigationTitle("Signing in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .alert("Add an email address", isPresented: $showingAdd) {
                TextField("you@example.com", text: $newAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                Button("Cancel", role: .cancel) { newAddress = "" }
                Button("Send the link") {
                    let address = newAddress
                    newAddress = ""
                    Task { await model.add(email: address) }
                }
            } message: {
                Text("Type the address you want to use. We'll send a link to it.")
            }
        }
    }

    @ViewBuilder
    private func row(_ credential: CredentialSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.displayName)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Text(subtitle(credential))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
            // Offered on every row, including the last one. The refusal comes from the server
            // and is shown as a sentence — hiding the control instead would leave a parent
            // wondering whether the app was broken.
            Button("Remove") {
                Task { await model.remove(credential) }
            }
            .disabled(model.isWorking)
            .typeRole(.metadata)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ credential: CredentialSummary) -> String {
        if credential.isPending {
            // Not "revoked". This one was never on — the link has not been opened yet.
            return "\(credential.subjectHint) · check your email for the link"
        }
        if !credential.isActive {
            return "\(credential.subjectHint) · off"
        }
        return credential.subjectHint
    }
}
