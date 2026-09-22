# Yol B / Faz 1 — Mac stream-json Chat Çekirdeği Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac tarafında `claude`'u stream-json child olarak çalıştıran, çıktısını token-token bir journal'a katlayan, headless test edilebilir bir chat veri çekirdeği kurmak (UI yok).

**Architecture:** Yeni bir uzun-yaşayan `StreamingProcess` soyutlaması pipe tabanlı child spawn eder; NDJSON satırları saf `StreamJsonEvent.decode` ile tip'li event'lere, saf `ChatJournal.reduce` ile mevcut `ChatMessage`/`ChatBlock` tipleriyle uyumlu bir duruma dönüşür; `StreamJsonAgentSession` bunları birleştirir. Chat oturumları PTY terminal modelinden ayrı `SessionKind`/`ChatSessionMeta` ile tutulur.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (LumiPackages), Foundation Process/Pipe, mevcut LumiWire `ChatMessage`/`ChatBlock`.

**Spec:** `docs/superpowers/specs/2026-09-17-streamjson-chat-phase1-design.md` (bağlayıcı).

## Global Constraints

- Branch: `feat/remote-orca-main` — **main'e commit YASAK**.
- UI YOK (Faz 1 salt veri katmanı); relay değişmez; telefon/Mac view sonraki fazlar.
- Chat oturumu **PTY değil** — pipe tabanlı stream-json child. PTY→UI backpressure/replay gereksinimleri (Ek A) chat lane'e uygulanmaz.
- Journal, mevcut LumiWire tiplerini üretir: `ChatMessage(id, role, blocks, timestampMs, turnId)`, `ChatBlock` (`.text`, `.toolCall`, `.toolResult`, …). Yeni wire tipi eklenmez.
- Canlı streaming metni YALNIZ `content_block_delta` içindeki `text_delta`'dan birikir; `thinking_delta` ve `input_json_delta` streaming metnine katılmaz.
- Env hijyeni: child env'inde `CLAUDECODE` + `CLAUDE_CODE_*` + `CLAUDE_EFFORT` sıfırlanır, `CLAUDE_CONFIG_DIR` korunur (mevcut `TerminalEnvironment` kuralı).
- `~/.lumi` persistence formatları değişmez; chat oturumları additive/ayrı.
- process I/O enjeksiyon üzerinden (`StreamingProcessSpawning` + `BinaryLocating`); Fake'ler `LumiTestSupport`'a, canlı kayıt `LiveServiceRegistry`/`FakeServiceRegistry`'ye eklenir.
- LumiUI literal yasağı bu faza uygulanmaz (UI yok).
- Test komutları: `cd LumiPackages && swift build && swift test` (+ `swift build -c release --product Lumi` sweep'te).

## Dosya yapısı

- `LumiPackages/Sources/LumiKit/NativeChat/ClaudeContentBlockDecoding.swift` — Anthropic content-block dict → `ChatBlock` (paylaşılan, saf).
- `LumiPackages/Sources/LumiKit/NativeChat/StreamJsonEvent.swift` — NDJSON satır → `StreamJsonEvent` (saf).
- `LumiPackages/Sources/LumiKit/NativeChat/ChatJournal.swift` — `StreamJsonEvent` → `ChatJournalState` reducer (saf).
- `LumiPackages/Sources/LumiKit/Models/ChatSessionModels.swift` — `SessionKind`, `ChatSessionMeta`.
- `LumiPackages/Sources/LumiKit/Protocols/StreamingProcess.swift` — `StreamingProcessSpawning` + `StreamingProcessHandle` protokolleri.
- `LumiPackages/Sources/LumiServices/NativeChat/LiveStreamingProcess.swift` — Foundation Process/Pipe canlı impl.
- `LumiPackages/Sources/LumiServices/NativeChat/StreamJsonAgentSession.swift` — spawn + decode + reduce + send.
- `LumiPackages/Tests/LumiTestSupport/FakeStreamingProcess.swift` — scripted satır + yazılan stdin yakalama.
- `LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift` — (Modify) blok çözümü paylaşılan yardımcıya delege.

---

### Task 1: Paylaşılan content-block decoder + transcript decoder refactor

**Files:**
- Create: `LumiPackages/Sources/LumiKit/NativeChat/ClaudeContentBlockDecoding.swift`
- Modify: `LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift:31-53`
- Test: `LumiPackages/Tests/LumiKitTests/ClaudeContentBlockDecodingTests.swift`

**Interfaces:**
- Produces: `enum ClaudeContentBlockDecoding { static func decodeBlock(_ dict: [String: Any]) -> ChatBlock? ; static func decodeBlocks(_ content: Any?) -> [ChatBlock] }`. `assistant`/transcript content dizisini `ChatBlock`'lara çevirir; `thinking` bloğu ve tanınmayan tip `nil`. `text`→`.text`, `tool_use`→`.toolCall(name, inputPreview, state:"completed")`, `tool_result`→`.toolResult`.

- [ ] **Step 1: Failing test**

`ClaudeContentBlockDecodingTests.swift`:

```swift
import Testing
import Foundation
import LumiWire
@testable import LumiKit

@Suite struct ClaudeContentBlockDecodingTests {
    @Test func decodesTextToolUseToolResultSkipsThinking() {
        let content: [[String: Any]] = [
            ["type": "thinking", "thinking": "hmm"],
            ["type": "text", "text": "Selam"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
            ["type": "tool_result", "content": "ok", "is_error": false],
        ]
        let blocks = ClaudeContentBlockDecoding.decodeBlocks(content)
        #expect(blocks.count == 3)   // thinking atlanır
        #expect(blocks[0] == .text("Selam", presentation: nil))
        if case let .toolCall(name, preview, state) = blocks[1] {
            #expect(name == "Bash"); #expect(preview.contains("command=ls")); #expect(state == "completed")
        } else { Issue.record("tool_use bekleniyordu") }
        if case let .toolResult(output, isError) = blocks[2] {
            #expect(output == "ok"); #expect(isError == false)
        } else { Issue.record("tool_result bekleniyordu") }
    }

    @Test func stringContentBecomesSingleText() {
        #expect(ClaudeContentBlockDecoding.decodeBlocks("düz metin") == [.text("düz metin", presentation: nil)])
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter ClaudeContentBlockDecodingTests`
Expected: derleme hatası (`ClaudeContentBlockDecoding` yok).

- [ ] **Step 3: Implementasyon**

`ClaudeContentBlockDecoding.swift` (mevcut `ClaudeTranscriptChatDecoder.decodeBlocks`/`preview`/`output`/`flatten` mantığı taşınır):

```swift
import Foundation
import LumiWire

/// Anthropic mesaj `content` dizisini `ChatBlock`'lara çeviren paylaşılan saf
/// yardımcı. Hem transcript JSONL decoder'ı hem stream-json `assistant` snapshot'ı
/// aynı blok şeklini gördüğü için tek kaynak (spec 2026-09-17 Faz 1 §B).
public enum ClaudeContentBlockDecoding {
    private static let maxPreview = 200
    private static let maxOutput = 4000

    public static func decodeBlocks(_ content: Any?) -> [ChatBlock] {
        if let string = content as? String {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.text(t, presentation: nil)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap(decodeBlock)
    }

    public static func decodeBlock(_ block: [String: Any]) -> ChatBlock? {
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
            return nil   // thinking + tanınmayan → gösterilmez
        }
    }

    private static func preview(_ input: Any?) -> String {
        let text: String
        if let s = input as? String { text = s }
        else if let d = input as? [String: Any] {
            text = d.map { "\($0.key)=\(flatten($0.value))" }.sorted().joined(separator: " ")
        } else { text = "" }
        return String(text.prefix(maxPreview))
    }

    private static func output(_ content: Any?) -> String {
        let text: String
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { text = "" }
        return String(text.prefix(maxOutput))
    }

    private static func flatten(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value).prefix(80).description
    }
}
```

`ClaudeTranscriptChatDecoder.swift`: `decodeBlocks(_:)` gövdesini `ClaudeContentBlockDecoding.decodeBlocks(content)` çağrısıyla değiştir; artık kullanılmayan private `decodeBlocks`/`preview`/`output`/`flatten` metodlarını sil (LumiServices zaten LumiKit'e bağımlı).

- [ ] **Step 4: PASS + transcript regresyonu yeşil**

Run: `cd LumiPackages && swift test --filter "ClaudeContentBlockDecodingTests|ClaudeTranscriptChatDecoder|TranscriptChat"`
Expected: yeni test PASS; transcript decoder testleri PASS (paylaşım kırmadı).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/NativeChat/ClaudeContentBlockDecoding.swift LumiPackages/Sources/LumiServices/NativeChat/ClaudeTranscriptChatDecoder.swift LumiPackages/Tests/LumiKitTests/ClaudeContentBlockDecodingTests.swift
git commit -m "refactor(chat): paylaşılan ClaudeContentBlockDecoding — transcript + stream-json tek kaynak"
```

---

### Task 2: `StreamJsonEvent` + decode

**Files:**
- Create: `LumiPackages/Sources/LumiKit/NativeChat/StreamJsonEvent.swift`
- Test: `LumiPackages/Tests/LumiKitTests/StreamJsonEventTests.swift`

**Interfaces:**
- Consumes: `ClaudeContentBlockDecoding.decodeBlocks` (Task 1).
- Produces:
  ```swift
  public enum StreamJsonEvent: Equatable, Sendable {
      case systemInit(sessionID: String, cwd: String?)
      case streamTextDelta(String)
      case assistantSnapshot(id: String, blocks: [ChatBlock])
      case userEcho(id: String, blocks: [ChatBlock])
      case turnResult(costUSD: Double?, outputTokens: Int?)
      case rateLimit
      case ignored
  }
  extension StreamJsonEvent { public static func decode(_ line: String) -> StreamJsonEvent }
  ```

- [ ] **Step 1: Failing test (gerçek NDJSON şekilleri)**

`StreamJsonEventTests.swift`:

```swift
import Testing
import Foundation
import LumiWire
@testable import LumiKit

@Suite struct StreamJsonEventTests {
    @Test func decodesSystemInit() {
        let line = #"{"type":"system","subtype":"init","cwd":"/repo","session_id":"S1"}"#
        #expect(StreamJsonEvent.decode(line) == .systemInit(sessionID: "S1", cwd: "/repo"))
    }
    @Test func decodesVisibleTextDeltaOnly() {
        let text = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#
        #expect(StreamJsonEvent.decode(text) == .streamTextDelta("Hel"))
        // thinking_delta streaming metnine katılmaz → ignored
        let think = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        #expect(StreamJsonEvent.decode(think) == .ignored)
    }
    @Test func decodesAssistantSnapshot() {
        let line = #"{"type":"assistant","message":{"role":"assistant","id":"msg_1","content":[{"type":"text","text":"Selam"}]}}"#
        #expect(StreamJsonEvent.decode(line) == .assistantSnapshot(id: "msg_1", blocks: [.text("Selam", presentation: nil)]))
    }
    @Test func decodesResult() {
        let line = #"{"type":"result","subtype":"success","result":"Selam","total_cost_usd":0.01,"usage":{"output_tokens":5}}"#
        #expect(StreamJsonEvent.decode(line) == .turnResult(costUSD: 0.01, outputTokens: 5))
    }
    @Test func unknownAndGarbageAreIgnored() {
        #expect(StreamJsonEvent.decode(#"{"type":"rate_limit_event"}"#) == .rateLimit)
        #expect(StreamJsonEvent.decode(#"{"type":"system","subtype":"status"}"#) == .ignored)
        #expect(StreamJsonEvent.decode("yarım-json{") == .ignored)
        #expect(StreamJsonEvent.decode("") == .ignored)
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter StreamJsonEventTests`
Expected: derleme hatası (`StreamJsonEvent` yok).

- [ ] **Step 3: Implementasyon**

`StreamJsonEvent.swift`:

```swift
import Foundation
import LumiWire

/// Bir stream-json NDJSON satırının tip'li karşılığı (spec 2026-09-17 Faz 1 §B).
/// Gerçek `claude --output-format stream-json` taksonomisine dayanır. Reducer'ın
/// umursadığı case'ler dışındaki her şey `.ignored` (akış ölmez).
public enum StreamJsonEvent: Equatable, Sendable {
    case systemInit(sessionID: String, cwd: String?)
    case streamTextDelta(String)
    case assistantSnapshot(id: String, blocks: [ChatBlock])
    case userEcho(id: String, blocks: [ChatBlock])
    case turnResult(costUSD: Double?, outputTokens: Int?)
    case rateLimit
    case ignored

    public static func decode(_ line: String) -> StreamJsonEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String else { return .ignored }
            return .systemInit(sessionID: sid, cwd: obj["cwd"] as? String)
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignored }
            return .streamTextDelta(text)
        case "assistant":
            guard let msg = obj["message"] as? [String: Any], let id = msg["id"] as? String else { return .ignored }
            let blocks = ClaudeContentBlockDecoding.decodeBlocks(msg["content"])
            return .assistantSnapshot(id: id, blocks: blocks)
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return .ignored }
            let id = (msg["id"] as? String) ?? "user-\(UUID().uuidString)"
            let blocks = ClaudeContentBlockDecoding.decodeBlocks(msg["content"])
            return blocks.isEmpty ? .ignored : .userEcho(id: id, blocks: blocks)
        case "result":
            let cost = obj["total_cost_usd"] as? Double
            let tokens = (obj["usage"] as? [String: Any])?["output_tokens"] as? Int
            return .turnResult(costUSD: cost, outputTokens: tokens)
        case "rate_limit_event":
            return .rateLimit
        default:
            return .ignored
        }
    }
}
```

- [ ] **Step 4: PASS**

Run: `cd LumiPackages && swift test --filter StreamJsonEventTests`
Expected: tümü PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/NativeChat/StreamJsonEvent.swift LumiPackages/Tests/LumiKitTests/StreamJsonEventTests.swift
git commit -m "feat(chat): StreamJsonEvent — NDJSON satır decode (gerçek stream-json taksonomisi)"
```

