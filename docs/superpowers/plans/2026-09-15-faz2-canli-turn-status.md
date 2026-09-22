# Faz 2 — Canlı Turn Status (Remote Native Chat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefon chat görünümünde, bir tur sürerken canlı "Çalışıyor {n}sn" bandı + o an koşan araç çipi + turu kesen Stop butonu göster; kaynak = Claude/Codex hook olayları.

**Architecture:** Mac tarafında `AgentHookServer.events()` akışı `RemoteService`'e enjekte edilir; session başına saf `TurnStatusReducer` hook olaylarını `ChatTurnStatus`'a katlar; durum değişince (ve session chat modunda abone ise) yeni bir opak `chat_status` frame'i relay üzerinden telefona passthrough edilir. Telefon `AppModel.turnStatus[sid]`'i günceller ve composer üstünde bir bant çizer. Nihai düz-metin akışı KAPSAM DIŞI (spec §1).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (iOS 17+), `AsyncStream`/`EventBroadcaster`, TypeScript (RelayServer, node:test), XCTest + swift-testing.

## Global Constraints

- **main'e commit YOK.** Branch: `feat/remote-orca-main`. Bu Mac'ten Lumi `main`'e commit yasak (memory: no-commit-to-main).
- **Wire modeli değişmez pattern:** model LumiKit'te tanımlanır, LumiMobileKit'e birebir kopyalanır (mevcut `ChatMessage` kalıbı). Wire JSON alan adları iki tarafta AYNI olmalı.
- **`chat_status` payload alanları (tam):** `{ "sessionId": String, "working": Bool, "startedAtMs": Int|null, "tool": String|null }`. Frame `type` string'i tam olarak `"chat_status"`.
- **Yön:** Mac → relay → telefon (tek yön, opak passthrough). Relay oda-izolasyonu korunur.
- **LumiMobile literal kullanır**, `Theme` token'ları DEĞİL. `DesignTokenLintTests` LumiMobile'ı kapsamaz — mevcut mobil literal kalıbını izle (`Color(uiColor: .systemBackground)` vb.).
- **`Date.now`/`Math.random` yasağı** yalnız workflow script'leri içindir; iOS/Mac uygulama kodu `Date()` / `.now` kullanabilir. Reducer'ın saati testte determinizm için enjekte edilir.
- **Build/test komutları (CI üçünü de koşar):**
  - `cd LumiPackages && swift build && swift test`
  - `cd LumiMobile/LumiMobileKit && swift test`
  - `cd RelayServer && npm test`
