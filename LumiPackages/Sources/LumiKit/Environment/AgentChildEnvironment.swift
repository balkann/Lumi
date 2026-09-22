import Foundation

/// Ajan child sürecine verilecek environment'tan claude-oturum kimliği miras
/// değişkenlerini temizler. Lumi bir claude oturumu içinden başlatılırsa (`open`
/// env taşır) child claude kendini alt-oturum sanıp (`CLAUDECODE=1` +
/// `CLAUDE_CODE_SESSION_ID`) transcript'i `--session-id` yoluna yazmıyordu
/// (2026-09-17 teşhisi). Stream-json chat lane pipe child'ı için gereken tek
/// hijyen budur (PTY/omz/TERM ayarları pipe I/O'da gereksiz). `CLAUDE_CONFIG_DIR`
/// bilinçli korunur — kullanıcının meşru global ayarı olabilir.
///
/// Not: PTY terminal tarafındaki `TerminalEnvironment` (LumiTerminal) aynı
/// stripping'i + terminal-özel ayarları uygular; bu yardımcı LumiKit'te olduğu
/// için hem LumiServices hem composition root'tan erişilebilir.
public enum AgentChildEnvironment {
    public static func cleaned(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["CLAUDECODE"] = nil
        env["CLAUDE_EFFORT"] = nil
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") { env[key] = nil }
        return env
    }
}
