import LumiKit
import LumiState
import SwiftUI

struct CodexAccountSwitcher: View {
    let store: CodexAccountStore
    var openSettings: (() -> Void)?
    @State private var isExpanded = false

    private static var maxListHeight: CGFloat { Theme.scaled(220) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Account").font(Theme.Typography.labelMono).foregroundStyle(Theme.textMuted)
                    Text(store.activeLabel)
                        .font(Theme.Typography.mono(.label, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if store.isBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Theme.Typography.ui(.caption, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Codex account: \(store.activeLabel)")
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        row(.systemDefault, title: "System default", subtitle: store.systemDefaultEmail)
                        ForEach(store.accounts) { account in
                            row(.account(account.id), title: account.email, subtitle: account.workspaceName)
                        }
                    }
                }.frame(maxHeight: Self.maxListHeight)
                Text("New Codex terminals use the selected account; running terminals keep theirs.")
                    .font(Theme.Typography.captionMono)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let openSettings {
                Button("Manage Accounts…", action: openSettings)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.labelMono)
                    .foregroundStyle(Theme.accentPrimary)
            }
        }
        .task { await store.load() }
    }

    private func row(
        _ selection: CodexAccountSelection, title: String, subtitle: String?
    ) -> some View {
        ClaudeAccountRow(
            title: title, subtitle: subtitle, isActive: store.isActive(selection),
            isWorking: store.activity == .switching(to: selection), isDisabled: store.isBusy
        ) {
            Task { await store.select(selection); isExpanded = false }
        }
    }
}
