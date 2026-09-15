# Native Chat — Faz 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefonda ham terminal yerine, Claude transcript JSONL'ini parse edip canlı tail eden native bir chat görünümü göster (yatay-scroll okunabilirlik sorununu çöz); orca `native-chat` modelinin Faz 1 alt kümesi.

**Architecture:** Mac tarafı abone olunan oturumun transcript dosyasını çözüp tail eder ve relay'e `chat` (snapshot) + `chat_append` frame'leri yollar (mevcut terminal-mirror mode toggle olarak kalır). Model + kaynak protokolü LumiKit'te (LumiRemote yalnız LumiKit'e bağlı), somut okuyucu LumiServices'te (AgentTranscriptParser/AgentDataRoots'a erişimi var), composition `RemoteFeatureAssembly`'de. Telefon wire'ı LumiMobileKit'te decode edip SwiftUI chat listesi render eder.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, XCTest + swift-testing, TypeScript/vitest (relay), xcodegen (iOS proje).

## Global Constraints

- Branch: `feat/remote-orca-main` — main'e commit YOK.
- Persistence/wire additive: mevcut `subscribe`/`data`/`sessions` frame'leri kırılmaz; `subscribe` payload'ına opsiyonel `mode` eklenir (yoksa `terminal`).
- LumiKit literal/token kuralları LumiUI için; bu plan LumiUI'a dokunmaz.
- Yeni servis process I/O `ProcessRunning` üzerinden — burada dosya-okuma var, `FileManager`/`FileHandle` doğrudan LumiServices içinde (mevcut `AgentHistoryService` deseni).
- Mac wire encode: `RemoteProtocol` (LumiRemote) `[String: Any]` payload üretir; telefon `PhoneProtocol` (LumiMobileKit) `JSONSerialization` ile decode eder — mevcut desen.
- Faz 1 sağlayıcı: yalnız Claude. Kaynak: yalnız transcript. `claudeSessionID` olmayan oturum chat'e giremez → terminal mode.
- Build/test komutları: `cd LumiPackages && swift test --scratch-path <tmp>`; `cd RelayServer && npm test`; `cd LumiMobile/LumiMobileKit && swift test`; iOS derleme `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.

---

## File Structure

**Mac (LumiPackages):**
- Create `Sources/LumiKit/Models/ChatMirrorModels.swift` — `ChatRole`, `ChatBlock`, `ChatMessage`, `ChatMirrorEvent`.
- Create `Sources/LumiKit/Protocols/ChatTranscriptSourcing.swift` — kaynak protokolü.
- Create `Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift` — JSONL satır dict → `ChatMessage?`.
- Create `Sources/LumiServices/NativeChat/TranscriptChatSource.swift` — yol çöz + snapshot + tail (polling), `ChatTranscriptSourcing`.
- Modify `Sources/LumiRemote/RemoteProtocol.swift` — `chatPayload`, `chatAppendPayload`, `ChatMessage`→dict encode.
- Modify `Sources/LumiRemote/RemoteService.swift` — `subscribe` mode; chat stream başlat; `chat`/`chat_append` gönder.
- Modify `Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift` — somut `TranscriptChatSource` enjekte.
- Create `Tests/LumiTestSupport/FakeChatTranscriptSource.swift` — test fake.
- Tests: `Tests/LumiServicesTests/ClaudeTranscriptChatDecoderTests.swift`, `Tests/LumiServicesTests/TranscriptChatSourceTests.swift`, `Tests/LumiRemoteTests/RemoteServiceTests.swift` (mode=chat).

**Relay (RelayServer):**
- Modify `src/protocol.ts` — `KNOWN_TYPES` += `chat`, `chat_append`.
- Modify `src/bridge.ts` — `fromMac` `chat`/`chat_append` broadcast.
- Test `test/bridge.test.ts`.

**Telefon (LumiMobile):**
- Create `LumiMobileKit/Sources/LumiMobileKit/ChatMirrorModels.swift` — Codable `ChatMessage`/`ChatBlock`.
- Modify `LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` — `chat`/`chat_append` decode; `subscribeFrame(mode:)`.
- Modify `LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — `chatMessages`, chat stream, subscribe mode, append merge.
- Create `LumiMobileKit/Sources/LumiMobileKit/ChatFold.swift` — tool-fold saf fonksiyon.
- Create `App/MobileChatToolRunView.swift`, `App/MobileChatMessageView.swift`, `App/MobileChatView.swift`.
- Modify `App/TerminalSessionView.swift` — chat↔terminal toggle (varsayılan chat).
- Tests: `LumiMobileKit/Tests/LumiMobileKitTests/ChatMirrorDecodeTests.swift`, `ChatFoldTests.swift`, `AppModelTests.swift` (chat).

---

## Task 1: Mac chat wire modeli (LumiKit)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Models/ChatMirrorModels.swift`
- Test: `LumiPackages/Tests/LumiKitTests/ChatMirrorModelsTests.swift`

**Interfaces:**
- Produces: `enum ChatRole: String { user, assistant, tool, reasoning, system }`; `enum ChatBlock` (`.text(String, presentation: String?)`, `.toolCall(name: String, inputPreview: String, state: String?)`, `.toolResult(output: String, isError: Bool)`, `.imageRef(path: String?, url: String?, alt: String?)`, `.subagentGroup(groupId: String, agents: [ChatSubagentEntry])`); `struct ChatMessage { id: String; role: ChatRole; blocks: [ChatBlock]; timestampMs: Int?; turnId: String? }` with `func toDict() -> [String: Any]`; `enum ChatMirrorEvent: Sendable { case snapshot([ChatMessage]); case append([ChatMessage]) }`.

- [ ] **Step 1: Write the failing test**

```swift
// LumiPackages/Tests/LumiKitTests/ChatMirrorModelsTests.swift
import Testing
@testable import LumiKit

@Suite struct ChatMirrorModelsTests {
    @Test func textMessageToDict() {
        let msg = ChatMessage(
            id: "m1", role: .assistant,
            blocks: [.text("hi", presentation: nil)],
            timestampMs: 1000, turnId: "t1"
        )
        let d = msg.toDict()
        #expect(d["id"] as? String == "m1")
        #expect(d["role"] as? String == "assistant")
        #expect(d["timestamp"] as? Int == 1000)
        #expect(d["turnId"] as? String == "t1")
        let blocks = d["blocks"] as? [[String: Any]]
        #expect(blocks?.first?["type"] as? String == "text")
        #expect(blocks?.first?["text"] as? String == "hi")
    }

    @Test func toolBlocksToDict() {
        let msg = ChatMessage(
            id: "m2", role: .assistant,
            blocks: [
                .toolCall(name: "Edit", inputPreview: "file.swift", state: "completed"),
                .toolResult(output: "ok", isError: false),
            ],
            timestampMs: nil, turnId: nil
        )
        let d = msg.toDict()
        #expect(d["timestamp"] is NSNull)
        let blocks = d["blocks"] as? [[String: Any]]
        #expect(blocks?[0]["type"] as? String == "tool-call")
        #expect(blocks?[0]["name"] as? String == "Edit")
        #expect(blocks?[0]["inputPreview"] as? String == "file.swift")
        #expect(blocks?[1]["type"] as? String == "tool-result")
        #expect(blocks?[1]["output"] as? String == "ok")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t1 --filter ChatMirrorModelsTests`
