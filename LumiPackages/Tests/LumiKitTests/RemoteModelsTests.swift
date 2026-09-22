import XCTest
@testable import LumiKit

final class RemoteModelsTests: XCTestCase {
    func testDefaults() {
        let d = RemoteConfig.defaults
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.relayUrl, "wss://lumi-relay-production.up.railway.app")
        XCTAssertEqual(d.token, "")
    }

    func testRemoteFilePath() {
        let paths = LumiPaths(mode: .development)
        XCTAssertEqual(paths.remoteFile.lastPathComponent, "remote.json")
        XCTAssertEqual(paths.remoteFile.deletingLastPathComponent().path, paths.configDir.path)
    }
}