---

### Task 3: `ChatJournal` reducer

**Files:**
- Create: `LumiPackages/Sources/LumiKit/NativeChat/ChatJournal.swift`
- Test: `LumiPackages/Tests/LumiKitTests/ChatJournalTests.swift`

**Interfaces:**
- Consumes: `StreamJsonEvent` (Task 2), `ChatMessage`/`ChatBlock` (LumiWire).
- Produces:
  ```swift
  public struct ChatJournalState: Equatable, Sendable {
      public var messages: [ChatMessage]
      public var streamingText: String?
      public var turnActive: Bool
      public var lastCostUSD: Double?
      public init()
  }
  public final class ChatJournal {
      public private(set) var state: ChatJournalState
      public init()
      @discardableResult public func reduce(_ event: StreamJsonEvent) -> ChatJournalState
  }
  ```

- [ ] **Step 1: Failing test**

`ChatJournalTests.swift`:

```swift
import Testing
import Foundation
import LumiWire
@testable import LumiKit

@Suite struct ChatJournalTests {
    @Test func streamingTextAccumulatesThenClearsOnSnapshot() {
        let j = ChatJournal()
        _ = j.reduce(.systemInit(sessionID: "S1", cwd: "/repo"))
        _ = j.reduce(.streamTextDelta("Hel"))
        _ = j.reduce(.streamTextDelta("lo"))
        #expect(j.state.streamingText == "Hello")
        #expect(j.state.turnActive == true)
        _ = j.reduce(.assistantSnapshot(id: "msg_1", blocks: [.text("Hello", presentation: nil)]))
        // Tamamlanmış mesaj streaming'i geçince overlay düşer:
        #expect(j.state.streamingText == nil)
        #expect(j.state.messages.count == 1)
        #expect(j.state.messages[0].id == "msg_1")
        #expect(j.state.messages[0].role == .assistant)
    }
    @Test func snapshotUpsertsByIdNoDuplicate() {
        let j = ChatJournal()
        _ = j.reduce(.assistantSnapshot(id: "msg_1", blocks: [.text("a", presentation: nil)]))
        _ = j.reduce(.assistantSnapshot(id: "msg_1", blocks: [.text("a", presentation: nil), .toolCall(name: "Bash", inputPreview: "command=ls", state: "completed")]))
        #expect(j.state.messages.count == 1)             // aynı id → upsert
        #expect(j.state.messages[0].blocks.count == 2)
    }
    @Test func userEchoAppends() {
        let j = ChatJournal()
        _ = j.reduce(.userEcho(id: "u1", blocks: [.text("merhaba", presentation: nil)]))
        #expect(j.state.messages.count == 1)
        #expect(j.state.messages[0].role == .user)
    }
    @Test func resultEndsTurn() {
        let j = ChatJournal()
        _ = j.reduce(.streamTextDelta("x"))
        #expect(j.state.turnActive == true)
        _ = j.reduce(.turnResult(costUSD: 0.02, outputTokens: 5))
        #expect(j.state.turnActive == false)
        #expect(j.state.lastCostUSD == 0.02)
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter ChatJournalTests`
Expected: derleme hatası (`ChatJournal` yok).

