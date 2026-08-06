import XCTest
@testable import LumiRemote

final class TranscriptPointerStoreTests: XCTestCase {
    private var mapDir: URL!
    override func setUp() {
        super.setUp()
        mapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("map-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: mapDir); super.tearDown() }

    private func writePointer(tid: String, path: String) throws {
        let json = #"{"session_id":"s","transcript_path":"\#(path)","cwd":"/c","source":"startup"}"#
        try json.data(using: .utf8)!.write(to: mapDir.appendingPathComponent("\(tid).json"))
    }

    func testReadsTranscriptPath() throws {
        try writePointer(tid: "tid1", path: "/tmp/foo/abc.jsonl")
        let store = TranscriptPointerStore(mapDir: mapDir)
        XCTAssertEqual(store.transcriptPath(for: "tid1"), URL(fileURLWithPath: "/tmp/foo/abc.jsonl"))
    }
    func testMissingPointerReturnsNil() {
        XCTAssertNil(TranscriptPointerStore(mapDir: mapDir).transcriptPath(for: "nope"))
    }
    func testCorruptJSONReturnsNil() throws {
        try "not json".data(using: .utf8)!.write(to: mapDir.appendingPathComponent("bad.json"))
        XCTAssertNil(TranscriptPointerStore(mapDir: mapDir).transcriptPath(for: "bad"))
    }
}
