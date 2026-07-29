# Lumi Remote — Plan 3.5: Transcript Backfill (Geçmiş Doldurma) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefon bir oturumun detayını açtığında Mac'ten transcript geçmişini çekmesi (`get_history`) — böylece app kapalıyken olan konuşma ve (jsonl'e düşen) soru metni telefonda görünür.

**Architecture:** Yeni komut aksiyonu `get_history {commandId, sessionId}` telefon→relay→Mac akar; Mac, oturumun eşleşmiş jsonl'inin kuyruğunu (~son 256KB) parse edip **tek bir** `event {kind:"history", sessionId, items:[...]}` mesajı + `command_result` döner. Relay'e DOKUNULMAZ: `command` payload'ı relay için opak, `event` payload'ında relay yalnız `kind=="status_change"`a bakar (push kuralı) — `"history"` güvenli. Telefon, history yanıtıyla oturumun feed'ini KOMPLE DEĞİŞTİRİR (dedup derdi yok; dosya, watcher'ın o ana dek yayınladığı her şeyi zaten içerir) ve oturum `waiting` rozetliyse son `turn_done`'dan sonraki soruyu karta yeniden sabitler.

**Tech Stack:** Mevcut yığın — Swift 6, XCTest; Mac tarafı `LumiRemote` (LumiPackages), iOS tarafı `LumiMobileKit` + `LumiMobile/App`.