- [ ] **Step 3: Implementasyon**

`ChatJournal.swift`:

```swift
import Foundation
import LumiWire

/// Stream-json event akışını, mevcut wire tipleriyle (Faz 2 wire'ı yeniden
/// kullansın) uyumlu bir duruma katlayan saf reducer (spec 2026-09-17 Faz 1 §C).
public struct ChatJournalState: Equatable, Sendable {
    public var messages: [ChatMessage]
    public var streamingText: String?
    public var turnActive: Bool
    public var lastCostUSD: Double?
    public init() { messages = []; streamingText = nil; turnActive = false; lastCostUSD = nil }
}

public final class ChatJournal {
    public private(set) var state = ChatJournalState()
    public init() {}

    @discardableResult
    public func reduce(_ event: StreamJsonEvent) -> ChatJournalState {
        switch event {
        case .systemInit:
            break
        case let .streamTextDelta(text):
            state.turnActive = true
            state.streamingText = (state.streamingText ?? "") + text
        case let .assistantSnapshot(id, blocks):
            upsert(ChatMessage(id: id, role: .assistant, blocks: blocks, timestampMs: nil, turnId: id))
            // Tamamlanmış assistant mesajı canlı overlay'i süpürür (orca gate mantığı).
            state.streamingText = nil
        case let .userEcho(id, blocks):
            upsert(ChatMessage(id: id, role: .user, blocks: blocks, timestampMs: nil, turnId: id))
        case let .turnResult(cost, _):
            state.turnActive = false
            state.streamingText = nil
            if let cost { state.lastCostUSD = cost }
        case .rateLimit, .ignored:
            break
        }
        return state
    }

    private func upsert(_ message: ChatMessage) {
        if let idx = state.messages.firstIndex(where: { $0.id == message.id }) {
            state.messages[idx] = message
        } else {
            state.messages.append(message)
        }
    }
}
```

