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
