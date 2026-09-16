import Foundation
import LumiKit
import LumiState

/// Claude hesapları (karar 56): listeyi store'a yükler ve açılışta seçili
/// hesabı aktif yüzeye yeniden materialize eder (başka bir araç üzerine
/// yazmış olabilir).
///
/// Kabuk katkısı YOK: Settings sekmesi `SettingsTab` kaydından, hesap
/// değiştirici de Claude kullanım popover'ının içinden gelir.
@MainActor
final class ClaudeAccountsAssembly: FeatureAssembly {
    let bootstrapPhase = BootstrapPhase.ui

    private(set) var claudeAccounts: ClaudeAccountStore!
    private var service: (any ClaudeAccountServicing)!

    /// Hesap değişince Claude kullanım göstergesi başka bir hesabı gösterir —
    /// store'a enjekte edilen bu kapama onu tazeler.
    private let refreshClaudeUsage: @MainActor () -> Void

    init(refreshClaudeUsage: @escaping @MainActor () -> Void) {
        self.refreshClaudeUsage = refreshClaudeUsage
    }

    func build(services: any ServiceRegistry, shared: SharedStores) {
        service = services.claudeAccounts
        claudeAccounts = ClaudeAccountStore(
            service: services.claudeAccounts,
            toasts: shared.toasts,
            onAccountSwitched: refreshClaudeUsage
        )
    }

    func start() async {
        await service.syncActiveSelection()
        await claudeAccounts.load()
    }

    func shutdown() async {}
}