- [ ] **Step 4: PASS**

Run: `cd LumiPackages && swift test --filter ChatJournalTests`
Expected: tümü PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/NativeChat/ChatJournal.swift LumiPackages/Tests/LumiKitTests/ChatJournalTests.swift
git commit -m "feat(chat): ChatJournal reducer — stream-json event'lerini mesaj+streaming durumuna katlar"
```

---

### Task 4: `StreamingProcess` protokolü + canlı impl + Fake

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Protocols/StreamingProcess.swift`
- Create: `LumiPackages/Sources/LumiServices/NativeChat/LiveStreamingProcess.swift`
- Create: `LumiPackages/Tests/LumiTestSupport/FakeStreamingProcess.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/LiveStreamingProcessTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol StreamingProcessHandle: Sendable {
      var lines: AsyncStream<String> { get }      // stdout, satır-sınırlı
      func write(_ text: String)                  // stdin'e yaz (metin verildiği gibi, newline ekleyen çağıran)
      func terminate()
  }
  public protocol StreamingProcessSpawning: Sendable {
      func spawn(executable: String, arguments: [String],
                 currentDirectory: String?, environment: [String: String]) -> any StreamingProcessHandle
  }
  ```
- `FakeStreamingProcess: StreamingProcessSpawning` — `scriptedLines: [String]` verilir; spawn edilen handle bu satırları `lines`'a yayar; `written: [String]` yazılan stdin'i biriktirir (test görünürlüğü).

