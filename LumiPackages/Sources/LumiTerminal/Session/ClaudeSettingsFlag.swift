import Foundation

/// Lumi'nin başlattığı `claude` oturumlarına `--settings <lumi-dosyası>` enjekte eder.
/// Böylece Lumi'nin SessionStart hook'u (transcript pointer'ını yazan) o oturumda,
/// kullanıcının global/proje ayarına dokunmadan, çalışır. Yalnız `claude` başlatan
/// ve henüz `--settings` içermeyen komutlara dokunur.
enum ClaudeSettingsFlag {
    static func inject(into command: String, settingsPath: String) -> String {
        guard command == "claude"
            || command.hasPrefix("claude ")
            || command.hasPrefix("claude\t"),
              !command.contains("--settings")
        else { return command }
        return "claude --settings '\(settingsPath)'" + command.dropFirst("claude".count)
    }
}
