# Çalışan Model Seçici Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Oturumun çalıştığı Claude modelini mobilde göstermek ve Opus/Sonnet/Haiku/Default arasından değiştirebilmek.

**Architecture:** Mac, jsonl assistant kayıtlarının `message.model` alanını okuyup per-session bir model sinyali üretir (snapshot `model` alanı + `model_change` event) — Spec 2'nin `awaiting_decision` kalıbı. Değiştirme için yeni `set_model` komutu terminale `/model <alias>` yazar. Telefon oturum detayı toolbar'ında bir Menu ile gösterir/değiştirir.

**Tech Stack:** Swift 6, SwiftUI, XCTest. Modüller: `LumiRemote` (Mac), `LumiMobileKit` (mobil), `LumiMobile/App` (SwiftUI). İzole worktree: `Lumi-worktrees/model-picker` (branch `model-picker`, main'den Spec 1+2 dahil).

## Global Constraints

- Swift 6 strict concurrency; mobil `@Observable @MainActor`, Combine yok.
- Protokol codec `docs/spec/50-remote-protocol.md` ile birebir; gelen taraf toleranslı (bilinmeyen event kind / eksik alan akışı kırmaz; eksik `model` → nil).
- Picker alias'ları: `opus`, `sonnet`, `haiku`, `default`. Mac allowlist bunlarla sınırlı; bilinmeyen → `unknown_model`.
- Model değiştirme: Mac terminale `/model <alias>\r` yazar (PTY girdisi; shell-exec değil).
- Güncel model kaynağı: jsonl `message.model` (gerçek çalışan model).
- Komut id formatı: `"ph-\(commandCounter)"`.
- Model kalıcı bilgidir: statusChange working/idle model'i SİLMEZ.
- `docs/spec/50-remote-protocol.md` bağlayıcıdır; protokol değişikliği orada da güncellenir.
- Tüm iş `Lumi-worktrees/model-picker` worktree'sinde; commit'ler `model-picker` dalına.

---

### Task 1: Mac — güncel model sinyali (TranscriptParser + RemoteService + SnapshotBuilder + spec)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/TranscriptParser.swift` (FeedItem `.model` + parse + itemPayload)
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (currentModel, handleFeedItem intercept→internal, model_change, get_history filter, stopWatcher, sendSnapshot)
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift` (snapshot model alanı + modelChangeEvent)
- Modify: `docs/spec/50-remote-protocol.md`
- Create: `LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: mevcut `FeedItem`, `handleFeedItem`, `SnapshotBuilder.snapshot(...awaitingDecision:)`, watcher stream.
- Produces:
  - Mac `FeedItem.model(String)`
  - Wire event `{kind:"model_change", sessionId, model}`
  - Snapshot session entry opsiyonel `model: String`
  - `SnapshotBuilder.modelChangeEvent(sessionId:model:) -> [String: Any]`
  - `SnapshotBuilder.snapshot(...currentModel: [TerminalID: String] = [:])`
  - `RemoteService.handleFeedItem` artık `internal` (test erişimi)

- [ ] **Step 1: TranscriptParser testlerini yaz (yeni dosya, başarısız olacak)**

`LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift`:

```swift
import XCTest
@testable import LumiRemote

final class TranscriptParserTests: XCTestCase {
    func testParseExtractsModelFromAssistant() {
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}]}}"#
        let items = TranscriptParser.parse(line: line)
        XCTAssertTrue(items.contains(.model("claude-opus-4-8")), "model çıkarılmalı")
        XCTAssertTrue(items.contains(.assistantText("hi")))
    }

    func testParseNoModelWhenAbsent() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        let items = TranscriptParser.parse(line: line)
        XCTAssertFalse(items.contains { if case .model = $0 { return true }; return false })
    }
}
```

- [ ] **Step 2: RemoteService/SnapshotBuilder testlerini yaz (RemoteServiceTests'e ekle, başarısız olacak)**

Önce `FakeConnection` actor'ına sorgu yardımcıları ekle:

```swift
func modelChangeEvent() -> (sessionId: String, model: String)? {
    guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "model_change" })
    else { return nil }
    return ((e.payload["sessionId"] as? String) ?? "", (e.payload["model"] as? String) ?? "")
}
func modelChangeEventCount() -> Int {
    sent.filter { $0.type == "event" && ($0.payload["kind"] as? String) == "model_change" }.count
}
func snapshotFirstSessionModel() -> String? {
    guard let snap = sent.last(where: { $0.type == "snapshot" }),
          let sessions = snap.payload["sessions"] as? [[String: Any]],
          let first = sessions.first else { return nil }
    return first["model"] as? String
}
```

Testler (`RemoteServiceTests` sınıfına):

```swift
func testModelChangeEventShape() {
    let e = SnapshotBuilder.modelChangeEvent(sessionId: "s1", model: "claude-opus-4-8")
    XCTAssertEqual(e["kind"] as? String, "model_change")
    XCTAssertEqual(e["sessionId"] as? String, "s1")
    XCTAssertEqual(e["model"] as? String, "claude-opus-4-8")
}

func testModelFeedItemEmitsChangeOnceAndSnapshotCarriesIt() async throws {
    let connection = FakeConnection()
    let terminal = FakeTerminal()
    let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
    let service = makeService(connection: connection, terminal: terminal)
    await service.start(); await drain()

    await service.handleFeedItem(.model("claude-opus-4-8"), sessionId: meta.id)
    let ev = await connection.modelChangeEvent()
    XCTAssertEqual(ev?.sessionId, meta.id.description)
    XCTAssertEqual(ev?.model, "claude-opus-4-8")

    // aynı model tekrar → yeni event yok
    await service.handleFeedItem(.model("claude-opus-4-8"), sessionId: meta.id)
    XCTAssertEqual(await connection.modelChangeEventCount(), 1)

    // snapshot güncel modeli taşır
    await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
    await drain()
    XCTAssertEqual(await connection.snapshotFirstSessionModel(), "claude-opus-4-8")
    service.stop()
}

func testGetHistoryExcludesModelItem() async throws {
    let connection = FakeConnection()
    let terminal = FakeTerminal()
    let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
    let projectDir = tempHome.appendingPathComponent("transcripts")
        .appendingPathComponent(TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"gecmis"}]}}"#
    try (line + "\n").data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s1.jsonl"))

    let service = makeService(connection: connection, terminal: terminal)
    await service.start(); await drain()
    await connection.push(.message(type: "command", payload: [
        "commandId": "h-9", "action": "get_history", "sessionId": meta.id.description,
    ]))
    await drain()

    let history = await connection.historyEvent()
    XCTAssertEqual(history?.itemCount, 1, "model öğesi history'den elenmeli, yalnız metin kalmalı")
    XCTAssertEqual(await connection.historyFirstItemText(), "gecmis")
    service.stop(); await drain()
}
```

- [ ] **Step 3: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiPackages && swift test --filter LumiRemoteTests`
Expected: FAIL — `FeedItem.model` yok (derleme hatası), `handleFeedItem` private (erişilemez), `modelChangeEvent`/`currentModel` yok.

- [ ] **Step 4: `TranscriptParser.swift` — `.model` case + parse + itemPayload**

`FeedItem` enum'una case ekle:

```swift
public enum FeedItem: Equatable, Sendable {
    case assistantText(String)
    case toolUse(name: String, summary: String)
    case question(payload: [Question])
    case turnDone
    case model(String)
}
```

`itemPayload` switch'ine ekle:

```swift
case .model(let model):
    return ["itemType": "model", "model": model]
```

`parse(line:)` içinde, `var items: [FeedItem] = []` satırından hemen sonra:

```swift
if let model = message["model"] as? String, !model.isEmpty {
    items.append(.model(model))
}
```

- [ ] **Step 5: `SnapshotBuilder.swift` — model alanı + event helper**

`snapshot(...)` imzasına parametre ekle (awaitingDecision'dan sonra):

```swift
static func snapshot(
    terminals: [TerminalMeta],
    repos: [Repo],
    personas: [Persona],
    awaitingDecision: [TerminalID: Bool] = [:],
    currentModel: [TerminalID: String] = [:]
) -> [String: Any] {
```

entry oluşturmada `awaitingDecision` satırının yanına:

```swift
if let model = currentModel[meta.id] { entry["model"] = model }
```

Yeni event helper (awaitingDecisionEvent yanına):

```swift
static func modelChangeEvent(sessionId: String, model: String) -> [String: Any] {
    ["kind": "model_change", "sessionId": sessionId, "model": model]
}
```

- [ ] **Step 6: `RemoteService.swift` — currentModel + handleFeedItem intercept + filter + snapshot**

`awaitingDecision` alanının yanına:

```swift
private var currentModel: [TerminalID: String] = [:]
```

`handleFeedItem`'ı `private` yerine `internal` yap (imzadan `private` kaldır) ve `.model` case'ini ekle:

```swift
func handleFeedItem(_ item: FeedItem, sessionId: TerminalID) async {
    switch item {
    case .question(let questions):
        lastSummary[sessionId] = questions.first?.question
    case .toolUse(let name, let summary):
        lastSummary[sessionId] = summary.isEmpty ? name : "\(name): \(summary)"
    case .model(let model):
        // model sinyaldir, transcript öğesi değil → telefona transcript olarak gitmez
        guard currentModel[sessionId] != model else { return }
        currentModel[sessionId] = model
        await connection.send(type: "event",
            payload: SnapshotBuilder.modelChangeEvent(sessionId: sessionId.description, model: model))
        return
    default:
        break
    }
    await connection.send(type: "event", payload: item.eventPayload(sessionId: sessionId.description))
}
```

`stopWatcher(for:)` içine (`awaitingDecision[id] = nil` yanına):

```swift
currentModel[id] = nil
```

`handleGetHistory` içinde `items.map(\.itemPayload)` satırını modele göre filtreye çevir:

```swift
"kind": "history", "sessionId": raw,
"items": items.filter { if case .model = $0 { return false }; return true }.map(\.itemPayload),
```

`sendSnapshot()` içindeki `SnapshotBuilder.snapshot(...)` çağrısına ekle:

```swift
awaitingDecision: awaitingDecision, currentModel: currentModel)
```

- [ ] **Step 7: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiPackages && swift test`
Expected: hepsi yeşil (yeni parser + RemoteService testleri; mevcut get_history/transcript testleri korunur), 0 warning.

- [ ] **Step 8: `docs/spec/50-remote-protocol.md`'i güncelle**

Event bölümüne (awaiting_decision yanına) ekle:

```markdown
### `model_change`
`{ "kind": "model_change", "sessionId": "<uuid>", "model": string }` — Mac, son assistant transcript kaydının `message.model` alanından çıkardığı güncel modeli, değiştiğinde bildirir. Relay bakmaz (push yalnız `status_change`).
```

Snapshot session şekline: opsiyonel `model?: string` (son bilinen çalışan model; yok → bilinmiyor).

- [ ] **Step 9: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/TranscriptParser.swift \
        LumiPackages/Sources/LumiRemote/RemoteService.swift \
        LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift \
        LumiPackages/Tests/LumiRemoteTests/TranscriptParserTests.swift \
        LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift \
        docs/spec/50-remote-protocol.md
git commit -m "remote: güncel model sinyali (message.model → model_change event + snapshot)"
```

---

### Task 2: Mac — `set_model` komutu (RemoteCommandHandler + spec)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`
- Modify: `docs/spec/50-remote-protocol.md`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift`

**Interfaces:**
- Consumes: mevcut `result(_:run:)`, `session(from:)`, `terminal.write(id:text:)`.
- Produces: `set_model` action → `terminal.write(id, "/model <alias>\r")`; allowlist `{opus,sonnet,haiku,default}`; hatalar `unknown_model`, `session_not_found`.

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`RemoteCommandHandlerTests.swift`'e ekle:

```swift
func testSetModelWritesSlashModel() async {
    let (handler, terminal) = makeHandler()
    let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
    let result = await handler.handle([
        "commandId": "m1", "action": "set_model",
        "sessionId": meta.id.description, "model": "opus",
    ])
    XCTAssertEqual(result["ok"] as? Bool, true)
    XCTAssertEqual(terminal.writes.last?.1, "/model opus\r")
}

func testSetModelUnknownModelRejected() async {
    let (handler, terminal) = makeHandler()
    let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
    let result = await handler.handle([
        "commandId": "m2", "action": "set_model",
        "sessionId": meta.id.description, "model": "gpt-4",
    ])
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["error"] as? String, "unknown_model")
    XCTAssertTrue(terminal.writes.isEmpty, "geçersiz model terminale yazılmamalı")
}

func testSetModelUnknownSessionFails() async {
    let (handler, _) = makeHandler()
    let result = await handler.handle([
        "commandId": "m3", "action": "set_model",
        "sessionId": UUID().uuidString, "model": "sonnet",
    ])
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["error"] as? String, "session_not_found")
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests`
Expected: FAIL — `set_model` işlenmiyor → `unknown_action`.

- [ ] **Step 3: `RemoteCommandHandler`'a case + allowlist ekle**

Sınıf gövdesine (diğer `private static let` / özelliklerin yanına):

```swift
private static let allowedModels: Set<String> = ["opus", "sonnet", "haiku", "default"]
```

`handle(_:)` switch'ine (delete_session yanına):

```swift
case "set_model":
    let model = payload["model"] as? String ?? ""
    guard Self.allowedModels.contains(model) else {
        return ["commandId": commandId, "ok": false, "error": "unknown_model"]
    }
    return result(commandId, run: {
        let id = try self.session(from: payload)
        try self.terminal.write(id: id, text: "/model \(model)\r")
    })
```

- [ ] **Step 4: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests`
Expected: PASS.

- [ ] **Step 5: `docs/spec/50-remote-protocol.md`'i güncelle**

Komut aksiyonları listesine ekle:

```markdown
- `set_model {commandId, sessionId, model}` — çalışan oturumun modelini değiştirir; Mac terminale `/model <model>` yazar. `model` ∈ `opus|sonnet|haiku|default`. Hatalar: `session_not_found`, `unknown_model`.
```

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift \
        LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift \
        docs/spec/50-remote-protocol.md
git commit -m "remote: set_model komutu (/model <alias>, allowlist)"
```

---

### Task 3: Mobil decode — `SessionSummary.model` + `RemoteEvent.modelChange` + `set_model` frame

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (yalnız geçici exhaustiveness stub)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: wire `model_change` event + snapshot `model` alanı (Task 1) + `set_model` komut şekli (Task 2).
- Produces:
  - `SessionSummary.model: String?` (Decodable, yoksa nil; memberwise init'te varsayılan nil)
  - `RemoteEvent.modelChange(sessionId: String, model: String)`
  - `CommandAction.setModel(sessionId: String, model: String)` + commandFrame `{action:"set_model", sessionId, model}`
  - Geçici `case .event(.modelChange): break` stub AppModel.handle'da (Task 4 değiştirir)

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`ProtocolTests.swift`'e ekle:

```swift
func testDecodeModelChangeEvent() {
    let text = #"{"v":1,"type":"event","payload":{"kind":"model_change","sessionId":"s1","model":"claude-opus-4-8"}}"#
    guard case .event(.modelChange(let id, let model))? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("model_change bekleniyordu")
    }
    XCTAssertEqual(id, "s1")
    XCTAssertEqual(model, "claude-opus-4-8")
}

