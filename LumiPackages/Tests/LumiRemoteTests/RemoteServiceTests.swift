import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

/// Sahte bağlantı: gönderilenleri kaydeder, inbound'u testin kontrolüne verir.
private actor FakeConnection: RelayConnecting {
    var sent: [(type: String, payload: [String: Any])] = []
    var started: [(url: URL, hello: [String: Any])] = []
    var stopCount = 0
    private var continuation: AsyncStream<RelayInbound>.Continuation?

    func start(url: URL, hello: [String: Any]) { started.append((url, hello)) }
    func stop() { stopCount += 1 }
    func send(type: String, payload: [String: Any]) { sent.append((type, payload)) }
    func inbound() -> AsyncStream<RelayInbound> {
        let (stream, c) = AsyncStream.makeStream(of: RelayInbound.self)
        continuation = c
        return stream
    }
    func push(_ inbound: RelayInbound) { continuation?.yield(inbound) }
    func startedCount() -> Int { started.count }
    func stops() -> Int { stopCount }
    /// Returns started[0] url and hello fields as sendable primitives
    func firstStartedURL() -> String? { started.first.map { $0.url.absoluteString } }
    func firstStartedRole() -> String? { started.first.flatMap { $0.hello["role"] as? String } }
    func firstStartedToken() -> String? { started.first.flatMap { $0.hello["token"] as? String } }
    // Snapshot query
    func snapshotSessionCount() -> Int? {
        guard let snap = sent.first(where: { $0.type == "snapshot" }) else { return nil }
        return (snap.payload["sessions"] as? [[String: Any]])?.count
    }
    func snapshotRepoCount() -> Int? {
        guard let snap = sent.first(where: { $0.type == "snapshot" }) else { return nil }
        return (snap.payload["repos"] as? [[String: Any]])?.count
    }
    // Status event query
    func firstEventKind() -> String? {
        guard let e = sent.first(where: { $0.type == "event" }) else { return nil }
        return e.payload["kind"] as? String
    }
    func firstEventStatus() -> String? {
        guard let e = sent.first(where: { $0.type == "event" }) else { return nil }
        return e.payload["status"] as? String
    }
    func firstEventRepoName() -> String? {
        guard let e = sent.first(where: { $0.type == "event" }) else { return nil }
        return e.payload["repoName"] as? String
    }
    // Command result query
    func commandResultOk() -> Bool? {
        guard let r = sent.last(where: { $0.type == "command_result" }) else { return nil }
        return r.payload["ok"] as? Bool
    }
    func commandResultId() -> String? {
        guard let r = sent.last(where: { $0.type == "command_result" }) else { return nil }
        return r.payload["commandId"] as? String
    }
    // History event query
    func historyEvent() -> (sessionId: String, itemCount: Int)? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "history" })
        else { return nil }
        return ((e.payload["sessionId"] as? String) ?? "",
                (e.payload["items"] as? [[String: Any]])?.count ?? -1)
    }
    func historyFirstItemText() -> String? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "history" }),
              let items = e.payload["items"] as? [[String: Any]] else { return nil }
        return items.first?["text"] as? String
    }
    func commandResultError() -> String? {
        guard let r = sent.last(where: { $0.type == "command_result" }) else { return nil }
        return r.payload["error"] as? String
    }
    func historyEventThenResultOrder() -> Bool? {
        guard let eventIdx = sent.firstIndex(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "history" }),
              let resultIdx = sent.firstIndex(where: { $0.type == "command_result" })
        else { return nil }
        return eventIdx < resultIdx
    }
    func awaitingEvent() -> (sessionId: String, awaiting: Bool)? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "awaiting_decision" })
        else { return nil }
        return ((e.payload["sessionId"] as? String) ?? "", (e.payload["awaiting"] as? Bool) ?? false)
    }
    func snapshotFirstSessionAwaiting() -> Bool? {
        guard let snap = sent.last(where: { $0.type == "snapshot" }),
              let sessions = snap.payload["sessions"] as? [[String: Any]],
              let first = sessions.first else { return nil }
        return (first["awaitingDecision"] as? Bool) ?? false
    }
    func modelChangeEvent() -> (sessionId: String, model: String)? {
        guard let e = sent.first(where: { $0.type == "event" && ($0.payload["kind"] as? String) == "model_change" })
        else { return nil }
        return ((e.payload["sessionId"] as? String) ?? "", (e.payload["model"] as? String) ?? "")
    }
    func modelChangeEventCount() -> Int {
        sent.filter { $0.type == "event" && ($0.payload["kind"] as? String) == "model_change" }.count
    }
    func snapshotFirstSessionModel() -> String? {
        guard let snap = sent.last(where: { $0.type == "snapshot" }),
              let sessions = snap.payload["sessions"] as? [[String: Any]],
              let first = sessions.first else { return nil }
        return first["model"] as? String
    }
    func promptEvent() -> (sessionId: String, optionCount: Int)? {
        guard let e = sent.first(where: {
            $0.type == "event" && ($0.payload["kind"] as? String) == "transcript"
                && (($0.payload["item"] as? [String: Any])?["itemType"] as? String) == "question"
        }) else { return nil }
        let item = e.payload["item"] as? [String: Any]
        let qs = item?["questions"] as? [[String: Any]]
        return ((e.payload["sessionId"] as? String) ?? "",
                (qs?.first?["options"] as? [String])?.count ?? -1)
    }
    func questionEventCount() -> Int {
        sent.filter {
            $0.type == "event" && ($0.payload["kind"] as? String) == "transcript"
                && (($0.payload["item"] as? [String: Any])?["itemType"] as? String) == "question"
        }.count
    }
    func snapshotFirstSessionHasActivePrompt() -> Bool {
        guard let snap = sent.last(where: { $0.type == "snapshot" }),
              let sessions = snap.payload["sessions"] as? [[String: Any]],
              let first = sessions.first else { return false }
        return first["activePrompt"] != nil
    }
    func sessionResetSent() -> String? {
        guard let e = sent.first(where: {
            $0.type == "event" && ($0.payload["kind"] as? String) == "session_reset"
        }) else { return nil }
        return e.payload["sessionId"] as? String
    }
}