**Bağlayıcı sözleşme:** `docs/spec/50-remote-protocol.md` (Task 2'de güncellenir). Tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` §5, §12.2.

## Global Constraints

- Zarf ve mesaj TİPLERİ değişmez (hello/welcome/snapshot/event/command/command_result/register_push/ping/pong) — yenilik yalnız payload İÇİNDE: `command.action == "get_history"` ve `event.kind == "history"`; relay/Railway'e dokunulmaz
- `get_history` payload: `{commandId, action:"get_history", sessionId}`; başarı: önce `event {kind:"history", sessionId, items:[<transcript item şekli>]}` sonra `command_result {commandId, ok:true}`; hata: `command_result {ok:false, error:"session_not_found"|"no_transcript"}`
- `items[]` eleman şekli, mevcut `event.item` şekliyle BİREBİR aynıdır (`itemType` + alanlar) — telefon aynı decoder'ı kullanır
- Geriye uyumluluk: eski telefon `history` kind'ını yok sayar (bilinmeyen kind toleransı zaten var); eski Mac `get_history`'ye `unknown_action` döner, telefon bunu KULLANICIYA GÖSTERMEZ (geçmişsiz devam)
- Limitler: en çok **50 item**, dosyanın son **262_144 bayt**'ı (tail); tail ortadan kesilen İLK satır atılır (yarım satır parse edilmez)
- Telefonda history feed'i DEĞİŞTİRİR (append değil); cap 200 korunur; `FeedEntry.id` monoton kalır; history isteğinin başarısızlığı `lastCommandError`/`startState`'e YAZILMAZ (sessiz)
- Soru yeniden sabitleme: history uygulandıktan sonra oturum rozeti `waiting` ise ve son `turn_done`'dan sonra `question` item'ı varsa `activeQuestions[sessionId]`'e yazılır
- Mac testleri: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter LumiRemoteTests` (tam suite Task 2 sonunda: 444+yeni); iOS testleri: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test` (39+yeni); iOS build komutu Plan 3'tekiyle aynı
- Branch: `feature/lumi-remote-backfill` (main'den); commit önekleri: Mac tarafı `remote:`, iOS tarafı `mobile:`; her commit trailer'ı: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## File Structure

```
docs/spec/50-remote-protocol.md                                   (Task 2: get_history + history kind)
LumiPackages/Sources/LumiRemote/TranscriptParser.swift            (Task 1: itemPayload refactoru)
LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift           (Task 1: historyItems(limit:maxTailBytes:))
LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift   (Task 1: yeni testler)
LumiPackages/Sources/LumiRemote/RemoteService.swift               (Task 2: get_history yönlendirmesi)
LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift       (Task 2: yeni testler)
LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift       (Task 3: RemoteEvent.history)
LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift(Task 3: history decode + getHistory encode)
LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift     (Task 3: requestHistory + history uygulama)
LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift (Task 3)
LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift (Task 3)
LumiMobile/App/SessionDetailView.swift                            (Task 4: .task ile istek)
```

---

### Task 1: Mac — FeedItem.itemPayload + TranscriptWatcher.historyItems

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/TranscriptParser.swift:22-37` (eventPayload refactoru)
- Modify: `LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift` (historyItems eklenir)
- Test: `LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift` (dosyanın sonuna yeni testler)

**Interfaces:**
- Consumes: mevcut `FeedItem`, `TranscriptParser.parse(line:)`, `TranscriptWatcher.bestCandidate()`
- Produces: `FeedItem.itemPayload: [String: Any]` (yalnız item sözlüğü, `kind`/`sessionId` YOK), `eventPayload(sessionId:)` davranışı DEĞİŞMEZ (itemPayload'ı sarar), `TranscriptWatcher.historyItems(limit: Int, maxTailBytes: Int) -> [FeedItem]` (actor metodu; eşleşme yoksa bestCandidate ile o an eşleştirmeyi dener, yine yoksa `[]`)

- [ ] **Step 1: Başarısız testleri yaz**

`LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift` dosyasının sonuna (sınıf İÇİNE) ekle — dosyadaki mevcut fixture/tmp-dizin kalıbını izle, mevcut yardımcılar varsa onları kullan; yoksa şu bağımsız testleri ekle:

```swift
    // MARK: - historyItems (Plan 3.5 backfill)

    private func makeHistoryDir() throws -> (root: URL, projectDir: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent(
            TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return (root, projectDir)
    }

    private func writeLines(_ lines: [String], to dir: URL, name: String = "s1.jsonl") throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
    }

    private let assistantLine =
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"MSG"}]}}"#

    func testHistoryItemsReturnsParsedTail() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...5).map { assistantLine.replacingOccurrences(of: "MSG", with: "m\($0)") }
        try writeLines(lines, to: projectDir)

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60))
        let items = await watcher.historyItems(limit: 3, maxTailBytes: 262_144)

        XCTAssertEqual(items, [
            .assistantText("m3"), .assistantText("m4"), .assistantText("m5"),
        ])
    }

    func testHistoryItemsDropsPartialFirstLineWhenTailCut() async throws {
        let (root, projectDir) = try makeHistoryDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...4).map { assistantLine.replacingOccurrences(of: "MSG", with: "m\($0)") }
        try writeLines(lines, to: projectDir)
        // maxTailBytes'ı 2. satırın ortasına denk gelecek kadar küçült:
        // son 3 satır + 2. satırın kuyruğu okunur; yarım satır atılmalı.
        let lineBytes = (lines[0] + "\n").utf8.count
        let tail = lineBytes * 2 + lineBytes / 2

        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date().addingTimeInterval(-60))
        let items = await watcher.historyItems(limit: 50, maxTailBytes: tail)

        XCTAssertEqual(items, [.assistantText("m3"), .assistantText("m4")])
    }

    func testHistoryItemsEmptyWhenNoMatch() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-none-\(UUID().uuidString)")
        let watcher = TranscriptWatcher(
            projectsRoot: root, repoPath: "/tmp/demo",
            sessionCreatedAt: Date())
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        XCTAssertTrue(items.isEmpty)
    }

    func testItemPayloadShapes() {
        XCTAssertEqual(
            FeedItem.assistantText("hi").itemPayload["itemType"] as? String, "assistant_text")
        let tool = FeedItem.toolUse(name: "Bash", summary: "swift test").itemPayload
        XCTAssertEqual(tool["tool"] as? String, "Bash")
        XCTAssertEqual(tool["summary"] as? String, "swift test")
        // eventPayload sarmalaması aynı kalmalı (mevcut telefonlar kırılmasın)
        let wrapped = FeedItem.turnDone.eventPayload(sessionId: "s1")
        XCTAssertEqual(wrapped["kind"] as? String, "transcript")
        XCTAssertEqual((wrapped["item"] as? [String: Any])?["itemType"] as? String, "turn_done")
    }
