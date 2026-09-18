import XCTest
@testable import LumiMobileKit
import LumiWire

final class FakeRelayClient: RelayClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [OutgoingCommand] = []
    private var _frames: [String] = []
    private var _started: [PairingInfo] = []
    private var _stopCount = 0
    var sendResult = true
    let stream: AsyncStream<ClientEvent>
    let continuation: AsyncStream<ClientEvent>.Continuation

    var commands: [OutgoingCommand] { lock.withLock { _commands } }
    var sentFrames: [String] { lock.withLock { _frames } }
    var started: [PairingInfo] { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }

    init() { (stream, continuation) = AsyncStream.makeStream() }

    /// Test yardımcısı: relay'den bir mesaj geldiğini simüle eder.
    func emit(_ message: ServerMessage) { continuation.yield(.message(message)) }

    func events() async -> AsyncStream<ClientEvent> { stream }
    func start(pairing: PairingInfo) async { lock.withLock { _started.append(pairing) } }
    func stop() async { lock.withLock { _stopCount += 1 } }
    @discardableResult func send(command: OutgoingCommand) async -> Bool {
        lock.withLock { () -> Bool in
            if sendResult { _commands.append(command) }
            return sendResult
        }
    }
    @discardableResult func send(frame: String) async -> Bool {
        lock.withLock { () -> Bool in
            if sendResult { _frames.append(frame) }
            return sendResult
        }
    }
    private var _pushRegistrations: [String] = []
    private var _pushUnregistrations: [String] = []
    var pushRegistrations: [String] { lock.withLock { _pushRegistrations } }
    var pushUnregistrations: [String] { lock.withLock { _pushUnregistrations } }
    func registerPush(deviceToken: String) async { lock.withLock { _pushRegistrations.append(deviceToken) } }
    func unregisterPush(deviceToken: String) async { lock.withLock { _pushUnregistrations.append(deviceToken) } }
    /// Test yardımcısı: gönderilen frame'leri temizler (reconnect testlerinde baseline sıfırlamak için).
    func clearSentFrames() { lock.withLock { _frames.removeAll() } }
    /// Test yardımcısı: ClientEvent yayımlar (stateChanged dahil).
    func emit(_ event: ClientEvent) { continuation.yield(event) }
}

@MainActor
private func makeModel(paired: Bool = true) -> (AppModel, FakeRelayClient, InMemorySecureStore) {
    let client = FakeRelayClient()
    let store = InMemorySecureStore()
    if paired {
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
    }
    return (AppModel(client: client, store: store), client, store)
}