func testDecodeSnapshotSessionModel() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"working","model":"claude-sonnet-4-6"}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("snapshot bekleniyordu")
    }
    XCTAssertEqual(snapshot.sessions[0].model, "claude-sonnet-4-6")
}

func testDecodeSnapshotSessionModelNilWhenAbsent() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle"}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("snapshot bekleniyordu")
    }
    XCTAssertNil(snapshot.sessions[0].model)
}

func testEncodeSetModelCommand() throws {
    let frame = PhoneProtocol.commandFrame(
        OutgoingCommand(commandId: "m9", action: .setModel(sessionId: "s1", model: "sonnet")))
    let data = try XCTUnwrap(frame.data(using: .utf8))
    let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try XCTUnwrap(dict["payload"] as? [String: Any])
    XCTAssertEqual(payload["action"] as? String, "set_model")
    XCTAssertEqual(payload["sessionId"] as? String, "s1")
    XCTAssertEqual(payload["model"] as? String, "sonnet")
    XCTAssertEqual(payload["commandId"] as? String, "m9")
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: FAIL — `RemoteEvent.modelChange`, `SessionSummary.model`, `CommandAction.setModel` yok (derleme hatası).

- [ ] **Step 3: `Models.swift` — SessionSummary.model + RemoteEvent.modelChange**

`SessionSummary`'ye alan + init parametresi + CodingKeys + init(from:) satırı ekle. Güncel hâli:

```swift
public struct SessionSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let repoPath: String
    public let repoName: String
    public var status: SessionStatus
    public let title: String?
    public let awaitingDecision: Bool
    public let model: String?

    public init(id: String, repoPath: String, repoName: String,
                status: SessionStatus, title: String? = nil,
                awaitingDecision: Bool = false, model: String? = nil) {
        self.id = id
        self.repoPath = repoPath
        self.repoName = repoName
        self.status = status
        self.title = title
        self.awaitingDecision = awaitingDecision
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoPath, repoName, status, title, awaitingDecision, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            repoPath: try c.decode(String.self, forKey: .repoPath),
            repoName: try c.decode(String.self, forKey: .repoName),
            status: try c.decode(SessionStatus.self, forKey: .status),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            awaitingDecision: try c.decodeIfPresent(Bool.self, forKey: .awaitingDecision) ?? false,
            model: try c.decodeIfPresent(String.self, forKey: .model)
        )
    }
}
```

`RemoteEvent`'e case ekle:

```swift
case awaitingDecision(sessionId: String, awaiting: Bool)
case modelChange(sessionId: String, model: String)
```

- [ ] **Step 4: `PhoneProtocol.swift` — decode + CommandAction + commandFrame**

`decodeEvent(_:)` switch'ine (`awaiting_decision` yanına, `default:` öncesi):

```swift
case "model_change":
    guard let model = payload["model"] as? String else { return nil }
    return .modelChange(sessionId: sessionId, model: model)
```

`CommandAction`'a case:

```swift
case setModel(sessionId: String, model: String)
```

`commandFrame`'in switch'ine:

```swift
case .setModel(let sessionId, let model):
    payload["action"] = "set_model"
    payload["sessionId"] = sessionId
    payload["model"] = model
```

- [ ] **Step 5: `AppModel.swift` — geçici exhaustiveness stub**

`handle`'ın event switch'ine (`.awaitingDecision` case'inin yanına) geçici stub ekle:

```swift
case .event(.modelChange):
    break // TODO(Task 4): models[sessionId] = model
```

- [ ] **Step 6: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: hepsi yeşil (tüm suite), 0 warning.

- [ ] **Step 7: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "mobile: model_change + SessionSummary.model decode + set_model frame"
```

---

### Task 4: Mobil AppModel — model durumu + setModel + prettify

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `RemoteEvent.modelChange`, `SessionSummary.model` (Task 3), `CommandAction.setModel` (Task 3), mevcut `dispatch`.
- Produces:
  - `AppModel.currentModel(for: String) -> String?`
  - `AppModel.setModel(sessionId: String, model: String) async`
  - `AppModel.modelLabel(_ raw: String) -> String` (public; UI kullanır)

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`AppModelTests.swift`'e ekle:

```swift
// MARK: Model seçici (Spec 3)

func testModelChangeEventSetsCurrentModel() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    model.handle(.event(.modelChange(sessionId: "s1", model: "claude-opus-4-8")))
    XCTAssertEqual(model.currentModel(for: "s1"), "claude-opus-4-8")
}

func testSnapshotAppliesModel() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [
        SessionSummary(id: "s1", repoPath: "/r/lumi", repoName: "lumi", status: .working, model: "claude-sonnet-4-6"),
    ], repos: [], personas: [])))
    XCTAssertEqual(model.currentModel(for: "s1"), "claude-sonnet-4-6")
}

