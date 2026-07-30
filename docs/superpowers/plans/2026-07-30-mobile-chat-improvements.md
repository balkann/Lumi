# Mobil Chat İyileştirmeleri Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LumiMobile chat'inde gönderilen mesajları durum göstergesiyle görünür kılmak, Enter=gönder yapmak ve gerçek oturum silme eklemek.

**Architecture:** Kullanıcı mesajları transcript'te olmadığından `FeedItem`'a yerel bir `.userMessage(text, status)` case'i eklenir ve iyimser (optimistic) olarak feed'e yazılır; `command_result` durumu günceller. Silme, yeni `delete_session` protokol action'ı ile Mac'te `terminal.kill(id:)` çağırır; oturum mevcut `.exited`→snapshot akışıyla listeden düşer.

**Tech Stack:** Swift 6, SwiftUI, XCTest. Modüller: `LumiMobileKit` (mobil çekirdek), `LumiMobile/App` (SwiftUI view'lar), `LumiRemote` (Mac remote servisi).

## Global Constraints

- macOS 14+ / iOS hedefi, Swift 6 strict concurrency; `@Observable` model, Combine yok.
- Protokol codec `docs/spec/50-remote-protocol.md` ile birebir; gelen taraf toleranslı kalır (bilinmeyen tip/action akışı kırmaz).
- Feed cap: `AppModel.feedCap = 200`.
- Persistence formatlarına dokunulmaz.
- Komut id formatı: `"ph-\(commandCounter)"`.
- `docs/spec/50-remote-protocol.md` bağlayıcıdır; protokol değişikliği bu dosyada da güncellenir.

---

### Task 1: `FeedItem.userMessage` + `SendStatus` + iyimser gönderim ve durum geçişleri

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (FeedItem enum)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.feeds: [String: [FeedEntry]]`, `appendFeed`, `dispatch(target:action:)`, `feedCounter`, `feedCap`, `commandTargets`, `client.send`.
- Produces:
  - `enum SendStatus: Sendable, Equatable { case sending, sent, failed }`
  - `FeedItem.userMessage(text: String, status: SendStatus)`
  - `AppModel.sendText(sessionId:text:)` (davranış değişti — iyimser bubble)
  - `AppModel.appendUserMessage(_ sessionId: String, text: String) -> Int` (private)
  - `AppModel.setUserMessageStatus(_ entryId: Int, _ status: SendStatus)` (private)
  - `dispatch(target:action:userMessageEntryId:)` (yeni opsiyonel parametre)

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`AppModelTests.swift` sonuna ekle:

```swift
// MARK: Yeni — gönderilen mesaj görünürlüğü + durum

func testSendTextAppendsOptimisticSendingBubble() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))

    await model.sendText(sessionId: "s1", text: "merhaba")

    let feed = model.feeds["s1"] ?? []
    XCTAssertEqual(feed.count, 1)
    XCTAssertEqual(feed[0].item, .userMessage(text: "merhaba", status: .sending))
    XCTAssertEqual(client.commands.count, 1)
    guard case .sendText(let sid, let text) = client.commands[0].action else { return XCTFail() }
    XCTAssertEqual(sid, "s1")
    XCTAssertEqual(text, "merhaba")
}

func testSendTextEmptyIsNoop() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    await model.sendText(sessionId: "s1", text: "   \n ")
    XCTAssertTrue((model.feeds["s1"] ?? []).isEmpty)
    XCTAssertTrue(client.commands.isEmpty)
}

func testCommandResultOkMarksBubbleSent() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    await model.sendText(sessionId: "s1", text: "merhaba")
    let commandId = client.commands[0].commandId

    model.handle(.commandResult(CommandResult(commandId: commandId, ok: true, error: nil)))

    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sent))
    XCTAssertNil(model.lastCommandError["s1"], "send_text lastCommandError kullanmaz")
}

