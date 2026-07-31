import Foundation

/// Claude Code oturumlarını transcript dosyalarına DETERMİNİSTİK bağlamak için
/// başlatma komutuna `--session-id <uuid>` enjekte eder. Böylece Claude'un yazdığı
/// transcript dosyası tam `<uuid>.jsonl` adını alır ve `TranscriptWatcher` dosyayı
/// mtime heuristiği yerine kesin adıyla eşler (aynı repoda çoklu oturumda yanlış/eski
/// transcript eşleşmesini önler). `<uuid>` = terminalin `TerminalID`'si.
///
/// Yalnız `claude` başlatan komutlara dokunur; `codex`/`bash`/başka komutlar ve zaten
/// `--session-id` içeren komutlar değişmeden geçer.
enum ClaudeSessionID {
    static func inject(into command: String, sessionId: String) -> String {
        guard command == "claude"
            || command.hasPrefix("claude ")
            || command.hasPrefix("claude\t"),
              !command.contains("--session-id")
        else { return command }
        return "claude --session-id \(sessionId)" + command.dropFirst("claude".count)
    }
}
