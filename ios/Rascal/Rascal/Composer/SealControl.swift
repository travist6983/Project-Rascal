import SwiftUI

/// The one control that sets `unlock_at_age` at creation time.
///
/// The reader for this shipped in Phase 4 and is complete — `EntryDetailScreen.sealedCard`, the
/// `EntryCard` sealed skin, the Sealed filter. Nothing wrote one. Meanwhile the library serves
/// eight active `letter` prompts, so "write him something about money you wish someone had told
/// you at nineteen" produced an ordinary entry his son could read the next morning.
///
/// **The copy here has to agree with the reader's**, because they describe the same thing from
/// two ends. The reader says "Sealed until 18." on Entry Detail and "Opens at 18." on the card;
/// this says "Opens at 18." for the same reason.

// MARK: - The setting

/// Whether this entry seals, and at what age. The composer's state; `unlockAtAge` is what goes
/// on the wire.
nonisolated struct SealSetting: Equatable, Sendable {
    /// 10–21. Below ten a letter is being written to a child who cannot read it as one; above
    /// twenty-one it is a letter to an adult, and `docs/decisions.md` open item 2 is still
    /// deciding where the handoff sits. Neither bound is load-bearing — the field is per-entry
    /// and the server accepts 0–120 — they are the range a stepper should offer.
    static let range = 10...21

    /// What a letter prompt with no `default_unlock_age` seals at. Matches the reader's own
    /// examples and open item 2's leading candidate.
    static let fallbackAge = 18

    var isSealed: Bool
    var age: Int

    /// **Nil is the whole point when sealing is off.** Not zero — zero is a value, and
    /// `unlock_at_age IS NOT NULL` is exactly how every reader decides a row is sealed, so a
    /// zero would render as "Opens at 0." rather than as an ordinary entry.
    var unlockAtAge: Int? { isSealed ? age : nil }

    /// The control is offered for **letter prompts only**, and never while editing.
    ///
    /// Sealing a freeform entry is a separate decision, and editing the seal on an entry that
    /// already exists has no UI this phase — `PATCH` supports it, nothing calls it.
    static func isOffered(for assignment: AssignmentResponse?, isEditing: Bool) -> Bool {
        !isEditing && assignment?.promptKind == .letter
    }

    /// Sealed by default for a letter prompt, because that is what a letter prompt is for.
    static func initial(for assignment: AssignmentResponse?, isEditing: Bool = false) -> SealSetting {
        guard isOffered(for: assignment, isEditing: isEditing) else {
            return SealSetting(isSealed: false, age: fallbackAge)
        }
        return SealSetting(isSealed: true, age: resolvedAge(assignment?.unlockAtAge))
    }

    /// The prompt's own `default_unlock_age`, which `GET /today` already carries on the
    /// assignment, clamped into the range the stepper offers. The server permits 0–120 and the
    /// seed library is free to say 25; a stepper that cannot reach its own starting value is
    /// worse than one that starts at the nearest age it can show.
    static func resolvedAge(_ promptDefault: Int?) -> Int {
        guard let promptDefault else { return fallbackAge }
        return min(max(promptDefault, range.lowerBound), range.upperBound)
    }

    /// The stepper's label, and **the sentence the reader already uses.** `EntryCard` writes
    /// "Opens at 18." on a sealed row; this is the same words at the other end of the object's
    /// life, which is the only reason to phrase it this way rather than "Age" or "Unlocks at".
    var openingLine: String { "Opens at \(age)" }

    /// Plain, and about what happens rather than about how it feels. Deliberately does **not**
    /// repeat the age — the stepper sits directly above it and says so, and a four-line card that
    /// prints "Opens at 13" twice reads as a stutter.
    var explanation: String {
        isSealed
            ? "It waits in the archive until then, and you can still open it yourself."
            : "Saved like any other entry, and readable straight away."
    }
}

// MARK: - The control

/// Washed with the same gradient the reader uses for a sealed card, over `sealedBorder`. Reusing
/// the reader's treatment rather than inventing a second one is the point: this is the same
/// object, being made.
struct SealControl: View {
    @Binding var seal: SealSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: seal.isSealed ? "lock" : "lock.open")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.terracottaDeep)
                    .accessibilityHidden(true)

                Text("Seal this letter")
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)

                Spacer(minLength: 8)

                Toggle("Seal this letter", isOn: $seal.isSealed)
                    .labelsHidden()
                    .tint(.terracotta)
            }

            // What it is, then when, then what that means. The age has to come before the
            // sentence that says "until then".
            if seal.isSealed {
                Stepper(value: $seal.age, in: SealSetting.range) {
                    Text(seal.openingLine)
                        .typeRole(.body)
                        .foregroundStyle(Color.ink)
                }
                // Read as one thing. Without this VoiceOver announces the label and the value
                // separately and the age arrives detached from what it means.
                .accessibilityLabel("Opens at age")
                .accessibilityValue("\(seal.age)")
            }

            Text(seal.explanation)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(wash: Gradients.wash, border: .sealedBorder)
    }
}
