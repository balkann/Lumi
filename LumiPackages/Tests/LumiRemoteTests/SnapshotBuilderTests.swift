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

    func testDuplicateRepoPathsDoNotCrash() throws {
        let a = Repo(name: "demo", path: "/tmp/demo", isGitRepo: true, source: .projectsRoot)
        let b = Repo(name: "demo-kopya", path: "/tmp/demo", isGitRepo: true, source: .standalone)
        let snap = SnapshotBuilder.snapshot(terminals: [meta(repoPath: "/tmp/demo")], repos: [a, b], personas: [])
        let sessions = try XCTUnwrap(snap["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions[0]["repoName"] as? String, "demo", "ilk kayıt kazanmalı")
    }

    func testPromptEventCarriesQuestionPayload() {
        let prompt = DetectedPrompt(kind: .permission,
                                    questionText: "Do you want to proceed?",
                                    options: ["Yes", "No"])
        let ev = SnapshotBuilder.promptEvent(sessionId: "s1", prompt: prompt)
        XCTAssertEqual(ev["kind"] as? String, "transcript")
        let item = ev["item"] as? [String: Any]
        XCTAssertEqual(item?["itemType"] as? String, "question")
        let qs = item?["questions"] as? [[String: Any]]
        XCTAssertEqual(qs?.count, 1)
        XCTAssertEqual(qs?.first?["question"] as? String, "Do you want to proceed?")
        XCTAssertEqual(qs?.first?["options"] as? [String], ["Yes", "No"])
    }

    func testPromptEventNilClearsWithEmptyQuestions() {
        let ev = SnapshotBuilder.promptEvent(sessionId: "s1", prompt: nil)
        let item = ev["item"] as? [String: Any]
        XCTAssertEqual((item?["questions"] as? [[String: Any]])?.count, 0)
    }

    func testSessionResetEvent() {
        let ev = SnapshotBuilder.sessionResetEvent(sessionId: "s1")
        XCTAssertEqual(ev["kind"] as? String, "session_reset")
        XCTAssertEqual(ev["sessionId"] as? String, "s1")
    }
}
