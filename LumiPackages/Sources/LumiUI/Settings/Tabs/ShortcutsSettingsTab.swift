import LumiKit
import SwiftUI

/// Kısayol referansı (tek kaynak: `AppCommands`) + indeksli kısayolların
/// ⌘/⌃ ekseni (karar 62). Tablonun geri kalanı salt-okunurdur.
struct ShortcutsSettingsTab: SettingsTabContent {
    static let tab: SettingsTab = .shortcuts

    @Shell private var shell

    init() {}

    private var style: IndexShortcutStyle { shell.settings.current.indexShortcutStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LumiSectionTitle(
                title: "Keyboard Shortcuts",
                description: "Application shortcuts. Read-only except the index shortcuts below."
            )
            LumiField(
                title: "Index Shortcuts",
                hint: "Which modifier switches repository tabs and which focuses terminals (1–9)"
            ) {
                LumiSegmented(
                    options: IndexShortcutStyle.allCases.map {
                        .init(value: $0, label: $0.label)
                    },
                    selection: Binding(
                        get: { style },
                        set: { shell.settings.setIndexShortcutStyle($0) }
                    )
                )
            }
            VStack(spacing: Theme.Stroke.hairline) {
                ForEach(ShortcutReference.list(style: style)) { reference in
                    row(reference)
                }
            }
            // satır araları 1px çizgi (v1 .shortcuts-list)
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
    }

    private func row(_ reference: ShortcutReference) -> some View {
        HStack(spacing: Theme.Spacing.xl) {
            Text(reference.action)
                .font(Theme.Typography.mono(.base, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(Array(reference.combos.enumerated()), id: \.offset) { index, combo in
                    if index > 0 {
                        Text("–")
                            .font(Theme.Typography.labelMono)
                            .foregroundStyle(Theme.textMuted)
                    }
                    HStack(spacing: Theme.Spacing.xxs) {
                        ForEach(Array(combo.enumerated()), id: \.offset) { _, key in
                            Keycap(key: key)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        // 10pt: ölçek dışı ara değer (v1 paritesi korunuyor).
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.bgDeep)
    }
}

#if DEBUG
#Preview("Shortcuts") {
    SettingsTabPreview(.shortcuts)
}
#endif
