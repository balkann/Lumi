import Testing
import Foundation
import LumiWire
@testable import LumiMobileKit

@Suite @MainActor struct GroupedPromptTests {
    @Test func selectionsEncodedInQuestionOrder() {
        let frame = PhoneProtocol.promptRespondSelectionsFrame(
            sessionId: "s", itemId: "q1", expectedRevision: 0,
            selections: [(indices: [1], other: nil), (indices: [0, 2], other: "x")])
        // frame payload selections[0]=={indices:[1]}, selections[1]=={indices:[0,2],other:"x"}
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = obj["payload"] as? [String: Any]
        let sels = payload?["selections"] as? [[String: Any]]
        #expect((sels?[0]["indices"] as? [Int]) == [1])
        #expect((sels?[1]["other"] as? String) == "x")
    }

    @Test func selectionsCountMatchesQuestionCount() {
        let frame = PhoneProtocol.promptRespondSelectionsFrame(
            sessionId: "s", itemId: "q2", expectedRevision: 1,
            selections: [
                (indices: [0], other: nil),
                (indices: [1, 2], other: nil),
                (indices: [], other: "free")
            ])
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = obj["payload"] as? [String: Any]
        let sels = payload?["selections"] as? [[String: Any]]
        #expect(sels?.count == 3)
        #expect((sels?[2]["other"] as? String) == "free")
    }

    @Test func singleSelectionStillWorks() {
        let frame = PhoneProtocol.promptRespondSelectionsFrame(
            sessionId: "s", itemId: "q3", expectedRevision: 0,
            selections: [(indices: [2], other: nil)])
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = obj["payload"] as? [String: Any]
        let sels = payload?["selections"] as? [[String: Any]]
        #expect(sels?.count == 1)
        #expect((sels?[0]["indices"] as? [Int]) == [2])
        #expect(sels?[0]["other"] == nil)
    }
}
