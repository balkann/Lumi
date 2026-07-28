# Lumi Remote — Plan 3/3: LumiMobile (iOS SwiftUI App) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Canlı relay'e (`wss://lumi-relay-production.up.railway.app`) `role:"phone"` ile bağlanıp Lumi oturumlarını izleyen ve yönlendiren (send_text / press_key / start_session) SwiftUI iOS uygulaması `LumiMobile/` eklemek.

**Architecture:** Tüm mantık (protokol codec'i, modeller, eşleştirme, `RelayClient` ws istemcisi, `AppModel` view-model) **dual-platform SPM paketi** `LumiMobile/LumiMobileKit`'te yaşar (iOS 17 + macOS 14) — böylece testler Mac host'ta `swift test` ile simülatörsüz koşar. SwiftUI görünümleri + kamera (VisionKit) yalnız iOS app target'ında (`LumiMobile/App/`); Xcode projesi `project.yml`'den XcodeGen ile üretilir (üretilen `.xcodeproj` gitignore'lu). Mac tarafındaki kalıbın aynası: I/O (URLSessionWebSocketTask, Keychain) ince katman, saf mantık birim testli.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + `@Observable` (Observation), XCTest, URLSessionWebSocketTask, VisionKit (QR), Keychain Services, XcodeGen.

**Bağlayıcı sözleşme:** `docs/spec/50-remote-protocol.md` (zarf, mesaj tablosu, snapshot/event payload şekilleri, komut aksiyonları). Tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` §4.3, §5, §7, §8, §9, §12.

**Karara bağlanan açık sorular** (handoff'taki öneriler benimsenmiştir):
- Minimum iOS: **17.0** (Observation/@Observable için)
- Proje yapısı: **XcodeGen ile üretilen normal Xcode projesi** + mantık SPM pakette (agent-dostu, tekrarlanabilir; kullanıcı yine Xcode'da açar)
- APNs: **Task 11, KAPILI** — ücretli Apple Developer hesabı hazır olana kadar atlanır; app açıkken canlı akış zaten çalışır (tasarım §8)
- Test: view-model/mantık için XCTest (`swift test`, Mac host); relay istemcisi için sahte `WebSocketConnection` enjeksiyonu; görünümler simülatör build'i + Task 10 uçtan uca doğrulama ile

## Global Constraints

- Zarf: `{"v":1,"type":"<tip>","payload":{...}}`; telefon YALNIZ `hello` / `command` / `register_push` / `ping` gönderir — relay bilinmeyen tipte bağlantıyı kapatır (4002)
- `hello` bağlantının ilk mesajı olmalı (5 sn içinde): `{role:"phone", token}`; token ≥ 16 karakter
- `welcome` (telefona): `{snapshot: object|null, macOnline: bool, lastSeenAt: number|null}` — `lastSeenAt` **epoch milisaniye** (relay `Date.now()`)
- `press_key` yalnız `"1"|"2"|"3"|"enter"|"esc"` gönderir; `command` payload'ı DÜZDÜR: `{commandId, action, sessionId?, text?/key?/repoPath?/personaId?/prompt?}`
- Oturum status kümesi: `idle|working|waiting-unseen|waiting-focused|waiting-seen|error`; telefon rozeti 4'e indirger (`waiting-*` → waiting); bilinmeyen status/itemType/mesaj tipi TOLERE edilir (atlanır ya da idle'a düşer) — tasarım §12.2
- Eşleştirme dizesi: `lumi-remote://pair?url=<pctEncoded>&token=<pctEncoded>` (Mac üretimi: `RemoteStore.pairingString`, `:` ve `/` de encode edilir); token iOS **Keychain**'e yazılır, UserDefaults'a ASLA
- Swift 6 strict concurrency; Combine YOK — istemci→model `AsyncStream`, model→UI `@Observable` (repo CLAUDE.md kalıbı)
- `LumiMobileKit` paketi iOS 17 + macOS 14 platformlarını destekler; UIKit/VisionKit importları YALNIZ `LumiMobile/App/` altında — yoksa Mac host'ta `swift test` kırılır
- Bundle id: `com.lumi.LumiMobile`; URL şeması: `lumi-remote`
- Test komutu: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test`; app build: `cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Mevcut Mac suite'i bozulmaz: Task 10 sonunda `cd /Users/balkan/Lumi/LumiPackages && swift test` (444 test) yeşil kalmalı (bu plan LumiPackages'a dokunmaz; kontrol güvence içindir)
- Commit'ler `feature/lumi-remote-ios` branch'ine, `mobile:` öneki ile; her commit mesajı şu trailer ile biter: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## File Structure

```
LumiMobile/
  project.yml                                        (Task 5: XcodeGen tanımı)
  LumiMobileKit/
    Package.swift                                    (Task 1)
    Sources/LumiMobileKit/
      Models.swift                                   (Task 1: SessionStatus, Badge, SessionSummary, Repo, Persona, Snapshot, Welcome, Question, FeedItem, RemoteEvent, CommandResult)
      PhoneProtocol.swift                            (Task 1: zarf codec + giden frame'ler + OutgoingCommand)
      Pairing.swift                                  (Task 2: PairingInfo, parse, SecureStore, InMemorySecureStore, KeychainStore)
      WebSocketTransport.swift                       (Task 3: WebSocketConnection protokolü + URLSession impl)
      RelayClient.swift                              (Task 3: actor — hello, yeniden bağlanma, event stream; ReconnectBackoff)
      AppModel.swift                                 (Task 4: @Observable view-model — snapshot/event/komut yaşam döngüsü)
    Tests/LumiMobileKitTests/
      ProtocolTests.swift                            (Task 1)
      PairingTests.swift                             (Task 2)
      RelayClientTests.swift                         (Task 3)
      AppModelTests.swift                            (Task 4)
  App/
    LumiMobileApp.swift                              (Task 5: @main + onOpenURL)
    RootView.swift                                   (Task 5: eşleşme yoksa PairingView, varsa NavigationStack)
    PairingView.swift                                (Task 5: manuel yapıştırma; Task 9: QR tarayıcı eklenir)
    SessionListView.swift                            (Task 6)
    SessionDetailView.swift                          (Task 7: akış + soru kartı + giriş çubuğu)
    NewSessionView.swift                             (Task 8)
    QRScannerView.swift                              (Task 9: VisionKit)
.gitignore                                           (Task 5: üretilen .xcodeproj + build/)
```

---

### Task 1: LumiMobileKit paketi + protokol modelleri + codec

**Files:**
- Create: `LumiMobile/LumiMobileKit/Package.swift`
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: — (ilk görev; sözleşme `docs/spec/50-remote-protocol.md`)
- Produces: `SessionStatus` (String enum, 6 durum + `badge: Badge`), `Badge {idle,working,waiting,error}`, `SessionSummary {id,repoPath,repoName,status,title?}`, `Repo {name,path}`, `Persona {id,label}`, `Snapshot {sessions,repos,personas}`, `Welcome {snapshot?,macOnline,lastSeenAt?}`, `Question {header,question,options}`, `FeedItem {assistantText(String), toolUse(tool:summary:), question([Question]), turnDone}`, `RemoteEvent {statusChange(sessionId:status:repoName:summary:), transcript(sessionId:item:)}`, `CommandResult {commandId,ok,error?}`, `ServerMessage {welcome,snapshot,event,commandResult,pong}`, `CommandAction {sendText,pressKey,startSession}`, `OutgoingCommand {commandId,action}`, `PhoneProtocol.decodeServerMessage(String) -> ServerMessage?`, `PhoneProtocol.helloFrame(token:)/commandFrame(_:)/registerPushFrame(deviceToken:)/pingFrame() -> String`

- [ ] **Step 1: Paket iskeletini oluştur**

`LumiMobile/LumiMobileKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiMobileKit",
    // macOS 14 desteği testlerin Mac host'ta simülatörsüz koşması içindir;
    // UIKit/VisionKit bağımlılığı bu pakete giremez.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumiMobileKit", targets: ["LumiMobileKit"])
    ],
    targets: [
        .target(name: "LumiMobileKit"),
        .testTarget(name: "LumiMobileKitTests", dependencies: ["LumiMobileKit"]),
    ]
)
```

- [ ] **Step 2: Başarısız testi yaz**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`:

```swift
import XCTest
@testable import LumiMobileKit

final class ProtocolTests: XCTestCase {

    // MARK: Gelen mesajlar

