# Tool-use İzin Promptu Görünürlüğü Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code'un tool-use izin promptlarını (yetki isteği) telefonda güvenilir bir "İzin isteği" kartıyla göstermek ve Evet / Evet-sorma / Hayır ile cevaplanabilir kılmak.

**Architecture:** Mac zaten izin isteğini `TerminalEvent.awaitingDecisionChanged(id, Bool)` ile üretiyor ama `RemoteService` bunu düşürüyor. Bu sinyali telefona ilet (yeni `awaiting_decision` event + snapshot alanı). Telefon `decisionPending` durumunu tutar ve rozetten bağımsız bir izin kartı gösterir; içerik için feed'deki son `tool_use` özeti kullanılır (yeni parse yok).

**Tech Stack:** Swift 6, SwiftUI, XCTest. Modüller: `LumiRemote` (Mac), `LumiMobileKit` (mobil çekirdek), `LumiMobile/App` (SwiftUI).

## Global Constraints

- Swift 6 strict concurrency; mobil `@Observable @MainActor`, Combine yok.
- Protokol codec `docs/spec/50-remote-protocol.md` ile birebir; gelen taraf toleranslı (bilinmeyen event kind / eksik alan akışı kırmaz; eksik `awaiting`/`awaitingDecision` → `false`).
- İzin kartı `decisionPending` sinyaliyle sürülür — **oturum rozetinden bağımsız**.
- İzin kartı buton etiketleri: `1 · Evet`, `2 · Evet, bir daha sorma`, `3 · Hayır` + `Esc` (pressKey "1"/"2"/"3"/"esc").
- İzin kartı bağlamı = feed'deki son `tool_use` özeti (`"tool: summary"`); yoksa nil. Yeni parse yok.
- Komut id formatı: `"ph-\(commandCounter)"`.
- `docs/spec/50-remote-protocol.md` bağlayıcıdır; protokol değişikliği bu dosyada da güncellenir.

---

### Task 1: Mac — `awaiting_decision` sinyalini ilet (RemoteService + SnapshotBuilder + spec)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (handleTerminalEvent, stopWatcher, sendSnapshot, yeni dict alanı)
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift` (yeni event helper + snapshot alanı)
- Modify: `docs/spec/50-remote-protocol.md` (yeni event kind + snapshot alanı)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: `TerminalEvent.awaitingDecisionChanged(TerminalID, Bool)` (LumiKit, mevcut), `terminal.terminals`, mevcut `connection.send(type:payload:)`, `sendSnapshot()`.
- Produces:
  - Wire event: `{kind:"awaiting_decision", sessionId:<uuid>, awaiting:Bool}`
  - Snapshot session entry'sine opsiyonel `awaitingDecision: Bool` (yalnız `true` iken yazılır)
  - `SnapshotBuilder.awaitingDecisionEvent(sessionId: String, awaiting: Bool) -> [String: Any]`
  - `SnapshotBuilder.snapshot(terminals:repos:personas:awaitingDecision:)` — yeni son parametre `awaitingDecision: [TerminalID: Bool] = [:]`

- [ ] **Step 1: FakeConnection'a sorgu yardımcıları ekle + testleri yaz (başarısız olacak)**

`RemoteServiceTests.swift` içindeki `FakeConnection` actor'ına ekle:

```swift
func awaitingEvent() -> (sessionId: String, awaiting: Bool)? {
    guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "awaiting_decision" })
    else { return nil }
    return ((e.payload["sessionId"] as? String) ?? "", (e.payload["awaiting"] as? Bool) ?? false)
}
func snapshotFirstSessionAwaiting() -> Bool? {
    guard let snap = sent.last(where: { $0.type == "snapshot" }),
          let sessions = snap.payload["sessions"] as? [[String: Any]],
          let first = sessions.first else { return nil }
    return (first["awaitingDecision"] as? Bool) ?? false
}
```

Yeni testleri `RemoteServiceTests` sınıfına ekle:

```swift
func testAwaitingDecisionChangeSendsEvent() async throws {
    let connection = FakeConnection()
    let terminal = FakeTerminal()
    let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
    let service = makeService(connection: connection, terminal: terminal)
    await service.start(); await drain()

    terminal.pushEvent(.awaitingDecisionChanged(meta.id, true))
    await drain()

    let ev = await connection.awaitingEvent()
    XCTAssertEqual(ev?.sessionId, meta.id.description)
    XCTAssertEqual(ev?.awaiting, true)
    service.stop()
}

