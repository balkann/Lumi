import Foundation
import LumiKit
import LumiState
import LumiTerminal

/// Repo/workspace yüklendikten SONRA anlamlı olan workspace boot durumu
/// (refactor 3.3, `.ui` fazı):
///
/// - **Onboarding kapısı:** ilk çalıştırmada sihirbaz açılır (design/03 §4).
/// - **Karar 23/79 oturum devamı:** önceki graceful quit'te persist edilen
///   Claude/Codex oturumları, açık tab'ı duran repo'larda yeniden spawn edilir. `shutdown()`
///   simetriktir ve canlı oturumları persist eder — `.ui` fazı ilk yıkılan faz
///   olduğu için persist, terminal feature'ının `killAll()`'undan ÖNCE koşar.
@MainActor
final class WorkspaceBootAssembly: FeatureAssembly {
    let bootstrapPhase = BootstrapPhase.ui

    private var services: (any ServiceRegistry)!
    private var shared: SharedStores!
    /// Onboarding akışının state'i (refactor 5.8) — `RootView` bunu okur.
    private(set) var onboarding: OnboardingStore!

    func build(services: any ServiceRegistry, shared: SharedStores) {
        self.services = services
        self.shared = shared
        onboarding = OnboardingStore(
            system: services.system,
            settings: shared.settings,
            toasts: shared.toasts,
            onComplete: { [weak shared] in shared?.dialogs.isOnboardingActive = false }
        )
    }

    func start() async {
        shared.dialogs.isOnboardingActive = await services.config.isFirstRun()
        await resumeAgentSessions()
    }

    func shutdown() async {
        // killAll'dan ÖNCE provider-owned kimlikler persist edilir. Codex'in
        // CODEX_HOME'u da thread rollout'unun bulunduğu hesapla birlikte sabitlenir.
        let resumeSessions = Self.resumeSessions(from: services.terminal.terminals)
        await services.config.updateUIState { $0.resumeSessions = resumeSessions }
    }

    static func resumeSessions(from terminals: [TerminalMeta]) -> [ResumeSession] {
        terminals.compactMap { meta in
            if meta.provider == .codex, let id = meta.codexSessionID,
               CodexSessionCommand.isSafe(id), let home = meta.codexHome {
                return ResumeSession(
                    repoPath: meta.repoPath,
                    sessionID: id,
                    provider: .codex,
                    codexHome: home
                )
            }
            guard meta.provider != .codex, let id = meta.claudeSessionID else { return nil }
            return ResumeSession(repoPath: meta.repoPath, sessionID: id)
        }
    }

    /// Kayıtlar TEK SEFERLİK tüketilir (önce boşaltılır — spawn başarısız olsa
    /// bile bayat liste sonraki açılışlara sarkmaz).
    private func resumeAgentSessions() async {
        let entries = await services.config.uiState().resumeSessions
        guard !entries.isEmpty else { return }
        await services.config.updateUIState { $0.resumeSessions = [] }
        for entry in entries where shared.navigation.openTabs.contains(entry.repoPath) {
            switch entry.provider {
            case .claude:
                shared.terminals.spawn(
                    in: entry.repoPath,
                    command: ClaudeSessionCommand.resumeCommand(sessionID: entry.sessionID)
                )
            case .codex:
                let pinnedHome = await services.codexAccounts.resolvedResumeHome(entry.codexHome)
                let home = if let pinnedHome {
                    pinnedHome
                } else {
                    await services.codexAccounts.selectedHome()
                }
                let command = CodexSessionCommand.resumeCommand(sessionID: entry.sessionID) ?? "codex"
                shared.terminals.spawn(
                    in: entry.repoPath,
                    command: command,
                    environment: ["CODEX_HOME": home]
                )
            }
        }
    }
}