    func testDecodeWelcomeWithSnapshot() throws {
        let text = """
        {"v":1,"type":"welcome","payload":{"macOnline":true,"lastSeenAt":1753660000000,
         "snapshot":{"sessions":[{"id":"s1","repoPath":"/r/lumi","repoName":"lumi",
                                  "status":"waiting-unseen","title":"swift test"}],
                     "repos":[{"name":"lumi","path":"/r/lumi"}],
                     "personas":[{"id":"reviewer","label":"Reviewer"}]}}}
        """
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("welcome bekleniyordu")
        }
        XCTAssertTrue(welcome.macOnline)
        XCTAssertEqual(welcome.lastSeenAt, 1_753_660_000_000)
        let snapshot = try XCTUnwrap(welcome.snapshot)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].status, .waitingUnseen)
        XCTAssertEqual(snapshot.sessions[0].status.badge, .waiting)
        XCTAssertEqual(snapshot.sessions[0].title, "swift test")
        XCTAssertEqual(snapshot.repos, [Repo(name: "lumi", path: "/r/lumi")])
        XCTAssertEqual(snapshot.personas, [Persona(id: "reviewer", label: "Reviewer")])
    }

    func testDecodeWelcomeMacOffline() {
        let text = #"{"v":1,"type":"welcome","payload":{"snapshot":null,"macOnline":false,"lastSeenAt":null}}"#
        guard case .welcome(let welcome)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("welcome bekleniyordu")
        }
        XCTAssertFalse(welcome.macOnline)
        XCTAssertNil(welcome.snapshot)
        XCTAssertNil(welcome.lastSeenAt)
    }

    func testDecodeStandaloneSnapshot() {
        let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[],"repos":[],"personas":[]}}"#
        guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("snapshot bekleniyordu")
        }
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testDecodeStatusChangeEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"status_change","sessionId":"s1","status":"working","repoName":"lumi","summary":"derliyor"}}"#
        guard case .event(.statusChange(let id, let status, let repo, let summary))? =
                PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("status_change bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        XCTAssertEqual(status, .working)
        XCTAssertEqual(repo, "lumi")
        XCTAssertEqual(summary, "derliyor")
    }

    func testDecodeTranscriptVariants() {
        let cases: [(String, FeedItem)] = [
            (#"{"itemType":"assistant_text","text":"merhaba"}"#, .assistantText("merhaba")),
            (#"{"itemType":"tool_use","tool":"Bash","summary":"swift test"}"#,
             .toolUse(tool: "Bash", summary: "swift test")),
            (#"{"itemType":"question","questions":[{"header":"İzin","question":"Bash koşsun mu?","options":["Evet","Hayır"]}]}"#,
             .question([Question(header: "İzin", question: "Bash koşsun mu?", options: ["Evet", "Hayır"])])),
            (#"{"itemType":"turn_done"}"#, .turnDone),
        ]
        for (itemJson, expected) in cases {
            let text = #"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":"# + itemJson + "}}"
            guard case .event(.transcript(let id, let item))? = PhoneProtocol.decodeServerMessage(text) else {
                return XCTFail("transcript bekleniyordu: \(itemJson)")
            }
            XCTAssertEqual(id, "s1")
            XCTAssertEqual(item, expected)
        }
    }

    func testDecodeCommandResult() {
        let text = #"{"v":1,"type":"command_result","payload":{"commandId":"ph-1","ok":false,"error":"mac_offline"}}"#
        guard case .commandResult(let result)? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("command_result bekleniyordu")
        }
        XCTAssertEqual(result, CommandResult(commandId: "ph-1", ok: false, error: "mac_offline"))
    }

    // MARK: Tolerans (tasarım §12.2)

    func testUnknownStatusFallsBackToIdle() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"status_change","sessionId":"s1","status":"hibernating","repoName":"r"}}"#
        guard case .event(.statusChange(_, let status, _, _))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("status_change bekleniyordu")
        }
        XCTAssertEqual(status, .idle)
    }

    func testUnknownItemTypeAndMessageTypeAreSkipped() {
        XCTAssertNil(PhoneProtocol.decodeServerMessage(
            #"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":{"itemType":"hologram"}}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":1,"type":"teleport","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage(#"{"v":2,"type":"pong","payload":{}}"#))
        XCTAssertNil(PhoneProtocol.decodeServerMessage("bozuk json"))
    }

    // MARK: Giden mesajlar

    private func payload(of frame: String, expectedType: String) throws -> [String: Any] {
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(frame.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(dict["v"] as? Int, 1)
        XCTAssertEqual(dict["type"] as? String, expectedType)
        return try XCTUnwrap(dict["payload"] as? [String: Any])
    }

    func testHelloFrame() throws {
        let payload = try payload(of: PhoneProtocol.helloFrame(token: "0123456789abcdef"), expectedType: "hello")
        XCTAssertEqual(payload["role"] as? String, "phone")
        XCTAssertEqual(payload["token"] as? String, "0123456789abcdef")
    }

    func testCommandFrames() throws {
        let sendText = OutgoingCommand(commandId: "ph-1", action: .sendText(sessionId: "s1", text: "devam"))
        var payload = try self.payload(of: PhoneProtocol.commandFrame(sendText), expectedType: "command")
        XCTAssertEqual(payload["commandId"] as? String, "ph-1")
        XCTAssertEqual(payload["action"] as? String, "send_text")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["text"] as? String, "devam")

        let pressKey = OutgoingCommand(commandId: "ph-2", action: .pressKey(sessionId: "s1", key: "enter"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(pressKey), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "press_key")
        XCTAssertEqual(payload["key"] as? String, "enter")

        let start = OutgoingCommand(commandId: "ph-3",
                                    action: .startSession(repoPath: "/r/lumi", personaId: "reviewer", prompt: "testleri koş"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(start), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "start_session")
        XCTAssertEqual(payload["repoPath"] as? String, "/r/lumi")
        XCTAssertEqual(payload["personaId"] as? String, "reviewer")
        XCTAssertEqual(payload["prompt"] as? String, "testleri koş")

        let startNoPersona = OutgoingCommand(commandId: "ph-4",
                                             action: .startSession(repoPath: "/r/lumi", personaId: nil, prompt: "p"))
        payload = try self.payload(of: PhoneProtocol.commandFrame(startNoPersona), expectedType: "command")
        XCTAssertNil(payload["personaId"])
    }

    func testRegisterPushAndPingFrames() throws {
        let push = try payload(of: PhoneProtocol.registerPushFrame(deviceToken: "abc123"), expectedType: "register_push")
        XCTAssertEqual(push["deviceToken"] as? String, "abc123")
        let ping = try payload(of: PhoneProtocol.pingFrame(), expectedType: "ping")
        XCTAssertTrue(ping.isEmpty)
    }
}
```

- [ ] **Step 3: Testin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: derleme hatası — `PhoneProtocol` / model tipleri bulunamıyor.

- [ ] **Step 4: Modelleri yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`:

```swift
import Foundation

/// Mac'in yayınladığı oturum durumu (docs/spec/50-remote-protocol.md snapshot payload).
public enum SessionStatus: String, Sendable, Equatable {
    case idle, working, error
    case waitingUnseen = "waiting-unseen"
    case waitingFocused = "waiting-focused"
    case waitingSeen = "waiting-seen"

    /// Telefon rozeti 4 duruma indirger (tasarım §2).
    public var badge: Badge {
        switch self {
        case .idle: .idle
        case .working: .working
        case .error: .error
        case .waitingUnseen, .waitingFocused, .waitingSeen: .waiting
        }
    }
}

extension SessionStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Tolerans (tasarım §12.2): ileride eklenen durumlar akışı kırmasın.
        self = SessionStatus(rawValue: raw) ?? .idle
    }
}

public enum Badge: Sendable, Equatable { case idle, working, waiting, error }

public struct SessionSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let repoPath: String
    public let repoName: String
    public var status: SessionStatus
    public let title: String?

    public init(id: String, repoPath: String, repoName: String, status: SessionStatus, title: String? = nil) {
        self.id = id
        self.repoPath = repoPath
        self.repoName = repoName
        self.status = status
        self.title = title
    }
}

public struct Repo: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct Persona: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct Snapshot: Decodable, Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let repos: [Repo]
    public let personas: [Persona]

    public init(sessions: [SessionSummary], repos: [Repo], personas: [Persona]) {
        self.sessions = sessions
        self.repos = repos
        self.personas = personas
    }
}

/// Relay'in telefona ilk cevabı; `lastSeenAt` epoch milisaniye (relay `Date.now()`).
public struct Welcome: Decodable, Sendable, Equatable {
    public let snapshot: Snapshot?
    public let macOnline: Bool
    public let lastSeenAt: Double?

    public init(snapshot: Snapshot?, macOnline: Bool, lastSeenAt: Double?) {
        self.snapshot = snapshot
        self.macOnline = macOnline
        self.lastSeenAt = lastSeenAt
    }
}

public struct Question: Decodable, Sendable, Equatable {
    public let header: String
    public let question: String
    public let options: [String]

    public init(header: String, question: String, options: [String]) {
        self.header = header
        self.question = question
        self.options = options
    }
}

/// Transcript akış öğesi (protokol `event.item.itemType`).
public enum FeedItem: Sendable, Equatable {
    case assistantText(String)
    case toolUse(tool: String, summary: String)
    case question([Question])
    case turnDone
}

public enum RemoteEvent: Sendable, Equatable {
    case statusChange(sessionId: String, status: SessionStatus, repoName: String, summary: String?)
    case transcript(sessionId: String, item: FeedItem)
}

public struct CommandResult: Decodable, Sendable, Equatable {
    public let commandId: String
    public let ok: Bool
    public let error: String?

    public init(commandId: String, ok: Bool, error: String?) {
        self.commandId = commandId
        self.ok = ok
        self.error = error
    }
}
```

- [ ] **Step 5: Codec'i yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`:

```swift
import Foundation

/// Relay'den gelebilecek mesajlar (telefon rolü için).
public enum ServerMessage: Sendable, Equatable {
    case welcome(Welcome)
    case snapshot(Snapshot)
    case event(RemoteEvent)
    case commandResult(CommandResult)
    case pong
}

public enum CommandAction: Sendable, Equatable {
    case sendText(sessionId: String, text: String)
    case pressKey(sessionId: String, key: String)
    case startSession(repoPath: String, personaId: String?, prompt: String)
}

public struct OutgoingCommand: Sendable, Equatable {
    public let commandId: String
    public let action: CommandAction

    public init(commandId: String, action: CommandAction) {
        self.commandId = commandId
        self.action = action
    }
}

/// Zarf codec'i — docs/spec/50-remote-protocol.md ile birebir.
/// Gelen taraf toleranslıdır: bilinmeyen tip/kind/itemType nil döner, akış kırılmaz.
public enum PhoneProtocol {
    public static let version = 1

    // MARK: Gelen

    public static func decodeServerMessage(_ text: String) -> ServerMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["v"] as? Int == version,
              let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any] else { return nil }

        func decodePayload<T: Decodable>(_: T.Type) -> T? {
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return try? JSONDecoder().decode(T.self, from: payloadData)
        }

        switch type {
        case "welcome": return decodePayload(Welcome.self).map(ServerMessage.welcome)
        case "snapshot": return decodePayload(Snapshot.self).map(ServerMessage.snapshot)
        case "event": return decodeEvent(payload).map(ServerMessage.event)
        case "command_result": return decodePayload(CommandResult.self).map(ServerMessage.commandResult)
        case "pong": return .pong
        default: return nil
        }
    }

    static func decodeEvent(_ payload: [String: Any]) -> RemoteEvent? {
        guard let kind = payload["kind"] as? String,
              let sessionId = payload["sessionId"] as? String else { return nil }
        switch kind {
        case "status_change":
            guard let rawStatus = payload["status"] as? String else { return nil }
            return .statusChange(
                sessionId: sessionId,
                status: SessionStatus(rawValue: rawStatus) ?? .idle,
                repoName: payload["repoName"] as? String ?? "",
                summary: payload["summary"] as? String
            )
        case "transcript":
            guard let item = payload["item"] as? [String: Any],
                  let feedItem = decodeFeedItem(item) else { return nil }
            return .transcript(sessionId: sessionId, item: feedItem)
        default:
            return nil
        }
    }

    static func decodeFeedItem(_ item: [String: Any]) -> FeedItem? {
        switch item["itemType"] as? String {
        case "assistant_text":
            guard let text = item["text"] as? String else { return nil }
            return .assistantText(text)
        case "tool_use":
            guard let tool = item["tool"] as? String else { return nil }
            return .toolUse(tool: tool, summary: item["summary"] as? String ?? "")
        case "question":
            guard let raw = item["questions"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let questions = try? JSONDecoder().decode([Question].self, from: data) else { return nil }
            return .question(questions)
        case "turn_done":
            return .turnDone
        default:
            return nil
        }
    }

    // MARK: Giden

    public static func helloFrame(token: String) -> String {
        frame(type: "hello", payload: ["role": "phone", "token": token])
    }

    public static func pingFrame() -> String {
        frame(type: "ping", payload: [:])
    }

    public static func registerPushFrame(deviceToken: String) -> String {
        frame(type: "register_push", payload: ["deviceToken": deviceToken])
    }

    public static func commandFrame(_ command: OutgoingCommand) -> String {
        var payload: [String: Any] = ["commandId": command.commandId]
        switch command.action {
        case .sendText(let sessionId, let text):
            payload["action"] = "send_text"
            payload["sessionId"] = sessionId
            payload["text"] = text
        case .pressKey(let sessionId, let key):
            payload["action"] = "press_key"
            payload["sessionId"] = sessionId
            payload["key"] = key
        case .startSession(let repoPath, let personaId, let prompt):
            payload["action"] = "start_session"
            payload["repoPath"] = repoPath
            payload["prompt"] = prompt
            if let personaId { payload["personaId"] = personaId }
        }
        return frame(type: "command", payload: payload)
    }

    private static func frame(type: String, payload: [String: Any]) -> String {
        let dict: [String: Any] = ["v": version, "type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
```

- [ ] **Step 6: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: PASS (ProtocolTests'in tamamı), 0 warning.

- [ ] **Step 7: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/LumiMobileKit
git commit -m "mobile: LumiMobileKit paketi — protokol modelleri + zarf codec'i" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Eşleştirme — pairing URL parse + SecureStore/Keychain

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Pairing.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PairingTests.swift`

**Interfaces:**
- Consumes: — (bağımsız)
- Produces: `PairingInfo {relayUrl: String, token: String}`, `Pairing.parse(_ string: String) -> PairingInfo?`, `SecureStore` protokolü (`read() -> PairingInfo?`, `write(_:)`, `clear()`), `InMemorySecureStore` (test), `KeychainStore` (üretim)

- [ ] **Step 1: Başarısız testi yaz**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PairingTests.swift`:

```swift
import XCTest
@testable import LumiMobileKit

final class PairingTests: XCTestCase {

    // Mac tarafı üretimi (RemoteStore.pairingString): ':' ve '/' de encode edilir.
    func testParseMacGeneratedPairingString() {
        let string = "lumi-remote://pair?url=wss%3A%2F%2Flumi-relay-production.up.railway.app&token=abcDEF123-_456789xyzABCDEF0123456789abcdefg"
        let info = Pairing.parse(string)
        XCTAssertEqual(info, PairingInfo(
            relayUrl: "wss://lumi-relay-production.up.railway.app",
            token: "abcDEF123-_456789xyzABCDEF0123456789abcdefg"
        ))
    }

    func testParseTrimsWhitespace() {
        let string = "  lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=0123456789abcdef\n"
        XCTAssertEqual(Pairing.parse(string)?.relayUrl, "wss://r.example")
    }

    func testParseRejectsInvalidInputs() {
        // yanlış şema / host
        XCTAssertNil(Pairing.parse("https://pair?url=wss%3A%2F%2Fr&token=0123456789abcdef"))
        XCTAssertNil(Pairing.parse("lumi-remote://settings?url=wss%3A%2F%2Fr&token=0123456789abcdef"))
        // eksik parametre
        XCTAssertNil(Pairing.parse("lumi-remote://pair?token=0123456789abcdef"))
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=wss%3A%2F%2Fr.example"))
        // kısa token (protokol: ≥16)
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=kisa"))
        // ws(s) olmayan relay url'i
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=https%3A%2F%2Fr.example&token=0123456789abcdef"))
        // düz metin
        XCTAssertNil(Pairing.parse("hic url degil"))
    }

    func testInMemoryStoreRoundTrip() {
        let store = InMemorySecureStore()
        XCTAssertNil(store.read())
        let info = PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")
        store.write(info)
        XCTAssertEqual(store.read(), info)
        store.clear()
        XCTAssertNil(store.read())
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: derleme hatası — `Pairing` bulunamıyor.

- [ ] **Step 3: Implementasyonu yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Pairing.swift`:

```swift
import Foundation
import Security

public struct PairingInfo: Sendable, Equatable {
    public let relayUrl: String
    public let token: String

    public init(relayUrl: String, token: String) {
        self.relayUrl = relayUrl
        self.token = token
    }
}

public enum Pairing {
    /// `lumi-remote://pair?url=<pct>&token=<pct>` → PairingInfo.
    /// URLComponents query değerlerini kendisi percent-decode eder.
    public static func parse(_ string: String) -> PairingInfo? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "lumi-remote",
              components.host == "pair",
              let items = components.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              token.count >= 16,
              url.hasPrefix("wss://") || url.hasPrefix("ws://")
        else { return nil }
        return PairingInfo(relayUrl: url, token: token)
    }
}

/// Eşleştirme bilgisinin güvenli saklanması. Üretimde Keychain; testte in-memory.
public protocol SecureStore: Sendable {
    func read() -> PairingInfo?
    func write(_ info: PairingInfo)
    func clear()
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PairingInfo?

    public init() {}

    public func read() -> PairingInfo? { lock.withLock { stored } }
    public func write(_ info: PairingInfo) { lock.withLock { stored = info } }
    public func clear() { lock.withLock { stored = nil } }
}

/// kSecClassGenericPassword altında tek kayıt (tasarım §7: token Keychain'de).
/// İnce I/O katmanı — birim testi yok, Task 10 uçtan uca doğrulamasıyla kapsanır.
public final class KeychainStore: SecureStore {
    private let service = "com.lumi.LumiMobile.pairing"
    private let account = "default"

    public init() {}

    public func read() -> PairingInfo? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let url = dict["relayUrl"], let token = dict["token"]
        else { return nil }
        return PairingInfo(relayUrl: url, token: token)
    }

    public func write(_ info: PairingInfo) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["relayUrl": info.relayUrl, "token": info.token]
        ) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: PASS (Protocol + Pairing testleri), 0 warning.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/LumiMobileKit
git commit -m "mobile: eşleştirme — pairing URL parse + SecureStore/Keychain" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: WebSocketTransport + RelayClient (yeniden bağlanan ws istemcisi)

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/WebSocketTransport.swift`
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/RelayClient.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/RelayClientTests.swift`

**Interfaces:**
- Consumes: `PhoneProtocol` (Task 1), `PairingInfo` (Task 2)
- Produces: `WebSocketConnection` protokolü (`incoming: AsyncThrowingStream<String, Error>`, `send(_ text: String) async throws`, `close()`), `ConnectionFactory = @Sendable (URL) -> any WebSocketConnection`, `URLSessionWebSocketConnection`, `ConnectionState {disconnected, connecting, connected}`, `ClientEvent {stateChanged(ConnectionState), message(ServerMessage)}`, `RelayClienting` protokolü (`events() async -> AsyncStream<ClientEvent>`, `start(pairing:) async`, `stop() async`, `send(command:) async`, `registerPush(deviceToken:) async`), `actor RelayClient: RelayClienting`, `ReconnectBackoff` (1,2,4,…60 sn)

- [ ] **Step 1: Başarısız testi yaz**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/RelayClientTests.swift`:

```swift
import XCTest
@testable import LumiMobileKit

/// Kontrol edilebilir sahte bağlantı: gelen frame'ler dışarıdan itilir, gidenler kaydedilir.
final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<String, Error>
    private let feed: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var sentFrames: [String] = []

    var sent: [String] { lock.withLock { sentFrames } }

    init() {
        (incoming, feed) = AsyncThrowingStream.makeStream()
    }

    func push(_ text: String) { feed.yield(text) }
    func dropConnection() { feed.finish(throwing: URLError(.networkConnectionLost)) }
    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }
    func close() { feed.finish() }
}

