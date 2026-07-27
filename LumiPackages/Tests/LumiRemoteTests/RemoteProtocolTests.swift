import Foundation
import XCTest
@testable import LumiRemote

final class RemoteProtocolTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let data = try XCTUnwrap(RemoteProtocol.envelope(type: "hello", payload: ["role": "mac", "token": "t-1234567890123456"]))
        let decoded = try XCTUnwrap(RemoteProtocol.decode(data))
        XCTAssertEqual(decoded.type, "hello")
        XCTAssertEqual(decoded.payload["role"] as? String, "mac")
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["v"] as? Int, 1)
    }

    func testDecodeRejectsBadInput() {
        XCTAssertNil(RemoteProtocol.decode(text: "not json"))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":2,"type":"ping","payload":{}}"#))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":1,"payload":{}}"#))
        XCTAssertNil(RemoteProtocol.decode(text: #"{"v":1,"type":"ping"}"#))
    }

    func testKeySequenceMap() {
        XCTAssertEqual(keySequence(for: "1"), "1")
        XCTAssertEqual(keySequence(for: "2"), "2")
        XCTAssertEqual(keySequence(for: "3"), "3")
        XCTAssertEqual(keySequence(for: "enter"), "\r")
        XCTAssertEqual(keySequence(for: "esc"), "\u{1B}")
        XCTAssertNil(keySequence(for: "rm -rf"))
        XCTAssertNil(keySequence(for: "f4"))
    }

    func testBackoffDoublesAndCapsAndResets() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        for _ in 0..<10 { _ = backoff.nextDelay() }
        XCTAssertEqual(backoff.nextDelay(), 60)
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
