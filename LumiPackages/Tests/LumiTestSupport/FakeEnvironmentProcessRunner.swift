import Foundation
import LumiKit

/// `EnvironmentProcessRunning` test ikamesi (karar 56). Komut satırına göre
/// sonuç döndürür ve çağrının ORTAMINI kaydeder — `claude auth login`'in
/// yalıtılmış `CLAUDE_CONFIG_DIR` altında koştuğu ancak böyle kanıtlanır.
public actor FakeEnvironmentProcessRunner: EnvironmentProcessRunning {
    public struct Invocation: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        public let environment: [String: String]
        public let timeout: TimeInterval

        public var commandLine: String { ([executable] + arguments).joined(separator: " ") }
        public var configDir: String? { environment["CLAUDE_CONFIG_DIR"] }
    }

    public private(set) var invocations: [Invocation] = []
    /// Argümanların ilk iki kelimesine göre sonuç (örn. "auth login").
    private var results: [String: ProcessOutput?] = [:]
    private var sideEffects: [String: @Sendable (Invocation) async -> Void] = [:]

    public init() {}

    public func setResult(_ result: ProcessOutput?, for command: String) {
        results[command] = result
    }

    /// Komut koşarken çalışacak yan etki: gerçek `claude`'un keychain'e ya da
    /// config dizinine yazmasını taklit eder.
    public func setSideEffect(
        for command: String, _ effect: @escaping @Sendable (Invocation) async -> Void
    ) {
        sideEffects[command] = effect
    }

    public func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ProcessOutput? {
        let invocation = Invocation(
            executable: executable, arguments: arguments,
            environment: environment, timeout: timeout
        )
        invocations.append(invocation)
        let command = arguments.prefix(2).joined(separator: " ")
        await sideEffects[command]?(invocation)
        guard let result = results[command] else {
            return ProcessOutput(exitCode: 0, stdout: "", stderr: "")
        }
        return result
    }
}