func testSnapshotCarriesAwaitingDecision() async throws {
    let connection = FakeConnection()
    let terminal = FakeTerminal()
    _ = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
    let meta = terminal.metas[0]
    let service = makeService(connection: connection, terminal: terminal)
    await service.start(); await drain()

    terminal.pushEvent(.awaitingDecisionChanged(meta.id, true))
    await drain()
    await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
    await drain()

    let awaiting = await connection.snapshotFirstSessionAwaiting()
    XCTAssertEqual(awaiting, true)
    service.stop()
}

func testExitClearsAwaitingDecision() async throws {
    let connection = FakeConnection()
    let terminal = FakeTerminal()
    let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
    let service = makeService(connection: connection, terminal: terminal)
    await service.start(); await drain()

    terminal.pushEvent(.awaitingDecisionChanged(meta.id, true)); await drain()
    terminal.pushEvent(.exited(meta.id, code: 0)); await drain() // stopWatcher temizler + snapshot yollar

    let awaiting = await connection.snapshotFirstSessionAwaiting()
    XCTAssertEqual(awaiting, false)
    service.stop()
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiPackages && swift test --filter RemoteServiceTests`
Expected: FAIL — `awaiting_decision` event hiç yollanmıyor (`.awaitingDecisionChanged` `default: break`'e düşüyor); snapshot alanı yok.

- [ ] **Step 3: `SnapshotBuilder`'ı güncelle**

`SnapshotBuilder.snapshot` imzasına parametre ekle ve entry'ye alanı koy:

```swift
static func snapshot(
    terminals: [TerminalMeta],
    repos: [Repo],
    personas: [Persona],
    awaitingDecision: [TerminalID: Bool] = [:]
) -> [String: Any] {
    let repoNames = Dictionary(repos.map { ($0.path, $0.name) },
                               uniquingKeysWith: { first, _ in first })
    let sessions: [[String: Any]] = terminals.map { meta in
        var entry: [String: Any] = [
            "id": meta.id.description,
            "repoPath": meta.repoPath,
            "repoName": repoNames[meta.repoPath]
                ?? (meta.repoPath as NSString).lastPathComponent,
            "status": meta.status.rawValue,
        ]
        if let title = meta.oscTitle { entry["title"] = title }
        if awaitingDecision[meta.id] == true { entry["awaitingDecision"] = true }
        return entry
    }
    return [
        "sessions": sessions,
        "repos": repos.map { ["name": $0.name, "path": $0.path] },
        "personas": personas.map { ["id": $0.id, "label": $0.label] },
    ]
}
```

Yeni event helper'ı (statusChangeEvent'in yanına) ekle:

```swift
static func awaitingDecisionEvent(sessionId: String, awaiting: Bool) -> [String: Any] {
    ["kind": "awaiting_decision", "sessionId": sessionId, "awaiting": awaiting]
}
```

- [ ] **Step 4: `RemoteService`'i güncelle**

`lastSummary` alanının yanına ekle:

```swift
private var awaitingDecision: [TerminalID: Bool] = [:]
```

`handleTerminalEvent` switch'ine `default: break`'ten önce yeni case:

```swift
case .awaitingDecisionChanged(let id, let awaiting):
    awaitingDecision[id] = awaiting
    guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
    await connection.send(type: "event", payload:
        SnapshotBuilder.awaitingDecisionEvent(sessionId: meta.id.description, awaiting: awaiting))
```

`stopWatcher(for:)` içine (mevcut `lastSummary[id] = nil` yanına):

```swift
awaitingDecision[id] = nil
```

`sendSnapshot()` içinde `SnapshotBuilder.snapshot` çağrısına parametreyi geçir:

```swift
let payload = SnapshotBuilder.snapshot(
    terminals: terminal.terminals, repos: repoList, personas: personaList,
    awaitingDecision: awaitingDecision)
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiPackages && swift test --filter RemoteServiceTests`
Expected: PASS. Sonra tam suite:
Run: `cd LumiPackages && swift test`
Expected: hepsi yeşil, 0 warning (SnapshotBuilder imza değişimi default parametreyle geriye uyumlu; başka çağrı kırılmaz).

- [ ] **Step 6: `docs/spec/50-remote-protocol.md`'i güncelle**

Event bölümüne (status_change / transcript / history yanına) ekle:

```markdown
### `awaiting_decision`
`{ "kind": "awaiting_decision", "sessionId": "<uuid>", "awaiting": bool }` — Mac bir tool için izin (karar) beklemeye başlayınca `true`, çözülünce `false`. Status'ten ayrı sinyaldir (OSC "needs your permission"); rozet OSC başlığına bağlı olduğundan bu daha güvenilirdir. Relay bu kind'a bakmaz (push kuralı yalnız `status_change`).
```

Snapshot payload bölümündeki session şekline not ekle: `awaitingDecision?: bool` (yok → `false`) — oturum bir izin/karar bekliyorsa `true`.

- [ ] **Step 7: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift \
        LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift \
        LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift \
        docs/spec/50-remote-protocol.md
git commit -m "remote: awaiting_decision sinyalini telefona ilet (event + snapshot) + spec"
```

---

### Task 2: Mobil decode — `RemoteEvent.awaitingDecision` + `SessionSummary.awaitingDecision`

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (RemoteEvent, SessionSummary)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (decodeEvent)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: wire `awaiting_decision` event + snapshot `awaitingDecision` alanı (Task 1).
- Produces:
  - `RemoteEvent.awaitingDecision(sessionId: String, awaiting: Bool)`
  - `SessionSummary.awaitingDecision: Bool` (Decodable, yoksa false; memberwise init'te varsayılan false)

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`ProtocolTests.swift`'e ekle:

```swift
func testDecodeAwaitingDecisionEvent() {
    let text = #"{"v":1,"type":"event","payload":{"kind":"awaiting_decision","sessionId":"s1","awaiting":true}}"#
    guard case .event(.awaitingDecision(let id, let awaiting))? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("awaiting_decision bekleniyordu")
    }
    XCTAssertEqual(id, "s1")
    XCTAssertTrue(awaiting)
}

func testDecodeAwaitingDecisionMissingAwaitingDefaultsFalse() {
    let text = #"{"v":1,"type":"event","payload":{"kind":"awaiting_decision","sessionId":"s1"}}"#
    guard case .event(.awaitingDecision(_, let awaiting))? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("awaiting_decision bekleniyordu")
    }
    XCTAssertFalse(awaiting)
}

func testDecodeSnapshotSessionAwaitingDecision() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"waiting-unseen","awaitingDecision":true}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("snapshot bekleniyordu")
    }
    XCTAssertTrue(snapshot.sessions[0].awaitingDecision)
}

func testDecodeSnapshotSessionAwaitingDefaultsFalseWhenAbsent() {
    let text = #"{"v":1,"type":"snapshot","payload":{"sessions":[{"id":"s1","repoPath":"/r","repoName":"r","status":"idle"}],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snapshot)? = PhoneProtocol.decodeServerMessage(text) else {
        return XCTFail("snapshot bekleniyordu")
    }
    XCTAssertFalse(snapshot.sessions[0].awaitingDecision)
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: FAIL — `RemoteEvent.awaitingDecision` yok (derleme hatası) ve `SessionSummary.awaitingDecision` yok.

- [ ] **Step 3: `Models.swift` — RemoteEvent case + SessionSummary alanı**

`RemoteEvent` enum'una case ekle:

```swift
public enum RemoteEvent: Sendable, Equatable {
    case statusChange(sessionId: String, status: SessionStatus, repoName: String, summary: String?)
    case transcript(sessionId: String, item: FeedItem)
    case history(sessionId: String, items: [FeedItem])
    case awaitingDecision(sessionId: String, awaiting: Bool)
}
```

`SessionSummary`'ye alan ekle, memberwise init'e varsayılanlı parametre ekle, ve toleranslı `init(from:)` yaz:

```swift
public struct SessionSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let repoPath: String
    public let repoName: String
    public var status: SessionStatus
    public let title: String?
    public let awaitingDecision: Bool

    public init(id: String, repoPath: String, repoName: String,
                status: SessionStatus, title: String? = nil,
                awaitingDecision: Bool = false) {
        self.id = id
        self.repoPath = repoPath
        self.repoName = repoName
        self.status = status
        self.title = title
        self.awaitingDecision = awaitingDecision
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoPath, repoName, status, title, awaitingDecision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            repoPath: try c.decode(String.self, forKey: .repoPath),
            repoName: try c.decode(String.self, forKey: .repoName),
            status: try c.decode(SessionStatus.self, forKey: .status),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            awaitingDecision: try c.decodeIfPresent(Bool.self, forKey: .awaitingDecision) ?? false
        )
    }
}
```

(Not: özel `init(from:)` synthesized Decodable'ı devre dışı bırakır; tüm alanlar elle çözülür. `SessionStatus`'un kendi toleranslı Decodable'ı korunur.)

- [ ] **Step 4: `PhoneProtocol.swift` — decodeEvent'e case ekle**

`decodeEvent(_:)` switch'ine `default:` öncesi:

```swift
case "awaiting_decision":
    return .awaitingDecision(
        sessionId: sessionId,
        awaiting: payload["awaiting"] as? Bool ?? false)
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: hepsi yeşil (tüm suite — `RemoteEvent`/`SessionSummary` exhaustiveness kırıkları yok; mevcut snapshot decode testleri `awaitingDecision` yokken false verir), 0 warning.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "mobile: awaiting_decision event + SessionSummary.awaitingDecision decode"
```

---

### Task 3: Mobil AppModel — `decisionPending` + izin kartı önceliği

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (QuestionCard.isPermission, decisionPending, handle, dispatch, apply, unpair, questionCard)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `RemoteEvent.awaitingDecision` + `SessionSummary.awaitingDecision` (Task 2), `FeedItem.toolUse`, mevcut `activeQuestions`, `dispatch`.
- Produces:
  - `QuestionCard.isPermission: Bool` (struct alanı, varsayılan false)
  - `AppModel.questionCard(for:)` yeni öncelik (question > permission > needInput)

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`AppModelTests.swift`'e ekle:

```swift
// MARK: İzin kartı (Spec 2)

