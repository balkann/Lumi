import Foundation
import LumiKit
import LumiRemote
import LumiState

/// Remote (terminal-ayna) özelliği: RemoteService + RemoteStore kurar, config
/// etkinse relay'e bağlanır. bootstrapPhase.config — terminal (system) kurulduktan
/// sonra, ama repo/ui'dan önce başlaması yeterli.
@MainActor
final class RemoteFeatureAssembly: FeatureAssembly {
    let bootstrapPhase = BootstrapPhase.config

    private(set) var remoteStore: RemoteStore!
    private var remoteService: RemoteService!
    private var services: (any ServiceRegistry)!

    func build(services: any ServiceRegistry, shared: SharedStores) {
        self.services = services
        remoteService = RemoteService(
            paths: services.paths,
            terminal: services.terminal,
            repos: services.repo
        )
        remoteStore = RemoteStore(service: remoteService)
    }

    func start() async {
        // store event köprüsü + servis bağlantısı (config.enabled=false ise no-op).
        remoteStore.start()
        await remoteService.start()
    }

    func shutdown() async {
        remoteService.stop()
    }
}