/// Bağlantı fabrikası + backoff uykularını kaydeden test tezgahı.
final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [FakeConnection] = []
    private var _sleeps: [Double] = []

    var connections: [FakeConnection] { lock.withLock { _connections } }
    var sleeps: [Double] { lock.withLock { _sleeps } }

    func makeClient() -> RelayClient {
        RelayClient(
            connect: { [self] _ in
                let conn = FakeConnection()
                lock.withLock { _connections.append(conn) }
                return conn
            },
            sleep: { [self] seconds in
                lock.withLock { _sleeps.append(seconds) }
                await Task.yield()
            }
        )
    }
}

private let pairing = PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")
private let welcomeFrame = #"{"v":1,"type":"welcome","payload":{"snapshot":null,"macOnline":true,"lastSeenAt":null}}"#

/// `condition` doğru olana dek bekler (en çok ~2 sn).
func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

final class RelayClientTests: XCTestCase {

    func testSendsHelloFirstAndBecomesConnectedOnWelcome() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        let helloSent = await waitUntil { (harness.connections.first?.sent.count ?? 0) >= 1 }
        XCTAssertTrue(helloSent)
        let hello = harness.connections[0].sent[0]
        XCTAssertTrue(hello.contains(#""type":"hello""#) || hello.contains(#""type": "hello""#))
        XCTAssertTrue(hello.contains("0123456789abcdef"))

        harness.connections[0].push(welcomeFrame)
        let connected = await waitUntil { await client.state == .connected }
        XCTAssertTrue(connected)
        await client.stop()
    }

    func testDeliversDecodedMessagesToEventStream() async {
        let harness = Harness()
        let client = harness.makeClient()
        let stream = await client.events()

        let collector = Task { () -> [ClientEvent] in
            var events: [ClientEvent] = []
            for await event in stream {
                events.append(event)
                if case .message(.event(.transcript)) = event { break }
            }
            return events
        }

        await client.start(pairing: pairing)
        _ = await waitUntil { !harness.connections.isEmpty }
        harness.connections[0].push(welcomeFrame)
        harness.connections[0].push(#"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":{"itemType":"turn_done"}}}"#)

        let events = await collector.value
        XCTAssertTrue(events.contains(.message(.event(.transcript(sessionId: "s1", item: .turnDone)))))
        XCTAssertTrue(events.contains(.stateChanged(.connected)))
        await client.stop()
    }

    func testReconnectsWithExponentialBackoff() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        _ = await waitUntil { harness.connections.count >= 1 }
        harness.connections[0].dropConnection()
        _ = await waitUntil { harness.connections.count >= 2 }
        harness.connections[1].dropConnection()
        let thirdConnection = await waitUntil { harness.connections.count >= 3 }

        XCTAssertTrue(thirdConnection, "kopan bağlantı yeniden denenmedi")
        XCTAssertEqual(Array(harness.sleeps.prefix(2)), [1, 2])
        await client.stop()
    }

    func testWelcomeResetsBackoff() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        _ = await waitUntil { harness.connections.count >= 1 }
        harness.connections[0].dropConnection()                 // → 1 sn
        _ = await waitUntil { harness.connections.count >= 2 }
        harness.connections[1].push(welcomeFrame)               // backoff sıfırlanır
        _ = await waitUntil { await client.state == .connected }
        harness.connections[1].dropConnection()                 // → yine 1 sn
        _ = await waitUntil { harness.connections.count >= 3 }

        XCTAssertEqual(Array(harness.sleeps.prefix(2)), [1, 1])
        await client.stop()
    }

