# Lumi Remote — Plan 2/3: LumiRemote (Mac Modülü) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lumi'ye, canlı relay'e (`wss://lumi-relay-production.up.railway.app`) bağlanıp oturum durumu + transcript akışı gönderen ve telefondan gelen komutları PTY'ye ileten `LumiRemote` SPM modülünü eklemek.

**Architecture:** Mevcut mimari kalıp birebir izlenir: protokoller/modeller LumiKit'e, implementasyon yeni `LumiRemote` target'ına (yalnız LumiKit'e bağımlı), UI durumu `LumiState`'teki yeni store'a, kablolama `AppContainer`'a. Saf mantık (zarf codec'i, snapshot üretimi, transcript parser, tuş haritası, backoff) ws/dosya sisteminden ayrık ve birim testli; `RelayConnection` (URLSessionWebSocketTask) ve `TranscriptWatcher` (dosya polling) ince I/O katmanları.

**Tech Stack:** Swift 6 (strict concurrency), SPM, XCTest, URLSessionWebSocketTask, JSONSerialization (karar 9: bilinmeyen anahtar korunur), CoreImage (QR).

**Bağlayıcı sözleşme:** `docs/spec/50-remote-protocol.md` (zarf `{"v":1,"type":...,"payload":{...}}`, mesaj tablosu, komut aksiyonları). Tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` §4.2, §5, §7.

## Global Constraints

- Swift 6 strict concurrency; macOS 14+; Combine YOK — servis→store `AsyncStream`, store→UI `@Observable` (repo CLAUDE.md)
- `LumiRemote` target'ı YALNIZ `LumiKit`'e bağımlı; `LumiState` LumiKit'e bağımlı kalır; `LumiUI` LumiRemote'u import ETMEZ (protokol LumiKit'te)
- Persistence uyumluluğu (karar 9): `remote.json` JSONSerialization ile okunur/yazılır, bilinmeyen anahtarlar yazımda AYNEN korunur; mevcut `config.json` formatına dokunulmaz
- Protokol zarfı: `{"v": 1, "type": "<tip>", "payload": {...}}`; tipler: hello/welcome/snapshot/event/command/command_result/register_push/ping/pong
- Token ≥ 16 karakter; Lumi tarafında 32 bayt rastgele → base64url (43 karakter) üretilir
- `press_key` haritası (protokol dokümanı): `"1"|"2"|"3"` → karakterin kendisi, `"enter"` → `"\r"`, `"esc"` → `"\u{1B}"`; başka tuş kabul edilmez
- Transcript proje dizini kodlaması: cwd'deki `[A-Za-z0-9]` dışındaki HER karakter `-` olur (ör. `/Users/balkan/wkspaces/sand_out` → `-Users-balkan-wkspaces-sand-out`)
- Testler XCTest (`import XCTest`, `@testable import LumiRemote`); her task TDD; test komutu: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter LumiRemoteTests`
- Mevcut 231+ Lumi testi bozulmaz: her task sonunda dokunulan modülün testleri, Task 9 sonunda tüm `swift test` koşulur
- Commit'ler `feature/lumi-remote-mac` branch'ine, `remote:` öneki ile

## File Structure

```
LumiPackages/Package.swift                                (Task 1: LumiRemote target + test target; LumiApp deps)
LumiPackages/Sources/LumiKit/Support/LumiPaths.swift      (Task 1: remoteFile property)
LumiPackages/Sources/LumiKit/Models/RemoteModels.swift    (Task 1: RemoteConfig, RemoteConnectionState, RemoteEvent)
LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift (Task 1: UI'nin göreceği sınır)
LumiPackages/Sources/LumiRemote/RemoteConfigService.swift (Task 2: remote.json okuma/yazma + token üretimi)
LumiPackages/Sources/LumiRemote/RemoteProtocol.swift      (Task 3: zarf codec + press_key haritası + backoff)
LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift     (Task 3: [TerminalMeta]+[Repo]+[Persona] → payload)
LumiPackages/Sources/LumiRemote/TranscriptParser.swift    (Task 4: jsonl satırı → FeedItem; dizin kodlama)
LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift   (Task 5: dosya eşleştirme + polling tail)
LumiPackages/Sources/LumiRemote/RelayConnection.swift     (Task 6: ws istemcisi + yeniden bağlanma)
LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift(Task 7: send_text/press_key/start_session)
LumiPackages/Sources/LumiRemote/RemoteService.swift       (Task 8: orkestratör, RemoteServicing impl)
LumiPackages/Sources/LumiState/RemoteStore.swift          (Task 9: @Observable köprü)
LumiPackages/Sources/LumiUI/SettingsView.swift            (Task 9: Remote bölümü + QR)
LumiPackages/Sources/LumiApp/AppContainer.swift           (Task 9: DI kablolama)
Scripts/fake-phone.mjs                                    (Task 10: uçtan uca doğrulama istemcisi)
LumiPackages/Tests/LumiRemoteTests/*                      (Task 2-8 testleri)
```

---

### Task 1: LumiKit sınırı + Package.swift

**Files:**
- Modify: `LumiPackages/Package.swift`
- Modify: `LumiPackages/Sources/LumiKit/Support/LumiPaths.swift` (uiStateFile satırının altına)
- Create: `LumiPackages/Sources/LumiKit/Models/RemoteModels.swift`
- Create: `LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift`
- Test: `LumiPackages/Tests/LumiKitTests/RemoteModelsTests.swift`

**Interfaces:**
- Consumes: `LumiPaths` mevcut yapısı
- Produces: `RemoteConfig { enabled: Bool; relayUrl: String; token: String }` (+ `defaults`), `RemoteConnectionState { disconnected, connecting, connected }`, `RemoteEvent { stateChanged(RemoteConnectionState) }`, `RemoteServicing` protokolü, `LumiPaths.remoteFile: URL`, Package'da `LumiRemote` target'ı

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiKitTests/RemoteModelsTests.swift`:

```swift
import XCTest
@testable import LumiKit

final class RemoteModelsTests: XCTestCase {
    func testDefaults() {
        let d = RemoteConfig.defaults
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.relayUrl, "wss://lumi-relay-production.up.railway.app")
        XCTAssertEqual(d.token, "")
    }

    func testRemoteFilePath() {
        let paths = LumiPaths(mode: .development)
        XCTAssertEqual(paths.remoteFile.lastPathComponent, "remote.json")
        XCTAssertEqual(paths.remoteFile.deletingLastPathComponent(), paths.configDir)
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter RemoteModelsTests 2>&1 | tail -5`
Expected: derleme hatası — `RemoteConfig` bulunamıyor.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiKit/Models/RemoteModels.swift`:

```swift
import Foundation

/// `~/.lumi/remote.json` şeması (Lumi Remote tasarımı §7). config.json'dan
/// bilinçli olarak ayrı dosya — karar 9 gereği mevcut format değişmez.
public struct RemoteConfig: Sendable, Equatable {
    public var enabled: Bool
    public var relayUrl: String
    public var token: String

    public static let defaults = RemoteConfig(
        enabled: false,
        relayUrl: "wss://lumi-relay-production.up.railway.app",
        token: ""
    )

    public init(enabled: Bool, relayUrl: String, token: String) {
        self.enabled = enabled
        self.relayUrl = relayUrl
        self.token = token
    }
}

public enum RemoteConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
}

public enum RemoteEvent: Sendable, Equatable {
    case stateChanged(RemoteConnectionState)
}
```

`LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift`:

```swift
import Foundation

/// Relay istemcisinin servis sınırı. Implementasyon LumiRemote'ta;
/// LumiUI yalnız bu protokolü (RemoteStore üzerinden) görür.
@MainActor
public protocol RemoteServicing: AnyObject, Sendable {
    var state: RemoteConnectionState { get }
    var currentConfig: RemoteConfig { get }
    /// Config'i günceller, diske yazar; enabled değiştiyse bağlantıyı açar/kapar.
    func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async
    /// Yeni token üretip kaydeder ve (bağlıysa) yeniden bağlanır.
    func regenerateToken() async
    func start() async
    func stop()
    func events() -> AsyncStream<RemoteEvent>
}
```

`LumiPaths.swift` — `uiStateFile` computed property'sinin hemen altına ekle:

```swift
    public var remoteFile: URL { configDir.appendingPathComponent("remote.json") }
```

`Package.swift` değişiklikleri:
- products'a: `.library(name: "LumiRemote", targets: ["LumiRemote"]),`
- targets'a (LumiState target'ından sonra): `.target(name: "LumiRemote", dependencies: ["LumiKit"]),`
- LumiApp executableTarget dependencies listesine: `"LumiRemote",`
- testTargets'a: `.testTarget(name: "LumiRemoteTests", dependencies: ["LumiRemote"]),`

Ayrıca boş target derlensin diye placeholder oluştur: `LumiPackages/Sources/LumiRemote/RemoteModule.swift` içeriği:

```swift
// LumiRemote: relay istemcisi. Parçalar Task 2-8'de eklenir.
```

ve `LumiPackages/Tests/LumiRemoteTests/PlaceholderTests.swift`:

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testModuleCompiles() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter RemoteModelsTests 2>&1 | tail -3` → PASS (2 test)
Run: `swift build 2>&1 | tail -2` → `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Package.swift LumiPackages/Sources/LumiKit LumiPackages/Sources/LumiRemote LumiPackages/Tests
git commit -m "remote: LumiKit sınırı (RemoteConfig/RemoteServicing) + LumiRemote target'ı"
```

---

### Task 2: RemoteConfigService — remote.json + token üretimi

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/RemoteConfigService.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteConfigServiceTests.swift` (PlaceholderTests.swift'i sil)

**Interfaces:**
- Consumes: `LumiPaths`, `RemoteConfig` (Task 1)
- Produces: `actor RemoteConfigService { init(paths: LumiPaths); func load() -> RemoteConfig; func save(_ config: RemoteConfig); func ensureToken() -> RemoteConfig }`; `generateToken() -> String` (43 karakterlik base64url, dosya-kapsamı fonksiyon, test edilebilir)

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteConfigServiceTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class RemoteConfigServiceTests: XCTestCase {
    private var tempHome: URL!
    private var paths: LumiPaths!

    override func setUp() {
        super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-remote-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = LumiPaths(mode: .development, homeDirectory: tempHome)
        try! paths.ensureDirectoriesExist()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    func testLoadWithoutFileReturnsDefaults() async {
        let service = RemoteConfigService(paths: paths)
        let config = await service.load()
        XCTAssertEqual(config, RemoteConfig.defaults)
    }

    func testSaveThenLoadRoundTrips() async {
        let service = RemoteConfigService(paths: paths)
        var config = RemoteConfig.defaults
        config.enabled = true
        config.token = "secret-token-1234567890"
        await service.save(config)
        let loaded = await service.load()
        XCTAssertEqual(loaded, config)
    }

    func testUnknownKeysPreservedOnSave() async throws {
        let raw = #"{"enabled": false, "relayUrl": "wss://x", "token": "t-1234567890123456", "futureKey": {"a": 1}}"#
        try raw.data(using: .utf8)!.write(to: paths.remoteFile)
        let service = RemoteConfigService(paths: paths)
        var config = await service.load()
        config.enabled = true
        await service.save(config)
        let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.remoteFile)) as! [String: Any]
        XCTAssertNotNil(dict["futureKey"], "bilinmeyen anahtar korunmalı (karar 9)")
        XCTAssertEqual(dict["enabled"] as? Bool, true)
    }

    func testEnsureTokenGeneratesOnceAndPersists() async {
        let service = RemoteConfigService(paths: paths)
        let first = await service.ensureToken()
        XCTAssertGreaterThanOrEqual(first.token.count, 16)
        let second = await service.ensureToken()
        XCTAssertEqual(first.token, second.token, "mevcut token yeniden üretilmemeli")
    }

    func testGenerateTokenShapeAndUniqueness() {
        let a = generateToken()
        let b = generateToken()
        XCTAssertEqual(a.count, 43)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "base64url olmalı")
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter RemoteConfigServiceTests 2>&1 | tail -5`
Expected: derleme hatası — `RemoteConfigService` yok.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/RemoteConfigService.swift` (RemoteModule.swift'i sil):

```swift
import Foundation
import LumiKit

/// 32 bayt rastgele → base64url (43 karakter, padding'siz).
func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// `remote.json` persistence'ı. ConfigService kalıbı: JSONSerialization +
/// ham-dict merge — bilinmeyen anahtarlar yazımda korunur (karar 9).
public actor RemoteConfigService {
    private let paths: LumiPaths

    public init(paths: LumiPaths) {
        self.paths = paths
    }

    public func load() -> RemoteConfig {
        guard let dict = readRaw() else { return .defaults }
        return RemoteConfig(
            enabled: dict["enabled"] as? Bool ?? RemoteConfig.defaults.enabled,
            relayUrl: dict["relayUrl"] as? String ?? RemoteConfig.defaults.relayUrl,
            token: dict["token"] as? String ?? RemoteConfig.defaults.token
        )
    }

    public func save(_ config: RemoteConfig) {
        var merged = readRaw() ?? [:]
        merged["enabled"] = config.enabled
        merged["relayUrl"] = config.relayUrl
        merged["token"] = config.token
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: paths.remoteFile, options: .atomic)
    }

    /// Token boşsa üretip kaydeder; her durumda güncel config'i döner.
    public func ensureToken() -> RemoteConfig {
        var config = load()
        if config.token.isEmpty {
            config.token = generateToken()
            save(config)
        }
        return config
    }

    private func readRaw() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.remoteFile),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter RemoteConfigServiceTests 2>&1 | tail -3` → PASS (5 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote LumiPackages/Tests/LumiRemoteTests
git commit -m "remote: RemoteConfigService — remote.json + token üretimi"
```

---

### Task 3: RemoteProtocol (zarf codec + tuş haritası + backoff) ve SnapshotBuilder

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift`
- Create: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: `TerminalMeta`, `TerminalID`, `TerminalStatus`, `Repo`, `Persona` (LumiKit)
- Produces:
  - `enum RemoteProtocol { static func envelope(type: String, payload: [String: Any]) -> Data?; static func decode(_ data: Data) -> (type: String, payload: [String: Any])?; static func decode(text: String) -> (type: String, payload: [String: Any])? }`
  - `func keySequence(for key: String) -> String?` (dosya kapsamı: "1"/"2"/"3"→kendisi, "enter"→"\r", "esc"→"\u{1B}", diğerleri nil)
  - `struct ReconnectBackoff { mutating func nextDelay() -> Double; mutating func reset() }` (1,2,4,8,…,60 sn cap)
  - `enum SnapshotBuilder { static func snapshot(terminals: [TerminalMeta], repos: [Repo], personas: [Persona]) -> [String: Any]; static func statusChangeEvent(meta: TerminalMeta, status: TerminalStatus, repoName: String, summary: String?) -> [String: Any] }`

- [ ] **Step 1: Başarısız testleri yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift`:

```swift
import Foundation
import XCTest
@testable import LumiRemote

final class RemoteProtocolTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let data = try XCTUnwrap(RemoteProtocol.envelope(type: "hello", payload: ["role": "mac", "token": "t-1234567890123456"]))
        let decoded = try XCTUnwrap(RemoteProtocol.decode(data))
        XCTAssertEqual(decoded.type, "hello")
        XCTAssertEqual(decoded.payload["role"] as? String, "mac")
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["v"] as? Int, 1)
    }

    func testDecodeRejectsBadInput() {
        XCTAssertNil(RemoteProtocol.decode(text: "not json"))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":2,"type":"ping","payload":{}}"#))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":1,"payload":{}}"#))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":1,"type":"ping"}"#))
    }

    func testKeySequenceMap() {
        XCTAssertEqual(keySequence(for: "1"), "1")
        XCTAssertEqual(keySequence(for: "2"), "2")
        XCTAssertEqual(keySequence(for: "3"), "3")
        XCTAssertEqual(keySequence(for: "enter"), "\r")
        XCTAssertEqual(keySequence(for: "esc"), "\u{1B}")
        XCTAssertNil(keySequence(for: "rm -rf"))
        XCTAssertNil(keySequence(for: "f4"))
    }

    func testBackoffDoublesAndCapsAndResets() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        for _ in 0..<10 { _ = backoff.nextDelay() }
        XCTAssertEqual(backoff.nextDelay(), 60)
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
```

`LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class SnapshotBuilderTests: XCTestCase {
    private func meta(name: String = "claude", repoPath: String = "/tmp/repo") -> TerminalMeta {
        TerminalMeta(
            id: TerminalID(), name: name, repoPath: repoPath,
            createdAt: Date(timeIntervalSince1970: 1000),
            task: nil, oscTitle: "✳ çalışıyor", status: .working
        )
    }

    func testSnapshotShape() throws {
        let m = meta()
        let repo = Repo(name: "repo", path: "/tmp/repo", isGitRepo: true, source: .projectsRoot)
        let persona = Persona(id: "reviewer", label: "Reviewer")
        let snap = SnapshotBuilder.snapshot(terminals: [m], repos: [repo], personas: [persona])

        let sessions = try XCTUnwrap(snap["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["id"] as? String, m.id.description)
        XCTAssertEqual(sessions[0]["repoName"] as? String, "repo")
        XCTAssertEqual(sessions[0]["repoPath"] as? String, "/tmp/repo")
        XCTAssertEqual(sessions[0]["status"] as? String, "working")
        XCTAssertEqual(sessions[0]["title"] as? String, "✳ çalışıyor")

        let repos = try XCTUnwrap(snap["repos"] as? [[String: Any]])
        XCTAssertEqual(repos[0]["name"] as? String, "repo")
        let personas = try XCTUnwrap(snap["personas"] as? [[String: Any]])
        XCTAssertEqual(personas[0]["id"] as? String, "reviewer")
        XCTAssertEqual(personas[0]["label"] as? String, "Reviewer")
    }

    func testSnapshotRepoNameFallsBackToLastPathComponent() throws {
        let m = meta(repoPath: "/Users/x/wkspaces/sand_out")
        let snap = SnapshotBuilder.snapshot(terminals: [m], repos: [], personas: [])
        let sessions = try XCTUnwrap(snap["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions[0]["repoName"] as? String, "sand_out")
    }

    func testStatusChangeEvent() {
        let m = meta()
        let event = SnapshotBuilder.statusChangeEvent(
            meta: m, status: .waitingUnseen, repoName: "repo", summary: "Bash izni istiyor")
        XCTAssertEqual(event["kind"] as? String, "status_change")
        XCTAssertEqual(event["sessionId"] as? String, m.id.description)
        XCTAssertEqual(event["status"] as? String, "waiting-unseen")
        XCTAssertEqual(event["repoName"] as? String, "repo")
        XCTAssertEqual(event["summary"] as? String, "Bash izni istiyor")
    }

    func testStatusChangeEventOmitsNilSummary() {
        let event = SnapshotBuilder.statusChangeEvent(
            meta: meta(), status: .error, repoName: "repo", summary: nil)
        XCTAssertNil(event["summary"])
    }
}
```

Not: `TerminalMeta`/`Repo`/`Persona` init imzaları LumiKit'te mevcut — `TerminalMeta(id:name:repoPath:createdAt:task:oscTitle:status:)`, `Repo(name:path:isGitRepo:source:)`, `Persona(id:label:)`. `RepoSource.projectsRoot` yoksa derleme hatasındaki gerçek case adını kullan (`RepoModels.swift`'e bak — muhtemel adaylar: `.projectsRoot`, `.root`, `.additional`).

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `swift test --filter RemoteProtocolTests 2>&1 | tail -3` → derleme hatası (RemoteProtocol yok).

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/RemoteProtocol.swift`:

```swift
import Foundation

/// Zarf codec'i — docs/spec/50-remote-protocol.md ile birebir.
enum RemoteProtocol {
    static let version = 1

    static func envelope(type: String, payload: [String: Any]) -> Data? {
        let dict: [String: Any] = ["v": version, "type": type, "payload": payload]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(_ data: Data) -> (type: String, payload: [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["v"] as? Int == version,
              let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any] else { return nil }
        return (type, payload)
    }

    static func decode(text: String) -> (type: String, payload: [String: Any])? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }
}

/// `press_key` sözleşmesi (protokol dokümanı): yalnız bu beş tuş.
func keySequence(for key: String) -> String? {
    switch key {
    case "1", "2", "3": return key
    case "enter": return "\r"
    case "esc": return "\u{1B}"
    default: return nil
    }
}

/// 1,2,4,8,…60 sn üstel geri çekilme.
struct ReconnectBackoff {
    private var attempt = 0
    private let capSeconds: Double = 60

    mutating func nextDelay() -> Double {
        let delay = min(pow(2, Double(attempt)), capSeconds)
        attempt += 1
        return delay
    }

    mutating func reset() { attempt = 0 }
}
```

`LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`:

```swift
import Foundation
import LumiKit

/// Telefon-yönelik durum özetini üretir (spec §4.2). Saf — I/O yok.
enum SnapshotBuilder {
    static func snapshot(
        terminals: [TerminalMeta],
        repos: [Repo],
        personas: [Persona]
    ) -> [String: Any] {
        let repoNames = Dictionary(uniqueKeysWithValues: repos.map { ($0.path, $0.name) })
        let sessions: [[String: Any]] = terminals.map { meta in
            var entry: [String: Any] = [
                "id": meta.id.description,
                "repoPath": meta.repoPath,
                "repoName": repoNames[meta.repoPath]
                    ?? (meta.repoPath as NSString).lastPathComponent,
                "status": meta.status.rawValue,
            ]
            if let title = meta.oscTitle { entry["title"] = title }
            return entry
        }
        return [
            "sessions": sessions,
            "repos": repos.map { ["name": $0.name, "path": $0.path] },
            "personas": personas.map { ["id": $0.id, "label": $0.label] },
        ]
    }

    static func statusChangeEvent(
        meta: TerminalMeta,
        status: TerminalStatus,
        repoName: String,
        summary: String?
    ) -> [String: Any] {
        var event: [String: Any] = [
            "kind": "status_change",
            "sessionId": meta.id.description,
            "status": status.rawValue,
            "repoName": repoName,
        ]
        if let summary { event["summary"] = summary }
        return event
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter LumiRemoteTests 2>&1 | tail -3` → PASS (RemoteConfig 5 + protocol 4 + snapshot 4 = 13 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote LumiPackages/Tests/LumiRemoteTests
git commit -m "remote: zarf codec, tuş haritası, backoff ve SnapshotBuilder"
```

---

### Task 4: TranscriptParser — jsonl satırı → FeedItem + dizin kodlama

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/TranscriptParser.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `enum FeedItem: Equatable { case assistantText(String); case toolUse(name: String, summary: String); case question(payload: [Question]); case turnDone }` ve `struct Question: Equatable { let header: String; let question: String; let options: [String] }`
  - `enum TranscriptParser { static func parse(line: String) -> [FeedItem]; static func projectDirName(forCwd: String) -> String }`
  - `FeedItem.eventPayload(sessionId: String) -> [String: Any]` — relay'e giden `{kind:"transcript", sessionId, item:{...}}`

**Format referansı (gerçek dosyalardan doğrulandı):** kayıtlar tek satır JSON. `type=="assistant"` → `message.content[]` blokları: `{"type":"text","text":...}`, `{"type":"tool_use","id","name","input":{...}}`, `{"type":"thinking",...}` (atlanır). `message.stop_reason=="end_turn"` → turn bitti. `AskUserQuestion` tool_use'unun `input.questions[]`: `{header, question, multiSelect, options:[{label,...}]}`. Diğer kayıt tipleri (`user`, `system`, `attachment`, meta satırları) atlanır. cwd→dizin kodlaması: `[A-Za-z0-9]` dışındaki her karakter `-`.

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift`:

```swift
import Foundation
import XCTest
@testable import LumiRemote

final class TranscriptParserTests: XCTestCase {
    func testProjectDirNameEncoding() {
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/balkan/Lumi"),
                       "-Users-balkan-Lumi")
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/balkan/wkspaces/sand_out"),
                       "-Users-balkan-wkspaces-sand-out")
        XCTAssertEqual(TranscriptParser.projectDirName(forCwd: "/Users/b/.unco-runner/x+y"),
                       "-Users-b--unco-runner-x-y")
    }

    func testAssistantTextParsed() {
        let line = #"{"type":"assistant","uuid":"u1","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Şimdi derliyorum."}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.assistantText("Şimdi derliyorum.")])
    }

    func testToolUseSummarized() {
        let line = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test","description":"Run tests"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.toolUse(name: "Bash", summary: "Run tests")])
    }

    func testToolUseSummaryFallsBackToPathThenCommand() {
        let edit = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/a/b/Config.swift"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: edit), [.toolUse(name: "Edit", summary: "Config.swift")])
        let bash = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls -la"}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: bash), [.toolUse(name: "Bash", summary: "ls -la")])
        let bare = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: bare), [.toolUse(name: "Read", summary: "")])
    }

    func testAskUserQuestionBecomesQuestion() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{"questions":[{"header":"Ağ","question":"Nereden erişim?","multiSelect":false,"options":[{"label":"Tailscale"},{"label":"Relay"}]}]}}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [
            .question(payload: [Question(header: "Ağ", question: "Nereden erişim?", options: ["Tailscale", "Relay"])])
        ])
    }

    func testEndTurnAppendsTurnDone() {
        let line = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Bitti."}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [.assistantText("Bitti."), .turnDone])
    }

    func testIrrelevantAndBrokenLinesYieldNothing() {
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"user","message":{"role":"user","content":"selam"}}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"system","subtype":"turn_duration"}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: #"{"type":"ai-title","aiTitle":"x"}"#), [])
        XCTAssertEqual(TranscriptParser.parse(line: "yarım json {"), [])
        XCTAssertEqual(TranscriptParser.parse(line: ""), [])
    }

    func testThinkingBlocksSkipped() {
        let line = #"{"type":"assistant","message":{"stop_reason":null,"content":[{"type":"thinking","thinking":"gizli akıl yürütme"}]}}"#
        XCTAssertEqual(TranscriptParser.parse(line: line), [])
    }

    func testEventPayloadShape() throws {
        let item = FeedItem.toolUse(name: "Bash", summary: "swift test")
        let payload = item.eventPayload(sessionId: "s1")
        XCTAssertEqual(payload["kind"] as? String, "transcript")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        let inner = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertEqual(inner["itemType"] as? String, "tool_use")
        XCTAssertEqual(inner["tool"] as? String, "Bash")
        XCTAssertEqual(inner["summary"] as? String, "swift test")
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter TranscriptParserTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/TranscriptParser.swift`:

```swift
import Foundation

public struct Question: Equatable, Sendable {
    let header: String
    let question: String
    let options: [String]

    init(header: String, question: String, options: [String]) {
        self.header = header
        self.question = question
        self.options = options
    }
}

/// Telefona giden sadeleştirilmiş akış birimi (spec §5 tablosu).
public enum FeedItem: Equatable, Sendable {
    case assistantText(String)
    case toolUse(name: String, summary: String)
    case question(payload: [Question])
    case turnDone

    func eventPayload(sessionId: String) -> [String: Any] {
        var item: [String: Any]
        switch self {
        case .assistantText(let text):
            item = ["itemType": "assistant_text", "text": text]
        case .toolUse(let name, let summary):
            item = ["itemType": "tool_use", "tool": name, "summary": summary]
        case .question(let questions):
            item = ["itemType": "question", "questions": questions.map {
                ["header": $0.header, "question": $0.question, "options": $0.options]
            }]
        case .turnDone:
            item = ["itemType": "turn_done"]
        }
        return ["kind": "transcript", "sessionId": sessionId, "item": item]
    }
}

/// Claude Code transcript jsonl kayıtlarını FeedItem'lara çevirir.
/// Format Anthropic'in iç formatı — toleranslı parse: bilinmeyen/bozuk
/// kayıtlar sessizce atlanır (tasarım riski §12.2).
enum TranscriptParser {
    /// cwd → ~/.claude/projects altındaki dizin adı: alfanümerik olmayan her karakter `-`.
    static func projectDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func parse(line: String) -> [FeedItem] {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["type"] as? String == "assistant",
              let message = dict["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var items: [FeedItem] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    items.append(.assistantText(text))
                }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "AskUserQuestion", let questions = parseQuestions(input) {
                    items.append(.question(payload: questions))
                } else {
                    items.append(.toolUse(name: name, summary: toolSummary(input)))
                }
            default:
                break // thinking vb. atlanır
            }
        }
        if message["stop_reason"] as? String == "end_turn" {
            items.append(.turnDone)
        }
        return items
    }

    /// Tek satırlık tool özeti: description > file_path'in son bileşeni > command > "".
    private static func toolSummary(_ input: [String: Any]) -> String {
        if let description = input["description"] as? String { return description }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let command = input["command"] as? String { return command }
        return ""
    }

    private static func parseQuestions(_ input: [String: Any]) -> [Question]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return raw.compactMap { q in
            guard let question = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
            return Question(
                header: q["header"] as? String ?? "",
                question: question,
                options: options
            )
        }
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter TranscriptParserTests 2>&1 | tail -3` → PASS (9 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/TranscriptParser.swift LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift
git commit -m "remote: TranscriptParser — jsonl → FeedItem + proje dizin kodlaması"
```

---

### Task 5: TranscriptWatcher — dosya eşleştirme + polling tail

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift`

**Interfaces:**
- Consumes: `TranscriptParser`, `FeedItem` (Task 4)
- Produces:
```swift
actor TranscriptWatcher {
    init(projectsRoot: URL, repoPath: String, sessionCreatedAt: Date,
         pollInterval: Duration = .milliseconds(1500))
    /// Eşleşen dosya bulunursa yeni FeedItem'ları akıtır; bulunamazsa akış
    /// açık kalır ve her poll'da yeniden dener (yalnız-durum modu, spec §5).
    func items() -> AsyncStream<FeedItem>
    func stop()
}
```
- Eşleştirme kuralı: `projectsRoot/<projectDirName(repoPath)>/*.jsonl` içinde **mtime >= sessionCreatedAt - 120sn** olan en yeni dosya; bir kez eşleşince pinlenir. Yalnız YENİ eklenen satırlar akar (dosyanın eşleşme anındaki boyutundan itibaren; yarım satır bir sonraki poll'a sarkar).

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift`:

```swift
import Foundation
import XCTest
@testable import LumiRemote

final class TranscriptWatcherTests: XCTestCase {
    private var root: URL!
    private var projectDir: URL!
    private let repoPath = "/tmp/demo-repo"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        projectDir = root.appendingPathComponent(TranscriptParser.projectDirName(forCwd: repoPath))
        try! FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func assistantLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }

    func testTailsOnlyNewLinesAppendedAfterMatch() async throws {
        let file = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try assistantLine("eski").write(to: file, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()

        // Eşleşme gerçekleşsin diye kısa bekleme, sonra yeni satır ekle
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: assistantLine("yeni").data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("yeni")], "eşleşme öncesi satırlar akmamalı")
    }

    func testIgnoresFilesOlderThanSession() async throws {
        let old = projectDir.appendingPathComponent("old.jsonl")
        try assistantLine("bayat").write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeIntervalDouble(-3600)], ofItemAtPath: old.path)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date(),  // dosyadan çok sonra
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()

        try await Task.sleep(for: .milliseconds(150))
        // Yeni bir dosya oluşunca eşleşmeli
        let fresh = projectDir.appendingPathComponent("fresh.jsonl")
        try Data().write(to: fresh)
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: fresh)
        try handle.write(contentsOf: assistantLine("taze").data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("taze")])
    }

    func testPartialLineWaitsForCompletion() async throws {
        let file = projectDir.appendingPathComponent("s.jsonl")
        try Data().write(to: file)
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date().addingTimeInterval(-60),
            pollInterval: .milliseconds(50))
        let stream = await watcher.items()
        try await Task.sleep(for: .milliseconds(150))

        let full = assistantLine("tam")
        let half = String(full.prefix(20))
        let rest = String(full.dropFirst(20))
        var handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: half.data(using: .utf8)!)
        try handle.close()
        try await Task.sleep(for: .milliseconds(150))
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: rest.data(using: .utf8)!)
        try handle.close()

        var received: [FeedItem] = []
        for await item in stream {
            received.append(item)
            break
        }
        await watcher.stop()
        XCTAssertEqual(received, [.assistantText("tam")])
    }

    func testStopFinishesStream() async throws {
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: repoPath,
            sessionCreatedAt: Date(), pollInterval: .milliseconds(50))
        let stream = await watcher.items()
        await watcher.stop()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "stop() akışı sonlandırmalı")
    }
}

