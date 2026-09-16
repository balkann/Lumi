import LumiKit
import LumiState
import SwiftUI

/// Ek ajan arka uçları (karar 54). Şimdilik tek bölüm: DeepSeek'i Claude Code
/// CLI'ı üzerinden çalıştıran env kurulumu.
struct AgentSettingsTab: SettingsTabContent {
    static let tab: SettingsTab = .agent

    @Shell private var shell

    init() {}

    private var deepSeek: DeepSeekStore { shell.deepSeek }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LumiSectionTitle(
                title: "Agent",
                description: "Extra agent backends available to new terminals."
            )
            SectionHeader(title: "DeepSeek", icon: "sparkles")
                .padding(.bottom, Theme.Spacing.md)
            InfoCard(
                "Setup writes an env file that points the Claude Code CLI at DeepSeek's "
                    + "Anthropic-compatible API. Your Anthropic subscription is never overridden: "
                    + "only terminals started with \"New DeepSeek\" source that file, plain "
                    + "\"New Claude\" keeps using your Anthropic account."
            )
            .padding(.bottom, Theme.Spacing.xxl)
            LumiField(
                title: "API Key",
                hint: "Kept only in \(pathHint) with 0600 permissions — never in Lumi's config"
            ) {
                LumiTextInput(
                    text: Binding(
                        get: { deepSeek.apiKeyDraft },
                        set: { deepSeek.apiKeyDraft = $0 }
                    ),
                    placeholder: "sk-…",
                    isSecure: true,
                    onSubmit: install
                )
            }
            LumiField(title: "Setup", hint: setupHint, isLast: true) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(spacing: Theme.Spacing.md) {
                        LumiBrowseButton(
                            icon: "sparkles",
                            label: deepSeek.isInstalled ? "Update DeepSeek Setup" : "DeepSeek Setup",
                            action: install
                        )
                        .disabled(!deepSeek.canInstall)
                        .opacity(deepSeek.canInstall ? 1 : 0.5)
                        if deepSeek.isInstalled {
                            LumiBrowseButton(icon: "trash", label: "Remove", action: remove)
                                .disabled(deepSeek.isBusy)
                        }
                    }
                    statusRow
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: deepSeek.isInstalled ? "checkmark.circle" : "circle.dashed")
                .font(Theme.Typography.label)
                .foregroundStyle(deepSeek.isInstalled ? Theme.accentCyan : Theme.textMuted)
                .accessibilityHidden(true)
            Text(statusText)
                .font(Theme.Typography.labelMono)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var statusText: String {
        guard deepSeek.isInstalled else { return "Not configured" }
        return deepSeek.hasUnsavedKey
            ? "Configured — the key in the field is not saved yet"
            : "Configured · \(pathHint)"
    }

    private var setupHint: String {
        "Writes the env file; existing DeepSeek terminals are not affected"
    }

    /// Yol henüz okunmadıysa konvansiyonel gösterim.
    private var pathHint: String {
        deepSeek.envFilePath ?? "~/\(DeepSeekEnvironment.directoryName)/\(DeepSeekEnvironment.fileName)"
    }

    private func install() {
        Task { await deepSeek.install() }
    }

    private func remove() {
        Task { await deepSeek.remove() }
    }
}

#if DEBUG
#Preview("Agent") {
    SettingsTabPreview(.agent)
}
#endif