func testAwaitingDecisionShowsPermissionCardWithToolContext() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    model.handle(.event(.transcript(sessionId: "s1", item: .toolUse(tool: "Bash", summary: "swift test"))))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: true)))

    let card = model.questionCard(for: "s1")
    XCTAssertNotNil(card)
    XCTAssertNil(card?.questions)
    XCTAssertEqual(card?.isPermission, true)
    XCTAssertEqual(card?.context, "Bash: swift test") // rozet .working olsa bile görünür
}

func testRealQuestionTakesPriorityOverPermission() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: true)))
    let qs = [Question(header: "h", question: "q", options: ["a"])]
    model.handle(.event(.transcript(sessionId: "s1", item: .question(qs))))

    XCTAssertEqual(model.questionCard(for: "s1")?.questions, qs)
    XCTAssertEqual(model.questionCard(for: "s1")?.isPermission, false)
}

func testStatusWorkingClearsDecisionPending() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: true)))
    XCTAssertEqual(model.questionCard(for: "s1")?.isPermission, true)

    model.handle(.event(.statusChange(sessionId: "s1", status: .working, repoName: "lumi", summary: nil)))
    XCTAssertNil(model.questionCard(for: "s1"))
}

func testAwaitingFalseClearsPermissionCard() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: true)))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: false)))
    XCTAssertNil(model.questionCard(for: "s1"))
}