- [ ] **Step 1: Failing test (canlı impl `/bin/cat` ile)**

`LiveStreamingProcessTests.swift`:

```swift
import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct LiveStreamingProcessTests {
    @Test func catEchoesWrittenLines() async throws {
        let spawner = LiveStreamingProcess()
        let handle = spawner.spawn(executable: "/bin/cat", arguments: [],
                                   currentDirectory: nil, environment: [:])
        handle.write("merhaba\n")
        handle.write("dünya\n")
        var got: [String] = []
        for await line in handle.lines {
            got.append(line)
            if got.count == 2 { break }
        }
        handle.terminate()
        #expect(got == ["merhaba", "dünya"])
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter LiveStreamingProcessTests`
Expected: derleme hatası (`LiveStreamingProcess` yok).

- [ ] **Step 3: Implementasyon**

`StreamingProcess.swift` (LumiKit) — yukarıdaki iki protokol.

`LiveStreamingProcess.swift` (LumiServices):

```swift
import Foundation
import LumiKit

/// Foundation Process + Pipe tabanlı uzun-yaşayan stream-json child (spec §A).
/// PTY değil: saf pipe I/O. stdout satır-sınırlı `AsyncStream`'e; yarım son satır
/// bir sonraki chunk'a taşınır. `Process` ve pipe'lar handle içinde kapsüllenir.
public final class LiveStreamingProcess: StreamingProcessSpawning {
    public init() {}

    public func spawn(executable: String, arguments: [String],
                      currentDirectory: String?, environment: [String: String]) -> any StreamingProcessHandle {
        LiveHandle(executable: executable, arguments: arguments,
                   currentDirectory: currentDirectory, environment: environment)
    }
}

private final class LiveHandle: StreamingProcessHandle, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let continuation: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>
    private var buffer = Data()
    private let lock = NSLock()

    init(executable: String, arguments: [String], currentDirectory: String?, environment: [String: String]) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if !environment.isEmpty { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.continuation.finish() }
        do { try process.run() } catch { continuation.finish() }
    }

    private func ingest(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: Data(lineData), encoding: .utf8) {
                continuation.yield(s)
            }
        }
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
```