func testCommandResultFailureMarksBubbleFailed() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    await model.sendText(sessionId: "s1", text: "merhaba")
    let commandId = client.commands[0].commandId

    model.handle(.commandResult(CommandResult(commandId: commandId, ok: false, error: "terminal kapandı")))

    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))
    XCTAssertNil(model.lastCommandError["s1"], "send_text hatası bubble'a yansır, lastCommandError'a değil")
}
```

Ayrıca **mevcut** `testSendTextFailureReportsLastCommandError` testini yeni davranışa göre değiştir (send_text artık bubble kullanır):

```swift
func testSendTextFailureMarksBubbleFailed() async {
    let (model, client, _) = makeModel()
    client.sendResult = false
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))

    await model.sendText(sessionId: "s1", text: "merhaba")

    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))
    XCTAssertNil(model.lastCommandError["s1"])
}
```

(Eski `testSendTextFailureReportsLastCommandError` fonksiyonunu SİL — yerine yukarıdaki geçer.)

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `.userMessage` case ve yeni davranış yok (derleme hatası: "type 'FeedItem' has no member 'userMessage'").

- [ ] **Step 3: `Models.swift`'e SendStatus + userMessage ekle**

`Models.swift`'te `FeedItem` enum'unu güncelle:

```swift
public enum SendStatus: Sendable, Equatable { case sending, sent, failed }

/// Transcript akış öğesi (protokol `event.item.itemType`).
public enum FeedItem: Sendable, Equatable {
    case assistantText(String)
    case toolUse(tool: String, summary: String)
    case question([Question])
    case turnDone
    /// Yalnız yerel: kullanıcının gönderdiği mesaj (protokol decode'u üretmez).
    case userMessage(text: String, status: SendStatus)
}
```

- [ ] **Step 4: `AppModel.swift`'te iyimser gönderim + durum mantığı**

`AppModel`'e yeni alan ekle (diğer private var'ların yanına):

```swift
/// commandId → gönderilen kullanıcı mesajının FeedEntry.id'si (durum güncellemesi için).
private var commandUserMessages: [String: Int] = [:]
```

`sendText`'i değiştir:

```swift
public func sendText(sessionId: String, text: String) async {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let entryId = appendUserMessage(sessionId, text: text)
    await dispatch(target: sessionId,
                   action: .sendText(sessionId: sessionId, text: text),
                   userMessageEntryId: entryId)
}
```

`dispatch`'e opsiyonel parametre ekle ve fail yolunu güncelle:

```swift
private func dispatch(target: String, action: CommandAction, userMessageEntryId: Int? = nil) async {
    commandCounter += 1
    let commandId = "ph-\(commandCounter)"
    commandTargets[commandId] = target
    if let userMessageEntryId { commandUserMessages[commandId] = userMessageEntryId }
    if !target.isEmpty {
        lastCommandError[target] = nil
        activeQuestions[target] = nil // cevap verildi → kart kalkar
    }
    let ok = await client.send(command: OutgoingCommand(commandId: commandId, action: action))
    if !ok {
        commandTargets[commandId] = nil
        commandUserMessages[commandId] = nil
        if let userMessageEntryId {
            setUserMessageStatus(userMessageEntryId, .failed)
        } else if target.isEmpty {
            startState = .failed("bağlantı yok")
        } else {
            lastCommandError[target] = "bağlantı yok"
        }
    }
}
```

`handle(.commandResult...)` içinde, `historyCommandIds` kontrolünden **sonra**, `commandTargets` guard'ından **önce** ekle:

```swift
case .commandResult(let result):
    if historyCommandIds.remove(result.commandId) != nil {
        return
    }
    if let entryId = commandUserMessages.removeValue(forKey: result.commandId) {
        commandTargets.removeValue(forKey: result.commandId)
        setUserMessageStatus(entryId, result.ok ? .sent : .failed)
        return
    }
    guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
    // ... (mevcut start_session / lastCommandError mantığı aynı kalır)
```

Yeni yardımcıları ekle (Yardımcılar bölümüne):

```swift
@discardableResult
private func appendUserMessage(_ sessionId: String, text: String) -> Int {
    feedCounter += 1
    let id = feedCounter
    var feed = feeds[sessionId] ?? []
    feed.append(FeedEntry(id: id, item: .userMessage(text: text, status: .sending)))
    if feed.count > Self.feedCap {
        feed.removeFirst(feed.count - Self.feedCap)
    }
    feeds[sessionId] = feed
    return id
}

private func setUserMessageStatus(_ entryId: Int, _ status: SendStatus) {
    for (sessionId, feed) in feeds {
        guard let idx = feed.firstIndex(where: { $0.id == entryId }),
              case .userMessage(let text, _) = feed[idx].item else { continue }
        feeds[sessionId]?[idx] = FeedEntry(id: entryId, item: .userMessage(text: text, status: status))
        return
    }
}
```

`unpair()` içine state temizliğine ekle (diğer `= [:]` atamalarının yanına):

```swift
commandUserMessages = [:]
```

`handle(.event(.transcript...))` switch'i `FeedItem` üzerinde exhaustive olduğu için `.userMessage` case'i ekle (transcript bunu üretmez, savunmacı):

```swift
case .assistantText, .toolUse:
    appendFeed(sessionId, item)
