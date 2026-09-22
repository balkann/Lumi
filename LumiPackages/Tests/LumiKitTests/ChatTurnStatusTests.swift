import Testing
import Foundation
@testable import LumiKit

@Suite struct ChatTurnStatusTests {
    @Test func idleIsNotWorking() {
        #expect(ChatTurnStatus.idle == ChatTurnStatus(working: false, startedAtMs: nil, tool: nil))
    }

    @Test func toDictEncodesWorkingWithNSNullForNils() {
        let dict = ChatTurnStatus(working: true, startedAtMs: nil, tool: nil).toDict()
        #expect(dict["working"] as? Bool == true)
        #expect(dict["startedAtMs"] is NSNull)
        #expect(dict["tool"] is NSNull)
    }

    @Test func toDictEncodesValues() {
        let dict = ChatTurnStatus(working: true, startedAtMs: 1234, tool: "Bash").toDict()
        #expect(dict["startedAtMs"] as? Int == 1234)
        #expect(dict["tool"] as? String == "Bash")
    }
}
