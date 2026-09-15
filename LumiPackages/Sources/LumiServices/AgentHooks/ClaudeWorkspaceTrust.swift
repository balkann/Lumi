import Foundation
import LumiKit

/// `~/.claude.json` (veya `CLAUDE_CONFIG_DIR/.claude.json`) içindeki proje
/// kaydının `hasTrustDialogAccepted` anahtarını `true` yapar; diğer tüm
/// anahtarlar/projeler korunur. Bkz. [[ClaudeWorkspaceTrusting]].
public struct ClaudeWorkspaceTrust: ClaudeWorkspaceTrusting {
    private let configFile: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        // Claude config dosyası: CLAUDE_CONFIG_DIR set ise <dir>/.claude.json,
        // değilse ~/.claude.json (Claude CLI ile aynı çözümleme).
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configFile = URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        } else {
            configFile = home.appendingPathComponent(".claude.json")
        }
    }

    public func markTrusted(repoPath: String) {
        guard !repoPath.isEmpty else { return }
        // Oku → projects[repoPath].hasTrustDialogAccepted=true → atomik yaz.
        // Dosya yoksa boştan başla (claude eksik anahtarları açılışta ekler).
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[repoPath] as? [String: Any] ?? [:]
        // Zaten güvenliyse dokunma — gereksiz yazımla eşzamanlı claude yazımını
        // ezme riskini alma.
        if entry["hasTrustDialogAccepted"] as? Bool == true { return }
        entry["hasTrustDialogAccepted"] = true
        projects[repoPath] = entry
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: configFile, options: .atomic)
    }
}
