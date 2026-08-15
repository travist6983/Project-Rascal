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

    /// When the control appears. Three ways in, and the order matters.
    ///
    /// **An entry that is already sealed always offers it**, whatever shape it is. `decisions.md`
    /// says a seal is always editable, and the entry that most needs unsealing is the one sealed
    /// by mistake — a rule that only offered the control to text would strand a sealed photo.
    ///
    /// **A `letter` prompt offers it**, as it always has. That is what a letter prompt is for.
    ///
    /// **A freeform write offers it, and that is phase 27.** `slots_for` mints a `letter` slot
    /// only on the 15th, so before this the answer to "I want to write him something today" was
    /// to wait a fortnight. Sealing is what makes an entry a letter, so any freeform writing can
    /// become one — the age is asked only once sealing is chosen, which the control does by
    /// hiding its stepper until the toggle is on.
    ///
    /// **`mode` only separates shapes on the edit path, and that is where the last clause earns
    /// its keep.** Every freeform capture is built `.text` whatever verb opened it — `RootView`
    /// says so: "a freeform entry can hold photos, a voice note, or nothing but words, and the
    /// verb chosen only decides what opens on top of it" — so all four verbs offer sealing, which
    /// is exactly what letter-on-any-day means. `editMode(for:in:)` is the only thing that ever
    /// produces `.media` or `.didIt`, so an unsealed photo opened for editing gets no control:
    /// nobody asked to seal a photograph after the fact, and an already-sealed one is covered by
    /// the first clause above.
    static func isOffered(
        mode: CompletionMode,
        assignment: AssignmentResponse?,
        isSealed: Bool
    ) -> Bool {
        if isSealed { return true }
        if assignment?.promptKind == .letter { return true }
        return assignment == nil && mode == .text
    }

    /// Sealed by default for a letter prompt, because that is what a letter prompt is for.
    ///
    /// **An existing seal wins over both defaults.** Editing seeds from the row: a sealed entry
    /// opens with the toggle on at its own age, and an unsealed one opens with it off. Seeding
    /// from the prompt default instead would mean opening a letter sealed at 16 and saving it at
    /// 18 without anyone touching the stepper.
    ///
    /// A freeform write starts **unsealed** — `decisions.md` calls this freeform-plus-seal, and
    /// the entry is the thing; the seal is a decision made about it, not a default applied to it.
    static func initial(
        for assignment: AssignmentResponse?,
        existingUnlockAtAge: Int? = nil
    ) -> SealSetting {
        if let existingUnlockAtAge {
            // **Not `resolvedAge`, and the difference is the whole point of this branch.** That
            // clamp is for a prompt *default* — a number nobody has committed to yet, where
            // rounding into the stepper's window is the friendly answer. This one is the
            // archive's own value. Clamping it makes `seal.unlockAtAge` differ from
            // `entry.unlockAtAge` before the parent has touched anything, and `saveEdit` then
            // writes the difference back and PATCHes it: an entry sealed at 25 would render
            // "Opens at 21" — contradicting the reader, which says 25 — and an untouched Save
            // would move the archive's seal to 21 permanently.
            //
            // That is precisely the regression `existingUnlockAtAge` was added to prevent, and
            // it was reintroduced one line below by reusing the create path's helper. The
            // stepper does not write back an out-of-range value — `Stepper(value:in:)` only
            // disables the offending button — so an untouched Save now sends what it was given.
            return SealSetting(isSealed: true, age: existingUnlockAtAge)
        }
        guard assignment?.promptKind == .letter else {
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
    /// Only the title changes. A letter prompt asked for a letter, so the control says so; a
    /// freeform write is an entry until sealing makes it one, and calling it a letter before the
    /// toggle is on would name something the parent has not chosen.
    var isLetterPrompt: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: seal.isSealed ? "lock" : "lock.open")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.terracottaDeep)
                    .accessibilityHidden(true)

                Text(isLetterPrompt ? "Seal this letter" : "Seal this entry")
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)

                Spacer(minLength: 8)

                Toggle(isLetterPrompt ? "Seal this letter" : "Seal this entry", isOn: $seal.isSealed)
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
