import Foundation
import LumiKit
import LumiState

/// DeepSeek kurulumu (karar 54): env dosyasının durumunu okuyup `DeepSeekStore`'a
/// koyar. Settings ▸ Agent sekmesi ve "New DeepSeek" dropdown öğesi bu store'dan
/// beslenir.
///
/// Kabuk katkısı YOK: Settings sekmesi `SettingsTab` kaydından, dropdown öğesi
/// terminal toolbar öğesinden gelir.
@MainActor
final class DeepSeekAssembly: FeatureAssembly {
    let bootstrapPhase = BootstrapPhase.ui

    private(set) var deepSeek: DeepSeekStore!

    func build(services: any ServiceRegistry, shared: SharedStores) {
        deepSeek = DeepSeekStore(service: services.deepSeek, toasts: shared.toasts)
    }

    func start() async {
        await deepSeek.load()
    }

    func shutdown() async {}
}
