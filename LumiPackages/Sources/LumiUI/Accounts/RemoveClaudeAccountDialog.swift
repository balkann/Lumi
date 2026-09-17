import LumiKit
import LumiState
import SwiftUI

/// Claude hesabı silme onayı (karar 56 sertleştirmesi).
///
/// Silme geri alınamaz: hesabın Keychain kaydı ve yönetilen dosyaları gider,
/// hesabı geri eklemek için yeniden oturum açmak gerekir. Tek tıkla
/// tetiklenmemeli (proje geneli desen, karar 53'teki oturum silme gibi).
public struct RemoveClaudeAccountDialogOverlay: View {
    @Shell private var shell

    public init() {}

    private static var width: CGFloat { Theme.scaled(440) }

    public var body: some View {
        if let dialog = shell.dialogs.removeClaudeAccountDialog {
            ModalOverlay(onDismiss: { shell.dialogs.dismiss(.removeClaudeAccount(dialog)) }) {
                Panel(variant: .modal) {
                    content(dialog).padding(Theme.Spacing.xxl).frame(width: Self.width)
                }
            }
        }
    }

    private func content(_ dialog: RemoveClaudeAccountDialogState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Remove Account")
                .font(Theme.Typography.titleMono)
                .foregroundStyle(Theme.textPrimary)
            Text(message(dialog))
                .font(Theme.Typography.bodyMono)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(dialog.account.email)
                .font(Theme.Typography.captionMono)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { shell.dialogs.dismiss(.removeClaudeAccount(dialog)) }
                    .buttonStyle(.bordered)
                Button("Remove") {
                    shell.dialogs.dismiss(.removeClaudeAccount(dialog))
                    Task { await shell.claudeAccounts.removeAccount(dialog.account) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.error)
            }
        }
        .disabled(shell.claudeAccounts.isBusy)
    }

    private func message(_ dialog: RemoveClaudeAccountDialogState) -> String {
        let base = "Removes this account's credentials from Lumi's Keychain entry. "
            + "You'll need to sign in again to add it back."
        guard dialog.isActive else { return base }
        return base + " Claude goes back to your system login."
    }
}

#if DEBUG
#Preview("RemoveClaudeAccountDialog") {
    let shell = ShellContext.preview()
    shell.dialogs.present(.removeClaudeAccount(RemoveClaudeAccountDialogState(
        account: ClaudeAccount(
            id: UUID().uuidString, email: "dev@example.com",
            createdAt: .now, updatedAt: .now, lastAuthenticatedAt: .now
        ),
        isActive: true
    )))
    return RemoveClaudeAccountDialogOverlay().environment(shell).frame(width: 800, height: 500)
}
#endif
