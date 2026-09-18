import LumiKit
import LumiState
import LumiUI
import SwiftUI

@MainActor
final class CodexAccountsAssembly: FeatureAssembly, ShellContributing {
    let bootstrapPhase = BootstrapPhase.ui
    private(set) var codexAccounts: CodexAccountStore!
    private var service: (any CodexAccountServicing)!
    private var terminal: (any TerminalSessionControlling)!
    private let refreshCodexUsage: @MainActor () -> Void

    init(refreshCodexUsage: @escaping @MainActor () -> Void) {
        self.refreshCodexUsage = refreshCodexUsage
    }

    func build(services: any ServiceRegistry, shared: SharedStores) {
        service = services.codexAccounts
        terminal = services.terminal
        codexAccounts = CodexAccountStore(
            service: services.codexAccounts,
            toasts: shared.toasts,
            onSelectionChanged: { [weak self] home in
                self?.terminal.setLaunchEnvironment(["CODEX_HOME": home], for: .codex)
                self?.refreshCodexUsage()
            }
        )
    }

    func registerShellItems(into registries: ShellRegistries) {
        registries.overlays.register(OverlayDescriptor(
            id: .removeCodexAccountDialog,
            isPresented: { $0.dialogs.removeCodexAccountDialog != nil },
            makeView: { AnyView(RemoveCodexAccountDialogOverlay()) }
        ))
    }

    func start() async {
        await service.syncActiveSelection()
        await codexAccounts.load()
    }
    func shutdown() async {}
}
