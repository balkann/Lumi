import Foundation
import XCTest
import LumiKit
import LumiState
import LumiTestSupport
@testable import LumiAppCore

/// Karar 84: git komutları yalnız git deposunda koşar, ve remote adresi dosya
/// izleyicisi tik'inde yeniden sorulmaz.
///
/// Bağlamayı (`wireActiveRepo` + `startFileTreeBridge`) doğrular; kuralların
/// kendisi `GitStoreTests` ve `GitServiceTests` içindedir.
@MainActor
final class RepoFeatureAssemblyGitGateTests: XCTestCase {
    private let repoPath = "/tmp/lumi-git-gate-repo"
    private var registry: FakeServiceRegistry!
    private var git: FakeGitService!
    private var shared: SharedStores!

    override func setUp() async throws {
        registry = FakeServiceRegistry()
        git = FakeGitService()
        registry.git = git
        shared = SharedStores.make(
            config: registry.config,
            terminal: registry.terminal,
            toastAutoDismissAfter: 60
        )
        await registry.fakeRepo.setDefaultFileTree([
            FileTreeNode(name: "Sources", path: "Sources", type: .folder, isIgnored: false, children: []),
        ])
    }

    override func tearDown() async throws {
        registry.removeTemporaryDirectories()
        registry = nil
        git = nil
        shared = nil
    }

    func testNonGitProjectNeverRunsGitCommands() async {
        let assembly = await makeAssembly(isGitRepo: false)

        shared.navigation.openTab(repoPath)
        await waitForFileTreeLoads(atLeast: 1)
        registry.fakeRepo.emit(.fileTreeChanged(repoPath: repoPath))
        await waitForFileTreeLoads(atLeast: 2)

        let branches = await git.branchesCallCount
        let status = await git.statusCallCount
        let remote = await git.remoteURLCallCount
        XCTAssertNotNil(assembly.repoStore.fileTrees[repoPath], "dosya ağacı yine de yüklenmeli")
        XCTAssertEqual(branches, 0, "git olmayan projede dal listesi sorulmamalı")
        XCTAssertEqual(status, 0, "git olmayan projede durum sorulmamalı")
        XCTAssertEqual(remote, 0, "git olmayan projede remote sorulmamalı")
    }

    func testGitProjectRefreshesOnFileChangeButProbesRemoteOnce() async {
        await git.setRemoteURL("git@github.com:lumi/lumi.git")
        let assembly = await makeAssembly(isGitRepo: true)

        shared.navigation.openTab(repoPath)
        await waitUntil("aktivasyon git panelini yüklemedi") {
            assembly.gitStore.remoteURLs[self.repoPath] != nil
        }
        let afterActivation = await git.statusCallCount

        registry.fakeRepo.emit(.fileTreeChanged(repoPath: repoPath))
        await waitForCondition("dosya değişimi git durumunu tazelemedi") {
            await self.git.statusCallCount > afterActivation
        }

        let remote = await git.remoteURLCallCount
        XCTAssertEqual(remote, 1, "remote yapılandırmadır; her tik'te yeniden sorulmaz")
    }

    // MARK: - Yardımcılar

    private func makeAssembly(isGitRepo: Bool) async -> RepoFeatureAssembly {
        await registry.fakeRepo.setCapabilities(
            ProjectCapabilities(isGitRepo: isGitRepo), for: repoPath
        )
        let assembly = RepoFeatureAssembly()
        assembly.build(services: registry, shared: shared)
        await assembly.start()
        return assembly
    }

    /// Köprünün o turu tamamladığının işareti: ağaç yeniden tarandı.
    private func waitForFileTreeLoads(atLeast count: Int) async {
        await waitForCondition("dosya ağacı \(count) kez taranmadı") {
            await self.registry.fakeRepo.fileTreeCalls.count >= count
        }
    }

    /// `waitUntil`in async koşul alan hâli — fake'ler actor olduğu için
    /// sayaçlar senkron okunamaz.
    private func waitForCondition(
        _ description: String,
        timeout: Duration = .milliseconds(2000),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, description, file: file, line: line)
    }
}