```

Not: `assistantLine` fixture'ı mevcut `TranscriptParserTests`'teki gerçek claude jsonl şekliyle uyumlu olmalı — parse `type:"assistant"` + `message.content[].type=="text"` yolunu okuyorsa bu satır onu üretir. Mevcut parser testlerindeki fixture şekline BAK ve gerekirse `assistantLine`'ı oradaki gerçek şekle uydur (davranışı değil fixture'ı uyarlıyorsun).

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter TranscriptWatcherTests 2>&1 | tail -5`
Expected: derleme hatası — `historyItems` / `itemPayload` yok.

- [ ] **Step 3: itemPayload refactorunu yaz**

`LumiPackages/Sources/LumiRemote/TranscriptParser.swift` içinde `eventPayload(sessionId:)` şu iki üyeyle değiştirilir (FeedItem enum'unda):

```swift
    /// Yalnız item sözlüğü — hem canlı `transcript` event'inde hem `history`
    /// yanıtında aynı şekil kullanılır (protokol: items[] elemanı).
    var itemPayload: [String: Any] {
        switch self {
        case .assistantText(let text):
            return ["itemType": "assistant_text", "text": text]
        case .toolUse(let name, let summary):
            return ["itemType": "tool_use", "tool": name, "summary": summary]
        case .question(let questions):
            return ["itemType": "question", "questions": questions.map {
                ["header": $0.header, "question": $0.question, "options": $0.options]
            }]
        case .turnDone:
            return ["itemType": "turn_done"]
        }
    }

    func eventPayload(sessionId: String) -> [String: Any] {
        ["kind": "transcript", "sessionId": sessionId, "item": itemPayload]
    }
```

- [ ] **Step 4: historyItems'ı yaz**

`LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift` içine (poll bölümünün altına) ekle:

```swift
    /// Eşleşen jsonl'in kuyruğunu parse edip son `limit` item'ı döner (backfill).
    /// Canlı tail durumuna (offset/pendingPartial) DOKUNMAZ — ayrı handle ile okur.
    /// Henüz eşleşme yoksa o an eşleştirmeyi dener; yine yoksa [].
    func historyItems(limit: Int = 50, maxTailBytes: Int = 262_144) -> [FeedItem] {
        if matchedFile == nil, let best = bestCandidate() {
            matchedFile = best.0
            offset = fileSize(best.0)
            pendingPartial = ""
        }
        guard let file = matchedFile,
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let size = fileSize(file)
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              var chunk = String(data: data, encoding: .utf8) else { return [] }

        // Kuyruk ortadan kesildiyse ilk satır yarımdır — at.
        if start > 0, let newline = chunk.firstIndex(of: "\n") {
            chunk = String(chunk[chunk.index(after: newline)...])
        }
        var items: [FeedItem] = []
        for line in chunk.components(separatedBy: "\n") where !line.isEmpty {
            items.append(contentsOf: TranscriptParser.parse(line: line))
        }
        return items.suffix(limit).map { $0 }
    }
```

Dikkat: `historyItems` ilk-eşleşme yaptığında `offset`'i dosya sonuna kurar — canlı tail davranışı `poll()`'daki ilk-eşleşme kurulumuyla aynıdır (yeni satırlar oradan akmaya devam eder). `start > 0` kontrolü, dosya baştan okunuyorsa ilk satırın atılMAmasını sağlar.

- [ ] **Step 5: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter LumiRemoteTests 2>&1 | grep -E "Executed|error" | tail -3`
Expected: PASS, 0 warning. (Fixture şekli parser'la uyuşmazsa Step 1'deki nota göre fixture'ı düzelt.)

- [ ] **Step 6: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/TranscriptParser.swift LumiPackages/Sources/LumiRemote/TranscriptWatcher.swift LumiPackages/Tests/LumiRemoteTests/TranscriptWatcherTests.swift
git commit -m "remote: TranscriptWatcher.historyItems — jsonl kuyruğundan backfill" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Mac — RemoteService get_history yönlendirmesi + protokol dokümanı

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (`handleInbound` içine)
- Modify: `docs/spec/50-remote-protocol.md`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: `TranscriptWatcher.historyItems(limit:maxTailBytes:)`, `FeedItem.itemPayload` (Task 1); mevcut `watchers: [TerminalID: TranscriptWatcher]`, `connection.send(type:payload:)`
- Produces: `command` payload'ında `action=="get_history"` görüldüğünde: watcher varsa `event {kind:"history", sessionId, items}` + `command_result {ok:true}`; oturum yoksa `{ok:false, error:"session_not_found"}`; watcher var ama item yoksa `{ok:false, error:"no_transcript"}` (event gönderilmez)

- [ ] **Step 1: Başarısız testleri yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift` — `FakeConnection` actor'ına şu sorgu yardımcılarını ekle:

```swift
    // History event query
    func historyEvent() -> (sessionId: String, itemCount: Int)? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "history" })
        else { return nil }
        return ((e.payload["sessionId"] as? String) ?? "",
                (e.payload["items"] as? [[String: Any]])?.count ?? -1)
    }
    func historyFirstItemText() -> String? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "history" }),
              let items = e.payload["items"] as? [[String: Any]] else { return nil }
        return items.first?["text"] as? String
    }
    func commandResultError() -> String? {
        guard let r = sent.first(where: { $0.type == "command_result" }) else { return nil }
        return r.payload["error"] as? String
    }
```

Test sınıfına yeni testler (mevcut `makeService`/`drain` kalıbıyla; `assistantLine` fixture'ı Task 1'dekiyle aynı — dosyada zaten benzeri varsa onu kullan):

```swift
    func testGetHistorySendsHistoryEventAndOkResult() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        // transcript fixture'ı: transcriptsRoot/<encoded>/s1.jsonl
        let projectDir = tempHome.appendingPathComponent("transcripts")
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"gecmis-mesaj"}]}}"#
        try (line + "\n").data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s1.jsonl"))

        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-1", "action": "get_history", "sessionId": meta.id.description,
        ]))
        await drain()

        let history = await connection.historyEvent()
        XCTAssertEqual(history?.sessionId, meta.id.description)
        XCTAssertEqual(history?.itemCount, 1)
        let text = await connection.historyFirstItemText()
        XCTAssertEqual(text, "gecmis-mesaj")
        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, true)
        service.stop()
        await drain()
    }

    func testGetHistoryUnknownSessionReturnsError() async {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-2", "action": "get_history",
            "sessionId": UUID().uuidString,
        ]))
        await drain()

        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, false)
        let error = await connection.commandResultError()
        XCTAssertEqual(error, "session_not_found")
        let history = await connection.historyEvent()
        XCTAssertNil(history)
        service.stop()
        await drain()
    }

    func testGetHistoryNoTranscriptReturnsError() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        _ = try terminal.spawn(repoPath: "/tmp/bos-repo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        let meta = terminal.terminals[0]

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-3", "action": "get_history", "sessionId": meta.id.description,
        ]))
        await drain()

        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, false)
        let error = await connection.commandResultError()
        XCTAssertEqual(error, "no_transcript")
        service.stop()
        await drain()
    }
```

Not: `FakeTerminal.spawn` çağrısı `@MainActor` sınıfta — test sınıfı zaten `@MainActor`. `meta.id.description`'ın UUID string ürettiğini mevcut kodda doğrula (RemoteCommandHandler.session UUID(uuidString:) ile parse ediyor); farklıysa testte `meta.id.raw.uuidString` kullan ve implementasyonda aynı yorumu yap.

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift test --filter RemoteServiceTests 2>&1 | tail -5`
Expected: yeni testler FAIL (`history` event'i yok, command_result `unknown_action`).

- [ ] **Step 3: RemoteService yönlendirmesini yaz**

`LumiPackages/Sources/LumiRemote/RemoteService.swift` — `handleInbound` içindeki `case "command":` şu hale gelir:

```swift
            case "command":
                if payload["action"] as? String == "get_history" {
                    await handleGetHistory(payload)
                } else {
                    let result = await commandHandler.handle(payload)
                    await connection.send(type: "command_result", payload: result)
                }
```

ve sınıfa şu metot eklenir (Transcript bölümünün altına):

```swift
    /// get_history (Plan 3.5): watcher'ın jsonl kuyruğunu tek `history`
    /// event'i olarak döner. Watcher'lara erişim gerektiğinden
    /// RemoteCommandHandler yerine burada ele alınır.
    private func handleGetHistory(_ payload: [String: Any]) async {
        let commandId: Any = (payload["commandId"] as? String) ?? NSNull()
        guard let raw = payload["sessionId"] as? String,
              let uuid = UUID(uuidString: raw),
              let watcher = watchers[TerminalID(raw: uuid)]
        else {
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "session_not_found",
            ])
            return
        }
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        guard !items.isEmpty else {
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "no_transcript",
            ])
            return
        }
        await connection.send(type: "event", payload: [
            "kind": "history", "sessionId": raw, "items": items.map(\.itemPayload),
        ])
        await connection.send(type: "command_result", payload: [
            "commandId": commandId, "ok": true,
        ])
    }
