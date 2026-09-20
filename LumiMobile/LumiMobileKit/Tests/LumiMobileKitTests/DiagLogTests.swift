import XCTest
@testable import LumiMobileKit
import LumiWire

final class DiagLogTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diaglog-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func contents(_ name: String = "test.log") -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func testAppendsTimestampedCategorizedLine() {
        let log = DiagLog()
        log.configure(directory: dir, filename: "test.log")
        log.log("remote", "connected wss://example")
        log.flush()
        let line = contents()
        XCTAssertTrue(
            line.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \[remote\] connected wss://example\n$"#,
                options: .regularExpression) != nil,
            "unexpected line: \(line)")
    }

    func testAppendsAcrossCallsAndCreatesDirectory() {
        let log = DiagLog()
        log.configure(directory: dir.appendingPathComponent("nested"), filename: "test.log")
        log.log("a", "one")
        log.log("b", "two")
        log.flush()
        let text = (try? String(
            contentsOf: dir.appendingPathComponent("nested/test.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("[a] one\n"))
        XCTAssertTrue(text.contains("[b] two\n"))
    }

    func testRotatesWhenExceedingMaxBytes() throws {
        let log = DiagLog()
        log.configure(directory: dir, filename: "test.log", maxBytes: 200)
        for index in 0..<20 {
            log.log("rot", "line \(index) — padding padding padding")
        }
        log.flush()
        let old = dir.appendingPathComponent("test.log.old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "rotation did not occur")
        let currentSize = try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent("test.log").path)[.size] as? Int
        XCTAssertLessThanOrEqual(currentSize ?? .max, 200)
        // The last line must be in the current file — rotation must not lose data.
        XCTAssertTrue(contents().contains("line 19"))
    }

    func testUnconfiguredLogIsSilentNoOp() {
        let log = DiagLog()
        log.log("x", "goes nowhere")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
