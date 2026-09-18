import Testing
import Foundation
import AppKit
@testable import LumiRemote
import LumiKit
import LumiTestSupport

// MARK: - Test paths helper

extension LumiPaths {
    /// Her çağrıda benzersiz geçici configDir + enabled=true remote.json.
    /// `start()` guard'ı `enabled` ister; token boşsa ensureToken üretir.
    static func testDefaults() -> LumiPaths {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-remote-test-\(UUID().uuidString)")
        let paths = LumiPaths(mode: .development, homeDirectory: home)
        try? paths.ensureDirectoriesExist()
        let json = "{\"enabled\":true,\"relayUrl\":\"wss://test.invalid\",\"token\":\"tok\"}"
        try? json.data(using: .utf8)!.write(to: paths.remoteFile)
        return paths
    }
}

// MARK: - FakeRelayConnection

/// Gönderilenleri kaydeder, inbound mesajlarını enjekte eder.
final actor FakeRelayConnection: RelayConnecting {
    private var continuation: AsyncStream<RelayInbound>.Continuation?
    private(set) var sent: [(type: String, payload: [String: Any])] = []

    func start(url: URL, hello: [String: Any]) {}
    func stop() {}

    func send(type: String, payload: [String: Any]) {
        sent.append((type, payload))
    }

    func inbound() -> AsyncStream<RelayInbound> {
        let (stream, continuation) = AsyncStream.makeStream(of: RelayInbound.self)
        self.continuation = continuation
        return stream
    }

    /// Test API — inbound mesajı enjekte et.
    func injectInbound(type: String, payload: [String: Any]) {
        continuation?.yield(.message(type: type, payload: payload))
    }

    /// Belirli tipteki ilk mesajın string alanı (Sendable sınır-güvenli).
    func firstString(type: String, key: String) -> String? {
        sent.first { $0.type == type }?.payload[key] as? String
    }

    /// Belirli tipteki ilk mesajın Int alanı.
    func firstInt(type: String, key: String) -> Int? {
        sent.first { $0.type == type }?.payload[key] as? Int
    }

    /// `repos` mesajının payload'ındaki repo adları (Sendable sınır-güvenli).
    func repoNames() -> [String] {
        guard let payload = sent.first(where: { $0.type == "repos" })?.payload,
              let list = payload["repos"] as? [[String: String]] else { return [] }
        return list.compactMap { $0["name"] }
    }

    func count(type: String) -> Int {
        sent.filter { $0.type == type }.count
    }

    func sentTypes() -> [String] { sent.map { $0.type } }

    /// Gönderilen `sessions` frame'lerindeki meta `kind` değerleri (Sendable [String]
    /// döner — actor sınırından [String: Any] geçirmemek için).
    func sessionKinds() -> [String] {
        sent.filter { $0.type == "sessions" }
            .flatMap { ($0.payload["sessions"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["kind"] as? String }
    }

    /// Verilen tüm tipler gönderilene kadar (kısa timeout) bekler.
    func waitForSent(types: [String]) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let have = Set(sent.map { $0.type })
            if types.allSatisfy({ have.contains($0) }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FakeError.timeout("sent types \(types), have \(sent.map { $0.type })")
    }

    func waitForNoSent(type: String, after count: Int, for duration: Duration) async throws {
        try await Task.sleep(for: duration)
        let got = sent.filter { $0.type == type }.count
        if got > count {
            throw FakeError.timeout("expected no more '\(type)' after \(count), got \(got)")
        }
    }

    func lastBool(type: String, key: String) -> Bool? { sent.last { $0.type == type }?.payload[key] as? Bool }
    func lastInt(type: String, key: String) -> Int? { sent.last { $0.type == type }?.payload[key] as? Int }
    func lastString(type: String, key: String) -> String? { sent.last { $0.type == type }?.payload[key] as? String }
    func waitForCount(type: String, atLeast n: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if sent.filter({ $0.type == type }).count >= n { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FakeError.timeout("expected >= \(n) '\(type)', have \(count(type: type))")
    }

    enum FakeError: Error { case timeout(String) }
}

// MARK: - FakeTerminalServicing

@MainActor
final class FakeTerminalServicing: TerminalServicing {
    private let broadcaster = EventBroadcaster<TerminalEvent>()
    private var outputBroadcasters: [TerminalID: EventBroadcaster<Data>] = [:]

    var metas: [TerminalMeta] = []
    var scrollback: (data: Data, cols: Int, rows: Int) = (Data(), 80, 24)
    private(set) var writtenInput: [TerminalID: Data] = [:]
    private(set) var subscribedIDs: [TerminalID] = []
    private var inputContinuations: [AsyncStream<Void>.Continuation] = []

    var terminals: [TerminalMeta] { metas }

    @discardableResult
    func spawn(repoPath: String, task: String?, command: String?) throws -> TerminalMeta {
        let meta = TerminalMeta(id: TerminalID(), name: "T", repoPath: repoPath, createdAt: Date())
        metas.append(meta)
        broadcaster.send(.spawned(meta))
        return meta
    }

    func write(id: TerminalID, text: String) throws {}
    func kill(id: TerminalID) throws {}
    func killAll() {}
    func resize(id: TerminalID, cols: Int, rows: Int) {}
    func setFocused(_ id: TerminalID?) {}
    func setWindowFocused(_ focused: Bool) {}
    func setMaxTerminals(_ n: Int) {}
    func events() -> AsyncStream<TerminalEvent> { broadcaster.stream() }
    func outputStream(id: TerminalID) -> AsyncStream<String>? { nil }

    // Yeni main protokol üyeleri (test için no-op).
    func processID(for id: TerminalID) -> Int32? { nil }
    func setSurfaceState(_ state: TerminalSurfaceState, for id: TerminalID) {}
    func setSurfaceState(_ state: TerminalSurfaceState, in sessionID: String?) {}
    func setAgentHookEndpoint(_ endpoint: AgentHookEndpoint?) {}
    func applyAgentHookEvent(_ event: AgentHookEvent) {}
    func shutdown() {}
    func applyFont(_ font: NSFont) {}
    func applyCursor(shape: TerminalCursorShape, blink: Bool) {}

    func subscribeOutput(_ id: TerminalID) -> AsyncStream<Data> {
        subscribedIDs.append(id)
        return outputBroadcaster(for: id).stream()
    }

    func writeInput(_ data: Data, to id: TerminalID) {
        writtenInput[id, default: Data()].append(data)   // biriktirir (paced çok-grup için)
        for c in inputContinuations { c.yield(()) }
    }

    func serializeScrollback(_ id: TerminalID) -> (data: Data, cols: Int, rows: Int) {
        scrollback
    }

    // MARK: Test API

    func emitOutput(_ id: TerminalID, _ data: Data) {
        outputBroadcaster(for: id).send(data)
    }

    func emit(_ event: TerminalEvent) { broadcaster.send(event) }

    /// writeInput çağrısı gelene kadar bekler.
    func waitForInput() async throws {
        if !writtenInput.isEmpty { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        inputContinuations.append(continuation)
        if !writtenInput.isEmpty { return }
        for await _ in stream { return }
    }

    private func outputBroadcaster(for id: TerminalID) -> EventBroadcaster<Data> {
        if let existing = outputBroadcasters[id] { return existing }
        let fresh = EventBroadcaster<Data>()
        outputBroadcasters[id] = fresh
        return fresh
    }
}

// MARK: - Tests

@Suite @MainActor struct RemoteServiceTests {
    /// Deterministik UUID — sessionId = meta.id.description.
    private func makeSession(_ term: FakeTerminalServicing, uuid: UUID = UUID()) -> String {
        let meta = TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo", createdAt: Date())
        term.metas.append(meta)
        return meta.id.description
    }

    @Test func subscribeSendsScrollbackThenData() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        term.scrollback = ("SCROLL".data(using: .utf8)!, 80, 24)
        let sid = makeSession(term)
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(), connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()

        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid])
        // scrollback gönderilene kadar bekle, sonra canlı çıktı üret
        try await conn.waitForSent(types: ["scrollback"])
        let tid = TerminalID(raw: UUID(uuidString: sid)!)
        term.emitOutput(tid, "LIVE".data(using: .utf8)!)
        try await conn.waitForSent(types: ["scrollback", "data"])

        #expect(await conn.firstString(type: "scrollback", key: "data") == "U0NST0xM") // base64 "SCROLL"
        #expect(await conn.firstInt(type: "scrollback", key: "seq") == 0)
        #expect(await conn.firstString(type: "data", key: "data") == "TElWRQ==")       // base64 "LIVE"
        #expect(await conn.firstInt(type: "data", key: "seq") == 1)
        svc.stop()
    }

    @Test func welcomeSendsSessionsAndRepos() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let repoSvc = FakeRepoService()
        await repoSvc.setRepos([
            Repo(name: "lumi", path: "/a/lumi", isGitRepo: true, source: .standalone),
            Repo(name: "beta", path: "/a/beta", isGitRepo: false, source: .standalone),
        ])
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: repoSvc, connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()

        await conn.injectInbound(type: "welcome", payload: [:])
        try await conn.waitForSent(types: ["sessions", "repos"])

        #expect(await conn.repoNames() == ["lumi", "beta"])
        svc.stop()
    }

    @Test func inputWritesToTerminal() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let sid = makeSession(term)
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(), connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()

        await conn.injectInbound(type: "input", payload: ["sessionId": sid, "data": "aGk="]) // "hi"
        try await term.waitForInput()

        let tid = TerminalID(raw: UUID(uuidString: sid)!)
        #expect(term.writtenInput[tid] == "hi".data(using: .utf8))
        svc.stop()
    }

    /// start_session, spawn'dan ÖNCE çalışma alanını güvenli işaretlemeli —
    /// remote claude ilk-açılış güven menüsünde takılıp transcript yazmayı
    /// bırakmasın (chat "yükleniyor"da kalmasın).
    @Test func startSessionMarksWorkspaceTrusted() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let trust = FakeClaudeWorkspaceTrust()
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
                                connection: conn, chatSource: FakeChatTranscriptSource(events: []),
                                trust: trust)
        await svc.start()

        await conn.injectInbound(type: "command", payload: [
            "action": "start_session", "repoPath": "/repo/untrusted",
            "prompt": "merhaba", "commandId": "c1"])
        try await conn.waitForSent(types: ["command_result"])

        #expect(trust.trusted == ["/repo/untrusted"])
        #expect(term.metas.map(\.repoPath) == ["/repo/untrusted"]) // spawn da oldu
        svc.stop()
    }

    @Test func exitedEventCancelsPerSessionDataTask() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        term.scrollback = ("X".data(using: .utf8)!, 80, 24)
        let sid = makeSession(term)
        let tid = TerminalID(raw: UUID(uuidString: sid)!)
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(), connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()

        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid])
        try await conn.waitForSent(types: ["scrollback"])
        term.emitOutput(tid, "A".data(using: .utf8)!)
        try await conn.waitForSent(types: ["data"])
        let dataCountBefore = await conn.count(type: "data")

        // Terminal exit → per-session data task iptal edilmeli
        term.emit(.exited(tid, code: 0))
        // İptalin işlenmesi için kısa bekleme; sonra daha fazla çıktı üret
        try await Task.sleep(for: .milliseconds(50))
        #expect(svc.hasActiveSubscription(tid) == false)
        term.emitOutput(tid, "B".data(using: .utf8)!)

        // Exit sonrası yeni 'data' gelmemeli
        try await conn.waitForNoSent(type: "data", after: dataCountBefore, for: .milliseconds(100))
        svc.stop()
    }

    /// Faz 2 söküm: mode=chat + terminal UUID → chat oturumu yok (NoopChatSessionService nil döndürür).
    /// Eski davranış: transcript-tail başlatılır + feed açılır → SÖKÜLDÜ.
    /// Yeni davranış: boş chat + idle status; scrollback/feed KURULMAZ.
    @Test func subscribeChatModeForTerminalUUIDEmitsEmptyChatAndIdle() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let uuid = UUID()
        let meta = TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo",
                                createdAt: Date(), claudeSessionID: uuid.uuidString)
        term.metas.append(meta)
        let sid = meta.id.description
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
                                connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()

        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat", "chat_status"])
        // Scrollback artık chat modu için kurulmaz (söküm)
        try await conn.waitForNoSent(type: "scrollback", after: 0, for: .milliseconds(150))
        svc.stop()
    }

    /// Faz 2 söküm: terminal UUID + mode=chat → chatSubscription artık KULLANILMIYOR
    /// (chatBridgeTasks string-keyli). Terminal modu exit → feed task iptal edilir.
    @Test func exitedEventCancelsFeedTaskForTerminalMode() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let uuid = UUID()
        let meta = TerminalMeta(id: TerminalID(raw: uuid), name: "T", repoPath: "/repo",
                                createdAt: Date(), claudeSessionID: uuid.uuidString)
        term.metas.append(meta)
        let sid = meta.id.description
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
                                connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()
        // Terminal mode subscribe → feed başlar
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid])
        try await conn.waitForSent(types: ["scrollback"])
        let tid = TerminalID(raw: uuid)
        #expect(svc.hasActiveSubscription(tid) == true)

        term.emit(.exited(tid, code: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(svc.hasActiveSubscription(tid) == false)
        svc.stop()
    }

    /// Faz 2 söküm: mode=chat + terminal UUID (claudeSessionID yok) → boş chat + idle.
    /// Feed başlamaz (scrollback gelmez).
    @Test func chatModeForTerminalWithoutClaudeSessionSendsEmptyChat() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        term.scrollback = ("X".data(using: .utf8)!, 80, 24)
        let sid = makeSession(term)  // claudeSessionID yok
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
                                connection: conn, chatSource: FakeChatTranscriptSource(events: []))
        await svc.start()
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        // Boş chat + idle (scrollback gelmez)
        try await conn.waitForSent(types: ["chat", "chat_status"])
        try await conn.waitForNoSent(type: "scrollback", after: 0, for: .milliseconds(150))
        svc.stop()
    }
}