```

- [ ] **Step 4: Protokol dokümanını güncelle**

`docs/spec/50-remote-protocol.md`:
1. "Komut aksiyonları" bölümüne satır ekle:
```markdown
- `get_history {commandId, sessionId}` — oturumun transcript geçmişini ister; Mac önce `event {kind:"history"}` sonra `command_result` döner (Plan 3.5). Hatalar: `session_not_found`, `no_transcript`.
```
2. "event payload — transcript" bölümünün altına yeni alt bölüm:
```markdown
## event payload — history (Plan 3.5 backfill)

`{ "kind": "history", "sessionId": "<uuid>", "items": [ {...}, ... ] }` —
`items[]` elemanları transcript `item` şekliyle birebir aynıdır (`itemType` + alanlar),
en çok 50 eleman (jsonl kuyruğunun son ~256KB'ından). Telefon, oturumun akışını bu
listeyle DEĞİŞTİRİR. Relay bu kind'a bakmaz (push kuralı yalnız `status_change`).
```

- [ ] **Step 5: Tam Mac suite'inin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiPackages && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 444 + yeni testler, 0 failure, 0 warning.

- [ ] **Step 6: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift docs/spec/50-remote-protocol.md
git commit -m "remote: get_history komutu — transcript backfill'i history event'iyle döner" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: iOS — history decode + getHistory komutu + AppModel uygulaması

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (`RemoteEvent`'e case)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (decode + encode)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `ProtocolTests.swift`, `AppModelTests.swift`

**Interfaces:**
- Consumes: mevcut `decodeFeedItem`, `FeedItem`, `dispatch` altyapısı, `FakeRelayClient`
- Produces: `RemoteEvent.history(sessionId: String, items: [FeedItem])`, `CommandAction.getHistory(sessionId: String)` (→ `action:"get_history"`), `AppModel.requestHistory(sessionId: String) async` (macOnline değilse no-op; başarısızlığı KULLANICIYA yansıtmaz), history event'i feed'i değiştirir + cap 200 + `waiting` ise soruyu yeniden sabitler

- [ ] **Step 1: Başarısız testleri yaz**

`ProtocolTests.swift`'e ekle:

```swift
    func testDecodeHistoryEvent() {
        let text = #"{"v":1,"type":"event","payload":{"kind":"history","sessionId":"s1","items":[{"itemType":"assistant_text","text":"eski"},{"itemType":"hologram"},{"itemType":"turn_done"}]}}"#
        guard case .event(.history(let id, let items))? = PhoneProtocol.decodeServerMessage(text) else {
            return XCTFail("history bekleniyordu")
        }
        XCTAssertEqual(id, "s1")
        // bilinmeyen itemType atlanır, kalanlar sıralı gelir
        XCTAssertEqual(items, [.assistantText("eski"), .turnDone])
    }

    func testGetHistoryCommandFrame() throws {
        let cmd = OutgoingCommand(commandId: "ph-9", action: .getHistory(sessionId: "s1"))
        let payload = try payload(of: PhoneProtocol.commandFrame(cmd), expectedType: "command")
        XCTAssertEqual(payload["action"] as? String, "get_history")
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
    }
```

`AppModelTests.swift`'e ekle:

```swift
    func testHistoryReplacesFeedAndRepinsQuestion() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        // canlı akıştan gelmiş eski bir satır — history bunu da içerir, çiftlenmemeli
        model.handle(.event(.transcript(sessionId: "s1", item: .assistantText("canli"))))

        let question = Question(header: "İzin", question: "Devam?", options: ["Evet", "Hayır"])
        model.handle(.event(.history(sessionId: "s1", items: [
            .assistantText("eski-1"),
            .turnDone,
            .assistantText("canli"),
            .question([question]),
        ])))

        // feed DEĞİŞTİ: history listesi (question feed'e girmez), çiftlenme yok
        XCTAssertEqual((model.feeds["s1"] ?? []).map(\.item),
                       [.assistantText("eski-1"), .turnDone, .assistantText("canli")])
        // id'ler monoton
        let ids = (model.feeds["s1"] ?? []).map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        // waiting + son turn_done'dan sonra soru var → kart yeniden sabitlendi
        XCTAssertEqual(model.questionCard(for: "s1")?.questions, [question])
    }

    func testHistoryDoesNotRepinWhenQuestionAnswered() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        model.handle(.event(.history(sessionId: "s1", items: [
            .question([Question(header: "h", question: "q", options: [])]),
            .turnDone,
        ])))
        // rozet waiting değil → sabitleme yok; turn_done sorudan sonra → zaten cevaplanmış
        XCTAssertNil(model.questionCard(for: "s1"))
    }

    func testHistoryCapsAt200() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        let items = (0..<250).map { FeedItem.assistantText("m\($0)") }
        model.handle(.event(.history(sessionId: "s1", items: items)))
        XCTAssertEqual(model.feeds["s1"]?.count, 200)
        XCTAssertEqual(model.feeds["s1"]?.last?.item, .assistantText("m249"))
    }

    func testRequestHistorySendsCommandAndFailureIsSilent() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        model.handle(.welcome(Welcome(snapshot: nil, macOnline: true, lastSeenAt: nil)))

        await model.requestHistory(sessionId: "s1")
        XCTAssertEqual(client.commands.count, 1)
        guard case .getHistory(let sid) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")

        // eski Mac: unknown_action → kullanıcıya YANSIMAZ
        model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: false, error: "unknown_action")))
        XCTAssertNil(model.lastCommandError["s1"])
        XCTAssertEqual(model.startState, .idle)
    }

    func testRequestHistoryNoopWhenMacOffline() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        model.handle(.welcome(Welcome(snapshot: nil, macOnline: false, lastSeenAt: nil)))
        await model.requestHistory(sessionId: "s1")
        XCTAssertTrue(client.commands.isEmpty)
    }
