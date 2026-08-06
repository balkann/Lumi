import Foundation

/// Lumi'nin transcript-eşleşme altyapısını kurar: (1) claude `SessionStart` hook
/// scripti, (2) `--settings` ile claude'a verilecek ayar dosyası. Hook, PTY'den
/// miras alınan `LUMI_TERMINAL_ID` ile `~/.lumi/transcript-map/<TID>.json` pointer'ını
/// yazar; `TranscriptWatcher` bu pointer'dan aktif transcript dosyasını KESİN okur.
/// Kullanıcının global/proje Claude ayarlarına dokunulmaz (yalnız --settings).
/// İdempotent: her uygulama açılışında güvenle çağrılır (üzerine yazar).
public struct TranscriptSettingsInstaller {
    private let lumiRoot: URL

    public init(lumiRoot: URL) { self.lumiRoot = lumiRoot }

    /// Dosyaları yaz; `claude --settings <path>`'te kullanılacak ayar dosyasının yolunu döner.
    @discardableResult
    public func install() throws -> URL {
        let fm = FileManager.default
        let hooksDir = lumiRoot.appendingPathComponent("hooks")
        let mapDir = lumiRoot.appendingPathComponent("transcript-map")
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: mapDir, withIntermediateDirectories: true)

        let script = hooksDir.appendingPathComponent("session-start.sh")
        try Self.hookScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let settingsPath = lumiRoot.appendingPathComponent("claude-settings.json")
        let settings: [String: Any] = [
            "hooks": ["SessionStart": [
                ["hooks": [["type": "command", "command": "sh \(script.path)"]]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: settingsPath, options: .atomic)
        return settingsPath
    }

    /// jq'suz, /bin/sh; ham SessionStart JSON'unu <TID>.json'a ATOMİK yazar. Lumi-dışı
    /// (env boş) oturumda no-op. `$HOME/.lumi` sabit — hook kendi mapDir'ini bulur.
    static let hookScript = """
    #!/bin/sh
    [ -n "$LUMI_TERMINAL_ID" ] || exit 0
    dir="$HOME/.lumi/transcript-map"
    mkdir -p "$dir"
    tmp="$dir/$LUMI_TERMINAL_ID.json.tmp.$$"
    cat > "$tmp"
    mv -f "$tmp" "$dir/$LUMI_TERMINAL_ID.json"
    exit 0
    """
}