    func testStopClosesAndStopsReconnecting() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)
        _ = await waitUntil { harness.connections.count >= 1 }

        await client.stop()
        harness.connections[0].dropConnection()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.connections.count, 1, "stop sonrası yeniden bağlanmamalı")
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testSendCommandWritesFrame() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)
        _ = await waitUntil { !harness.connections.isEmpty }
        harness.connections[0].push(welcomeFrame)
        _ = await waitUntil { await client.state == .connected }

        await client.send(command: OutgoingCommand(commandId: "ph-1", action: .pressKey(sessionId: "s1", key: "enter")))

        let sent = await waitUntil { harness.connections[0].sent.count >= 2 }
        XCTAssertTrue(sent)
        XCTAssertTrue(harness.connections[0].sent[1].contains("press_key"))
        await client.stop()
    }

    func testBackoffSequence() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual([backoff.nextDelay(), backoff.nextDelay(), backoff.nextDelay(), backoff.nextDelay()],
                       [1, 2, 4, 8])
        for _ in 0..<10 { _ = backoff.nextDelay() }
        XCTAssertEqual(backoff.nextDelay(), 60)
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: derleme hatası — `WebSocketConnection` / `RelayClient` bulunamıyor.

- [ ] **Step 3: Transport'u yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/WebSocketTransport.swift`:

```swift
import Foundation

/// Tek bir ws bağlantısının soyutlaması. `incoming` bağlantı kopunca biter
/// (hata ile ya da normal); RelayClient bunu yeniden bağlanma sinyali sayar.
public protocol WebSocketConnection: Sendable {
    var incoming: AsyncThrowingStream<String, Error> { get }
    func send(_ text: String) async throws
    func close()
}

public typealias ConnectionFactory = @Sendable (URL) -> any WebSocketConnection

/// URLSessionWebSocketTask sarmalayıcısı — ince I/O katmanı, birim testi yok
/// (Task 10 uçtan uca doğrulamasıyla kapsanır).
/// @unchecked Sendable: task'e yalnız init'te atanır; URLSessionWebSocketTask
/// thread-safe API sunar.
public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    public let incoming: AsyncThrowingStream<String, Error>

    public init(url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        self.incoming = AsyncThrowingStream { continuation in
            @Sendable func receiveNext() {
                task.receive { result in
                    switch result {
                    case .success(.string(let text)):
                        continuation.yield(text)
                        receiveNext()
                    case .success:
                        receiveNext() // binary frame beklenmez; atla
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                }
            }
            receiveNext()
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
```

- [ ] **Step 4: RelayClient'ı yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/RelayClient.swift`:

```swift
import Foundation

public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected
}

public enum ClientEvent: Sendable, Equatable {
    case stateChanged(ConnectionState)
    case message(ServerMessage)
}

/// 1,2,4,8,…60 sn üstel geri çekilme (Mac tarafındaki ReconnectBackoff'un aynısı).
public struct ReconnectBackoff: Sendable {
    private var attempt = 0
    private let capSeconds: Double = 60

    public init() {}

    public mutating func nextDelay() -> Double {
        let delay = min(pow(2, Double(attempt)), capSeconds)
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}

/// AppModel'in gördüğü sınır — testlerde FakeRelayClient bunu implemente eder.
public protocol RelayClienting: Sendable {
    func events() async -> AsyncStream<ClientEvent>
    func start(pairing: PairingInfo) async
    func stop() async
    func send(command: OutgoingCommand) async
    func registerPush(deviceToken: String) async
}

/// Relay'e telefon rolüyle bağlanan istemci: hello → welcome → mesaj akışı;
/// kopunca üstel backoff ile yeniden bağlanır (tasarım §9).
public actor RelayClient: RelayClienting {
    public private(set) var state: ConnectionState = .disconnected

    private let connect: ConnectionFactory
    private let sleep: @Sendable (Double) async -> Void
    private var backoff = ReconnectBackoff()
    private var connection: (any WebSocketConnection)?
    private var runTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]

    public init(
        connect: @escaping ConnectionFactory = { URLSessionWebSocketConnection(url: $0) },
        sleep: @escaping @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.connect = connect
        self.sleep = sleep
    }

    public func events() -> AsyncStream<ClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start(pairing: PairingInfo) {
        guard runTask == nil, let url = URL(string: pairing.relayUrl) else { return }
        let token = pairing.token
        runTask = Task { await run(url: url, token: token) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        connection?.close()
        connection = nil
        backoff.reset()
        setState(.disconnected)
    }

    public func send(command: OutgoingCommand) {
        sendFrame(PhoneProtocol.commandFrame(command))
    }

    public func registerPush(deviceToken: String) {
        sendFrame(PhoneProtocol.registerPushFrame(deviceToken: deviceToken))
    }

    // MARK: İç işleyiş

    private func run(url: URL, token: String) async {
        while !Task.isCancelled {
            setState(.connecting)
            let conn = connect(url)
            connection = conn
            do {
                try await conn.send(PhoneProtocol.helloFrame(token: token))
                for try await frame in conn.incoming {
                    guard let message = PhoneProtocol.decodeServerMessage(frame) else { continue }
                    if case .welcome = message {
                        backoff.reset()
                        setState(.connected)
                    }
                    yield(.message(message))
                }
            } catch {
                // kopma → aşağıda backoff ile yeniden dene
            }
            connection = nil
            if Task.isCancelled { return }
            setState(.disconnected)
            await sleep(backoff.nextDelay())
        }
    }

    private func sendFrame(_ frame: String) {
        guard let connection else { return }
        Task { try? await connection.send(frame) }
    }

    private func setState(_ newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        yield(.stateChanged(newState))
    }

    private func yield(_ event: ClientEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
```

- [ ] **Step 5: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: PASS (tüm testler), 0 warning. Zamanlamaya bağlı test kırılganlığı görürsen `waitUntil` döngü sayısını artırmak yerine olayın kendisini bekleyecek şekilde testi düzelt.

- [ ] **Step 6: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/LumiMobileKit
git commit -m "mobile: RelayClient — hello/welcome, mesaj akışı, üstel backoff ile yeniden bağlanma" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: AppModel — @Observable view-model (snapshot/event/komut yaşam döngüsü)

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `RelayClienting`, `ClientEvent`, `ConnectionState` (Task 3); `SecureStore`, `PairingInfo`, `Pairing.parse` (Task 2); modeller + `ServerMessage`, `OutgoingCommand` (Task 1)
- Produces: `@Observable @MainActor final class AppModel` —
  `init(client: any RelayClienting, store: any SecureStore)`,
  durum: `isPaired: Bool`, `connection: ConnectionState`, `macOnline: Bool`, `lastSeenAt: Date?`, `sessions: [SessionSummary]`, `repos: [Repo]`, `personas: [Persona]`, `feeds: [String: [FeedEntry]]`, `lastCommandError: [String: String]`, `startState: StartSessionState`,
  türetilmiş: `orderedSessions: [SessionSummary]`, `session(_ id: String) -> SessionSummary?`, `questionCard(for: String) -> QuestionCard?`,
  eylemler: `start() async`, `pair(from: String) async -> Bool`, `unpair() async`, `sendText(sessionId:text:) async`, `pressKey(sessionId:key:) async`, `startSession(repoPath:personaId:prompt:) async`, `resetStartState()`, `registerPush(deviceToken:) async`,
  test kancası: `handle(_ message: ServerMessage)`,
  yardımcı tipler: `FeedEntry {id: Int, item: FeedItem}`, `QuestionCard {questions: [Question]?, context: String?}` (questions nil → jenerik kart), `StartSessionState {idle, sending, failed(String), succeeded}`

- [ ] **Step 1: Başarısız testi yaz**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`:

```swift
import XCTest
@testable import LumiMobileKit

