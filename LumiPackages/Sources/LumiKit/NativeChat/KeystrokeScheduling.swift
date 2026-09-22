import Foundation

/// Faz 3.1: paced keystroke yazımı için gruplar arası zamanlama. Test'te ani-çalışan
/// bir fake enjekte edilir; üretimde `Task.sleep`. (orca `NATIVE_CHAT_QUESTION_STEP_MS`.)
public protocol KeystrokeScheduling: Sendable {
    func sleep(_ duration: Duration) async throws
}

public struct LiveKeystrokeScheduler: KeystrokeScheduling {
    public init() {}
    public func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