```

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: derleme hatası — `.history` / `.getHistory` / `requestHistory` yok.

- [ ] **Step 3: Modelleri ve codec'i güncelle**

`Models.swift` — `RemoteEvent`'e case ekle:

```swift
public enum RemoteEvent: Sendable, Equatable {
    case statusChange(sessionId: String, status: SessionStatus, repoName: String, summary: String?)
    case transcript(sessionId: String, item: FeedItem)
    case history(sessionId: String, items: [FeedItem])
}
```

`PhoneProtocol.swift` — `decodeEvent`'e case ekle (`transcript`'in altına):

```swift
        case "history":
            guard let rawItems = payload["items"] as? [[String: Any]] else { return nil }
            let items = rawItems.compactMap(decodeFeedItem)
            return .history(sessionId: sessionId, items: items)
```

`CommandAction`'a case + `commandFrame`'e kol ekle:

```swift
    case getHistory(sessionId: String)
```
```swift
        case .getHistory(let sessionId):
            payload["action"] = "get_history"
            payload["sessionId"] = sessionId
```

- [ ] **Step 4: AppModel'i güncelle**

`AppModel.swift`:

1. Yeni private durum: `private var historyCommandIds: Set<String> = []`
2. `handle`'a case ekle (`transcript` case'inin altına):

```swift
        case .event(.history(let sessionId, let items)):
            macOnline = true
            applyHistory(sessionId: sessionId, items: items)
