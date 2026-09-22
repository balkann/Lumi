# Faz 3 — Etkileşimli Prompt Kartları Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefon chat'inde ajan bir karar beklediğinde (izin veya AskUserQuestion) tıklanabilir kart göster; seçilen cevabı hook-first journal + PTY keystroke ile ajana ulaştır.

**Architecture:** Hook olayları (Faz 2 tap'i) `tool_input` ile zenginleştirilir; saf `PromptJournal` (LumiKit) bunları `ChatPrompt` item'larına katlar; `RemoteService` `prompt` frame'i yayınlar (Mac→relay→telefon); telefon `prompt_respond` yollar; host `optionId`'yi tek-bayt keystroke'a çevirip PTY'ye yazar (`writeInput`), item'ı resolved işaretleyip yayınlar. Referans: orca (hook-first + keystroke actuation).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (iOS 17+), `AsyncStream`, TypeScript (RelayServer, node:test), XCTest + swift-testing.

## Global Constraints

- **main'e commit YOK.** Branch: `feat/remote-orca-main`.
- **Kaynak: hook-first (orca paritesi), terminal-scrape YOK.** Hook script + installer DEĞİŞMEZ (payload'ın tamamını zaten forward eder; `PermissionRequest`+`PreToolUse` matcher `*` zaten kayıtlı). Tek hook değişikliği: decoder `tool_input` çıkarır.
- **Wire modeli değişmez pattern:** model LumiKit'te, LumiMobileKit'e birebir kopya (Faz 1/2 `ChatMessage`/`ChatTurnStatus` kalıbı).
- **`prompt` frame payload:** `ChatPrompt.toDict()` + `sessionId`. `type` string tam `"prompt"`. Mac→telefon.
- **`prompt_respond` frame payload:** `{ sessionId, itemId, expectedRevision, optionId }`. `type` string tam `"prompt_respond"`. Telefon→Mac.
- **Keystroke actuation (orca kodundan, kesin):** approval allow → `Data([0x31])` (`"1"`); deny → `Data([0x1b])` (ESC); question tek-select index `i` → `Data([UInt8(0x31 + i)])` (`"1"`..`"9"`). **Trailing Enter YOK.** `terminal.writeInput(_:to:)` ile.
- **Kapsam Faz 3.0:** izin (Allow/Deny) + tek-soru tek-seçim. multiSelect/gruplu/free-text/Codex/"don't ask again" = DIŞ.
- **`PromptJournal` ve `ChatPrompt` LumiKit'te** (Faz 2 `TurnStatusReducer` gibi; LumiRemote yalnız LumiKit'e bağlı).
- **LumiMobile literal kullanır**, Theme token değil (`DesignTokenLintTests` LumiMobile'ı kapsamaz).
- **Optimistic dismiss YOK:** kart, resolution broadcast'i (state=resolved/cancelled) gelince kaybolur.
- **Build/test:** `cd LumiPackages && swift build && swift test --scratch-path /tmp/lumi`; `cd LumiMobile/LumiMobileKit && swift test`; `cd RelayServer && npm test`.
- **Launch-env kuralı:** app'i Claude bash'ından başlatma; KULLANICI Finder/Dock'tan başlatır. Cihaz + relay deploy (lumi-relay servisi) kullanıcıya.

## File Structure

- **Modify** `LumiPackages/Sources/LumiKit/Models/AgentHookModels.swift` — `AgentHookEvent.toolInput`/`toolUseID` + `parse` çıkarımı.
- **Create** `LumiPackages/Sources/LumiKit/Models/ChatPrompt.swift` — wire modeli + `toDict()` + `.pending/.resolved`.
- **Create** `LumiPackages/Sources/LumiKit/NativeChat/PromptJournal.swift` — saf hook→prompt reducer.
- **Modify** `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` — `promptPayload` + `decodePromptRespond`.
- **Modify** `LumiPackages/Sources/LumiRemote/RemoteService.swift` — journal tap + prompt yayını + snapshot + prompt_respond→keystroke + cleanup.
- **Modify** `RelayServer/src/protocol.ts`, `RelayServer/src/bridge.ts` — `prompt`/`prompt_respond` passthrough.
- **Create** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift` — LumiKit kopyası + `decode`.
- **Modify** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` — `ServerMessage.prompt` decode + `promptRespondFrame`.
- **Modify** `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — `prompts` merge + `respondPrompt` + temizlik.
- **Create** `LumiMobile/App/MobileChatPromptCard.swift` — SwiftUI kart.
- **Modify** `LumiMobile/App/MobileChatView.swift` — kartı composer üstüne yerleştir.

---

### Task 1: `AgentHookEvent.toolInput` / `toolUseID` (LumiKit decoder)

**Files:**
- Modify: `LumiPackages/Sources/LumiKit/Models/AgentHookModels.swift` (struct alanları + init + `parse` ~satır 152-176)
- Test: `LumiPackages/Tests/LumiKitTests/AgentHookToolInputTests.swift`

**Interfaces:**
- Produces: `AgentHookEvent.toolInput: String?` (ham tool_input JSON, ≤16 KB else nil), `AgentHookEvent.toolUseID: String?`. `parse(...)` bunları doldurur.

- [ ] **Step 1: Write the failing test**

`AgentHookToolInputTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiKit

@Suite struct AgentHookToolInputTests {
    private func parse(_ json: String) -> AgentHookEvent? {
        AgentHookEvent.parse(provider: .claude, terminalID: TerminalID(),
                             body: Data(json.utf8), receivedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func extractsToolInputObjectAsString() {
        let e = parse(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q"}]},"tool_use_id":"tu_1"}"#)
        #expect(e?.toolName == "AskUserQuestion")
        #expect(e?.toolUseID == "tu_1")
        // toolInput geçerli JSON string olmalı ve "questions" içermeli
        let data = e?.toolInput.flatMap { $0.data(using: .utf8) }
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(obj?["questions"] != nil)
    }

    @Test func nilToolInputWhenAbsent() {
        let e = parse(#"{"hook_event_name":"Stop"}"#)
        #expect(e?.toolInput == nil)
        #expect(e?.toolUseID == nil)
    }

    @Test func nilWhenToolInputExceedsCap() {
        let big = String(repeating: "x", count: 20_000)
        let e = parse(#"{"hook_event_name":"PreToolUse","tool_input":{"blob":"\#(big)"}}"#)
        #expect(e?.toolInput == nil)   // 16 KB tavan aşıldı
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/AgentHookToolInputTests`
Expected: FAIL — `AgentHookEvent` `toolInput` üyesi yok.

- [ ] **Step 3: Add struct fields + init params**

`AgentHookModels.swift`, `promptHead` alanının yakınına (public let bloğu):
```swift
    /// PreToolUse/PermissionRequest ham `tool_input` JSON'u (string; ≤16 KB, yoksa nil).
    public let toolInput: String?
    /// Hook'tan `tool_use_id` — prompt itemId stabilitesi için.
    public let toolUseID: String?
```
init parametre listesinin sonuna (mevcut `receivedAt`'ten önce, default'lu):
```swift
        toolInput: String? = nil,
        toolUseID: String? = nil,
```
init gövdesine:
```swift
        self.toolInput = toolInput
        self.toolUseID = toolUseID
```

- [ ] **Step 4: Extract in `parse`**

`parse(...)`'ta `AgentHookEvent(` çağrısına (satır ~163), `runningBackgroundAgentIDs`'ten sonra:
```swift
            toolInput: serializedToolInput(dict["tool_input"]),
            toolUseID: string(dict["tool_use_id"]),
```
`string(_:)` helper'ının yanına yeni helper:
```swift
    /// tool_input nesnesini/array'ini JSON string'e çevirir (16 KB tavanı; aşarsa nil).
    private static func serializedToolInput(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let obj: Any
        if value is [String: Any] || value is [Any] { obj = value }
        else if let s = value as? String { return s.count <= 16_384 ? s : nil }
        else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              data.count <= 16_384, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/AgentHookToolInputTests`
Expected: PASS (3). Ayrıca `swift build` (mevcut AgentHookEvent çağrı yerleri default'la derlenir).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/AgentHookModels.swift LumiPackages/Tests/LumiKitTests/AgentHookToolInputTests.swift
git commit -m "feat(hooks): AgentHookEvent tool_input/tool_use_id çıkarımı (Faz 3)"
```

---

### Task 2: `ChatPrompt` wire modeli (LumiKit)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Models/ChatPrompt.swift`
- Test: `LumiPackages/Tests/LumiKitTests/ChatPromptTests.swift`

**Interfaces:**
- Produces: `ChatPromptKind{approval,question}`, `ChatPromptState{pending,resolved,cancelled}`, `ChatPromptOption{id,label,description?}`, `ChatPrompt{itemId,revision,kind,title,detail?,options,state,selectedOptionId?}` (Sendable, Equatable), `toDict() -> [String:Any]`.

- [ ] **Step 1: Write the failing test**

`ChatPromptTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiKit

@Suite struct ChatPromptTests {
    @Test func toDictEncodesOptionsAndState() {
        let p = ChatPrompt(itemId: "i1", revision: 2, kind: .question, title: "Pick",
            detail: nil, options: [ChatPromptOption(id: "opt-0", label: "A", description: "aa")],
            state: .pending, selectedOptionId: nil)
        let d = p.toDict()
        #expect(d["itemId"] as? String == "i1")
        #expect(d["revision"] as? Int == 2)
        #expect(d["kind"] as? String == "question")
        #expect(d["state"] as? String == "pending")
        #expect(d["selectedOptionId"] is NSNull)
        let opts = d["options"] as? [[String: Any]]
        #expect(opts?.first?["id"] as? String == "opt-0")
        #expect(opts?.first?["label"] as? String == "A")
        #expect(opts?.first?["description"] as? String == "aa")
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/ChatPromptTests`
Expected: FAIL — `ChatPrompt` yok.

- [ ] **Step 3: Write the model**

`LumiPackages/Sources/LumiKit/Models/ChatPrompt.swift`:
```swift
import Foundation

/// Faz 3 etkileşimli prompt wire modeli (orca paritesi). LumiKit'te tanımlanır,
/// LumiMobileKit'e birebir kopyalanır. `sessionId` frame zarfında taşınır.
public enum ChatPromptKind: String, Sendable, Equatable { case approval, question }
public enum ChatPromptState: String, Sendable, Equatable { case pending, resolved, cancelled }

public struct ChatPromptOption: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?
    public init(id: String, label: String, description: String?) {
        self.id = id; self.label = label; self.description = description
    }
    public func toDict() -> [String: Any] {
        ["id": id, "label": label, "description": description.map { $0 as Any } ?? NSNull()]
    }
}

public struct ChatPrompt: Sendable, Equatable {
    public var itemId: String
    public var revision: Int
    public var kind: ChatPromptKind
    public var title: String
    public var detail: String?
    public var options: [ChatPromptOption]
    public var state: ChatPromptState
    public var selectedOptionId: String?

    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String,
                detail: String?, options: [ChatPromptOption], state: ChatPromptState,
                selectedOptionId: String?) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state
        self.selectedOptionId = selectedOptionId
    }

    public func toDict() -> [String: Any] {
        [
            "itemId": itemId, "revision": revision, "kind": kind.rawValue, "title": title,
            "detail": detail.map { $0 as Any } ?? NSNull(),
            "options": options.map { $0.toDict() },
            "state": state.rawValue,
            "selectedOptionId": selectedOptionId.map { $0 as Any } ?? NSNull(),
        ]
    }
}
```

- [ ] **Step 4: Run to verify PASS**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/ChatPromptTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/ChatPrompt.swift LumiPackages/Tests/LumiKitTests/ChatPromptTests.swift
git commit -m "feat(remote): ChatPrompt wire modeli (Faz 3)"
```

---

### Task 3: `PromptJournal` (LumiKit, saf)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/NativeChat/PromptJournal.swift`
- Test: `LumiPackages/Tests/LumiKitTests/PromptJournalTests.swift`

**Interfaces:**
- Consumes: `AgentHookEvent` (Task 1 `toolInput`/`toolUseID`, `isUserQuestionTool`, `isLead`), `ChatPrompt` (Task 2).
- Produces: `public final class PromptJournal` — `init(seq: @escaping () -> Int)` (itemId stabilitesi için sıra üreteci; test'te deterministik), `private(set) var items: [ChatPrompt]` (pending + son değişenler), `func reduce(_ event: AgentHookEvent) -> [ChatPrompt]` (değişen item'lar; boşsa değişiklik yok).

Kurallar:
| Event | Etki |
|---|---|
| `preToolUse` + `isUserQuestionTool` + `isLead` + toolInput parse | question item ekle (pending); options = questions[0].options |
| `permissionRequest` + `isLead` | approval item ekle (pending); options=[allow,deny]; title/detail toolName+toolInput'tan |
| `postToolUse`/`postToolUseFailure` (isLead) | eşleşen pending item → cancelled |
| `stop`/`stopFailure` | tüm pending → cancelled |
| `sessionStart` source=="clear" | tüm item'ları temizle |
| diğer | boş dön |

itemId = `event.toolUseID ?? "item-\(seq())"`. Aynı toolUseID tekrar gelirse mevcut item güncellenir (revision +1 yalnız içerik değişince). Idempotent: içerik+state aynıysa boş dön.

- [ ] **Step 1: Write the failing test**

`PromptJournalTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiKit

@Suite struct PromptJournalTests {
    private let term = TerminalID()
    private func ev(_ kind: AgentHookEventKind, tool: String? = nil, input: String? = nil,
                    useID: String? = nil, source: String? = nil, agentID: String? = nil) -> AgentHookEvent {
        AgentHookEvent(provider: .claude, terminalID: term, kind: kind, agentID: agentID,
                       teammateName: nil, toolName: tool, source: source, trigger: nil,
                       isInterrupt: false, promptHead: nil, runningBackgroundAgentIDs: nil,
                       toolInput: input, toolUseID: useID)
    }
    private func journal() -> PromptJournal { var n = 0; return PromptJournal(seq: { n += 1; return n }) }

    @Test func askUserQuestionBecomesQuestionItem() {
        let j = journal()
        let input = #"{"questions":[{"question":"Pick DB","options":[{"label":"PG","description":"rel"},{"label":"Mongo"}]}]}"#
        let changed = j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: input, useID: "tu1"))
        #expect(changed.count == 1)
        let p = changed[0]
        #expect(p.kind == .question)
        #expect(p.itemId == "tu1")
        #expect(p.title == "Pick DB")
        #expect(p.options.map(\.label) == ["PG", "Mongo"])
        #expect(p.options[0].id == "opt-0")
        #expect(p.state == .pending)
    }

    @Test func permissionBecomesApprovalItem() {
        let j = journal()
        let changed = j.reduce(ev(.permissionRequest, tool: "Bash", input: #"{"command":"npm i"}"#, useID: "tu2"))
        #expect(changed.count == 1)
        #expect(changed[0].kind == .approval)
        #expect(changed[0].options.map(\.id) == ["allow", "deny"])
    }

    @Test func postToolCancelsPending() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu3"))
        let changed = j.reduce(ev(.postToolUse, tool: "Bash", useID: "tu3"))
        #expect(changed.first?.state == .cancelled)
    }

    @Test func stopCancelsAllPending() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu4"))
        let changed = j.reduce(ev(.stop))
        #expect(changed.allSatisfy { $0.state == .cancelled })
        #expect(!changed.isEmpty)
    }

    @Test func subagentAndUnrelatedIgnored() {
        let j = journal()
        #expect(j.reduce(ev(.preToolUse, tool: "AskUserQuestion", input: "{}", agentID: "sub")).isEmpty)
        #expect(j.reduce(ev(.preToolUse, tool: "Bash", input: "{}")).isEmpty) // soru değil, izin değil
    }

    @Test func clearResetsJournal() {
        let j = journal()
        _ = j.reduce(ev(.permissionRequest, tool: "Bash", input: "{}", useID: "tu5"))
        _ = j.reduce(ev(.sessionStart, source: "clear"))
        #expect(j.items.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/PromptJournalTests`
Expected: FAIL — `PromptJournal` yok.

- [ ] **Step 3: Write the journal**

`LumiPackages/Sources/LumiKit/NativeChat/PromptJournal.swift`:
```swift
import Foundation

/// Saf, test-edilebilir etkileşimli-prompt reducer (spec §4.3). Session başına bir örnek;
/// hook olaylarını `ChatPrompt` item'larına katlar. Faz 3.0: izin + tek-soru tek-seçim.
public final class PromptJournal {
    private let seq: () -> Int
    public private(set) var items: [ChatPrompt] = []

    public init(seq: @escaping () -> Int = { 0 }) { self.seq = seq }

    /// Değişen (yeni/güncellenen/iptal) item'ları döndürür; değişiklik yoksa boş.
    public func reduce(_ event: AgentHookEvent) -> [ChatPrompt] {
        switch event.kind {
        case .preToolUse where event.isUserQuestionTool && event.isLead:
            guard let p = makeQuestion(event) else { return [] }
            return upsert(p)
        case .permissionRequest where event.isLead:
            guard let p = makeApproval(event) else { return [] }
            return upsert(p)
        case .postToolUse, .postToolUseFailure:
            guard event.isLead, let id = event.toolUseID else { return [] }
            return cancel(where: { $0.itemId == id })
        case .stop, .stopFailure:
            return cancel(where: { $0.state == .pending })
        case .sessionStart where event.source == "clear":
            let had = !items.isEmpty
            items.removeAll()
            return had ? [] : []   // reset; yayına gerek yok (telefon /clear'ı ayrı işler)
        default:
            return []
        }
    }

    private func itemId(_ event: AgentHookEvent) -> String { event.toolUseID ?? "item-\(seq())" }

    private func makeQuestion(_ event: AgentHookEvent) -> ChatPrompt? {
        guard let obj = parse(event.toolInput),
              let questions = obj["questions"] as? [[String: Any]],
              let q0 = questions.first,
              let question = q0["question"] as? String else { return nil }
        let rawOptions = (q0["options"] as? [[String: Any]]) ?? []
        let options = rawOptions.enumerated().compactMap { (i, o) -> ChatPromptOption? in
            guard let label = o["label"] as? String else { return nil }
            return ChatPromptOption(id: "opt-\(i)", label: label, description: o["description"] as? String)
        }
        guard !options.isEmpty else { return nil }
        return ChatPrompt(itemId: itemId(event), revision: 0, kind: .question, title: question,
                          detail: nil, options: options, state: .pending, selectedOptionId: nil)
    }

    private func makeApproval(_ event: AgentHookEvent) -> ChatPrompt? {
        let tool = event.toolName ?? "araç"
        let detail = event.toolInput.flatMap { summarize($0) }
        let options = [ChatPromptOption(id: "allow", label: "Allow", description: nil),
                       ChatPromptOption(id: "deny", label: "Deny", description: nil)]
        return ChatPrompt(itemId: itemId(event), revision: 0, kind: .approval,
                          title: "\(tool) çalıştırılsın mı?", detail: detail,
                          options: options, state: .pending, selectedOptionId: nil)
    }

    /// itemId ile ekle/güncelle; içerik değişmediyse boş dön (idempotent).
    private func upsert(_ p: ChatPrompt) -> [ChatPrompt] {
        if let idx = items.firstIndex(where: { $0.itemId == p.itemId }) {
            var existing = items[idx]
            if existing.kind == p.kind && existing.title == p.title
                && existing.options == p.options && existing.state == p.state { return [] }
            existing.kind = p.kind; existing.title = p.title; existing.detail = p.detail
            existing.options = p.options; existing.state = p.state; existing.revision += 1
            items[idx] = existing
            return [existing]
        }
        items.append(p)
        return [p]
    }

    private func cancel(where match: (ChatPrompt) -> Bool) -> [ChatPrompt] {
        var changed: [ChatPrompt] = []
        for idx in items.indices where items[idx].state == .pending && match(items[idx]) {
            items[idx].state = .cancelled
            items[idx].revision += 1
            changed.append(items[idx])
        }
        return changed
    }

    private func parse(_ s: String?) -> [String: Any]? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func summarize(_ input: String) -> String? {
        guard let obj = parse(input) else { return input.count <= 120 ? input : nil }
        if let cmd = obj["command"] as? String { return cmd }
        if let path = obj["file_path"] as? String { return path }
        return nil
    }
}
```

> Not: `sessionStart(clear)` item'ları temizler ama boş yayınlar — telefon `/clear`'da prompts'u ayrıca sıfırlar (Task 8 AppModel). Cancel edilen item'lar `items`'ta kalır (telefon resolved/cancelled görünce düşürür); pending sayımı için `state` bakılır. `makeApproval`'ın `title`/`Allow`/`Deny` literalleri Faz 4 lokalizasyon kapsam dışı.

- [ ] **Step 4: Run to verify PASS**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiKitTests/PromptJournalTests`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/NativeChat/PromptJournal.swift LumiPackages/Tests/LumiKitTests/PromptJournalTests.swift
git commit -m "feat(remote): PromptJournal — hook olayları → ChatPrompt item'ları (Faz 3)"
```

---

### Task 4: `RemoteProtocol.promptPayload` + `decodePromptRespond`

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` (chatStatusPayload yanına)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift` (mevcut suite'e ekle)

**Interfaces:**
- Produces: `static func promptPayload(sessionId: String, prompt: ChatPrompt) -> [String: Any]` (prompt.toDict()+sessionId); `static func decodePromptRespond(_ payload: [String: Any]) -> (sessionId: String, itemId: String, expectedRevision: Int, optionId: String)?`.

- [ ] **Step 1: Write the failing test**

`RemoteProtocolTests.swift`'e ekle:
```swift
@Suite struct RemoteProtocolPromptTests {
    @Test func promptPayloadCarriesSessionIdAndItem() {
        let p = ChatPrompt(itemId: "i1", revision: 0, kind: .approval, title: "Bash?", detail: "npm i",
            options: [ChatPromptOption(id: "allow", label: "Allow", description: nil)],
            state: .pending, selectedOptionId: nil)
        let d = RemoteProtocol.promptPayload(sessionId: "s1", prompt: p)
        #expect(d["sessionId"] as? String == "s1")
        #expect(d["itemId"] as? String == "i1")
        #expect(d["kind"] as? String == "approval")
    }
    @Test func decodePromptRespondParsesFields() {
        let r = RemoteProtocol.decodePromptRespond(["sessionId": "s1", "itemId": "i1", "expectedRevision": 2, "optionId": "allow"])
        #expect(r?.sessionId == "s1"); #expect(r?.itemId == "i1")
        #expect(r?.expectedRevision == 2); #expect(r?.optionId == "allow")
    }
    @Test func decodePromptRespondNilOnMissing() {
        #expect(RemoteProtocol.decodePromptRespond(["sessionId": "s1"]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteProtocolPromptTests`
Expected: FAIL — üyeler yok.

- [ ] **Step 3: Add helpers**

`RemoteProtocol.swift`, `chatStatusPayload`'ın altına:
```swift
/// `prompt` payload: bir oturumun etkileşimli prompt item'ı (Faz 3). Mac→telefon.
static func promptPayload(sessionId: String, prompt: ChatPrompt) -> [String: Any] {
    var dict = prompt.toDict()
    dict["sessionId"] = sessionId
    return dict
}

/// `prompt_respond` çözer (Faz 3). Telefon→Mac.
static func decodePromptRespond(_ payload: [String: Any]) -> (sessionId: String, itemId: String, expectedRevision: Int, optionId: String)? {
    guard let sessionId = payload["sessionId"] as? String,
          let itemId = payload["itemId"] as? String,
          let rev = payload["expectedRevision"] as? Int,
          let optionId = payload["optionId"] as? String else { return nil }
    return (sessionId, itemId, rev, optionId)
}
```

- [ ] **Step 4: Run to verify PASS**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteProtocolPromptTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteProtocol.swift LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift
git commit -m "feat(remote): RemoteProtocol prompt/prompt_respond codec (Faz 3)"
```

---

### Task 5: `RemoteService` journal entegrasyonu + prompt_respond → keystroke

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServicePromptTests.swift`

**Interfaces:**
- Consumes: `PromptJournal` (Task 3), `RemoteProtocol.promptPayload`/`decodePromptRespond` (Task 4), Faz 2 `handleHookEvent`/`chatSubscriptions`/`terminal.writeInput`.
- Produces: prompt journal per session; `prompt` frame yayını (değişimde + subscribe snapshot); `prompt_respond` işleme → keystroke actuation.

Notlar (mevcut anchor'lar): `handleInbound` dispatch satır ~154-160; `handleHookEvent` satır ~308 (turnReducers ilerletir); `emitTurnStatus` ~320; `handleInput` ~352 (`terminal.writeInput`); chat subscribe snapshot ~260; `.exited` cleanup ~180; `shutdown` ~121. Hook stream Faz 2'de zaten enjekte (assembly değişmez).

- [ ] **Step 1: Write the failing test**

`RemoteServicePromptTests.swift` (RemoteServiceTurnStatusTests kalıbı — chat session setup + FakeAgentHookServer + FakeRelayConnection helpers'ı kullan):
```swift
import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiRemote

@Suite @MainActor struct RemoteServicePromptTests {
    private func hookEvent(_ kind: AgentHookEventKind, terminalID: TerminalID, tool: String? = nil,
                           input: String? = nil, useID: String? = nil) -> AgentHookEvent {
        AgentHookEvent(provider: .claude, terminalID: terminalID, kind: kind, agentID: nil,
                       teammateName: nil, toolName: tool, source: nil, trigger: nil,
                       isInterrupt: false, promptHead: nil, runningBackgroundAgentIDs: nil,
                       toolInput: input, toolUseID: useID)
    }

    @Test func permissionPromptEmittedThenResolvedByRespond() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let hooks = FakeAgentHookServer()
        let uuid = UUID()
        let meta = TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo",
                                createdAt: Date(), claudeSessionID: uuid.uuidString)
        term.metas.append(meta)
        let sid = meta.id.description
        let id = TerminalID(raw: uuid)
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []), hookEvents: hooks.events())
        await svc.start()
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat_status"])   // Faz 2 snapshot

        // permission hook → prompt frame (pending, approval)
        hooks.emit(hookEvent(.permissionRequest, terminalID: id, tool: "Bash", input: #"{"command":"npm i"}"#, useID: "tu1"))
        try await conn.waitForCount(type: "prompt", atLeast: 1)
        #expect(await conn.lastString(type: "prompt", key: "kind") == "approval")
        #expect(await conn.lastString(type: "prompt", key: "state") == "pending")

        // telefon Allow → keystroke "1" PTY'ye yazılır + resolved yayınlanır
        await conn.injectInbound(type: "prompt_respond",
            payload: ["sessionId": sid, "itemId": "tu1", "expectedRevision": 0, "optionId": "allow"])
        try await conn.waitForCount(type: "prompt", atLeast: 2)
        #expect(await conn.lastString(type: "prompt", key: "state") == "resolved")
        #expect(term.writtenInput[id] == Data([0x31]))   // "1"
        svc.stop()
    }

    @Test func denyWritesEscape() async throws {
        let conn = FakeRelayConnection(); let term = FakeTerminalServicing(); let hooks = FakeAgentHookServer()
        let uuid = UUID()
        term.metas.append(TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo", createdAt: Date(), claudeSessionID: uuid.uuidString))
        let sid = TerminalID(raw: uuid).description; let id = TerminalID(raw: uuid)
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []), hookEvents: hooks.events())
        await svc.start()
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat_status"])
        hooks.emit(hookEvent(.permissionRequest, terminalID: id, tool: "Bash", input: "{}", useID: "tu9"))
        try await conn.waitForCount(type: "prompt", atLeast: 1)
        await conn.injectInbound(type: "prompt_respond", payload: ["sessionId": sid, "itemId": "tu9", "expectedRevision": 0, "optionId": "deny"])
        try await conn.waitForCount(type: "prompt", atLeast: 2)
        #expect(term.writtenInput[id] == Data([0x1b]))
        svc.stop()
    }
}
```
> `waitForCount`/`lastString` yardımcıları Faz 2'de `FakeRelayConnection`'a eklendi. `term.writtenInput` FakeTerminalServicing'de mevcut (`private(set) var writtenInput`).

- [ ] **Step 2: Run to verify FAIL**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests/RemoteServicePromptTests`
Expected: FAIL — `prompt` frame yayılmıyor.

- [ ] **Step 3: Add journal state + hook integration**

`RemoteService.swift`, `turnReducers` yanına:
```swift
    private var promptJournals: [TerminalID: PromptJournal] = [:]
    private var promptSeq = 0
```
`handleHookEvent(_:)` içinde (turnReducer ilerletildikten sonra), fonksiyon sonuna:
```swift
        let journal = promptJournals[id] ?? {
            let j = PromptJournal(seq: { [weak self] in self?.promptSeq += 1; return self?.promptSeq ?? 0 })
            promptJournals[id] = j
            return j
        }()
        let changed = journal.reduce(event)
        if !changed.isEmpty, chatSubscriptions[id] != nil {
            for item in changed { await emitPrompt(id: id, prompt: item) }
        }
```
Emit helper (`emitTurnStatus` yanına):
```swift
    private func emitPrompt(id: TerminalID, prompt: ChatPrompt) async {
        await connection.send(type: "prompt",
            payload: RemoteProtocol.promptPayload(sessionId: id.description, prompt: prompt))
    }
```

- [ ] **Step 4: Subscribe snapshot**

`handleSubscribe` chat branch'inde, Faz 2 `emitTurnStatus(... snapshot)` satırından sonra:
```swift
            for item in (promptJournals[id]?.items ?? []) where item.state == .pending {
                await emitPrompt(id: id, prompt: item)
            }
```

- [ ] **Step 5: prompt_respond handler + keystroke**

`handleInbound` dispatch'ine (`case "input":` yanına):
```swift
            case "prompt_respond":
                handlePromptRespond(payload)
```
Yeni method (`handleInput` yanına):
```swift
    private func handlePromptRespond(_ payload: [String: Any]) {
        guard let r = RemoteProtocol.decodePromptRespond(payload),
              let id = terminalID(from: r.sessionId),
              let journal = promptJournals[id],
              let idx = journal.items.firstIndex(where: { $0.itemId == r.itemId }) else { return }
        var item = journal.items[idx]
        guard item.state == .pending, item.revision == r.expectedRevision else { return } // bayat/çift-cevap
        guard let keys = keystroke(for: item, optionId: r.optionId) else { return }
        terminal.writeInput(keys, to: id)
        journal.resolve(itemId: r.itemId, optionId: r.optionId)   // state=resolved, revision+1
        if let resolved = journal.items.first(where: { $0.itemId == r.itemId }) {
            Task { await emitPrompt(id: id, prompt: resolved) }
        }
    }

    /// orca keystroke haritası: allow="1", deny=ESC, question index i → "1"+i. Trailing Enter yok.
    private func keystroke(for item: ChatPrompt, optionId: String) -> Data? {
        switch item.kind {
        case .approval:
            if optionId == "allow" { return Data([0x31]) }
            if optionId == "deny" { return Data([0x1b]) }
            return nil
        case .question:
            guard let i = item.options.firstIndex(where: { $0.id == optionId }), i < 9 else { return nil }
            return Data([UInt8(0x31 + i)])
        }
    }
```
`PromptJournal`'a (Task 3 dosyası) resolve metodu ekle:
```swift
    /// Bir item'ı resolved yapar (revision+1).
    public func resolve(itemId: String, optionId: String) {
        guard let idx = items.firstIndex(where: { $0.itemId == itemId }), items[idx].state == .pending else { return }
        items[idx].state = .resolved
        items[idx].selectedOptionId = optionId
        items[idx].revision += 1
    }
```

- [ ] **Step 6: Cleanup**

`.exited` bloğuna (`turnReducers[id] = nil` yanına):
```swift
                promptJournals[id] = nil
```
`shutdown()`'a (`turnReducers.removeAll()` yanına):
```swift
        promptJournals.removeAll()
```

- [ ] **Step 7: Run tests + build**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi --filter LumiRemoteTests`
Expected: PASS (yeni prompt testleri + mevcut). Then `swift build` → succeeds.

- [ ] **Step 8: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Sources/LumiKit/NativeChat/PromptJournal.swift LumiPackages/Tests/LumiRemoteTests/RemoteServicePromptTests.swift
git commit -m "feat(remote): RemoteService prompt journal + prompt_respond → keystroke (Faz 3)"
```

---

### Task 6: Relay `prompt` + `prompt_respond` passthrough

**Files:**
- Modify: `RelayServer/src/protocol.ts` (KNOWN_TYPES), `RelayServer/src/bridge.ts` (fromMac + fromPhone)
- Test: `RelayServer/test/bridge.test.ts`

**Interfaces:** `prompt` mac→telefon broadcast; `prompt_respond` telefon→mac forward (input gibi).

- [ ] **Step 1: Write the failing test**

`bridge.test.ts`'e ekle:
```typescript
test('mac prompt → telefonlara broadcast; telefon prompt_respond → mac', () => {
  const { bridge } = setup()
  const phone = new FakeClient()
  bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))
  const mac = new FakeClient()
  const macSession = bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))!

  bridge.handleMessage(macSession, env('prompt', { sessionId: 's1', itemId: 'i1', kind: 'approval', state: 'pending' }))
  expect(phone.last().type).toBe('prompt')
  expect(phone.last().payload.itemId).toBe('i1')

  const phoneSession = bridge.sessionFor ? bridge.sessionFor(phone) : macSession // helper varsa; yoksa handleHello dönüşünü kullan
  bridge.handleMessage(phoneSessionForPhone(bridge, phone), env('prompt_respond', { sessionId: 's1', itemId: 'i1', expectedRevision: 0, optionId: 'allow' }))
  expect(mac.last().type).toBe('prompt_respond')
  expect(mac.last().payload.optionId).toBe('allow')
})
```
> Not: telefon→mac forward testinde telefon session'ını elde etmek için mevcut `input`/`command` forward testindeki kalıbı bire bir izle (o testler telefon session'ını nasıl alıyorsa aynen). Yukarıdaki `phoneSessionForPhone` yer tutucu değil — mevcut input-forward testinin session-elde etme satırını kopyala.

- [ ] **Step 2: Run to verify FAIL**

Run: `cd RelayServer && npm test`
Expected: FAIL.

- [ ] **Step 3: KNOWN_TYPES + bridge**

`protocol.ts` KNOWN_TYPES'a `'prompt', 'prompt_respond'` ekle (chat_status yanına).
`bridge.ts` `fromMac` switch'ine (`case 'chat_status':` yanına):
```typescript
    case 'prompt':
      this.broadcast(room, envelope('prompt', env.payload))
      break
```
`bridge.ts` `fromPhone`'a (`input` forward'ı yanına), telefon→mac forward:
```typescript
    case 'prompt_respond':
      this.forwardToMac(room, envelope('prompt_respond', env.payload))
      break
```
> `forwardToMac`/mac'e iletme yardımcısının gerçek adını mevcut `input` case'inden al (aynı mekanizma).

- [ ] **Step 4: Run to verify PASS**

Run: `cd RelayServer && npm test`
Expected: PASS (yeni + mevcut, izolasyon dahil).

- [ ] **Step 5: Commit**

```bash
git add RelayServer/src/protocol.ts RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "feat(relay): prompt (mac→phone) + prompt_respond (phone→mac) passthrough (Faz 3)"
```

---

### Task 7: LumiMobileKit `ChatPrompt` kopyası + PhoneProtocol + AppModel (MERGED)

> **Neden birleşik:** `ServerMessage`'a `prompt` case eklemek AppModel'in exhaustive `handle`/`describe` switch'lerini kırar (Faz 2 T6+7 dersi) — birlikte inmeli.

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PromptDecodeTests.swift`, `AppModelPromptTests.swift`

**Interfaces:**
- Produces: mobil `ChatPrompt`/`ChatPromptOption`/enum'lar + `decode`; `ServerMessage.prompt(sessionId:prompt:)`; `PhoneProtocol.promptRespondFrame(sessionId:itemId:expectedRevision:optionId:)`; `AppModel.prompts: [String:[ChatPrompt]]`, `AppModel.respondPrompt(_:itemId:revision:optionId:)`.

- [ ] **Step 1: Write the failing tests**

`PromptDecodeTests.swift`:
```swift
import XCTest
@testable import LumiMobileKit

final class PromptDecodeTests: XCTestCase {
    func testDecodePromptFrame() {
        let frame = #"""
        {"v":1,"type":"prompt","payload":{"sessionId":"s1","itemId":"i1","revision":0,"kind":"approval","title":"Bash?","detail":"npm i","options":[{"id":"allow","label":"Allow","description":null},{"id":"deny","label":"Deny","description":null}],"state":"pending","selectedOptionId":null}}
        """#
        guard case let .prompt(sessionId, p)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("prompt decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(p.itemId, "i1")
        XCTAssertEqual(p.kind, .approval)
        XCTAssertEqual(p.options.map(\.id), ["allow", "deny"])
        XCTAssertEqual(p.state, .pending)
    }
}
```
`AppModelPromptTests.swift`:
```swift
import XCTest
@testable import LumiMobileKit

@MainActor
final class AppModelPromptTests: XCTestCase {
    private func prompt(_ id: String, state: ChatPromptState) -> ChatPrompt {
        ChatPrompt(itemId: id, revision: 0, kind: .approval, title: "t", detail: nil,
                   options: [ChatPromptOption(id: "allow", label: "Allow", description: nil)],
                   state: state, selectedOptionId: nil)
    }
    func testPendingPromptAddedResolvedRemoved() {
        let m = AppModel()
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .pending)))
        XCTAssertEqual(m.prompts["s1"]?.count, 1)
        m.handle(.prompt(sessionId: "s1", prompt: prompt("i1", state: .resolved)))
        XCTAssertTrue((m.prompts["s1"] ?? []).isEmpty)   // resolved → düşer
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PromptDecodeTests`
Expected: FAIL — `ChatPrompt`/`.prompt` yok.

- [ ] **Step 3: Mobile ChatPrompt copy**

`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift`:
```swift
import Foundation

public enum ChatPromptKind: String, Sendable, Equatable { case approval, question }
public enum ChatPromptState: String, Sendable, Equatable { case pending, resolved, cancelled }

public struct ChatPromptOption: Sendable, Equatable {
    public let id: String; public let label: String; public let description: String?
    public init(id: String, label: String, description: String?) { self.id = id; self.label = label; self.description = description }
    static func decode(_ d: [String: Any]) -> ChatPromptOption? {
        guard let id = d["id"] as? String, let label = d["label"] as? String else { return nil }
        return ChatPromptOption(id: id, label: label, description: d["description"] as? String)
    }
}

public struct ChatPrompt: Sendable, Equatable {
    public let itemId: String; public let revision: Int; public let kind: ChatPromptKind
    public let title: String; public let detail: String?; public let options: [ChatPromptOption]
    public let state: ChatPromptState; public let selectedOptionId: String?
    public init(itemId: String, revision: Int, kind: ChatPromptKind, title: String, detail: String?,
                options: [ChatPromptOption], state: ChatPromptState, selectedOptionId: String?) {
        self.itemId = itemId; self.revision = revision; self.kind = kind; self.title = title
        self.detail = detail; self.options = options; self.state = state; self.selectedOptionId = selectedOptionId
    }
    static func decode(_ d: [String: Any]) -> ChatPrompt? {
        guard let itemId = d["itemId"] as? String, let revision = d["revision"] as? Int,
              let kind = (d["kind"] as? String).flatMap(ChatPromptKind.init(rawValue:)),
              let title = d["title"] as? String,
              let state = (d["state"] as? String).flatMap(ChatPromptState.init(rawValue:)) else { return nil }
        let options = (d["options"] as? [[String: Any]])?.compactMap(ChatPromptOption.decode) ?? []
        return ChatPrompt(itemId: itemId, revision: revision, kind: kind, title: title,
                          detail: d["detail"] as? String, options: options, state: state,
                          selectedOptionId: d["selectedOptionId"] as? String)
    }
}
```

- [ ] **Step 4: PhoneProtocol — ServerMessage.prompt + decode + promptRespondFrame**

`PhoneProtocol.swift` `ServerMessage`'a (`chatStatus` yanına):
```swift
    case prompt(sessionId: String, prompt: ChatPrompt)
```
`decodeServerMessage` switch'ine (`"chat_status"` yanına):
```swift
    case "prompt":
        guard let sessionId = payload["sessionId"] as? String,
              let p = ChatPrompt.decode(payload) else { return nil }
        return .prompt(sessionId: sessionId, prompt: p)
```
Frame üreteci (mevcut `inputFrame`/`subscribeFrame` yanına):
```swift
    public static func promptRespondFrame(sessionId: String, itemId: String, expectedRevision: Int, optionId: String) -> String {
        encode(type: "prompt_respond", payload: ["sessionId": sessionId, "itemId": itemId, "expectedRevision": expectedRevision, "optionId": optionId])
    }
```
> `encode(type:payload:)`'ın gerçek adını mevcut `inputFrame`'den doğrula (aynı envelope üreteci).

- [ ] **Step 5: AppModel — prompts + handle + respondPrompt + cleanup**

`AppModel.swift`, `turnStatus` yanına:
```swift
    /// Faz 3: session başına aktif (pending) etkileşimli prompt'lar.
    public private(set) var prompts: [String: [ChatPrompt]] = [:]
```
`handle(_:)` switch'ine (`.chatStatus` yanına):
```swift
        case .prompt(let sessionId, let p):
            macOnline = true
            var list = prompts[sessionId] ?? []
            list.removeAll { $0.itemId == p.itemId }
            if p.state == .pending { list.append(p) }   // resolved/cancelled → listede tutma
            prompts[sessionId] = list
```
`describe(_:)` switch'ine (`.chatStatus` yanına):
```swift
        case .prompt(let sessionId, let p):
            "prompt \(sessionId.prefix(8)) \(p.kind.rawValue) \(p.state.rawValue)"
```
respondPrompt (public method):
```swift
    public func respondPrompt(_ sessionId: String, itemId: String, revision: Int, optionId: String) {
        Task { await client.send(frame: PhoneProtocol.promptRespondFrame(sessionId: sessionId, itemId: itemId, expectedRevision: revision, optionId: optionId)) }
        // optimistic yok: resolution broadcast'i beklenir (kart, prompt frame resolved gelince düşer)
    }
```
Temizlik: `applySessions` ölü-aktif-oturum bloğunda (`turnStatus[active] = nil` yanına) `prompts[active] = nil`; reset (`chatBySession = [:]` yanında) `prompts = [:]`.

- [ ] **Step 6: Run tests + full suite**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PromptDecodeTests && swift test --filter AppModelPromptTests && swift test`
Expected: hepsi PASS (module exhaustive switch'ler artık `.prompt`'u işliyor).

- [ ] **Step 7: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PromptDecodeTests.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelPromptTests.swift
git commit -m "feat(mobile): ChatPrompt decode + AppModel.prompts merge + respondPrompt (Faz 3)"
```

---

### Task 8: `MobileChatPromptCard` UI + MobileChatView insert (SwiftUI)

**Files:**
- Create: `LumiMobile/App/MobileChatPromptCard.swift`
- Modify: `LumiMobile/App/MobileChatView.swift` (turn-status bandı ile composer arasına)

**Interfaces:** Consumes `model.prompts[sessionId]` (Task 7), `model.respondPrompt`. Görsel; birim test yok, build + cihaz.

- [ ] **Step 1: Create the card**

`LumiMobile/App/MobileChatPromptCard.swift`:
```swift
import SwiftUI
import LumiMobileKit

/// Faz 3: composer üstünde etkileşimli prompt kartı. En son pending item'ı çizer.
/// approval: title+detail + Allow(mavi)/Deny. question: soru + tek-seçim satırları.
struct MobileChatPromptCard: View {
    let prompt: ChatPrompt
    let onRespond: (String) -> Void   // optionId
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: prompt.kind == .approval ? "shield.lefthalf.filled" : "questionmark.circle")
                    Text(prompt.title).font(.footnote.bold())
                }
                if let detail = prompt.detail, !detail.isEmpty {
                    Text(detail).font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                ForEach(Array(prompt.options.enumerated()), id: \.element.id) { idx, opt in
                    Button {
                        guard !sending else { return }
                        sending = true
                        onRespond(opt.id)
                    } label: {
                        HStack {
                            Text(opt.label).font(.footnote.bold())
                            if let d = opt.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(idx == 0 ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(sending)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }
}
```

- [ ] **Step 2: Insert into MobileChatView**

`MobileChatView.swift`, TurnStatusBar insert'inin hemen altına (composer'dan önce):
```swift
            if let pending = model.prompts[sessionId]?.last(where: { $0.state == .pending }) {
                MobileChatPromptCard(prompt: pending) { optionId in
                    model.respondPrompt(sessionId, itemId: pending.itemId, revision: pending.revision, optionId: optionId)
                }
            }
```

- [ ] **Step 3: Regenerate project + build**

Run:
```bash
cd LumiMobile && xcodegen generate
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build
```
Expected: BUILD SUCCEEDED. (`.xcodeproj` commit'e girmemeli — gitignore.)

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/MobileChatPromptCard.swift LumiMobile/App/MobileChatView.swift
git commit -m "feat(mobile): etkileşimli prompt kartı (izin/soru) + tap→respond (Faz 3)"
```

---

### Task 9: Full sweep + device handoff

- [ ] **Step 1:** `cd LumiPackages && swift test --scratch-path /tmp/lumi` → tümü yeşil.
- [ ] **Step 2:** `cd LumiMobile/LumiMobileKit && swift test` → tümü yeşil.
- [ ] **Step 3:** `cd RelayServer && npm test` → tümü yeşil.
- [ ] **Step 4:** `cd LumiPackages && swift build -c release --product Lumi` → succeeds.
- [ ] **Step 5 (kullanıcı, launch-env):** relay deploy (lumi-relay servisi — `railway up -s lumi-relay`); Mac paketle + Finder/Dock'tan başlat; iOS cihaza kur.
- [ ] **Step 6 (cihaz doğrulama):** gerçek Claude'da Bash-izin prompt'u → telefonda Allow/Deny kartı; Allow → claude devam eder. AskUserQuestion → tek-seçim kartı; seçim → cevap işlenir. Mac'te cevaplama → telefonda kart kaybolur (postToolUse cancel). `/clear` → kart temizlenir. Keystroke doğruluğu (orca haritası) burada teyit edilir.

---

## Self-Review

**Spec coverage:** §4.1 hook toolInput → Task 1; §4.2 ChatPrompt → Task 2 (+7 kopya); §4.3 PromptJournal + RemoteService → Task 3+5; §4.4 keystroke → Task 5 `keystroke(for:)`; §4.5 wire → Task 4+6+7; §4.6 AppModel+UI → Task 7+8; §5 kenar durumlar (bayat revision Task 5 guard, postTool/stop cancel Task 3, clear Task 3+7, reconnect snapshot Task 5, çoklu-session per-journal) → kapsanıyor; §6 testler → her task; §8 envanter → File Structure. Kapsam dışı (multiSelect/gruplu/free-text/Codex) uygulanmadı (kasıtlı).

**Placeholder scan:** Kod adımları tam. İki yerde "mevcut kalıbı/yardımcı adını doğrula" notu (RelayServer telefon-session elde etme; PhoneProtocol `encode` adı) — codebase'e özgü yönlendirme, placeholder değil.

**Type consistency:** `ChatPrompt(itemId:revision:kind:title:detail:options:state:selectedOptionId:)` LumiKit↔LumiMobileKit aynı; `PromptJournal.reduce -> [ChatPrompt]` + `resolve(itemId:optionId:)` Task 3↔5; `promptPayload`/`decodePromptRespond` Task 4↔5; `ServerMessage.prompt(sessionId:prompt:)` Task 7↔8; keystroke değerleri (0x31/0x1b/0x31+i) Global Constraints↔Task 5; frame type'ları `"prompt"`/`"prompt_respond"` her katmanda aynı. ✓

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-15-faz3-interactive-prompt-cards.md`.**