@MainActor
private func makeModelP(paired: Bool = true) -> (AppModel, FakeRelayClient, InMemoryPreferenceStore) {
    let client = FakeRelayClient()
    let store = InMemorySecureStore()
    let prefs = InMemoryPreferenceStore()
    if paired { store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")) }
    return (AppModel(client: client, store: store, prefs: prefs), client, prefs)
}

private func meta(_ id: String, repo: String, _ status: String = "idle",
                  title: String? = nil, model: String? = nil,
                  cols: Int = 80, rows: Int = 24) -> SessionMeta {
    SessionMeta(id: id, repoName: repo, status: status, title: title, model: model, cols: cols, rows: rows)
}

private func data(_ id: String, seq: Int, _ text: String) -> TerminalChunk {
    TerminalChunk(sessionId: id, seq: seq, bytes: text.data(using: .utf8)!)
}

@MainActor
final class AppModelTests: XCTestCase {

    // MARK: Terminal byte-routing (Task 8)

    func testRoutesDataToSessionStream() async throws {
        let (model, client, _) = makeModel()
        await model.start()
        model.subscribe("s1")
        var got = Data()
        let stream = model.terminalStream("s1")
        client.emit(.data(data("s1", seq: 1, "hi")))
        for await chunk in stream { got.append(chunk.bytes); break }
        XCTAssertEqual(got, "hi".data(using: .utf8))
        XCTAssertTrue(client.sentFrames.contains { $0.contains(#""type":"subscribe""#) })
    }

    /// Scrollback subscribe ile stream attach arasında geldiyse, yeni stream onu replay eder.
    func testTerminalStreamReplaysBufferedScrollback() async throws {
        let (model, _, _) = makeModel()
        model.subscribe("s1")
        // Stream henüz bağlanmadan scrollback geldi (view geç mount oldu).
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 24,
                                                bytes: "SCROLL".data(using: .utf8)!)))
        // Şimdi view stream'e bağlanır → tamponlanan scrollback replay edilmeli.
        var got = Data()
        let stream = model.terminalStream("s1")
        for await chunk in stream { got.append(chunk.bytes); break }
        XCTAssertEqual(got, "SCROLL".data(using: .utf8))
    }

    /// Terminal-mirror replay tamponu view bağlı değilken cap'te (2048) kalır ve EN
    /// YENİ chunk'lar korunur (head-drop). Uzun-oturum bellek koruması — Faz1'de
    /// eklenen replayBufferCap davranışını kilitler (ChatLiveStripTests sökülünce
    /// buraya taşındı; artık terminal `subscribe` yoluyla exercise edilir).
    func testTerminalReplayBufferIsCappedWhenViewUnattached() async {
        let (model, _, _) = makeModel()
        model.subscribe("s1")
        let cap = 2048
        for i in 0..<(cap + 10) {
            model.handle(.data(TerminalChunk(sessionId: "s1", seq: i, bytes: Data("\(i)".utf8))))
        }
        var got: [TerminalChunk] = []
        for await chunk in model.terminalStream("s1") {
            got.append(chunk)
            if got.count == cap { break }
        }
        XCTAssertEqual(got.count, cap)
        XCTAssertEqual(got.first?.seq, 10)       // en eski 10 düştü
        XCTAssertEqual(got.last?.seq, cap + 9)   // en yeniler korundu
    }

    /// subscribe/unsubscribe/sendInput frame'i bir Task içinde async gönderir; oluşana dek bekler.
    private func awaitFrame(_ client: FakeRelayClient, containing needle: String) async {
        for _ in 0..<200 where !client.sentFrames.contains(where: { $0.contains(needle) }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testSubscribeSetsActiveAndSendsFrame() async {
        let (model, client, _) = makeModel()
        model.subscribe("s1")
        XCTAssertEqual(model.activeSessionId, "s1")
        await awaitFrame(client, containing: #""type":"subscribe""#)
        XCTAssertTrue(client.sentFrames.contains { $0.contains(#""type":"subscribe""#) && $0.contains(#""s1""#) })
    }

    func testUnsubscribeClearsActiveAndSendsFrame() async {
        let (model, client, _) = makeModel()
        model.subscribe("s1")
        model.unsubscribe("s1")
        XCTAssertNil(model.activeSessionId)
        await awaitFrame(client, containing: #""type":"unsubscribe""#)
        XCTAssertTrue(client.sentFrames.contains { $0.contains(#""type":"unsubscribe""#) })
    }

    func testSendInputSendsInputFrame() async {
        let (model, client, _) = makeModel()
        model.sendInput("s1", "hi".data(using: .utf8)!)
        await awaitFrame(client, containing: #""type":"input""#)
        let frame = client.sentFrames.first { $0.contains(#""type":"input""#) }
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame!.contains("aGk="), "input base64 (\"hi\" == aGk=)")
    }

    /// Chat/komut gönderimi: metin ve Enter (CR) AYRI iki input frame'i olmalı,
    /// birleşik `metin\r` DEĞİL. Birleşik write Claude Code TUI'sinde paste ingest'i
    /// tamamlanmadan gelen Enter olarak yutulur ve submit tetiklenmez (orca
    /// runtime-terminal-writer paritesi: text → settle → CR).
    func testSubmitTextSplitsTextAndEnterIntoSeparateFrames() async {
        let (model, client, _) = makeModel()
        model.submitSettle = .zero  // testi hızlandır (gecikme davranışı ayrı)
        model.submitText("s1", "hi")
        await awaitFrame(client, containing: "DQ==")  // CR frame'i (en son gelir)
        let inputs = client.sentFrames.filter { $0.contains(#""type":"input""#) }
        XCTAssertEqual(inputs.count, 2, "metin ve CR ayrı iki input frame olmalı")
        XCTAssertTrue(inputs[0].contains("aGk="), #"ilk frame metin ("hi" == aGk=)"#)
        XCTAssertTrue(inputs[1].contains("DQ=="), #"ikinci frame CR (\r == DQ==)"#)
        XCTAssertFalse(inputs.contains { $0.contains("aGkN") },
                       #"birleşik "hi\r" (== aGkN) frame'i OLMAMALI"#)
    }

    /// unsubscribe ÇAĞRILMADAN başka session'a subscribe edilince eski stream sonlanmalı.
    func testSubscribeSwitchFinishesPreviousStream() async {
        let (model, _, _) = makeModel()
        model.subscribe("s1")
        let s1Stream = model.terminalStream("s1")
        let drained = Task { () -> Int in
            var count = 0
            for await _ in s1Stream { count += 1 }
            return count  // s1 for-await sonlanınca döner
        }

        // unsubscribe olmadan s2'ye geç → s1 sink'i finish edilmeli
        model.subscribe("s2")

        // Geç gelen eski s1 data'sı artık s1 stream'ine yield EDİLMEMELİ.
        model.handle(.data(data("s1", seq: 9, "gec")))

        let count = await drained.value  // finish olmazsa burada takılırdı
        XCTAssertEqual(count, 0, "s1 stream'i chunk almadan sonlanmalı")
        XCTAssertEqual(model.activeSessionId, "s2")
    }

    func testDataForInactiveSessionIsDropped() async {
        let (model, _, _) = makeModel()
        model.subscribe("s1")
        // s2 aktif değil → chunk düşürülür (tampon oluşmaz)
        model.handle(.data(data("s2", seq: 1, "leak")))
        // s2 stream'i bağlanınca bir şey replay edilmemeli — canlı bir chunk yield edip onu okuyalım
        let stream = model.terminalStream("s2")
        model.handle(.data(data("s2", seq: 2, "live")))
        var got = Data()
        for await chunk in stream { got.append(chunk.bytes); break }
        XCTAssertEqual(got, "live".data(using: .utf8), "sadece canlı chunk gelmeli, düşen 'leak' değil")
    }

    // MARK: Session list (welcome/sessions)

    func testWelcomeAppliesSessionsAndOfflineInfo() {
        let (model, _, _) = makeModel()
        model.handle(.welcome(Welcome(macOnline: false, lastSeenAt: 1_753_660_000_000,
                                      sessions: [meta("s1", repo: "lumi", "working")])))
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.repoName, "lumi")
        XCTAssertFalse(model.macOnline)
        XCTAssertEqual(model.lastSeenAt, Date(timeIntervalSince1970: 1_753_660_000))
    }

    func testSessionsMessageUpdatesListAndMarksMacOnline() {
        let (model, _, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "working"), meta("s2", repo: "beta", "idle")]))
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(model.macOnline, "sessions mesajı Mac'ten gelir → online")
    }

    // MARK: Repos (yeni oturum seçici — bug #2)

    func testWelcomeAppliesRepos() {
        let (model, _, _) = makeModel()
        model.handle(.welcome(Welcome(macOnline: true, lastSeenAt: nil, sessions: [],
                                      repos: [Repo(name: "lumi", path: "/a/lumi"),
                                              Repo(name: "beta", path: "/a/beta")])))
        XCTAssertEqual(model.repos.map(\.name), ["lumi", "beta"])
        XCTAssertEqual(model.repos.map(\.path), ["/a/lumi", "/a/beta"])
    }

    func testReposMessageUpdatesListAndMarksMacOnline() {
        let (model, _, _) = makeModel()
        model.handle(.repos([Repo(name: "lumi", path: "/a/lumi")]))
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertTrue(model.macOnline, "repos mesajı Mac'ten gelir → online")
    }

    func testReposDecodeFromWire() {
        let frame = #"{"v":1,"type":"repos","payload":{"repos":[{"name":"lumi","path":"/a/lumi"}]}}"#
        guard case .repos(let repos)? = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("repos frame decode edilemedi")
        }
        XCTAssertEqual(repos, [Repo(name: "lumi", path: "/a/lumi")])
    }

    func testOrderedSessionsPutWaitingFirstThenErrorWorkingIdle() {
        let (model, _, _) = makeModel()
        model.handle(.sessions([
            meta("a", repo: "alpha", "idle"),
            meta("b", repo: "beta", "working"),
            meta("c", repo: "gamma", "waiting-unseen"),
            meta("d", repo: "delta", "error"),
            meta("e", repo: "epsilon", "waiting-seen"),
        ]))
        XCTAssertEqual(model.orderedSessions.map(\.repoName), ["epsilon", "gamma", "delta", "beta", "alpha"])
    }

    func testSessionsCloseClearsActiveSink() async {
        let (model, _, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "working")]))
        model.subscribe("s1")
        let stream = model.terminalStream("s1")
        // s1 kapandı: yeni sessions listesinde yok → sink finish → stream biter
        model.handle(.sessions([meta("s2", repo: "beta", "idle")]))
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "kapanan oturumun stream'i sonlanmalı")
    }

    // MARK: Model tracking (SessionMeta.model)

    func testSessionsAppliesModel() {
        let (model, _, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "working", model: "claude-sonnet-4-6")]))
        XCTAssertEqual(model.currentModel(for: "s1"), "claude-sonnet-4-6")
    }

    func testModelPersistsWhenLaterSessionsOmitsModel() {
        let (model, _, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "working", model: "claude-opus-4-8")]))
        model.handle(.sessions([meta("s1", repo: "lumi", "idle")]))  // model alanı yok
        XCTAssertEqual(model.currentModel(for: "s1"), "claude-opus-4-8", "model kalıcı bilgidir")
    }

    func testSetModelDispatchesCommand() async {
        let (model, client, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "working")]))
        await model.setModel(sessionId: "s1", model: "sonnet")
        XCTAssertEqual(client.commands.count, 1)
        guard case .setModel(let sid, let m) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(m, "sonnet")
    }

    func testModelLabelPrettify() {
        let (model, _, _) = makeModel()
        XCTAssertEqual(model.modelLabel("claude-opus-4-8"), "Opus")
        XCTAssertEqual(model.modelLabel("claude-sonnet-4-6"), "Sonnet")
        XCTAssertEqual(model.modelLabel("claude-haiku-4-5"), "Haiku")
        XCTAssertEqual(model.modelLabel("weird-id"), "weird-id")
    }

    // MARK: Commands (start/delete + command_result)

    func testStartSessionLifecycle() async {
        let (model, client, _) = makeModel()
        XCTAssertEqual(model.startState, .idle)

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "merhaba")
        XCTAssertEqual(model.startState, .sending)
        guard case .startSession(let repoPath, let personaId, let prompt, _) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(repoPath, "/r/lumi")
        XCTAssertNil(personaId)
        XCTAssertEqual(prompt, "merhaba")

        model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: true, error: nil)))
        XCTAssertEqual(model.startState, .succeeded)

        model.resetStartState()
        XCTAssertEqual(model.startState, .idle)

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "p")
        model.handle(.commandResult(CommandResult(commandId: client.commands[1].commandId, ok: false, error: "mac_offline")))
        XCTAssertEqual(model.startState, .failed("mac_offline"))
    }

    func testStartSessionFailureLandsInFailed() async {
        let (model, client, _) = makeModel()
        client.sendResult = false
        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "merhaba")
        XCTAssertEqual(model.startState, .failed("bağlantı yok"))
    }

    func testFailedCommandResultSurfacesErrorForSession() async {
        let (model, client, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "idle")]))
        await model.deleteSession(sessionId: "s1")
        let commandId = client.commands[0].commandId

        model.handle(.commandResult(CommandResult(commandId: commandId, ok: false, error: "terminal kapandı")))
        XCTAssertEqual(model.lastCommandError["s1"], "terminal kapandı")

        // sonraki komut hatayı temizler
        await model.deleteSession(sessionId: "s1")
        XCTAssertNil(model.lastCommandError["s1"])

        // bilinmeyen commandId (başka telefonun komutu) yok sayılır
        model.handle(.commandResult(CommandResult(commandId: "baska-tel-9", ok: false, error: "x")))
        XCTAssertNil(model.lastCommandError["s1"])
    }

    func testDeleteSessionDispatchesCommand() async {
        let (model, client, _) = makeModel()
        model.handle(.sessions([meta("s1", repo: "lumi", "idle")]))
        await model.deleteSession(sessionId: "s1")
        XCTAssertEqual(client.commands.count, 1)
        guard case .deleteSession(let sid) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(model.sessions.count, 1, "deleteSession iyimser yerel kaldırma yapmaz — sessions bekler")
    }

    // MARK: Yaşam döngüsü / bağlantı

    func testStartConsumesClientEventStream() async {
        let (model, client, _) = makeModel()
        await model.start()
        XCTAssertEqual(client.started.count, 1, "eşleşme varsa start client'ı başlatır")

        client.continuation.yield(.stateChanged(.connected))
        client.continuation.yield(.message(.sessions([meta("s1", repo: "lumi", "idle")])))

        for _ in 0..<200 where !(model.sessions.count == 1 && model.connection == .connected) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.connection, .connected)
    }

    func testDisconnectedStateSetsMacOnlineFalse() async {
        let (model, client, _) = makeModel()
        await model.start()

        client.continuation.yield(.message(.welcome(Welcome(macOnline: true, lastSeenAt: nil))))
        for _ in 0..<200 where !model.macOnline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.macOnline, "welcome sonrası mac online olmalı")

        client.continuation.yield(.stateChanged(.disconnected))
        for _ in 0..<200 where model.macOnline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.macOnline, "disconnected sonrası macOnline false olmalı")
    }

    func testPairStartsClientAndUnpairStops() async {
        let (model, client, store) = makeModel(paired: false)
        XCTAssertFalse(model.isPaired)

        let bad = await model.pair(from: "gecersiz")
        XCTAssertFalse(bad)

        let ok = await model.pair(from: "lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=0123456789abcdef")
        XCTAssertTrue(ok)
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(store.read()?.token, "0123456789abcdef")
        XCTAssertEqual(client.started.map(\.relayUrl), ["wss://r.example"])

        await model.unpair()
        XCTAssertFalse(model.isPaired)
        XCTAssertNil(store.read())
        XCTAssertGreaterThanOrEqual(client.stopCount, 1)
        XCTAssertTrue(model.lastCommandError.isEmpty)
        XCTAssertNil(model.activeSessionId)
        XCTAssertEqual(model.startState, .idle)
    }

    // MARK: Push state (Task 4 — korunur)

    func testApplyPushTokenRegistersWhenEnabled() async {
        let (model, client, prefs) = makeModelP()
        prefs.set(true, forKey: "notificationsEnabled")
        let model2 = AppModel(client: client, store: InMemorySecureStore(), prefs: prefs)
        XCTAssertTrue(model2.notificationsEnabled)
        await model2.applyPushToken("tok-1")
        XCTAssertEqual(client.pushRegistrations, ["tok-1"])
        _ = model
    }

    func testApplyPushTokenNoRegisterWhenDisabled() async {
        let (model, client, _) = makeModelP()
        XCTAssertFalse(model.notificationsEnabled)
        await model.applyPushToken("tok-1")
        XCTAssertTrue(client.pushRegistrations.isEmpty)
    }

    func testMarkEnabledTrueRegistersTokenAndPersists() async {
        let (model, client, prefs) = makeModelP()
        await model.applyPushToken("tok-1")
        await model.markNotificationsEnabled(true)
        XCTAssertTrue(model.notificationsEnabled)
        XCTAssertTrue(prefs.bool(forKey: "notificationsEnabled"))
        XCTAssertEqual(client.pushRegistrations, ["tok-1"])
    }

    func testMarkEnabledFalseUnregistersToken() async {
        let (model, client, prefs) = makeModelP()
        await model.applyPushToken("tok-1")
        await model.markNotificationsEnabled(true)
        await model.markNotificationsEnabled(false)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
        XCTAssertEqual(client.pushUnregistrations, ["tok-1"])
    }

    func testReRegisterAfterWelcomeWhenEnabled() async {
        let (model, client, _) = makeModelP()
        await model.applyPushToken("tok-1")
        await model.markNotificationsEnabled(true)
        await model.reRegisterPushIfNeeded()
        XCTAssertEqual(client.pushRegistrations, ["tok-1", "tok-1"])
    }

    // MARK: Reconnect subscription replay (Task 11)

    /// Bağlantı kopup yeniden kurulunca aktif session için otomatik yeniden subscribe gönderilmeli.
    func testResubscribesActiveSessionOnReconnect() async throws {
        let (model, client, _) = makeModel()
        await model.start()
        model.subscribe("s1")
        // subscribe frame'ini temizle — sadece yeniden bağlantı sonrası frame'i izle.
        await awaitFrame(client, containing: #""type":"subscribe""#)
        client.clearSentFrames()
        // Bağlantı kopar sonra yeniden kurulur.
        client.emit(.stateChanged(.disconnected))
        client.emit(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(
            client.sentFrames.contains { $0.contains(#""type":"subscribe""#) && $0.contains("s1") },
            "reconnect sonrası s1 için yeniden subscribe frame'i gönderilmeli"
        )
    }

    /// Chat modunda kopup dönünce reconnect TERMINAL değil CHAT modunda yeniden
    /// subscribe etmeli — aksi halde chat sessizce terminale düşer ve mesajlar
    /// telefona gelmez (handoff #6).
    func testResubscribesInChatModeOnReconnectWhenChatActive() async throws {
        let (model, client, _) = makeModel()
        await model.start()
        model.subscribeChat("s1")
        await awaitFrame(client, containing: #""mode":"chat""#)
        client.clearSentFrames()
        client.emit(.stateChanged(.disconnected))
        client.emit(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(50))
        let sub = client.sentFrames.first { $0.contains(#""type":"subscribe""#) && $0.contains("s1") }
        XCTAssertNotNil(sub, "reconnect sonrası s1 için yeniden subscribe gönderilmeli")
        XCTAssertTrue(sub!.contains(#""mode":"chat""#),
                      "chat modunda reconnect chat modunda yeniden subscribe etmeli, terminale düşmemeli")
    }

    /// Terminal modunda reconnect terminal modunda kalmalı (chat'e sızmamalı).
    func testResubscribesInTerminalModeOnReconnectWhenTerminalActive() async throws {
        let (model, client, _) = makeModel()
        await model.start()
        model.subscribe("s1")
        await awaitFrame(client, containing: #""type":"subscribe""#)
        client.clearSentFrames()
        client.emit(.stateChanged(.disconnected))
        client.emit(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(50))
        let sub = client.sentFrames.first { $0.contains(#""type":"subscribe""#) && $0.contains("s1") }
        XCTAssertNotNil(sub)
        XCTAssertTrue(sub!.contains(#""mode":"terminal""#), "terminal modunda reconnect terminal kalmalı")
    }

    /// Aktif session yokken bağlantı kurulunca subscribe frame'i gönderilmemeli.
    func testNoResubscribeWhenNoActiveSessionOnConnect() async throws {
        let (model, client, _) = makeModel()
        await model.start()
        // Hiç subscribe yapılmadı — activeSessionId nil.
        client.emit(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            client.sentFrames.contains { $0.contains(#""type":"subscribe""#) },
            "aktif session yokken connected'da subscribe frame'i gönderilmemeli"
        )
    }

    // MARK: Chat durumu + append merge (Task 10)

    func testChatSnapshotThenAppendMerges() async {
        let (model, _, _) = makeModel()
        let m1 = ChatMessage(id: "m1", role: .user, blocks: [.text("hi", presentation: nil)], timestampMs: nil, turnId: nil)
        let m2 = ChatMessage(id: "m2", role: .assistant, blocks: [.text("yo", presentation: nil)], timestampMs: nil, turnId: nil)
        model.handle(.chat(sessionId: "s1", messages: [m1]))
        XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1"])
        model.handle(.chatAppend(sessionId: "s1", messages: [m2]))
        XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1", "m2"])
        // Aynı id tekrar gelirse güncellenir, çoğalmaz.
        let m2b = ChatMessage(id: "m2", role: .assistant, blocks: [.text("yo!", presentation: nil)], timestampMs: nil, turnId: nil)
        model.handle(.chatAppend(sessionId: "s1", messages: [m2b]))
        XCTAssertEqual(model.chatMessages("s1").map(\.id), ["m1", "m2"])
        XCTAssertEqual(model.chatMessages("s1").last?.blocks, [.text("yo!", presentation: nil)])
    }

    func testSubscribeChatSendsModeFrame() async {
        let (model, client, _) = makeModel()
        model.subscribeChat("s1")
        await awaitFrame(client, containing: "\"mode\":\"chat\"")
        XCTAssertTrue(client.sentFrames.contains { $0.contains("\"mode\":\"chat\"") })
    }

    // MARK: chat_send routing (Faz 2 Task 4)

    /// Chat türü oturumda submitText → chat_send frame'i (PTY input DEĞİL).
    func testSubmitTextSendsChatSendFrameForChatSession() async {
        let (model, client, _) = makeModel()
        // Chat oturumu olarak işaretle (kind = "chat")
        model.handle(.sessions([
            SessionMeta(id: "s1", repoName: "lumi", status: "working",
                        cols: 80, rows: 24, kind: "chat")
        ]))
        model.subscribeChat("s1")
        model.submitText("s1", "merhaba")
        // chat_send frame'ini bekle
        await awaitFrame(client, containing: "\"type\":\"chat_send\"")
        let chatSend = client.sentFrames.first { $0.contains("\"type\":\"chat_send\"") }
        XCTAssertNotNil(chatSend, "chat oturumunda submitText chat_send frame'i göndermeli")
        XCTAssertTrue(chatSend!.contains("merhaba"), "chat_send içinde metin olmalı")
        // PTY input frame'i gönderilmemeli
        XCTAssertFalse(client.sentFrames.contains { $0.contains("\"type\":\"input\"") },
                       "chat oturumunda PTY input frame'i GÖNDERİLMEMELİ")
    }

    /// Terminal oturumunda submitText mevcut PTY yolunu korumalı (chat_send değil).
    func testSubmitTextKeepsTerminalRouteForTerminalSession() async {
        let (model, client, _) = makeModel()
        // Terminal oturumu (kind yok)
        model.handle(.sessions([meta("s1", repo: "lumi", "working")]))
        model.subscribe("s1")
        model.submitSettle = .zero
        model.submitText("s1", "ls")
        await awaitFrame(client, containing: "\"type\":\"input\"")
        XCTAssertTrue(client.sentFrames.contains { $0.contains("\"type\":\"input\"") },
                      "terminal oturumunda input frame'i gönderilmeli")
        XCTAssertFalse(client.sentFrames.contains { $0.contains("\"type\":\"chat_send\"") },
                       "terminal oturumunda chat_send frame'i GÖNDERİLMEMELİ")
    }

    // MARK: chatStreamingText (Faz 2 Task 4)

    /// chat_status streamingText → chatStreamingText working+leading → görünür.
    func testChatStreamingTextVisibleWhenWorkingAndLeading() {
        let (model, _, _) = makeModel()
        // Bir assistant mesajı var
        let m1 = ChatMessage(id: "m1", role: .assistant,
                             blocks: [.text("Selam", presentation: nil)],
                             timestampMs: nil, turnId: nil)
        model.handle(.chat(sessionId: "s1", messages: [m1]))
        // Streaming metni son assistant metnini geçiyor → görünür
        model.handle(.chatStatus(sessionId: "s1",
            status: ChatTurnStatus(working: true, startedAtMs: 10, tool: nil,
                                   streamingText: "Selam dünya")))
        XCTAssertEqual(model.chatStreamingText("s1"), "Selam dünya")
    }

    /// chat_status streamingText ≤ son assistant metni → nil (transcript yerleşti).
    func testChatStreamingTextNilWhenCaughtUp() {
        let (model, _, _) = makeModel()
        let m1 = ChatMessage(id: "m1", role: .assistant,
                             blocks: [.text("Selam dünya", presentation: nil)],
                             timestampMs: nil, turnId: nil)
        model.handle(.chat(sessionId: "s1", messages: [m1]))
        model.handle(.chatStatus(sessionId: "s1",
            status: ChatTurnStatus(working: true, startedAtMs: 10, tool: nil,
                                   streamingText: "Selam")))
        XCTAssertNil(model.chatStreamingText("s1"), "streaming kısa — transcript yerleşti, nil döner")
    }

    /// working=false → streaming nil.
    func testChatStreamingTextNilWhenIdle() {
        let (model, _, _) = makeModel()
        model.handle(.chatStatus(sessionId: "s1",
            status: ChatTurnStatus(working: false, startedAtMs: nil, tool: nil,
                                   streamingText: "x")))
        XCTAssertNil(model.chatStreamingText("s1"), "idle → nil")
    }

    // MARK: startChatSession (Faz 2 Task 4)

    /// startChatSession start_session komutunu kind=chat ile gönderir.
    func testStartChatSessionSendsKindChat() async {
        let (model, client, _) = makeModel()
        await model.startChatSession(repoPath: "/r/lumi")
        XCTAssertEqual(model.startState, .sending)
        XCTAssertEqual(client.commands.count, 1)
        guard case .startSession(let repoPath, _, _, _) = client.commands[0].action else {
            return XCTFail("startChatSession startSession action göndermeli")
        }
        XCTAssertEqual(repoPath, "/r/lumi")
        // kind=chat payload'da olmalı — commandFrame'in JSON çıktısını kontrol et
        let frame = PhoneProtocol.commandFrame(client.commands[0])
        XCTAssertTrue(frame.contains("\"kind\":\"chat\""), "start_session payload'ında kind:chat olmalı")
    }

    /// startChatSession commandResult sessionId → subscribeChat otomatik çağrılır.
    /// Final review #1 regresyonu: chat oturumu başlatıldıktan sonra kullanıcının
    /// yazdığı İKİNCİ mesaj `chat_send` olarak gitmeli — `sessions` broadcast'i elle
    /// enjekte EDİLMEDEN (yerel chatSessionIds routing'i). Aksi halde mesaj sessizce
    /// PTY input yoluna düşerdi ("ikinci mesaj ölü" bugı).
    func testSubmitTextRoutesChatSendAfterStartWithoutSessionsBroadcast() async {
        let (model, client, _) = makeModel()
        await model.startChatSession(repoPath: "/r/lumi")
        let commandId = client.commands[0].commandId
        model.handle(.commandResult(CommandResult(commandId: commandId, ok: true,
                                                   error: nil, sessionId: "chat-xyz")))
        // sessions frame'i HİÇ gelmedi; yine de chat_send'e yönlenmeli.
        model.submitText("chat-xyz", "ikinci mesaj")
        await awaitFrame(client, containing: "\"type\":\"chat_send\"")
        let sent = client.sentFrames.first { $0.contains("\"type\":\"chat_send\"") }
        XCTAssertNotNil(sent, "chat oturumunda submitText chat_send yollamalı (sessions broadcast'i olmadan)")
        XCTAssertTrue(sent!.contains("ikinci mesaj"))
        // PTY input yoluna DÜŞMEMELİ:
        XCTAssertFalse(client.sentFrames.contains { $0.contains("\"type\":\"input\"") },
                       "chat oturumunda input frame'i gönderilmemeli")
    }

    func testStartChatSessionSubscribesChatOnSuccess() async {
        let (model, client, _) = makeModel()
        await model.startChatSession(repoPath: "/r/lumi")
        let commandId = client.commands[0].commandId
        // Mac sessionId ile ok döndürür
        model.handle(.commandResult(CommandResult(commandId: commandId, ok: true,
                                                   error: nil, sessionId: "new-session-42")))
        XCTAssertEqual(model.startState, .succeeded)
        // subscribeChat frame'i gönderilmeli
        await awaitFrame(client, containing: "\"mode\":\"chat\"")
        let sub = client.sentFrames.first {
            $0.contains("\"type\":\"subscribe\"") && $0.contains("\"mode\":\"chat\"")
        }
        XCTAssertNotNil(sub, "startChatSession başarıyla döndükten sonra chat subscribe gönderilmeli")
        XCTAssertTrue(sub!.contains("new-session-42"), "subscribe new-session-42 için olmalı")
    }
}
