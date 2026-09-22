import XCTest
@testable import LumiMobileKit

/// TerminalFeedBuffer behavior — bug #3 regression lock:
/// chunks are buffered until the view is attached, applied IN ORDER at attach time,
/// scrollback is visible in idle sessions even if no further chunk arrives.
@MainActor
final class TerminalFeedTests: XCTestCase {

    /// Fake feeder that records applied calls.
    final class FakeFeeder: TerminalFeeder {
        enum Call: Equatable {
            case resize(Int, Int)
            case reset
            case feed([UInt8])
        }
        var calls: [Call] = []
        func resize(cols: Int, rows: Int) { calls.append(.resize(cols, rows)) }
        func reset() { calls.append(.reset) }
        func feed(bytes: [UInt8]) { calls.append(.feed(bytes)) }
    }

    private func chunk(seq: Int, _ text: String, cols: Int? = nil, rows: Int? = nil) -> TerminalChunk {
        TerminalChunk(sessionId: "s", seq: seq, cols: cols, rows: rows, bytes: Data(text.utf8))
    }

    /// Chunks arriving BEFORE attach are not lost; they are applied in order at attach time.
    /// (Idle session: scrollback flows even if no new chunk arrives after attach.)
    func testBuffersUntilAttachThenDrainsInOrder() {
        let buffer = TerminalFeedBuffer()
        buffer.feed(chunk(seq: 0, "SCROLL", cols: 80, rows: 24)) // scrollback
        buffer.feed(chunk(seq: 1, "LIVE"))
        XCTAssertEqual(buffer.pendingCount, 2, "should be buffered when no view is attached")

        let feeder = FakeFeeder()
        buffer.attach(feeder)

        XCTAssertEqual(buffer.pendingCount, 0)
        XCTAssertEqual(feeder.calls, [
            .resize(80, 24),
            .reset,                 // seq==0 → reset
            .feed(Array("SCROLL".utf8)),
            .feed(Array("LIVE".utf8)),
        ])
    }

    /// Chunks arriving AFTER attach are applied immediately (not buffered).
    func testFeedAfterAttachAppliesImmediately() {
        let buffer = TerminalFeedBuffer()
        let feeder = FakeFeeder()
        buffer.attach(feeder)

        buffer.feed(chunk(seq: 1, "A"))
        buffer.feed(chunk(seq: 2, "B"))

        XCTAssertEqual(buffer.pendingCount, 0)
        XCTAssertEqual(feeder.calls, [.feed(Array("A".utf8)), .feed(Array("B".utf8))])
    }

    /// A chunk arriving after detach is buffered again (waits for the next attach).
    func testDetachRebuffers() {
        let buffer = TerminalFeedBuffer()
        let feeder = FakeFeeder()
        buffer.attach(feeder)
        buffer.detach()

        buffer.feed(chunk(seq: 1, "X"))
        XCTAssertEqual(buffer.pendingCount, 1)
        XCTAssertEqual(feeder.calls, [])
    }
}
