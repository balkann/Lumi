import Foundation
import LumiKit
import Observation

/// Bir link eyleminin NE YAPACAĞI (karar 57). Store yalnız niyeti üretir;
/// yürütme kabuk katmanındadır (`ShellContext`) — sekme açma, FileViewer ve
/// Finder zaten orada yaşıyor.
public enum TerminalLinkIntent: Sendable, Equatable {
    /// Sistemdeki varsayılan tarayıcı (Lumi içine tarayıcı konmaz).
    case openURL(URL)
    case switchWorkspace(path: String)
    case openFile(repoPath: String, filePath: String)
    /// Bilinen bir kökün dışındaki dosya: FileViewer repo-göreli çalıştığı için
    /// sistemin varsayılan uygulamasına devredilir.
    case openWithDefaultApp(path: String)
    case revealInFinder(path: String)
}

/// Popover'daki tek satır.
public struct TerminalLinkAction: Identifiable, Equatable, Sendable {
    public enum Slot: String, Sendable { case primary, alternate }

    public let slot: Slot
    public let title: String
    public let intent: TerminalLinkIntent

    public var id: String { slot.rawValue }

    /// Satırın sağındaki tuş kombinasyonu.
    public var shortcutKeys: [String] {
        slot == .primary ? ["⌘", "Click"] : ["⇧", "⌘", "Click"]
    }
}

/// Açık popover'ın durumu.
public struct TerminalLinkRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: TerminalLinkTarget
    /// Kabuk koordinat uzayında tık noktası.
    public let anchor: CGPoint
    public let primary: TerminalLinkAction
    public let alternate: TerminalLinkAction?

    public var destination: String { target.displayText }

    /// Kopyala butonu yalnız URL'lerde çıkar (Orca paritesi).
    public var isCopyable: Bool {
        if case .url = target { return true }
        return false
    }

    public init(
        id: UUID = UUID(),
        target: TerminalLinkTarget,
        anchor: CGPoint,
        primary: TerminalLinkAction,
        alternate: TerminalLinkAction?
    ) {
        self.id = id
        self.target = target
        self.anchor = anchor
        self.primary = primary
        self.alternate = alternate
    }
}

/// Terminal link tıklamalarının tek karar noktası (karar 57).
///
/// Hedefi çözer (URL / workspace / dizin / dosya), jeste göre ya popover'ı açar
/// ya da eylemi doğrudan işletir. Dosya sistemi sorgusu enjekte edilir; testler
/// diske hiç dokunmaz.
@Observable
@MainActor
public final class TerminalLinkActionStore {
    public private(set) var request: TerminalLinkRequest?

    @ObservationIgnored private let terminals: TerminalListStore
    @ObservationIgnored private let repos: RepoStore
    @ObservationIgnored private let workspaces: ProjectWorkspaceStore
    @ObservationIgnored private let homeDirectory: String
    @ObservationIgnored private let pathKind: (String) -> TerminalLinkPathKind
    /// Kabuk bağlar; bağlanmazsa eylem sessizce düşer (test/preview).
    @ObservationIgnored public var onIntent: ((TerminalLinkIntent) -> Void)?

    public init(
        terminals: TerminalListStore,
        repos: RepoStore,
        workspaces: ProjectWorkspaceStore,
        homeDirectory: String = NSHomeDirectory(),
        pathKind: @escaping (String) -> TerminalLinkPathKind = TerminalLinkActionStore.diskPathKind
    ) {
        self.terminals = terminals
        self.repos = repos
        self.workspaces = workspaces
        self.homeDirectory = homeDirectory
        self.pathKind = pathKind
    }

    public static func diskPathKind(_ path: String) -> TerminalLinkPathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    // MARK: - Giriş

    public func handle(_ activation: TerminalLinkActivation) {
        guard let resolved = makeRequest(activation) else {
            request = nil
            return
        }
        switch activation.gesture {
        case .actions:
            request = resolved
        case .primary:
            perform(resolved.primary)
        case .alternate:
            // Alternatifi olmayan hedefte (URL, dizin) ⇧⌘ birincil eylemi işletir.
            perform(resolved.alternate ?? resolved.primary)
        }
    }

    public func perform(_ action: TerminalLinkAction) {
        request = nil
        onIntent?(action.intent)
    }

    public func dismiss() {
        request = nil
    }

    // MARK: - Çözümleme

    /// Bilinen kökler: sidebar projeleri + oluşturulan workspace'ler.
    private var knownRoots: [String] {
        repos.repos.map(\.path) + workspaces.records.map(\.path)
    }

    func makeRequest(_ activation: TerminalLinkActivation) -> TerminalLinkRequest? {
        let basePath = terminals.meta(for: activation.terminalID)?.repoPath ?? ""
        let roots = knownRoots
        guard let target = TerminalLinkResolver.resolve(
            link: activation.link,
            basePath: basePath,
            homeDirectory: homeDirectory,
            knownRoots: roots,
            pathKind: pathKind
        ) else { return nil }

        let actions = Self.actions(for: target, knownRoots: roots)
        return TerminalLinkRequest(
            target: target,
            anchor: activation.anchor,
            primary: actions.primary,
            alternate: actions.alternate
        )
    }

    static func actions(
        for target: TerminalLinkTarget,
        knownRoots: [String]
    ) -> (primary: TerminalLinkAction, alternate: TerminalLinkAction?) {
        switch target {
        case .url(let url):
            return (.init(slot: .primary, title: "Open link", intent: .openURL(url)), nil)
        case .workspace(let path):
            return (
                .init(slot: .primary, title: "Switch workspace", intent: .switchWorkspace(path: path)),
                .init(slot: .alternate, title: "Open in Finder", intent: .revealInFinder(path: path))
            )
        case .directory(let path):
            return (
                .init(slot: .primary, title: "Open in Finder", intent: .revealInFinder(path: path)),
                nil
            )
        case .file(let path):
            let primary: TerminalLinkAction
            if let root = TerminalLinkResolver.enclosingRoot(of: path, in: knownRoots),
               let relative = TerminalLinkResolver.relativePath(of: path, in: root) {
                primary = .init(
                    slot: .primary,
                    title: "Open file",
                    intent: .openFile(repoPath: root, filePath: relative)
                )
            } else {
                primary = .init(
                    slot: .primary,
                    title: "Open with default app",
                    intent: .openWithDefaultApp(path: path)
                )
            }
            return (
                primary,
                .init(slot: .alternate, title: "Open in Finder", intent: .revealInFinder(path: path))
            )
        }
    }
}
