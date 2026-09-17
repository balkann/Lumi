# Yol B / Faz 2 — Telefon Native Chat (stream-json) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faz 1'in stream-json journal'ını telefona akıtarak canlı token-token chat'i (soru-öncesi metin dahil) getirmek; eski terminal-şeridi + transcript-tail chat'i sökmek.

**Architecture:** Telefon `start_session{kind:chat}` ile Mac'te `ChatSessionService` üzerinden bir `StreamJsonAgentSession` (Faz 1) başlatır; `RemoteService` journal `snapshots()`'ını diff'leyerek mevcut `chat`/`chat_append`/`chat_status` frame'lerine köprüler, telefon metnini `chat_send` frame'iyle `session.send()`'e yönlendirir. iOS mevcut chat view'ı kullanır, `streamingText` canlı prose öğesi ekler, terminal şeridini kaldırır.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (LumiPackages), XCTest (LumiMobileKit), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-17-streamjson-chat-phase2-design.md` (bağlayıcı).

## Global Constraints

- Branch `feat/remote-orca-main` — **main'e commit YASAK**.
- Relay değişmez; **yeni frame tipi eklenmez** — `chat_status`'a additive `streamingText`, `SessionMeta`'ya additive `kind`, `chat_send` mevcut frame-gönderme kalıbıyla.
- Faz 2 = görüntüleme + metin gönder; soru/izin **cevaplama Faz 2b** (kapsam dışı). AskUserQuestion görünür ama cevaplanamaz (kart bilgilendirici/pasif).
- Chat = stream-json chat oturumu; eski transcript-tail chat + terminal şeridi **sökülür**; terminal oturumları mirror-only.
- Journal mevcut `ChatMessage`/`ChatBlock` üretir; köprü token başına tam-journal serialize ETMEZ (diff).
- Env hijyeni `TerminalEnvironment` (mevcut). `~/.lumi` formatları değişmez.
- DI constructor-injection + `ServiceRegistry` slotu; Fake `LumiTestSupport`.
- Test: `cd LumiPackages && swift build && swift test`; `cd LumiMobile/LumiMobileKit && swift test`; `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- Faz 1 arayüzleri (tüket): `StreamJsonAgentSession(sessionID:repoPath:environment:spawner:binaryLocator:)` (canlı default'lar var), `.start()`, `.send(_:)`, `.snapshots() -> AsyncStream<ChatJournalState>`, `.stop()`; `ChatJournalState(messages:[ChatMessage], streamingText:String?, turnActive:Bool, lastCostUSD:Double?)`; `ChatSessionMeta(id:repoPath:createdAt:)`, `SessionKind`.

---

### Task 1: Wire additive alanları — streamingText + SessionMeta.kind + chat_send

**Files:**
- Modify: `LumiPackages/Sources/LumiWire/ChatTurnStatus.swift` (streamingText alanı + toDict + decode)
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` (SessionMeta.kind encode; sessionsPayload; chat_send decode helper)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (SessionMeta.kind decode)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (chatSendFrame)
- Test: `LumiPackages/Tests/LumiRemoteTests/WireRoundTripTests.swift` (streamingText round-trip); `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStatusDecodeTests.swift` (streamingText decode); `.../ProtocolTests.swift` (chatSendFrame)

**Interfaces:**
- Produces: `ChatTurnStatus.streamingText: String?` (init param sonuna eklenir, default nil); `SessionMeta.kind: String?` (Mac struct + iOS struct); `PhoneProtocol.chatSendFrame(sessionId:text:) -> String` (frame: `{"type":"chat_send","sessionId":...,"text":...}`).

- [ ] **Step 1: Failing test — streamingText round-trip (Mac)**

`WireRoundTripTests.swift`'e ekle:
```swift
@Test func chatStatusStreamingTextRoundTrips() {
    let status = ChatTurnStatus(working: true, startedAtMs: 100, tool: "Bash", streamingText: "Sel")
    let dict = RemoteProtocol.chatStatusPayload(sessionId: "s1", status: status)["status"] as! [String: Any]
    let decoded = ChatTurnStatus.decode(dict)
    #expect(decoded?.streamingText == "Sel")
    #expect(decoded?.working == true)
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter WireRoundTripTests`
Expected: derleme hatası (`streamingText` yok).

- [ ] **Step 3: Implementasyon — ChatTurnStatus.streamingText**

