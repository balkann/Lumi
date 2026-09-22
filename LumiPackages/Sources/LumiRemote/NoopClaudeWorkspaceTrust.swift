import LumiKit

/// `ClaudeWorkspaceTrusting` no-op'u: `RemoteService` default'u — üretimde
/// `RemoteFeatureAssembly` gerçek `ClaudeWorkspaceTrust`'i enjekte eder; bu
/// default yalnız test kurulumları güven yazımı istemediğinde kullanılır.
public struct NoopClaudeWorkspaceTrust: ClaudeWorkspaceTrusting {
    public init() {}
    public func markTrusted(repoPath: String) {}
}
