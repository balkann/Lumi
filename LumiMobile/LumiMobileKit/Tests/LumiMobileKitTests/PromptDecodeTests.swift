import XCTest
@testable import LumiMobileKit

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
}
