import LumiKit
import LumiState
import SwiftUI

struct CodexAccountsSettingsSection: View {
    @Shell private var shell
    private var store: CodexAccountStore { shell.codexAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Codex", icon: "person.crop.circle.badge.checkmark")
                .padding(.bottom, Theme.Spacing.md)
            InfoCard(
                "Optional. Each account uses an isolated CODEX_HOME. Switching affects new "
                    + "Codex terminals and usage checks; running terminals keep their account."
            )
            .padding(.bottom, Theme.Spacing.xxl)
            addRow.padding(.bottom, Theme.Spacing.lg)
            accountList
        }
        .task { await store.load() }
    }

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            LumiBrowseButton(icon: "plus", label: "Add Codex Account") {
                Task { await store.addAccount() }
            }
            .disabled(store.isBusy).opacity(store.isBusy ? 0.5 : 1)
            if store.isSigningIn {
                ProgressView().controlSize(.small)
                Text("Finish the sign-in in your browser…")
                    .font(Theme.Typography.labelMono).foregroundStyle(Theme.textMuted)
                LumiBrowseButton(icon: "xmark", label: "Cancel") {
                    Task { await store.cancelPendingLogin() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ClaudeAccountRow(
                title: "System default",
                subtitle: store.systemDefaultEmail ?? "Use the Codex login already on this Mac.",
                isActive: store.isActive(.systemDefault),
                isWorking: store.activity == .switching(to: .systemDefault),
                isDisabled: store.isBusy
            ) { Task { await store.select(.systemDefault) } }
            ForEach(store.accounts) { account in row(for: account) }
        }
    }

    private func row(for account: CodexAccount) -> some View {
        ClaudeAccountRow(
            title: account.email,
            subtitle: account.workspaceName,
            isActive: store.isActive(.account(account.id)),
            isWorking: isWorking(account),
            isDisabled: store.isBusy,
            action: { Task { await store.select(.account(account.id)) } },
            trailing: {
                HStack(spacing: Theme.Spacing.xs) {
                    IconButton(systemName: "arrow.clockwise", label: "Re-authenticate") {
                        Task { await store.reauthenticate(account) }
                    }
                    IconButton(systemName: "trash", label: "Remove", role: .destructive) {
                        shell.dialogs.present(.removeCodexAccount(RemoveCodexAccountDialogState(
                            account: account,
                            isActive: store.isActive(.account(account.id))
                        )))
                    }
                }
                .disabled(store.isBusy).opacity(store.isBusy ? 0.5 : 1)
            }
        )
    }

    private func isWorking(_ account: CodexAccount) -> Bool {
        switch store.activity {
        case .switching(to: .account(account.id)),
             .reauthenticating(accountID: account.id),
             .removing(accountID: account.id): true
        default: false
        }
    }
}
