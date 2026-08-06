# Transcript Eşleşmesi — SessionStart Hook Deterministik Model — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bir terminalin telefona yansıyan transcript'i, tahmin (registry+mtime) yerine, Lumi'nin `--settings` ile eklediği bir `SessionStart` hook'unun yazdığı `{LUMI_TERMINAL_ID → transcript_path}` pointer'ından deterministik okunsun; worktree/`/clear`/resume takip edilsin; eşleşemeyen oturum telefonda "yansıtılamıyor" gösterilsin.

**Architecture:** PTY, claude'u `LUMI_TERMINAL_ID=<TID>` env'i + `--session-id <TID>` + `--settings <lumi-dosyası>` ile başlatır. Hook her SessionStart'ta (startup/resume/clear/compact/fork) `~/.lumi/transcript-map/<TID>.json` pointer'ını atomik yazar. `TranscriptWatcher` pointer'dan kesin dosyayı okur (fallback: tüm proje dizinlerinde `<TID>.jsonl` global arama; yoksa not-mirrored). Dosya değişince `/clear`/resume reset'i telefona yansır.

**Tech Stack:** Swift 6 (strict concurrency), SPM lokal paketler (LumiKit/LumiTerminal/LumiServices/LumiRemote/LumiApp), XCTest; iOS tarafı LumiMobileKit (Swift, XcodeGen). Kabuk hook `/bin/sh` (jq yok).

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; servis→store `AsyncStream`, store→UI `@Observable`, Combine yok. (CLAUDE.md)
- `~/.lumi` mevcut JSON/YAML formatları değişmez (karar 9) — yalnız YENİ dosyalar eklenir (`hooks/session-start.sh`, `claude-settings.json`, `transcript-map/`).
- Kullanıcının global/proje Claude ayarlarına dokunulmaz; hook YALNIZ `--settings` ile eklenir.
- Tasarım kaydı bağlayıcı: `docs/superpowers/specs/2026-08-06-transcript-matching-hook-design.md`.
- Hook script `/bin/sh`, jq bağımlılığı yok; pointer atomik `mv` ile yazılır.
- `LUMI_TERMINAL_ID` = `--session-id` değeri = `TerminalID.raw.uuidString.lowercased()` — tek kimlik, üç yerde de aynı biçim.
- Test dizinleri `NSTemporaryDirectory()` altında izole; her testte tearDown'da silinir (mevcut test deseni).

---

## Faz 1 — Mac: env + hook kurulumu + `--settings` (LumiTerminal / LumiServices / LumiApp)

### Task 1: PTY'ye `LUMI_TERMINAL_ID` env'i

**Files:**
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift:54-58`
- Test: `LumiPackages/Tests/LumiTerminalTests/TerminalSessionEnvTests.swift` (Create)

**Interfaces:**
- Produces: PTY çocuk süreç ortamında `LUMI_TERMINAL_ID=<terminalID.lowercased>` bulunur (claude ve hook'ları miras alır).

- [ ] **Step 1: Failing test yaz** — env sözlüğünü kuran saf yardımcıyı test et.

`TerminalSession`'daki env kurulumu şu an init içinde gömülü. Test edilebilir olması için saf bir static fonksiyona çıkaracağız. Önce testi yaz:

```swift
import XCTest
@testable import LumiTerminal
import LumiKit

