import Foundation
import LumiKit

/// Eski `RemoteCommandHandler` init çağrılarını bozmamak için no-op `RepoServicing`.
actor NoopRepoServicing: RepoServicing {
    func repos() async -> [Repo] { [] }
    func setRoots(projectsRoot: String, additionalPaths: [AdditionalPath]) async {}
    func searchContents(repoPath: String, paths: [String], query: ExplorerContentQuery) async throws -> ExplorerContentResult { ExplorerContentResult() }
    func editFile(repoPath: String, edit: ExplorerFileEdit) async throws {}
    func capabilities(repoPath: String) async -> ProjectCapabilities { ProjectCapabilities(isGitRepo: false) }
    func fileTree(repoPath: String) async -> [FileTreeNode] { [] }
    func watchFileTree(repoPath: String) async {}
    func unwatchFileTree(repoPath: String) async {}
    nonisolated func events() -> AsyncStream<RepoEvent> { AsyncStream { _ in } }
}