final class FakeRelayClient: RelayClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [OutgoingCommand] = []
    private var _started: [PairingInfo] = []
    private var _stopCount = 0
    let stream: AsyncStream<ClientEvent>
    let continuation: AsyncStream<ClientEvent>.Continuation

    var commands: [OutgoingCommand] { lock.withLock { _commands } }
    var started: [PairingInfo] { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func events() async -> AsyncStream<ClientEvent> { stream }
    func start(pairing: PairingInfo) async { lock.withLock { _started.append(pairing) } }
    func stop() async { lock.withLock { _stopCount += 1 } }
    func send(command: OutgoingCommand) async { lock.withLock { _commands.append(command) } }
    func registerPush(deviceToken: String) async {}
}

@MainActor
private func makeModel(paired: Bool = true) -> (AppModel, FakeRelayClient, InMemorySecureStore) {
    let client = FakeRelayClient()
    let store = InMemorySecureStore()
    if paired {
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
    }
    return (AppModel(client: client, store: store), client, store)
}

private func session(_ id: String, repo: String, _ status: SessionStatus) -> SessionSummary {
    SessionSummary(id: id, repoPath: "/r/\(repo)", repoName: repo, status: status)
}

@MainActor
final class AppModelTests: XCTestCase {

    func testWelcomeAppliesSnapshotAndOfflineInfo() {
        let (model, _, _) = makeModel()
        let snapshot = Snapshot(sessions: [session("s1", repo: "lumi", .working)],
                                repos: [Repo(name: "lumi", path: "/r/lumi")],
                                personas: [Persona(id: "p", label: "P")])
        model.handle(.welcome(Welcome(snapshot: snapshot, macOnline: false, lastSeenAt: 1_753_660_000_000)))

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.personas.count, 1)
        XCTAssertFalse(model.macOnline)
        // epoch ms → Date
        XCTAssertEqual(model.lastSeenAt, Date(timeIntervalSince1970: 1_753_660_000))
    }

    func testOrderedSessionsPutWaitingFirstThenErrorWorkingIdle() {
        let (model, _, _) = makeModel()
        let snapshot = Snapshot(sessions: [
            session("a", repo: "alpha", .idle),
            session("b", repo: "beta", .working),
            session("c", repo: "gamma", .waitingUnseen),
            session("d", repo: "delta", .error),
            session("e", repo: "epsilon", .waitingSeen),
        ], repos: [], personas: [])
        model.handle(.snapshot(snapshot))

        // waiting (epsilon, gamma — grup içi repoName alfabetik) → error (delta) → working (beta) → idle (alpha)
        XCTAssertEqual(model.orderedSessions.map(\.repoName), ["epsilon", "gamma", "delta", "beta", "alpha"])
    }

    func testStatusChangeUpdatesSessionAndClearsQuestionWhenWorking() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .question([Question(header: "İzin", question: "Olur mu?", options: ["Evet"])]))))
        XCTAssertNotNil(model.questionCard(for: "s1")?.questions)

        model.handle(.event(.statusChange(sessionId: "s1", status: .working, repoName: "lumi", summary: nil)))
        XCTAssertEqual(model.session("s1")?.status, .working)
        XCTAssertNil(model.questionCard(for: "s1"))
        XCTAssertTrue(model.macOnline, "mac'ten event geldiyse mac online'dır")
    }

    func testTranscriptFeedAppendsAndCapsAt200() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        for i in 0..<210 {
            model.handle(.event(.transcript(sessionId: "s1", item: .assistantText("m\(i)"))))
        }
        let feed = model.feeds["s1"] ?? []
        XCTAssertEqual(feed.count, 200)
        XCTAssertEqual(feed.last?.item, .assistantText("m209"))
        XCTAssertEqual(feed.first?.item, .assistantText("m10"))
        // id'ler monoton artar (ScrollView diff'i için kararlı kimlik)
        XCTAssertEqual(feed.map(\.id), Array(feed.map(\.id)).sorted())
    }

    func testQuestionPinsCardAndTurnDoneClearsIt() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        let questions = [Question(header: "İzin", question: "Bash koşsun mu?", options: ["Evet", "Hayır"])]
        model.handle(.event(.transcript(sessionId: "s1", item: .question(questions))))

        XCTAssertEqual(model.questionCard(for: "s1"), QuestionCard(questions: questions, context: nil))
        // question akışa girmez, kartta yaşar (tasarım §5)
        XCTAssertTrue((model.feeds["s1"] ?? []).isEmpty)

        model.handle(.event(.transcript(sessionId: "s1", item: .turnDone)))
        XCTAssertNil(model.questionCard(for: "s1")?.questions)
    }

    func testGenericCardWhenWaitingWithoutQuestionText() {
        // tasarım §12.3: soru metni yoksa jenerik kart + son tool_use bağlamı
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .toolUse(tool: "Bash", summary: "swift test"))))
        model.handle(.event(.statusChange(sessionId: "s1", status: .waitingUnseen, repoName: "lumi", summary: nil)))

        let card = model.questionCard(for: "s1")
        XCTAssertNotNil(card)
        XCTAssertNil(card?.questions)
        XCTAssertEqual(card?.context, "Bash: swift test")
    }

    func testSendTextRecordsCommandAndClearsQuestion() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .question([Question(header: "h", question: "q", options: [])]))))

        await model.sendText(sessionId: "s1", text: "evet devam")

        XCTAssertEqual(client.commands.count, 1)
        guard case .sendText(let sid, let text) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(text, "evet devam")
        XCTAssertNil(model.questionCard(for: "s1")?.questions, "cevap verilince kart kalkar")
    }

    func testFailedCommandResultSurfacesErrorForSession() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.pressKey(sessionId: "s1", key: "enter")
        let commandId = client.commands[0].commandId

        model.handle(.commandResult(CommandResult(commandId: commandId, ok: false, error: "terminal kapandı")))
        XCTAssertEqual(model.lastCommandError["s1"], "terminal kapandı")

        // sonraki komut hatayı temizler
        await model.pressKey(sessionId: "s1", key: "1")
        XCTAssertNil(model.lastCommandError["s1"])

        // bilinmeyen commandId (başka telefonun komutu) yok sayılır
        model.handle(.commandResult(CommandResult(commandId: "baska-tel-9", ok: false, error: "x")))
        XCTAssertNil(model.lastCommandError["s1"])
    }

    func testStartSessionLifecycle() async {
        let (model, client, _) = makeModel()
        XCTAssertEqual(model.startState, .idle)

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "merhaba")
        XCTAssertEqual(model.startState, .sending)
        guard case .startSession(let repoPath, let personaId, let prompt) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(repoPath, "/r/lumi")
        XCTAssertNil(personaId)
        XCTAssertEqual(prompt, "merhaba")

        model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: true, error: nil)))
        XCTAssertEqual(model.startState, .succeeded)

        model.resetStartState()
        XCTAssertEqual(model.startState, .idle)

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "p")
        model.handle(.commandResult(CommandResult(commandId: client.commands[1].commandId, ok: false, error: "mac_offline")))
        XCTAssertEqual(model.startState, .failed("mac_offline"))
    }

    func testPairStartsClientAndUnpairStops() async {
        let (model, client, store) = makeModel(paired: false)
        XCTAssertFalse(model.isPaired)

        let bad = await model.pair(from: "gecersiz")
        XCTAssertFalse(bad)

        let ok = await model.pair(from: "lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=0123456789abcdef")
        XCTAssertTrue(ok)
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(store.read()?.token, "0123456789abcdef")
        XCTAssertEqual(client.started.map(\.relayUrl), ["wss://r.example"])

        await model.unpair()
        XCTAssertFalse(model.isPaired)
        XCTAssertNil(store.read())
        XCTAssertGreaterThanOrEqual(client.stopCount, 1)
    }

    func testStartConsumesClientEventStream() async {
        let (model, client, _) = makeModel()
        await model.start()
        XCTAssertEqual(client.started.count, 1, "eşleşme varsa start client'ı başlatır")

        client.continuation.yield(.stateChanged(.connected))
        client.continuation.yield(.message(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: []))))

        // Test @MainActor'da koşar; sleep aktörü bıraktığı için consumeTask ilerler.
        for _ in 0..<200 where !(model.sessions.count == 1 && model.connection == .connected) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.connection, .connected)
    }
}
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: derleme hatası — `AppModel` bulunamıyor.

- [ ] **Step 3: Implementasyonu yaz**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`:

```swift
import Foundation
import Observation

/// Akışta gösterilen tek öğe; `id` monoton artar (ScrollView kimliği için).
public struct FeedEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let item: FeedItem
}

/// Oturum detayında sabitlenen cevap kartı.
/// `questions == nil` → jenerik kart (tasarım §12.3): "izin bekliyor" + son tool_use bağlamı.
public struct QuestionCard: Sendable, Equatable {
    public let questions: [Question]?
    public let context: String?

    public init(questions: [Question]?, context: String?) {
        self.questions = questions
        self.context = context
    }
}

public enum StartSessionState: Sendable, Equatable {
    case idle, sending, succeeded
    case failed(String)
}

/// Tek view-model: RelayClient olaylarını UI durumuna indirger, komutları yollar.
/// istemci→model AsyncStream, model→UI @Observable (repo kalıbı; Combine yok).
@Observable @MainActor
public final class AppModel {
    public private(set) var isPaired: Bool
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var macOnline = false
    public private(set) var lastSeenAt: Date?
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var repos: [Repo] = []
    public private(set) var personas: [Persona] = []
    public private(set) var feeds: [String: [FeedEntry]] = [:]
    public private(set) var lastCommandError: [String: String] = [:]
    public private(set) var startState: StartSessionState = .idle

    private let client: any RelayClienting
    private let store: any SecureStore
    private var consumeTask: Task<Void, Never>?
    private var commandCounter = 0
    private var feedCounter = 0
    private var activeQuestions: [String: [Question]] = [:]
    /// commandId → sessionId; start_session için "" (oturum henüz yok).
    private var commandTargets: [String: String] = [:]
    private static let feedCap = 200

    public init(client: any RelayClienting, store: any SecureStore) {
        self.client = client
        self.store = store
        self.isPaired = store.read() != nil
    }

    // MARK: Yaşam döngüsü