private extension Date {
    func addingTimeIntervalDouble(_ t: Double) -> Date { addingTimeInterval(t) }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter TranscriptWatcherTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift`:

```swift
import Foundation
import LumiKit

/// Bir terminal oturumunun Claude Code transcript'ini izler (spec §4.2).
/// Dosya sistemi olayı yerine basit polling: 1.5 sn'de bir dizin/dosya kontrolü.
/// Eşleşme: repo cwd'sinin proje dizinindeki, oturum başlangıcından (−120 sn
/// tolerans) yeni, en güncel mtime'lı jsonl. Eşleşemezse akış boş kalır —
/// "yalnız durum modu" (spec §5); her poll'da yeniden denenir.
actor TranscriptWatcher {
    private let projectDir: URL
    private let sessionCreatedAt: Date
    private let pollInterval: Duration

    private var matchedFile: URL?
    private var offset: UInt64 = 0
    private var pendingPartial = ""
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FeedItem>.Continuation?

    init(
        projectsRoot: URL,
        repoPath: String,
        sessionCreatedAt: Date,
        pollInterval: Duration = .milliseconds(1500)
    ) {
        self.projectDir = projectsRoot
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: repoPath))
        self.sessionCreatedAt = sessionCreatedAt
        self.pollInterval = pollInterval
    }

    func items() -> AsyncStream<FeedItem> {
        let (stream, continuation) = AsyncStream.makeStream(of: FeedItem.self)
        self.continuation = continuation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                guard let interval = await self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func poll() {
        if matchedFile == nil { tryMatch() }
        guard let file = matchedFile else { return }
        readNewLines(from: file)
    }

    private func tryMatch() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = sessionCreatedAt.addingTimeInterval(-120)
        let candidates = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? {
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return mtime >= cutoff ? (url, mtime) : nil
            }
            .sorted { $0.1 > $1.1 }
        guard let (file, _) = candidates.first else { return }
        matchedFile = file
        // Eşleşme anındaki içerik "geçmiş"tir — yalnız sonrası akar.
        offset = (try? fm.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
    }

    private func readNewLines(from file: URL) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let chunk = pendingPartial + (String(data: data, encoding: .utf8) ?? "")
        var lines = chunk.components(separatedBy: "\n")
        // Son parça \n ile bitmiyorsa yarım satırdır — bir sonraki poll'a sakla.
        pendingPartial = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        for line in lines where !line.isEmpty {
            for item in TranscriptParser.parse(line: line) {
                continuation?.yield(item)
            }
        }
    }
}
```

Not — Swift derleme detayı: `compactMap` closure'ındaki tuple dönüşü tip çıkarımını zorlarsa açık imza kullan: `.compactMap { url -> (URL, Date)? in ... }`.

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter TranscriptWatcherTests 2>&1 | tail -3` → PASS (4 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift
git commit -m "remote: TranscriptWatcher — dosya eşleştirme ve polling tail"
```

---

### Task 6: RelayConnection — ws istemcisi + yeniden bağlanma

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/RelayConnection.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RelayConnectionTests.swift`

**Interfaces:**
- Consumes: `RemoteProtocol`, `ReconnectBackoff` (Task 3), `RemoteConnectionState` (LumiKit)
- Produces:
```swift
/// RemoteService'in bağlantı bağımlılığı — testte sahtelenir.
protocol RelayConnecting: Actor {
    func start(url: URL, hello: [String: Any])
    func stop()
    func send(type: String, payload: [String: Any])
    /// Gelen zarflar + bağlantı durumu değişimleri.
    func inbound() -> AsyncStream<RelayInbound>
}

enum RelayInbound: Sendable {
    case stateChanged(RemoteConnectionState)
    case message(type: String, payload: [String: Any])
}

actor RelayConnection: RelayConnecting { init(session: URLSession = .shared) }
```
- Davranış: `start` → durum `.connecting` yayınla, `URLSessionWebSocketTask` aç, hello zarfını gönder, receive döngüsü başlat. `welcome` DAHİL her mesaj `.message` olarak akar; ilk mesaj alınınca durum `.connected` + backoff reset. Hata/kopma → `.disconnected` yayınla, `ReconnectBackoff.nextDelay()` bekle, aynı url/hello ile yeniden dene. `stop()` → task iptal, akış SONLANMAZ (yeniden start edilebilir), durum `.disconnected`.
- `RelayInbound.message` payload'ı `[String: Any]` olduğundan `Sendable` uyarısı: `RelayInbound`'u `@unchecked Sendable` işaretle (JSON değerleri pratikte value-type).

Not: gerçek ağ birim testte kullanılmaz. `RelayConnection`'ın kendisi Task 10'daki canlı smoke ile doğrulanır; bu task'in birim testleri yalnız durum makinesi yüzeyini (`inbound()` akışına state yayını, stop sonrası yeniden start) kapsar — ws framework'ünü mock'lamaya çalışma.

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/RelayConnectionTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class RelayConnectionTests: XCTestCase {
    func testStartPublishesConnectingThenDisconnectedOnUnreachableHost() async throws {
        let connection = RelayConnection()
        let stream = await connection.inbound()
        // Kapalı porta bağlanma → connecting, ardından disconnected beklenir
        await connection.start(
            url: URL(string: "ws://127.0.0.1:1")!,
            hello: ["role": "mac", "token": "secret-token-1234567890"])

        var states: [RemoteConnectionState] = []
        for await inbound in stream {
            if case .stateChanged(let s) = inbound {
                states.append(s)
                if states.count == 2 { break }
            }
        }
        await connection.stop()
        XCTAssertEqual(states, [.connecting, .disconnected])
    }

    func testStopIsIdempotentAndAllowsRestart() async throws {
        let connection = RelayConnection()
        _ = await connection.inbound()
        await connection.stop()
        await connection.stop()
        await connection.start(
            url: URL(string: "ws://127.0.0.1:1")!,
            hello: ["role": "mac", "token": "secret-token-1234567890"])
        await connection.stop()
        // Çökmeden buraya gelmek yeterli
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter RelayConnectionTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/RelayConnection.swift`:

```swift
import Foundation
import LumiKit

enum RelayInbound: @unchecked Sendable {
    case stateChanged(RemoteConnectionState)
    case message(type: String, payload: [String: Any])
}

protocol RelayConnecting: Actor {
    func start(url: URL, hello: [String: Any])
    func stop()
    func send(type: String, payload: [String: Any])
    func inbound() -> AsyncStream<RelayInbound>
}

/// URLSessionWebSocketTask tabanlı relay istemcisi. Kopunca üstel geri
/// çekilmeyle aynı hello'yla yeniden bağlanır (spec §4.2, §9).
actor RelayConnection: RelayConnecting {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var backoff = ReconnectBackoff()
    private var continuation: AsyncStream<RelayInbound>.Continuation?
    private var currentURL: URL?
    private var currentHello: [String: Any] = [:]
    private var stopped = true

    init(session: URLSession = .shared) {
        self.session = session
    }

    func inbound() -> AsyncStream<RelayInbound> {
        let (stream, continuation) = AsyncStream.makeStream(of: RelayInbound.self)
        self.continuation = continuation
        return stream
    }

    func start(url: URL, hello: [String: Any]) {
        stopped = false
        currentURL = url
        currentHello = hello
        connect()
    }

    func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.yield(.stateChanged(.disconnected))
    }

    func send(type: String, payload: [String: Any]) {
        guard let task, let data = RemoteProtocol.envelope(type: type, payload: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in } // hata → receive döngüsü zaten kopmayı görür
    }

    private func connect() {
        guard !stopped, let url = currentURL else { return }
        continuation?.yield(.stateChanged(.connecting))
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        if let data = RemoteProtocol.envelope(type: "hello", payload: currentHello),
           let text = String(data: data, encoding: .utf8) {
            wsTask.send(.string(text)) { _ in }
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: wsTask)
        }
    }

    private func receiveLoop(on wsTask: URLSessionWebSocketTask) async {
        var receivedAny = false
        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                if !receivedAny {
                    receivedAny = true
                    backoff.reset()
                    continuation?.yield(.stateChanged(.connected))
                }
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                if let decoded = RemoteProtocol.decode(text: text) {
                    continuation?.yield(.message(type: decoded.type, payload: decoded.payload))
                }
            } catch {
                break
            }
        }
        guard !stopped else { return }
        continuation?.yield(.stateChanged(.disconnected))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = backoff.nextDelay()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter RelayConnectionTests 2>&1 | tail -3` → PASS (2 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/RelayConnection.swift LumiPackages/Tests/LumiRemoteTests/RelayConnectionTests.swift
git commit -m "remote: RelayConnection — ws istemcisi ve üstel yeniden bağlanma"
```

---

### Task 7: RemoteCommandHandler — send_text / press_key / start_session

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift`

**Interfaces:**
- Consumes: `keySequence(for:)` (Task 3); LumiKit protokolleri: `TerminalServicing` (`write(id:text:)`, `spawn(repoPath:task:command:)`, `terminals`), `PersonaServicing` (`spawn(personaID:repoPath:)`), `TerminalID(raw: UUID)`
- Produces:
```swift
@MainActor
final class RemoteCommandHandler {
    init(terminal: any TerminalServicing, personas: any PersonaServicing)
    /// Telefondan gelen command payload'ını uygular; command_result payload'ı döner.
    func handle(_ payload: [String: Any]) async -> [String: Any]
}
func shellQuoted(_ s: String) -> String  // tek-tırnak sarma + ' kaçışı
```
- Davranışlar (hepsi `{commandId, ok, error?}` döner; commandId yoksa `NSNull()`):
  - `send_text {sessionId, text}` → id çözümle (UUID string → terminals içinde ara), `write(id:text: text + "\r")`
  - `press_key {sessionId, key}` → `keySequence` nil ise `ok:false error:"unknown_key"`; değilse write
  - `start_session {repoPath, personaId?, prompt}` → personaId varsa `personas.spawn(personaID:repoPath:)`, prompt boş değilse 3 sn sonra prompt+`"\r"` yaz (agent CLI'ın açılmasını beklemek için — bilinçli best-effort, spec riski); personaId yoksa `terminal.spawn(repoPath:task:nil,command: "claude " + shellQuoted(prompt))`
  - Bilinmeyen `action` → `ok:false, error:"unknown_action"`; oturum bulunamazsa `ok:false, error:"session_not_found"`; spawn/write fırlatırsa `ok:false, error:"<hata metni>"`

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

@MainActor
private final class FakeTerminal: TerminalServicing {
    var writes: [(TerminalID, String)] = []
    var spawns: [(repoPath: String, command: String?)] = []
    var metas: [TerminalMeta] = []
    var writeError: Error?

    func spawn(repoPath: String, task: String?, command: String?) throws -> TerminalMeta {
        spawns.append((repoPath, command))
        let meta = TerminalMeta(id: TerminalID(), name: "t", repoPath: repoPath,
                                createdAt: Date(), task: task, oscTitle: nil, status: .idle)
        metas.append(meta)
        return meta
    }
    func write(id: TerminalID, text: String) throws {
        if let writeError { throw writeError }
        writes.append((id, text))
    }
    func kill(id: TerminalID) throws {}
    func killAll() {}
    func resize(id: TerminalID, cols: Int, rows: Int) {}
    func setFocused(_ id: TerminalID?) {}
    func setWindowFocused(_ focused: Bool) {}
    var terminals: [TerminalMeta] { metas }
    func setMaxTerminals(_ n: Int) {}
    func events() -> AsyncStream<TerminalEvent> { AsyncStream { $0.finish() } }
    func outputStream(id: TerminalID) -> AsyncStream<String>? { nil }
}

private actor FakePersonas: PersonaServicing {
    var spawned: [(personaID: String, repoPath: String)] = []
    private let meta: TerminalMeta

    init(meta: TerminalMeta) { self.meta = meta }
    func personas(projectPath: String?) async -> [Persona] { [] }
    func seedDefaults() async {}
    func spawn(personaID: String, repoPath: String) async throws -> TerminalMeta {
        spawned.append((personaID, repoPath))
        return meta
    }
    func events() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func spawnCount() -> Int { spawned.count }
}

@MainActor
final class RemoteCommandHandlerTests: XCTestCase {
    private func makeHandler() -> (RemoteCommandHandler, FakeTerminal) {
        let terminal = FakeTerminal()
        let personaMeta = TerminalMeta(id: TerminalID(), name: "p", repoPath: "/r",
                                       createdAt: Date(), task: nil, oscTitle: nil, status: .idle)
        let handler = RemoteCommandHandler(terminal: terminal, personas: FakePersonas(meta: personaMeta))
        return (handler, terminal)
    }

    func testSendTextWritesWithEnter() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        terminal.spawns.removeAll()
        let result = await handler.handle([
            "commandId": "c1", "action": "send_text",
            "sessionId": meta.id.description, "text": "devam et",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["commandId"] as? String, "c1")
        XCTAssertEqual(terminal.writes.count, 1)
        XCTAssertEqual(terminal.writes[0].1, "devam et\r")
    }

    func testPressKeyMapsAndRejectsUnknown() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        var result = await handler.handle([
            "commandId": "c2", "action": "press_key",
            "sessionId": meta.id.description, "key": "esc",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(terminal.writes.last?.1, "\u{1B}")

        result = await handler.handle([
            "commandId": "c3", "action": "press_key",
            "sessionId": meta.id.description, "key": "delete-everything",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "unknown_key")
    }

    func testUnknownSessionAndUnknownAction() async {
        let (handler, _) = makeHandler()
        var result = await handler.handle([
            "commandId": "c4", "action": "send_text",
            "sessionId": UUID().uuidString, "text": "x",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "session_not_found")

        result = await handler.handle(["commandId": "c5", "action": "reboot"])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "unknown_action")
    }

    func testStartSessionWithoutPersonaSpawnsClaudeWithQuotedPrompt() async {
        let (handler, terminal) = makeHandler()
        let result = await handler.handle([
            "commandId": "c6", "action": "start_session",
            "repoPath": "/r", "prompt": "it's a bug; fix it",
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(terminal.spawns.count, 1)
        XCTAssertEqual(terminal.spawns[0].command, "claude 'it'\\''s a bug; fix it'")
    }

    func testShellQuoted() {
        XCTAssertEqual(shellQuoted("abc"), "'abc'")
        XCTAssertEqual(shellQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(shellQuoted(""), "''")
    }

    func testWriteFailureSurfacesError() async {
        let (handler, terminal) = makeHandler()
        let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
        terminal.writeError = NSError(domain: "test", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "pty kapalı"])
        let result = await handler.handle([
            "commandId": "c7", "action": "send_text",
            "sessionId": meta.id.description, "text": "x",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNotNil(result["error"])
    }
}
```

Not: `TerminalServicing` protokolünün TAM üye listesi derlemede belli olur — eksik üye hatası alırsan protokol dosyasına (`LumiKit/Protocols/TerminalServicing.swift`) bakıp fake'e aynen ekle (boş gövde yeterli).

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter RemoteCommandHandlerTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`:

```swift
import Foundation
import LumiKit

/// POSIX tek-tırnak quoting: ' → '\'' .
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Telefondan gelen komutları uygular (spec §4.2 RemoteCommandHandler).
/// Cevap her zaman command_result payload'ıdır: {commandId, ok, error?}.
@MainActor
final class RemoteCommandHandler {
    private let terminal: any TerminalServicing
    private let personas: any PersonaServicing
    /// start_session persona yolunda agent CLI'ın açılması için beklenen süre.
    /// Bilinçli best-effort (tasarım kararı) — test edilebilirlik için enjekte.
    private let personaPromptDelay: Duration

    init(
        terminal: any TerminalServicing,
        personas: any PersonaServicing,
        personaPromptDelay: Duration = .seconds(3)
    ) {
        self.terminal = terminal
        self.personas = personas
        self.personaPromptDelay = personaPromptDelay
    }

    func handle(_ payload: [String: Any]) async -> [String: Any] {
        let commandId = payload["commandId"] ?? NSNull()
        switch payload["action"] as? String {
        case "send_text":
            return result(commandId, run: {
                let id = try self.session(from: payload)
                let text = payload["text"] as? String ?? ""
                try self.terminal.write(id: id, text: text + "\r")
            })
        case "press_key":
            guard let sequence = keySequence(for: payload["key"] as? String ?? "") else {
                return ["commandId": commandId, "ok": false, "error": "unknown_key"]
            }
            return result(commandId, run: {
                let id = try self.session(from: payload)
                try self.terminal.write(id: id, text: sequence)
            })
        case "start_session":
            return await startSession(payload, commandId: commandId)
        default:
            return ["commandId": commandId, "ok": false, "error": "unknown_action"]
        }
    }

    private func startSession(_ payload: [String: Any], commandId: Any) async -> [String: Any] {
        let repoPath = payload["repoPath"] as? String ?? ""
        let prompt = payload["prompt"] as? String ?? ""
        do {
            if let personaId = payload["personaId"] as? String, !personaId.isEmpty {
                let meta = try await personas.spawn(personaID: personaId, repoPath: repoPath)
                if !prompt.isEmpty {
                    try? await Task.sleep(for: personaPromptDelay)
                    try terminal.write(id: meta.id, text: prompt + "\r")
                }
            } else {
                let command = prompt.isEmpty ? "claude" : "claude " + shellQuoted(prompt)
                _ = try terminal.spawn(repoPath: repoPath, task: nil, command: command)
            }
            return ["commandId": commandId, "ok": true]
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }

    private func session(from payload: [String: Any]) throws -> TerminalID {
        guard let raw = payload["sessionId"] as? String,
              let uuid = UUID(uuidString: raw),
              terminal.terminals.contains(where: { $0.id.raw == uuid })
        else { throw CommandError.sessionNotFound }
        return TerminalID(raw: uuid)
    }

    private func result(_ commandId: Any, run: () throws -> Void) -> [String: Any] {
        do {
            try run()
            return ["commandId": commandId, "ok": true]
        } catch CommandError.sessionNotFound {
            return ["commandId": commandId, "ok": false, "error": "session_not_found"]
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }

    private enum CommandError: Error { case sessionNotFound }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter RemoteCommandHandlerTests 2>&1 | tail -3` → PASS (6 test)

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift
git commit -m "remote: RemoteCommandHandler — send_text/press_key/start_session"
```

---

### Task 8: RemoteService — orkestratör

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: her şey — `RemoteConfigService` (T2), `SnapshotBuilder` (T3), `TranscriptWatcher`+`FeedItem` (T4/5), `RelayConnecting`+`RelayInbound` (T6), `RemoteCommandHandler` (T7); LumiKit: `TerminalServicing`, `RepoServicing`, `PersonaServicing`, `RemoteServicing`, `EventBroadcaster`
- Produces: `RemoteServicing` implementasyonu:
```swift
@MainActor
public final class RemoteService: RemoteServicing {
    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        personas: any PersonaServicing,
        connection: (any RelayConnecting)? = nil,   // nil → RelayConnection()
        transcriptsRoot: URL? = nil                 // nil → ~/.claude/projects
    )
}
```
- Davranış sözleşmesi (testler bunu doğrular):
  1. `start()`: config yükle (`ensureToken`), `enabled` değilse hiçbir şey yapma. Enabled ise: connection.start(url: relayUrl, hello: {role:"mac", token}), inbound tüketim task'i + terminal events tüketim task'i başlat, durum `.connecting`.
  2. `.message(type:"welcome")` alınınca → `send(type:"snapshot", payload: SnapshotBuilder.snapshot(...))` (repos `await repos.repos()`, personas `await personas.personas(projectPath: nil)`).
  3. TerminalEvent `.spawned`/`.exited` → taze snapshot gönder; `.spawned`'da o terminal için TranscriptWatcher başlat, `.exited`'da durdur.
  4. TerminalEvent `.statusChanged(id, status)` → `send(type:"event", payload: SnapshotBuilder.statusChangeEvent(...))`; summary = o oturum için son cache'lenen özet (aşağıda 5).
  5. Watcher'dan gelen her FeedItem → `send(type:"event", payload: item.eventPayload(sessionId:))`; ayrıca özet cache'i güncelle: `.question` → ilk sorunun metni, `.toolUse` → "\(name): \(summary)".
  6. `.message(type:"command")` → `RemoteCommandHandler.handle` → `send(type:"command_result", ...)`.
  7. `stop()` → tüm task'ler iptal, watcher'lar durdurulur, connection.stop().
  8. `updateConfig`: kaydet; `enabled` false→true `start()`, true→false `stop()`; relayUrl/token değiştiyse ve bağlıysa stop()+start(). `regenerateToken`: yeni token üret, kaydet, bağlıysa yeniden bağlan.
  9. `events()`: `EventBroadcaster<RemoteEvent>` — connection'dan gelen `.stateChanged` aynen yayınlanır ve `state` property güncellenir.

- [ ] **Step 1: Başarısız testi yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

/// Sahte bağlantı: gönderilenleri kaydeder, inbound'u testin kontrolüne verir.
private actor FakeConnection: RelayConnecting {
    var sent: [(type: String, payload: [String: Any])] = []
    var started: [(url: URL, hello: [String: Any])] = []
    var stopCount = 0
    private var continuation: AsyncStream<RelayInbound>.Continuation?

    func start(url: URL, hello: [String: Any]) { started.append((url, hello)) }
    func stop() { stopCount += 1 }
    func send(type: String, payload: [String: Any]) { sent.append((type, payload)) }
    func inbound() -> AsyncStream<RelayInbound> {
        let (stream, c) = AsyncStream.makeStream(of: RelayInbound.self)
        continuation = c
        return stream
    }
    func push(_ inbound: RelayInbound) { continuation?.yield(inbound) }
    func sentSnapshot() -> [(type: String, payload: [String: Any])] { sent }
    func startedCount() -> Int { started.count }
    func stops() -> Int { stopCount }
}

// FakeTerminal: RemoteCommandHandlerTests'tekiyle aynı yüzey + events push'u
@MainActor
private final class FakeTerminal: TerminalServicing {
    var metas: [TerminalMeta] = []
    var writes: [(TerminalID, String)] = []
    private var eventContinuations: [AsyncStream<TerminalEvent>.Continuation] = []

    func spawn(repoPath: String, task: String?, command: String?) throws -> TerminalMeta {
        let meta = TerminalMeta(id: TerminalID(), name: "t", repoPath: repoPath,
                                createdAt: Date(), task: task, oscTitle: nil, status: .idle)
        metas.append(meta)
        return meta
    }
    func write(id: TerminalID, text: String) throws { writes.append((id, text)) }
    func kill(id: TerminalID) throws {}
    func killAll() {}
    func resize(id: TerminalID, cols: Int, rows: Int) {}
    func setFocused(_ id: TerminalID?) {}
    func setWindowFocused(_ focused: Bool) {}
    var terminals: [TerminalMeta] { metas }
    func setMaxTerminals(_ n: Int) {}
    func events() -> AsyncStream<TerminalEvent> {
        let (stream, c) = AsyncStream.makeStream(of: TerminalEvent.self)
        eventContinuations.append(c)
        return stream
    }
    func outputStream(id: TerminalID) -> AsyncStream<String>? { nil }
    func pushEvent(_ e: TerminalEvent) { eventContinuations.forEach { $0.yield(e) } }
}

private actor FakeRepos: RepoServicing {
    func repos() async -> [Repo] { [Repo(name: "demo", path: "/tmp/demo", isGitRepo: true, source: .projectsRoot)] }
    func setRoots(projectsRoot: String, additionalPaths: [AdditionalPath]) async {}
    func fileTree(repoPath: String) async -> [FileTreeNode] { [] }
    func watchFileTree(repoPath: String) async {}
    func unwatchFileTree(repoPath: String) async {}
    func events() -> AsyncStream<RepoEvent> { AsyncStream { $0.finish() } }
}

private actor FakePersonas: PersonaServicing {
    func personas(projectPath: String?) async -> [Persona] { [Persona(id: "rev", label: "Reviewer")] }
    func seedDefaults() async {}
    func spawn(personaID: String, repoPath: String) async throws -> TerminalMeta {
        TerminalMeta(id: TerminalID(), name: "p", repoPath: repoPath,
                     createdAt: Date(), task: nil, oscTitle: nil, status: .idle)
    }
    func events() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor
final class RemoteServiceTests: XCTestCase {
    private var tempHome: URL!
    private var paths: LumiPaths!

    override func setUp() {
        super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-service-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = LumiPaths(mode: .development, homeDirectory: tempHome)
        try! paths.ensureDirectoriesExist()
        // enabled config hazırla
        let raw = #"{"enabled": true, "relayUrl": "wss://relay.test", "token": "secret-token-1234567890"}"#
        try! raw.data(using: .utf8)!.write(to: paths.remoteFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    private func makeService(connection: FakeConnection, terminal: FakeTerminal) -> RemoteService {
        RemoteService(
            paths: paths, terminal: terminal, repos: FakeRepos(),
            personas: FakePersonas(), connection: connection,
            transcriptsRoot: tempHome.appendingPathComponent("transcripts"))
    }

    private func drain() async { try? await Task.sleep(for: .milliseconds(200)) }

    func testStartSendsHelloWithToken() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        let started = await connection.started
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].url.absoluteString, "wss://relay.test")
        XCTAssertEqual(started[0].hello["role"] as? String, "mac")
        XCTAssertEqual(started[0].hello["token"] as? String, "secret-token-1234567890")
        service.stop()
    }

    func testDisabledConfigDoesNotConnect() async {
        let raw = #"{"enabled": false, "relayUrl": "wss://relay.test", "token": "secret-token-1234567890"}"#
        try! raw.data(using: .utf8)!.write(to: paths.remoteFile)
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        let count = await connection.startedCount()
        XCTAssertEqual(count, 0)
    }

    func testWelcomeTriggersSnapshot() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        _ = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()
        let sent = await connection.sentSnapshot()
        let snapshot = try XCTUnwrap(sent.first { $0.type == "snapshot" })
        let sessions = try XCTUnwrap(snapshot.payload["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual((snapshot.payload["repos"] as? [[String: Any]])?.count, 1)
        service.stop()
    }

    func testStatusChangeSendsEvent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        terminal.pushEvent(.statusChanged(meta.id, .waitingUnseen))
        await drain()
        let sent = await connection.sentSnapshot()
        let event = try XCTUnwrap(sent.first { $0.type == "event" })
        XCTAssertEqual(event.payload["kind"] as? String, "status_change")
        XCTAssertEqual(event.payload["status"] as? String, "waiting-unseen")
        XCTAssertEqual(event.payload["repoName"] as? String, "demo")
        service.stop()
    }

    func testCommandRoutedAndResultSent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        await connection.push(.message(type: "command", payload: [
            "commandId": "c1", "action": "send_text",
            "sessionId": meta.id.description, "text": "merhaba",
        ]))
        await drain()
        XCTAssertEqual(terminal.writes.last?.1, "merhaba\r")
        let sent = await connection.sentSnapshot()
        let result = try XCTUnwrap(sent.first { $0.type == "command_result" })
        XCTAssertEqual(result.payload["ok"] as? Bool, true)
        XCTAssertEqual(result.payload["commandId"] as? String, "c1")
        service.stop()
    }

    func testStateChangesBroadcast() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        let stream = service.events()
        await service.start()
        await drain()
        await connection.push(.stateChanged(.connected))
        var got: RemoteConnectionState?
        for await event in stream {
            if case .stateChanged(let s) = event, s == .connected { got = s; break }
        }
        XCTAssertEqual(got, .connected)
        XCTAssertEqual(service.state, .connected)
        service.stop()
    }

    func testStopStopsConnection() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        service.stop()
        await drain()
        let stops = await connection.stops()
        XCTAssertGreaterThanOrEqual(stops, 1)
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `swift test --filter RemoteServiceTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: Implementasyonu yaz**

`LumiPackages/Sources/LumiRemote/RemoteService.swift`:

```swift
import Foundation
import LumiKit

/// LumiRemote orkestratörü (spec §4.2): config'i okur, relay bağlantısını
/// yönetir, terminal olaylarını + transcript akışını relay'e çevirir ve
/// telefon komutlarını uygular. Servis→store sınırı: EventBroadcaster.
@MainActor
public final class RemoteService: RemoteServicing {
    public private(set) var state: RemoteConnectionState = .disconnected
    public private(set) var currentConfig: RemoteConfig = .defaults

    private let configService: RemoteConfigService
    private let terminal: any TerminalServicing
    private let repos: any RepoServicing
    private let personas: any PersonaServicing
    private let connection: any RelayConnecting
    private let commandHandler: RemoteCommandHandler
    private let transcriptsRoot: URL
    private let broadcaster = EventBroadcaster<RemoteEvent>()

    private var inboundTask: Task<Void, Never>?
    private var terminalTask: Task<Void, Never>?
    private var watchers: [TerminalID: TranscriptWatcher] = [:]
    private var watcherTasks: [TerminalID: Task<Void, Never>] = [:]
    private var lastSummary: [TerminalID: String] = [:]
    private var running = false

    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        personas: any PersonaServicing,
        connection: (any RelayConnecting)? = nil,
        transcriptsRoot: URL? = nil
    ) {
        self.configService = RemoteConfigService(paths: paths)
        self.terminal = terminal
        self.repos = repos
        self.personas = personas
        self.connection = connection ?? RelayConnection()
        self.commandHandler = RemoteCommandHandler(terminal: terminal, personas: personas)
        self.transcriptsRoot = transcriptsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
    }

    public func events() -> AsyncStream<RemoteEvent> { broadcaster.stream() }

    public func start() async {
        currentConfig = await configService.ensureToken()
        guard currentConfig.enabled, !running else { return }
        guard let url = URL(string: currentConfig.relayUrl) else { return }
        running = true

        let inboundStream = await connection.inbound()
        inboundTask = Task { [weak self] in
            for await inbound in inboundStream {
                await self?.handleInbound(inbound)
            }
        }
        let terminalStream = terminal.events()
        terminalTask = Task { [weak self] in
            for await event in terminalStream {
                await self?.handleTerminalEvent(event)
            }
        }
        for meta in terminal.terminals { startWatcher(for: meta) }
        await connection.start(url: url, hello: ["role": "mac", "token": currentConfig.token])
        setState(.connecting)
    }

    public func stop() {
        running = false
        inboundTask?.cancel(); inboundTask = nil
        terminalTask?.cancel(); terminalTask = nil
        for (id, task) in watcherTasks { task.cancel(); watcherTasks[id] = nil }
        let currentWatchers = watchers
        watchers = [:]
        Task { for (_, watcher) in currentWatchers { await watcher.stop() } }
        Task { [connection] in await connection.stop() }
        setState(.disconnected)
    }

    public func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async {
        var config = await configService.load()
        let old = config
        mutate(&config)
        await configService.save(config)
        currentConfig = config
        guard old != config else { return }
        if running { stop() }
        if config.enabled { await start() }
    }

    public func regenerateToken() async {
        await updateConfig { $0.token = generateToken() }
    }

    // MARK: - Inbound

    private func handleInbound(_ inbound: RelayInbound) async {
        switch inbound {
        case .stateChanged(let newState):
            setState(newState)
        case .message(let type, let payload):
            switch type {
            case "welcome":
                await sendSnapshot()
            case "command":
                let result = await commandHandler.handle(payload)
                await connection.send(type: "command_result", payload: result)
            default:
                break
            }
        }
    }

    // MARK: - Terminal olayları

    private func handleTerminalEvent(_ event: TerminalEvent) async {
        switch event {
        case .spawned(let meta):
            startWatcher(for: meta)
            await sendSnapshot()
        case .exited(let id, _):
            stopWatcher(for: id)
            await sendSnapshot()
        case .statusChanged(let id, let status):
            guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
            let repoName = await repoName(for: meta.repoPath)
            let payload = SnapshotBuilder.statusChangeEvent(
                meta: meta, status: status, repoName: repoName, summary: lastSummary[id])
            await connection.send(type: "event", payload: payload)
        default:
            break
        }
    }

    // MARK: - Transcript

    private func startWatcher(for meta: TerminalMeta) {
        guard watchers[meta.id] == nil else { return }
        let watcher = TranscriptWatcher(
            projectsRoot: transcriptsRoot,
            repoPath: meta.repoPath,
            sessionCreatedAt: meta.createdAt)
        watchers[meta.id] = watcher
        let sessionId = meta.id
        watcherTasks[sessionId] = Task { [weak self] in
            let stream = await watcher.items()
            for await item in stream {
                await self?.handleFeedItem(item, sessionId: sessionId)
            }
        }
    }

    private func stopWatcher(for id: TerminalID) {
        watcherTasks[id]?.cancel(); watcherTasks[id] = nil
        if let watcher = watchers.removeValue(forKey: id) {
            Task { await watcher.stop() }
        }
        lastSummary[id] = nil
    }

    private func handleFeedItem(_ item: FeedItem, sessionId: TerminalID) async {
        switch item {
        case .question(let questions):
            lastSummary[sessionId] = questions.first?.question
        case .toolUse(let name, let summary):
            lastSummary[sessionId] = summary.isEmpty ? name : "\(name): \(summary)"
        default:
            break
        }
        await connection.send(type: "event", payload: item.eventPayload(sessionId: sessionId.description))
    }

    // MARK: - Yardımcılar

    private func sendSnapshot() async {
        let repoList = await repos.repos()
        let personaList = await personas.personas(projectPath: nil)
        let payload = SnapshotBuilder.snapshot(
            terminals: terminal.terminals, repos: repoList, personas: personaList)
        await connection.send(type: "snapshot", payload: payload)
    }

    private func repoName(for path: String) async -> String {
        let repoList = await repos.repos()
        return repoList.first { $0.path == path }?.name
            ?? (path as NSString).lastPathComponent
    }

    private func setState(_ newState: RemoteConnectionState) {
        guard state != newState else { return }
        state = newState
        broadcaster.send(.stateChanged(newState))
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `swift test --filter RemoteServiceTests 2>&1 | tail -3` → PASS (7 test)
Run: `swift test --filter LumiRemoteTests 2>&1 | tail -3` → tüm LumiRemote testleri yeşil

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift
git commit -m "remote: RemoteService orkestratörü"
```

---

### Task 9: RemoteStore (LumiState) + Settings UI + AppContainer kablolama

**Files:**
- Create: `LumiPackages/Sources/LumiState/RemoteStore.swift`
- Modify: `LumiPackages/Sources/LumiUI/SettingsView.swift` (mevcut bölümlerin sonuna Remote bölümü)
- Modify: `LumiPackages/Sources/LumiApp/AppContainer.swift`
- Test: `LumiPackages/Tests/LumiStateTests/RemoteStoreTests.swift`

**Interfaces:**
- Consumes: `RemoteServicing`, `RemoteConfig`, `RemoteConnectionState`, `RemoteEvent` (LumiKit); `RemoteService` (LumiRemote, yalnız AppContainer'da)
- Produces:
```swift
@Observable @MainActor
public final class RemoteStore {
    public private(set) var state: RemoteConnectionState
    public private(set) var config: RemoteConfig
    public init(service: any RemoteServicing)
    public func start()                       // servis event'lerini tüketmeye başlar
    public func setEnabled(_ enabled: Bool) async
    public func setRelayUrl(_ url: String) async
    public func regenerateToken() async
    /// iOS eşleştirme QR içeriği: lumi-remote://pair?url=<..>&token=<..>
    public var pairingString: String { get }
}
```

- [ ] **Step 1: Başarısız store testini yaz**

`LumiPackages/Tests/LumiStateTests/RemoteStoreTests.swift`:

```swift
import Foundation
import XCTest
import LumiKit
@testable import LumiState

@MainActor
private final class FakeRemoteService: RemoteServicing {
    var state: RemoteConnectionState = .disconnected
    var currentConfig = RemoteConfig(enabled: false, relayUrl: "wss://r.test", token: "tok-1234567890123456")
    var startCount = 0
    private var continuation: AsyncStream<RemoteEvent>.Continuation?

    func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async {
        mutate(&currentConfig)
    }
    func regenerateToken() async { currentConfig.token = "yeni-token-1234567890" }
    func start() async { startCount += 1 }
    func stop() {}
    func events() -> AsyncStream<RemoteEvent> {
        let (stream, c) = AsyncStream.makeStream(of: RemoteEvent.self)
        continuation = c
        return stream
    }
    func push(_ e: RemoteEvent) { continuation?.yield(e) }
}

@MainActor
final class RemoteStoreTests: XCTestCase {
    func testStateFollowsServiceEvents() async throws {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        store.start()
        try await Task.sleep(for: .milliseconds(50))
        service.push(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.state, .connected)
    }

    func testSetEnabledUpdatesConfig() async {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        await store.setEnabled(true)
        XCTAssertTrue(store.config.enabled)
        XCTAssertTrue(service.currentConfig.enabled)
    }

    func testPairingStringEncodesUrlAndToken() {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        XCTAssertTrue(store.pairingString.hasPrefix("lumi-remote://pair?"))
        XCTAssertTrue(store.pairingString.contains("token=tok-1234567890123456"))
        XCTAssertTrue(store.pairingString.contains("url=wss%3A%2F%2Fr.test"))
    }

    func testRegenerateTokenRefreshesConfig() async {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        await store.regenerateToken()
        XCTAssertEqual(store.config.token, "yeni-token-1234567890")
    }
}
```

- [ ] **Step 2: Başarısızlığı doğrula**

Run: `swift test --filter RemoteStoreTests 2>&1 | tail -3` → derleme hatası.

- [ ] **Step 3: RemoteStore'u yaz**

`LumiPackages/Sources/LumiState/RemoteStore.swift`:

```swift
import Foundation
import LumiKit

/// RemoteServicing → UI köprüsü (servis→store AsyncStream, store→UI @Observable).
@Observable @MainActor
public final class RemoteStore {
    public private(set) var state: RemoteConnectionState
    public private(set) var config: RemoteConfig

    private let service: any RemoteServicing
    private var consumeTask: Task<Void, Never>?

    public init(service: any RemoteServicing) {
        self.service = service
        self.state = service.state
        self.config = service.currentConfig
    }

    public func start() {
        guard consumeTask == nil else { return }
        let stream = service.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let newState):
                    self.state = newState
                }
                self.config = self.service.currentConfig
            }
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        await service.updateConfig { $0.enabled = enabled }
        config = service.currentConfig
    }

    public func setRelayUrl(_ url: String) async {
        await service.updateConfig { $0.relayUrl = url }
        config = service.currentConfig
    }

    public func regenerateToken() async {
        await service.regenerateToken()
        config = service.currentConfig
    }

    public var pairingString: String {
        var components = URLComponents()
        components.scheme = "lumi-remote"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "url", value: config.relayUrl),
            URLQueryItem(name: "token", value: config.token),
        ]
        return components.string ?? ""
    }
}
```

Not: `url=wss%3A%2F%2F...` kodlaması için `URLComponents` yeterli değilse (`:` ve `/` query'de escape edilmez), `pairingString` içinde değerleri elle kodla:

```swift
    public var pairingString: String {
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        return "lumi-remote://pair?url=\(encode(config.relayUrl))&token=\(encode(config.token))"
    }
