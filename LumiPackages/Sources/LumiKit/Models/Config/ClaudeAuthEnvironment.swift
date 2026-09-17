import Foundation

/// Hesap değiştirmeyi ETKİSİZ kılan ortam değişkenleri (karar 56).
///
/// Claude Code bu değişkenlerden biri doluyken Keychain/dosya yüzeyine hiç
/// bakmaz — Lumi'nin materialize ettiği hesap devre dışı kalır. Lumi yalnız
/// KENDİ ortamını görebildiği için (kullanıcının `.zshrc`'sinde tanımlı bir
/// değişken görünmez) bu bir teşhis aracıdır, sessiz bir düzeltme değil:
/// değerler asla okunmaz, yalnız hangi anahtarın dolu olduğu bildirilir.
public enum ClaudeAuthEnvironment {
    public static let conflictingKeys = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "AWS_BEARER_TOKEN_BEDROCK",
    ]

    /// Dolu olan çakışan anahtarların ADLARI (değerleri taşınmaz).
    public static func conflicts(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        conflictingKeys.filter { key in
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(value ?? "").isEmpty
        }
    }
}
