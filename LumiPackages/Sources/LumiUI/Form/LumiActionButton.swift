import SwiftUI

/// Modal/dialog aksiyon butonu (karar 58).
///
/// Native `.bordered` / `.borderedProminent` sistem kapsülleriyle geliyordu ve
/// koyu panelin içinde eski duruyordu. Bu buton `LumiSegmented`/`LumiTextInput`
/// ile aynı dili konuşur: `.primary` dolu accent, `.secondary` elevated zemin +
/// hairline kenarlık, ikisi de `Theme.Radius.md`.
struct LumiActionButton: View {
    enum Kind { case primary, secondary }

    let title: String
    var kind: Kind = .secondary
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HoverReader { isHovering in
            Button(action: action) {
                Text(title)
                    .font(Theme.Typography.bodyMono)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.md)
                    .frame(minWidth: Self.minWidth)
                    .background(background(isHovering: isHovering && isEnabled))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(border, lineWidth: Theme.Stroke.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }

    private static var minWidth: CGFloat { Theme.scaled(88) }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.textPrimary
        case .secondary: Theme.textSecondary
        }
    }

    private var border: Color {
        switch kind {
        case .primary: Theme.accentVivid
        case .secondary: Theme.border
        }
    }

    private func background(isHovering: Bool) -> Color {
        switch kind {
        case .primary: isHovering ? Theme.accentPrimary : Theme.accentVivid
        case .secondary: isHovering ? Theme.bgDeep : Theme.bgElevated
        }
    }
}

#if DEBUG
#Preview("LumiActionButton") {
    HStack(spacing: Theme.Spacing.md) {
        LumiActionButton(title: "Cancel") {}
        LumiActionButton(title: "Create workspace", kind: .primary) {}
        LumiActionButton(title: "Disabled", kind: .primary) {}.disabled(true)
    }
    .padding(Theme.Spacing.xxl)
    .background(Theme.bgSurface)
}
#endif
