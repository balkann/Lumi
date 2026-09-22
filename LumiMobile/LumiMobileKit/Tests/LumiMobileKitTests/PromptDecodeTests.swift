import XCTest
@testable import LumiMobileKit
import LumiWire

final class PromptDecodeTests: XCTestCase {
    func testDecodePromptFrame() {
        let frame = #"""
        {"v":1,"type":"prompt","payload":{"sessionId":"s1","itemId":"i1","revision":0,"kind":"approval","title":"Bash?","detail":"npm i","options":[{"id":"allow","label":"Allow","description":null},{"id":"deny","label":"Deny","description":null}],"state":"pending","selectedOptionId":null}}
        """#
        guard case let .prompt(sessionId, p)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("prompt decode edilemedi")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(p.itemId, "i1")
        XCTAssertEqual(p.kind, .approval)
        XCTAssertEqual(p.options.map(\.id), ["allow", "deny"])
        XCTAssertEqual(p.state, .pending)
    }

    func testDecodeQuestionPromptWithDescriptions() {
        let frame = #"""
        {"v":1,"type":"prompt","payload":{"sessionId":"s1","itemId":"q1","revision":1,"kind":"question","title":"Pick","detail":null,"options":[{"id":"opt-0","label":"A","description":"aa"}],"state":"pending","selectedOptionId":null}}
        """#
        guard case let .prompt(_, p)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("question prompt decode edilemedi")
        }
        XCTAssertEqual(p.kind, .question)
        XCTAssertEqual(p.options.first?.description, "aa")
        XCTAssertNil(p.detail)
    }

    func testDecodeGroupedQuestionPrompt() {
        let frame = #"""
        {"v":1,"type":"prompt","payload":{"sessionId":"s1","itemId":"g1","revision":0,"kind":"question","title":"G","detail":null,"options":[],"state":"pending","selectedOptionId":null,"multiSelect":false,"allowOther":true,"questions":[{"id":"q0","question":"Q0","header":"H","multiSelect":true,"allowOther":false,"options":[{"id":"opt-0","label":"A","description":null}]}]}}
        """#
        guard case let .prompt(_, p)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("gruplu prompt decode edilemedi")
        }
        XCTAssertTrue(p.allowOther)
        XCTAssertEqual(p.questions.count, 1)
        XCTAssertEqual(p.questions.first?.id, "q0")
        XCTAssertTrue(p.questions.first?.multiSelect ?? false)
        XCTAssertEqual(p.questions.first?.options.first?.label, "A")
    }

    func testPromptRespondSelectionsFrameEncodes() throws {
        let frame = PhoneProtocol.promptRespondSelectionsFrame(sessionId: "s1", itemId: "i1", expectedRevision: 2,
            selections: [(indices: [0, 2], other: "x"), (indices: [], other: nil)])
        let obj = try JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        XCTAssertEqual(payload["sessionId"] as? String, "s1")
        XCTAssertEqual(payload["expectedRevision"] as? Int, 2)
        let sels = payload["selections"] as! [[String: Any]]
        XCTAssertEqual(sels.count, 2)
        XCTAssertEqual(sels[0]["indices"] as? [Int], [0, 2])
        XCTAssertEqual(sels[0]["other"] as? String, "x")
        XCTAssertEqual(sels[1]["indices"] as? [Int], [])
        XCTAssertNil(sels[1]["other"])
    }
}
