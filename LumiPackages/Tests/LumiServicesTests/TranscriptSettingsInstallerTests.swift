import XCTest
@testable import LumiServices

final class TranscriptSettingsInstallerTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-inst-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testInstallWritesHookAndSettingsAndReturnsSettingsPath() throws {
        let settingsPath = try TranscriptSettingsInstaller(lumiRoot: root).install()

        let script = root.appendingPathComponent("hooks/session-start.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        let perms = (try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "script sahibi/grup/diğer için çalıştırılabilir olmalı")
        let body = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(body.contains("LUMI_TERMINAL_ID"))
        XCTAssertTrue(body.contains("transcript-map"))

        XCTAssertEqual(settingsPath, root.appendingPathComponent("claude-settings.json"))
        let settings = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["SessionStart"], "settings SessionStart hook içermeli")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("transcript-map").path))
    }

    func testHookCommandSingleQuotesPathWithSpace() throws {
        // Build a lumiRoot whose path contains a space to exercise quoting
        let spaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi inst \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spaceRoot) }

        try TranscriptSettingsInstaller(lumiRoot: spaceRoot).install()

        let settingsPath = spaceRoot.appendingPathComponent("claude-settings.json")
        let data = try Data(contentsOf: settingsPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let innerHooks = sessionStart[0]["hooks"] as! [[String: Any]]
        let command = innerHooks[0]["command"] as! String

        let expectedScriptPath = spaceRoot
            .appendingPathComponent("hooks/session-start.sh").path
        XCTAssertTrue(command.contains("'\(expectedScriptPath)'"),
            "command '\(command)' should single-quote script path '\(expectedScriptPath)'")
    }

    func testInstallIsIdempotent() throws {
        let p1 = try TranscriptSettingsInstaller(lumiRoot: root).install()
        let p2 = try TranscriptSettingsInstaller(lumiRoot: root).install()
        XCTAssertEqual(p1, p2)
    }
}