- **Launch-env kuralı (kritik):** LumiRework'ü Claude Code bash'ından `open`/`swift run` ile BAŞLATMA — `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID` env'i spawn edilen claude'lara sızıp transcript yazımını bozar. iOS bandı + canlı senaryo doğrulaması KULLANICI tarafından (Finder/Dock'tan temiz env) yapılır.

## Deviations from spec §8 file inventory (kasıtlı, gerekçeli)

Spec §8 "Dosya envanteri (**tahmini**)" başlıklı — bağlayıcı değil. İki sapma:

1. **`TurnStatusReducer` → `LumiKit`, `LumiServices` değil.** `RemoteService` `LumiRemote` modülündedir ve `Package.swift`'te **yalnız `LumiKit`'e** bağlıdır (satır 46). `AgentHookEvent`/`AgentHookEventKind`/`AgentHookServing` zaten LumiKit'te. Reducer'ı LumiServices'e koymak LumiRemote→LumiServices bağımlılığı (+ transitively Highlightr) gerektirirdi. Reducer saf olduğu ve yalnız LumiKit tiplerine dokunduğu için `Sources/LumiKit/NativeChat/TurnStatusReducer.swift`'e konur; testi `LumiKitTests`'e gider.
2. **`FakeAgentHookEventStream` EKLENMEZ.** `LumiTestSupport/FakeAgentHooks.swift`'teki mevcut `FakeAgentHookServer` (`events()` + `emit(_:)`) bu işi birebir yapar — DRY gereği yeniden kullanılır.

## File Structure

- **Create** `LumiPackages/Sources/LumiKit/Models/ChatTurnStatus.swift` — wire modeli + `toDict()` + `.idle`.
- **Create** `LumiPackages/Sources/LumiKit/NativeChat/TurnStatusReducer.swift` — saf hook→status reducer (enjekte saat).
- **Modify** `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` — `chatStatusPayload(...)`.
- **Modify** `LumiPackages/Sources/LumiRemote/RemoteService.swift` — hook tap, per-session reducer, `chat_status` yayını + subscribe snapshot + cleanup, init'e `hookEvents`/`turnClock`.
- **Modify** `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift` — `services.agentHooks.events()` enjeksiyonu.
- **Modify** `RelayServer/src/protocol.ts` + `RelayServer/src/bridge.ts` — `chat_status` opak passthrough.
- **Create** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatTurnStatus.swift` — LumiKit kopyası + `decode`.
- **Modify** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` — `ServerMessage.chatStatus` + decode.
- **Modify** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — `turnStatus` merge + ölü-oturum temizliği.
- **Create** `LumiMobile/App/TurnStatusBar.swift` — SwiftUI bant.
- **Modify** `LumiMobile/App/MobileChatView.swift` — bandı composer üstüne yerleştir.
- **Tests:** `LumiKitTests` (model + reducer), `LumiRemoteTests` (hook→frame), `LumiMobileKitTests` (decode + AppModel merge), `RelayServer/test` (passthrough).

---

### Task 1: `ChatTurnStatus` wire modeli (LumiKit)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Models/ChatTurnStatus.swift`
- Test: `LumiPackages/Tests/LumiKitTests/ChatTurnStatusTests.swift`

**Interfaces:**
- Produces: `public struct ChatTurnStatus: Sendable, Equatable { var working: Bool; var startedAtMs: Int?; var tool: String? }`, `static let idle`, `func toDict() -> [String: Any]` (alanlar: `working`, `startedAtMs` (nil→`NSNull`), `tool` (nil→`NSNull`); `sessionId` DAHİL DEĞİL — onu payload builder ekler).

- [ ] **Step 1: Write the failing test**

`LumiPackages/Tests/LumiKitTests/ChatTurnStatusTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiKit

@Suite struct ChatTurnStatusTests {
    @Test func idleIsNotWorking() {
        #expect(ChatTurnStatus.idle == ChatTurnStatus(working: false, startedAtMs: nil, tool: nil))
    }

    @Test func toDictEncodesWorkingWithNSNullForNils() {
        let dict = ChatTurnStatus(working: true, startedAtMs: nil, tool: nil).toDict()
        #expect(dict["working"] as? Bool == true)
        #expect(dict["startedAtMs"] is NSNull)
        #expect(dict["tool"] is NSNull)
    }

    @Test func toDictEncodesValues() {
        let dict = ChatTurnStatus(working: true, startedAtMs: 1234, tool: "Bash").toDict()
        #expect(dict["startedAtMs"] as? Int == 1234)
        #expect(dict["tool"] as? String == "Bash")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/ChatTurnStatusTests`
Expected: FAIL — "cannot find 'ChatTurnStatus' in scope".

- [ ] **Step 3: Write the model**

`LumiPackages/Sources/LumiKit/Models/ChatTurnStatus.swift`:
```swift
import Foundation

/// Faz 2 canlı turn-status wire modeli. Değişmez pattern: LumiKit'te tanımlanır,
/// LumiMobileKit'e birebir kopyalanır (bkz. `ChatMessage`). `sessionId` frame
/// zarfında taşınır, modelin parçası değildir.
public struct ChatTurnStatus: Sendable, Equatable {
    public var working: Bool
    public var startedAtMs: Int?   // tur başı (epoch ms); working=false ise nil
    public var tool: String?       // o an koşan lider araç adı; yoksa nil

    public init(working: Bool, startedAtMs: Int?, tool: String?) {
        self.working = working
        self.startedAtMs = startedAtMs
        self.tool = tool
    }

    public static let idle = ChatTurnStatus(working: false, startedAtMs: nil, tool: nil)

    public func toDict() -> [String: Any] {
        [
            "working": working,
            "startedAtMs": startedAtMs.map { $0 as Any } ?? NSNull(),
            "tool": tool.map { $0 as Any } ?? NSNull(),
        ]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/ChatTurnStatusTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/ChatTurnStatus.swift LumiPackages/Tests/LumiKitTests/ChatTurnStatusTests.swift
git commit -m "feat(remote): ChatTurnStatus wire modeli (Faz 2 turn-status)"
```

---

### Task 2: `TurnStatusReducer` (LumiKit, saf)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/NativeChat/TurnStatusReducer.swift`
- Test: `LumiPackages/Tests/LumiKitTests/TurnStatusReducerTests.swift`

**Interfaces:**
- Consumes: `AgentHookEvent` (LumiKit — alanlar: `kind: AgentHookEventKind`, `toolName: String?`, `source: String?`, `terminalID: TerminalID`, hesap özelliği `isLead: Bool` = `agentID == nil`), `ChatTurnStatus` (Task 1).
- Produces: `public final class TurnStatusReducer` — `init(now: @escaping @Sendable () -> Date = { Date() })`, `private(set) var status: ChatTurnStatus` (başlangıç `.idle`), `func reduce(_ event: AgentHookEvent) -> ChatTurnStatus?` (değişiklikte yeni durum, aksi halde `nil` — idempotent).

Reduce kuralları (spec §4.2):

| `event.kind` | Etki |
|---|---|
| `.userPromptSubmit` | `working=true`, `startedAtMs=now()` ms, `tool=nil` |
| `.preToolUse` (yalnız `isLead`) | `tool = event.toolName` |
| `.postToolUse` / `.postToolUseFailure` (yalnız `isLead`) | `tool=nil` |
| `.stop` / `.stopFailure` | `.idle`'a sıfırla |
| `.sessionStart` `source=="clear"` | `.idle`'a sıfırla |
| diğer (subagent*, permissionRequest, sessionEnd, teammateIdle, postCompact, unknown, sessionStart≠clear) | değişiklik yok (`nil`) |

- [ ] **Step 1: Write the failing test**

`LumiPackages/Tests/LumiKitTests/TurnStatusReducerTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiKit

@Suite struct TurnStatusReducerTests {
    private let term = TerminalID()
    private func event(_ kind: AgentHookEventKind, tool: String? = nil,
                       source: String? = nil, agentID: String? = nil) -> AgentHookEvent {
        AgentHookEvent(
            provider: .claude, terminalID: term, kind: kind, agentID: agentID,
            teammateName: nil, toolName: tool, source: source, trigger: nil,
            isInterrupt: false, promptHead: nil, runningBackgroundAgentIDs: nil,
            receivedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func promptStartsWorkingWithInjectedClock() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 100) })
        let s = r.reduce(event(.userPromptSubmit))
        #expect(s == ChatTurnStatus(working: true, startedAtMs: 100_000, tool: nil))
    }

    @Test func preToolSetsToolPostToolClearsIt() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 1) })
        _ = r.reduce(event(.userPromptSubmit))
        #expect(r.reduce(event(.preToolUse, tool: "Bash"))?.tool == "Bash")
        #expect(r.reduce(event(.postToolUse, tool: "Bash"))?.tool == nil)
        #expect(r.status.working == true)   // working korunur
    }

    @Test func stopResetsToIdle() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 1) })
        _ = r.reduce(event(.userPromptSubmit))
        #expect(r.reduce(event(.stop)) == .idle)
    }

    @Test func clearSessionStartResets() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 1) })
        _ = r.reduce(event(.userPromptSubmit))
        #expect(r.reduce(event(.sessionStart, source: "clear")) == .idle)
    }

    @Test func subagentAndUnrelatedEventsAreIgnored() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 1) })
        _ = r.reduce(event(.userPromptSubmit))
        #expect(r.reduce(event(.preToolUse, tool: "Bash", agentID: "sub-1")) == nil) // subagent → yok
        #expect(r.reduce(event(.permissionRequest)) == nil)
        #expect(r.reduce(event(.sessionStart, source: "resume")) == nil)             // clear değil
    }

    @Test func idempotentSameStatusNotReemitted() {
        let r = TurnStatusReducer(now: { Date(timeIntervalSince1970: 1) })
        _ = r.reduce(event(.userPromptSubmit))
        _ = r.reduce(event(.stop))
        #expect(r.reduce(event(.stop)) == nil)   // zaten idle → nil
    }
}
```

> Not: `AgentHookEvent` üye init'inin argüman etiket/sırasını, `LumiTerminalTests/AgentHookStatusReducerTests.swift`'teki `event()` helper'ıyla karşılaştırıp birebir eşle (alanlar: provider, terminalID, kind, agentID, teammateName, toolName, source, trigger, isInterrupt, promptHead, runningBackgroundAgentIDs, receivedAt). Init public değilse orada nasıl çağrılıyorsa aynen kullan.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/TurnStatusReducerTests`
Expected: FAIL — "cannot find 'TurnStatusReducer' in scope".

- [ ] **Step 3: Write the reducer**

`LumiPackages/Sources/LumiKit/NativeChat/TurnStatusReducer.swift`:
```swift
import Foundation

/// Saf, test-edilebilir turn-status reducer (spec §4.2). Session başına bir örnek;
/// hook olaylarını `ChatTurnStatus`'a katlar. Saat testte determinizm için enjekte
/// edilir. "working" için TEK otorite budur (userPromptSubmit→stop); SessionMeta.status
/// ile çift-kaynak kullanılmaz.
public final class TurnStatusReducer {
    private let now: @Sendable () -> Date
    public private(set) var status: ChatTurnStatus = .idle

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Durum değiştiyse yeni `ChatTurnStatus`, aksi halde `nil` (idempotent).
    public func reduce(_ event: AgentHookEvent) -> ChatTurnStatus? {
        var next = status
        switch event.kind {
        case .userPromptSubmit:
            next = ChatTurnStatus(
                working: true,
                startedAtMs: Int(now().timeIntervalSince1970 * 1000),
                tool: nil
            )
        case .preToolUse:
            guard event.isLead else { return nil }
            next.tool = event.toolName
        case .postToolUse, .postToolUseFailure:
            guard event.isLead else { return nil }
            next.tool = nil
        case .stop, .stopFailure:
            next = .idle
        case .sessionStart:
            guard event.source == "clear" else { return nil }
            next = .idle
        default:
            return nil
        }
        guard next != status else { return nil }
        status = next
        return next
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/TurnStatusReducerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/NativeChat/TurnStatusReducer.swift LumiPackages/Tests/LumiKitTests/TurnStatusReducerTests.swift
git commit -m "feat(remote): TurnStatusReducer — hook olayları → ChatTurnStatus"
```

---

### Task 3: `RemoteProtocol.chatStatusPayload`

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` (mevcut `chatPayload`/`chatAppendPayload` ~satır 87-95 yanına)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift` (varsa oraya ekle; yoksa oluştur)

**Interfaces:**
- Consumes: `ChatTurnStatus.toDict()` (Task 1).
- Produces: `static func chatStatusPayload(sessionId: String, status: ChatTurnStatus) -> [String: Any]` — `status.toDict()` + `["sessionId": sessionId]`.

- [ ] **Step 1: Write the failing test**

`LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift` (yeni dosyaysa):
```swift
import Testing
import Foundation
import LumiKit
@testable import LumiRemote

@Suite struct RemoteProtocolChatStatusTests {
    @Test func chatStatusPayloadCarriesSessionIdAndFields() {
        let p = RemoteProtocol.chatStatusPayload(
            sessionId: "s1",
            status: ChatTurnStatus(working: true, startedAtMs: 42, tool: "Read")
        )
        #expect(p["sessionId"] as? String == "s1")
        #expect(p["working"] as? Bool == true)
        #expect(p["startedAtMs"] as? Int == 42)
        #expect(p["tool"] as? String == "Read")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteProtocolChatStatusTests`
Expected: FAIL — "type 'RemoteProtocol' has no member 'chatStatusPayload'".

- [ ] **Step 3: Add the payload builder**

`RemoteProtocol.swift`'te `chatAppendPayload` fonksiyonunun hemen altına:
```swift
/// `chat_status` payload: bir oturumun canlı turn-status'u (Faz 2). Mac→telefon.
static func chatStatusPayload(sessionId: String, status: ChatTurnStatus) -> [String: Any] {
    var dict = status.toDict()
    dict["sessionId"] = sessionId
    return dict
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteProtocolChatStatusTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteProtocol.swift LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift
git commit -m "feat(remote): RemoteProtocol.chatStatusPayload"
```

---

### Task 4: `RemoteService` hook tap + `chat_status` yayını + snapshot + cleanup + assembly

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- Modify: `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTurnStatusTests.swift`

**Interfaces:**
- Consumes: `TurnStatusReducer` (Task 2), `RemoteProtocol.chatStatusPayload` (Task 3), `AgentHookServing.events() -> AsyncStream<AgentHookEvent>` (LumiKit), mevcut `FakeAgentHookServer` (LumiTestSupport).
- Produces: `RemoteService.init` yeni parametreler `hookEvents: AsyncStream<AgentHookEvent> = AsyncStream { _ in }`, `turnClock: @escaping @Sendable () -> Date = { Date() }`.

Mantık:
- `event.terminalID` → session'ın `TerminalID`'si; frame `sessionId = id.description` (mevcut `SessionMeta.id = meta.id.description`, satır 181 — subscribe `raw` == `id.description`).
- Reducer session başına `turnReducers[id]`'te tutulur; abone olmasa da güncellenir (sonraki subscribe snapshot'ı için).
- Durum değişir VE `chatSubscriptions[id] != nil` ise `chat_status` frame yollanır.
- Chat subscribe anında mevcut snapshot (`turnReducers[id]?.status ?? .idle`) yollanır.
- `.exited`'de reducer temizlenir; `shutdown`'da hepsi.

