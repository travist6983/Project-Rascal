import SwiftUI

/// The type scale from `docs/design-system.md`.
///
/// The sizes here are the values at the default Dynamic Type setting, not fixed point sizes.
/// `Font.system(size:)` alone would refuse to scale, so every role carries a text style and is
/// applied through `@ScaledMetric`, which runs the size through `UIFontMetrics` for the user's
/// setting. SF Pro Rounded carries the headline warmth; SF Pro Text carries the reading copy.
enum TypeRole {
    /// 34pt bold, rounded. Occasionally one word in terracotta.
    case display
    /// 22pt semibold, rounded.
    case title
    /// 17pt semibold, rounded.
    case cardTitle
    /// 20pt regular — the prompt body on a `PromptCard`, per the component spec.
    case promptBody
    /// 16pt regular, line height 1.45.
    case body
    /// 13pt regular. Pair with `inkMuted`.
    case metadata
    /// 12pt semibold, tracked +0.6, uppercase. Section headers and badges.
    case label

    var size: CGFloat {
        switch self {
        case .display: 34
        case .title: 22
        case .promptBody: 20
        case .cardTitle: 17
        case .body: 16
        case .metadata: 13
        case .label: 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display: .bold
        case .title, .cardTitle, .label: .semibold
        case .promptBody, .body, .metadata: .regular
        }
    }

    /// Rounded for headlines, default (SF Pro Text) for reading copy and metadata.
    var design: Font.Design {
        switch self {
        case .display, .title, .cardTitle, .promptBody: .rounded
        case .body, .metadata, .label: .default
        }
    }

    /// What Dynamic Type scales this role against.
    var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title2
        case .promptBody: .title3
        case .cardTitle: .headline
        case .body: .body
        case .metadata: .footnote
        case .label: .caption
        }
    }

    /// Body sets line height 1.45; the rest sit at their natural leading.
    var lineSpacingMultiple: CGFloat? {
        switch self {
        case .body: 0.45
        case .promptBody: 0.30
        default: nil
        }
    }

    var tracking: CGFloat {
        self == .label ? 0.6 : 0
    }

    var isUppercased: Bool {
        self == .label
    }
}

private struct ScaledTypeRole: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let role: TypeRole

    init(_ role: TypeRole) {
        self.role = role
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: role.weight, design: role.design))
            .tracking(role.tracking)
            .lineSpacing((role.lineSpacingMultiple ?? 0) * size)
            .textCase(role.isUppercased ? .uppercase : nil)
    }
}

extension View {
    /// Applies a role from the type scale, scaled for Dynamic Type.
    func typeRole(_ role: TypeRole) -> some View {
        modifier(ScaledTypeRole(role))
    }
}

/// A section header — small caps in `inkMuted`, never big display type.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .typeRole(.label)
            .foregroundStyle(Color.inkMuted)
            .accessibilityAddTraits(.isHeader)
    }
}
