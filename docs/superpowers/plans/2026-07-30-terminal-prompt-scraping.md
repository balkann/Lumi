# Terminal-ekran Prompt Dedektörü Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terminalde render edilen interaktif seçim promptlarını (izin diyaloğu, plan-onay, AskUserQuestion menüsü) ekran-buffer'ından okuyup telefonda gerçek soru kartı olarak göstermek.

**Architecture:** Saf bir parser (`TerminalPromptScanner`) görünür alt satırları `DetectedPrompt`'a çevirir. `TerminalPipeline` çıktı sessizliğinde (350 ms debounce) MainActor'da ekranı yakalar, tarar, son sonuçla diff'leyip değişince `TerminalEvent.promptChanged` yayar. `RemoteService` bunu mevcut mobil `question` olayına map eder (ekran-scrape birincil; transcript AskUserQuestion fallback). Mobil zaten `question` kartını gösteriyor; sadece "boş = temizle" ve snapshot `activePrompt` eklenir.

**Tech Stack:** Swift 6 (strict concurrency), SwiftTerm, XCTest, SPM. Combine yok, manuel DI.

## Global Constraints

- macOS 14+; Swift 6 strict concurrency; Combine kullanılmaz.
- Servis→store `AsyncStream`, store→UI `@Observable`.
- SwiftTerm emülatörüne yalnız `@MainActor`'da erişilir (buffer okuma dahil).
- Salt-okuma: PTY→UI ack/backpressure yoluna yeni yazma/inject yapılmaz (spec/00 §4).
- Persistence formatları (`~/.lumi`, protokol) geriye uyumlu kalır; bilinmeyen alan akışı kırmaz.
- LumiPackages testleri: `cd LumiPackages && swift test`. Mobil: `cd LumiMobile/LumiMobileKit && swift test`.
- Türkçe UI metinleri korunur.
- Her task sonunda commit.

---

### Task 1: `DetectedPrompt` modeli + `TerminalPromptScanner` parser

Saf, bağımsız test edilebilir çekirdek. Ekrandaki interaktif promptu düz satırlardan çıkarır.

**Files:**
- Create: `LumiPackages/Sources/LumiKit/Models/DetectedPrompt.swift`
- Create: `LumiPackages/Sources/LumiTerminal/Parsing/TerminalPromptScanner.swift`
- Test: `LumiPackages/Tests/LumiTerminalTests/TerminalPromptScannerTests.swift`

**Interfaces:**
- Produces: `public struct DetectedPrompt: Sendable, Equatable` with `enum Kind: String { case permission, question, generic }`, `let kind: Kind`, `let questionText: String?`, `let options: [String]`.
- Produces: `enum TerminalPromptScanner { static func scan(lines: [String]) -> DetectedPrompt? }` (internal to LumiTerminal).

- [ ] **Step 1: Write `DetectedPrompt` model**

Create `LumiPackages/Sources/LumiKit/Models/DetectedPrompt.swift`:

```swift
import Foundation

/// Terminal ekranından okunan interaktif seçim promptu (spec 4).
/// `kind` best-effort'tur; yalnız kart başlığını etkiler, davranışı değil.
public struct DetectedPrompt: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case permission   // izin/onay diyaloğu ("don't ask again" / proceed)
        case question     // AskUserQuestion menüsü (to select / to navigate)
        case generic
    }

    public let kind: Kind
    /// Seçeneklerin hemen üstündeki soru/başlık bloğu; yoksa nil.
    public let questionText: String?
    /// Ekranda göründüğü sırayla seçenek etiketleri.
    public let options: [String]

    public init(kind: Kind, questionText: String?, options: [String]) {
        self.kind = kind
        self.questionText = questionText
        self.options = options
    }
}
```

- [ ] **Step 2: Write the failing scanner tests**

Create `LumiPackages/Tests/LumiTerminalTests/TerminalPromptScannerTests.swift`:

```swift
import XCTest
import LumiKit
@testable import LumiTerminal

final class TerminalPromptScannerTests: XCTestCase {
    func testAskUserQuestionMenu() {
        let lines = [
            "",
            "□ Görsel adım",
            "",
            "Version review ekranı şu an sade baseline. Nasıl ilerleyelim?",
            "",
            "❯ 1. Önce frontend-design polish, sonra localhost onay",
            "  2. Önce baseline'ı localhost'ta göreyim",
            "  3. Polish'i atla, baseline'ı gönderelim",
            "  4. Type something.",
            "  5. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .question)
        XCTAssertEqual(p?.questionText,
                       "Version review ekranı şu an sade baseline. Nasıl ilerleyelim?")
        XCTAssertEqual(p?.options, [
            "Önce frontend-design polish, sonra localhost onay",
            "Önce baseline'ı localhost'ta göreyim",
            "Polish'i atla, baseline'ı gönderelim",
            "Type something.",
            "Chat about this",
        ])
    }

    func testSkillPermissionWithWrappedOption() {
        let lines = [
            "  Design guidance and fundamentals for Artifacts.",
            "",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. Yes, and don't ask again for artifact-design in",
            "     /Users/balkan/Desktop/side-projects/unco-forge",
            "  3. No",
            "",
            "Esc to cancel · Tab to amend",
        ]
        let p = TerminalPromptScanner.scan(lines: lines)
        XCTAssertEqual(p?.kind, .permission)
        XCTAssertEqual(p?.questionText, "Do you want to proceed?")
        XCTAssertEqual(p?.options, [
            "Yes",
            "Yes, and don't ask again for artifact-design in /Users/balkan/Desktop/side-projects/unco-forge",
            "No",
        ])
    }

    func testNormalOutputHasNoPrompt() {
        let lines = ["$ ls", "file1.txt  file2.txt", "$ "]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }

    func testFooterWithoutOptionsIsNil() {
        let lines = ["Loading…", "Enter to select · ↑/↓ to navigate"]
        XCTAssertNil(TerminalPromptScanner.scan(lines: lines))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd LumiPackages && swift test --filter TerminalPromptScannerTests`
Expected: FAIL — "cannot find 'TerminalPromptScanner' in scope".

- [ ] **Step 4: Write the scanner implementation**

Create `LumiPackages/Sources/LumiTerminal/Parsing/TerminalPromptScanner.swift`:

```swift
import Foundation
import LumiKit

/// Görünür terminal alt-satırlarını interaktif prompt'a çeviren saf parser (spec 4 §1).
/// Emülatörden bağımsız: girdi `translateToString(trimRight:)` ile alınmış düz satırlardır.
enum TerminalPromptScanner {
    private static let footerNeedles = [
        "to select", "to navigate", "to proceed", "esc to cancel", "tab to amend", "↑/↓",
    ]
    private static let markerChars: Set<Character> = ["❯", "›", "▸", "*", ">"]
    private static let boxChars: Set<Character> = Set(
        "─│┌┐└┘├┤┬┴┼╭╮╯╰═║╔╗╚╝▏▕□▢☐")

    static func scan(lines: [String]) -> DetectedPrompt? {
        // (1) Footer imzası zorunlu — normal çıktı/yarı-render elenir.
        guard lines.contains(where: isFooter) else { return nil }

        // (2) İlk numaralı seçenek satırını bul.
        guard let firstOptIdx = lines.firstIndex(where: { parseOption($0) != nil }) else {
            return nil
        }

        // (3) Seçenek bloğu: numaralı satırlar + sarılan devam satırları.
        var options: [String] = []
        var idx = firstOptIdx
        while idx < lines.count {
            let raw = lines[idx]
            if isFooter(raw) { break }
            if let opt = parseOption(raw) {
                options.append(opt)
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }               // blok bitti
                if !options.isEmpty { options[options.count - 1] += " " + trimmed } // sarılan seçenek
            }
            idx += 1
        }
        guard !options.isEmpty else { return nil }

        // (4) Soru metni: seçeneklerin üstündeki en yakın boş-olmayan blok.
        var i = firstOptIdx - 1
        while i >= 0, cleanLine(lines[i]).isEmpty { i -= 1 }  // aradaki boşlukları atla
        var qLines: [String] = []
        while i >= 0 {
            let c = cleanLine(lines[i])
            if c.isEmpty || isFooter(lines[i]) { break }
            qLines.insert(c, at: 0)
            i -= 1
        }
        let questionText = qLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // (5) Kind (best-effort): options/soru "don't ask again"/"proceed" → izin;
        //     footer "to select"/"to navigate" → soru; aksi generic.
        let hay = (questionText + " " + options.joined(separator: " ")).lowercased()
        let footerText = lines.filter(isFooter).joined(separator: " ").lowercased()
        let kind: DetectedPrompt.Kind
        if hay.contains("don't ask again") || hay.contains("do you want to proceed") {
            kind = .permission
        } else if footerText.contains("to select") || footerText.contains("to navigate") {
            kind = .question
        } else {
            kind = .generic
        }

        return DetectedPrompt(kind: kind,
                              questionText: questionText.isEmpty ? nil : questionText,
                              options: options)
    }

    private static func isFooter(_ line: String) -> Bool {
        let l = line.lowercased()
        return footerNeedles.contains { l.contains($0) }
    }

    /// "❯ 1. Yes" / "  2. …" → seçenek metni; değilse nil.
    private static func parseOption(_ line: String) -> String? {
        var s = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        if let f = s.first, markerChars.contains(f) {
            s = s.dropFirst().drop(while: { $0 == " " })
        }
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        s = s.dropFirst(digits.count)
        guard s.first == "." else { return nil }
        s = s.dropFirst()
        guard s.first == " " || s.isEmpty else { return nil }  // "1.5" gibi ondalıkları ele
        let text = s.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Kutu-çizgi/checkbox karakterlerini söküp trim'ler (soru metni için).
    private static func cleanLine(_ line: String) -> String {
        String(line.filter { !boxChars.contains($0) }).trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd LumiPackages && swift test --filter TerminalPromptScannerTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/DetectedPrompt.swift \
        LumiPackages/Sources/LumiTerminal/Parsing/TerminalPromptScanner.swift \
        LumiPackages/Tests/LumiTerminalTests/TerminalPromptScannerTests.swift
git commit -m "feat(terminal): ekran prompt parser (TerminalPromptScanner + DetectedPrompt)"
```