    public func start() async {
        guard consumeTask == nil, let pairing = store.read() else { return }
        let stream = await client.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let state): self.connection = state
                case .message(let message): self.handle(message)
                }
            }
        }
        await client.start(pairing: pairing)
    }

    @discardableResult
    public func pair(from string: String) async -> Bool {
        guard let info = Pairing.parse(string) else { return false }
        store.write(info)
        isPaired = true
        await client.stop()
        consumeTask?.cancel()
        consumeTask = nil
        await start()
        return true
    }

    public func unpair() async {
        store.clear()
        isPaired = false
        consumeTask?.cancel()
        consumeTask = nil
        await client.stop()
        connection = .disconnected
        macOnline = false
        sessions = []
        feeds = [:]
        activeQuestions = [:]
    }

    // MARK: Gelen mesajlar

    public func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let welcome):
            macOnline = welcome.macOnline
            lastSeenAt = welcome.lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if let snapshot = welcome.snapshot { apply(snapshot) }

        case .snapshot(let snapshot):
            // snapshot'ı yalnız Mac gönderebilir → Mac online.
            macOnline = true
            apply(snapshot)

        case .event(.statusChange(let sessionId, let status, _, _)):
            macOnline = true
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].status = status
            }
            // Soru cevaplanmış / tur ilerlemiş demektir.
            if status.badge == .working || status.badge == .idle {
                activeQuestions[sessionId] = nil
            }

        case .event(.transcript(let sessionId, let item)):
            macOnline = true
            switch item {
            case .question(let questions):
                activeQuestions[sessionId] = questions
            case .turnDone:
                activeQuestions[sessionId] = nil
                appendFeed(sessionId, item)
            case .assistantText, .toolUse:
                appendFeed(sessionId, item)
            }

        case .commandResult(let result):
            guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
            if target.isEmpty {
                startState = result.ok ? .succeeded : .failed(result.error ?? "oturum açılamadı")
            } else if !result.ok {
                lastCommandError[target] = result.error ?? "komut iletilemedi"
            }

        case .pong:
            break
        }
    }

    // MARK: Türetilmiş durum

    /// `waiting` üstte (tasarım §4.3), sonra error/working/idle; grup içi repo adına göre.
    public var orderedSessions: [SessionSummary] {
        func priority(_ badge: Badge) -> Int {
            switch badge {
            case .waiting: 0
            case .error: 1
            case .working: 2
            case .idle: 3
            }
        }
        return sessions.sorted { a, b in
            let pa = priority(a.status.badge), pb = priority(b.status.badge)
            if pa != pb { return pa < pb }
            return a.repoName.localizedCaseInsensitiveCompare(b.repoName) == .orderedAscending
        }
    }

    public func session(_ id: String) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    public func questionCard(for sessionId: String) -> QuestionCard? {
        if let questions = activeQuestions[sessionId] {
            return QuestionCard(questions: questions, context: nil)
        }
        guard session(sessionId)?.status.badge == .waiting else { return nil }
        let context = (feeds[sessionId] ?? []).reversed().compactMap { entry -> String? in
            if case .toolUse(let tool, let summary) = entry.item { return "\(tool): \(summary)" }
            return nil
        }.first
        return QuestionCard(questions: nil, context: context)
    }

    // MARK: Komutlar

    public func sendText(sessionId: String, text: String) async {
        await dispatch(target: sessionId, action: .sendText(sessionId: sessionId, text: text))
    }

    public func pressKey(sessionId: String, key: String) async {
        await dispatch(target: sessionId, action: .pressKey(sessionId: sessionId, key: key))
    }

    public func startSession(repoPath: String, personaId: String?, prompt: String) async {
        startState = .sending
        await dispatch(target: "", action: .startSession(repoPath: repoPath, personaId: personaId, prompt: prompt))
    }

    public func resetStartState() {
        startState = .idle
    }

    public func registerPush(deviceToken: String) async {
        await client.registerPush(deviceToken: deviceToken)
    }

    // MARK: Yardımcılar

    private func dispatch(target: String, action: CommandAction) async {
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        commandTargets[commandId] = target
        if !target.isEmpty {
            lastCommandError[target] = nil
            activeQuestions[target] = nil // cevap verildi → kart kalkar
        }
        await client.send(command: OutgoingCommand(commandId: commandId, action: action))
    }

    private func apply(_ snapshot: Snapshot) {
        sessions = snapshot.sessions
        repos = snapshot.repos
        personas = snapshot.personas
        let liveIds = Set(snapshot.sessions.map(\.id))
        feeds = feeds.filter { liveIds.contains($0.key) }
        activeQuestions = activeQuestions.filter { liveIds.contains($0.key) }
        lastCommandError = lastCommandError.filter { liveIds.contains($0.key) }
    }

    private func appendFeed(_ sessionId: String, _ item: FeedItem) {
        feedCounter += 1
        var feed = feeds[sessionId] ?? []
        feed.append(FeedEntry(id: feedCounter, item: item))
        if feed.count > Self.feedCap {
            feed.removeFirst(feed.count - Self.feedCap)
        }
        feeds[sessionId] = feed
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: PASS (tüm paket testleri), 0 warning.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/LumiMobileKit
git commit -m "mobile: AppModel — snapshot/event indirgeme, soru kartı, komut yaşam döngüsü" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Xcode app kabuğu (XcodeGen) + RootView + manuel eşleştirme

**Files:**
- Create: `LumiMobile/project.yml`
- Create: `LumiMobile/App/LumiMobileApp.swift`
- Create: `LumiMobile/App/RootView.swift`
- Create: `LumiMobile/App/PairingView.swift`
- Modify: `.gitignore` (repo kökü — üretilen proje + build çıktıları)

**Interfaces:**
- Consumes: `AppModel`, `RelayClient`, `KeychainStore` (Task 3-4)
- Produces: derlenen iOS app target'ı `LumiMobile` (bundle `com.lumi.LumiMobile`, URL şeması `lumi-remote`); `RootView(model:)` — `model.isPaired`'e göre `PairingView` ya da oturum navigasyonu; `PairingView(model:)` manuel yapıştırma alanı (Task 9'da QR eklenir); sonraki view görevleri `RootView` içindeki `SessionListView(model:)` placeholder'ını gerçek görünümlerle değiştirir

- [ ] **Step 1: XcodeGen'i kur (yoksa)**

Run: `command -v xcodegen || brew install xcodegen`
Expected: `xcodegen` yolu basılır (kurulum gerekirse brew çıktısı sonrası).

- [ ] **Step 2: project.yml'i yaz**

`LumiMobile/project.yml`:

```yaml
name: LumiMobile
options:
  bundleIdPrefix: com.lumi
  deploymentTarget:
    iOS: "17.0"
packages:
  LumiMobileKit:
    path: LumiMobileKit
targets:
  LumiMobile:
    type: application
    platform: iOS
    sources: [App]
    dependencies:
      - package: LumiMobileKit
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: Lumi
        NSCameraUsageDescription: Eşleştirme QR kodunu okumak için kamera gerekir.
        UILaunchScreen: {}
        CFBundleURLTypes:
          - CFBundleURLName: com.lumi.LumiMobile.pair
            CFBundleURLSchemes: [lumi-remote]
```

- [ ] **Step 3: App kabuğunu yaz**

`LumiMobile/App/LumiMobileApp.swift`:

```swift
import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @State private var model = AppModel(client: RelayClient(), store: KeychainStore())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
                .onOpenURL { url in
                    Task { await model.pair(from: url.absoluteString) }
                }
        }
    }
}
```

`LumiMobile/App/RootView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct RootView: View {
    let model: AppModel

    var body: some View {
        if model.isPaired {
            SessionListView(model: model)
        } else {
            PairingView(model: model)
        }
    }
}

// Task 6'da gerçek listeyle değiştirilecek geçici görünüm.
struct SessionListView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Text("Eşleşti — oturum listesi Task 6'da")
                .navigationTitle("Lumi")
        }
    }
}
```

`LumiMobile/App/PairingView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct PairingView: View {
    let model: AppModel
    @State private var pastedLink = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Mac'te Lumi → Ayarlar → Remote ekranındaki QR'ı okut ya da eşleştirme bağlantısını yapıştır.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                scannerSection
                Section("Bağlantıyı yapıştır") {
                    TextField("lumi-remote://pair?...", text: $pastedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Eşleştir") {
                        Task {
                            let ok = await model.pair(from: pastedLink)
                            showError = !ok
                        }
                    }
                    .disabled(pastedLink.isEmpty)
                    if showError {
                        Text("Bağlantı çözümlenemedi. `lumi-remote://pair?...` biçiminde olmalı.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Eşleştirme")
        }
    }

    // Task 9'da VisionKit tarayıcısıyla doldurulur.
    @ViewBuilder private var scannerSection: some View {
        EmptyView()
    }
}
```

- [ ] **Step 4: .gitignore'a üretilen dosyaları ekle**

Repo kökündeki `.gitignore` dosyasının sonuna şu satırları ekle (dosya yoksa oluştur):

```
# LumiMobile — XcodeGen üretimi + build çıktıları
LumiMobile/LumiMobile.xcodeproj
LumiMobile/build/
```

- [ ] **Step 5: Projeyi üret ve derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Paket testlerinin hâlâ geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/project.yml LumiMobile/App .gitignore
git commit -m "mobile: Xcode app kabuğu (XcodeGen) + manuel eşleştirme ekranı" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: SessionListView — oturum listesi + rozetler + offline şeridi

**Files:**
- Modify: `LumiMobile/App/RootView.swift` (geçici `SessionListView`'ı SİL)
- Create: `LumiMobile/App/SessionListView.swift`

**Interfaces:**
- Consumes: `AppModel.orderedSessions / macOnline / lastSeenAt / connection / unpair()`, `SessionSummary`, `Badge`
- Produces: `SessionListView(model:)` — `NavigationStack` + `navigationDestination(for: String.self)` ile oturum id'sine gider; Task 7 `SessionDetailView(model:sessionId:)` sağlayana kadar detay hedefi geçici `Text(sessionId)`; `StatusBadge(badge:)` görünümü Task 7'de de kullanılır

- [ ] **Step 1: RootView'daki geçici SessionListView'ı sil**

`LumiMobile/App/RootView.swift` içinden `// Task 6'da gerçek listeyle değiştirilecek geçici görünüm.` yorumuyla başlayan `struct SessionListView` bloğunun tamamını sil.