final class TerminalSessionEnvTests: XCTestCase {
    func testBuildsEnvironmentWithTerminalID() {
        let id = TerminalID()
        let env = TerminalSession.childEnvironment(base: ["PATH": "/usr/bin"], terminalID: id)
        XCTAssertEqual(env["LUMI_TERMINAL_ID"], id.raw.uuidString.lowercased())
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["PATH"], "/usr/bin", "taban env korunmalı")
    }

    func testDefaultsLangWhenAbsent() {
        let id = TerminalID()
        let env = TerminalSession.childEnvironment(base: [:], terminalID: id)
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter TerminalSessionEnvTests`
Expected: FAIL — `type 'TerminalSession' has no member 'childEnvironment'`

- [ ] **Step 3: Saf `childEnvironment` ekle + init'te kullan**

`TerminalSession.swift` içinde (sınıf gövdesine, `static let` sabitlerinin yanına) ekle:

```swift
/// PTY çocuk süreç ortamı (saf, test edilebilir). `LUMI_TERMINAL_ID` claude'un
/// SessionStart hook'una miras kalır; hook bunu pointer dosya adı olarak kullanır.
static func childEnvironment(base: [String: String], terminalID: TerminalID) -> [String: String] {
    var environment = base
    environment["TERM"] = "xterm-256color"
    if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
    environment["LUMI_TERMINAL_ID"] = terminalID.raw.uuidString.lowercased()
    return environment
}
```

`init` içindeki 54-58. satırları şu tek satırla değiştir:

```swift
let environment = Self.childEnvironment(base: ProcessInfo.processInfo.environment, terminalID: id)
```

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter TerminalSessionEnvTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift LumiPackages/Tests/LumiTerminalTests/TerminalSessionEnvTests.swift
git commit -m "feat(terminal): PTY env'ine LUMI_TERMINAL_ID ekle (hook pointer kimliği)"
```

---

### Task 2: `TranscriptSettingsInstaller` — hook script + claude-settings.json

**Files:**
- Create: `LumiPackages/Sources/LumiServices/Remote/TranscriptSettingsInstaller.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/TranscriptSettingsInstallerTests.swift` (Create)

**Interfaces:**
- Produces: `TranscriptSettingsInstaller(lumiRoot: URL)`; `func install() throws -> URL` — `hooks/session-start.sh` (0755) + `claude-settings.json`'ı idempotent yazar, `claude-settings.json` mutlak yolunu döner. `transcript-map/` dizinini oluşturur.

- [ ] **Step 1: Failing test yaz**

```swift
import XCTest
@testable import LumiServices

final class TranscriptSettingsInstallerTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-inst-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testInstallWritesHookAndSettingsAndReturnsSettingsPath() throws {
        let settingsPath = try TranscriptSettingsInstaller(lumiRoot: root).install()

        let script = root.appendingPathComponent("hooks/session-start.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        let perms = (try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "script sahibi/grup/diğer için çalıştırılabilir olmalı")
        let body = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(body.contains("LUMI_TERMINAL_ID"))
        XCTAssertTrue(body.contains("transcript-map"))

        XCTAssertEqual(settingsPath, root.appendingPathComponent("claude-settings.json"))
        let settings = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["SessionStart"], "settings SessionStart hook içermeli")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("transcript-map").path))
    }

    func testInstallIsIdempotent() throws {
        let p1 = try TranscriptSettingsInstaller(lumiRoot: root).install()
        let p2 = try TranscriptSettingsInstaller(lumiRoot: root).install()
        XCTAssertEqual(p1, p2)
    }
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter TranscriptSettingsInstallerTests`
Expected: FAIL — `cannot find 'TranscriptSettingsInstaller' in scope`

- [ ] **Step 3: Installer'ı yaz**

```swift
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
```

Not: `command` alanı hook scriptin MUTLAK yolunu (`sh /Users/.../.lumi/hooks/session-start.sh`) gömer; script içi `$HOME/.lumi` sabittir (lumiRoot her zaman `~/.lumi`). Testte lumiRoot temp olsa da script gövdesi `$HOME/.lumi`'ye yazar — bu davranış üretimde doğru; test yalnız script/settings içeriğini doğrular, hook'u çalıştırmaz.

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter TranscriptSettingsInstallerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiServices/Remote/TranscriptSettingsInstaller.swift LumiPackages/Tests/LumiServicesTests/TranscriptSettingsInstallerTests.swift
git commit -m "feat(services): TranscriptSettingsInstaller — SessionStart hook + --settings dosyası"
```

---

### Task 3: `--settings` enjeksiyonu + AppContainer bootstrap

**Files:**
- Create: `LumiPackages/Sources/LumiTerminal/Session/ClaudeSettingsFlag.swift`
- Test: `LumiPackages/Tests/LumiTerminalTests/ClaudeSettingsFlagTests.swift` (Create)
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift` (spawn — launch satırı ~128-134; init'e `claudeSettingsPath: String?` alanı)
- Modify: `LumiPackages/Sources/LumiApp/AppContainer.swift` (bootstrap: installer.install() → path'i manager'a geçir)

**Interfaces:**
- Consumes: Task 2 `TranscriptSettingsInstaller.install() -> URL`.
- Produces: `ClaudeSettingsFlag.inject(into: String, settingsPath: String) -> String` — `claude ...` komutuna `--settings <path>` ekler (zaten varsa/claude değilse dokunmaz). `TerminalSessionManager` claude başlatırken hem `--session-id` hem `--settings` enjekte eder.

- [ ] **Step 1: Failing test yaz**

```swift
import XCTest
@testable import LumiTerminal

final class ClaudeSettingsFlagTests: XCTestCase {
    func testInjectsSettingsIntoClaude() {
        let out = ClaudeSettingsFlag.inject(into: "claude --session-id abc", settingsPath: "/x/s.json")
        XCTAssertEqual(out, "claude --settings '/x/s.json' --session-id abc")
    }
    func testLeavesNonClaudeUntouched() {
        XCTAssertEqual(ClaudeSettingsFlag.inject(into: "git pull", settingsPath: "/x/s.json"), "git pull")
    }
    func testDoesNotDoubleInject() {
        let cmd = "claude --settings '/y.json'"
        XCTAssertEqual(ClaudeSettingsFlag.inject(into: cmd, settingsPath: "/x/s.json"), cmd)
    }
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter ClaudeSettingsFlagTests`
Expected: FAIL — `cannot find 'ClaudeSettingsFlag' in scope`

- [ ] **Step 3: `ClaudeSettingsFlag` yaz**

`ClaudeSessionID.swift` ile aynı desende:

```swift
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
```

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter ClaudeSettingsFlagTests`
Expected: PASS

- [ ] **Step 5: `TerminalSessionManager`'a settings path'i geçir + spawn'da uygula**

`TerminalSessionManager` init'ine stored property + init parametresi ekle (mevcut init imzasına opsiyonel, default `nil`):

```swift
private let claudeSettingsPath: String?
```
init parametre listesine `claudeSettingsPath: String? = nil,` ekle ve gövdede `self.claudeSettingsPath = claudeSettingsPath`.

spawn'daki launch bloğunu (satır ~128-134) güncelle:

```swift
if let command {
    var launch = ClaudeSessionID.inject(
        into: command, sessionId: session.id.raw.uuidString.lowercased())
    if let claudeSettingsPath {
        launch = ClaudeSettingsFlag.inject(into: launch, settingsPath: claudeSettingsPath)
    }
    session.write(launch + "\r")
}
```

- [ ] **Step 6: AppContainer bootstrap'ta installer'ı çalıştır, path'i manager'a ver**

`AppContainer.swift` içinde `TerminalSessionManager` kurulan yeri bul; ondan ÖNCE:

```swift
let claudeSettingsPath = try? TranscriptSettingsInstaller(
    lumiRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumi")
).install().path
```
ve `TerminalSessionManager(...)` çağrısına `claudeSettingsPath: claudeSettingsPath` argümanını ekle. (LumiApp zaten LumiServices'e bağımlı; import gerekmiyorsa `import LumiServices` ekle.)

- [ ] **Step 7: Tüm suite yeşil**

Run: `cd LumiPackages && swift build && swift test`
Expected: build OK; mevcut + yeni testler PASS (henüz watcher/registry değişmedi).

- [ ] **Step 8: Commit**

```bash
git add LumiPackages/Sources/LumiTerminal/Session/ClaudeSettingsFlag.swift LumiPackages/Tests/LumiTerminalTests/ClaudeSettingsFlagTests.swift LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift LumiPackages/Sources/LumiApp/AppContainer.swift
git commit -m "feat(terminal): claude başlatırken --settings enjekte et + bootstrap'ta hook kur"
```

---

## Faz 2 — Mac: pointer store + watcher yeniden yazımı + RemoteService (LumiRemote)

### Task 4: `TranscriptPointerStore`

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/TranscriptPointerStore.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptPointerStoreTests.swift` (Create)

**Interfaces:**
- Produces: `struct TranscriptPointerStore { init(mapDir: URL); func transcriptPath(for terminalID: String) -> URL? }` — `mapDir/<tid>.json` okur, `transcript_path` alanını URL olarak döner (dosya var/yok kontrolü ÇAĞIRANA ait). Pointer yok / bozuk JSON / alan yok → nil.

- [ ] **Step 1: Failing test yaz**

```swift
import XCTest
@testable import LumiRemote

final class TranscriptPointerStoreTests: XCTestCase {
    private var mapDir: URL!
    override func setUp() {
        super.setUp()
        mapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: mapDir); super.tearDown() }

    private func writePointer(tid: String, path: String) throws {
        let json = #"{"session_id":"s","transcript_path":"\#(path)","cwd":"/c","source":"startup"}"#
        try json.data(using: .utf8)!.write(to: mapDir.appendingPathComponent("\(tid).json"))
    }

    func testReadsTranscriptPath() throws {
        try writePointer(tid: "tid1", path: "/tmp/foo/abc.jsonl")
        let store = TranscriptPointerStore(mapDir: mapDir)
        XCTAssertEqual(store.transcriptPath(for: "tid1"), URL(fileURLWithPath: "/tmp/foo/abc.jsonl"))
    }
    func testMissingPointerReturnsNil() {
        XCTAssertNil(TranscriptPointerStore(mapDir: mapDir).transcriptPath(for: "nope"))
    }
    func testCorruptJSONReturnsNil() throws {
        try "not json".data(using: .utf8)!.write(to: mapDir.appendingPathComponent("bad.json"))
        XCTAssertNil(TranscriptPointerStore(mapDir: mapDir).transcriptPath(for: "bad"))
    }
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter TranscriptPointerStoreTests`
Expected: FAIL — `cannot find 'TranscriptPointerStore' in scope`

- [ ] **Step 3: Store'u yaz**

```swift
import Foundation

/// SessionStart hook'unun yazdığı `<mapDir>/<terminalID>.json` pointer'ından bir
/// terminalin AKTİF transcript dosyasının yolunu okur. Hook her oturum başında
/// (startup/resume/clear/compact/fork) bu dosyayı atomik overwrite eder → pointer
/// her zaman güncel dosyayı gösterir (/clear'da yeni dosya, worktree'de doğru dizin).
/// Saf/senkron okuma; dosya var/yok kararı watcher'a aittir.
struct TranscriptPointerStore: Sendable {
    let mapDir: URL

    init(mapDir: URL) { self.mapDir = mapDir }

    func transcriptPath(for terminalID: String) -> URL? {
        let pointer = mapDir.appendingPathComponent("\(terminalID).json")
        guard let data = try? Data(contentsOf: pointer),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["transcript_path"] as? String, !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
```

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter TranscriptPointerStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/TranscriptPointerStore.swift LumiPackages/Tests/LumiRemoteTests/TranscriptPointerStoreTests.swift
git commit -m "feat(remote): TranscriptPointerStore — hook pointer'ından kesin transcript yolu"
```

---

### Task 5: `FeedItem`'a kontrol sinyalleri (`sessionReset`, `mirrorUnavailable`)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/TranscriptParser.swift:16-24` (enum + itemPayload)
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift` (mevcut dosyaya test ekle)

**Interfaces:**
- Produces: `FeedItem.sessionReset` ve `FeedItem.mirrorUnavailable` — transcript öğesi DEĞİL, kontrol sinyali. `itemPayload` bunlar için `[:]` döner (asla transcript olarak gönderilmez; `handleFeedItem` önce yakalar).

- [ ] **Step 1: Failing test yaz** — `TranscriptParserTests.swift` sonuna:

```swift
func testControlItemsHaveEmptyPayload() {
    XCTAssertTrue(FeedItem.sessionReset.itemPayload.isEmpty)
    XCTAssertTrue(FeedItem.mirrorUnavailable.itemPayload.isEmpty)
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter TranscriptParserTests.testControlItemsHaveEmptyPayload`
Expected: FAIL — `type 'FeedItem' has no member 'sessionReset'`

- [ ] **Step 3: Enum'a iki case + itemPayload branch ekle**

`TranscriptParser.swift` enum'una (satır 21 `case model` sonrası):

```swift
    /// Kontrol sinyali: terminalin aktif transcript dosyası değişti (/clear, resume,
    /// fork). Transcript öğesi değildir — RemoteService bunu `transcript_reset`
    /// event'ine çevirir; telefon feed'i temizler.
    case sessionReset
    /// Kontrol sinyali: bu terminale ait transcript dosyası bulunamıyor (pointer yok
    /// + <TID>.jsonl hiçbir proje dizininde yok) → "yansıtılamıyor".
    case mirrorUnavailable
```

`itemPayload` switch'ine (default'tan önce) ekle:

```swift
        case .sessionReset, .mirrorUnavailable:
            return [:]
```

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter TranscriptParserTests`
Expected: PASS (tüm parser testleri)

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/TranscriptParser.swift LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift
git commit -m "feat(remote): FeedItem kontrol sinyalleri sessionReset + mirrorUnavailable"
```

---

### Task 6: `TranscriptWatcher` yeniden yazımı (pointer → global exactFile → not-mirrored)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift` (tam yeniden yazım)
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift` (registry/heuristic testleri sil, yeni testler yaz)

**Interfaces:**
- Consumes: Task 4 `TranscriptPointerStore`; Task 5 `FeedItem.sessionReset`/`.mirrorUnavailable`.
- Produces: `TranscriptWatcher(projectsRoot: URL, terminalID: String, pointerStore: TranscriptPointerStore, pollInterval: Duration = .milliseconds(1500), notMirrorableAfterPolls: Int = 4)`; `func items() -> AsyncStream<FeedItem>`; `func stop()`; `func historyItems(limit:maxTailBytes:) async -> [FeedItem]`. `resolveMatch()`: pointer(dosya varsa) → global `<tid>.jsonl` → nil. Dosya değişince (ilk eşleşme sonrası) `.sessionReset` yield; grace sonrası kalıcı nil'de bir kez `.mirrorUnavailable` yield.

- [ ] **Step 1: Failing testler yaz** — `TranscriptWatcherTests.swift`'i TAMAMEN değiştir (registry/heuristic senaryoları kaldırıldı):

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class TranscriptWatcherTests: XCTestCase {
    private var root: URL!          // ~/.claude/projects karşılığı
    private var mapDir: URL!        // ~/.lumi/transcript-map karşılığı
    private let tid = "abcdef01-1111-4222-8333-abcdef012345"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("proj-\(UUID().uuidString)")
        mapDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("map-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: mapDir)
        super.tearDown()
    }

    private func assistantLine(_ t: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(t)"}]}}"# + "\n"
    }
    private func projDir(_ repo: String) -> URL {
        let d = root.appendingPathComponent(TranscriptParser.projectDirName(forCwd: repo))
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func writePointer(transcriptPath: String) throws {
        let json = #"{"session_id":"\#(tid)","transcript_path":"\#(transcriptPath)","source":"startup"}"#
        try json.data(using: .utf8)!.write(to: mapDir.appendingPathComponent("\(tid).json"))
    }
    private func makeWatcher(pollMs: Int = 50, grace: Int = 4) -> TranscriptWatcher {
        TranscriptWatcher(projectsRoot: root, terminalID: tid,
                          pointerStore: TranscriptPointerStore(mapDir: mapDir),
                          pollInterval: .milliseconds(pollMs), notMirrorableAfterPolls: grace)
    }

    func testTailsFileFromPointer() async throws {
        let dir = projDir("/tmp/demo")
        let file = dir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("eski").write(to: file, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: file.path)

        let watcher = makeWatcher()
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
        try h.write(contentsOf: assistantLine("yeni").data(using: .utf8)!); try h.close()

        var got: FeedItem?
        for await item in stream where item != .mirrorUnavailable { got = item; break }
        await watcher.stop()
        XCTAssertEqual(got, .assistantText("yeni"))
    }

    func testFallsBackToGlobalExactFileInWorktreeDir() async throws {
        // Pointer YOK; <tid>.jsonl repo-kökü DEĞİL worktree-türevi dizinde.
        let wtDir = projDir("/tmp/demo/.claude/worktrees/feat-x")
        let file = wtDir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("wt").write(to: file, atomically: true, encoding: .utf8)

        let watcher = makeWatcher()
        let items = await watcher.historyItems()
        await watcher.stop()
        XCTAssertEqual(items, [.assistantText("wt")], "global <tid>.jsonl araması worktree'yi bulmalı")
    }

    func testEmitsSessionResetWhenPointerSwitchesFile() async throws {
        let dir = projDir("/tmp/demo")
        let a = dir.appendingPathComponent("\(tid).jsonl")
        try assistantLine("a").write(to: a, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: a.path)

        let watcher = makeWatcher()
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))

        // /clear: yeni dosya + pointer güncellenir
        let b = dir.appendingPathComponent("newsession.jsonl")
        try assistantLine("b").write(to: b, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: b.path)

        var sawReset = false
        var sawB = false
        for await item in stream {
            if item == .sessionReset { sawReset = true }
            if item == .assistantText("b") { sawB = true }
            if sawReset && sawB { break }
        }
        await watcher.stop()
        XCTAssertTrue(sawReset, "dosya değişince sessionReset yayılmalı")
        XCTAssertTrue(sawB, "yeni dosyanın satırları akmalı")
    }

    func testEmitsMirrorUnavailableWhenNoFileAfterGrace() async throws {
        // Pointer yok, <tid>.jsonl hiçbir yerde yok.
        let watcher = makeWatcher(pollMs: 20, grace: 2)
        let stream = await watcher.items()
        var got: FeedItem?
        for await item in stream { got = item; break }
        await watcher.stop()
        XCTAssertEqual(got, .mirrorUnavailable)
    }

    func testStopFinishesStream() async throws {
        let watcher = makeWatcher()
        let stream = await watcher.items()
        await watcher.stop()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testHistoryItemsReturnsParsedTailFromPointer() async throws {
        let dir = projDir("/tmp/demo")
        let file = dir.appendingPathComponent("\(tid).jsonl")
        let lines = (1...5).map { assistantLine("m\($0)") }.joined()
        try lines.write(to: file, atomically: true, encoding: .utf8)
        try writePointer(transcriptPath: file.path)

        let watcher = makeWatcher()
        let items = await watcher.historyItems(limit: 3, maxTailBytes: 262_144)
        await watcher.stop()
        XCTAssertEqual(items, [.assistantText("m3"), .assistantText("m4"), .assistantText("m5")])
    }

    func testHistoryItemsEmptyWhenNoMatch() async {
        let watcher = makeWatcher()
        let items = await watcher.historyItems()
        await watcher.stop()
        XCTAssertTrue(items.isEmpty)
    }
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter TranscriptWatcherTests`
Expected: FAIL — yeni init imzası yok / derlenmez.

- [ ] **Step 3: `TranscriptWatcher`'ı yeniden yaz**

Tüm dosyayı değiştir:

```swift
import Foundation
import LumiKit

/// Bir terminalin Claude Code transcript'ini izler (spec §4.2), DETERMİNİSTİK eşleşme.
/// 1.5 sn polling. Eşleşme (bkz. `resolveMatch`):
/// 1. **Pointer:** SessionStart hook'unun yazdığı `<tid>.json` → `transcript_path`
///    (dosya diskte varsa). /clear/resume/compact/fork ve worktree bununla çözülür.
/// 2. **Fallback (global exactFile):** pointer yoksa (hook henüz tetiklenmedi/kurulu
///    değil), tüm `<projectsRoot>/*/` altında `<tid>.jsonl` ara. id global unique →
///    en çok bir sonuç; worktree'yi hook olmadan da bulur (ilk oturum köprüsü).
/// 3. Aksi halde nil → grace sonrası bir kez `.mirrorUnavailable` yayılır (not-mirrored).
///
/// Aktif dosya değişince (ilk eşleşme sonrası farklı dosya) `.sessionReset` yayılır →
/// RemoteService `transcript_reset` yollar → telefon feed'i temizler.
actor TranscriptWatcher {
    private let projectsRoot: URL
    private let terminalID: String
    private let pointerStore: TranscriptPointerStore
    private nonisolated let pollInterval: Duration
    private let notMirrorableAfterPolls: Int

    private var matchedFile: URL?
    private var offset: UInt64 = 0
    private var pendingPartial = ""
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FeedItem>.Continuation?
    private var everMatched = false
    private var emptyPolls = 0
    private var emittedUnavailable = false

    init(
        projectsRoot: URL,
        terminalID: String,
        pointerStore: TranscriptPointerStore,
        pollInterval: Duration = .milliseconds(1500),
        notMirrorableAfterPolls: Int = 4
    ) {
        self.projectsRoot = projectsRoot
        self.terminalID = terminalID.lowercased()
        self.pointerStore = pointerStore
        self.pollInterval = pollInterval
        self.notMirrorableAfterPolls = notMirrorableAfterPolls
    }

    func items() -> AsyncStream<FeedItem> {
        let (stream, continuation) = AsyncStream.makeStream(of: FeedItem.self)
        self.continuation = continuation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
        return stream
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        continuation?.finish(); continuation = nil
    }

    private func poll() async {
        let match = resolveMatch()
        if let match {
            emptyPolls = 0
            if match != matchedFile {
                let wasMatched = matchedFile != nil
                matchedFile = match
                offset = fileSize(match)
                pendingPartial = ""
                if wasMatched {
                    // Aktif dosya değişti (/clear, resume, fork) → reset sinyali.
                    continuation?.yield(.sessionReset)
                }
                everMatched = true
                emittedUnavailable = false
            }
        } else {
            // Eşleşme yok. Fresh oturumda pointer/dosya birkaç poll gecikebilir → grace.
            if matchedFile == nil, !everMatched, !emittedUnavailable {
                emptyPolls += 1
                if emptyPolls >= notMirrorableAfterPolls {
                    emittedUnavailable = true
                    continuation?.yield(.mirrorUnavailable)
                }
            }
            return
        }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    /// 1) pointer (dosya varsa) → 2) global <tid>.jsonl → nil.
    private func resolveMatch() -> URL? {
        if let p = pointerStore.transcriptPath(for: terminalID),
           FileManager.default.fileExists(atPath: p.path) {
            return p
        }
        return globalExactFile()
    }

    /// Tüm proje dizinlerinde `<tid>.jsonl` ara (id global unique → tek sonuç).
    private func globalExactFile() -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        let name = "\(terminalID).jsonl"
        for dir in dirs {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Eşleşen jsonl'in kuyruğunu parse edip son `limit` item'ı döner (backfill).
    /// Yayın başladıysa (continuation != nil) ilk eşleşmeyi kalıcılaştırır.
    func historyItems(limit: Int = 50, maxTailBytes: Int = 262_144) async -> [FeedItem] {
        let resolved = resolveMatch()
        rlog("historyItems tid=\(terminalID) matched=\(matchedFile?.lastPathComponent ?? "-") candidate=\(resolved?.lastPathComponent ?? "-")")
        let file: URL
        if let matched = matchedFile, FileManager.default.fileExists(atPath: matched.path) {
            file = matched
        } else if let resolved {
            if continuation != nil {
                matchedFile = resolved
                offset = fileSize(resolved)
                pendingPartial = ""
                everMatched = true
            }
            file = resolved
        } else {
            return []
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = fileSize(file)
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var chunk = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = chunk.firstIndex(of: "\n") {
            chunk = String(chunk[chunk.index(after: newline)...])
        }
        var items: [FeedItem] = []
        for line in chunk.components(separatedBy: "\n") where !line.isEmpty {
            items.append(contentsOf: TranscriptParser.parse(line: line))
        }
        return Array(items.suffix(limit))
    }

    private func readNewLines(from file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let chunk = pendingPartial + (String(data: data, encoding: .utf8) ?? "")
        var lines = chunk.components(separatedBy: "\n")
        pendingPartial = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        for line in lines where !line.isEmpty {
            for item in TranscriptParser.parse(line: line) {
                continuation?.yield(item)
            }
        }
    }
}
```

- [ ] **Step 4: Testi çalıştır, PASS gör**

Run: `cd LumiPackages && swift test --filter TranscriptWatcherTests`
Expected: PASS (yeni testler). Derleme `RemoteService`/registry yüzünden kırıksa Task 7'ye kadar `swift test --filter TranscriptWatcherTests` yerine hedefli çalıştırma yapılamayabilir — bu durumda Task 7 ile birlikte derlenecek; yine de bu adımda watcher dosyası izole derlenmeli.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift
git commit -m "feat(remote): TranscriptWatcher pointer-tabanlı deterministik eşleşme + reset/not-mirrored"
```

---

### Task 7: RemoteService entegrasyonu + `TranscriptClaimRegistry` kaldırma + snapshot `mirrorable`

**Files:**
- Delete: `LumiPackages/Sources/LumiRemote/TranscriptClaimRegistry.swift`
- Delete: registry testleri — `TranscriptWatcherTests`'teki registry senaryoları Task 6'da zaten kaldırıldı; ayrı `TranscriptClaimRegistryTests` dosyası varsa sil.
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (startWatcher/stopWatcher/handleFeedItem; `mirrorable` state; pointerStore + mapDir)
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift` (snapshot'a `mirrorable`; `transcriptResetEvent`)
- Test: `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift` (mirrorable + reset event)

**Interfaces:**
- Consumes: Task 4 `TranscriptPointerStore`, Task 6 yeni `TranscriptWatcher` init, Task 5 kontrol sinyalleri.
- Produces: `SnapshotBuilder.snapshot(..., mirrorable: [TerminalID: Bool] = [:])` — `false` olan session'a `entry["mirrorable"] = false`. `SnapshotBuilder.transcriptResetEvent(sessionId: String) -> [String: Any]` = `{"kind":"transcript_reset","sessionId":...}`.

- [ ] **Step 1: Failing test yaz** — `SnapshotBuilderTests.swift`'e:

```swift
func testSnapshotMarksNotMirrorable() {
    let id = TerminalID()
    let meta = TerminalMeta(id: id, name: "t", repoPath: "/r", createdAt: Date())
    let snap = SnapshotBuilder.snapshot(
        terminals: [meta], repos: [], personas: [], mirrorable: [id: false])
    let session = (snap["sessions"] as! [[String: Any]]).first!
    XCTAssertEqual(session["mirrorable"] as? Bool, false)
}

func testSnapshotOmitsMirrorableWhenTrue() {
    let id = TerminalID()
    let meta = TerminalMeta(id: id, name: "t", repoPath: "/r", createdAt: Date())
    let snap = SnapshotBuilder.snapshot(terminals: [meta], repos: [], personas: [])
    let session = (snap["sessions"] as! [[String: Any]]).first!
    XCTAssertNil(session["mirrorable"], "mirrorable yalnız false iken bulunur")
}

func testTranscriptResetEventShape() {
    let e = SnapshotBuilder.transcriptResetEvent(sessionId: "s1")
    XCTAssertEqual(e["kind"] as? String, "transcript_reset")
    XCTAssertEqual(e["sessionId"] as? String, "s1")
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiPackages && swift test --filter SnapshotBuilderTests`
Expected: FAIL — `mirrorable` argümanı / `transcriptResetEvent` yok.

- [ ] **Step 3: SnapshotBuilder'a `mirrorable` + `transcriptResetEvent` ekle**

`snapshot(...)` imzasına parametre ekle (currentModel'den sonra):

```swift
        mirrorable: [TerminalID: Bool] = [:]
```
`entry` kurulumuna (model satırının yanına) ekle:

```swift
            if mirrorable[meta.id] == false { entry["mirrorable"] = false }
```
Yeni static fonksiyon (awaitingDecisionEvent yanına):

```swift
    static func transcriptResetEvent(sessionId: String) -> [String: Any] {
        ["kind": "transcript_reset", "sessionId": sessionId]
    }
```

- [ ] **Step 4: `RemoteService`'i güncelle**

`RemoteService.swift`:
1. Property: `private let claimRegistry = TranscriptClaimRegistry()` (satır ~49) satırını kaldır; ekle:
```swift
    private let pointerStore: TranscriptPointerStore
    private var mirrorable: [TerminalID: Bool] = [:]
```
init gövdesinde (transcriptsRoot atamasından sonra) `pointerStore`'u kur:
```swift
        self.pointerStore = TranscriptPointerStore(
            mapDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lumi/transcript-map"))
```

2. `startWatcher(for:)`'ı sadeleştir:
```swift
    private func startWatcher(for meta: TerminalMeta) async {
        guard watchers[meta.id] == nil else { return }
        let watcher = TranscriptWatcher(
            projectsRoot: transcriptsRoot,
            terminalID: meta.id.raw.uuidString.lowercased(),
            pointerStore: pointerStore)
        watchers[meta.id] = watcher
        rlog("watcher started session=\(meta.id.description) repo=\(meta.repoPath)")
        let sessionId = meta.id
        watcherTasks[sessionId] = Task { [weak self] in
            let stream = await watcher.items()
            for await item in stream {
                await self?.handleFeedItem(item, sessionId: sessionId)
            }
        }
    }
```

3. `stopWatcher(for:)`: `await claimRegistry.unregister(owner: id)` satırını sil; ekle `mirrorable[id] = nil`.

4. `handleFeedItem(_:sessionId:)` başına, mevcut `switch` ÖNCESİNE, kontrol sinyallerini yakala:
```swift
        switch item {
        case .sessionReset:
            lastSummary[sessionId] = nil
            await connection.send(type: "event",
                payload: SnapshotBuilder.transcriptResetEvent(sessionId: sessionId.description))
            return
        case .mirrorUnavailable:
            guard mirrorable[sessionId] != false else { return }
            mirrorable[sessionId] = false
            await sendSnapshot()
            return
        default:
            break
        }
```

5. `sendSnapshot()` (satır ~288) içindeki `SnapshotBuilder.snapshot(...)` çağrısına `mirrorable: mirrorable` argümanını ekle. Başka snapshot üreten çağrı varsa ona da ekle.

- [ ] **Step 5: Registry dosyasını ve TÜM kalan referanslarını sil**

`claimRegistry` referansları: satır ~49 (property — Step 4.1'de gitti), ~118 (terminal-exit handler'da `unregister`), ~198 (`register`), ~208 (`registry:` argümanı — Step 4.2'de yeni startWatcher ile gitti), ~225 (stopWatcher `unregister` — Step 4.3'te gitti). Kalan 118 ve 198'i de kaldır (startWatcher'daki `dir`+`register` bloğu ve exit handler'daki `unregister`).

```bash
git rm LumiPackages/Sources/LumiRemote/TranscriptClaimRegistry.swift
grep -rn "claimRegistry\|TranscriptClaimRegistry" LumiPackages   # boş dönmeli
```

- [ ] **Step 6: Tüm suite yeşil**

Run: `cd LumiPackages && swift build && swift test`
Expected: build OK; TranscriptWatcher/PointerStore/SnapshotBuilder/Parser testleri PASS; registry testi kalmadı.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(remote): registry+mtime kaldır; pointer watcher + mirrorable/transcript_reset entegrasyonu"
```

---

## Faz 3 — Protokol + iOS (LumiMobileKit)

### Task 8: Protokol spec dokümanı

**Files:**
- Modify: `docs/spec/50-remote-protocol.md`

- [ ] **Step 1: `mirrorable` alanını snapshot bölümüne ekle**

`snapshot payload` → sessions nesnesi açıklamasına:
> `mirrorable` yalnız `false` olduğunda bulunur (yoksa → `true`); Lumi bu oturumun transcript dosyasını eşleyemiyor (Lumi-dışı/id'siz başlatılmış) — telefon "yansıtılamıyor" banner'ı gösterir, giden mesaj açık kalır.

- [ ] **Step 2: `transcript_reset` event'ini ekle**

`event payload` bölümüne yeni alt-başlık:
> ### `transcript_reset`
> `{ "kind": "transcript_reset", "sessionId": "<uuid>" }` — Mac, bir oturumun aktif transcript dosyası değişince (`/clear`/resume/fork) yollar. Telefon o oturumun feed'ini temizler; sonraki canlı `transcript` item'ları ve bir sonraki `get_history` yeni oturumu doldurur. Relay bakmaz (push yalnız `status_change`).

- [ ] **Step 3: Commit**

```bash
git add docs/spec/50-remote-protocol.md
git commit -m "docs(protocol): mirrorable alanı + transcript_reset event"
```

---

### Task 9: iOS decode — `mirrorable` + `transcript_reset`

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (SessionSummary + RemoteEvent)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (decodeEvent)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (handle)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `SessionSummary.mirrorable: Bool` (default true; decode key `mirrorable`); `RemoteEvent.transcriptReset(sessionId:)`; decode `kind:"transcript_reset"`; AppModel `.transcriptReset` → `feeds[sessionId] = []`, `activeQuestions[sessionId] = nil`.

- [ ] **Step 1: Failing testler yaz** — `ProtocolTests.swift`'e:

```swift
func testDecodesMirrorableFalseInSnapshot() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle","mirrorable":false}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snap)? = PhoneProtocol.decodeServerMessage(text) else { return XCTFail() }
    XCTAssertEqual(snap.sessions.first?.mirrorable, false)
}

func testMirrorableDefaultsTrueWhenAbsent() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle"}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snap)? = PhoneProtocol.decodeServerMessage(text) else { return XCTFail() }
    XCTAssertEqual(snap.sessions.first?.mirrorable, true)
}

func testDecodesTranscriptResetEvent() {
    let text = #"{"v":1,"type":"event","payload":{"kind":"transcript_reset","sessionId":"s1"}}"#
    guard case .event(.transcriptReset(let sid))? = PhoneProtocol.decodeServerMessage(text) else { return XCTFail() }
    XCTAssertEqual(sid, "s1")
}
```

- [ ] **Step 2: Testi çalıştır, FAIL gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: FAIL — `mirrorable` yok / `transcriptReset` yok.

- [ ] **Step 3: `SessionSummary`'e `mirrorable` ekle**

`Models.swift` SessionSummary'e:
- property: `public let mirrorable: Bool`
- init parametresi: `mirrorable: Bool = true,` ve gövdede `self.mirrorable = mirrorable`
- `CodingKeys`'e `mirrorable` ekle
- `init(from:)` içinde (mevcut decode deseninde, awaitingDecision gibi opsiyonel):
```swift
        mirrorable = (try? c.decode(Bool.self, forKey: .mirrorable)) ?? true
```

- [ ] **Step 4: `RemoteEvent` + decode ekle**

`Models.swift` RemoteEvent enum'una:
```swift
    case transcriptReset(sessionId: String)
```
`PhoneProtocol.swift` `decodeEvent` switch'ine (`model_change`'den sonra):
```swift
        case "transcript_reset":
            return .transcriptReset(sessionId: sessionId)
```

- [ ] **Step 5: `AppModel.handle`'a reset işleme ekle**

`AppModel.swift` `handle` switch'ine (`.event(.modelChange...)`'den sonra):
```swift
        case .event(.transcriptReset(let sessionId)):
            macOnline = true
            feeds[sessionId] = []
            activeQuestions[sessionId] = nil
```

- [ ] **Step 6: Testi çalıştır, PASS gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "feat(mobile): mirrorable decode + transcript_reset event (feed temizle)"
```

---

### Task 10: iOS UI — "yansıtılamıyor" banner

**Files:**
- Modify: `LumiMobile/App/SessionDetailView.swift`

**Interfaces:**
- Consumes: Task 9 `SessionSummary.mirrorable`.

- [ ] **Step 1: Banner'ı ekle**

`SessionDetailView` gövdesinde, feed listesinin ÜSTÜNE, oturum `mirrorable == false` iken görünen bir banner ekle (mevcut oturum `session` erişimiyle):

```swift
if session.mirrorable == false {
    HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
        Text("Bu oturum Lumi dışından başlatıldı — transcript yansıtılamıyor. Mesaj göndermek çalışır.")
            .font(.footnote)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.15))
    .foregroundStyle(.orange)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal)
}
```
(`session` değişkeninin bu view'da nasıl elde edildiğine uy — AppModel'den `model.session(id)?.mirrorable ?? true` şeklinde de okunabilir.)

- [ ] **Step 2: Derle + görsel doğrula**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -scheme LumiMobile -destination 'generic/platform=iOS' build` (veya mevcut build betiği)
Expected: build OK.

- [ ] **Step 3: Commit**

```bash
git add LumiMobile/App/SessionDetailView.swift
git commit -m "feat(mobile): yansıtılamayan oturum için uyarı banner'ı"
```

---

## Manuel doğrulama (implementasyon sonrası, cihazda)

- [ ] Lumi'yi bu branch'ten derleyip çalıştır; `~/.lumi/hooks/session-start.sh` + `~/.lumi/claude-settings.json` oluştuğunu doğrula.
- [ ] Lumi'den claude terminali aç; `~/.lumi/transcript-map/<TID>.json` oluşuyor ve `transcript_path` doğru mu?
- [ ] Telefonda o chat'in canlı transcript'i geliyor mu?
- [ ] Chat'te `/clear` yap → telefon feed'i temizleniyor ve yeni oturum akıyor mu? (`transcript_reset`)
- [ ] Worktree'ye giren bir oturum (cwd `.claude/worktrees/...`) telefona doğru yansıyor mu?
- [ ] Rider'dan/elle `claude` başlat (Lumi terminali değil) → o oturum telefonda "yansıtılamıyor" banner'ıyla mı görünüyor / listede mi? (mirrorable=false)
- [ ] Aynı repoda 3 Lumi tab → mesaj sızması YOK (crosstalk gitti).

## Notlar / riskler
- `--settings` ile PTY-spawn'da hook'un tetiklendiği Task 3 sonrası ilk manuel testte doğrulanmalı (belgede engel yok; bilinen bug yok).
- Kurumsal `allowManagedHooksOnly: true` → hook bloklanır → fallback global exactFile (ilk oturum yansır, /clear takip edilmez → not-mirrored). Kabul, dokümante.
- Claude JSONL/hook alan adları sürüme bağlı (v2.1.169+ doğrulandı).
