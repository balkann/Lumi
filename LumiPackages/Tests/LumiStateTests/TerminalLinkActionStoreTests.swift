import Foundation
import LumiKit
import LumiTestSupport
import XCTest
@testable import LumiState

/// Karar 57: jest → (popover | doğrudan eylem) ve hedefe göre eylem seçimi.
@MainActor
final class TerminalLinkActionStoreTests: XCTestCase {
    private let project = Repo(name: "Game", path: "/projects/game", isGitRepo: true, source: .standalone)
    private let workspace = ProjectWorkspace(
        projectPath: "/projects/game", path: "/workspaces/review", name: "Review",
        branch: "review", scm: .git
    )
    private var terminals: TerminalListStore!
    private var repos: RepoStore!
    private var workspaces: ProjectWorkspaceStore!
    private var store: TerminalLinkActionStore!
    private var intents: [TerminalLinkIntent] = []
    private var terminalID = TerminalID()

    override func setUp() async throws {
        let service = FakeTerminalService()
        terminals = TerminalListStore(service: service, toasts: ToastStore(autoDismissAfter: 60))
        let repoService = FakeRepoService()
        await repoService.setRepos([project])
        repos = RepoStore(service: repoService)
        await repos.reload()
        workspaces = ProjectWorkspaceStore(
            service: FakeWorkspaceService(), config: FakeConfigService(),
            repos: repos, toasts: ToastStore()
        )
        workspaces.updateRecords([workspace])

        let meta = try service.spawn(repoPath: project.path, task: nil, command: nil)
        terminalID = meta.id
        terminals.apply(.spawned(meta))

        intents = []
        store = TerminalLinkActionStore(
            terminals: terminals, repos: repos, workspaces: workspaces,
            homeDirectory: "/Users/dev",
            pathKind: { path in path.hasSuffix("/logs") ? .directory : .file }
        )
        store.onIntent = { [weak self] in self?.intents.append($0) }
    }

    private func activate(_ link: String, _ gesture: TerminalLinkGesture) {
        store.handle(TerminalLinkActivation(
            terminalID: terminalID, link: link, gesture: gesture, anchor: CGPoint(x: 8, y: 9)
        ))
    }

    // MARK: - Jestler

    func testPlainClickOpensPopoverWithoutRunningAnything() {
        activate("src/App.swift", .actions)

        XCTAssertEqual(store.request?.destination, "/projects/game/src/App.swift")
        XCTAssertEqual(store.request?.anchor, CGPoint(x: 8, y: 9))
        XCTAssertEqual(store.request?.primary.title, "Open file")
        XCTAssertEqual(store.request?.alternate?.title, "Open in Finder")
        XCTAssertTrue(intents.isEmpty, "popover açılırken eylem çalışmamalı")
    }

    func testCommandClickRunsPrimaryWithoutPopover() {
        activate("src/App.swift", .primary)

        XCTAssertNil(store.request)
        XCTAssertEqual(
            intents, [.openFile(repoPath: "/projects/game", filePath: "src/App.swift")]
        )
    }

    func testShiftCommandClickRunsAlternate() {
        activate("src/App.swift", .alternate)

        XCTAssertEqual(intents, [.revealInFinder(path: "/projects/game/src/App.swift")])
    }

    /// Alternatifi olmayan hedefte ⇧⌘ birincil eylemi işletir.
    func testShiftCommandFallsBackToPrimaryWhenThereIsNoAlternate() {
        activate("https://lumi.dev", .alternate)

        XCTAssertEqual(intents, [.openURL(URL(string: "https://lumi.dev")!)])
    }

    func testUnresolvableLinkOpensNothing() {
        activate("mailto:a@b.com", .actions)

        XCTAssertNil(store.request)
        XCTAssertTrue(intents.isEmpty)
    }

    // MARK: - Hedefe göre eylemler

    func testWorkspaceRootOffersSwitchAndFinder() {
        activate("/workspaces/review", .actions)

        XCTAssertEqual(store.request?.primary.intent, .switchWorkspace(path: "/workspaces/review"))
        XCTAssertEqual(store.request?.alternate?.intent, .revealInFinder(path: "/workspaces/review"))
        XCTAssertEqual(store.request?.primary.shortcutKeys, ["⌘", "Click"])
        XCTAssertEqual(store.request?.alternate?.shortcutKeys, ["⇧", "⌘", "Click"])
    }

    func testProjectRootIsAlsoAWorkspaceTarget() {
        activate("/projects/game", .actions)

        XCTAssertEqual(store.request?.primary.intent, .switchWorkspace(path: "/projects/game"))
    }

    func testDirectoryOutsideKnownRootsOnlyRevealsInFinder() {
        activate("/tmp/logs", .actions)

        XCTAssertEqual(store.request?.primary.intent, .revealInFinder(path: "/tmp/logs"))
        XCTAssertNil(store.request?.alternate)
    }

    /// Bilinen kökün dışındaki dosya FileViewer'a değil sistem uygulamasına gider.
    func testFileOutsideKnownRootsUsesDefaultApp() {
        activate("/tmp/report.pdf", .actions)

        XCTAssertEqual(store.request?.primary.intent, .openWithDefaultApp(path: "/tmp/report.pdf"))
        XCTAssertEqual(store.request?.alternate?.intent, .revealInFinder(path: "/tmp/report.pdf"))
    }

    func testOnlyURLsShowTheCopyButton() {
        activate("https://lumi.dev", .actions)
        XCTAssertEqual(store.request?.isCopyable, true)

        activate("src/App.swift", .actions)
        XCTAssertEqual(store.request?.isCopyable, false)
    }

    // MARK: - Kapanış

    func testPerformClosesPopoverAndEmitsIntent() throws {
        activate("src/App.swift", .actions)
        let primary = try XCTUnwrap(store.request?.primary)

        store.perform(primary)

        XCTAssertNil(store.request)
        XCTAssertEqual(intents, [.openFile(repoPath: "/projects/game", filePath: "src/App.swift")])
    }

    func testDismissClosesPopover() {
        activate("src/App.swift", .actions)
        store.dismiss()

        XCTAssertNil(store.request)
        XCTAssertTrue(intents.isEmpty)
    }
}
