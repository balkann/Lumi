import LumiKit
import XCTest
@testable import LumiState

/// Karar 83: tüketici döngüsünün çıkışı ve sayacı gözlemlenebilir olmalı —
/// hayalet terminal teşhisinde "döngü hâlâ dönüyor mu" sorusunun cevabı budur.
@MainActor
final class EventConsumerDiagnosticsTests: XCTestCase {
    func testCountsHandledEventsAndReportsStreamFinish() async {
        let consumer = EventConsumer(label: "test")
        var continuation: AsyncStream<Int>.Continuation!
        let stream = AsyncStream<Int> { continuation = $0 }
        var received: [Int] = []
        consumer.start(stream, describe: { "event \($0)" }) { received.append($0) }

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()

        await waitUntil { consumer.lastExitReason != nil }
        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(consumer.eventsHandled, 2)
        XCTAssertEqual(consumer.lastExitReason, "stream finished")
    }

    func testStopCancelsLoop() async {
        let consumer = EventConsumer(label: "test")
        var continuation: AsyncStream<Int>.Continuation!
        let stream = AsyncStream<Int> { continuation = $0 }
        consumer.start(stream) { _ in }
        XCTAssertTrue(consumer.isRunning)

        consumer.stop()
        continuation.yield(1)

        XCTAssertFalse(consumer.isRunning)
        await waitUntil { consumer.lastExitReason != nil }
        XCTAssertEqual(consumer.eventsHandled, 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
