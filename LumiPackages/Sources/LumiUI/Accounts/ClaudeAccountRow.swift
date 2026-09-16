import LumiKit
import LumiState
import SwiftUI

/// Bir hesap satırı (karar 56) — Settings ▸ Accounts ve usage popover'ının
/// hesap listesi AYNI bileşeni çizer, böylece aktiflik göstergesi ve meşgul
/// hâli iki yerde ayrışmaz.
struct ClaudeAccountRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let isActive: Bool
    /// Bu satırın kendi işlemi sürüyor (switch/re-auth/remove).
    var isWorking = false
    /// Başka bir işlem sürerken tüm satırlar kilitlenir.
    var isDisabled = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: action) {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(title)
                                .font(Theme.Typography.mono(.body, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isActive {
                                Badge(text: "ACTIVE", color: Theme.accentPrimary)
                            }
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.Typography.labelMono)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || isActive)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(isActive ? Theme.accentPrimary.opacity(0.08) : Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(isActive ? Theme.accentPrimary.opacity(0.35) : Theme.border,
                        lineWidth: Theme.Stroke.hairline)
        )
        .opacity(isDisabled && !isWorking ? 0.6 : 1)
    }
}

extension ClaudeAccountRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        isActive: Bool,
        isWorking: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title, subtitle: subtitle, isActive: isActive, isWorking: isWorking,
            isDisabled: isDisabled, action: action, trailing: { EmptyView() }
        )
    }
}

/// Hesap satırlarının ortak metinleri — iki ekranda da aynı sözler çıksın.
enum ClaudeAccountText {
    static let systemDefaultTitle = "System default"
    static let systemDefaultSubtitle = "Use the Claude login already on this Mac."
    /// Switch sonrası uyarısı (Orca paritesi): canlı oturumlar eski token'la
    /// açılmıştır.
    static let restartNotice = "Restart running Claude terminals before continuing old conversations."

    static func subtitle(for account: ClaudeAccount) -> String {
        let date = account.lastAuthenticatedAt.formatted(date: .abbreviated, time: .shortened)
        guard let organization = account.organizationName, !organization.isEmpty else {
            return "Signed in \(date)"
        }
        return "\(organization) · \(date)"
    }
}