`ChatTurnStatus.swift`: alanı, init'i, toDict'i, decode'u additive güncelle:
```swift
public struct ChatTurnStatus: Sendable, Equatable {
    public var working: Bool
    public var startedAtMs: Int?
    public var tool: String?
    public var streamingText: String?   // canlı in-flight assistant metni (Faz 2); yoksa nil

    public init(working: Bool, startedAtMs: Int?, tool: String?, streamingText: String? = nil) {
        self.working = working; self.startedAtMs = startedAtMs; self.tool = tool
        self.streamingText = streamingText
    }
    public static let idle = ChatTurnStatus(working: false, startedAtMs: nil, tool: nil)

    public func toDict() -> [String: Any] {
        [
            "working": working,
            "startedAtMs": startedAtMs.map { $0 as Any } ?? NSNull(),
            "tool": tool.map { $0 as Any } ?? NSNull(),
            "streamingText": streamingText.map { $0 as Any } ?? NSNull(),
        ]
    }
```
`ChatTurnStatus.decode` (dosyada mevcut) `streamingText` okur: `streamingText: dict["streamingText"] as? String`. (Decode fonksiyonunun mevcut imzasına bu alanı ekle.)

- [ ] **Step 4: SessionMeta.kind (Mac + iOS) + chatSendFrame**