case .userMessage:
    break // transcript kullanıcı mesajı üretmez
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS (yeni testler + değişen test yeşil; eski `testSendTextRecordsCommandAndClearsQuestion` hâlâ geçer).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: gönderilen mesaj iyimser bubble + gönderim durumu (sending/sent/failed)"
```

---

### Task 2: `applyHistory` kullanıcı mesajlarını korur

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift:233-262` (`applyHistory`)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `FeedItem.userMessage` (Task 1), `feeds`, `feedCounter`, `feedCap`.
- Produces: `applyHistory` artık mevcut `.userMessage` entry'lerini id/status koruyarak history sonrası tail'e ekler.

- [ ] **Step 1: Testi yaz (başarısız olacak)**

```swift
func testHistoryPreservesLocalUserMessages() async {
    let (model, _, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    // kullanıcı bir mesaj göndersin (iyimser bubble feed'e girsin)
    await model.sendText(sessionId: "s1", text: "kullanici-mesaji")
    let userEntryId = model.feeds["s1"]!.first!.id

    // sonra history gelsin (transcript kullanıcı mesajını İÇERMEZ)
    model.handle(.event(.history(sessionId: "s1", items: [
        .assistantText("eski-1"), .turnDone,
    ])))

    let items = (model.feeds["s1"] ?? []).map(\.item)
    XCTAssertEqual(items, [
        .assistantText("eski-1"),
        .turnDone,
        .userMessage(text: "kullanici-mesaji", status: .sending),
    ])
    // korunan entry'nin id'si değişmedi (commandUserMessages eşlemesi geçerli kalır)
    XCTAssertEqual(model.feeds["s1"]?.last?.id, userEntryId)
}
```

- [ ] **Step 2: Testi koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter testHistoryPreservesLocalUserMessages`
Expected: FAIL — history feed'i replace edip userMessage'ı siliyor.

- [ ] **Step 3: `applyHistory`'yi güncelle**

`applyHistory` başındaki döngü + feed atamasını değiştir:

```swift
private func applyHistory(sessionId: String, items: [FeedItem]) {
    var entries: [FeedEntry] = []
    for item in items {
        switch item {
        case .question, .userMessage:
            continue // sorular karta gider; userMessage transcript'te olmaz
        default:
            feedCounter += 1
            entries.append(FeedEntry(id: feedCounter, item: item))
        }
    }
    // yerelde eklenen kullanıcı mesajlarını koru (id/status ile) — history'nin sonuna
    let userEntries = (feeds[sessionId] ?? []).filter {
        if case .userMessage = $0.item { return true }
        return false
    }
    entries.append(contentsOf: userEntries)
    if entries.count > Self.feedCap {
        entries.removeFirst(entries.count - Self.feedCap)
    }
    feeds[sessionId] = entries

    // (repin mantığı aşağıda AYNEN kalır)
    guard session(sessionId)?.status.badge == .waiting else { return }
    // ...
}
```

- [ ] **Step 4: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS (yeni test + mevcut `testHistoryReplacesFeedAndRepinsQuestion`, `testHistoryCapsAt200` hâlâ yeşil — onlarda userMessage yok).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: history reload gönderilen mesajları korur"
```

---

### Task 3: Başarısız gönderimi tekrar dene (`retrySend`)

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `feeds`, `setUserMessageStatus`, `dispatch(...userMessageEntryId:)` (Task 1).
- Produces: `AppModel.retrySend(sessionId: String, entryId: Int) async`

- [ ] **Step 1: Testi yaz (başarısız olacak)**

```swift
func testRetrySendResendsFailedBubble() async {
    let (model, client, _) = makeModel()
    client.sendResult = false
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    await model.sendText(sessionId: "s1", text: "merhaba")
    let entryId = model.feeds["s1"]!.first!.id
    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))

    // bağlantı geri geldi → tekrar dene
    client.sendResult = true
    await model.retrySend(sessionId: "s1", entryId: entryId)

    // aynı bubble tekrar sending'e döndü, YENİ bubble eklenmedi
    XCTAssertEqual(model.feeds["s1"]?.count, 1)
    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sending))
    XCTAssertEqual(client.commands.count, 1)

    // yeni komutun sonucu bubble'ı sent yapar
    model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: true, error: nil)))
    XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sent))
}
```