```

3. `commandResult` case'inin BAŞINA history süzgeci:

```swift
        case .commandResult(let result):
            if historyCommandIds.remove(result.commandId) != nil {
                return // geçmiş isteğinin sonucu kullanıcıya yansıtılmaz (ok da olsa hata da)
            }
            guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
            ...
```

4. Yeni metotlar (Komutlar bölümüne):

```swift
    /// Oturum detayı açılınca çağrılır: transcript geçmişini ister.
    /// Başarısızlık kullanıcıya yansıtılmaz (eski Mac `unknown_action`,
    /// eşleşmesiz oturum `no_transcript` döndürebilir — ikisi de normaldir).
    public func requestHistory(sessionId: String) async {
        guard macOnline else { return }
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        historyCommandIds.insert(commandId)
        await client.send(command: OutgoingCommand(
            commandId: commandId, action: .getHistory(sessionId: sessionId)))
    }

    private func applyHistory(sessionId: String, items: [FeedItem]) {
        var entries: [FeedEntry] = []
        for item in items {
            switch item {
            case .question:
                continue // sorular akışa değil karta gider
            default:
                feedCounter += 1
                entries.append(FeedEntry(id: feedCounter, item: item))
            }
        }
        if entries.count > Self.feedCap {
            entries.removeFirst(entries.count - Self.feedCap)
        }
        feeds[sessionId] = entries

        // waiting rozetli oturumda son turn_done'dan SONRAKİ soru hâlâ açıktır → sabitle
        guard session(sessionId)?.status.badge == .waiting else { return }
        var openQuestion: [Question]?
        for item in items {
            switch item {
            case .question(let questions): openQuestion = questions
            case .turnDone: openQuestion = nil
            default: break
            }
        }
        if let openQuestion {
            activeQuestions[sessionId] = openQuestion
        }
    }