Mac `RemoteProtocol.swift` `SessionMeta` struct'ına `let kind: String?` ekle; `sessionsPayload` her meta dict'ine `"kind": meta.kind.map { $0 as Any } ?? NSNull()` ekle; `SessionMeta` init'ine `kind: String? = nil`.
iOS `Models.swift` `SessionMeta`'ya `public let kind: String?` + init default `kind: String? = nil` + `Decodable` otomatik (opsiyonel alan). 
iOS `PhoneProtocol.swift`:
```swift
    public static func chatSendFrame(sessionId: String, text: String) -> String {
        frame(["type": "chat_send", "sessionId": sessionId, "text": text])
    }
```
(`frame(_:)` mevcut yardımcı — diğer *Frame'lerin kullandığı JSON-encode helper; dosyadaki kalıba uy.)
Mac `RemoteProtocol.swift`'e chat_send decode: `static func decodeChatSend(_ payload: [String: Any]) -> (sessionId: String, text: String)?` (sessionId+text String guard).

- [ ] **Step 5: iOS decode testleri**

`ChatStatusDecodeTests.swift`'e streamingText decode testi; `ProtocolTests.swift`'e chatSendFrame testi (JSON içerik doğrula). RED→GREEN.

- [ ] **Step 6: Tüm ilgili testler yeşil**

Run: `cd LumiPackages && swift test --filter "WireRoundTripTests|RemoteProtocolTests" && cd ../LumiMobile/LumiMobileKit && swift test --filter "ChatStatusDecodeTests|ProtocolTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add LumiPackages/Sources/LumiWire LumiPackages/Sources/LumiRemote/RemoteProtocol.swift LumiPackages/Tests/LumiRemoteTests/WireRoundTripTests.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStatusDecodeTests.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "feat(chat): wire additive — chat_status.streamingText + SessionMeta.kind + chat_send frame"
```

---

### Task 2: Mac — `ChatSessionService` (çok-oturum yöneticisi)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Protocols/ChatSessionServicing.swift`
- Create: `LumiPackages/Sources/LumiServices/NativeChat/ChatSessionService.swift`
- Create: `LumiPackages/Tests/LumiTestSupport/FakeChatSessionService.swift`
- Modify: `LumiPackages/Sources/LumiKit/Composition/ServiceRegistry.swift` (`chatSessions` slotu) + `LumiPackages/Sources/LumiAppCore/Composition/LiveServiceRegistry.swift` (live) + Fake registry
- Test: `LumiPackages/Tests/LumiServicesTests/ChatSessionServiceTests.swift`

**Interfaces:**
- Consumes: `StreamJsonAgentSession` (Faz 1).
- Produces:
  ```swift
  public protocol ChatSessionServicing: Sendable {
      @discardableResult func create(repoPath: String) async -> ChatSessionMeta
      func list() async -> [ChatSessionMeta]
      func close(id: String) async
      func send(id: String, text: String) async
      func snapshots(id: String) async -> AsyncStream<ChatJournalState>?
  }
  ```

- [ ] **Step 1: Failing test (Fake StreamingProcess ile gerçek StreamJsonAgentSession)**

`ChatSessionServiceTests.swift`:
```swift
import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiServices

@Suite struct ChatSessionServiceTests {
    @Test func createStartsSessionAndListsIt() async {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let svc = ChatSessionService(spawner: fake, binaryLocator: FixedBinaryLocator2(path: "/usr/bin/claude"),
                                     environment: [:])
        let meta = await svc.create(repoPath: "/repo")
        let list = await svc.list()
        #expect(list.contains(where: { $0.id == meta.id }))
        #expect(list.count == 1)
    }
    @Test func sendRoutesToSession() async {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let svc = ChatSessionService(spawner: fake, binaryLocator: FixedBinaryLocator2(path: "/usr/bin/claude"),
                                     environment: [:])
        let meta = await svc.create(repoPath: "/repo")
        await svc.send(id: meta.id, text: "merhaba")
        // create bir handle spawn etti; send ona yazdı.
        let written = fake.handles.first?.written.joined() ?? ""
        #expect(written.contains("merhaba"))
    }
}
struct FixedBinaryLocator2: BinaryLocating {
    let path: String?
    func locate(_ name: String, timeout: TimeInterval) async -> String? { path }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter ChatSessionServiceTests`
Expected: derleme hatası (`ChatSessionService` yok).

- [ ] **Step 3: Implementasyon**

`ChatSessionServicing.swift` (LumiKit) — protokol (yukarıdaki).

`ChatSessionService.swift` (LumiServices):
```swift
import Foundation
import LumiKit

/// Chat oturumlarını yöneten actor: her biri bir StreamJsonAgentSession (Faz 1).
/// In-memory; geçmiş claude transcript'inde kalıcı (spec Faz 2 §A).
public actor ChatSessionService: ChatSessionServicing {
    private let spawner: any StreamingProcessSpawning
    private let binaryLocator: any BinaryLocating
    private let environment: [String: String]
    private let makeSessionID: () -> String
    private var sessions: [String: StreamJsonAgentSession] = [:]
    private var metas: [String: ChatSessionMeta] = [:]

    public init(spawner: any StreamingProcessSpawning = LiveStreamingProcess(),
                binaryLocator: any BinaryLocating = SystemBinaryLocator(),
                environment: [String: String],
                makeSessionID: @escaping () -> String = { UUID().uuidString.lowercased() },
                now: @escaping () -> Date = Date.init) {
        self.spawner = spawner; self.binaryLocator = binaryLocator
        self.environment = environment; self.makeSessionID = makeSessionID
        self.now = now
    }
    private let now: () -> Date

    @discardableResult
    public func create(repoPath: String) async -> ChatSessionMeta {
        let id = makeSessionID()
        let session = StreamJsonAgentSession(sessionID: id, repoPath: repoPath, environment: environment,
                                             spawner: spawner, binaryLocator: binaryLocator)
        sessions[id] = session
        let meta = ChatSessionMeta(id: id, repoPath: repoPath, createdAt: now())
        metas[id] = meta
        await session.start()
        return meta
    }
    public func list() -> [ChatSessionMeta] { Array(metas.values) }
    public func close(id: String) async {
        await sessions[id]?.stop(); sessions[id] = nil; metas[id] = nil
    }
    public func send(id: String, text: String) async { await sessions[id]?.send(text) }
    public func snapshots(id: String) async -> AsyncStream<ChatJournalState>? {
        guard let s = sessions[id] else { return nil }
        return await s.snapshots()
    }
}
```
Not: `now` parametresi `Date.now()` yasağına takılmaz çünkü enjekte; testte default kullanılır (test `createdAt`'ı kontrol etmiyor).

`FakeChatSessionService.swift` (LumiTestSupport) — RemoteService testleri için: scripted `[ChatJournalState]` snapshot verilir; `create` sabit meta döndürür; `snapshots(id:)` scripted state'leri yayan bir AsyncStream; `send` çağrılarını `sentText: [(String,String)]` biriktirir; `created:[ChatSessionMeta]`.

`ServiceRegistry.swift`'e `var chatSessions: any ChatSessionServicing { get }`; `LiveServiceRegistry`'de `ChatSessionService(environment: <TerminalEnvironment temiz env>)`; Fake registry'de `FakeChatSessionService()`.

- [ ] **Step 4: PASS**

Run: `cd LumiPackages && swift test --filter ChatSessionServiceTests && swift build 2>&1 | tail -2`
Expected: testler PASS, registry derlenir.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit LumiPackages/Sources/LumiServices/NativeChat/ChatSessionService.swift LumiPackages/Sources/LumiAppCore LumiPackages/Tests/LumiTestSupport/FakeChatSessionService.swift LumiPackages/Tests/LumiServicesTests/ChatSessionServiceTests.swift
git commit -m "feat(chat): ChatSessionService — chat oturumu yöneticisi + DI slotu + Fake"
```

---

### Task 3: Mac — RemoteService chat köprüsü + eski chat yolunun sökümü

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (chat köprüsü; startFeedEmission chat kolundan kaldır; transcript-tail chat kaldır)
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift` (start_session kind=chat; chat_send)
- Modify: `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift` (chatSessions enjekte)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatBridgeTests.swift`; `RemoteCommandHandlerTests.swift` (kind=chat, chat_send)

**Interfaces:**
- Consumes: `ChatSessionServicing` (Task 2), `chat_status.streamingText`/`SessionMeta.kind`/`chat_send` (Task 1).
- Produces: chat-oturumu subscribe'ında journal→frame köprüsü; `start_session{kind:chat}` chat oturumu; `chat_send` → service.send.

- [ ] **Step 1: Failing test — köprü diff**

`RemoteServiceChatBridgeTests.swift` (Fake ChatSessionService scripted snapshot'larıyla):
```swift
@Test func chatSessionSubscribeBridgesSnapshotsToFrames() async throws {
    let conn = FakeRelayConnection()
    let chatSvc = FakeChatSessionService()
    let meta = ChatSessionMeta(id: "cs1", repoPath: "/repo", createdAt: Date())
    chatSvc.stub(meta: meta, snapshots: [
        ChatJournalState(),                                              // boş
        { var s = ChatJournalState(); s.streamingText = "Sel"; s.turnActive = true; return s }(),
        { var s = ChatJournalState(); s.messages = [ChatMessage(id: "m1", role: .assistant, blocks: [.text("Selam", presentation: nil)], timestampMs: nil, turnId: "m1")]; return s }(),
    ])
    let svc = RemoteService(paths: .testDefaults(), terminal: FakeTerminalServicing(), repos: FakeRepoService(),
        connection: conn, chatSource: FakeChatTranscriptSource(events: []),
        hookEvents: { AsyncStream { _ in } }, chatSessions: chatSvc)
    await svc.start()
    await conn.injectInbound(type: "subscribe", payload: ["sessionId": "cs1", "mode": "chat"])
    // streamingText chat_status'ta, tamamlanmış mesaj chat/chat_append'te gelir:
    try await conn.waitForSent(types: ["chat_status", "chat_append"])
    svc.stop()
}
```
(Not: RemoteService init'ine `chatSessions` parametresi eklenir; mevcut testlerin init çağrıları default'la geriye uyumlu olmalı — `chatSessions: any ChatSessionServicing = NoopChatSessionService()` default ver.)

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatBridgeTests`
Expected: derleme/subscribe hatası.

- [ ] **Step 3: Implementasyon — köprü + söküm**

`RemoteService.swift`:
- init'e `chatSessions: any ChatSessionServicing` (default `NoopChatSessionService()` — LumiRemote'a küçük noop ekle).
- `handleSubscribe` chat dalı: eğer sessionId bir chat oturumuysa (`chatSessions.snapshots(id:)` nil değilse) journal köprüsü kur; DEĞİLSE bugünkü transcript yolu YERİNE — **bu faz eski chat yolunu söküyor**: terminal oturumları için `mode=chat` artık desteklenmez; chat yalnız chat oturumları için. `startFeedEmission` çağrısını chat kolundan kaldır (terminal kolunda kalır). Transcript-tail chat (chatSource/awaitTranscript/emitChat) chat oturumu olmayan id için çağrılmaz.
- Köprü: `chatSubscriptions[id] = Task { for await snap in stream { await self.emitChatDiff(sessionId: raw, snap) } }`.
- `emitChatDiff`: oturum başına `lastMessages`/`lastStreaming`/`lastWorking` tut; yeni mesajlar (id ile karşılaştır) → ilkse `chat` snapshot, sonra `chat_append`; `streamingText`/`turnActive`/tool değişince `chat_status(streamingText:)`.

`RemoteCommandHandler.swift`:
- `startSession`: `let kind = payload["kind"] as? String`; `kind == "chat"` → `let meta = await chatSessions.create(repoPath: repoPath)`; `if !prompt.isEmpty { await chatSessions.send(id: meta.id, text: prompt) }`; `return ["commandId": commandId, "ok": true, "sessionId": meta.id]`. Aksi halde bugünkü terminal spawn.
- Yeni `chat_send` komut/route: RemoteService frame router'ında `chat_send` → `chatSessions.send(id:text:)` (decode `RemoteProtocol.decodeChatSend`).
- `RemoteFeatureAssembly`: `services.chatSessions`'ı RemoteService/handler'a geçir.

- [ ] **Step 4: kind=chat + chat_send testleri**

`RemoteCommandHandlerTests.swift`: `start_session{kind:chat}` → FakeChatSessionService.created dolu + commandResult.sessionId; `chat_send` → FakeChatSessionService.sentText dolu. Terminal `start_session` (kind yok) regresyonu korunur.

- [ ] **Step 5: Tüm Mac chat/remote testleri yeşil**

Run: `cd LumiPackages && swift test --filter "RemoteService|RemoteCommandHandler|RemoteServiceChatBridge"`
Expected: PASS (eski `RemoteServiceChatFallbackTests` mode=chat davranışı değiştiği için — o testler eski transcript-tail chat yolunu doğruluyordu; bu faz o yolu söktüğü için ilgili testleri chat-oturumu köprüsüne göre güncelle veya kaldır; hangi testlerin güncellendiğini raporda belirt).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift LumiPackages/Tests/LumiRemoteTests
git commit -m "feat(chat): RemoteService journal→frame köprüsü + start_session kind=chat + chat_send; eski transcript-tail chat söküldü"
```

---

### Task 4: iOS Kit — AppModel chat oturumu + streaming + chat_send

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatStreamingGate.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStreamingGateTests.swift`; `AppModelTests.swift` (chat_send routing, streamingText)

**Interfaces:**
- Consumes: `chat_status.streamingText` (Task 1), `SessionMeta.kind`.
- Produces: `chatStreamingText(sessionId) -> String?`; `startChatSession(repoPath:)`; `submitText` chat oturumu için `chat_send`; saf `chatStreamingVisible(...)`.

- [ ] **Step 1: Failing test — streaming gate + chat_send**

`ChatStreamingGateTests.swift`:
```swift
import XCTest
@testable import LumiMobileKit
import LumiWire

final class ChatStreamingGateTests: XCTestCase {
    func testStreamingVisibleWhenLeadingLastMessage() {
        // streaming metni son mesajı geçiyorsa göster; içeriyorsa/kısaysa gizle (orca gate)
        XCTAssertEqual(chatStreamingText(working: true, streaming: "Selam dünya",
                                         lastAssistantText: "Selam"), "Selam dünya")
        XCTAssertNil(chatStreamingText(working: true, streaming: "Selam",
                                       lastAssistantText: "Selam dünya"))   // caught up
        XCTAssertNil(chatStreamingText(working: false, streaming: "x", lastAssistantText: ""))  // idle
        XCTAssertNil(chatStreamingText(working: true, streaming: nil, lastAssistantText: ""))
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatStreamingGateTests`
Expected: derleme hatası.

- [ ] **Step 3: Implementasyon**

`ChatStreamingGate.swift` (orca `deriveNativeChatStreamingText` paritesi):
```swift
import Foundation

/// Canlı streaming metnini göster/gizle kuralı (orca native-chat-streaming paritesi;
/// spec Faz 2 §E). working değilse veya streaming boşsa nil; streaming son assistant
/// metnini geçmiyorsa (içeriyorsa/kısaysa) nil — transcript yerleşince overlay düşer.
public func chatStreamingText(working: Bool, streaming: String?, lastAssistantText: String) -> String? {
    guard working, let text = streaming?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    if lastAssistantText.contains(text) || text.count <= lastAssistantText.count { return nil }
    return text
}
```

`AppModel.swift`:
- `chatStreamingText(_ sessionId:) -> String?`: `turnStatus[sessionId]`'in `working`+`streamingText`'i ile o oturumun son assistant mesaj metnini kurala verir.
- `startChatSession(repoPath:)`: `start_session` komutunu `kind:"chat"` ile yollar (mevcut start komutu payload'ına kind ekle); commandResult'tan sessionId alınınca oturum açılır (mevcut start akışına kind + dönen sessionId eklenir).
- `submitText(_ sessionId:_ text:)`: oturum chat türündeyse (`sessions`'daki `SessionMeta.kind == "chat"`) `chat_send` frame'i yollar; değilse mevcut PTY input yolu.
- `chat_status` decode zaten streamingText taşıyacak (Task 1) → `turnStatus` güncellenir.

- [ ] **Step 4: chat_send + streamingText testleri (AppModelTests)**

chat türü oturumda `submitText` → `chat_send` frame'i (PTY input değil); terminal oturumda mevcut input yolu korunur. chat_status streamingText → `chatStreamingText` doğru döndürür.

- [ ] **Step 5: Tüm Kit testleri yeşil**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit
git commit -m "feat(mobile-kit): chat oturumu başlatma + streaming gate + chat_send routing"
```

---

### Task 5: iOS App — MobileChatView streaming prose + şerit sökümü + oturum başlatma

**Files:**
- Modify: `LumiMobile/App/MobileChatView.swift` (streaming prose öğesi; strip kaldır)
- Delete: `LumiMobile/App/ChatLiveTerminalStrip.swift`, `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatLiveStrip.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (feedSeen/gridRows/hasFeed/feed rotası kaldır — bu task'e ait; Task 4 additive kalır)
- Modify: `LumiMobile/App/NewSessionView.swift` (chat oturumu başlat) + `LumiMobile/App/SessionListView.swift` (chat/terminal ayrımı, opsiyonel)
- Regenerate: `LumiMobile/LumiMobile.xcodeproj` (dosya silme/ekleme → xcodegen)

**Interfaces:**
- Consumes: `model.chatStreamingText(_:)`, `model.startChatSession(...)`, `SessionMeta.kind` (Task 4).

Test yok (saf UI); teslim kriteri build + Kit testleri yeşil.

- [ ] **Step 1: Şeridi kaldır + streaming prose ekle**

`MobileChatView.swift`: `ChatLiveTerminalStrip` bloğunu ve `chatLiveStripVisible(...)` çağrısını KALDIR. Yerine, mesaj listesinin sonuna (son turn'den sonra) canlı streaming prose öğesi ekle:
```swift
    if let streaming = model.chatStreamingText(sessionId) {
        Text(streaming)
            .textSelection(.enabled)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
```
(assistant prose stiliyle; balonsuz — Task-4 önceki iş ile tutarlı.)

- [ ] **Step 2: feed altyapısını kaldır**

`AppModel.swift`'te `feedSeen`/`gridRows`/`hasFeed`/`route`'taki feed işaretleme + `applySessions` feed filtresi (önceki milestone Task 2) KALDIR. `ChatLiveStrip.swift` sil. `terminalStream`/terminal-mirror yolları KALIR (terminal oturumları için).

- [ ] **Step 3: NewSessionView chat başlat**

`NewSessionView.swift`: başlat butonu `model.startChatSession(repoPath:)` çağırır (mevcut terminal-start yerine chat). (Terminal oturumu başlatma UI'si bu fazda kapsam dışı — telefon chat-first.)

- [ ] **Step 4: Proje üret + build**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (silinen dosyalara referans kalmamalı).

- [ ] **Step 5: Commit**

```bash
git add -A LumiMobile
git commit -m "feat(mobile): stream-json chat view (streaming prose) + terminal şeridi/feed sökümü + chat oturumu başlatma"
```

---

### Task 6: Sweep + kurulum + final review

**Files:** yok (doğrulama + paketleme).

- [ ] **Step 1: Mac tam test + release**

Run: `cd LumiPackages && swift build && swift test 2>&1 | tail -3 && swift build -c release --product Lumi 2>&1 | tail -2`
Expected: tümü yeşil (disk-I/O'da `--scratch-path /tmp/lumi-scratch`).

- [ ] **Step 2: iOS Kit + app build**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -3 && cd .. && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: Kit PASS, BUILD SUCCEEDED.

- [ ] **Step 3: Mac app kur + temiz env relaunch**

Run:
```bash
pkill -x Lumi 2>/dev/null; sleep 1
Scripts/make-app.sh --install
env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT open /Applications/Lumi.app
```

- [ ] **Step 4: iPhone build + kur**

Run: `cd LumiMobile && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'platform=iOS,id=55DA1E5F-6F85-5746-8171-E25C8C0E0C5C' -allowProvisioningUpdates build`, sonra `APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/LumiMobile-*/Build/Products/Debug-iphoneos/LumiMobile.app | head -1); xcrun devicectl device install app --device 55DA1E5F-6F85-5746-8171-E25C8C0E0C5C "$APP"`.

- [ ] **Step 5: Final whole-branch review + ledger + rapor**

Whole-branch review (opus) dispatch (Faz 2 aralığı). Ledger'a task satırları. Kullanıcıya cihaz test senaryosu: telefondan yeni chat → prompt yaz → canlı token-token akış + soru-öncesi metin görünür → AskUserQuestion görünür (cevaplama Faz 2b). Terminal oturumları hâlâ mirror.