- [ ] **Step 2: Gerçek listeyi yaz**

`LumiMobile/App/SessionListView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct SessionListView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if !model.macOnline {
                    offlineBanner
                }
                ForEach(model.orderedSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                }
                if model.orderedSessions.isEmpty {
                    Text("Aktif oturum yok")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Lumi")
            .navigationDestination(for: String.self) { sessionId in
                // Task 7'de SessionDetailView(model: model, sessionId: sessionId) olur.
                Text(sessionId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionDot
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Eşleştirmeyi kaldır", role: .destructive) {
                            Task { await model.unpair() }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    private var offlineBanner: some View {
        Label {
            Text("Mac çevrimdışı" + lastSeenSuffix)
        } icon: {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
        }
        .font(.callout)
        .foregroundStyle(.orange)
    }

    private var lastSeenSuffix: String {
        guard let lastSeenAt = model.lastSeenAt else { return "" }
        return " — son görülme " + lastSeenAt.formatted(date: .omitted, time: .shortened)
    }

    private var connectionDot: some View {
        Circle()
            .fill(model.connection == .connected ? .green :
                  model.connection == .connecting ? .yellow : .red)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Relay bağlantısı")
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.repoName).font(.headline)
                if let title = session.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            StatusBadge(badge: session.status.badge)
        }
    }
}

struct StatusBadge: View {
    let badge: Badge

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch badge {
        case .idle: "boşta"
        case .working: "çalışıyor"
        case .waiting: "bekliyor"
        case .error: "hata"
        }
    }

    private var color: Color {
        switch badge {
        case .idle: .gray
        case .working: .blue
        case .waiting: .orange
        case .error: .red
        }
    }
}
```

- [ ] **Step 3: Derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/App
git commit -m "mobile: oturum listesi — rozetler, waiting üstte, offline şeridi" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: SessionDetailView — akış + soru kartı + giriş çubuğu

**Files:**
- Create: `LumiMobile/App/SessionDetailView.swift`
- Modify: `LumiMobile/App/SessionListView.swift` (`navigationDestination` içindeki geçici `Text(sessionId)` → `SessionDetailView(model: model, sessionId: sessionId)`)

**Interfaces:**
- Consumes: `AppModel.feeds / questionCard(for:) / lastCommandError / macOnline / session(_:) / sendText / pressKey`, `FeedEntry`, `FeedItem`, `QuestionCard`, `StatusBadge` (Task 6)
- Produces: `SessionDetailView(model:sessionId:)`

- [ ] **Step 1: navigationDestination'ı bağla**

`LumiMobile/App/SessionListView.swift` içinde:

```swift
            .navigationDestination(for: String.self) { sessionId in
                // Task 7'de SessionDetailView(model: model, sessionId: sessionId) olur.
                Text(sessionId)
            }
```
şu hale gelir:
```swift
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailView(model: model, sessionId: sessionId)
            }
```

- [ ] **Step 2: Detay görünümünü yaz**

`LumiMobile/App/SessionDetailView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct SessionDetailView: View {
    let model: AppModel
    let sessionId: String
    @State private var draft = ""

    private var feed: [FeedEntry] { model.feeds[sessionId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            feedScroll
            if let error = model.lastCommandError[sessionId] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let card = model.questionCard(for: sessionId) {
                QuestionCardView(card: card, disabled: !model.macOnline) { key in
                    Task { await model.pressKey(sessionId: sessionId, key: key) }
                }
            }
            inputBar
        }
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = model.session(sessionId) {
                    StatusBadge(badge: session.status.badge)
                }
            }
        }
    }

    private var feedScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if feed.isEmpty {
                        // Eşleşmeyen oturum (Codex / jsonl yok) — tanımlı davranış (tasarım §5).
                        Text("Bu oturum için zengin akış yok; durum ve metin gönderme çalışır.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(feed) { entry in
                        FeedEntryView(entry: entry).id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: feed.last?.id) { _, lastId in
                if let lastId {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .onAppear {
                if let lastId = feed.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(model.macOnline ? "Mesaj yaz…" : "Mac çevrimdışı", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.macOnline)
            Button {
                let text = draft
                draft = ""
                Task { await model.sendText(sessionId: sessionId, text: text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!model.macOnline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct FeedEntryView: View {
    let entry: FeedEntry

    var body: some View {
        switch entry.item {
        case .assistantText(let text):
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let tool, let summary):
            Label("\(tool): \(summary)", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .turnDone:
            Divider().padding(.vertical, 2)
        case .question:
            // Sorular akışta değil sabit kartta gösterilir (AppModel bunları feed'e koymaz).
            EmptyView()
        }
    }
}

struct QuestionCardView: View {
    let card: QuestionCard
    let disabled: Bool
    let onKey: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = card.questions?.first {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(question.question).font(.subheadline)
                ForEach(Array(question.options.prefix(3).enumerated()), id: \.offset) { index, option in
                    Button {
                        onKey("\(index + 1)")
                    } label: {
                        Text("\(index + 1). \(option)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Oturum girdi bekliyor")
                    .font(.subheadline.weight(.semibold))
                if let context = card.context {
                    Text(context).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(["1", "2", "3"], id: \.self) { key in
                        Button(key) { onKey(key) }.buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                Button("Enter") { onKey("enter") }.buttonStyle(.borderedProminent)
                Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
            }
        }
        .disabled(disabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .top)
    }
}
```

- [ ] **Step 3: Derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/App
git commit -m "mobile: oturum detayı — olay akışı, soru/jenerik cevap kartı, giriş çubuğu" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: NewSessionView — telefondan yeni oturum açma

**Files:**
- Create: `LumiMobile/App/NewSessionView.swift`
- Modify: `LumiMobile/App/SessionListView.swift` (toolbar'a "+" butonu + sheet)

**Interfaces:**
- Consumes: `AppModel.repos / personas / macOnline / startState / startSession / resetStartState`, `StartSessionState`
- Produces: `NewSessionView(model:)` (sheet olarak sunulur; başarıda kendini kapatır)

- [ ] **Step 1: Listeye "+" butonunu ekle**

`LumiMobile/App/SessionListView.swift` içinde `struct SessionListView`'a state ekle (`let model: AppModel` satırının altına):

```swift
    @State private var showNewSession = false
```

`toolbar`'daki `ToolbarItem(placement: .topBarTrailing)` bloğunun ÜSTÜNE şu item'ı ekle:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.macOnline)
                }
```

`.toolbar { ... }` bloğunun kapanışından hemen sonra ekle:

```swift
            .sheet(isPresented: $showNewSession) {
                NewSessionView(model: model)
            }
```

- [ ] **Step 2: Yeni oturum formunu yaz**

`LumiMobile/App/NewSessionView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct NewSessionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoPath = ""
    @State private var personaId = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoPath) {
                    Text("Seç…").tag("")
                    ForEach(model.repos) { repo in
                        Text(repo.name).tag(repo.path)
                    }
                }
                Picker("Persona", selection: $personaId) {
                    Text("Yok").tag("")
                    ForEach(model.personas) { persona in
                        Text(persona.label).tag(persona.id)
                    }
                }
                TextField("İlk prompt", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)

                Section {
                    Button(action: submit) {
                        if model.startState == .sending {
                            ProgressView()
                        } else {
                            Text("Oturumu başlat")
                        }
                    }
                    .disabled(!canSubmit)
                    if case .failed(let error) = model.startState {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Yeni oturum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
            .onChange(of: model.startState) { _, state in
                if state == .succeeded {
                    model.resetStartState()
                    dismiss()
                }
            }
            .onAppear { model.resetStartState() }
        }
    }

    private var canSubmit: Bool {
        model.macOnline
            && !repoPath.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.startState != .sending
    }

    private func submit() {
        Task {
            await model.startSession(
                repoPath: repoPath,
                personaId: personaId.isEmpty ? nil : personaId,
                prompt: prompt
            )
        }
    }
}
```

- [ ] **Step 3: Derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/App
git commit -m "mobile: yeni oturum ekranı — repo/persona seçimi + ilk prompt" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: QR tarayıcı (VisionKit) — eşleştirmeyi kamerayla yap

**Files:**
- Create: `LumiMobile/App/QRScannerView.swift`
- Modify: `LumiMobile/App/PairingView.swift` (`scannerSection` placeholder'ını doldur)

**Interfaces:**
- Consumes: `AppModel.pair(from:)` (Task 4)
- Produces: `QRScannerView(onScan: (String) -> Void)` — VisionKit `DataScannerViewController` sarmalayıcısı; simülatörde (`isSupported == false`) bölüm gizlenir, manuel yapıştırma zaten çalışır

- [ ] **Step 1: Tarayıcı sarmalayıcısını yaz**

`LumiMobile/App/QRScannerView.swift`:

```swift
import SwiftUI
import VisionKit

/// VisionKit QR tarayıcısı. Yalnız gerçek cihazda çalışır
/// (DataScannerViewController.isSupported simülatörde false).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onScan(value)
                    return
                }
            }
        }
    }
}
```

- [ ] **Step 2: PairingView'a tarayıcıyı bağla**

`LumiMobile/App/PairingView.swift` içindeki:

```swift
    // Task 9'da VisionKit tarayıcısıyla doldurulur.
    @ViewBuilder private var scannerSection: some View {
        EmptyView()
    }
