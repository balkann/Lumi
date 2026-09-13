import Foundation

/// `~/.lumi/remote.json` şeması (Lumi Remote tasarımı §7). config.json'dan
/// bilinçli olarak ayrı dosya — karar 9 gereği mevcut format değişmez.
public struct RemoteConfig: Sendable, Equatable {
    public var enabled: Bool
    public var relayUrl: String
    public var token: String

    public static let defaults = RemoteConfig(
        enabled: false,
        relayUrl: "wss://lumi-relay-production.up.railway.app",
        token: ""
    )

    public init(enabled: Bool, relayUrl: String, token: String) {
        self.enabled = enabled
        self.relayUrl = relayUrl
        self.token = token
    }
}

public enum RemoteConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
}

public enum RemoteEvent: Sendable, Equatable {
    case stateChanged(RemoteConnectionState)
}