- [ ] **Step 2: Testi koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter testRetrySendResendsFailedBubble`
Expected: FAIL — `retrySend` yok.

- [ ] **Step 3: `retrySend` ekle (Komutlar bölümüne)**

```swift
/// Başarısız bir kullanıcı mesajı baloncuğuna dokununca aynı entry'yi tekrar gönderir.
public func retrySend(sessionId: String, entryId: Int) async {
    guard let feed = feeds[sessionId],
          let idx = feed.firstIndex(where: { $0.id == entryId }),
          case .userMessage(let text, _) = feed[idx].item else { return }
    setUserMessageStatus(entryId, .sending)
    await dispatch(target: sessionId,
                   action: .sendText(sessionId: sessionId, text: text),
                   userMessageEntryId: entryId)
}
```

- [ ] **Step 4: Testi koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: başarısız gönderimi dokununca tekrar dene (retrySend)"
```

---

### Task 4: `delete_session` protokolü (mobil) + `AppModel.deleteSession`

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (CommandAction + commandFrame)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (deleteSession)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`, `AppModelTests.swift`

**Interfaces:**
- Consumes: `OutgoingCommand`, `PhoneProtocol.frame`, `dispatch`.
- Produces:
  - `CommandAction.deleteSession(sessionId: String)`
  - `PhoneProtocol.commandFrame` → `{action:"delete_session", sessionId, commandId}`
  - `AppModel.deleteSession(sessionId: String) async`

- [ ] **Step 1: Testleri yaz (başarısız olacak)**

`ProtocolTests.swift`'e ekle:

```swift
func testEncodeDeleteSessionCommand() throws {
    let frame = PhoneProtocol.commandFrame(
        OutgoingCommand(commandId: "c9", action: .deleteSession(sessionId: "s1")))
    let data = try XCTUnwrap(frame.data(using: .utf8))
    let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(dict["type"] as? String, "command")
    let payload = try XCTUnwrap(dict["payload"] as? [String: Any])
    XCTAssertEqual(payload["action"] as? String, "delete_session")
    XCTAssertEqual(payload["sessionId"] as? String, "s1")
    XCTAssertEqual(payload["commandId"] as? String, "c9")
}
```

`AppModelTests.swift`'e ekle:

```swift
func testDeleteSessionDispatchesCommand() async {
    let (model, client, _) = makeModel()
    model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
    await model.deleteSession(sessionId: "s1")
    XCTAssertEqual(client.commands.count, 1)
    guard case .deleteSession(let sid) = client.commands[0].action else { return XCTFail() }
    XCTAssertEqual(sid, "s1")
}
```

- [ ] **Step 2: Testleri koştur, başarısız olduğunu doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter "testEncodeDeleteSessionCommand|testDeleteSessionDispatchesCommand"`
Expected: FAIL — `deleteSession` case yok (derleme hatası).

- [ ] **Step 3: `PhoneProtocol.swift`'i güncelle**

`CommandAction`'a case ekle (`PhoneProtocol.swift`):

```swift
public enum CommandAction: Sendable, Equatable {
    case sendText(sessionId: String, text: String)
    case pressKey(sessionId: String, key: String)
    case startSession(repoPath: String, personaId: String?, prompt: String)
    case getHistory(sessionId: String)
    case deleteSession(sessionId: String)
}
```

`commandFrame`'in switch'ine case ekle:

```swift
case .deleteSession(let sessionId):
    payload["action"] = "delete_session"
    payload["sessionId"] = sessionId
```

- [ ] **Step 4: `AppModel.swift`'e `deleteSession` ekle (Komutlar bölümüne)**

```swift
public func deleteSession(sessionId: String) async {
    await dispatch(target: sessionId, action: .deleteSession(sessionId: sessionId))
}
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS (tüm LumiMobileKit testleri yeşil).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: delete_session protokol action'ı + AppModel.deleteSession"
```

---

### Task 5: Mac tarafı `delete_session` handler + spec güncellemesi

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift:29-51` (handle switch)
- Modify: `LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift` (FakeTerminal.kill kaydı + test)
- Modify: `docs/spec/50-remote-protocol.md` (komut listesi)

**Interfaces:**
- Consumes: `TerminalServicing.kill(id:)`, `session(from:)`, `result(_:run:)`.
- Produces: `delete_session` action'ı → `terminal.kill(id:)`; hata `session_not_found`.

- [ ] **Step 1: Testi yaz (başarısız olacak)**

`RemoteCommandHandlerTests.swift`'te önce `FakeTerminal.kill`'i kayıt tutacak şekilde değiştir:

```swift
    var kills: [TerminalID] = []
    // ...
    func kill(id: TerminalID) throws { kills.append(id) }