func testAnsweringPermissionClearsCard() async {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
    model.handle(.event(.awaitingDecision(sessionId: "s1", awaiting: true)))
    XCTAssertEqual(model.questionCard(for: "s1")?.isPermission, true)

    await model.pressKey(sessionId: "s1", key: "1")
    XCTAssertNil(model.questionCard(for: "s1"), "cevap verilince izin kartı kalkar")
}

func testSnapshotAppliesAwaitingDecision() {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [
        SessionSummary(id: "s1", repoPath: "/r/lumi", repoName: "lumi", status: .working, awaitingDecision: true),
    ], repos: [], personas: [])))
    XCTAssertEqual(model.questionCard(for: "s1")?.isPermission, true)
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `QuestionCard` `isPermission` alanı yok (derleme hatası) ve `awaitingDecision` event işlenmiyor.

- [ ] **Step 3: `QuestionCard`'a `isPermission` ekle** (`AppModel.swift`)

```swift
public struct QuestionCard: Sendable, Equatable {
    public let questions: [Question]?
    public let context: String?
    public let isPermission: Bool

    public init(questions: [Question]?, context: String?, isPermission: Bool = false) {
        self.questions = questions
        self.context = context
        self.isPermission = isPermission
    }
}
```

(Varsayılan `false` → mevcut `QuestionCard(questions:context:)` çağrıları ve testleri aynen derlenir/geçer.)

