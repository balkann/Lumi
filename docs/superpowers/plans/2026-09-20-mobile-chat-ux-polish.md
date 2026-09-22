# Mobile Chat UX Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add orca-parity chat UX to Lumi iOS — a scroll-to-bottom FAB with gated autoscroll, and an inline copy icon on assistant messages.

**Architecture:** Two pure, UIKit-free helpers land in `LumiMobileKit` (unit-tested on the Mac host). The SwiftUI views (`MobileChatView`, `MobileChatMessageView`) consume them: `MobileChatView` reads the bottom-sentinel position via a `PreferenceKey` to decide at-bottom, gates its autoscroll, and overlays the FAB; `MobileChatMessageView` shows the copy icon and writes to `UIPasteboard`.

**Tech Stack:** Swift 6, SwiftUI, iOS 17 (min), SPM (`LumiMobileKit`), XCTest.

## Global Constraints

- iOS deployment target: **17.0** — `onScrollGeometryChange` (iOS 18) is FORBIDDEN; use iOS 17-safe `GeometryReader` + `PreferenceKey`.
- `LumiMobileKit` MUST NOT import UIKit/VisionKit (it builds on the Mac host without a simulator). `UIPasteboard` and all UIKit usage stay in the App target (`LumiMobile/App/`).
- Pure logic goes in `LumiMobileKit` with XCTest coverage; SwiftUI/geometry glue is not unit-tested.
- Types (from `LumiWire`): `ChatRole.user`/`.assistant`; `ChatBlock.text(String, presentation: String?)`, `.toolCall(name:inputPreview:state:)`, `.toolResult(output:isError:)`; `ChatMessage(id:role:blocks:timestampMs:turnId:)`. `FoldedTurn` (from `LumiMobileKit`) has `.id`, `.message: ChatMessage`, `.toolActivity: [ChatMessage]`.
- FAB threshold: **80** (orca `distanceFromBottom < 80` parity). Copy confirmation: **0.7s** icon swap.
- Scope excludes: load-earlier/pagination, copy on user bubbles, FAB unread badge.
- Tests run: `cd LumiMobile/LumiMobileKit && swift test`.

---

### Task 1: `chatAtBottom` helper

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatScrollGate.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatScrollGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `func chatAtBottom(sentinelMinY: CGFloat, viewportHeight: CGFloat, threshold: CGFloat = 80) -> Bool`

The bottom sentinel's `minY`, measured in the ScrollView's named coordinate space, equals ~`viewportHeight` when the content is scrolled to the bottom and grows larger as the user scrolls up. At-bottom means the sentinel sits within `threshold` points of (or above) the viewport's bottom edge.

- [ ] **Step 1: Write the failing test**

```swift
// LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatScrollGateTests.swift
import XCTest
@testable import LumiMobileKit

final class ChatScrollGateTests: XCTestCase {
    func testSentinelAtViewportBottomIsAtBottom() {
        XCTAssertTrue(chatAtBottom(sentinelMinY: 600, viewportHeight: 600))
    }

    func testSentinelExactlyAtThresholdIsAtBottom() {
        // 600 + 80 == 680 → still at bottom (inclusive).
        XCTAssertTrue(chatAtBottom(sentinelMinY: 680, viewportHeight: 600))
    }

    func testSentinelJustBeyondThresholdIsNotAtBottom() {
        XCTAssertFalse(chatAtBottom(sentinelMinY: 681, viewportHeight: 600))
    }

    func testFarScrolledUpIsNotAtBottom() {
        XCTAssertFalse(chatAtBottom(sentinelMinY: 1200, viewportHeight: 600))
    }

    func testShortContentThatFitsIsAtBottom() {
        // Content shorter than the viewport → sentinel above the fold → at bottom.
        XCTAssertTrue(chatAtBottom(sentinelMinY: 200, viewportHeight: 600))
    }

    func testCustomThreshold() {
        XCTAssertFalse(chatAtBottom(sentinelMinY: 650, viewportHeight: 600, threshold: 40))
        XCTAssertTrue(chatAtBottom(sentinelMinY: 640, viewportHeight: 600, threshold: 40))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatScrollGateTests`
Expected: FAIL — `cannot find 'chatAtBottom' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatScrollGate.swift
import CoreGraphics

/// Decides whether the chat list is scrolled to (or near) the bottom.
///
/// `sentinelMinY` is the bottom sentinel's `minY` in the ScrollView's named
/// coordinate space: ~`viewportHeight` when pinned to the bottom, larger when
/// the user has scrolled up. At-bottom means the sentinel is within `threshold`
/// points of the viewport's bottom edge (or above it, when content fits).
/// Threshold defaults to 80 (orca `distanceFromBottom < 80` parity).
public func chatAtBottom(sentinelMinY: CGFloat, viewportHeight: CGFloat, threshold: CGFloat = 80) -> Bool {
    sentinelMinY <= viewportHeight + threshold
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatScrollGateTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatScrollGate.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatScrollGateTests.swift
git commit -m "feat(mobile): chatAtBottom scroll-gate helper + tests"
```

