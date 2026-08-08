import SwiftData
import SwiftUI

struct ComposerRequest: Identifiable {
    let id = UUID()
    let childId: UUID
    let assignment: AssignmentResponse?
    let mode: CompletionMode
}

/// Writing an entry. Opens knowing its completion mode, because "we did it" and "write it" are
/// different gestures, not the same form with a different label.
struct ComposerView: View {
    let request: ComposerRequest
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Backdating is a first-class flow, so this is a real choice and not a hidden setting.
    @State private var occurredAt = Date()
    @State private var showDatePicker = false
    @State private var text = ""
    @State private var didIt = false
    @State private var saving = false
    @State private var notice: String?
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DatePill(date: $occurredAt, isExpanded: $showDatePicker)

                    if let assignment = request.assignment {
                        quotedPrompt(assignment)
                    }

                    switch request.mode {
                    case .text: writeIt
                    case .didIt: didItControl
                    case .media, .unknown: captureComingSoon
                    }

                    if let notice {
                        Text(notice)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving" : "Save") { Task { await save() } }
                        .foregroundStyle(canSave ? Color.terracotta : Color.inkMuted)
                        .disabled(!canSave || saving)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Modes

    /// A clean field on canvas, with nothing competing with it.
    private var writeIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("What happened")
            TextEditor(text: $text)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180, alignment: .topLeading)
                .padding(10)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
                .focused($writing)
        }
    }

    /// This has to read as complete and legitimate, not degraded. Half the library produces no
    /// artifact, and a note on a did-it mission stays a did-it entry — the server derives the
    /// type and will not reclassify it because the parent wrote something.
    private var didItControl: some View {
        VStack(spacing: 16) {
            Button {
                didIt.toggle()
                if didIt { Haptics.completion() }
            } label: {
                CompletionCheck(isComplete: didIt, diameter: 96)
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel(didIt ? "Done" : "Mark as done")
            .accessibilityAddTraits(didIt ? [.isSelected, .isButton] : .isButton)

            Text(didIt ? "Done." : "Tap when you've done it.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Add a note — optional")
                TextField("Anything worth remembering", text: $text, axis: .vertical)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                            .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Media capture is out of scope this phase. The card still rendered on Today, so this
    /// says plainly why it can't be finished rather than failing silently.
    private var captureComingSoon: some View {
        VStack(spacing: 10) {
            Image(systemName: request.assignment?.promptKind.symbol ?? "camera")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("Capture is coming next")
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
            Text("Photo, video, and voice arrive in the next phase. You can still write about this one.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            writeIt.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func quotedPrompt(_ assignment: AssignmentResponse) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.terracotta.opacity(0.35))
                .frame(width: 3)
                .clipShape(Capsule())
            Text(assignment.body)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
    }

    // MARK: Saving

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        switch request.mode {
        case .didIt: didIt
        default: !trimmed.isEmpty
        }
    }

    /// Local first, network second. The row exists in SwiftData before any request goes out, so
    /// a failure is never lost work and never a lost-work error message.
    private func save() async {
        saving = true
        defer { saving = false }

        let entry = Entry(
            childId: request.childId,
            assignmentId: request.assignment?.id,
            occurredAt: occurredAt,
            body: trimmed.isEmpty ? nil : trimmed
        )
        context.insert(entry)
        try? context.save()

        do {
            let response = try await api.createEntry(entry)
            entry.applyServerResponse(response)
            try? context.save()
            dismiss()
        } catch let error as APIError {
            // The one real user-facing failure: the entry saves, it just no longer completes
            // that assignment. Said plainly and without alarm.
            if error.code == .assignmentExpired {
                entry.assignmentId = nil
                entry.sync = .pending
                try? context.save()
                notice = error.userMessage
                return
            }
            entry.sync = .failed
            try? context.save()
            // Not an error dialog. It is saved here and will retry on next foreground.
            notice = error.userMessage
            dismiss()
        } catch {
            entry.sync = .failed
            try? context.save()
            dismiss()
        }
    }
}

/// The backdating affordance, in the composer header where it's obvious.
struct DatePill: View {
    @Binding var date: Date
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.tap) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(label)
                        .typeRole(.metadata)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel("Entry date, \(label). Tap to change.")

            if isExpanded {
                DatePicker(
                    "Entry date",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(.terracotta)
                .labelsHidden()
            }
        }
    }

    private var label: String {
        Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.day().month(.wide).year())
    }
}