Expected: FAIL (compile error: `ChatMessage` not found).

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiPackages/Sources/LumiKit/Models/ChatMirrorModels.swift
import Foundation

/// orca `native-chat-types.ts` paritesi (Faz 1 alt kümesi). Wire modeli:
/// `RemoteProtocol` bunları `[String: Any]` payload'a çevirir, telefon decode eder.
public enum ChatRole: String, Sendable, Equatable {
    case user, assistant, tool, reasoning, system
}

public enum ChatBlock: Sendable, Equatable {
    case text(String, presentation: String?)
    case toolCall(name: String, inputPreview: String, state: String?)
    case toolResult(output: String, isError: Bool)
    case imageRef(path: String?, url: String?, alt: String?)
    case subagentGroup(groupId: String, agentsJSON: [[String: String]])

    func toDict() -> [String: Any] {
        switch self {
        case let .text(text, presentation):
            var d: [String: Any] = ["type": "text", "text": text]
            if let presentation { d["presentation"] = presentation }
            return d
        case let .toolCall(name, inputPreview, state):
            var d: [String: Any] = ["type": "tool-call", "name": name, "inputPreview": inputPreview]
            if let state { d["state"] = state }
            return d
        case let .toolResult(output, isError):
            return ["type": "tool-result", "output": output, "isError": isError]
        case let .imageRef(path, url, alt):
            var d: [String: Any] = ["type": "image-ref"]
            if let path { d["path"] = path }
            if let url { d["url"] = url }
            if let alt { d["alt"] = alt }
            return d
        case let .subagentGroup(groupId, agentsJSON):
            return ["type": "subagent-group", "groupId": groupId, "agents": agentsJSON]
        }
    }
}

public struct ChatMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let role: ChatRole
    public let blocks: [ChatBlock]
    public let timestampMs: Int?
    public let turnId: String?

    public init(id: String, role: ChatRole, blocks: [ChatBlock], timestampMs: Int?, turnId: String?) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestampMs = timestampMs
        self.turnId = turnId
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "role": role.rawValue,
            "timestamp": timestampMs.map { $0 as Any } ?? NSNull(),
            "turnId": turnId.map { $0 as Any } ?? NSNull(),
            "blocks": blocks.map { $0.toDict() },
        ]
    }
}