---

### Task 2: `chatCopyText` helper

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatCopy.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatCopyTests.swift`

**Interfaces:**
- Consumes: `FoldedTurn` (LumiMobileKit), `ChatBlock`/`ChatMessage`/`ChatRole` (LumiWire).
- Produces: `func chatCopyText(_ turn: FoldedTurn) -> String?`

Extracts the turn owner's prose: join `.text` blocks with newlines, skip tool blocks, return `nil` when the result is effectively empty.

- [ ] **Step 1: Write the failing test**

```swift
// LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatCopyTests.swift
import XCTest
@testable import LumiMobileKit
import LumiWire

final class ChatCopyTests: XCTestCase {
    private func turn(_ role: ChatRole, _ blocks: [ChatBlock]) -> FoldedTurn {
        let m = ChatMessage(id: "m", role: role, blocks: blocks, timestampMs: nil, turnId: nil)
        return FoldedTurn(id: "m", message: m, toolActivity: [])
    }

    func testTextOnly() {
        XCTAssertEqual(chatCopyText(turn(.assistant, [.text("hello", presentation: nil)])), "hello")
    }

    func testMultipleTextBlocksJoinWithNewline() {
        let t = turn(.assistant, [.text("a", presentation: nil), .text("b", presentation: nil)])
        XCTAssertEqual(chatCopyText(t), "a\nb")
    }

    func testMixedTextAndToolKeepsOnlyText() {
        let t = turn(.assistant, [
            .text("hi", presentation: nil),
            .toolCall(name: "Read", inputPreview: "f", state: nil),
            .toolResult(output: "ok", isError: false),
        ])
        XCTAssertEqual(chatCopyText(t), "hi")
    }

    func testToolOnlyReturnsNil() {
        let t = turn(.assistant, [.toolCall(name: "Bash", inputPreview: "ls", state: nil)])
        XCTAssertNil(chatCopyText(t))
    }

