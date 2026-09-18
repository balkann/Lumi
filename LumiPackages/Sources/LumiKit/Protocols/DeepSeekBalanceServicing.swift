import Foundation

/// DeepSeek bakiyesini okuyan servis yüzü (karar 75).
///
/// `UsageServicing`'ten ayrıdır ve ayrı kalmalıdır (ISP): kullanım göstergesi
/// pencere + yüzde sözleşmesidir, bakiye ise para. DeepSeek bir `AgentProvider`
/// de DEĞİLDİR — Claude Code'u kendi endpoint'ine yönlendirerek koşar (karar 54),
/// terminal kartında kimliği Claude'dur.
public protocol DeepSeekBalanceServicing: Sendable {
    /// Anahtar kurulu değilse `LumiError.deepSeekBalanceUnavailable` fırlatır.
    func fetch() async throws -> DeepSeekBalance
}