```

Not: `requestHistory` `dispatch`'i KULLANMAZ — dispatch `activeQuestions`/`lastCommandError` temizliği yapar ve başarısızlıkta hata yazar; history'nin ikisini de yapmaması gerekir. `unpair()` içine `historyCommandIds = []` sıfırlaması da ekle.

- [ ] **Step 5: Testlerin geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/LumiMobile/LumiMobileKit && swift test 2>&1 | grep -E "Executed|error" | tail -3`
Expected: 39 + yeni testler PASS, 0 warning.

- [ ] **Step 6: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/LumiMobileKit
git commit -m "mobile: transcript backfill — get_history komutu, history event'i feed'i doldurur" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: iOS UI bağlama + build + doğrulama

**Files:**
- Modify: `LumiMobile/App/SessionDetailView.swift`

**Interfaces:**
- Consumes: `AppModel.requestHistory(sessionId:)` (Task 3)
- Produces: detay ekranı açılınca geçmiş isteği; simülatör build'i yeşil

- [ ] **Step 1: Detay ekranına isteği bağla**

`LumiMobile/App/SessionDetailView.swift` — `body`'deki dış `VStack`'in modifier zincirine (`.navigationTitle(...)` satırının ÜSTÜNE) ekle:

```swift
        .task(id: sessionId) { await model.requestHistory(sessionId: sessionId) }
```

- [ ] **Step 2: Build**

Run:
```bash
cd /Users/balkan/Lumi/LumiMobile && xcodegen generate && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd /Users/balkan/Lumi
git add LumiMobile/App/SessionDetailView.swift
git commit -m "mobile: oturum detayı açılınca geçmiş isteği" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Canlı doğrulama (kontrolör)**

Kontrolör, Plan 3 Task 10 altyapısıyla doğrular: Mac Lumi'yi (GUI Terminal'den) yeni build'le yeniden başlat, mevcut/yeni bir claude oturumu konuşturduktan SONRA telefon/simülatör app'ini aç → detaya gir → geçmişin (app kapalıyken yazılmış mesajların) aktığını gör; `waiting` oturumda soru metninin karta geldiğini gör. Gerçek cihaza güncel build kur (`xcodebuild ... -destination 'generic/platform=iOS' ... && xcrun devicectl device install app ...`).

---

## Bitiş

Tamamlanınca `superpowers:finishing-a-development-branch` → main'e merge. Yürütme kalıbı: Task 1-3 kod planda tam yazılı ama mevcut dosyalara dokunuyor → implementer=sonnet (Task 1-2 Mac tarafı mevcut suite'i bozmamalı), Task 4=haiku olabilir; incelemeler=sonnet; final inceleme küçük diff için sonnet yeterli.
