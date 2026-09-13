import Foundation
import LumiKit

/// 32 bayt rastgele → base64url (43 karakter, padding'siz).
func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// `remote.json` persistence'ı. ConfigService kalıbı: JSONSerialization +
/// ham-dict merge — bilinmeyen anahtarlar yazımda korunur (karar 9).
public actor RemoteConfigService {
    private let paths: LumiPaths

    public init(paths: LumiPaths) {
        self.paths = paths
    }

    public func load() -> RemoteConfig {
        guard let dict = readRaw() else { return .defaults }
        return RemoteConfig(
            enabled: dict["enabled"] as? Bool ?? RemoteConfig.defaults.enabled,
            relayUrl: dict["relayUrl"] as? String ?? RemoteConfig.defaults.relayUrl,
            token: dict["token"] as? String ?? RemoteConfig.defaults.token
        )
    }

    public func save(_ config: RemoteConfig) {
        var merged = readRaw() ?? [:]
        merged["enabled"] = config.enabled
        merged["relayUrl"] = config.relayUrl
        merged["token"] = config.token
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: paths.remoteFile, options: .atomic)
    }

    /// Token boşsa üretip kaydeder; her durumda güncel config'i döner.
    public func ensureToken() -> RemoteConfig {
        var config = load()
        if config.token.isEmpty {
            config.token = generateToken()
            save(config)
        }
        return config
    }

    private func readRaw() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.remoteFile),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
