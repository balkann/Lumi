import XCTest
@testable import LumiMobileKit
import LumiWire

final class ChatStreamingGateTests: XCTestCase {
    func testStreamingVisibleWhenLeadingLastMessage() {
        // streaming metni son mesajı geçiyorsa göster; içeriyorsa/kısaysa gizle (orca gate)
        XCTAssertEqual(chatStreamingText(working: true, streaming: "Selam dünya",
                                         lastAssistantText: "Selam"), "Selam dünya")
        XCTAssertNil(chatStreamingText(working: true, streaming: "Selam",
                                       lastAssistantText: "Selam dünya"))   // caught up
        XCTAssertNil(chatStreamingText(working: false, streaming: "x", lastAssistantText: ""))  // idle
        XCTAssertNil(chatStreamingText(working: true, streaming: nil, lastAssistantText: ""))
    }
}
