import LumiState
import SwiftUI

public struct RemoveCodexAccountDialogOverlay: View {
    @Shell private var shell
    public init() {}
    private static var width: CGFloat { Theme.scaled(440) }

    public var body: some View {
        if let dialog = shell.dialogs.removeCodexAccountDialog {
            ModalOverlay(onDismiss: { shell.dialogs.dismiss(.removeCodexAccount(dialog)) }) {
                Panel(variant: .modal) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        Text("Remove Codex Account")
                            .font(Theme.Typography.titleMono).foregroundStyle(Theme.textPrimary)
                        Text(message(dialog))
                            .font(Theme.Typography.bodyMono).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(dialog.account.email)
                            .font(Theme.Typography.captionMono).foregroundStyle(Theme.textMuted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        HStack {
                            Spacer(minLength: 0)
                            Button("Cancel") { shell.dialogs.dismiss(.removeCodexAccount(dialog)) }
                                .buttonStyle(.bordered)
                            Button("Remove") {
                                shell.dialogs.dismiss(.removeCodexAccount(dialog))
                                Task { await shell.codexAccounts.removeAccount(dialog.account) }
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.error)
                        }
                    }
                    .padding(Theme.Spacing.xxl).frame(width: Self.width)
                    .disabled(shell.codexAccounts.isBusy)
                }
            }
        }
    }

    private func message(_ dialog: RemoveCodexAccountDialogState) -> String {
        let base = "Removes this isolated Codex login and its local account home. You'll need to sign in again to add it back."
        return dialog.isActive ? base + " New Codex terminals go back to your system login." : base
    }
}
