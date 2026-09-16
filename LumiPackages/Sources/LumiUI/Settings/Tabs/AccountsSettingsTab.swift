import LumiKit
import LumiState
import SwiftUI

/// Settings ▸ Accounts (karar 56): Claude hesaplarını ekle, yeniden doğrula,
/// sil ve aralarında geçiş yap.
///
/// Hesap eklemek ZORUNLU değildir — Lumi hiç hesap eklenmemişken kullanıcının
/// kendi `~/.claude` oturumuyla ("System default") çalışır.
struct AccountsSettingsTab: SettingsTabContent {
    static let tab: SettingsTab = .accounts

    @Shell private var shell

    init() {}

    private var store: ClaudeAccountStore { shell.claudeAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LumiSectionTitle(
                title: "Accounts",
                description: "Switch between Claude logins without signing in again."
            )
            SectionHeader(title: "Claude", icon: "person.crop.circle")
                .padding(.bottom, Theme.Spacing.md)
            InfoCard(
                "Optional. Each account's credentials stay in your macOS Keychain; switching "
                    + "writes the selected account into the files the Claude Code CLI reads. "
                    + ClaudeAccountText.restartNotice
            )
            .padding(.bottom, Theme.Spacing.xxl)
            addRow
                .padding(.bottom, Theme.Spacing.lg)
            accountList
            Spacer(minLength: 0)
        }
        .task { await store.load() }
    }

    // MARK: - Ekleme

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            LumiBrowseButton(icon: "plus", label: "Add Account") {
                Task { await store.addAccount() }
            }
            .disabled(store.isBusy)
            .opacity(store.isBusy ? 0.5 : 1)
            if store.activity == .adding {
                ProgressView().controlSize(.small)
                Text("Finish the sign-in in your browser…")
                    .font(Theme.Typography.labelMono)
                    .foregroundStyle(Theme.textMuted)
                LumiBrowseButton(icon: "xmark", label: "Cancel") {
                    Task { await store.cancelPendingLogin() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Liste

    private var accountList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ClaudeAccountRow(
                title: ClaudeAccountText.systemDefaultTitle,
                subtitle: ClaudeAccountText.systemDefaultSubtitle,
                isActive: store.isActive(.systemDefault),
                isWorking: store.activity == .switching(to: .systemDefault),
                isDisabled: store.isBusy
            ) {
                Task { await store.select(.systemDefault) }
            }
            ForEach(store.accounts) { account in
                row(for: account)
            }
        }
    }

    private func row(for account: ClaudeAccount) -> some View {
        ClaudeAccountRow(
            title: account.email,
            subtitle: ClaudeAccountText.subtitle(for: account),
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
                        Task { await store.removeAccount(account) }
                    }
                }
                .disabled(store.isBusy)
                .opacity(store.isBusy ? 0.5 : 1)
            }
        )
    }

    private func isWorking(_ account: ClaudeAccount) -> Bool {
        switch store.activity {
        case .switching(to: .account(account.id)),
             .reauthenticating(accountID: account.id),
             .removing(accountID: account.id):
            return true
        default:
            return false
        }
    }
}

#if DEBUG
#Preview("Accounts") {
    SettingsTabPreview(.accounts)
}
#endif