```

Test `url=wss%3A%2F%2Fr.test` beklediği için elle kodlayan varyantı kullan.

- [ ] **Step 4: Store testlerinin geçtiğini doğrula**

Run: `swift test --filter RemoteStoreTests 2>&1 | tail -3` → PASS (4 test)

- [ ] **Step 5: Settings UI bölümünü ekle**

`LumiPackages/Sources/LumiUI/SettingsView.swift` — önce dosyayı oku, mevcut bölüm kalıbını (başlık + içerik yerleşimi, hangi container view kullanılıyorsa) aynen izleyerek dosyanın bölümler listesinin SONUNA "Remote" bölümü ekle. `SettingsView`'a `RemoteStore` mevcut store'lar nasıl geçiriliyorsa öyle geçir (environment / init parametresi — dosyadaki kalıba uy). Bölüm içeriği:

```swift
// Remote bölümü — mevcut section kalıbıyla sarmala
@Bindable var remote = remoteStore  // dosyadaki kalıba göre uyarla

Toggle("Telefondan erişim", isOn: Binding(
    get: { remote.config.enabled },
    set: { newValue in Task { await remote.setEnabled(newValue) } }
))

// Durum satırı
HStack {
    Circle()
        .fill(remote.state == .connected ? Color.green
              : remote.state == .connecting ? Color.yellow : Color.gray)
        .frame(width: 8, height: 8)
    Text(remote.state == .connected ? "Bağlı"
         : remote.state == .connecting ? "Bağlanıyor…" : "Bağlı değil")
        .font(.caption)
}

