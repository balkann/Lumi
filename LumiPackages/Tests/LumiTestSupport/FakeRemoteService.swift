import Foundation
import LumiKit

/// `RemoteServicing` fake'i: davranışsız, yalnız derlenebilir bir bağlam kurar
/// (RemoteStore + ShellContext fixture'ları için). State/config ayarlanabilir.
@MainActor
public final class FakeRemoteService: RemoteServicing {
    public private(set) var state: RemoteConnectionState
    public private(set) var currentConfig: RemoteConfig
    private let broadcaster = EventBroadcaster<RemoteEvent>()

    public init(
        state: RemoteConnectionState = .disconnected,
        config: RemoteConfig = .defaults
    ) {
        self.state = state
        self.currentConfig = config
    }

    public func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async {
        var config = currentConfig
        mutate(&config)
        currentConfig = config
    }

    public func regenerateToken() async {}
    public func start() async {}
    public func stop() {}
    public func events() -> AsyncStream<RemoteEvent> { broadcaster.stream() }
}
