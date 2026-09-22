import Foundation
import LumiKit

/// Eski `RemoteService` init çağrılarını bozmamak için no-op `WorkspaceServicing`.
public actor NoopWorkspaceServicing: WorkspaceServicing {
    public init() {}
    public func inspect(project: Repo) async throws -> WorkspaceSource {
        WorkspaceSource(projectPath: project.path, scm: .none, destinationDirectory: NSTemporaryDirectory())
    }
    public func branches(project: Repo, limit: Int) async throws -> [WorkspaceBranch] { [] }
    public func create(_ request: WorkspaceCreateRequest) async throws -> WorkspaceCreateResult {
        throw WorkspaceFailure("noop workspace servisi create desteklemez")
    }
    public func copyLibrary(sourcePath: String, workspacePath: String) async throws {}
    public func remove(_ workspace: ProjectWorkspace, force: Bool) async throws {}
}