func testStatusWorkingDoesNotClearModel() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    model.handle(.event(.modelChange(sessionId: "s1", model: "claude-opus-4-8")))
    model.handle(.event(.statusChange(sessionId: "s1", status: .idle, repoName: "lumi", summary: nil)))
    XCTAssertEqual(model.currentModel(for: "s1"), "claude-opus-4-8", "model kalıcı bilgidir")
}

func testSetModelDispatchesCommand() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    await model.setModel(sessionId: "s1", model: "sonnet")
    XCTAssertEqual(client.commands.count, 1)
    guard case .setModel(let sid, let m) = client.commands[0].action else { return XCTFail() }
    XCTAssertEqual(sid, "s1")
    XCTAssertEqual(m, "sonnet")
}

func testModelLabelPrettify() {
    let (model, _, _) = makeModel()
    XCTAssertEqual(model.modelLabel("claude-opus-4-8"), "Opus")
    XCTAssertEqual(model.modelLabel("claude-sonnet-4-6"), "Sonnet")
    XCTAssertEqual(model.modelLabel("claude-haiku-4-5"), "Haiku")
    XCTAssertEqual(model.modelLabel("weird-id"), "weird-id")
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `currentModel`, `setModel`, `modelLabel` yok; `models` durumu yok.

- [ ] **Step 3: `AppModel.swift` — model durumu + API**

Yeni alan (`decisionPending` yanına):

```swift
private var models: [String: String] = [:]
```

`handle`'daki geçici stub'ı gerçek mantıkla DEĞİŞTİR:

```swift
case .event(.modelChange(let sessionId, let model)):
    macOnline = true
    models[sessionId] = model
```

`apply(_ snapshot:)` içine (liveIds hesaplandıktan sonra):

```swift
models = models.filter { liveIds.contains($0.key) }
for s in snapshot.sessions {
    if let m = s.model { models[s.id] = m }
}
```

`unpair()` içine:

```swift
models = [:]
```

Komutlar bölümüne API:

```swift
public func currentModel(for sessionId: String) -> String? {
    models[sessionId]
}

public func setModel(sessionId: String, model: String) async {
    await dispatch(target: sessionId, action: .setModel(sessionId: sessionId, model: model))
}

/// Ham model id'sini kısa etikete indirger (UI).
public func modelLabel(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("opus") { return "Opus" }
    if lower.contains("sonnet") { return "Sonnet" }
    if lower.contains("haiku") { return "Haiku" }
    return raw
}
```

- [ ] **Step 4: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: hepsi yeşil, 0 warning.

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: model durumu + setModel + prettify etiketi"
```

---

### Task 5: Mobil UI — toolbar model Menu

**Files:**
- Modify: `LumiMobile/App/SessionDetailView.swift`

**Interfaces:**
- Consumes: `AppModel.currentModel(for:)`, `AppModel.modelLabel(_:)`, `AppModel.setModel(sessionId:model:)` (Task 4), `model.macOnline`.
- Produces: toolbar'da mevcut modeli gösteren + değiştiren Menu.

- [ ] **Step 1: Toolbar'a model Menu ekle**

`SessionDetailView.body`'deki `.toolbar { ... }` bloğuna, mevcut StatusBadge `ToolbarItem`'ının yanına yeni bir `ToolbarItem` ekle:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Menu {
        Button("Opus") { Task { await model.setModel(sessionId: sessionId, model: "opus") } }
        Button("Sonnet") { Task { await model.setModel(sessionId: sessionId, model: "sonnet") } }
        Button("Haiku") { Task { await model.setModel(sessionId: sessionId, model: "haiku") } }
        Button("Default") { Task { await model.setModel(sessionId: sessionId, model: "default") } }
    } label: {
        if let raw = model.currentModel(for: sessionId) {
            Text(model.modelLabel(raw))
        } else {
            Image(systemName: "cpu")
        }
    }
    .disabled(!model.macOnline)
    .accessibilityIdentifier("modelMenu")
}
```

(Mevcut StatusBadge ToolbarItem'ı ve diğer her şey değişmeden kalır.)

- [ ] **Step 2: Derle**

Run: `xcodebuild -project LumiMobile/LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED. (Gerekirse `xcrun simctl list devices available` ile bir simülatör seç.)

- [ ] **Step 3: Manuel doğrulama**

Gerçek Lumi'de bir oturum aç → toolbar'da güncel model (ör. "Opus") görünür. Menu'den "Sonnet" seç → Mac terminalinde `/model sonnet` çalışır; sonraki assistant yanıtıyla `model_change` gelir ve Menu "Sonnet" olur.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/SessionDetailView.swift
git commit -m "mobile: oturum detayı toolbar'ında model seçici Menu"
```

---

## Self-Review

**Spec coverage:**
- Mac güncel model (jsonl parse + snapshot + model_change) → Task 1. ✓
- set_model komutu + allowlist → Task 2. ✓
- Protokol (model_change event, snapshot model, set_model) → Task 1 Step 8 + Task 2 Step 5. ✓
- Mobil decode (SessionSummary.model, RemoteEvent.modelChange, CommandAction.setModel) → Task 3. ✓
- Mobil AppModel (models, apply, event, unpair, currentModel, setModel, prettify) → Task 4. ✓
- UI toolbar Menu → Task 5. ✓
- Karar: model kalıcı (statusChange silmez) → Task 4 testStatusWorkingDoesNotClearModel. ✓

**Placeholder scan:** Tüm adımlar gerçek kod/komut; TBD yok. Geçici stub (Task 3) bilinçli ve Task 4'te değiştiriliyor. ✓

**Type consistency:**
- `FeedItem.model(String)` (Task 1) — Mac-içi; mobil FeedItem'a EKLENMEZ (model event/snapshot ile gelir). ✓
- `SnapshotBuilder.snapshot(...currentModel:)` + `modelChangeEvent` (Task 1) ← RemoteService çağrısı. ✓
- `handleFeedItem` internal (Task 1) ← RemoteServiceTests doğrudan çağırır. ✓
- Wire `"model_change"` / `"set_model"` (Task 1/2 üretim) = decode/encode (Task 3). ✓
- `SessionSummary.model: String?` + init varsayılanı (Task 3) ← Task 4 apply + testler. ✓
- `RemoteEvent.modelChange(sessionId:model:)` (Task 3) ← Task 4 handle (stub değişimi). ✓
- `CommandAction.setModel(sessionId:model:)` (Task 3) ← Task 4 setModel + Task 2 Mac string `"set_model"`. ✓
- `currentModel(for:)` / `modelLabel(_:)` / `setModel(...)` (Task 4) ← Task 5 UI. ✓
- allowlist alias'ları `opus/sonnet/haiku/default` (Task 2) = UI butonları (Task 5) = picker listesi. ✓
