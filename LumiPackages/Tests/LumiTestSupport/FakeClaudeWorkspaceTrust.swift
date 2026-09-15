import Foundation
import LumiKit

/// `ClaudeWorkspaceTrusting` fake'i: `markTrusted` çağrılan repoPath'leri kaydeder.
public final class FakeClaudeWorkspaceTrust: ClaudeWorkspaceTrusting, @unchecked Sendable {
    private let lock = NSLock()
    private var _trusted: [String] = []
    public var trusted: [String] { lock.withLock { _trusted } }

    public init() {}

    public func markTrusted(repoPath: String) {
        lock.withLock { _trusted.append(repoPath) }
    }
}