```

Sonra test ekle:

```swift
func testDeleteSessionKillsTerminal() async {
    let (handler, terminal) = makeHandler()
    let meta = try! terminal.spawn(repoPath: "/r", task: nil, command: nil)
    let result = await handler.handle([
        "commandId": "d1", "action": "delete_session",
        "sessionId": meta.id.description,
    ])
    XCTAssertEqual(result["ok"] as? Bool, true)
    XCTAssertEqual(result["commandId"] as? String, "d1")
    XCTAssertEqual(terminal.kills.count, 1)
    XCTAssertEqual(terminal.kills[0], meta.id)
}

func testDeleteSessionUnknownSessionFails() async {
    let (handler, _) = makeHandler()
    let result = await handler.handle([
        "commandId": "d2", "action": "delete_session",
        "sessionId": UUID().uuidString,
    ])
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["error"] as? String, "session_not_found")
}
```

- [ ] **Step 2: Testi koştur, başarısız olduğunu doğrula**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests`
Expected: FAIL — `delete_session` işlenmiyor → `unknown_action`.

- [ ] **Step 3: `RemoteCommandHandler.handle`'a case ekle**

`handle(_:)` switch'ine `start_session` case'inden önce/sonra:

```swift
case "delete_session":
    return result(commandId, run: {
        let id = try self.session(from: payload)
        try self.terminal.kill(id: id)
    })
```

- [ ] **Step 4: Testi koştur, geçtiğini doğrula**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests`
Expected: PASS.

- [ ] **Step 5: `docs/spec/50-remote-protocol.md`'i güncelle**

Komut aksiyonları listesine (get_history satırından sonra) ekle:

```markdown
- `delete_session {commandId, sessionId}` — oturumu Mac'te sonlandırır (`terminal.kill`). Ardından `.exited` → yeni `snapshot` yayınlanır ve oturum telefon listesinden düşer. Hata: `session_not_found`.
```

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift \
        LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift \
        docs/spec/50-remote-protocol.md
git commit -m "remote: delete_session komutu terminali sonlandırır + spec"
```

---

### Task 6: UI — SessionDetailView: kullanıcı baloncuğu + Enter=gönder

**Files:**
- Modify: `LumiMobile/App/SessionDetailView.swift`

**Interfaces:**
- Consumes: `FeedItem.userMessage` (Task 1), `SendStatus`, `AppModel.sendText`, `AppModel.retrySend` (Task 3).
- Produces: `.userMessage` render (sağa hizalı baloncuk + durum ikonu); Enter=gönder input bar.

- [ ] **Step 1: `FeedEntryView`'a `.userMessage` case'i ekle**

`FeedEntryView.body` switch'ine ekle:

```swift
case .userMessage(let text, let status):
    HStack(alignment: .bottom, spacing: 6) {
        Spacer(minLength: 40)
        Text(text)
            .font(.body)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        sendStatusIcon(status)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
```

`FeedEntryView`'a yardımcı ekle. `.failed` durumunda dokunma tekrar-dene tetikler; bunun için `FeedEntryView`'a bir `onRetry: (() -> Void)?` closure eklenir:

```swift
struct FeedEntryView: View {
    let entry: FeedEntry
    var onRetry: (() -> Void)? = nil

    // ... body switch ...

    @ViewBuilder
    private func sendStatusIcon(_ status: SendStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Button { onRetry?() } label: {
                Image(systemName: "exclamationmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.red)
            .accessibilityLabel("Tekrar gönder")
        }
    }
}
```

`feedScroll` içindeki `ForEach`'te retry closure'ını bağla:

```swift
ForEach(feed) { entry in
    FeedEntryView(entry: entry, onRetry: retryClosure(for: entry))
        .id(entry.id)
}
```

Ve `SessionDetailView`'a yardımcı:

```swift
private func retryClosure(for entry: FeedEntry) -> (() -> Void)? {
    guard case .userMessage(_, .failed) = entry.item else { return nil }
    return { Task { await model.retrySend(sessionId: sessionId, entryId: entry.id) } }
}
```

- [ ] **Step 2: `inputBar`'ı Enter=gönder yap**

`inputBar`'ı değiştir:

```swift
private var inputBar: some View {
    HStack(spacing: 8) {
        TextField(model.macOnline ? "Mesaj yaz…" : "Mac çevrimdışı", text: $draft)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.send)
            .onSubmit(send)
            .disabled(!model.macOnline)
            .accessibilityIdentifier("messageField")
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill").font(.title2)
        }
        .accessibilityIdentifier("sendButton")
        .disabled(!model.macOnline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
}

private func send() {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    draft = ""
    Task { await model.sendText(sessionId: sessionId, text: text) }
}
```

(`axis: .vertical` ve `lineLimit(1...4)` kaldırıldı.)

- [ ] **Step 3: Derle**

Run: `cd LumiMobile/LumiMobileKit && swift build`
Expected: BUILD SUCCEEDED (LumiMobileKit derlenir). App target için Xcode derlemesi:
Run: `xcodebuild -project LumiMobile/LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build` (ya da mevcut simülatör hedefi)
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manuel doğrulama**

Simülatörde/cihazda oturum aç, mesaj yaz, **Enter'a bas** → mesaj sağda baloncukta ⏳ ile görünür, komut sonucu gelince ✓ olur. Bağlantı yokken gönder → kırmızı ⚠︎, dokununca tekrar dener.

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/App/SessionDetailView.swift
git commit -m "mobile: chat kullanıcı baloncuğu + durum ikonu + Enter=gönder"
```

---

### Task 7: UI — SessionListView: swipe-to-delete + onay

**Files:**
- Modify: `LumiMobile/App/SessionListView.swift`

**Interfaces:**
- Consumes: `AppModel.deleteSession` (Task 4), `model.orderedSessions`.
- Produces: Liste satırında swipe → destructive "Sil" → onay diyaloğu → `deleteSession`.

- [ ] **Step 1: Swipe action + onay state ekle**

`SessionListView`'a state ekle:

```swift
@State private var pendingDelete: SessionSummary?
```

`ForEach` satırına swipe action ekle:

```swift
ForEach(model.orderedSessions) { session in
    NavigationLink(value: session.id) {
        SessionRow(session: session)
    }
    .swipeActions(edge: .trailing) {
        Button(role: .destructive) {
            pendingDelete = session
        } label: {
            Label("Sil", systemImage: "trash")
        }
    }
}
```

`List`'e (veya `NavigationStack` gövdesine) onay diyaloğu ekle:

```swift
.confirmationDialog(
    "Oturum sonlandırılsın mı?",
    isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
    ),
    presenting: pendingDelete
) { session in
    Button("Sonlandır", role: .destructive) {
        Task { await model.deleteSession(sessionId: session.id) }
        pendingDelete = nil
    }
    Button("Vazgeç", role: .cancel) { pendingDelete = nil }
} message: { session in
    Text("\(session.repoName) oturumu Mac'te sonlandırılacak.")
}
```

- [ ] **Step 2: Derle**

Run: `xcodebuild -project LumiMobile/LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manuel doğrulama**

Listede bir oturumu sola kaydır → "Sil" → onay diyaloğu çıkar → "Sonlandır" → oturum Mac'te kapanır ve snapshot ile listeden düşer.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/SessionListView.swift
git commit -m "mobile: oturum listesinde swipe-to-delete + onay"
```

---

## Self-Review

**Spec coverage:**
- Bileşen 1 (gönderilen mesaj + durum) → Task 1, 2, 3, 6. ✓
- Bileşen 2 (Enter=gönder) → Task 6. ✓
- Bileşen 3 (gerçek silme) → Task 4 (mobil), 5 (Mac+spec), 7 (UI). ✓
- applyHistory koruması → Task 2. ✓
- Tekrar dene → Task 3, 6. ✓
- Test bölümü (AppModel/Protocol/RemoteCommandHandler) → Task 1-5 testleri. ✓

**Placeholder scan:** Tüm adımlarda gerçek kod ve komutlar var; TBD/TODO yok. ✓

**Type consistency:**
- `SendStatus` (Task 1) ← kullanılıyor Task 2, 3, 6. ✓
- `FeedItem.userMessage(text:status:)` imzası tüm task'larda aynı. ✓
- `dispatch(target:action:userMessageEntryId:)` (Task 1) ← Task 3'te aynı imza. ✓
- `CommandAction.deleteSession(sessionId:)` (Task 4) ← Task 4'te `AppModel.deleteSession`, Task 5 Mac tarafı string `"delete_session"` ile eşleşir. ✓
- `retrySend(sessionId:entryId:)` (Task 3) ← Task 6 UI'da aynı imza. ✓
- `FakeTerminal.kill` kayıt değişikliği (Task 5) `TerminalServicing.kill(id:)` imzasıyla uyumlu. ✓