`FakeStreamingProcess.swift` (LumiTestSupport):

```swift
import Foundation
import LumiKit

/// Test için: verilen satırları `lines`'a yayan, yazılan stdin'i biriktiren
/// sahte streaming süreç. `emitAll()` scripted satırları sırayla verir.
public final class FakeStreamingProcess: StreamingProcessSpawning, @unchecked Sendable {
    public private(set) var handles: [FakeStreamingHandle] = []
    private let scriptedLines: [String]
    public init(scriptedLines: [String] = []) { self.scriptedLines = scriptedLines }

    public func spawn(executable: String, arguments: [String],
                      currentDirectory: String?, environment: [String: String]) -> any StreamingProcessHandle {
        let h = FakeStreamingHandle(scriptedLines: scriptedLines)
        handles.append(h)
        return h
    }
}

public final class FakeStreamingHandle: StreamingProcessHandle, @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    public private(set) var written: [String] = []
    private let scriptedLines: [String]

    public init(scriptedLines: [String]) {
        self.scriptedLines = scriptedLines
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
    }
    /// Scripted satırları yayınlar ve stream'i bitirir (test kontrollü).
    public func emitAll() { for l in scriptedLines { continuation.yield(l) }; continuation.finish() }
    public func emit(_ line: String) { continuation.yield(line) }
    public func finish() { continuation.finish() }
    public func write(_ text: String) { written.append(text) }
    public func terminate() { continuation.finish() }
}
```

- [ ] **Step 4: PASS**

Run: `cd LumiPackages && swift test --filter LiveStreamingProcessTests`
Expected: PASS (`/bin/cat` iki satırı yankılar).

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Protocols/StreamingProcess.swift LumiPackages/Sources/LumiServices/NativeChat/LiveStreamingProcess.swift LumiPackages/Tests/LumiTestSupport/FakeStreamingProcess.swift LumiPackages/Tests/LumiServicesTests/LiveStreamingProcessTests.swift
git commit -m "feat(chat): StreamingProcess soyutlaması + Foundation canlı impl + Fake"
```

---

### Task 5: `StreamJsonAgentSession` + oturum türü modeli

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Models/ChatSessionModels.swift`
- Create: `LumiPackages/Sources/LumiServices/NativeChat/StreamJsonAgentSession.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/StreamJsonAgentSessionTests.swift`

**Interfaces:**
- Consumes: `StreamingProcessSpawning` (Task 4), `BinaryLocating`, `StreamJsonEvent`+`ChatJournal` (Task 2/3), `FakeStreamingProcess`.
- Produces:
  ```swift
  public enum SessionKind: String, Sendable, Equatable { case terminal, chat }
  public struct ChatSessionMeta: Sendable, Identifiable, Equatable {
      public let id: String; public let repoPath: String; public let createdAt: Date
      public init(id: String, repoPath: String, createdAt: Date)
  }
  public actor StreamJsonAgentSession {
      public init(sessionID: String, repoPath: String, environment: [String: String],
                  spawner: any StreamingProcessSpawning, binaryLocator: any BinaryLocating)
      public func start() async                       // claude'u locate+spawn, okuma döngüsü başlar
      public func send(_ text: String) async          // user message NDJSON → stdin
      public func snapshots() -> AsyncStream<ChatJournalState>
      public func stop() async
  }
  ```

- [ ] **Step 1: Failing test (Fake spawner)**

`StreamJsonAgentSessionTests.swift`:

```swift
import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiServices

@Suite struct StreamJsonAgentSessionTests {
    @Test func reducesScriptedNdjsonIntoJournalSnapshots() async throws {
        let scripted = [
            #"{"type":"system","subtype":"init","cwd":"/repo","session_id":"S1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"am"}}}"#,
            #"{"type":"assistant","message":{"role":"assistant","id":"msg_1","content":[{"type":"text","text":"Selam"}]}}"#,
            #"{"type":"result","subtype":"success","result":"Selam","total_cost_usd":0.01,"usage":{"output_tokens":2}}"#,
        ]
        let fake = FakeStreamingProcess(scriptedLines: scripted)
        let locator = FixedBinaryLocator(path: "/usr/bin/claude")
        let session = StreamJsonAgentSession(sessionID: "S1", repoPath: "/repo", environment: [:],
                                             spawner: fake, binaryLocator: locator)
        await session.start()
        // Aboneliği emit'ten ÖNCE al: emitAll stream'i hemen bitirir; geç abone
        // olan yalnız başlangıç snapshot'ını görüp finish'i kaçırabilir.
        let stream = await session.snapshots()
        fake.handles.first?.emitAll()
        var final: ChatJournalState?
        for await snap in stream { final = snap }   // stream, child bitince kapanır
        #expect(final?.messages.count == 1)
        #expect(final?.messages.first?.id == "msg_1")
        #expect(final?.turnActive == false)
        #expect(final?.lastCostUSD == 0.01)
    }

    @Test func sendWritesUserMessageNdjson() async throws {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let session = StreamJsonAgentSession(sessionID: "S1", repoPath: "/repo", environment: [:],
                                             spawner: fake, binaryLocator: FixedBinaryLocator(path: "/usr/bin/claude"))
        await session.start()
        await session.send("merhaba")
        let written = fake.handles.first?.written.joined() ?? ""
        #expect(written.contains("\"type\":\"user\""))
        #expect(written.contains("merhaba"))
        #expect(written.hasSuffix("\n"))
        await session.stop()
    }
}

/// Test yardımcısı: sabit yol döndüren binary locator.
struct FixedBinaryLocator: BinaryLocating {
    let path: String?
    func locate(_ name: String, timeout: TimeInterval) async -> String? { path }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiPackages && swift test --filter StreamJsonAgentSessionTests`
Expected: derleme hatası (`StreamJsonAgentSession`/`SessionKind` yok).

- [ ] **Step 3: Implementasyon**

`ChatSessionModels.swift` (LumiKit) — `SessionKind` + `ChatSessionMeta` (yukarıdaki imzalar).

`StreamJsonAgentSession.swift` (LumiServices):

```swift
import Foundation
import LumiKit
import LumiWire

/// Bir chat oturumu: claude'u stream-json child olarak çalıştırır, çıktısını
/// journal'a katlar, kullanıcı mesajını stdin'e yazar (spec §D). PTY yok.
public actor StreamJsonAgentSession {
    private let sessionID: String
    private let repoPath: String
    private let environment: [String: String]
    private let spawner: any StreamingProcessSpawning
    private let binaryLocator: any BinaryLocating

    private let journal = ChatJournal()
    private var handle: (any StreamingProcessHandle)?
    private var readTask: Task<Void, Never>?
    private var snapshotContinuations: [AsyncStream<ChatJournalState>.Continuation] = []

    public init(sessionID: String, repoPath: String, environment: [String: String],
                spawner: any StreamingProcessSpawning, binaryLocator: any BinaryLocating) {
        self.sessionID = sessionID
        self.repoPath = repoPath
        self.environment = environment
        self.spawner = spawner
        self.binaryLocator = binaryLocator
    }

    public func start() async {
        guard handle == nil else { return }
        let claude = await binaryLocator.locate("claude") ?? "claude"
        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose", "--session-id", sessionID]
        let h = spawner.spawn(executable: claude, arguments: args,
                              currentDirectory: repoPath, environment: environment)
        handle = h
        readTask = Task { [weak self] in
            guard let self else { return }
            for await line in h.lines {
                await self.ingest(line)
            }
            await self.finishSnapshots()
        }
    }

    private func ingest(_ line: String) {
        let snap = journal.reduce(StreamJsonEvent.decode(line))
        for c in snapshotContinuations { c.yield(snap) }
    }

    private func finishSnapshots() {
        for c in snapshotContinuations { c.finish() }
        snapshotContinuations.removeAll()
    }

    public func send(_ text: String) async {
        let payload: [String: Any] = ["type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        handle?.write(json + "\n")
    }

    public func snapshots() -> AsyncStream<ChatJournalState> {
        AsyncStream { continuation in
            continuation.yield(journal.state)   // mevcut durum
            snapshotContinuations.append(continuation)
        }
    }

    public func stop() async {
        readTask?.cancel()
        handle?.terminate()
        handle = nil
        finishSnapshots()
    }
}
```