- [ ] **Step 1: Write the failing test**

`LumiPackages/Tests/LumiRemoteTests/RemoteServiceTurnStatusTests.swift`:
```swift
import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiRemote

@Suite @MainActor struct RemoteServiceTurnStatusTests {
    // NOT: makeSession + FakeRelayConnection + FakeTerminalServicing yardımcılarının
    // tam imzasını RemoteServiceTests.swift'ten kopyala. Session'ın meta'sında
    // claudeSessionID DOLU olmalı (chat moduna girsin). Aşağıdaki iskelet o kalıbı izler.

    @Test func hookDrivenStatusEmitsChatStatusToSubscriber() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let hooks = FakeAgentHookServer()
        let sid = makeChatSession(term)                     // claudeSessionID dolu session
        let id = term.terminals.first!.id

        let svc = RemoteService(
            paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []),
            hookEvents: hooks.events(),
            turnClock: { Date(timeIntervalSince1970: 100) }
        )
        await svc.start()

        // (a) subscribe (chat) → idle snapshot chat_status gelir
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat_status"])
        #expect(await conn.firstBool(type: "chat_status", key: "working") == false)

        // (b) userPromptSubmit → working=true, startedAtMs=100000
        hooks.emit(hookEvent(.userPromptSubmit, terminalID: id))
        try await conn.waitForSent(types: ["chat_status"], where: { $0["working"] as? Bool == true })
        #expect(await conn.lastInt(type: "chat_status", key: "startedAtMs") == 100_000)

        // (c) preToolUse Bash → tool=Bash
        hooks.emit(hookEvent(.preToolUse, terminalID: id, tool: "Bash"))
        try await conn.waitForSent(types: ["chat_status"], where: { $0["tool"] as? String == "Bash" })

        // (d) stop → working=false
        hooks.emit(hookEvent(.stop, terminalID: id))
        try await conn.waitForSent(types: ["chat_status"], where: { $0["working"] as? Bool == false })
        svc.stop()
    }

    @Test func noChatStatusForUnsubscribedSession() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let hooks = FakeAgentHookServer()
        _ = makeChatSession(term)
        let id = term.terminals.first!.id
        let svc = RemoteService(
            paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []),
            hookEvents: hooks.events()
        )
        await svc.start()
        hooks.emit(hookEvent(.userPromptSubmit, terminalID: id))   // abone yok
        // kısa bir settle sonrası hiç chat_status yollanmamalı
        try? await conn.waitForSent(types: ["chat_status"], timeout: .milliseconds(200))
        #expect(await conn.countSent(type: "chat_status") == 0)
        svc.stop()
    }

    private func hookEvent(_ kind: AgentHookEventKind, terminalID: TerminalID,
                           tool: String? = nil) -> AgentHookEvent {
        AgentHookEvent(provider: .claude, terminalID: terminalID, kind: kind, agentID: nil,
                       teammateName: nil, toolName: tool, source: nil, trigger: nil,
                       isInterrupt: false, promptHead: nil, runningBackgroundAgentIDs: nil,
                       receivedAt: Date(timeIntervalSince1970: 0))
    }
}
```

