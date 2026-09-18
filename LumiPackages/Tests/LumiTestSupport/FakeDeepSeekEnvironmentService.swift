import Foundation
import LumiKit

/// Bellekte yaşayan DeepSeek env kurulumu — gerçek `~/.claude`'a dokunmaz.
public actor FakeDeepSeekEnvironmentService: DeepSeekEnvironmentServicing {
    public private(set) var installedKeys: [String] = []
    public private(set) var removeCount = 0
    public var failure: Error?

    private let path: String
    private var apiKey: String?

    public init(path: String = "/tmp/lumi-tests/.claude/deepseek.env", apiKey: String? = nil) {
        self.path = path
        self.apiKey = apiKey
    }

    public func setFailure(_ value: Error?) { failure = value }

    public func read() async -> DeepSeekSetup {
        DeepSeekSetup(envFilePath: path, apiKey: apiKey)
    }

    public func install(apiKey key: String) async throws -> DeepSeekSetup {
        if let failure { throw failure }
        installedKeys.append(key)
        apiKey = key
        return DeepSeekSetup(envFilePath: path, apiKey: key)
    }

    public func remove() async throws -> DeepSeekSetup {
        if let failure { throw failure }
        removeCount += 1
        apiKey = nil
        return DeepSeekSetup(envFilePath: path, apiKey: nil)
    }
}