- [ ] **Step 4: `AppModel` durum + mantık**

Yeni alan (`activeQuestions`'ın yanına):

```swift
private var decisionPending: [String: Bool] = [:]
```

`handle(.event(...))` switch'ine yeni case ekle (transcript/history/statusChange yanına):

```swift
case .event(.awaitingDecision(let sessionId, let awaiting)):
    macOnline = true
    decisionPending[sessionId] = awaiting ? true : nil
```

`handle(.event(.statusChange...))` içindeki working/idle temizliğini genişlet:

```swift
if status.badge == .working || status.badge == .idle {
    activeQuestions[sessionId] = nil
    decisionPending[sessionId] = nil
}
```

`dispatch(...)` içindeki hedef temizliğine ekle (`activeQuestions[target] = nil` yanına):

```swift
if !target.isEmpty {
    lastCommandError[target] = nil
    activeQuestions[target] = nil
    decisionPending[target] = nil // izne cevap verildi → kart kalkar
}
```

`apply(_ snapshot:)` — snapshot'tan yeniden kur (liveIds filtresi + snapshot otorite):

```swift
decisionPending = Dictionary(
    snapshot.sessions.compactMap { $0.awaitingDecision ? ($0.id, true) : nil },
    uniquingKeysWith: { first, _ in first })
```

`unpair()`'a ekle:

```swift
decisionPending = [:]
```

`questionCard(for:)`'ı yeniden yaz (son tool_use bağlamını helper'a çıkar):

```swift
public func questionCard(for sessionId: String) -> QuestionCard? {
    if let questions = activeQuestions[sessionId] {
        return QuestionCard(questions: questions, context: nil)
    }
    if decisionPending[sessionId] == true {
        return QuestionCard(questions: nil, context: lastToolContext(sessionId), isPermission: true)
    }
    guard session(sessionId)?.status.badge == .waiting else { return nil }
    return QuestionCard(questions: nil, context: lastToolContext(sessionId))
}

private func lastToolContext(_ sessionId: String) -> String? {
    (feeds[sessionId] ?? []).reversed().compactMap { entry -> String? in
        if case .toolUse(let tool, let summary) = entry.item { return "\(tool): \(summary)" }
        return nil
    }.first
}
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: hepsi yeşil (yeni izin testleri + mevcut `testGenericCardWhenWaitingWithoutQuestionText`, `testQuestionPinsCardAndTurnDoneClearsIt` hâlâ geçer — jenerik kart yolu ve Equatable `isPermission:false` ile korunur), 0 warning.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: decisionPending + rozetten bağımsız izin kartı önceliği"
```

---