TextField("Relay adresi", text: Binding(
    get: { remote.config.relayUrl },
    set: { _ in }  // düzenleme onSubmit'te
), prompt: Text("wss://…"))
.onSubmit { Task { await remote.setRelayUrl(remote.config.relayUrl) } }

if remote.config.enabled {
    // QR: iOS uygulaması bu kodu okutarak eşleşir (Plan 3)
    if let qr = QRCodeRenderer.image(for: remote.pairingString, scale: 6) {
        Image(nsImage: qr)
            .interpolation(.none)
            .frame(width: 160, height: 160)
    }
    Button("Token'ı yenile") { Task { await remote.regenerateToken() } }
}
```

TextField binding'i dosyadaki mevcut ayar kalıbına göre uyarla (SettingsView başka text ayarlarını nasıl yazıyorsa aynı yöntem; yerel `@State` + onSubmit kalıbı varsa onu kullan).

Ayrıca `LumiPackages/Sources/LumiUI/Support/QRCodeRenderer.swift` oluştur:

```swift
import AppKit
import CoreImage.CIFilterBuiltins

/// Eşleştirme QR'ı üretir (CIQRCodeGenerator).
enum QRCodeRenderer {
    static func image(for string: String, scale: CGFloat = 6) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
```

- [ ] **Step 6: AppContainer'ı kablola**

`LumiPackages/Sources/LumiApp/AppContainer.swift`:
- import listesine `LumiRemote` ekle
- Property'ler: `let remoteService: RemoteService` ve `let remoteStore: RemoteStore`
- `init` içinde (mevcut servis bloğunda, `personaService`'ten sonra):

```swift
remoteService = RemoteService(
    paths: paths,
    terminal: terminal,
    repos: repoService,
    personas: personaService
)
remoteStore = RemoteStore(service: remoteService)
```

- `start()` içinde, store'ların start edildiği blokta: `remoteStore.start()`; bootstrap'in sonunda: `Task { await remoteService.start() }` (enabled değilse no-op).
- SettingsView'a `remoteStore` mevcut store geçirme kalıbıyla ver (environment veya parametre — dosyadaki kalıba uy).
- Uygulama kapanışında (`shutdown`/`applicationWillTerminate` karşılığı neresiyse): `remoteService.stop()`.

- [ ] **Step 7: Tüm paketin derlendiğini ve TÜM testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift build 2>&1 | tail -2` → `Build complete!`
Run: `swift test 2>&1 | tail -4` → tüm testler yeşil (231+ mevcut + yeni LumiRemote/LumiState/LumiKit testleri). Mevcut bir test kırılırsa nedenini bul ve düzelt — bu task mevcut davranışı DEĞİŞTİRMEMELİ.

- [ ] **Step 8: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages
git commit -m "remote: RemoteStore + Settings Remote bölümü (QR) + AppContainer kablolama"
```

---

### Task 10: Uçtan uca doğrulama — canlı relay + sahte telefon

**Files:**
- Create: `Scripts/fake-phone.mjs`

**Interfaces:**
- Consumes: canlı relay (`wss://lumi-relay-production.up.railway.app`), Task 9 sonrası çalışan Lumi
- Produces: uçtan uca kanıt — telefon rolüyle bağlanan istemci Mac'in snapshot'ını görür ve `send_text` komutu Lumi terminaline ulaşır

- [ ] **Step 1: Sahte telefon istemcisini yaz**

`Scripts/fake-phone.mjs`:

```javascript
// Kullanım: node Scripts/fake-phone.mjs <token> [komut-modu]
// Telefon rolüyle relay'e bağlanır; welcome+snapshot'ı basar, event'leri dinler.
// "send <sessionId> <metin>" satırı yazılırsa send_text komutu gönderir.
import WebSocket from '../RelayServer/node_modules/ws/wrapper.mjs'
import readline from 'node:readline'

const token = process.argv[2]
if (!token) { console.error('kullanım: node fake-phone.mjs <token>'); process.exit(1) }

const ws = new WebSocket('wss://lumi-relay-production.up.railway.app')
const send = (type, payload) => ws.send(JSON.stringify({ v: 1, type, payload }))

ws.on('open', () => send('hello', { role: 'phone', token }))
ws.on('message', (d) => {
  const env = JSON.parse(d.toString())
  console.log(`\n[${env.type}]`, JSON.stringify(env.payload, null, 1).slice(0, 1200))
})
ws.on('close', () => { console.log('bağlantı kapandı'); process.exit(0) })

const rl = readline.createInterface({ input: process.stdin })
let n = 0
rl.on('line', (line) => {
  const m = line.match(/^send (\S+) (.+)$/)
  if (m) send('command', { commandId: `fp-${++n}`, action: 'send_text', sessionId: m[1], text: m[2] })
})
```

- [ ] **Step 2: Lumi'de remote'u etkinleştir (dev config)**

`~/.lumi-dev/remote.json` oluştur (token'ı not al):

```bash
python3 - <<'EOF'
import json, secrets, base64, pathlib
token = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip('=')
path = pathlib.Path.home() / '.lumi-dev' / 'remote.json'
path.write_text(json.dumps({
    "enabled": True,
    "relayUrl": "wss://lumi-relay-production.up.railway.app",
    "token": token,
}, indent=2))
print("TOKEN:", token)
EOF
```

- [ ] **Step 3: Uçtan uca senaryo**

1. `cd /Users/balkan/Lumi/LumiPackages && swift run Lumi` (arka planda)
2. `node /Users/balkan/Lumi/Scripts/fake-phone.mjs <TOKEN>` çalıştır
3. Doğrula: `[welcome]` payload'ında `macOnline: true`; ardından `[snapshot]` geliyor ve `sessions`/`repos` dolu (Lumi'de en az bir terminal açıksa `sessions` ≥ 1)
4. Lumi'de bir claude oturumu başlat; fake-phone çıktısında `[event] {"kind":"transcript",...}` satırlarının aktığını doğrula
5. fake-phone'da `send <sessionId> merhaba` yaz; Lumi terminalinde "merhaba" + Enter'ın işlendiğini ve `[command_result] {"ok":true}` döndüğünü doğrula
6. Lumi'yi kapat; fake-phone'a relay'den bir şey gelmediğini (bağlantının açık kaldığını) doğrula — Mac offline senaryosu
7. Ayarlar penceresinde Remote bölümünün durumu "Bağlı" gösterdiğini ve QR'ın çizildiğini gözle doğrula

- [ ] **Step 4: Sonucu belgele ve commit'le**

Senaryonun çıktısını (kısaltılmış) `.superpowers/sdd/plan2-e2e-notes.md`'ye yaz.

```bash
cd /Users/balkan/Lumi
git add Scripts/fake-phone.mjs
git commit -m "remote: fake-phone uçtan uca doğrulama istemcisi"
```

---

## Self-Review Kaydı

- **Spec kapsaması (§4.2):** RelayConnection→T6, SnapshotBuilder→T3, TranscriptWatcher→T4+T5, RemoteCommandHandler→T7, orkestrasyon+config→T2+T8, UI (bağlantı göstergesi+QR)→T9, uçtan uca→T10. §5 olay tablosu: assistant_text/tool_use/question/turn_done→T4, status_change→T8. §7 güvenlik: token üretimi→T2, QR eşleştirme→T9. §9 hata: yeniden bağlanma→T6, mac offline→relay tarafı (Plan 1'de hazır). §12.3 izin metni transcript'te yoksa: status_change summary cache'i (T8) genel kartın bağlamını sağlar.
- **Placeholder taraması:** temiz. T9 Step 5'te SettingsView'un mevcut kalıbına uyum talimatı bilinçli — dosyanın bugünkü tam halini plana gömmek yanlış-eskime riski taşır; implementer önce dosyayı okuyup kalıbı uygular (kod blokları içerik olarak eksiksiz).
- **Tip tutarlılığı:** `RelayConnecting.start(url:hello:)/stop()/send(type:payload:)/inbound()` T6↔T8 birebir; `FeedItem.eventPayload(sessionId:)` T4↔T8; `keySequence(for:)` T3↔T7; `RemoteServicing` T1↔T8↔T9; `TerminalServicing.spawn(repoPath:task:command:)` gerçek protokol imzasıyla doğrulandı.
- **Bilinen riskler (bilinçli):** (1) persona+prompt kombinasyonunda 3 sn best-effort bekleme — spec riski olarak kayıtlı; (2) transcript eşleştirme cwd+zaman sezgiseli — spec §12.1'de kabul edilmiş, "yalnız durum modu" fallback'i tanımlı; (3) RelayConnection'ın gerçek ws yolu birim test yerine T10 canlı smoke ile doğrulanıyor.

## Sonraki plan

- **Plan 3/3 — LumiMobile (iOS):** SwiftUI istemci + APNs. Bu planın T9 QR içeriği (`lumi-remote://pair?url=..&token=..`) Plan 3'ün eşleştirme girdisidir.
