import Foundation

/// Ortam değişkeni geçirebilen süreç sınırı (karar 56).
///
/// `ProcessRunning`'den ayrı bir protokoldür (ISP): tüm çağrı yerlerine env
/// parametresi eklemek yerine, gerçekten ihtiyacı olan tek akış — `claude auth
/// login`'i yalıtılmış bir `CLAUDE_CONFIG_DIR` altında koşturmak — kendi dar
/// sınırını alır.
///
/// Sessiz-fail sözleşmesi `ProcessRunning` ile aynıdır: timeout, başlatma
/// hatası ya da iptal `nil` döndürür.
public protocol EnvironmentProcessRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ProcessOutput?
}