---

### Task 2: `PromptScanTimer` + pipeline'a bağlama

Çıktı sessizliğinde tarama tetikleyicisi. Mevcut `CodexSilenceTimer` desenini birebir izler.

**Files:**
- Create: `LumiPackages/Sources/LumiTerminal/Status/PromptScanTimer.swift`
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalPipeline.swift`
- Test: `LumiPackages/Tests/LumiTerminalTests/PromptScanTimerTests.swift`

**Interfaces:**
- Consumes: `OneShotScheduling` (mevcut), `DispatchOneShotScheduler` (mevcut), `TestScheduler` (mevcut, `OutputCoalescerTests.swift` içinde tanımlı — aynı test target'ında erişilebilir).
- Produces: `final class PromptScanTimer` with `static let defaultInterval: TimeInterval`, `var onDue: (() -> Void)?`, `func touch()`, `func cancel()`.
- Produces: `TerminalPipeline.onPromptScanDue: (@Sendable () -> Void)?` — io queue'da çağrılır.

- [ ] **Step 1: Write the failing timer test**

Create `LumiPackages/Tests/LumiTerminalTests/PromptScanTimerTests.swift`:

```swift
import XCTest
@testable import LumiTerminal

final class PromptScanTimerTests: XCTestCase {
    func testTouchSchedulesWithDefaultInterval() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        timer.touch()
        XCTAssertEqual(scheduler.lastInterval, PromptScanTimer.defaultInterval)
    }

    func testFireInvokesOnDue() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        var fired = 0
        timer.onDue = { fired += 1 }
        timer.touch()
        scheduler.fire()
        XCTAssertEqual(fired, 1)
    }

    func testCancelPreventsFire() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        var fired = 0
        timer.onDue = { fired += 1 }
        timer.touch()
        timer.cancel()
        scheduler.fire()
        XCTAssertEqual(fired, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --filter PromptScanTimerTests`
Expected: FAIL — "cannot find 'PromptScanTimer' in scope".

- [ ] **Step 3: Write `PromptScanTimer`**

Create `LumiPackages/Sources/LumiTerminal/Status/PromptScanTimer.swift`:

```swift
import Foundation

/// Ekran-scrape tetikleyicisi: çıktı `interval` boyunca durunca onDue (spec 4 §2/K2).
/// CodexSilenceTimer'ın kardeşi ama daha kısa; provider'dan bağımsız her çıktıda touch edilir.
final class PromptScanTimer {
    static let defaultInterval: TimeInterval = 0.35

    var onDue: (() -> Void)?
    private let scheduler: OneShotScheduling
    private let interval: TimeInterval

    init(scheduler: OneShotScheduling, interval: TimeInterval = PromptScanTimer.defaultInterval) {
        self.scheduler = scheduler
        self.interval = interval
    }

    func touch() {
        scheduler.schedule(after: interval) { [weak self] in
            self?.onDue?()
        }
    }

    func cancel() {
        scheduler.cancel()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --filter PromptScanTimerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire the timer into `TerminalPipeline`**

In `LumiPackages/Sources/LumiTerminal/Session/TerminalPipeline.swift`:

Add stored property after `private let silenceTimer: CodexSilenceTimer` (line 19):

```swift
    private let promptScanTimer: PromptScanTimer
```

Add callback declaration after `var onOutputText: (@Sendable (String) -> Void)?` (line 28):

```swift
    /// Çıktı sessizliğinde ekran-scrape tetikler (io queue'da çağrılır; tüketici main'e sıçrar).
    var onPromptScanDue: (@Sendable () -> Void)?
```

In `init`, after `self.silenceTimer = CodexSilenceTimer(...)` (line 33):

```swift
        self.promptScanTimer = PromptScanTimer(scheduler: DispatchOneShotScheduler(queue: queue))
```

In `init`, after the `decisionTracker.onChange = { ... }` block (line 44-46):

```swift
        promptScanTimer.onDue = { [weak self] in
            self?.onPromptScanDue?()
        }
```

In `processOutput`, inside `if !text.isEmpty { ... }`, right after `onOutputText?(text)` (line 66):

```swift
            promptScanTimer.touch()
```

In `prepareForExit`, after `silenceTimer.cancel()` (line 146):

```swift
        promptScanTimer.cancel()
```

- [ ] **Step 6: Run the full LumiTerminal suite to verify no regressions**

Run: `cd LumiPackages && swift test --filter LumiTerminalTests`
Expected: PASS (all existing + new).

- [ ] **Step 7: Commit**

```bash
git add LumiPackages/Sources/LumiTerminal/Status/PromptScanTimer.swift \
        LumiPackages/Sources/LumiTerminal/Session/TerminalPipeline.swift \
        LumiPackages/Tests/LumiTerminalTests/PromptScanTimerTests.swift
git commit -m "feat(terminal): PromptScanTimer + pipeline quiescence tetikleyici"
```

---

### Task 3: `TerminalEvent.promptChanged` + session yakalama/tarama/diff + manager yayını

Ekran yakalama (MainActor) → scan → diff → delegate → broadcaster zinciri. Ağırlıklı kablolama; `TerminalPromptScanner` (Task 1) zaten test edildi.

**Files:**
- Modify: `LumiPackages/Sources/LumiKit/Models/TerminalModels.swift:88-97` (TerminalEvent)
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift`
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift:185-217`

**Interfaces:**
- Consumes: `DetectedPrompt` (Task 1), `TerminalPromptScanner.scan(lines:)` (Task 1), `TerminalPipeline.onPromptScanDue` (Task 2).
- Produces: `TerminalEvent.promptChanged(TerminalID, DetectedPrompt?)`.
- Produces: `TerminalSessionDelegate.session(_:didDetectPrompt: DetectedPrompt?)`.

- [ ] **Step 1: Add the `TerminalEvent` case**

In `LumiPackages/Sources/LumiKit/Models/TerminalModels.swift`, in `enum TerminalEvent` after `case awaitingDecisionChanged(TerminalID, Bool)` (line 95):

```swift
    /// Ekranda interaktif prompt belirdi/değişti (nil = kalktı). Ekran-scrape (spec 4).
    case promptChanged(TerminalID, DetectedPrompt?)
```

- [ ] **Step 2: Verify LumiKit still builds**

Run: `cd LumiPackages && swift build`
Expected: builds (DetectedPrompt is Sendable+Equatable → TerminalEvent synthesis OK). If RemoteService switch warns about new case, that is fixed in Task 4.

- [ ] **Step 3: Extend the session delegate protocol**

In `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift`, in `protocol TerminalSessionDelegate` after the `didChangeAwaitingDecision` line (line 9):

```swift
    func session(_ session: TerminalSession, didDetectPrompt prompt: DetectedPrompt?)
```

- [ ] **Step 4: Add capture + scan + diff to `TerminalSession`**

In `TerminalSession.swift`, add a stored property after `private var pendingResize: DispatchWorkItem?` (line 37):

```swift
    private var lastPrompt: DetectedPrompt?
```

In `wirePipeline()`, after the `pipeline.onDisplayTitle = { ... }` block (line 107-109):

```swift
        pipeline.onPromptScanDue = { [weak self] in
            hopToMain { self?.runPromptScan() }
        }
```

Add these methods after `applyAwaitingDecision(_:)` (line 141):

```swift
    /// Çıktı sessizliğinde (io queue debounce) main'de tetiklenir: alt satırları
    /// tarar, son sonuçtan farklıysa delegate'e bildirir. Salt-okuma (spec 4 §K4).
    private func runPromptScan() {
        guard !isTerminated else { return }
        let prompt = TerminalPromptScanner.scan(lines: captureBottomLines())
        guard prompt != lastPrompt else { return }
        lastPrompt = prompt
        delegate?.session(self, didDetectPrompt: prompt)
    }

    /// Emülatörün görünür alt `n` satırını düz metin olarak okur (MainActor).
    private func captureBottomLines(_ n: Int = 16) -> [String] {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let start = max(0, rows - n)
        var out: [String] = []
        for row in start..<rows {
            out.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        return out
    }
```

- [ ] **Step 5: Broadcast the event in `TerminalSessionManager`**

In `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift`, in the `extension TerminalSessionManager: TerminalSessionDelegate` block, after the `didChangeAwaitingDecision` method (line 191-194):

```swift
    func session(_ session: TerminalSession, didDetectPrompt prompt: DetectedPrompt?) {
        guard isRegistered(session) else { return }
        broadcaster.send(.promptChanged(session.id, prompt))
    }
```

- [ ] **Step 6: Build the LumiTerminal target**

Run: `cd LumiPackages && swift build --target LumiTerminal`
Expected: builds. (`getLine`/`translateToString` are SwiftTerm public API; `hopToMain` is the existing helper used elsewhere in the file.)

- [ ] **Step 7: Run the LumiTerminal suite**

Run: `cd LumiPackages && swift test --filter LumiTerminalTests`
Expected: PASS (no regressions).

- [ ] **Step 8: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/TerminalModels.swift \
        LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift \
        LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift
git commit -m "feat(terminal): promptChanged event + session ekran yakalama/diff"
```

---

### Task 4: `RemoteService` + `SnapshotBuilder` — mobil `question`'a map + dedup + protokol

`promptChanged` olayını mevcut mobil `question` olayına çevirir; ekran-scrape aktifken transcript AskUserQuestion'ı düşürür; snapshot'a `activePrompt` koyar.

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- Modify: `docs/spec/50-remote-protocol.md`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`, `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: `TerminalEvent.promptChanged` (Task 3), `DetectedPrompt` (Task 1).
- Produces: `SnapshotBuilder.promptEvent(sessionId: String, prompt: DetectedPrompt?) -> [String: Any]`.
- Produces: `SnapshotBuilder.snapshot(..., activePrompts: [TerminalID: DetectedPrompt] = [:])` (yeni opsiyonel parametre).

- [ ] **Step 1: Write the failing SnapshotBuilder test**

In `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift`, add:

```swift
    func testPromptEventCarriesQuestionPayload() {
        let prompt = DetectedPrompt(kind: .permission,
                                    questionText: "Do you want to proceed?",
                                    options: ["Yes", "No"])
        let ev = SnapshotBuilder.promptEvent(sessionId: "s1", prompt: prompt)
        XCTAssertEqual(ev["kind"] as? String, "transcript")
        let item = ev["item"] as? [String: Any]
        XCTAssertEqual(item?["itemType"] as? String, "question")
        let qs = item?["questions"] as? [[String: Any]]
        XCTAssertEqual(qs?.count, 1)
        XCTAssertEqual(qs?.first?["question"] as? String, "Do you want to proceed?")
        XCTAssertEqual(qs?.first?["options"] as? [String], ["Yes", "No"])
    }

    func testPromptEventNilClearsWithEmptyQuestions() {
        let ev = SnapshotBuilder.promptEvent(sessionId: "s1", prompt: nil)
        let item = ev["item"] as? [String: Any]
        XCTAssertEqual((item?["questions"] as? [[String: Any]])?.count, 0)
    }
```

Note: the test uses `import LumiKit` (already present in that test file for `DetectedPrompt`). If not, add `import LumiKit` at the top.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiPackages && swift test --filter SnapshotBuilderTests`
Expected: FAIL — "type 'SnapshotBuilder' has no member 'promptEvent'".

- [ ] **Step 3: Implement `promptEvent` + snapshot `activePrompts` in `SnapshotBuilder`**

In `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`:

Add `activePrompts` param to `snapshot(...)` signature (line 6-11) — add after `awaitingDecision`:

```swift
        awaitingDecision: [TerminalID: Bool] = [:],
        activePrompts: [TerminalID: DetectedPrompt] = [:]
```

In the `sessions` map closure, after `if awaitingDecision[meta.id] == true { entry["awaitingDecision"] = true }` (line 23):

```swift
            if let prompt = activePrompts[meta.id] {
                entry["activePrompt"] = [questionDict(prompt)]
            }
```

Add these helpers inside `enum SnapshotBuilder` (e.g. after `awaitingDecisionEvent`, line 35):

```swift
    static func promptEvent(sessionId: String, prompt: DetectedPrompt?) -> [String: Any] {
        let questions: [[String: Any]] = prompt.map { [questionDict($0)] } ?? []
        return ["kind": "transcript", "sessionId": sessionId,
                "item": ["itemType": "question", "questions": questions]]
    }

    private static func questionDict(_ prompt: DetectedPrompt) -> [String: Any] {
        ["header": kindLabel(prompt.kind),
         "question": prompt.questionText ?? "",
         "options": prompt.options]
    }

    private static func kindLabel(_ kind: DetectedPrompt.Kind) -> String {
        switch kind {
        case .permission: return "İzin isteği"
        case .question: return "Soru"
        case .generic: return ""
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiPackages && swift test --filter SnapshotBuilderTests`
Expected: PASS.

- [ ] **Step 5: Write the failing RemoteService tests**

In `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`:

Add these query helpers inside `private actor FakeConnection` (after `snapshotFirstSessionAwaiting()`, line 91):

```swift
    func promptEvent() -> (sessionId: String, optionCount: Int)? {
        guard let e = sent.first(where: {
            $0.type == "event" && ($0.payload["kind"] as? String) == "transcript"
                && (($0.payload["item"] as? [String: Any])?["itemType"] as? String) == "question"
        }) else { return nil }
        let item = e.payload["item"] as? [String: Any]
        let qs = item?["questions"] as? [[String: Any]]
        return ((e.payload["sessionId"] as? String) ?? "",
                (qs?.first?["options"] as? [String])?.count ?? -1)
    }
    func questionEventCount() -> Int {
        sent.filter {
            $0.type == "event" && ($0.payload["kind"] as? String) == "transcript"
                && (($0.payload["item"] as? [String: Any])?["itemType"] as? String) == "question"
        }.count
    }
    func snapshotFirstSessionHasActivePrompt() -> Bool {
        guard let snap = sent.last(where: { $0.type == "snapshot" }),
              let sessions = snap.payload["sessions"] as? [[String: Any]],
              let first = sessions.first else { return false }
        return first["activePrompt"] != nil
    }
```

Add these test methods at the end of `RemoteServiceTests` (before the closing brace, line 408):

```swift
    func testPromptChangedSendsQuestionEvent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .permission,
                                    questionText: "Do you want to proceed?",
                                    options: ["Yes", "No"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()

        let ev = await connection.promptEvent()
        XCTAssertEqual(ev?.sessionId, meta.id.description)
        XCTAssertEqual(ev?.optionCount, 2)
        service.stop()
    }

    func testScreenPromptSuppressesTranscriptQuestion() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .question, questionText: "Q?", options: ["A", "B"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()
        // transcript AskUserQuestion aynı oturuma gelirse düşürülür
        await service.ingestFeedItemForTest(.question([
            Question(header: "", question: "Q?", options: ["A", "B"])
        ]), sessionId: meta.id)
        await drain()

        let count = await connection.questionEventCount()
        XCTAssertEqual(count, 1) // yalnız ekran-scrape olayı
        service.stop()
    }

    func testSnapshotCarriesActivePrompt() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .question, questionText: "Q?", options: ["A"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()

        let has = await connection.snapshotFirstSessionHasActivePrompt()
        XCTAssertTrue(has)
        service.stop()
    }
```

Note: `testScreenPromptSuppressesTranscriptQuestion` needs a test seam because `handleFeedItem` is private and normally fed by the file watcher. Add this seam to `RemoteService` in Step 6.

- [ ] **Step 6: Run tests to verify they fail**

Run: `cd LumiPackages && swift test --filter RemoteServiceTests`
Expected: FAIL — `.promptChanged` not handled / `ingestFeedItemForTest` missing.

- [ ] **Step 7: Implement in `RemoteService`**

In `LumiPackages/Sources/LumiRemote/RemoteService.swift`:

Add stored property after `private var awaitingDecision: [TerminalID: Bool] = [:]` (line 26):

```swift
    private var screenPrompt: [TerminalID: DetectedPrompt] = [:]
```

In `handleTerminalEvent`, add a case before `default:` (line 155):

```swift
        case .promptChanged(let id, let prompt):
            screenPrompt[id] = prompt   // nil → anahtar silinir
            guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
            await connection.send(type: "event",
                payload: SnapshotBuilder.promptEvent(sessionId: meta.id.description, prompt: prompt))
```

In `handleFeedItem`, change the `.question` case to drop transcript questions while a screen prompt is active (line 218-219):

```swift
        case .question(let questions):
            // Ekran-scrape birincil (spec 4 §K1): ekranda aktif prompt varken transcript sorusu düşürülür.
            if screenPrompt[sessionId] != nil { return }
            lastSummary[sessionId] = questions.first?.question
```

In `stopWatcher`, after `awaitingDecision[id] = nil` (line 184):

```swift
        screenPrompt[id] = nil
```

In `sendSnapshot`, pass `activePrompts` (line 233-235):

```swift
        let payload = SnapshotBuilder.snapshot(
            terminals: terminal.terminals, repos: repoList, personas: personaList,
            awaitingDecision: awaitingDecision, activePrompts: screenPrompt)
```

Add the test seam at the end of the class (after `setState`, before the final closing brace, line 249):

```swift
    /// Test seam: watcher olmadan feed öğesi enjekte eder (dedup davranışını doğrular).
    func ingestFeedItemForTest(_ item: FeedItem, sessionId: TerminalID) async {
        await handleFeedItem(item, sessionId: sessionId)
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd LumiPackages && swift test --filter RemoteServiceTests`
Expected: PASS (existing + 3 new).

- [ ] **Step 9: Document the protocol change**

In `docs/spec/50-remote-protocol.md`, add to the `transcript`/`question` item section (find the `itemType: "question"` description) the semantics:

```markdown
- `question` item'ının `questions` alanı **boş dizi (`[]`)** ise: o oturumun açık
  prompt kartı **temizlenir** (ekran-scrape prompt kalktığında gönderilir; spec 4).
  Boş olmayan dizi → kart gösterilir. Transcript-türevli AskUserQuestion asla boş
  göndermez; boş yalnız ekran-scrape temizliğinden gelir.
```

And to the snapshot `sessions[]` shape description, add:

```markdown
- `activePrompt` (opsiyonel): `[{header, question, options}]` — o an ekranda duran
  interaktif prompt (izin/soru). Yoksa alan gelmez. Reconnect'te telefon kartı yeniden kurar.
```

- [ ] **Step 10: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift \
        LumiPackages/Sources/LumiRemote/RemoteService.swift \
        LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift \
        LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift \
        docs/spec/50-remote-protocol.md
git commit -m "feat(remote): ekran promptunu mobil question'a map + transcript dedup + snapshot activePrompt"
```

---

### Task 5: Mobil — `activePrompt` decode + boş-question temizleme + snapshot doldurma

Mobil görüntüleme yolu (`activeQuestions` → `QuestionCardView`) zaten var. Sadece "boş = temizle" ve snapshot `activePrompt` eklenir.

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift:31-65`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift:141-153, 346-363`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`, `.../ProtocolTests.swift`

**Interfaces:**
- Consumes: wire format from Task 4 (`transcript/question` with empty array = clear; snapshot `sessions[].activePrompt`).
- Produces: `SessionSummary.activePrompt: [Question]?`.

- [ ] **Step 1: Write the failing tests**

In `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`, add (this file's `makeModel(paired:)` returns a tuple `(AppModel, FakeRelayClient, InMemorySecureStore)` — destructure it like the other tests; the class is `@MainActor` so no `async` needed here):

```swift
    func testEmptyQuestionClearsCard() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(
            sessions: [SessionSummary(id: "s1", repoPath: "/r", repoName: "r",
                                      status: .waitingUnseen)],
            repos: [], personas: [])))
        // önce dolu soru → kart var
        model.handle(.event(.transcript(sessionId: "s1",
            item: .question([Question(header: "", question: "Q?", options: ["A", "B"])]))))
        XCTAssertNotNil(model.questionCard(for: "s1")?.questions)
        // boş soru → kart kalkar
        model.handle(.event(.transcript(sessionId: "s1", item: .question([]))))
        XCTAssertNil(model.questionCard(for: "s1")?.questions)
    }

    func testSnapshotActivePromptPopulatesCard() {
        let (model, _, _) = makeModel()
        let summary = SessionSummary(id: "s1", repoPath: "/r", repoName: "r",
                                     status: .waitingUnseen,
                                     activePrompt: [Question(header: "İzin isteği",
                                                             question: "Do you want to proceed?",
                                                             options: ["Yes", "No"])])
        model.handle(.snapshot(Snapshot(sessions: [summary], repos: [], personas: [])))
        XCTAssertEqual(model.questionCard(for: "s1")?.questions?.first?.options, ["Yes", "No"])
    }
```

In `.../ProtocolTests.swift`, add a decode test for the new snapshot field:

```swift
    func testSnapshotDecodesActivePrompt() {
        let json = """
        {"v":1,"type":"snapshot","payload":{"sessions":[
          {"id":"s1","repoPath":"/r","repoName":"r","status":"waiting-unseen",
           "activePrompt":[{"header":"İzin isteği","question":"Do you want to proceed?","options":["Yes","No"]}]}
        ],"repos":[],"personas":[]}}
        """
        guard case .snapshot(let snap)? = PhoneProtocol.decodeServerMessage(json) else {
            return XCTFail("snapshot decode edilemedi")
        }
        XCTAssertEqual(snap.sessions.first?.activePrompt?.first?.options, ["Yes", "No"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `SessionSummary` has no `activePrompt`.

- [ ] **Step 3: Add `activePrompt` to `SessionSummary`**

In `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`, in `struct SessionSummary`:

Add stored property after `public let awaitingDecision: Bool` (line 37):

```swift
    public let activePrompt: [Question]?
```

Update `init` signature — add param after `awaitingDecision: Bool = false` (line 41) and assignment:

```swift
                awaitingDecision: Bool = false,
                activePrompt: [Question]? = nil) {
```

Add after `self.awaitingDecision = awaitingDecision` (line 47):

```swift
        self.activePrompt = activePrompt
```

Add `activePrompt` to `CodingKeys` (line 51):

```swift
        case id, repoPath, repoName, status, title, awaitingDecision, activePrompt
```

In `init(from:)`, add to the `self.init(...)` call after the `awaitingDecision:` line (line 62):

```swift
            awaitingDecision: try c.decodeIfPresent(Bool.self, forKey: .awaitingDecision) ?? false,
            activePrompt: try c.decodeIfPresent([Question].self, forKey: .activePrompt)
```

- [ ] **Step 4: Handle empty question as clear + snapshot population in `AppModel`**

In `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`:

Change the `.question` case in the transcript handler (line 144-145):

```swift
            case .question(let questions):
                // Boş dizi = ekran-scrape prompt kalktı → kartı temizle (spec 4).
                activeQuestions[sessionId] = questions.isEmpty ? nil : questions
```

In `apply(_ snapshot:)`, after the `for s in snapshot.sessions where !s.awaitingDecision { ... }` block (line 360-362):

```swift
        // Ekran-scrape aktif promptu snapshot'tan geri kur (reconnect).
        for s in snapshot.sessions {
            if let prompt = s.activePrompt, !prompt.isEmpty {
                activeQuestions[s.id] = prompt
            }
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS (existing + new).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift \
        LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift \
        LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "feat(mobile): activePrompt decode + boş-question temizleme + snapshot doldurma"
```

---

### Final: full suite + manual verification

- [ ] **Step 1: Run all package tests**

Run: `cd LumiPackages && swift test` — Expected: all PASS.
Run: `cd LumiMobile/LumiMobileKit && swift test` — Expected: all PASS.

- [ ] **Step 2: Build the app**

Run: `cd LumiPackages && swift build` — Expected: builds.

- [ ] **Step 3: Manual end-to-end (real device)**

1. `cd LumiPackages && swift run Lumi`; telefonu eşle (remote enabled).
2. Bir oturumda Claude Code'a bir skill/tool izin promptu ("Use skill …? 1.Yes 2.Yes-don't-ask 3.No") çıkart.
3. Telefonda **gerçek etiketli** kart görünmeli (Yes / Yes-don't-ask / No + soru metni), jenerik "girdi bekliyor" değil.
4. AskUserQuestion menüsü ("Enter to select") çıkart → telefonda tam şıklar görünmeli.
5. Telefondan cevapla → Mac ilerlemeli, kart kalkmalı.
6. Prompt varken telefonu kapatıp yeniden bağlan → kart snapshot'tan geri gelmeli.

---

## Self-Review Notları

- **Spec kapsamı:** Parser (T1), tetikleme (T2), event+session+manager (T3), remote map+dedup+snapshot+protokol (T4), mobil decode+temizleme (T5) — spec'in 5 bileşeni birebir karşılanıyor. Cevap yolu spec'te "değişmez" — plan da dokunmuyor. ✓
- **Tip tutarlılığı:** `DetectedPrompt` (LumiKit) T1'de tanımlı; T3 `TerminalEvent.promptChanged`, T4 `promptEvent`/`activePrompts`, T5 `[Question]` payload'ı aynı şekli kullanıyor. ✓
- **Bilinçli kısıt:** T2 pipeline zamanlayıcı entegrasyonu deterministik unit-test edilemiyor (dahili scheduler enjekte edilmiyor); `PromptScanTimer` izole test + build + manuel ile doğrulanıyor. T3 session yakalama/diff SwiftTerm+MainActor gerektirdiğinden build + manuel + RemoteService testleri (FakeTerminal.pushEvent) ile kapsanıyor — mevcut `awaitingDecision` kablolamasının test deseniyle aynı.
