import XCTest
@testable import LumiMobileKit

/// TerminalFeedBuffer davranışı — bug #3 regresyon kilidi:
/// view attach edilene dek chunk'lar tamponlanır, attach anında SIRAYLA uygulanır,
/// boşta oturumda (sonraki chunk gelmese de) scrollback görünür.
@MainActor
final class TerminalFeedTests: XCTestCase {

    /// Uygulanan çağrıları kaydeden fake feeder.
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

    /// Attach ÖNCESİ gelen chunk'lar kaybolmaz; attach anında sırayla uygulanır.
    /// (Boşta oturum: attach'tan sonra hiç yeni chunk gelmese de scrollback akar.)
    func testBuffersUntilAttachThenDrainsInOrder() {
        let buffer = TerminalFeedBuffer()
        buffer.feed(chunk(seq: 0, "SCROLL", cols: 80, rows: 24)) // scrollback
        buffer.feed(chunk(seq: 1, "LIVE"))
        XCTAssertEqual(buffer.pendingCount, 2, "view yokken tamponlanmalı")

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

    /// Attach SONRASI gelen chunk'lar anında uygulanır (tamponlanmaz).
    func testFeedAfterAttachAppliesImmediately() {
        let buffer = TerminalFeedBuffer()
        let feeder = FakeFeeder()
        buffer.attach(feeder)

        buffer.feed(chunk(seq: 1, "A"))
        buffer.feed(chunk(seq: 2, "B"))

        XCTAssertEqual(buffer.pendingCount, 0)
        XCTAssertEqual(feeder.calls, [.feed(Array("A".utf8)), .feed(Array("B".utf8))])
    }

    /// detach sonrası gelen chunk yeniden tamponlanır (yeni attach'ı bekler).
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
