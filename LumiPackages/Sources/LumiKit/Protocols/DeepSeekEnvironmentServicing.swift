import Foundation

/// DeepSeek env dosyasının diskteki durumu (karar 54).
public struct DeepSeekSetup: Sendable, Equatable {
    /// `~/.claude/deepseek.env` mutlak yolu — dosya yoksa da doludur.
    public let envFilePath: String
    /// Dosyadaki anahtar; `nil` = kurulu değil.
    public let apiKey: String?

    public init(envFilePath: String, apiKey: String?) {
        self.envFilePath = envFilePath
        self.apiKey = apiKey
    }

    public var isInstalled: Bool { apiKey != nil }

    /// Kurulu değilse `nil` — çağıran DeepSeek terminali açmayı reddeder.
    public var launchCommand: String? {
        guard isInstalled else { return nil }
        return DeepSeekEnvironment.launchCommand(envFilePath: envFilePath)
    }
}

/// DeepSeek kurulumunu okuyan/yazan servis yüzü (karar 54).
///
/// Anahtar Lumi config'ine (`~/.lumi/config.json`) ASLA yazılmaz — karar 9
/// format uyumluluğu ve sır hijyeni: tek kaynak env dosyasıdır (0600).
public protocol DeepSeekEnvironmentServicing: Sendable {
    /// Diski okur; dosya yoksa `apiKey == nil` döner (hata değil).
    func read() async -> DeepSeekSetup
    /// Env dosyasını verilen anahtarla (yeniden) yazar.
    func install(apiKey: String) async throws -> DeepSeekSetup
    /// Env dosyasını siler; yoksa sessizce başarılıdır.
    func remove() async throws -> DeepSeekSetup
}
