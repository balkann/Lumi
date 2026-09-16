import Foundation

/// DeepSeek'i Claude Code üzerinden koşturan env dosyasının İÇERİĞİ (karar 54).
///
/// Saf metin üretimi + ayrıştırma; dosya I/O'su `DeepSeekEnvironmentServicing`
/// implementasyonundadır. Değerler DeepSeek'in Claude Code entegrasyon
/// dokümanından birebir alınmıştır (`docsURL`) — Lumi kendi model/efor
/// politikası uydurmaz.
///
/// Abonelik override edilmez: env yalnız bu dosyayı `source` eden terminalde
/// geçerlidir, düz `claude` hâlâ Anthropic hesabıyla açılır.
public enum DeepSeekEnvironment {
    /// `~/.claude/deepseek.env` — kullanıcıların elle kurduğu konvansiyon.
    public static let directoryName = ".claude"
    public static let fileName = "deepseek.env"

    public static let docsURL = "https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code"
    public static let baseURL = "https://api.deepseek.com/anthropic"
    /// Anahtarı taşıyan değişken; ayrıştırma da bunu arar.
    public static let tokenVariable = "ANTHROPIC_AUTH_TOKEN"

    private static let model = "deepseek-flash[1m]"
    private static let fastModel = "deepseek-flash"
    private static let effortLevel = "max"
    private static let autoCompactWindow = "786432"

    /// Yazılacak dosyanın tam içeriği. Değerler ÇİFT TIRNAKLI: `[1m]` soneki
    /// zsh'te glob olarak yorumlanmasın ve anahtar boşluk taşısa bile tek
    /// token kalsın.
    public static func fileContents(apiKey: String) -> String {
        """
        # Lumi tarafından yönetilir (Settings ▸ Agent ▸ DeepSeek).
        # Kaynak: \(docsURL)
        # Kullanım: source ~/\(directoryName)/\(fileName) && claude
        export ANTHROPIC_BASE_URL="\(baseURL)"
        export \(tokenVariable)="\(apiKey)"
        export ANTHROPIC_MODEL="\(model)"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="\(model)"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="\(model)"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="\(fastModel)"
        export CLAUDE_CODE_SUBAGENT_MODEL="\(fastModel)"
        export CLAUDE_CODE_EFFORT_LEVEL="\(effortLevel)"
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW="\(autoCompactWindow)"

        """
    }

    /// Dosyadaki anahtar — `export X="..."`, `export X=...` ve `X=...` biçimleri
    /// okunur (kullanıcı elle kurmuş olabilir). Boş değer = anahtar yok.
    public static func apiKey(inFileContents contents: String) -> String? {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard line.hasPrefix("\(tokenVariable)=") else { continue }
            let value = String(line.dropFirst("\(tokenVariable)=".count))
            let unquoted = unquote(value.trimmingCharacters(in: .whitespaces))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    /// Sınır doğrulaması: anahtar kabuk metnine gömüleceği için tırnak, `$`,
    /// backtick, ters bölü ve boşluk taşıyan değerler REDDEDİLİR (komut
    /// enjeksiyonu ve bozuk dosya).
    public static func isValidAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let forbidden = CharacterSet(charactersIn: "\"'`$\\\n\r\t ")
        return trimmed.rangeOfCharacter(from: forbidden) == nil
    }

    /// Terminale yazılan spawn komutu: env dosyası `source` edilir, sonra
    /// `claude` açılır. `AgentProvider.detect` son `&&` parçasına baktığı için
    /// kart kimliği yine Claude görünür.
    public static func launchCommand(envFilePath: String) -> String {
        "source \"\(envFilePath)\" && claude"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
