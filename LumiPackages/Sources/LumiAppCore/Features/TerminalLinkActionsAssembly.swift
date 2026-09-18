import Foundation
import LumiKit
import LumiState
import LumiUI
import SwiftUI

/// Terminal link eylemleri (karar 57): terminalden gelen link tıklamasını
/// store'a bağlar ve tık noktasındaki popover'ı kabuğa kaydeder.
///
/// Eylemlerin YÜRÜTÜLMESİ kabukta (`ShellContext.performTerminalLinkIntent`)
/// kalır; burada yalnız kanal kurulur — store sekmeyi, FileViewer'ı ve
/// Finder'ı görmez.
@MainActor
final class TerminalLinkActionsAssembly: FeatureAssembly, ShellContributing {
    let bootstrapPhase = BootstrapPhase.ui

    func build(services: any ServiceRegistry, shared: SharedStores) {}

    /// Repo/workspace store'ları repo assembly'sinde doğduğu için store bu
    /// ikinci adımda kurulur (composition root sırası).
    func makeStore(shared: SharedStores, repo: RepoFeatureAssembly) -> TerminalLinkActionStore {
        let store = TerminalLinkActionStore(
            terminals: shared.terminals,
            repos: repo.repoStore,
            workspaces: repo.workspaceStore
        )
        shared.terminals.onLinkActivated = { [weak store] activation in
            // Çözümleme dosya sistemine sorduğu için async'tir (karar 57
            // sertleştirmesi: MainActor'da senkron `stat` yok).
            Task { await store?.handle(activation) }
        }
        return store
    }

    func registerShellItems(into registries: ShellRegistries) {
        registries.overlays.register(OverlayDescriptor(
            id: .terminalLinkActions,
            alignment: .topLeading,
            isPresented: { $0.terminalLinks.request != nil },
            makeView: { AnyView(TerminalLinkActionOverlay()) }
        ))
    }

    func start() async {}

    func shutdown() async {}
}