```
şu hale gelir:
```swift
    @ViewBuilder private var scannerSection: some View {
        if QRScannerView.isAvailable {
            Section("QR okut") {
                QRScannerView { value in
                    Task {
                        let ok = await model.pair(from: value)
                        showError = !ok
                    }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
        }
    }
```

- [ ] **Step 3: Derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/App
git commit -m "mobile: VisionKit QR tarayıcısıyla eşleştirme" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Uçtan uca doğrulama — simülatör + canlı relay + gerçek Lumi

Bu görev kod yazmaz; gerçek zincirle (`LumiMobile → canlı relay → Mac'teki Lumi`) davranış doğrular. Plan 2'nin `fake-phone.mjs` doğrulamasının aynası — bu kez telefon tarafı gerçek.

**Files:**
- (yok — doğrulama görevi; bulgular commit mesajına değil `.superpowers/sdd/progress.md` ledger'ına yazılır)

**Interfaces:**
- Consumes: tüm önceki görevler; Mac tarafı dev config `~/.lumi-dev/remote.json` (enabled=true, canlı relay + token)
- Produces: doğrulanmış uçtan uca akış; bulunan hatalar bu görev içinde düzeltilip commit'lenir

- [ ] **Step 1: Mac Lumi'yi başlat (ayrı süreç, açık kalsın)**

Run (arka planda):
```bash
cd /Users/balkan/Lumi/LumiPackages && swift run Lumi
```
Expected: Lumi açılır; Ayarlar → Remote "bağlı" gösterir. (Zaten çalışıyorsa bu adımı atla.)

- [ ] **Step 2: Eşleştirme deeplink'ini hazırla**

Run: `python3 -c "import json,urllib.parse; c=json.load(open('$HOME/.lumi-dev/remote.json')); print('lumi-remote://pair?url=' + urllib.parse.quote(c['relayUrl'], safe='') + '&token=' + urllib.parse.quote(c['token'], safe=''))"`
Expected: `lumi-remote://pair?url=wss%3A%2F%2Flumi-relay-production.up.railway.app&token=<43-karakter>` basılır. Bu satırı sonraki adımda kullan.

- [ ] **Step 3: Simülatörü aç, uygulamayı kur ve başlat**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build build 2>&1 | tail -3 && \
xcrun simctl boot "iPhone 17" 2>/dev/null; open -a Simulator && \
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/LumiMobile.app && \
xcrun simctl launch booted com.lumi.LumiMobile
```
Expected: BUILD SUCCEEDED; app simülatörde açılır, Eşleştirme ekranı görünür (QR bölümü simülatörde gizli).

- [ ] **Step 4: Deeplink ile eşleştir**

Run: `xcrun simctl openurl booted "<Step 2'deki tam URL>"`
Expected: App eşleştirme ekranından oturum listesine geçer; sol üst bağlantı noktası yeşil; Mac'teki gerçek oturumlar rozetleriyle listelenir.

- [ ] **Step 5: Doğrulama listesini gerçek zincirle geç**

Her maddeyi simülatörde elle doğrula (simülatör ekranını `xcrun simctl io booted screenshot /tmp/lumi-e2e-<n>.png` ile belgeleyebilirsin):

1. **Canlı durum:** Mac'te bir oturumda claude'a iş ver → telefonda rozet `çalışıyor`a döner, transcript akışı (asistan metni + tool satırları) akar.
2. **Soru kartı:** claude bir izin/soru sorduğunda telefonda kart belirir; `1`/`Enter` butonu Mac'teki oturumu gerçekten ilerletir; kart kalkar.
3. **Serbest metin:** telefondan metin gönder → Mac'teki terminale yazılır.
4. **Yeni oturum:** telefondan repo + prompt ile oturum başlat → Mac'te gerçek claude süreci açılır, telefon listesine düşer.
5. **Hatalı komut:** Mac'te oturumu kapat, telefondan aynı oturuma tuş gönder → satır içi hata görünür (`command_result ok:false`).
6. **Mac offline:** Lumi'yi kapat → telefonda turuncu "Mac çevrimdışı — son görülme HH:mm" şeridi; giriş alanları devre dışı. Lumi'yi tekrar aç → şerit kalkar, liste tazelenir.
7. **Yeniden bağlanma:** Simülatörde uçak modu aç/kapat (Ayarlar) ya da app'i öldürüp yeniden başlat → app kendiliğinden yeniden bağlanır, snapshot yeniden dolar.

Expected: 7 maddenin 7'si geçer. Geçmeyen madde için: hatayı bu görev içinde düzelt, ilgili birim testini ekle/güncelle, yeniden doğrula, `mobile:` önekiyle commit'le.

- [ ] **Step 6: Tüm test süitlerinin yeşil olduğunu doğrula**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -3 && \
cd /Users/balkan/Lumi/LumiPackages && swift test 2>&1 | tail -3
```
Expected: LumiMobileKit testleri PASS; LumiPackages 444 test PASS (bu plan LumiPackages'a dokunmadı — güvence kontrolü).

- [ ] **Step 7: Ledger'a doğrulama kaydını yaz ve commit'le (varsa düzeltmelerle birlikte)**

`.superpowers/sdd/progress.md`'ye Task 10 sonucunu (7 maddelik listenin durumu + ekran görüntüsü yolları) ekle.

```bash
cd /Users/balkan/Lumi
git add .superpowers/sdd/progress.md
git commit -m "mobile: uçtan uca doğrulama — simülatör + canlı relay + gerçek Lumi" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: APNs push [KAPILI — ücretli Apple Developer hesabı gerekir]

**ÖN KOŞUL:** Ücretli Apple Developer üyeliği (99 $/yıl) aktif olmalı. Değilse bu görevi ATLA ve planı Task 10'da bitir — app açıkken canlı akış zaten çalışır (tasarım §8); push ayrı bir fast-follow olarak sonra yapılır. Bu görevin cihaz/portal adımları kullanıcıyla birlikte yürütülür (Apple hesabına ve fiziksel iPhone'a erişim gerekir).

**Files:**
- Modify: `LumiMobile/project.yml` (entitlements + signing)
- Create: `LumiMobile/App/PushRegistrar.swift`
- Modify: `LumiMobile/App/LumiMobileApp.swift` (AppDelegate adaptörü + izin isteği)

**Interfaces:**
- Consumes: `AppModel.registerPush(deviceToken:)` (Task 4) → relay'e `register_push {deviceToken}` gider; relay push kuralı: `status_change` + `status ∈ {waiting-unseen, error}` → APNs alert (`docs/spec/50-remote-protocol.md`)
- Produces: gerçek cihazda push bildirimi; Railway'de APNs env değişkenleri

- [ ] **Step 1: APNs anahtarını üret (kullanıcıyla, portalda)**

developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → `+` → "Apple Push Notifications service (APNs)" işaretle → anahtarı indir (`AuthKey_<KEY_ID>.p8`, TEK SEFER indirilir, sakla). `KEY_ID` ve hesap `TEAM_ID`'sini not al. Identifiers altında `com.lumi.LumiMobile` App ID'si yoksa oluştur ve Push Notifications capability'sini işaretle.

- [ ] **Step 2: Railway env değişkenlerini gir**

Railway dashboard → `lumi-relay` projesi (hesap alknberkant@gmail.com) → Variables:

```
APNS_KEY_P8   = <AuthKey_<KEY_ID>.p8 dosyasının TAM içeriği>
APNS_KEY_ID   = <KEY_ID>
APNS_TEAM_ID  = <TEAM_ID>
APNS_BUNDLE_ID = com.lumi.LumiMobile
```

Kaydet → servis yeniden başlar. Doğrulama: Railway logs'ta relay'in Noop yerine gerçek push sender ile açıldığı görülür.

- [ ] **Step 3: project.yml'e push capability + signing ekle**

`LumiMobile/project.yml` içinde `LumiMobile` target'ının `settings.base` bölümüne ekle (TEAM_ID'yi gerçek değerle):

```yaml
        DEVELOPMENT_TEAM: <TEAM_ID>
        CODE_SIGN_STYLE: Automatic
```

ve target'a `entitlements` bölümü ekle (`info:` bloğuyla aynı seviyeye):

```yaml
    entitlements:
      path: App/LumiMobile.entitlements
      properties:
        aps-environment: development
```

- [ ] **Step 4: Push kaydını yaz**

`LumiMobile/App/PushRegistrar.swift`:

```swift
import UIKit
import UserNotifications

/// APNs cihaz token'ını yakalayıp AppModel'e iletir.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    var onDeviceToken: (@MainActor (String) -> Void)?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            self.onDeviceToken?(hex)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Push olmadan da app tam çalışır (tasarım §8); sessiz geç.
    }

    static func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}
```

`LumiMobile/App/LumiMobileApp.swift` şu hale gelir:

```swift
import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
    @State private var model = AppModel(client: RelayClient(), store: KeychainStore())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.start()
                    pushRegistrar.onDeviceToken = { token in
                        Task { await model.registerPush(deviceToken: token) }
                    }
                    if model.isPaired {
                        PushRegistrar.requestAuthorizationAndRegister()
                    }
                }
                .onOpenURL { url in
                    Task {
                        if await model.pair(from: url.absoluteString) {
                            PushRegistrar.requestAuthorizationAndRegister()
                        }
                    }
                }
        }
    }
}
```

- [ ] **Step 5: Derle**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` (simülatörde push kaydı çalışmaz ama derleme geçer).

- [ ] **Step 6: Gerçek cihazda doğrula (kullanıcıyla)**

Kullanıcı Xcode'da (`open LumiMobile.xcodeproj`) kendi iPhone'unu seçip Run eder; QR ile eşleştirir; bildirim izni verir. Sonra iPhone'da app'i KAPATIR, Mac'te bir oturumu `waiting` durumuna düşürür (claude'a izin gerektiren bir iş verir).
Expected: iPhone'a push düşer — title repo adı, body soru özeti (relay push kuralı).

- [ ] **Step 7: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/project.yml LumiMobile/App
git commit -m "mobile: APNs push — cihaz token kaydı + entitlements" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Bitiş

Task 10 (push'suz) ya da Task 11 (push'lu) tamamlanınca `superpowers:finishing-a-development-branch` ile `feature/lumi-remote-ios` → fork main'e merge edilir (handoff'taki akış). Yürütme kalıbı Plan 1/2 ile aynı: kod planda tam yazılı görevlerde implementer=haiku; UI/eşzamanlılık/E2E görevleri (Task 3, 5, 10) = sonnet; incelemeler=sonnet; final tüm-branch incelemesi=fable. Her görev sonrası `scripts/review-package` + task-reviewer subagent; ledger: `.superpowers/sdd/progress.md`.