### Task 4: Mobil UI — `QuestionCardView` izin kartı dalı

**Files:**
- Modify: `LumiMobile/App/SessionDetailView.swift` (`QuestionCardView`)

**Interfaces:**
- Consumes: `QuestionCard.isPermission` + `QuestionCard.context` (Task 3), mevcut `onKey` closure (pressKey'e bağlı).
- Produces: izin kartı görünümü (başlık + komut + Evet/Evet-sorma/Hayır + Esc).

- [ ] **Step 1: `QuestionCardView` gövdesini üç dala ayır**

Mevcut `if let question = card.questions?.first { ... } else { ... }` yapısını şu şekilde değiştir:

```swift
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
            enterEscRow
        } else if card.isPermission {
            Text("İzin isteği")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let context = card.context {
                Text(context)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            permissionButton("1", "Evet")
            permissionButton("2", "Evet, bir daha sorma")
            permissionButton("3", "Hayır")
            Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
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
            enterEscRow
        }
    }
    .disabled(disabled)
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.08))
    .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .top)
}

private func permissionButton(_ key: String, _ label: String) -> some View {
    Button {
        onKey(key)
    } label: {
        Text("\(key) · \(label)")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
}

private var enterEscRow: some View {
    HStack {
        Button("Enter") { onKey("enter") }.buttonStyle(.borderedProminent)
        Button("Esc") { onKey("esc") }.buttonStyle(.bordered)
    }
}
```

(Not: gerçek-soru ve jenerik dalları bugünkü davranışı korur; yalnız ortak `enterEscRow` helper'ına çıkarıldı ve `isPermission` dalı eklendi.)

- [ ] **Step 2: Derle**

Run: `xcodebuild -project LumiMobile/LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manuel doğrulama**

Gerçek Lumi'de bir oturumda tool izin promptu tetikle (ör. Bash komutu) → telefonda "İzin isteği" kartı + komut + `1 · Evet` / `2 · Evet, bir daha sorma` / `3 · Hayır` + `Esc`. "Evet"e dokun → Mac ilerler, kart kalkar. Rozet waiting'e dönmese bile kart görünür.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/SessionDetailView.swift
git commit -m "mobile: QuestionCardView izin kartı (Evet/Evet-sorma/Hayır)"
```

---

## Self-Review

**Spec coverage:**
- Bileşen 1 (Mac awaiting_decision event + snapshot + exit temizliği) → Task 1. ✓
- Bileşen 2 (protokol: event kind + snapshot alanı) → Task 1 Step 6. ✓
- Bileşen 3 mobil decode (RemoteEvent + SessionSummary) → Task 2. ✓
- Bileşen 3 mobil AppModel (decisionPending, apply, event, statusChange clear, dispatch clear, unpair, questionCard önceliği) → Task 3. ✓
- Bileşen 4 UI (izin kartı) → Task 4. ✓
- Kararlar: rozetten bağımsız (Task 3 questionCard), buton etiketleri (Task 4), son tool_use bağlamı (Task 3 lastToolContext). ✓
- Test bölümü → Task 1-3 unit testleri + Task 4 build/manuel. ✓

**Placeholder scan:** Tüm adımlar gerçek kod/komut içerir; TBD/TODO yok. ✓

**Type consistency:**
- `RemoteEvent.awaitingDecision(sessionId:awaiting:)` (Task 2) ← Task 3 handle + testler aynı imza. ✓
- `SessionSummary.awaitingDecision: Bool` + init varsayılanı (Task 2) ← Task 3 apply + testler. ✓
- `QuestionCard.isPermission` varsayılan false (Task 3) ← Task 4 UI `card.isPermission`. ✓
- `SnapshotBuilder.snapshot(...awaitingDecision:)` + `awaitingDecisionEvent` (Task 1) ← RemoteService çağrısı. ✓
- Wire string `"awaiting_decision"` (Task 1 üretim) = decode (Task 2). ✓
- pressKey "1"/"2"/"3"/"esc" (Task 4 onKey) = mevcut `AppModel.pressKey` + Mac keySequence. ✓