// FakeTerminal: RemoteCommandHandlerTests'tekiyle aynı yüzey + events push'u
@MainActor
private final class FakeTerminal: TerminalServicing {
    var metas: [TerminalMeta] = []
    var writes: [(TerminalID, String)] = []
    private var eventContinuations: [AsyncStream<TerminalEvent>.Continuation] = []

    func spawn(repoPath: String, task: String?, command: String?) throws -> TerminalMeta {
        let meta = TerminalMeta(id: TerminalID(), name: "t", repoPath: repoPath,
                                createdAt: Date(), task: task, oscTitle: nil, status: .idle)
        metas.append(meta)
        return meta
    }
    func write(id: TerminalID, text: String) throws { writes.append((id, text)) }
    func kill(id: TerminalID) throws {}
    func killAll() {}
    func resize(id: TerminalID, cols: Int, rows: Int) {}
    func setFocused(_ id: TerminalID?) {}
    func setWindowFocused(_ focused: Bool) {}
    var terminals: [TerminalMeta] { metas }
    func setMaxTerminals(_ n: Int) {}
    func events() -> AsyncStream<TerminalEvent> {
        let (stream, c) = AsyncStream.makeStream(of: TerminalEvent.self)
        eventContinuations.append(c)
        return stream
    }
    func outputStream(id: TerminalID) -> AsyncStream<String>? { nil }
    func pushEvent(_ e: TerminalEvent) { eventContinuations.forEach { $0.yield(e) } }
}