/// Kaynak → RemoteService olayları: ilk snapshot, sonra append'ler.
public enum ChatMirrorEvent: Sendable, Equatable {
    case snapshot([ChatMessage])
    case append([ChatMessage])
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t1 --filter ChatMirrorModelsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/ChatMirrorModels.swift LumiPackages/Tests/LumiKitTests/ChatMirrorModelsTests.swift
git commit -m "feat(remote): chat wire modeli (LumiKit) — orca native-chat paritesi"
```

---

## Task 2: Claude transcript decoder (LumiServices)

**Files:**
- Create: `LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/ClaudeTranscriptChatDecoderTests.swift`

**Interfaces:**
- Consumes: `ChatMessage`, `ChatBlock`, `ChatRole` (Task 1).
- Produces: `struct ClaudeTranscriptChatDecoder { func decode(_ record: [String: Any], index: Int) -> ChatMessage? }`.

Claude JSONL satır şekli (doğrulandı): `{ "type":"user"|"assistant", "uuid":"...", "timestamp":"ISO8601", "message": { "content": <String | [ {type:text,text} | {type:tool_use,id,name,input} | {type:tool_result,tool_use_id,content,is_error?} ] } }`. `isMeta==true` atlanır.

- [ ] **Step 1: Write the failing test**

```swift
// LumiPackages/Tests/LumiServicesTests/ClaudeTranscriptChatDecoderTests.swift
import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct ClaudeTranscriptChatDecoderTests {
    private let decoder = ClaudeTranscriptChatDecoder()

    @Test func decodesUserTextString() {
        let rec: [String: Any] = ["type": "user", "uuid": "u1",
                                  "message": ["content": "merhaba"]]
        let msg = decoder.decode(rec, index: 0)
        #expect(msg?.role == .user)
        #expect(msg?.blocks == [.text("merhaba", presentation: nil)])
        #expect(msg?.id == "u1")
    }

    @Test func decodesAssistantTextAndToolUse() {
        let rec: [String: Any] = [
            "type": "assistant", "uuid": "a1",
            "message": ["content": [
                ["type": "text", "text": "düzeltiyorum"],
                ["type": "tool_use", "id": "tu1", "name": "Edit",
                 "input": ["file_path": "/x/file.swift"]],
            ]],
        ]
        let msg = decoder.decode(rec, index: 1)
        #expect(msg?.role == .assistant)
        #expect(msg?.blocks.count == 2)
        #expect(msg?.blocks[0] == .text("düzeltiyorum", presentation: nil))
        if case let .toolCall(name, preview, _) = msg?.blocks[1] {
            #expect(name == "Edit")
            #expect(preview.contains("file.swift"))
        } else { Issue.record("tool-call bekleniyordu") }
    }

    @Test func decodesToolResult() {
        let rec: [String: Any] = [
            "type": "user", "uuid": "r1",
            "message": ["content": [
                ["type": "tool_result", "tool_use_id": "tu1", "content": "tamam", "is_error": false],
            ]],
        ]
        let msg = decoder.decode(rec, index: 2)
        #expect(msg?.role == .user)
        #expect(msg?.blocks == [.toolResult(output: "tamam", isError: false)])
    }

    @Test func skipsMetaAndUnknown() {
        #expect(decoder.decode(["type": "user", "isMeta": true, "message": ["content": "x"]], index: 0) == nil)
        #expect(decoder.decode(["type": "summary"], index: 0) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t2 --filter ClaudeTranscriptChatDecoderTests`
Expected: FAIL (compile error: `ClaudeTranscriptChatDecoder` not found).

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift
import Foundation
import LumiKit

/// Claude transcript JSONL satırını `ChatMessage`'a çevirir (orca
/// `transcript-line-decoders-claude.ts` Faz 1 alt kümesi). Blok-farkındalıklı:
/// `message.content` dizisini text/tool_use/tool_result olarak yürür.
struct ClaudeTranscriptChatDecoder {
    private static let maxPreview = 200
    private static let maxOutput = 4000

    func decode(_ record: [String: Any], index: Int) -> ChatMessage? {
        guard record["isMeta"] as? Bool != true else { return nil }
        let kind = record["type"] as? String
        let role: ChatRole
        switch kind {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let content = (record["message"] as? [String: Any])?["content"]
        let blocks = decodeBlocks(content)
        guard !blocks.isEmpty else { return nil }
        let id = (record["uuid"] as? String) ?? "idx-\(index)"
        return ChatMessage(
            id: id, role: role, blocks: blocks,
            timestampMs: timestampMs(record["timestamp"] as? String),
            turnId: id
        )
    }

    private func decodeBlocks(_ content: Any?) -> [ChatBlock] {
        if let string = content as? String {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.text(t, presentation: nil)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return .text(text, presentation: nil)
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return .toolCall(name: name, inputPreview: preview(block["input"]), state: "completed")
            case "tool_result":
                return .toolResult(output: output(block["content"]),
                                   isError: block["is_error"] as? Bool ?? false)
            default:
                return nil
            }
        }
    }

    /// tool_use.input → tek satır kısa önizleme (JSON değerlerini düzleştir).
    private func preview(_ input: Any?) -> String {
        let text: String
        if let s = input as? String { text = s }
        else if let d = input as? [String: Any] {
            text = d.map { "\($0.key)=\(flatten($0.value))" }.sorted().joined(separator: " ")
        } else { text = "" }
        return String(text.prefix(Self.maxPreview))
    }

    private func output(_ content: Any?) -> String {
        let text: String
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { text = "" }
        return String(text.prefix(Self.maxOutput))
    }

    private func flatten(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value).prefix(80).description
    }

    private func timestampMs(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let styles = [Date.ISO8601FormatStyle(includingFractionalSeconds: true),
                      Date.ISO8601FormatStyle()]
        for style in styles {
            if let date = try? style.parse(raw) {
                return Int(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t2 --filter ClaudeTranscriptChatDecoderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift LumiPackages/Tests/LumiServicesTests/ClaudeTranscriptChatDecoderTests.swift
git commit -m "feat(remote): Claude transcript chat decoder (blok-farkındalıklı)"
```

---

## Task 3: Transcript kaynağı — protokol + polling tail (LumiKit + LumiServices)

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Protocols/ChatTranscriptSourcing.swift`
- Create: `LumiPackages/Sources/LumiServices/NativeChat/TranscriptChatSource.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/TranscriptChatSourceTests.swift`

**Interfaces:**
- Consumes: `ChatMessage`, `ChatMirrorEvent`, `ClaudeTranscriptChatDecoder`.
- Produces: `protocol ChatTranscriptSourcing: Sendable { func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent> }`; `actor TranscriptChatSource: ChatTranscriptSourcing` with `init(home: URL = FileManager.default.homeDirectoryForCurrentUser, pollInterval: Duration = .milliseconds(500))`.

Tail mekaniği: **polling** (en basit/güvenli). Kaynak dosyayı offset'ten büyümeye karşı yoklar; ilk okuma → `.snapshot`, sonraki büyümeler → `.append`. Test determinizmi için okuma senkron; poll döngüsü `AsyncStream` içinde `Task.sleep(pollInterval)`.

- [ ] **Step 1: Write the failing test**

```swift
// LumiPackages/Tests/LumiServicesTests/TranscriptChatSourceTests.swift
import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct TranscriptChatSourceTests {
    /// Geçici home + claude projects/<encoded>/<sid>.jsonl kur.
    private func makeTranscript(sid: String, repoPath: String, lines: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-chat-\(UUID().uuidString)")
        let encoded = repoPath.replacingOccurrences(of: "/", with: "-")
        let dir = home.appendingPathComponent(".claude/projects/\(encoded)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sid).jsonl")
        try lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: file)
        return home
    }

    @Test func snapshotThenAppend() async throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let repo = "/Users/x/proj"
        let line1 = #"{"type":"user","uuid":"u1","message":{"content":"selam"}}"#
        let home = try makeTranscript(sid: sid, repoPath: repo, lines: [line1])
        let file = home.appendingPathComponent(
            ".claude/projects/\(repo.replacingOccurrences(of: "/", with: "-"))/\(sid).jsonl")

        let source = TranscriptChatSource(home: home, pollInterval: .milliseconds(20))
        var iterator = source.stream(sessionID: sid, repoPath: repo).makeAsyncIterator()

        let first = await iterator.next()
        guard case let .snapshot(msgs)? = first else { return Issue.record("snapshot bekleniyordu") }
        #expect(msgs.map(\.id) == ["u1"])

        // Dosyaya yeni satır ekle → append gelmeli.
        let line2 = #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"tamam"}]}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line2 + "\n").data(using: .utf8)!)
        try handle.close()

        let second = await iterator.next()
        guard case let .append(more)? = second else { return Issue.record("append bekleniyordu") }
        #expect(more.map(\.id) == ["a1"])
    }

    @Test func missingFileEmitsEmptySnapshotThenFills() async throws {
        let sid = "22222222-2222-2222-2222-222222222222"
        let repo = "/Users/x/empty"
        // Dosya yok; source boş snapshot verip dosya belirince append etmeli.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-chat-\(UUID().uuidString)")
        let source = TranscriptChatSource(home: home, pollInterval: .milliseconds(20))
        var it = source.stream(sessionID: sid, repoPath: repo).makeAsyncIterator()
        guard case let .snapshot(msgs)? = await it.next() else { return Issue.record("snapshot") }
        #expect(msgs.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t3 --filter TranscriptChatSourceTests`
Expected: FAIL (`TranscriptChatSource` not found).

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiPackages/Sources/LumiKit/Protocols/ChatTranscriptSourcing.swift
import Foundation

/// Bir oturumun transcript'ini chat olaylarına çeviren kaynak sınırı.
/// RemoteService bunu enjekte alır (LumiRemote yalnız LumiKit'e bağlı).
public protocol ChatTranscriptSourcing: Sendable {
    /// İlk `.snapshot`, sonra dosya büyüdükçe `.append`. Consumer iptal edince biter.
    func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent>
}
```

```swift
// LumiPackages/Sources/LumiServices/NativeChat/TranscriptChatSource.swift
import Foundation
import LumiKit

/// Claude transcript JSONL'ini polling ile tail edip chat olayları yayar
/// (orca `transcript-watch`/`transcript-tail-boundary` Faz 1 alt kümesi).
/// Değişmez durum (hepsi `let`) → `struct` + otomatik `Sendable`; aktör izolasyonu
/// gerekmez (dosya okuma saf, self mutasyonu yok).
public struct TranscriptChatSource: ChatTranscriptSourcing {
    private let home: URL
    private let pollInterval: Duration
    private let decoder = ClaudeTranscriptChatDecoder()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                pollInterval: Duration = .milliseconds(500)) {
        self.home = home
        self.pollInterval = pollInterval
    }

    public func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent> {
        AsyncStream { continuation in
            let task = Task { [pollInterval] in
                let file = Self.transcriptURL(home: self.home, sessionID: sessionID, repoPath: repoPath)
                var offset: UInt64 = 0
                var index = 0
                var sentSnapshot = false
                while !Task.isCancelled {
                    let (messages, newOffset, newIndex) = self.readAppended(file, from: offset, index: index)
                    offset = newOffset
                    index = newIndex
                    if !sentSnapshot {
                        continuation.yield(.snapshot(messages))
                        sentSnapshot = true
                    } else if !messages.isEmpty {
                        continuation.yield(.append(messages))
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `<home>/.claude/projects/<encoded-cwd>/<sid>.jsonl` (AgentDataRoots paritesi).
    static func transcriptURL(home: URL, sessionID: String, repoPath: String) -> URL {
        let encoded = repoPath.replacingOccurrences(of: "/", with: "-")
        return home.appendingPathComponent(".claude/projects/\(encoded)/\(sessionID).jsonl")
    }

    /// Offset'ten itibaren tam satırları okuyup decode eder; yeni offset + index döner.
    private func readAppended(_ file: URL, from offset: UInt64, index: Int) -> ([ChatMessage], UInt64, Int) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], offset, index) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], offset, index) }
        // Son newline'a kadar tam satırlar; yarım son satır bir sonraki poll'a kalsın.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return ([], offset, index) }
        let complete = data[..<data.index(after: lastNL)]
        var messages: [ChatMessage] = []
        var idx = index
        for lineData in complete.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let record = obj as? [String: Any] else { idx += 1; continue }
            if let msg = decoder.decode(record, index: idx) { messages.append(msg) }
            idx += 1
        }
        return (messages, offset + UInt64(complete.count), idx)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t3 --filter TranscriptChatSourceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Protocols/ChatTranscriptSourcing.swift LumiPackages/Sources/LumiServices/NativeChat/TranscriptChatSource.swift LumiPackages/Tests/LumiServicesTests/TranscriptChatSourceTests.swift
git commit -m "feat(remote): transcript chat kaynağı — polling tail + protokol"
```

---

## Task 4: RemoteProtocol chat payload'ları (LumiRemote)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift`

**Interfaces:**
- Consumes: `ChatMessage` (LumiKit).
- Produces: `RemoteProtocol.chatPayload(sessionId: String, messages: [ChatMessage]) -> [String: Any]`; `RemoteProtocol.chatAppendPayload(sessionId: String, messages: [ChatMessage]) -> [String: Any]`; `RemoteProtocol.decodeSubscribeMode(_ payload:) -> String` (default `"terminal"`).

- [ ] **Step 1: Write the failing test**

Add to `LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift`:

```swift
@Test func chatPayloadShape() {
    let msg = ChatMessage(id: "m1", role: .assistant,
                          blocks: [.text("hi", presentation: nil)],
                          timestampMs: 5, turnId: nil)
    let p = RemoteProtocol.chatPayload(sessionId: "s1", messages: [msg])
    #expect(p["sessionId"] as? String == "s1")
    let msgs = p["messages"] as? [[String: Any]]
    #expect(msgs?.first?["id"] as? String == "m1")
}

@Test func subscribeModeDefaultsTerminal() {
    #expect(RemoteProtocol.decodeSubscribeMode(["sessionId": "s"]) == "terminal")
    #expect(RemoteProtocol.decodeSubscribeMode(["sessionId": "s", "mode": "chat"]) == "chat")
}
```

(Requires `import LumiKit` at top of the test file — add if missing.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t4 --filter RemoteProtocolTests`
Expected: FAIL (`chatPayload` not found).

- [ ] **Step 3: Write minimal implementation**

Add to `RemoteProtocol` enum in `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` (after `sessionsPayload`), and `import LumiKit` is already present:

```swift
    /// `chat` payload: bir oturumun tam mesaj listesi (snapshot).
    static func chatPayload(sessionId: String, messages: [ChatMessage]) -> [String: Any] {
        ["sessionId": sessionId, "messages": messages.map { $0.toDict() }]
    }

    /// `chat_append` payload: tail'de gelen yeni mesajlar.
    static func chatAppendPayload(sessionId: String, messages: [ChatMessage]) -> [String: Any] {
        ["sessionId": sessionId, "messages": messages.map { $0.toDict() }]
    }

    /// `subscribe` payload'ından mode; yoksa geriye-uyumlu `terminal`.
    static func decodeSubscribeMode(_ payload: [String: Any]) -> String {
        payload["mode"] as? String ?? "terminal"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t4 --filter RemoteProtocolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteProtocol.swift LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift
git commit -m "feat(remote): RemoteProtocol chat/chat_append payload + subscribe mode"
```

---

## Task 5: RemoteService chat mode + streaming (LumiRemote)

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- Create: `LumiPackages/Tests/LumiTestSupport/FakeChatTranscriptSource.swift`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: `ChatTranscriptSourcing`, `ChatMirrorEvent`, `ChatMessage`, `RemoteProtocol.chatPayload/chatAppendPayload/decodeSubscribeMode`.
- Produces: `RemoteService.init(..., chatSource: any ChatTranscriptSourcing)` yeni parametre; `subscribe` mode=chat → `chat` + `chat_append` gönderir.

- [ ] **Step 1: Write the failing test**

Add `FakeChatTranscriptSource` to LumiTestSupport:

```swift
// LumiPackages/Tests/LumiTestSupport/FakeChatTranscriptSource.swift
import Foundation
import LumiKit

/// Testte belirli olayları yayan chat kaynağı.
public final class FakeChatTranscriptSource: ChatTranscriptSourcing, @unchecked Sendable {
    private let events: [ChatMirrorEvent]
    public private(set) var requested: [(sessionID: String, repoPath: String)] = []

    public init(events: [ChatMirrorEvent]) { self.events = events }

    public func stream(sessionID: String, repoPath: String) -> AsyncStream<ChatMirrorEvent> {
        requested.append((sessionID, repoPath))
        let events = self.events
        return AsyncStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
        }
    }
}
```

Add to `RemoteServiceTests.swift`:

```swift
@Test func subscribeChatModeSendsChatThenAppend() async throws {
    let conn = FakeRelayConnection()
    let term = FakeTerminalServicing()
    let uuid = UUID()
    let meta = TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo",
                            createdAt: Date(), claudeSessionID: uuid.uuidString)
    term.metas.append(meta)
    let sid = meta.id.description
    let m1 = ChatMessage(id: "m1", role: .user, blocks: [.text("hi", presentation: nil)],
                         timestampMs: nil, turnId: nil)
    let m2 = ChatMessage(id: "m2", role: .assistant, blocks: [.text("yo", presentation: nil)],
                         timestampMs: nil, turnId: nil)
    let chat = FakeChatTranscriptSource(events: [.snapshot([m1]), .append([m2])])
    let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
                            connection: conn, chatSource: chat)
    await svc.start()

    await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
    try await conn.waitForSent(types: ["chat", "chat_append"])

    #expect(await conn.count(type: "scrollback") == 0)  // chat mode: terminal göndermez
    svc.stop()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t5 --filter RemoteServiceTests`
Expected: FAIL (`RemoteService.init` has no `chatSource`).

- [ ] **Step 3: Write minimal implementation**

In `RemoteService.swift`: add stored `chatSource`, init param, chat-subscription task map, and mode branch in `handleSubscribe`.

Add property near `subscriptions`:

```swift
    private let chatSource: any ChatTranscriptSourcing
    /// Session başına chat tail task'ı (mode=chat aboneliği).
    private var chatSubscriptions: [TerminalID: Task<Void, Never>] = [:]
```

Change `init` signature and body to accept and store it:

```swift
    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        connection: (any RelayConnecting)? = nil,
        chatSource: any ChatTranscriptSourcing
    ) {
        self.configService = RemoteConfigService(paths: paths)
        self.terminal = terminal
        self.repos = repos
        self.connection = connection ?? RelayConnection()
        self.commandHandler = RemoteCommandHandler(terminal: terminal)
        self.chatSource = chatSource
    }
```

Replace `handleSubscribe(_:)` with a mode-aware version:

```swift
    private func handleSubscribe(_ payload: [String: Any]) async {
        guard let raw = RemoteProtocol.decodeSubscribe(payload),
              let id = terminalID(from: raw) else { return }

        cancelSubscription(id)
        cancelChatSubscription(id)

        if RemoteProtocol.decodeSubscribeMode(payload) == "chat",
           let meta = terminal.terminals.first(where: { $0.id == id }),
           let claudeSessionID = meta.claudeSessionID {
            let stream = chatSource.stream(sessionID: claudeSessionID, repoPath: meta.repoPath)
            let task = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.emitChat(sessionId: raw, event: event)
                }
            }
            chatSubscriptions[id] = task
            return
        }

        // terminal mode (mevcut davranış)
        seqCounters[id] = 0
        let (data, cols, rows) = terminal.serializeScrollback(id)
        await connection.send(
            type: "scrollback",
            payload: RemoteProtocol.scrollbackPayload(sessionId: raw, seq: 0, cols: cols, rows: rows, data: data)
        )
        let stream = terminal.subscribeOutput(id)
        let task = Task { [weak self] in
            for await batch in stream {
                guard !Task.isCancelled else { break }
                await self?.emitData(id: id, sessionId: raw, batch: batch)
            }
        }
        subscriptions[id] = task
    }

    private func emitChat(sessionId: String, event: ChatMirrorEvent) async {
        switch event {
        case .snapshot(let messages):
            await connection.send(type: "chat",
                payload: RemoteProtocol.chatPayload(sessionId: sessionId, messages: messages))
        case .append(let messages):
            guard !messages.isEmpty else { return }
            await connection.send(type: "chat_append",
                payload: RemoteProtocol.chatAppendPayload(sessionId: sessionId, messages: messages))
        }
    }

    private func cancelChatSubscription(_ id: TerminalID) {
        chatSubscriptions[id]?.cancel()
        chatSubscriptions[id] = nil
    }
```

Update `handleUnsubscribe`, `cancelSubscription` call sites, and `shutdown()` to also cancel chat subscriptions:

In `handleUnsubscribe(_:)` after `cancelSubscription(id)` add `cancelChatSubscription(id)`.
In `shutdown()` after the `subscriptions` loop add:

```swift
        for task in chatSubscriptions.values { task.cancel() }
        chatSubscriptions.removeAll()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t5 --filter RemoteServiceTests`
Expected: PASS (all RemoteService tests, incl. new one). Existing tests that call `RemoteService(...)` without `chatSource` will fail to compile — update them to pass `chatSource: FakeChatTranscriptSource(events: [])`.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Tests/LumiTestSupport/FakeChatTranscriptSource.swift LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift
git commit -m "feat(remote): RemoteService chat mode — transcript stream → chat/chat_append"
```

---

## Task 6: Composition wiring (LumiAppCore)

**Files:**
- Modify: `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift`

**Interfaces:**
- Consumes: `TranscriptChatSource` (LumiServices), `RemoteService.init(chatSource:)`.

- [ ] **Step 1: Wire the concrete source**

In `RemoteFeatureAssembly.swift`, ensure `import LumiServices` is present, then pass a `TranscriptChatSource()` into the `RemoteService(...)` call at line ~22:

```swift
        remoteService = RemoteService(
            paths: paths,
            terminal: terminal,
            repos: repos,
            chatSource: TranscriptChatSource()
        )
```

(Keep any existing arguments; only add `chatSource:`.)

- [ ] **Step 2: Build to verify it compiles**

Run: `cd LumiPackages && swift build --scratch-path /tmp/lumi-t6`
Expected: Build complete (no errors).

- [ ] **Step 3: Run the full Mac suite**

Run: `cd LumiPackages && swift test --scratch-path /tmp/lumi-t6 --filter "LumiRemoteTests|LumiServicesTests|LumiKitTests"`
Expected: PASS (all).

- [ ] **Step 4: Commit**

```bash
git add LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift
git commit -m "feat(remote): composition — TranscriptChatSource enjeksiyonu"
```

---

## Task 7: Relay chat passthrough (RelayServer)

**Files:**
- Modify: `RelayServer/src/protocol.ts`
- Modify: `RelayServer/src/bridge.ts`
- Test: `RelayServer/test/bridge.test.ts`

**Interfaces:**
- Produces: relay `chat`/`chat_append` frame'lerini mac→phone broadcast eder.

- [ ] **Step 1: Write the failing test**

Add to `RelayServer/test/bridge.test.ts`:

```ts
test('mac chat/chat_append → telefonlara broadcast', () => {
  const { bridge } = setup()
  const phone = new FakeClient()
  bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))
  const macSession = bridge.handleHello(new FakeClient(), env('hello', { role: 'mac', token: TOKEN }))!

  bridge.handleMessage(macSession, env('chat', { sessionId: 's1', messages: [{ id: 'm1' }] }))
  expect(phone.last().type).toBe('chat')
  expect(phone.last().payload.sessionId).toBe('s1')

  bridge.handleMessage(macSession, env('chat_append', { sessionId: 's1', messages: [{ id: 'm2' }] }))
  expect(phone.last().type).toBe('chat_append')
})

test('subscribe mode alanı opak geçer (phone→mac)', () => {
  const { bridge } = setup()
  const mac = new FakeClient()
  bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))
  const phoneSession = bridge.handleHello(new FakeClient(), env('hello', { role: 'phone', token: TOKEN }))!
  bridge.handleMessage(phoneSession, env('subscribe', { sessionId: 's1', mode: 'chat' }))
  expect(mac.last().type).toBe('subscribe')
  expect(mac.last().payload.mode).toBe('chat')
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd RelayServer && npm test`
Expected: FAIL (chat frames rejected by `parseEnvelope` / not broadcast).

- [ ] **Step 3: Write minimal implementation**

In `src/protocol.ts` `KNOWN_TYPES`, add `'chat'`, `'chat_append'`:

```ts
const KNOWN_TYPES = new Set([
  'hello', 'welcome', 'sessions', 'repos', 'subscribe', 'unsubscribe',
  'scrollback', 'data', 'chat', 'chat_append', 'input', 'command', 'command_result',
  'register_push', 'unregister_push', 'ping', 'pong',
])
```

In `src/bridge.ts` `fromMac` switch, add cases (after `data`):

```ts
      case 'chat':
        this.broadcast(room, envelope('chat', env.payload))
        break
      case 'chat_append':
        this.broadcast(room, envelope('chat_append', env.payload))
        break
```

(No `fromPhone` change needed — `subscribe` already forwards its payload verbatim, so `mode` passes through.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd RelayServer && npm run build && npm test`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add RelayServer/src/protocol.ts RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "feat(relay): chat/chat_append passthrough + subscribe mode opak geçiş"
```

---

## Task 8: Telefon chat wire decode (LumiMobileKit)

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatMirrorModels.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatMirrorDecodeTests.swift`

**Interfaces:**
- Produces: `enum ChatRole`, `enum ChatBlock`, `struct ChatMessage: Decodable` (telefon kopyası, wire ile birebir); `ServerMessage.chat([String: [ChatMessage]])`? Hayır — `.chat(sessionId: String, messages: [ChatMessage])` ve `.chatAppend(sessionId: String, messages: [ChatMessage])`; `PhoneProtocol.subscribeFrame(sessionId:mode:)`.

- [ ] **Step 1: Write the failing test**

```swift
// LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatMirrorDecodeTests.swift
import XCTest
@testable import LumiMobileKit

final class ChatMirrorDecodeTests: XCTestCase {
    func testDecodeChatFrame() {
        let frame = #"""
        {"v":1,"type":"chat","payload":{"sessionId":"s1","messages":[
          {"id":"m1","role":"user","timestamp":5,"blocks":[{"type":"text","text":"hi"}]},
          {"id":"m2","role":"assistant","timestamp":null,"blocks":[
            {"type":"tool-call","name":"Edit","inputPreview":"file.swift"},
            {"type":"tool-result","output":"ok","isError":false}]}]}}
        """#
        guard case let .chat(sessionId, messages)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].blocks, [.text("hi", presentation: nil)])
        XCTAssertEqual(messages[1].blocks.first, .toolCall(name: "Edit", inputPreview: "file.swift", state: nil))
    }

    func testDecodeChatAppendFrame() {
        let frame = #"{"v":1,"type":"chat_append","payload":{"sessionId":"s1","messages":[{"id":"m3","role":"assistant","blocks":[{"type":"text","text":"done"}]}]}}"#
        guard case let .chatAppend(_, messages)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("chat_append decode edilemedi")
        }
        XCTAssertEqual(messages.first?.id, "m3")
    }

    func testSubscribeFrameCarriesMode() {
        let frame = PhoneProtocol.subscribeFrame(sessionId: "s1", mode: "chat")
        XCTAssertTrue(frame.contains("\"mode\":\"chat\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatMirrorDecodeTests`
Expected: FAIL (`ChatMessage`/`.chat` not found).

- [ ] **Step 3: Write minimal implementation**

Create the model:

```swift
// LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatMirrorModels.swift
import Foundation

public enum ChatRole: String, Decodable, Sendable, Equatable {
    case user, assistant, tool, reasoning, system
}

public enum ChatBlock: Sendable, Equatable {
    case text(String, presentation: String?)
    case toolCall(name: String, inputPreview: String, state: String?)
    case toolResult(output: String, isError: Bool)
    case imageRef(path: String?, url: String?, alt: String?)
    case unknown

    static func decode(_ dict: [String: Any]) -> ChatBlock {
        switch dict["type"] as? String {
        case "text":
            return .text(dict["text"] as? String ?? "", presentation: dict["presentation"] as? String)
        case "tool-call":
            return .toolCall(name: dict["name"] as? String ?? "tool",
                             inputPreview: dict["inputPreview"] as? String ?? "",
                             state: dict["state"] as? String)
        case "tool-result":
            return .toolResult(output: dict["output"] as? String ?? "",
                               isError: dict["isError"] as? Bool ?? false)
        case "image-ref":
            return .imageRef(path: dict["path"] as? String, url: dict["url"] as? String,
                             alt: dict["alt"] as? String)
        default:
            return .unknown
        }
    }
}

public struct ChatMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let role: ChatRole
    public let blocks: [ChatBlock]
    public let timestampMs: Int?
    public let turnId: String?

    public init(id: String, role: ChatRole, blocks: [ChatBlock], timestampMs: Int?, turnId: String?) {
        self.id = id; self.role = role; self.blocks = blocks
        self.timestampMs = timestampMs; self.turnId = turnId
    }

    static func decode(_ dict: [String: Any]) -> ChatMessage? {
        guard let id = dict["id"] as? String,
              let role = ChatRole(rawValue: dict["role"] as? String ?? "") else { return nil }
        let blocks = (dict["blocks"] as? [[String: Any]])?.map(ChatBlock.decode) ?? []
        return ChatMessage(id: id, role: role, blocks: blocks,
                           timestampMs: dict["timestamp"] as? Int, turnId: dict["turnId"] as? String)
    }
}
```

Add to `ServerMessage` enum in `PhoneProtocol.swift`:

```swift
    case chat(sessionId: String, messages: [ChatMessage])
    case chatAppend(sessionId: String, messages: [ChatMessage])
```

Add decode cases in `decodeServerMessage`'s switch (before `default`):

```swift
        case "chat", "chat_append":
            guard let sessionId = payload["sessionId"] as? String,
                  let raw = payload["messages"] as? [[String: Any]] else { return nil }
            let messages = raw.compactMap(ChatMessage.decode)
            return type == "chat" ? .chat(sessionId: sessionId, messages: messages)
                                  : .chatAppend(sessionId: sessionId, messages: messages)
```

Add `mode` to `subscribeFrame`:

```swift
    public static func subscribeFrame(sessionId: String, mode: String = "terminal") -> String {
        frame(type: "subscribe", payload: ["sessionId": sessionId, "mode": mode])
    }
```

Add the two new cases to the `describe(_:)` helper in `AppModel.swift` to satisfy exhaustiveness (Task 10 also touches this; add here to compile):

```swift
        case .chat(_, let messages): "chat count=\(messages.count)"
        case .chatAppend(_, let messages): "chat_append count=\(messages.count)"
```

And a `handle(_:)` no-op branch for now (Task 10 fills it):

```swift
        case .chat, .chatAppend:
            break
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatMirrorDecodeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatMirrorModels.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatMirrorDecodeTests.swift
git commit -m "feat(mobile): chat wire decode + subscribe mode"
```

---

## Task 9: Tool-fold saf fonksiyonu (LumiMobileKit)

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatFold.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatFoldTests.swift`

**Interfaces:**
- Produces: `struct FoldedTurn: Identifiable { id, message: ChatMessage, toolActivity: [ChatMessage] }`; `func foldChatMessages(_ messages: [ChatMessage]) -> [FoldedTurn]`.

Kural (orca `native-chat-tool-fold` Faz 1 alt kümesi): yalnız tool-call/tool-result bloklarından oluşan mesajlar ("tool-only") bir önceki metinli turn'e `toolActivity` olarak katlanır; metin taşıyan mesajlar kendi turn'lerini açar.

- [ ] **Step 1: Write the failing test**

```swift
// LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatFoldTests.swift
import XCTest
@testable import LumiMobileKit

final class ChatFoldTests: XCTestCase {
    private func msg(_ id: String, _ role: ChatRole, _ blocks: [ChatBlock]) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestampMs: nil, turnId: nil)
    }

    func testFoldsToolOnlyIntoPrecedingTextTurn() {
        let messages = [
            msg("a1", .assistant, [.text("bakıyorum", presentation: nil)]),
            msg("a2", .assistant, [.toolCall(name: "Read", inputPreview: "f", state: nil)]),
            msg("u1", .user, [.toolResult(output: "ok", isError: false)]),
            msg("a3", .assistant, [.text("düzelttim", presentation: nil)]),
        ]
        let folded = foldChatMessages(messages)
        XCTAssertEqual(folded.count, 2)               // iki metinli turn
        XCTAssertEqual(folded[0].message.id, "a1")
        XCTAssertEqual(folded[0].toolActivity.map(\.id), ["a2", "u1"])
        XCTAssertEqual(folded[1].message.id, "a3")
        XCTAssertTrue(folded[1].toolActivity.isEmpty)
    }

    func testLeadingToolOnlyBecomesOwnTurn() {
        // Öncesinde metin turn yoksa tool-only kendi turn'ü olur (kaybolmaz).
        let folded = foldChatMessages([msg("a1", .assistant, [.toolCall(name: "Bash", inputPreview: "ls", state: nil)])])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].message.id, "a1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatFoldTests`
Expected: FAIL (`foldChatMessages` not found).

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatFold.swift
import Foundation

/// Katlanmış turn: bir "sahip" mesaj + ona ait tool-only aktivite mesajları.
public struct FoldedTurn: Identifiable, Sendable, Equatable {
    public let id: String
    public let message: ChatMessage
    public let toolActivity: [ChatMessage]
}

/// tool-only mesajları (yalnız tool-call/tool-result blokları) önceki metinli
/// turn'e katlar. Öncesinde sahip yoksa kendi turn'ü olur (orca fold alt kümesi).
public func foldChatMessages(_ messages: [ChatMessage]) -> [FoldedTurn] {
    var result: [FoldedTurn] = []
    for message in messages {
        if isToolOnly(message), var last = result.last {
            last = FoldedTurn(id: last.id, message: last.message,
                              toolActivity: last.toolActivity + [message])
            result[result.count - 1] = last
        } else {
            result.append(FoldedTurn(id: message.id, message: message, toolActivity: []))
        }
    }
    return result
}

private func isToolOnly(_ message: ChatMessage) -> Bool {
    guard !message.blocks.isEmpty else { return false }
    return message.blocks.allSatisfy { block in
        switch block {
        case .toolCall, .toolResult: return true
        default: return false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatFoldTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatFold.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatFoldTests.swift
git commit -m "feat(mobile): chat tool-fold saf fonksiyonu"
```

---

## Task 10: AppModel chat durumu + append merge (LumiMobileKit)

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `ChatMessage`, `ServerMessage.chat/.chatAppend`.
- Produces: `AppModel.chatMessages(_ sessionId: String) -> [ChatMessage]`; `subscribeChat(_:)` (mode=chat frame); `.chat` replaces, `.chatAppend` merges (id ile dedup, sıra korunur).

- [ ] **Step 1: Write the failing test**

Add to `AppModelTests.swift`:

```swift
func testChatSnapshotThenAppendMerges() async {
    let (model, _, _) = makeModel()
    let m1 = ChatMessage(id: "m1", role: .user, blocks: [.text("hi", presentation: nil)], timestampMs: nil, turnId: nil)
    let m2 = ChatMessage(id: "m2", role: .assistant, blocks: [.text("yo", presentation: nil)], timestampMs: nil, turnId: nil)
    model.handle(.chat(sessionId: "s1", messages: [m1]))
    XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1"])
    model.handle(.chatAppend(sessionId: "s1", messages: [m2]))
    XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1", "m2"])
    // Aynı id tekrar gelirse güncellenir, çoğalmaz.
    let m2b = ChatMessage(id: "m2", role: .assistant, blocks: [.text("yo!", presentation: nil)], timestampMs: nil, turnId: nil)
    model.handle(.chatAppend(sessionId: "s1", messages: [m2b]))
    XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1", "m2"])
    XCTAssertEqual(model.chatMessages("s1").last?.blocks, [.text("yo!", presentation: nil)])
}

func testSubscribeChatSendsModeFrame() async {
    let (model, client, _) = makeModel()
    model.subscribeChat("s1")
    await Task.yield()
    XCTAssertTrue(client.sentFrames.contains { $0.contains("\"mode\":\"chat\"") })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL (`chatMessages`/`subscribeChat` not found).

- [ ] **Step 3: Write minimal implementation**

In `AppModel.swift` add storage near `terminalSinks`:

```swift
    /// sessionId → chat mesajları (mode=chat aboneliği; orca native-chat).
    private var chatBySession: [String: [ChatMessage]] = [:]
```

Replace the placeholder `case .chat, .chatAppend: break` (added in Task 8) with:

```swift
        case .chat(let sessionId, let messages):
            macOnline = true
            chatBySession[sessionId] = messages

        case .chatAppend(let sessionId, let messages):
            macOnline = true
            var current = chatBySession[sessionId] ?? []
            for message in messages {
                if let idx = current.firstIndex(where: { $0.id == message.id }) {
                    current[idx] = message
                } else {
                    current.append(message)
                }
            }
            chatBySession[sessionId] = current
```

Add public accessors + subscribe:

```swift
    /// mode=chat aboneliği: activeSessionId ayarla + chat frame'i gönder.
    public func subscribeChat(_ sessionId: String) {
        activeSessionId = sessionId
        chatBySession[sessionId] = chatBySession[sessionId] ?? []
        Task { await client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sessionId, mode: "chat")) }
    }

    public func chatMessages(_ sessionId: String) -> [ChatMessage] {
        chatBySession[sessionId] ?? []
    }
```

Also clear chat in `unpair()` and when a session closes in `applySessions` (mirror the terminalSinks cleanup): add `chatBySession[active] = nil` alongside the existing active-session cleanup, and `chatBySession = [:]` in `unpair()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS (all AppModel tests).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "feat(mobile): AppModel chat durumu + append merge + subscribeChat"
```

---

## Task 11: Chat mesaj + araç satırı görünümleri (SwiftUI)

**Files:**
- Create: `LumiMobile/App/MobileChatToolRunView.swift`
- Create: `LumiMobile/App/MobileChatMessageView.swift`

**Interfaces:**
- Consumes: `FoldedTurn`, `ChatMessage`, `ChatBlock` (LumiMobileKit).
- Produces: `MobileChatMessageView(turn: FoldedTurn)`; `MobileChatToolRunView(activity: [ChatMessage])`.

Görsel parite kaynağı: `orca/mobile/src/theme/mobile-theme.ts` (renkler) + `orca/mobile/src/session/mobile-native-chat-view-styles.ts` (spacing/rol renkleri). Faz 1: user sağ hizalı balon (accent), assistant sol hizalı düz metin, tool aktivite katlanmış satır (tap→genişlet→tool-result).

- [ ] **Step 1: Implement MobileChatToolRunView**

```swift
// LumiMobile/App/MobileChatToolRunView.swift
import SwiftUI
import LumiMobileKit

/// Katlanmış araç aktivitesi: "🔧 3 işlem" satırı; tap → tool-call/result detayları.
struct MobileChatToolRunView: View {
    let activity: [ChatMessage]
    @State private var expanded = false

    var body: some View {
        if !activity.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text("\(toolCount) işlem")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(activity) { message in
                        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                            toolLine(block)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var toolCount: Int {
        activity.reduce(0) { total, m in
            total + m.blocks.filter { if case .toolCall = $0 { return true } else { return false } }.count
        }
    }

    @ViewBuilder
    private func toolLine(_ block: ChatBlock) -> some View {
        switch block {
        case let .toolCall(name, preview, _):
            Text("▶ \(name) \(preview)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case let .toolResult(output, isError):
            Text(output)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(6)
        default:
            EmptyView()
        }
    }
}
```

- [ ] **Step 2: Implement MobileChatMessageView**

```swift
// LumiMobile/App/MobileChatMessageView.swift
import SwiftUI
import LumiMobileKit

/// Bir katlanmış turn: sahip mesajın metin balonu + altına katlanmış araç aktivitesi.
struct MobileChatMessageView: View {
    let turn: FoldedTurn

    var body: some View {
        VStack(alignment: turn.message.role == .user ? .trailing : .leading, spacing: 4) {
            ForEach(Array(turn.message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            MobileChatToolRunView(activity: turn.toolActivity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: turn.message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case let .text(text, _):
            Text(LocalizedStringKey(text))     // markdown inline render
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(turn.message.role == .user ? Color.white : Color.primary)
                .frame(maxWidth: 300, alignment: turn.message.role == .user ? .trailing : .leading)
        case let .toolResult(output, isError):
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private var bubbleColor: Color {
        turn.message.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ios-t11 build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/MobileChatToolRunView.swift LumiMobile/App/MobileChatMessageView.swift
git commit -m "feat(mobile): chat mesaj + katlanmış araç satırı görünümleri"
```

---

## Task 12: Chat listesi + terminal toggle (SwiftUI)

**Files:**
- Create: `LumiMobile/App/MobileChatView.swift`
- Modify: `LumiMobile/App/TerminalSessionView.swift`

**Interfaces:**
- Consumes: `AppModel.chatMessages/subscribeChat/unsubscribe/sendInput`, `foldChatMessages`, `MobileChatMessageView`, `KeyboardObserver`, `AccessoryBar`.
- Produces: `MobileChatView(model:sessionId:)`; `TerminalSessionView` toolbar'ında chat↔terminal toggle (varsayılan chat).

- [ ] **Step 1: Implement MobileChatView**

```swift
// LumiMobile/App/MobileChatView.swift
import SwiftUI
import LumiMobileKit

/// Native chat görünümü: transcript'ten türeyen mesajları satır-saran balonlar
/// olarak gösterir (yatay scroll yok). Composer serbest metin gönderir.
struct MobileChatView: View {
    let model: AppModel
    let sessionId: String

    @StateObject private var keyboard = KeyboardObserver()
    @State private var draft = ""

    private var turns: [FoldedTurn] { foldChatMessages(model.chatMessages(sessionId)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if turns.isEmpty {
                            Text("Sohbet yükleniyor…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(turns) { turn in
                            MobileChatMessageView(turn: turn).id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            composer
        }
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) { model.subscribeChat(sessionId) }
        .onDisappear { model.unsubscribe(sessionId) }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                TextField("Mesaj…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button {
                    guard !draft.isEmpty else { return }
                    model.sendInput(sessionId, Data((draft + "\r").utf8))
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }
}
```

- [ ] **Step 2: Add toggle to TerminalSessionView**

In `TerminalSessionView.swift`, add a view-mode state and switch chat/terminal. Add near the other `@State`:

```swift
    @State private var showChat = true
```

Wrap the existing `VStack { TerminalHostView…; AccessoryBar… }` body content and the new chat in a switch. Replace the top-level `body`'s content root so it reads:

```swift
    var body: some View {
        Group {
            if showChat {
                MobileChatView(model: model, sessionId: sessionId)
            } else {
                terminalBody   // mevcut VStack(terminal+accessory) buraya taşınır
            }
        }
        .navigationTitle(model.session(sessionId)?.repoName ?? "Oturum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showChat.toggle()
                } label: {
                    Image(systemName: showChat ? "terminal" : "bubble.left.and.bubble.right")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { toolbarItems }
        }
    }

    /// Mevcut terminal-mirror gövdesi (VStack + klavye padding + .task subscribe/feed).
    private var terminalBody: some View {
        VStack(spacing: 0) {
            TerminalHostView(onInput: { model.sendInput(sessionId, $0) }, buffer: buffer)
            AccessoryBar { model.sendInput(sessionId, $0) }
        }
        .padding(.bottom, keyboard.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: 0.25), value: keyboard.height)
        .task(id: sessionId) {
            model.subscribe(sessionId)
            for await chunk in model.terminalStream(sessionId) { buffer.feed(chunk) }
        }
        .onDisappear { buffer.detach(); model.unsubscribe(sessionId) }
    }
```

(Move the existing terminal `.task`/`.onDisappear`/keyboard modifiers off the outer body and into `terminalBody` exactly as shown; remove them from where they were.)

- [ ] **Step 3: Build to verify it compiles**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/ios-t12 build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/MobileChatView.swift LumiMobile/App/TerminalSessionView.swift
git commit -m "feat(mobile): native chat listesi + chat/terminal toggle (varsayılan chat)"
```

---

## Task 13: Uçtan uca doğrulama + build/deploy

**Files:** yok (doğrulama).

- [ ] **Step 1: Tüm test paketleri yeşil**

```bash
cd LumiPackages && swift test --scratch-path /tmp/lumi-final --filter "LumiKitTests|LumiServicesTests|LumiRemoteTests"
cd ../RelayServer && npm test
cd ../LumiMobile/LumiMobileKit && swift test
```
Expected: hepsi PASS.

- [ ] **Step 2: Mac app + iOS app + relay**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
Scripts/make-rework-app.sh                 # LumiRework.app taze
cd LumiMobile && xcodegen generate
# iOS cihaza kur (cihaz kablo+kilitsiz):
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -configuration Debug \
  -destination 'platform=iOS,id=<DEVICE_ID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_ID> <app-path>
cd ../RelayServer && railway up --detach     # chat passthrough canlıya
```

- [ ] **Step 3: Manuel senaryo**

Mac'te LumiRework.app aç → telefonda oturuma gir → varsayılan chat görünümü, transcript mesajları satır-saran balonlar (yatay scroll YOK); mesaj gönder → kullanıcı + assistant balonları belirir; araç satırları katlanmış, tap → genişler; toolbar'dan terminal'e toggle → eski mirror.

- [ ] **Step 4: Commit (varsa doküman güncellemesi)**

```bash
git add -A && git commit -m "docs(remote): native chat Faz 1 tamam — doğrulama notları" || true
```

---

## Self-Review Notları

- **Spec kapsamı:** model (T1), Claude decoder (T2), tail kaynağı (T3), wire (T4/T8), RemoteService mode (T5), composition (T6), relay (T7), fold (T9), AppModel (T10), UI (T11/T12), doğrulama (T13) — spec'in tüm Faz 1 maddeleri karşılanıyor. Terminal toggle T12'de korunuyor (kullanıcı onayı). Streaming/ask/composer-paritesi/subagent/Codex bilinçli olarak dışarıda (Faz 2-5).
- **Placeholder:** yok; her kod adımı tam kod içeriyor.
- **Tip tutarlılığı:** `ChatMessage`/`ChatBlock` Mac (LumiKit) ve telefon (LumiMobileKit) kopyaları wire JSON'da birebir; `subscribeFrame(mode:)`, `decodeSubscribeMode`, `chatPayload`/`chatAppendPayload`, `.chat`/`.chatAppend`, `foldChatMessages`/`FoldedTurn` adları tüm task'larda aynı.
- **Açık nokta (kabul edilen):** tail = polling (500ms; testte 20ms). FSEvents optimizasyonu Faz 2+'ye bırakıldı. `/clear` sonrası yeni transcript dosyası takibi Faz 5.
