import Testing
import Foundation
@testable import LumiServices

@Suite struct ClaudeWorkspaceTrustTests {
    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-trust-\(UUID().uuidString)")
    }

    private func readProjects(_ home: URL) -> [String: Any] {
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projs = obj["projects"] as? [String: Any] else { return [:] }
        return projs
    }

    @Test func createsFileAndMarksTrustedWhenMissing() throws {
        let home = tempHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeWorkspaceTrust(home: home, environment: [:]).markTrusted(repoPath: "/repo/x")
        let entry = readProjects(home)["/repo/x"] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func preservesExistingProjectsAndKeys() throws {
        let home = tempHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "numStartups": 42,
            "projects": [
                "/repo/other": ["hasTrustDialogAccepted": true, "lastCost": 1.5],
                "/repo/x": ["hasTrustDialogAccepted": false, "lastSessionId": "abc"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: home.appendingPathComponent(".claude.json"))

        ClaudeWorkspaceTrust(home: home, environment: [:]).markTrusted(repoPath: "/repo/x")

        // Hedef proje güvenli oldu, diğer anahtarı korundu.
        let x = readProjects(home)["/repo/x"] as? [String: Any]
        #expect(x?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(x?["lastSessionId"] as? String == "abc")
        // Diğer proje ve kök anahtarlar dokunulmadan durdu.
        let other = readProjects(home)["/repo/other"] as? [String: Any]
        #expect(other?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(other?["lastCost"] as? Double == 1.5)
        let url = home.appendingPathComponent(".claude.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(root?["numStartups"] as? Int == 42)
    }

    @Test func respectsClaudeConfigDirOverride() throws {
        let home = tempHome()
        let cfg = tempHome()
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        ClaudeWorkspaceTrust(home: home, environment: ["CLAUDE_CONFIG_DIR": cfg.path])
            .markTrusted(repoPath: "/repo/y")
        // ~/.claude.json DEĞİL, override dizinine yazılmalı.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        let overridden = cfg.appendingPathComponent(".claude.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: overridden)) as? [String: Any]
        let projs = root?["projects"] as? [String: Any]
        #expect((projs?["/repo/y"] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func emptyRepoPathIsNoop() throws {
        let home = tempHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeWorkspaceTrust(home: home, environment: [:]).markTrusted(repoPath: "")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
    }
}
