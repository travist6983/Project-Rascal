import SwiftUI

/// Every token in one scrollable screen, so a drift from `docs/design-system.md` is visible
/// rather than argued about. Not reachable from the app — it exists for the preview canvas.
struct DesignSystemCatalog: View {
    @State private var checked = false

    private let swatches: [(String, Color, Color)] = [
        ("terracotta", .terracotta, .surface),
        ("terracottaSoft", .terracottaSoft, .ink),
        ("terracottaDeep", .terracottaDeep, .surface),
        ("periwinkle", .periwinkle, .surface),
        ("periwinkleSoft", .periwinkleSoft, .ink),
        ("sage", .sage, .ink),
        ("ink", .ink, .surface),
        ("inkMuted", .inkMuted, .surface),
        ("canvas", .canvas, .ink),
        ("surface", .surface, .ink),
        ("border", .border, .ink),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Colour") {
                    VStack(spacing: 6) {
                        ForEach(swatches, id: \.0) { name, fill, fg in
                            HStack {
                                Text(name).typeRole(.metadata).foregroundStyle(fg)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(fill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                            )
                        }
                    }
                }

                section("Type") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Display 34").typeRole(.display).foregroundStyle(Color.ink)
                        Text("Title 22").typeRole(.title).foregroundStyle(Color.ink)
                        Text("Prompt body 20").typeRole(.promptBody).foregroundStyle(Color.ink)
                        Text("Card title 17").typeRole(.cardTitle).foregroundStyle(Color.ink)
                        Text("Body 16 — line height 1.45, the reading size for entry text and anything the parent writes.")
                            .typeRole(.body).foregroundStyle(Color.ink)
                        Text("Metadata 13").typeRole(.metadata).foregroundStyle(Color.inkMuted)
                        SectionLabel("Label 12 tracked")
                    }
                }

                section("Shape & elevation") {
                    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        Text("Surface card, radius 20, hairline border, shadow y2/blur8/0.04")
                            .typeRole(.body).foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                        Text("Mission tint — terracottaSoft")
                            .typeRole(.body).foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(fill: .terracottaSoft)
                        Text("Question tint — periwinkleSoft")
                            .typeRole(.body).foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(fill: .periwinkleSoft)
                        Text("Did-it — sage")
                            .typeRole(.body).foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(fill: .sage)
                    }
                }

                section("Chips & badges") {
                    HStack(spacing: 8) {
                        KindBadge(kind: "photo", tint: .terracotta)
                        KindBadge(kind: "question", tint: .periwinkle)
                        Chip(text: "2 days left")
                        Chip(text: "4 waiting", bordered: true)
                    }
                }

                section("Motion") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            CompletionCheck(isComplete: checked, diameter: 44)
                            Button(checked ? "Undo" : "Complete") {
                                checked.toggle()
                                if checked { Haptics.completion() }
                            }
                            .buttonStyle(TapScaleButtonStyle())
                            .typeRole(.body)
                            .foregroundStyle(Color.terracotta)
                        }
                        Button("Capsule primary") {}
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }

                section("Gradient — emotional beats only") {
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .fill(Gradients.wash)
                        .frame(height: 90)
                }
            }
            .padding(Layout.screenMargin)
        }
        .background(Color.canvas)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
    }
}

#Preview("Design system") {
    DesignSystemCatalog()
}

#Preview("Accessibility XXL") {
    DesignSystemCatalog()
        .environment(\.dynamicTypeSize, .accessibility2)
}