> Implementer notu: `FakeRelayConnection`'ın gerçek yardımcı imzalarını (`waitForSent`, `firstBool`/`lastInt`/`countSent`, `injectInbound`) `RemoteServiceTests.swift`'ten doğrula; eksik olan küçük yardımcıları (`where:` filtresi, `countSent`, `firstBool`, `lastInt`, `waitForSent(timeout:)`) `FakeRelayConnection`'a ekle — mevcut `firstString`/`waitForSent` kalıbını izleyerek. `makeChatSession`, `FakeTerminalServicing`'e claudeSessionID dolu bir session ekleyip `id.description` döndürmeli (mevcut `makeSession` yardımcısını temel al; FakeTerminalServicing'de claudeSessionID alanı yoksa meta oluşturma yardımcısına ekle).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteServiceTurnStatusTests`
Expected: FAIL — `RemoteService.init` `hookEvents`/`turnClock` bilmiyor (extra argument).

- [ ] **Step 3: Add stored properties + init params**

`RemoteService.swift`, mevcut property'lerin yanına (satır ~46 sonrası):
```swift
/// Faz 2: hook olay akışı + session başına turn-status reducer'ları.
private let hookEvents: AsyncStream<AgentHookEvent>
private let turnClock: @Sendable () -> Date
private var turnReducers: [TerminalID: TurnStatusReducer] = [:]
private var hookTask: Task<Void, Never>?
```

`init` imzasını genişlet (mevcut son parametre `trust`'tan sonra):
```swift
public init(
    paths: LumiPaths,
    terminal: any TerminalServicing,
    repos: any RepoServicing,
    connection: (any RelayConnecting)? = nil,
    chatSource: any ChatTranscriptSourcing,
    trust: any ClaudeWorkspaceTrusting = NoopClaudeWorkspaceTrust(),
    hookEvents: AsyncStream<AgentHookEvent> = AsyncStream { _ in },
    turnClock: @escaping @Sendable () -> Date = { Date() }
) {
```

init gövdesinin sonuna (satır ~61 `self.chatSource = chatSource` altına):
```swift
        self.hookEvents = hookEvents
        self.turnClock = turnClock
```

- [ ] **Step 4: Consume hook stream in `start()`**

`start()` içinde `terminalTask = ...` bloğundan sonra (satır ~86, `await connection.start(...)`'tan önce):
```swift
        hookTask = Task { [weak self] in
            for await event in hookEvents {
                await self?.handleHookEvent(event)
            }
        }
```

- [ ] **Step 5: Add hook handler + emit helper**

`emitChat(...)` fonksiyonunun altına (satır ~279):
```swift
    // MARK: - Turn status (Faz 2)

    private func handleHookEvent(_ event: AgentHookEvent) async {
        let id = event.terminalID
        let reducer = turnReducers[id] ?? {
            let r = TurnStatusReducer(now: turnClock)
            turnReducers[id] = r
            return r
        }()
        guard let status = reducer.reduce(event) else { return }
        guard chatSubscriptions[id] != nil else { return }
        await emitTurnStatus(id: id, status: status)
    }

    private func emitTurnStatus(id: TerminalID, status: ChatTurnStatus) async {
        await connection.send(
            type: "chat_status",
            payload: RemoteProtocol.chatStatusPayload(sessionId: id.description, status: status)
        )
    }
```

- [ ] **Step 6: Send snapshot on chat subscribe**

`handleSubscribe(...)` chat branşında, `chatSubscriptions[id] = task` satırından hemen sonra, `return`'den önce (satır ~241):
```swift
            let snapshot = turnReducers[id]?.status ?? .idle
            await emitTurnStatus(id: id, status: snapshot)
```

- [ ] **Step 7: Cleanup on exit + shutdown**

`handleTerminalEvent` `.exited` bloğuna (satır ~162, `modelCache[id] = nil` yanına):
```swift
                turnReducers[id] = nil
```

`shutdown()` içine (satır ~104, `chatSubscriptions.removeAll()` sonrası):
```swift
        hookTask?.cancel(); hookTask = nil
        turnReducers.removeAll()
```

- [ ] **Step 8: Wire assembly**

`RemoteFeatureAssembly.swift`, `RemoteService(...)` çağrısına `trust:` sonrası ekle:
```swift
        remoteService = RemoteService(
            paths: services.paths,
            terminal: services.terminal,
            repos: services.repo,
            chatSource: TranscriptChatSource(),
            trust: ClaudeWorkspaceTrust(),
            hookEvents: services.agentHooks.events()
        )
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests`
Expected: PASS (yeni turn-status testleri + mevcut RemoteService testleri).
Then: `cd LumiPackages && swift build` (assembly derlensin).
Expected: Build succeeds.

- [ ] **Step 10: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift LumiPackages/Tests/LumiRemoteTests/RemoteServiceTurnStatusTests.swift
git commit -m "feat(remote): RemoteService hook tap → chat_status yayını + subscribe snapshot"
```

---

### Task 5: Relay `chat_status` opak passthrough (Mac→telefon)

**Files:**
- Modify: `RelayServer/src/protocol.ts` (KNOWN_TYPES, ~satır 16-20)
- Modify: `RelayServer/src/bridge.ts` (`fromMac` switch, ~satır 46-81)
- Test: `RelayServer/test/bridge.test.ts` (chat testi yanına)

**Interfaces:**
- Produces: relay `chat_status` frame'ini `chat`/`chat_append` gibi oda içine broadcast eder; telefon→Mac yönünde işlenmez.

- [ ] **Step 1: Write the failing test**

`RelayServer/test/bridge.test.ts` içinde, mevcut "mac chat/chat_append → telefonlara broadcast" testinin altına:
```typescript
test('mac chat_status → telefonlara broadcast', () => {
  const { bridge } = setup()
  const phone = new FakeClient()
  bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))
  const macSession = bridge.handleHello(new FakeClient(), env('hello', { role: 'mac', token: TOKEN }))!

  bridge.handleMessage(macSession, env('chat_status', {
    sessionId: 's1', working: true, startedAtMs: 42, tool: 'Bash',
  }))
  expect(phone.last().type).toBe('chat_status')
  expect(phone.last().payload.sessionId).toBe('s1')
  expect(phone.last().payload.tool).toBe('Bash')
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd RelayServer && npm test`
Expected: FAIL — telefon `chat_status` almıyor (broadcast yok / tip bilinmiyor).

- [ ] **Step 3: Add to KNOWN_TYPES**

`RelayServer/src/protocol.ts`, `KNOWN_TYPES` set'ine `'chat_append'` yanına `'chat_status'` ekle:
```typescript
const KNOWN_TYPES = new Set([
  'hello', 'welcome', 'sessions', 'repos', 'subscribe', 'unsubscribe',
  'scrollback', 'data', 'chat', 'chat_append', 'chat_status', 'input', 'command', 'command_result',
  'register_push', 'unregister_push', 'ping', 'pong',
])
```

- [ ] **Step 4: Add fromMac broadcast case**

`RelayServer/src/bridge.ts`, `fromMac` switch'inde `case 'chat_append':` bloğunun altına:
```typescript
    case 'chat_status':
      this.broadcast(room, envelope('chat_status', env.payload))
      break
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd RelayServer && npm test`
Expected: PASS (yeni test + mevcut chat/isolation testleri; oda izolasyonu değişmez çünkü `broadcast(room, ...)` kalıbı aynı).

- [ ] **Step 6: Commit**

```bash
git add RelayServer/src/protocol.ts RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "feat(relay): chat_status opak passthrough (mac→telefon)"
```

---

### Task 6: LumiMobileKit `ChatTurnStatus` kopyası + `PhoneProtocol` decode

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatTurnStatus.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (`ServerMessage` enum + decode switch)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStatusDecodeTests.swift`

**Interfaces:**
- Produces: `public struct ChatTurnStatus: Sendable, Equatable` (LumiKit ile aynı alanlar) + `static func decode(_ dict: [String: Any]) -> ChatTurnStatus`; `PhoneProtocol.ServerMessage.chatStatus(sessionId: String, status: ChatTurnStatus)`.
- Consumes: Task 5 wire frame (`type == "chat_status"`).

- [ ] **Step 1: Write the failing test**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStatusDecodeTests.swift`:
```swift
import XCTest
@testable import LumiMobileKit

final class ChatStatusDecodeTests: XCTestCase {
    func testDecodeChatStatusFrame() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":true,"startedAtMs":42,"tool":"Bash"}}
        """#
        guard case let .chatStatus(sessionId, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(status, ChatTurnStatus(working: true, startedAtMs: 42, tool: "Bash"))
    }

    func testDecodeChatStatusIdleWithNulls() {
        let frame = #"""
        {"v":1,"type":"chat_status","payload":{"sessionId":"s1","working":false,"startedAtMs":null,"tool":null}}
        """#
        guard case let .chatStatus(_, status)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_status idle decode edilemedi")
        }
        XCTAssertEqual(status, .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatStatusDecodeTests`
Expected: FAIL — "cannot find 'ChatTurnStatus'" / `.chatStatus` yok.

- [ ] **Step 3: Add the mobile model copy**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatTurnStatus.swift`:
```swift
import Foundation

/// LumiKit `ChatTurnStatus`'un birebir telefon kopyası (decode yönü). Wire alanları:
/// working / startedAtMs / tool. sessionId frame zarfında taşınır.
public struct ChatTurnStatus: Sendable, Equatable {
    public let working: Bool
    public let startedAtMs: Int?
    public let tool: String?

    public init(working: Bool, startedAtMs: Int?, tool: String?) {
        self.working = working
        self.startedAtMs = startedAtMs
        self.tool = tool
    }

    public static let idle = ChatTurnStatus(working: false, startedAtMs: nil, tool: nil)

    static func decode(_ dict: [String: Any]) -> ChatTurnStatus {
        ChatTurnStatus(
            working: dict["working"] as? Bool ?? false,
            startedAtMs: dict["startedAtMs"] as? Int,
            tool: dict["tool"] as? String
        )
    }
}
```

- [ ] **Step 4: Add ServerMessage case + decode**

`PhoneProtocol.swift`, `ServerMessage` enum'ına `chatAppend` yanına (~satır 15-16):
```swift
    case chatStatus(sessionId: String, status: ChatTurnStatus)
```

`decodeServerMessage` switch'ine `"chat"`/`"chat_append"` case'inin altına:
```swift
    case "chat_status":
        guard let sessionId = payload["sessionId"] as? String else { return nil }
        return .chatStatus(sessionId: sessionId, status: ChatTurnStatus.decode(payload))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatStatusDecodeTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatTurnStatus.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatStatusDecodeTests.swift
git commit -m "feat(mobile): ChatTurnStatus kopyası + chat_status decode"
```

---

### Task 7: `AppModel.turnStatus` merge + ölü-oturum temizliği

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTurnStatusTests.swift`

**Interfaces:**
- Consumes: `ServerMessage.chatStatus` (Task 6), mevcut `handle(_:)` dispatcher, `applySessions(_:)` temizliği.
- Produces: `public private(set) var turnStatus: [String: ChatTurnStatus]`.

- [ ] **Step 1: Write the failing test**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTurnStatusTests.swift`:
```swift
import XCTest
@testable import LumiMobileKit

@MainActor
final class AppModelTurnStatusTests: XCTestCase {
    func testChatStatusMergesIntoTurnStatus() {
        let model = AppModel()
        model.handle(.chatStatus(sessionId: "s1",
            status: ChatTurnStatus(working: true, startedAtMs: 10, tool: "Read")))
        XCTAssertEqual(model.turnStatus["s1"], ChatTurnStatus(working: true, startedAtMs: 10, tool: "Read"))
    }

    func testDeadActiveSessionClearsTurnStatus() {
        let model = AppModel()
        model.handle(.chatStatus(sessionId: "s1", status: ChatTurnStatus(working: true, startedAtMs: 1, tool: nil)))
        model.setActiveSessionForTesting("s1")     // aktif oturum = s1 (yardımcı yoksa mevcut kalıbı kullan)
        model.handle(.sessions(sessions: []))       // s1 artık canlı değil
        XCTAssertNil(model.turnStatus["s1"])
    }
}
```

> Implementer notu: `AppModel()`'in test'ten construct edilebilirliğini ve aktif oturum set etme yolunu mevcut `LumiMobileKitTests` (ör. AppModel testleri) kalıbından doğrula. `activeSessionId` private ise, mevcut testlerdeki set-etme yöntemini (welcome/subscribe akışı ya da mevcut bir test yardımcısı) kullan; yoksa ikinci testi mevcut ölü-oturum test kalıbına uyarla. Eğer AppModel init dış bağımlılık istiyorsa (client vb.), mevcut AppModel testlerindeki construction'ı bire bir kopyala.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTurnStatusTests`
Expected: FAIL — `turnStatus` yok / `.chatStatus` handle edilmiyor.

- [ ] **Step 3: Add property**

`AppModel.swift`, `chatBySession` yanına (~satır 60):
```swift
    /// Faz 2: session başına canlı turn-status (chat_status frame'lerinden).
    public private(set) var turnStatus: [String: ChatTurnStatus] = [:]
```

- [ ] **Step 4: Handle the message**

`handle(_ message:)` switch'inde `.chatAppend` case'inin altına (~satır 188):
```swift
        case .chatStatus(let sessionId, let status):
            turnStatus[sessionId] = status
```

- [ ] **Step 5: Clear on dead active session**

`applySessions(_:)` içinde, aktif oturum ölünce yapılan temizliğe (`chatBySession[active] = nil` yanına, ~satır 231):
```swift
            turnStatus[active] = nil
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTurnStatusTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTurnStatusTests.swift
git commit -m "feat(mobile): AppModel.turnStatus merge + ölü-oturum temizliği"
```

---

### Task 8: `MobileChatView` turn-status bandı + Stop (SwiftUI)

**Files:**
- Create: `LumiMobile/App/TurnStatusBar.swift`
- Modify: `LumiMobile/App/MobileChatView.swift` (ScrollView ile composer arası)
- Modify: `LumiMobile/project.yml` gerekmez; ama yeni `App/` dosyası için `xcodegen generate` ŞART (App target `sources: [App]`).

**Interfaces:**
- Consumes: `model.turnStatus[sessionId]` (Task 7), `model.sendInput(_:_:)` (Ctrl-C 0x03), `ChatTurnStatus` (Task 6).
- Bu görsel task; birim testi YOK (SwiftUI). Doğrulama = derleme + cihaz.

- [ ] **Step 1: Create the bar view**

`LumiMobile/App/TurnStatusBar.swift`:
```swift
import SwiftUI
import LumiMobileKit

/// Faz 2: chat composer'ının üstünde canlı turn-status bandı. working iken görünür.
/// Sol: spinner + "Çalışıyor {n}sn" (TimelineView ile canlı). Orta: araç çipi.
/// Sağ: Stop → Ctrl-C (0x03).
struct TurnStatusBar: View {
    let status: ChatTurnStatus
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedLabel(now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let tool = status.tool {
                    Text(tool)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button("Durdur", role: .destructive) { onStop() }
                    .font(.footnote.bold())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func elapsedLabel(now: Date) -> String {
        guard let startedAtMs = status.startedAtMs else { return "Çalışıyor" }
        let started = Date(timeIntervalSince1970: Double(startedAtMs) / 1000)
        let secs = max(0, Int(now.timeIntervalSince(started)))
        return "Çalışıyor \(secs)sn"
    }
}
```

- [ ] **Step 2: Insert into MobileChatView**

`MobileChatView.swift`, `body`'de `ScrollViewReader { ... }` bloğu ile `composer` arasına (~satır 38-39):
```swift
            if let status = model.turnStatus[sessionId], status.working {
                TurnStatusBar(status: status) {
                    model.sendInput(sessionId, Data([0x03]))
                }
            }
```

> Not: `sessionId` `MobileChatView`'de zaten mevcut (`.task(id: sessionId)`). `model` de mevcut (`@Bindable`/`@Environment` — mevcut kullanıma bak). `Data` için dosyada `import Foundation` yoksa ekle.

- [ ] **Step 3: Regenerate Xcode project + build**

Run:
```bash
cd LumiMobile && xcodegen generate
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build
```
Expected: Build succeeds (yeni `TurnStatusBar.swift` derlenir).

> `xcodegen generate` UNUTULURSA build bayat proje yüzünden kırılır (memory: ios-xcodeproj-is-generated).

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/TurnStatusBar.swift LumiMobile/App/MobileChatView.swift
git commit -m "feat(mobile): canlı turn-status bandı + Stop (Ctrl-C)"
```

---

### Task 9: Full build + test sweep + device handoff

**Files:** yok (doğrulama).

- [ ] **Step 1: LumiPackages full test**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi`
Expected: Tümü yeşil (yeni + mevcut).

- [ ] **Step 2: LumiMobileKit test**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: Tümü yeşil.

- [ ] **Step 3: Relay test**

Run: `cd RelayServer && npm test`
Expected: Tümü yeşil.

- [ ] **Step 4: Release build (CI paritesi)**

Run: `cd LumiPackages && swift build -c release --product Lumi`
Expected: Build succeeds.

- [ ] **Step 5: Kullanıcıya devir (KRİTİK — launch-env kuralı)**

Mac uygulamasını Claude Code bash'ından BAŞLATMA. Kullanıcıdan iste:
- `Scripts/make-rework-app.sh` ile paketle (veya mevcut kurulu app'i güncelle), **kendisi Finder/Dock'tan** temiz env'de başlatsın.
- iOS: `cd LumiMobile && xcodegen generate` → Xcode/`xcodebuild` ile cihaza `devicectl install`.
- Relay değişikliği canlıya gerekiyorsa Railway deploy (yalnız `chat_status` passthrough eklendi — geriye uyumlu).

- [ ] **Step 6: Cihaz doğrulama senaryoları (kullanıcı)**

- Telefondan başlatılan bir oturumda prompt gönder → composer üstünde "Çalışıyor {n}sn" bandı çıkar, sayaç canlı artar.
- Bir araç koşarken (ör. Bash/Read) araç çipi görünür, sonuç düşünce kaybolur.
- **Durdur**'a bas → gerçek Stop event'iyle bant kaybolur (optimistic yok; spec §5).
- Reconnect (chat modda) → bant doğru snapshot'la yeniden görünür.
- `/clear` → bant sıfırlanır.

---

## Self-Review

**Spec coverage:**
- §1 "Çalışıyor {n}sn" + araç çipi + Stop → Task 8 (bant/çip/Stop), Task 2 (working+startedAtMs+tool türetimi). ✓
- §1 kapsam dışı token-token metin → uygulanmadı (kasıtlı). ✓
- §4.1 `ChatTurnStatus` (LumiKit + LumiMobileKit kopyası) → Task 1 + Task 6. ✓
- §4.2 `TurnStatusReducer` + enjekte saat + idempotent → Task 2. ✓
- §4.3 RemoteService entegrasyonu: hook enjeksiyonu, tek tüketici Task, subscribe snapshot, exit/unsubscribe/clear temizliği, working için tek otorite hook → Task 4 (+ §4.3 not: SessionMeta.status OKUNMAZ — reducer'a bağlı, sağlandı). ✓
- §4.4 `chat_status` frame (RemoteProtocol + PhoneProtocol + relay allowlist) → Task 3, Task 6, Task 5. ✓
- §4.5 telefon AppModel `turnStatus` + gizli-oturum temizliği + bant + Stop + mobil literaller → Task 7, Task 8. ✓
- §5 bayat working (heartbeat YOK) → uygulanmadı (kasıtlı, sonraki snapshot düzeltir); §5 optimistic-Stop YOK → Task 8'de gerçek event beklenir; §5 /clear reset → Task 2 `sessionStart source=clear`; §5 reconnect snapshot → Task 4 Step 6; §5 çoklu-session izolasyonu → reducer session başına + `chatSubscriptions[id]` gate (Task 4) + relay oda izolasyonu (Task 5). ✓
- §6 test stratejisi: reducer birim (Task 2), RemoteService+fake hook+abone (Task 4), AppModel merge (Task 7), wire relay (Task 5). ✓ (Not: `FakeAgentHookEventStream` yerine mevcut `FakeAgentHookServer` — gerekçe yukarıda.)
- §8 dosya envanteri → 2 kasıtlı sapma (LumiKit reducer, fake reuse) belgelendi.
- §9 build/doğrulama → Task 9.

**Placeholder scan:** Kod adımları tam kod içeriyor. İki yerde implementer'a "mevcut yardımcı imzasını doğrula" notu var (FakeRelayConnection yardımcıları, AppModel test construction) — bunlar codebase'e özgü test iskele detayları, placeholder değil yönlendirme.

**Type consistency:** `ChatTurnStatus(working:startedAtMs:tool:)` iki modülde aynı; `TurnStatusReducer.reduce(_:) -> ChatTurnStatus?` Task 2↔4 tutarlı; `chatStatusPayload(sessionId:status:)` Task 3↔4; `ServerMessage.chatStatus(sessionId:status:)` Task 6↔7; frame `type` string'i her katmanda `"chat_status"`; wire alanları `working`/`startedAtMs`/`tool`/`sessionId` her yerde aynı. ✓

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-15-faz2-canli-turn-status.md`.**