- [ ] **Step 4: PASS**

Run: `cd LumiPackages && swift test --filter StreamJsonAgentSessionTests`
Expected: iki test PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/ChatSessionModels.swift LumiPackages/Sources/LumiServices/NativeChat/StreamJsonAgentSession.swift LumiPackages/Tests/LumiServicesTests/StreamJsonAgentSessionTests.swift
git commit -m "feat(chat): StreamJsonAgentSession — stream-json child spawn + journal + send; SessionKind/ChatSessionMeta"
```

---

### Task 6: Bağlayıcı doc güncellemesi + DI kaydı + sweep

**Files:**
- Modify: `docs/design/00-architecture.md` (chat lane bölümü + SessionKind)
- Modify: `docs/decisions.md` (yeni karar)
- Modify: `LumiPackages/Sources/LumiServices/...` DI kayıt noktası (`LiveServiceRegistry`) — `LiveStreamingProcess` canlı kaydı
- Modify: `LumiPackages/Tests/LumiTestSupport/...` `FakeServiceRegistry` — `FakeStreamingProcess` kaydı (varsa registry kalıbı)

**Interfaces:**
- Consumes: Task 4/5 çıktıları.

Not: Faz 1'de UI/kompozisyon tüketicisi yok; DI kaydı yalnız canlı `StreamingProcessSpawning`'i registry'ye ekler ki Faz 2 tüketebilsin. Registry kalıbı yoksa (StreamingProcess'i doğrudan AppContainer enjekte ediyorsa) bu adımı AppContainer'a tek satır ekleme olarak uygula; kalıbı bulup uygula.

- [ ] **Step 1: DI kayıt noktasını bul**

Run: `grep -rn "LiveServiceRegistry\|FakeServiceRegistry\|ProcessRunning(" LumiPackages/Sources/LumiServices LumiPackages/Sources/LumiAppCore 2>/dev/null | head`
Beklenen: registry veya composition root'ta `ProcessRunning` canlı kaydının yeri. Aynı yere `StreamingProcessSpawning` canlı kaydı (`LiveStreamingProcess()`) eklenir.

- [ ] **Step 2: Canlı + fake kaydı ekle**

Registry/composition root'ta `ProcessRunning` kaydının hemen yanına:
```swift
// stream-json chat lane süreç sağlayıcısı (Faz 1; Faz 2 tüketir).
let streamingProcess: any StreamingProcessSpawning = LiveStreamingProcess()
```
Fake registry varsa aynı anahtara `FakeStreamingProcess()` kaydedilir.

- [ ] **Step 3: Bağlayıcı doc güncellemesi**

`docs/design/00-architecture.md`'ye yeni alt bölüm ekle (mevcut terminal alt-sistem bölümünün yanına): **"Chat lane (stream-json)"** — chat oturumları PTY yerine `claude --output-format stream-json` pipe child'ı çalıştırır; `SessionKind = terminal | chat`; chat lane Ek A'daki PTY→UI backpressure/replay gereksinimlerinden muaftır (pipe I/O, TUI yok); veri akışı `StreamingProcess → StreamJsonEvent → ChatJournal`. `docs/decisions.md`'ye sıradaki numarayla karar: "Yol B Faz 1 — stream-json chat lane eklendi; terminal-tek-kaynak yalnız terminal oturumları için geçerli; chat oturumları ayrı `ChatSessionMeta`, transcript'te kalıcı."

- [ ] **Step 4: Sweep**

Run: `cd LumiPackages && swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3 && swift build -c release --product Lumi 2>&1 | tail -2`
Expected: build OK, tüm testler PASS, release OK. (Disk-I/O hatasında `--scratch-path /tmp/lumi-scratch` ekle.)

- [ ] **Step 5: Commit**

```bash
git add docs/design/00-architecture.md docs/decisions.md LumiPackages/Sources LumiPackages/Tests/LumiTestSupport
git commit -m "feat(chat): stream-json chat lane DI kaydı + bağlayıcı mimari/karar güncellemesi (Faz 1 kapanış)"
```