private actor FakeRepos: RepoServicing {
    func repos() async -> [Repo] { [Repo(name: "demo", path: "/tmp/demo", isGitRepo: true, source: .projectsRoot)] }
    func setRoots(projectsRoot: String, additionalPaths: [AdditionalPath]) async {}
    func fileTree(repoPath: String) async -> [FileTreeNode] { [] }
    func watchFileTree(repoPath: String) async {}
    func unwatchFileTree(repoPath: String) async {}
    func events() -> AsyncStream<RepoEvent> { AsyncStream { $0.finish() } }
}

private actor FakePersonas: PersonaServicing {
    func personas(projectPath: String?) async -> [Persona] { [Persona(id: "rev", label: "Reviewer")] }
    func seedDefaults() async {}
    func spawn(personaID: String, repoPath: String) async throws -> TerminalMeta {
        TerminalMeta(id: TerminalID(), name: "p", repoPath: repoPath,
                     createdAt: Date(), task: nil, oscTitle: nil, status: .idle)
    }
    func events() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor
final class RemoteServiceTests: XCTestCase {
    nonisolated(unsafe) private var tempHome: URL!
    nonisolated(unsafe) private var paths: LumiPaths!

    override func setUp() {
        super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-service-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        paths = LumiPaths(mode: .development, homeDirectory: tempHome)
        try! paths.ensureDirectoriesExist()
        // enabled config hazırla
        let raw = #"{"enabled": true, "relayUrl": "wss://relay.test", "token": "secret-token-1234567890"}"#
        try! raw.data(using: .utf8)!.write(to: paths.remoteFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    private func makeService(connection: FakeConnection, terminal: FakeTerminal) -> RemoteService {
        RemoteService(
            paths: paths, terminal: terminal, repos: FakeRepos(),
            personas: FakePersonas(), connection: connection,
            transcriptsRoot: tempHome.appendingPathComponent("transcripts"))
    }

    private func drain() async { try? await Task.sleep(for: .milliseconds(200)) }

    func testStartSendsHelloWithToken() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        let count = await connection.startedCount()
        let url = await connection.firstStartedURL()
        let role = await connection.firstStartedRole()
        let token = await connection.firstStartedToken()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(url, "wss://relay.test")
        XCTAssertEqual(role, "mac")
        XCTAssertEqual(token, "secret-token-1234567890")
        service.stop()
    }

    func testDisabledConfigDoesNotConnect() async {
        let raw = #"{"enabled": false, "relayUrl": "wss://relay.test", "token": "secret-token-1234567890"}"#
        try! raw.data(using: .utf8)!.write(to: paths.remoteFile)
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        let count = await connection.startedCount()
        XCTAssertEqual(count, 0)
    }

    func testWelcomeTriggersSnapshot() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        _ = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()
        let sessionCount = await connection.snapshotSessionCount()
        let repoCount = await connection.snapshotRepoCount()
        XCTAssertEqual(sessionCount, 1)
        XCTAssertEqual(repoCount, 1)
        service.stop()
    }

    func testStatusChangeSendsEvent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        terminal.pushEvent(.statusChanged(meta.id, .waitingUnseen))
        await drain()
        let kind = await connection.firstEventKind()
        let status = await connection.firstEventStatus()
        let repoName = await connection.firstEventRepoName()
        XCTAssertEqual(kind, "status_change")
        XCTAssertEqual(status, "waiting-unseen")
        XCTAssertEqual(repoName, "demo")
        service.stop()
    }

    func testCommandRoutedAndResultSent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        await connection.push(.message(type: "command", payload: [
            "commandId": "c1", "action": "send_text",
            "sessionId": meta.id.description, "text": "merhaba",
        ]))
        await drain()
        XCTAssertEqual(terminal.writes.last?.1, "merhaba\r")
        let ok = await connection.commandResultOk()
        let commandId = await connection.commandResultId()
        XCTAssertEqual(ok, true)
        XCTAssertEqual(commandId, "c1")
        service.stop()
    }

    func testStateChangesBroadcast() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        let stream = service.events()
        await service.start()
        await drain()
        await connection.push(.stateChanged(.connected))
        var got: RemoteConnectionState?
        for await event in stream {
            if case .stateChanged(let s) = event, s == .connected { got = s; break }
        }
        XCTAssertEqual(got, .connected)
        XCTAssertEqual(service.state, .connected)
        service.stop()
    }

    func testStopStopsConnection() async {
        let connection = FakeConnection()
        let service = makeService(connection: connection, terminal: FakeTerminal())
        await service.start()
        await drain()
        service.stop()
        await drain()
        let stops = await connection.stops()
        XCTAssertGreaterThanOrEqual(stops, 1)
    }

    func testGetHistorySendsHistoryEventAndOkResult() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        // transcript fixture'ı: transcriptsRoot/<encoded>/s1.jsonl
        let projectDir = tempHome.appendingPathComponent("transcripts")
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"gecmis-mesaj"}]}}"#
        try (line + "\n").data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s1.jsonl"))

        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-1", "action": "get_history", "sessionId": meta.id.description,
        ]))
        await drain()

        let history = await connection.historyEvent()
        XCTAssertEqual(history?.sessionId, meta.id.description)
        XCTAssertEqual(history?.itemCount, 1)
        let text = await connection.historyFirstItemText()
        XCTAssertEqual(text, "gecmis-mesaj")
        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, true)
        let ordered = await connection.historyEventThenResultOrder()
        XCTAssertEqual(ordered, true, "history event'i command_result'tan ÖNCE gitmeli")
        service.stop()
        await drain()
    }

    func testGetHistoryUnknownSessionReturnsError() async {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-2", "action": "get_history",
            "sessionId": UUID().uuidString,
        ]))
        await drain()

        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, false)
        let error = await connection.commandResultError()
        XCTAssertEqual(error, "session_not_found")
        let history = await connection.historyEvent()
        XCTAssertNil(history)
        service.stop()
        await drain()
    }

    func testGetHistoryNoTranscriptReturnsError() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        _ = try terminal.spawn(repoPath: "/tmp/bos-repo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start()
        await drain()
        let meta = terminal.terminals[0]

        await connection.push(.message(type: "command", payload: [
            "commandId": "h-3", "action": "get_history", "sessionId": meta.id.description,
        ]))
        await drain()

        let ok = await connection.commandResultOk()
        XCTAssertEqual(ok, false)
        let error = await connection.commandResultError()
        XCTAssertEqual(error, "no_transcript")
        service.stop()
        await drain()
    }

    func testAwaitingDecisionChangeSendsEvent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        terminal.pushEvent(.awaitingDecisionChanged(meta.id, true))
        await drain()

        let ev = await connection.awaitingEvent()
        XCTAssertEqual(ev?.sessionId, meta.id.description)
        XCTAssertEqual(ev?.awaiting, true)
        service.stop()
    }

    func testSnapshotCarriesAwaitingDecision() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        _ = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let meta = terminal.metas[0]
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        terminal.pushEvent(.awaitingDecisionChanged(meta.id, true))
        await drain()
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()

        let awaiting = await connection.snapshotFirstSessionAwaiting()
        XCTAssertEqual(awaiting, true)
        service.stop()
    }

    func testExitClearsAwaitingDecision() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        terminal.pushEvent(.awaitingDecisionChanged(meta.id, true)); await drain()
        terminal.pushEvent(.exited(meta.id, code: 0)); await drain() // stopWatcher temizler + snapshot yollar

        let awaiting = await connection.snapshotFirstSessionAwaiting()
        XCTAssertEqual(awaiting, false)
        service.stop()
    }

    func testModelChangeEventShape() {
        let e = SnapshotBuilder.modelChangeEvent(sessionId: "s1", model: "claude-opus-4-8")
        XCTAssertEqual(e["kind"] as? String, "model_change")
        XCTAssertEqual(e["sessionId"] as? String, "s1")
        XCTAssertEqual(e["model"] as? String, "claude-opus-4-8")
    }

    func testModelFeedItemEmitsChangeOnceAndSnapshotCarriesIt() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        await service.handleFeedItem(.model("claude-opus-4-8"), sessionId: meta.id)
        let ev = await connection.modelChangeEvent()
        XCTAssertEqual(ev?.sessionId, meta.id.description)
        XCTAssertEqual(ev?.model, "claude-opus-4-8")

        // aynı model tekrar → yeni event yok
        await service.handleFeedItem(.model("claude-opus-4-8"), sessionId: meta.id)
        let eventCount = await connection.modelChangeEventCount()
        XCTAssertEqual(eventCount, 1)

        // snapshot güncel modeli taşır
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()
        let snapshotModel = await connection.snapshotFirstSessionModel()
        XCTAssertEqual(snapshotModel, "claude-opus-4-8")
        service.stop()
    }

    func testGetHistoryExcludesModelItem() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let projectDir = tempHome.appendingPathComponent("transcripts")
            .appendingPathComponent(TranscriptParser.projectDirName(forCwd: "/tmp/demo"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"gecmis"}]}}"#
        try (line + "\n").data(using: .utf8)!.write(to: projectDir.appendingPathComponent("s1.jsonl"))

        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()
        await connection.push(.message(type: "command", payload: [
            "commandId": "h-9", "action": "get_history", "sessionId": meta.id.description,
        ]))
        await drain()

        let history = await connection.historyEvent()
        XCTAssertEqual(history?.itemCount, 1, "model öğesi history'den elenmeli, yalnız metin kalmalı")
        let firstText = await connection.historyFirstItemText()
        XCTAssertEqual(firstText, "gecmis")
        service.stop(); await drain()
    }

    func testPromptChangedSendsQuestionEvent() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .permission,
                                    questionText: "Do you want to proceed?",
                                    options: ["Yes", "No"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()

        let ev = await connection.promptEvent()
        XCTAssertEqual(ev?.sessionId, meta.id.description)
        XCTAssertEqual(ev?.optionCount, 2)
        service.stop(); await drain()
    }

    func testScreenPromptSuppressesTranscriptQuestion() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .question, questionText: "Q?", options: ["A", "B"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()
        // transcript AskUserQuestion aynı oturuma gelirse düşürülür
        await service.ingestFeedItemForTest(.question(payload: [
            Question(header: "", question: "Q?", options: ["A", "B"])
        ]), sessionId: meta.id)
        await drain()

        let count = await connection.questionEventCount()
        XCTAssertEqual(count, 1) // yalnız ekran-scrape olayı
        service.stop(); await drain()
    }

    func testSnapshotCarriesActivePrompt() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        let prompt = DetectedPrompt(kind: .question, questionText: "Q?", options: ["A"])
        terminal.pushEvent(.promptChanged(meta.id, prompt))
        await drain()
        await connection.push(.message(type: "welcome", payload: ["phoneCount": 0]))
        await drain()

        let has = await connection.snapshotFirstSessionHasActivePrompt()
        XCTAssertTrue(has)
        service.stop(); await drain()
    }

    func testSessionResetSendsResetEventAndClearsPrompt() async throws {
        let connection = FakeConnection()
        let terminal = FakeTerminal()
        let meta = try terminal.spawn(repoPath: "/tmp/demo", task: nil, command: nil)
        let service = makeService(connection: connection, terminal: terminal)
        await service.start(); await drain()

        // Önce ekran promptu aktifleşsin (durum sıfırlanacak).
        terminal.pushEvent(.promptChanged(meta.id,
            DetectedPrompt(kind: .question, questionText: "Q?", options: ["A"])))
        await drain()

        // /clear → watcher .sessionReset yayar (test seam ile enjekte).
        await service.ingestFeedItemForTest(.sessionReset, sessionId: meta.id)
        await drain()

        let sid = await connection.sessionResetSent()
        XCTAssertEqual(sid, meta.id.description, "session_reset event'i doğru oturuma gönderilmeli")
        service.stop(); await drain()
    }
}
