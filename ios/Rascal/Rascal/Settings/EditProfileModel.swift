import Foundation

/// Editing the signed-in person: their display name, and nothing else.
///
/// `display_name` is the only human-readable identity in the product. Apple sends one exactly
/// once, at first authorization, and the relay email is unreliable enough that `users.email` is
/// nullable — so an account that cannot fix its name is labelled with whatever Apple sent that
/// one time, forever. That is the whole reason `PATCH /me` exists.
///
/// Email is read-only here and it is **nullable**. A row that renders an empty value, or worse
/// force-unwraps one, is the defect this model exists to make impossible: the view asks for
/// `emailDisplay` and gets words either way.
@MainActor
@Observable
final class EditProfileModel {

    /// The server trims and then rejects blank or over-length with `invalid_display_name`. The
    /// client mirrors the bound so Save is disabled rather than round-tripping a known refusal,
    /// and still surfaces the server's message if the two ever disagree.
    static let maxDisplayNameLength = 100

    var displayName: String

    private(set) var isSaving = false
    private(set) var notice: String?

    /// Never a `String` with an empty value standing in for absent. Nil is a real state here.
    let email: String?

    private let api: APIClient
    private let original: String

    init(user: UserResponse?, api: APIClient) {
        self.api = api
        self.displayName = user?.displayName ?? ""
        self.original = user?.displayName ?? ""
        // **The record is the only source, and there is no stand-in.** This used to fall back to
        // `AppConfig.devLoginEmail`, which is a build-configuration constant with a hardcoded
        // `dev@rascal.local` behind it — so an Apple account whose relay address came back null
        // was shown a developer's email address and told it was theirs. A missing email is a
        // state this screen can say out loud; inventing one is not.
        self.email = user?.email
    }

    /// The words a null email renders as, in the Settings row and in this sheet alike. Two
    /// spellings of "we do not have one" is two answers to the same question.
    static let absentEmail = "Not provided"

    /// What the read-only email row shows. Words in both states, never a blank.
    var emailDisplay: String { email ?? Self.absentEmail }

    /// True when there is no email to show, so the row can be set in `inkMuted` rather than ink.
    var emailIsMissing: Bool { email == nil }

    var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasChanges: Bool { trimmedName != original }

    var isValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= Self.maxDisplayNameLength
    }

    var canSave: Bool { hasChanges && isValid && !isSaving }

    /// Shown under the field as it is typed past the limit — the same bound the server enforces,
    /// stated before the write rather than after it.
    var lengthWarning: String? {
        guard trimmedName.count > Self.maxDisplayNameLength else { return nil }
        return "That's longer than \(Self.maxDisplayNameLength) characters."
    }

    // MARK: Saving

    /// Returns the updated user on success, nil on failure. The sheet stays open on nil with the
    /// typed name intact.
    func save() async -> UserResponse? {
        guard canSave else { return nil }
        isSaving = true
        notice = nil
        defer { isSaving = false }

        do {
            return try await api.updateMe(displayName: trimmedName)
        } catch let error as APIError {
            notice = Self.explain(error)
            return nil
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Switched on `code`. `invalid_display_name` carries the server's own sentence naming the
    /// bound it rejected, which belongs under the text field it came from.
    private static func explain(_ error: APIError) -> String {
        switch error.code {
        case .invalidDisplayName:
            error.userMessage
        case .unauthenticated, .tokenExpired:
            "Signed out. Sign in again to change this."
        default:
            error.userMessage
        }
    }
}