    func testEmptyTextReturnsNil() {
        XCTAssertNil(chatCopyText(turn(.assistant, [.text("   ", presentation: nil)])))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatCopyTests`
Expected: FAIL — `cannot find 'chatCopyText' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatCopy.swift
import Foundation
import LumiWire

/// The plain-text prose of a folded turn's owner message: `.text` blocks joined
/// with newlines, tool blocks skipped. `nil` when the result is effectively empty
/// (e.g. a tool-only turn) so callers can hide the copy affordance.
public func chatCopyText(_ turn: FoldedTurn) -> String? {
    let parts = turn.message.blocks.compactMap { block -> String? in
        if case let .text(text, _) = block { return text }
        return nil
    }
    let joined = parts.joined(separator: "\n")
    return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatCopyTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatCopy.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatCopyTests.swift
git commit -m "feat(mobile): chatCopyText turn-prose helper + tests"
```

---

### Task 3: Gated autoscroll + scroll-to-bottom FAB in `MobileChatView`

**Files:**
- Modify: `LumiMobile/App/MobileChatView.swift`

**Interfaces:**
- Consumes: `chatAtBottom(sentinelMinY:viewportHeight:threshold:)` (Task 1).
- Produces: nothing consumed by later tasks.

No unit test (SwiftUI/geometry glue). Verified by the Mac `swift build`/`swift test` of LumiMobileKit staying green and by the iOS build in Task 5.

- [ ] **Step 1: Add at-bottom state and a PreferenceKey**

Add the state property alongside the existing `@State` properties (near line 13):

```swift
    @State private var atBottom = true
```

Add this `PreferenceKey` at file scope (after the imports, before `struct MobileChatView`):

```swift
/// Reports the bottom sentinel's minY within the ScrollView's "chatScroll"
/// coordinate space, so the view can tell whether the list is at the bottom.
private struct BottomSentinelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

- [ ] **Step 2: Measure the sentinel and name the scroll coordinate space**

Replace the sentinel line inside the `LazyVStack` (currently `Color.clear.frame(height: 1).id("bottom")`, ~line 40) with:

```swift
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: BottomSentinelKey.self,
                                            value: g.frame(in: .named("chatScroll")).minY
                                        )
                                    }
                                )
```

On the `ScrollView` (the one opened at ~line 26), add the coordinate space modifier. Attach it right after the `ScrollView { ... }` closing brace, before the existing `.onChange` modifiers:

```swift
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(BottomSentinelKey.self) { minY in
                        atBottom = chatAtBottom(sentinelMinY: minY, viewportHeight: geo.size.height)
                    }
```

- [ ] **Step 3: Gate the two autoscroll handlers**

Replace the two existing `.onChange` bodies (~lines 45-51) so they scroll only when already at the bottom:

```swift
                    .onChange(of: turns.count) { _, _ in
                        if atBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                    // Also scroll to bottom as streaming text grows (during token stream).
                    .onChange(of: model.gatedStreaming[sessionId]) { _, _ in
                        if atBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
```

- [ ] **Step 4: Overlay the FAB**

Add an overlay on the `ScrollView` (after the `.onPreferenceChange` added in Step 2, still inside the `ScrollViewReader` so `proxy` is in scope):

```swift
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button {
                                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                atBottom = true
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.accentColor)
                                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                            .accessibilityLabel("Scroll to latest")
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: atBottom)
```

- [ ] **Step 5: Verify the LumiMobileKit build/tests still pass and the file compiles**

Run: `cd LumiMobile/LumiMobileKit && swift build && swift test`
Expected: build succeeds, all tests PASS (existing + Task 1/2).

(Full iOS compile of the App target happens in Task 5.)

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/App/MobileChatView.swift
git commit -m "feat(mobile): gated autoscroll + scroll-to-bottom FAB in chat"
```

---

### Task 4: Inline copy icon in `MobileChatMessageView`

**Files:**
- Modify: `LumiMobile/App/MobileChatMessageView.swift`

**Interfaces:**
- Consumes: `chatCopyText(_:)` (Task 2).
- Produces: nothing consumed by later tasks.

No unit test (SwiftUI glue). Verified by the iOS build in Task 5.

- [ ] **Step 1: Import UIKit and add copied state**

At the top of the file, add `import UIKit` (after `import SwiftUI`). Inside `struct MobileChatMessageView`, add:

```swift
    @State private var copied = false
```

- [ ] **Step 2: Add the copy control to assistant turns**

In `body`, inside the outer `VStack` (before the `ForEach` over blocks, ~line 12), add the copy row for assistant turns only:

```swift
            if turn.message.role == .assistant, let text = chatCopyText(turn) {
                HStack {
                    Spacer()
                    Button {
                        performCopy(text)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy message")
                }
            }
```

- [ ] **Step 3: Add the copy action**

Add this method inside `struct MobileChatMessageView` (e.g. after `body`, before `blockView`):

```swift
    private func performCopy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        // Revert the confirmation checkmark after a short beat (orca 700ms).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { copied = false }
    }
```

- [ ] **Step 4: Verify LumiMobileKit still green**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS (App target compiles in Task 5).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/App/MobileChatMessageView.swift
git commit -m "feat(mobile): inline copy icon on assistant chat messages"
```

---

### Task 5: Mac + iOS build verification

**Files:** none (verification only).

**Interfaces:** consumes all prior tasks.

- [ ] **Step 1: Mac — LumiMobileKit full build + test**

Run: `cd LumiMobile/LumiMobileKit && swift build && swift test`
Expected: build succeeds; all tests PASS (including `ChatScrollGateTests`, `ChatCopyTests`).

- [ ] **Step 2: iOS — regenerate project and build the app**

All new files live in the `LumiMobileKit` SPM package (auto-included); only existing App files were modified, so the `.xcodeproj` structure is unchanged. Regenerate anyway to be safe, then build for the simulator.

Run:
```bash
cd LumiMobile && xcodegen generate
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'generic/platform=iOS Simulator' build | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit any regenerated project changes (if the generated project is tracked)**

```bash
git add -A && git commit -m "chore(mobile): regenerate project for chat UX polish" || echo "nothing to commit"
```

## Self-Review

**Spec coverage:**
- Feature A gated autoscroll + FAB → Task 3 (helper: Task 1). ✔
- Feature B inline copy icon + 0.7s confirmation → Task 4 (helper: Task 2). ✔
- Pure helpers tested in LumiMobileKit → Tasks 1, 2. ✔
- iOS 17-safe detection (PreferenceKey, no onScrollGeometryChange) → Task 3 Steps 1-2. ✔
- LumiMobileKit UIKit-free; UIPasteboard in App target → Task 2 (Foundation only), Task 4 (import UIKit). ✔
- Excluded: load-earlier, user-bubble copy, unread badge → not present. ✔
- Mac + iOS build → Task 5. ✔

**Placeholder scan:** none — every code step shows full code.

**Type consistency:** `chatAtBottom(sentinelMinY:viewportHeight:threshold:)` and `chatCopyText(_:)` are used with identical signatures in Tasks 3/4 as defined in Tasks 1/2. `ChatBlock.text(_, presentation:)`, `.toolCall(name:inputPreview:state:)`, `.toolResult(output:isError:)`, `ChatMessage(id:role:blocks:timestampMs:turnId:)`, `FoldedTurn(id:message:toolActivity:)` match the LumiWire/LumiMobileKit definitions. ✔
