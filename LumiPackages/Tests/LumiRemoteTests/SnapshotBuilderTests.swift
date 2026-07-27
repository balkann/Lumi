import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class SnapshotBuilderTests: XCTestCase {
    private func meta(name: String = "claude", repoPath: String = "/tmp/repo") -> TerminalMeta {
        TerminalMeta(
            id: TerminalID(), name: name, repoPath: repoPath,
            createdAt: Date(timeIntervalSince1970: 1000),
            task: nil, oscTitle: "✳ çalışıyor", status: .working
        )
    }

    func testSnapshotShape() throws {
        let m = meta()
        let repo = Repo(name: "repo", path: "/tmp/repo", isGitRepo: true, source: .projectsRoot)
        let persona = Persona(id: "reviewer", label: "Reviewer")
        let snap = SnapshotBuilder.snapshot(terminals: [m], repos: [repo], personas: [persona])

        let sessions = try XCTUnwrap(snap["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["id"] as? String, m.id.description)
        XCTAssertEqual(sessions[0]["repoName"] as? String, "repo")
        XCTAssertEqual(sessions[0]["repoPath"] as? String, "/tmp/repo")
        XCTAssertEqual(sessions[0]["status"] as? String, "working")
        XCTAssertEqual(sessions[0]["title"] as? String, "✳ çalışıyor")

        let repos = try XCTUnwrap(snap["repos"] as? [[String: Any]])
        XCTAssertEqual(repos[0]["name"] as? String, "repo")
        let personas = try XCTUnwrap(snap["personas"] as? [[String: Any]])
        XCTAssertEqual(personas[0]["id"] as? String, "reviewer")
        XCTAssertEqual(personas[0]["label"] as? String, "Reviewer")
    }

    func testSnapshotRepoNameFallsBackToLastPathComponent() throws {
        let m = meta(repoPath: "/Users/x/wkspaces/sand_out")
        let snap = SnapshotBuilder.snapshot(terminals: [m], repos: [], personas: [])
        let sessions = try XCTUnwrap(snap["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions[0]["repoName"] as? String, "sand_out")
    }

    func testStatusChangeEvent() {
        let m = meta()
        let event = SnapshotBuilder.statusChangeEvent(
            meta: m, status: .waitingUnseen, repoName: "repo", summary: "Bash izni istiyor")
        XCTAssertEqual(event["kind"] as? String, "status_change")
        XCTAssertEqual(event["sessionId"] as? String, m.id.description)
        XCTAssertEqual(event["status"] as? String, "waiting-unseen")
        XCTAssertEqual(event["repoName"] as? String, "repo")
        XCTAssertEqual(event["summary"] as? String, "Bash izni istiyor")
    }

    func testStatusChangeEventOmitsNilSummary() {
        let event = SnapshotBuilder.statusChangeEvent(
            meta: meta(), status: .error, repoName: "repo", summary: nil)
        XCTAssertNil(event["summary"])
    }
}
