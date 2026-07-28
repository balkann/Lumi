import XCTest
@testable import LumiMobileKit

final class FakeRelayClient: RelayClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [OutgoingCommand] = []
    private var _started: [PairingInfo] = []
    private var _stopCount = 0
    let stream: AsyncStream<ClientEvent>
    let continuation: AsyncStream<ClientEvent>.Continuation

    var commands: [OutgoingCommand] { lock.withLock { _commands } }
    var started: [PairingInfo] { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func events() async -> AsyncStream<ClientEvent> { stream }
    func start(pairing: PairingInfo) async { lock.withLock { _started.append(pairing) } }
    func stop() async { lock.withLock { _stopCount += 1 } }
    func send(command: OutgoingCommand) async { lock.withLock { _commands.append(command) } }
    func registerPush(deviceToken: String) async {}
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

private func session(_ id: String, repo: String, _ status: SessionStatus) -> SessionSummary {
    SessionSummary(id: id, repoPath: "/r/\(repo)", repoName: repo, status: status)
}

@MainActor
final class AppModelTests: XCTestCase {

    func testWelcomeAppliesSnapshotAndOfflineInfo() {
        let (model, _, _) = makeModel()
        let snapshot = Snapshot(sessions: [session("s1", repo: "lumi", .working)],
                                repos: [Repo(name: "lumi", path: "/r/lumi")],
                                personas: [Persona(id: "p", label: "P")])
        model.handle(.welcome(Welcome(snapshot: snapshot, macOnline: false, lastSeenAt: 1_753_660_000_000)))

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.repos.count, 1)
        XCTAssertEqual(model.personas.count, 1)
        XCTAssertFalse(model.macOnline)
        // epoch ms → Date
        XCTAssertEqual(model.lastSeenAt, Date(timeIntervalSince1970: 1_753_660_000))
    }

    func testOrderedSessionsPutWaitingFirstThenErrorWorkingIdle() {
        let (model, _, _) = makeModel()
        let snapshot = Snapshot(sessions: [
            session("a", repo: "alpha", .idle),
            session("b", repo: "beta", .working),
            session("c", repo: "gamma", .waitingUnseen),
            session("d", repo: "delta", .error),
            session("e", repo: "epsilon", .waitingSeen),
        ], repos: [], personas: [])
        model.handle(.snapshot(snapshot))

        // waiting (epsilon, gamma — grup içi repoName alfabetik) → error (delta) → working (beta) → idle (alpha)
        XCTAssertEqual(model.orderedSessions.map(\.repoName), ["epsilon", "gamma", "delta", "beta", "alpha"])
    }

    func testStatusChangeUpdatesSessionAndClearsQuestionWhenWorking() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .question([Question(header: "İzin", question: "Olur mu?", options: ["Evet"])]))))
        XCTAssertNotNil(model.questionCard(for: "s1")?.questions)

        model.handle(.event(.statusChange(sessionId: "s1", status: .working, repoName: "lumi", summary: nil)))
        XCTAssertEqual(model.session("s1")?.status, .working)
        XCTAssertNil(model.questionCard(for: "s1"))
        XCTAssertTrue(model.macOnline, "mac'ten event geldiyse mac online'dır")
    }

    func testTranscriptFeedAppendsAndCapsAt200() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        for i in 0..<210 {
            model.handle(.event(.transcript(sessionId: "s1", item: .assistantText("m\(i)"))))
        }
        let feed = model.feeds["s1"] ?? []
        XCTAssertEqual(feed.count, 200)
        XCTAssertEqual(feed.last?.item, .assistantText("m209"))
        XCTAssertEqual(feed.first?.item, .assistantText("m10"))
        // id'ler monoton artar (ScrollView diff'i için kararlı kimlik)
        XCTAssertEqual(feed.map(\.id), Array(feed.map(\.id)).sorted())
    }

    func testQuestionPinsCardAndTurnDoneClearsIt() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        let questions = [Question(header: "İzin", question: "Bash koşsun mu?", options: ["Evet", "Hayır"])]
        model.handle(.event(.transcript(sessionId: "s1", item: .question(questions))))

        XCTAssertEqual(model.questionCard(for: "s1"), QuestionCard(questions: questions, context: nil))
        // question akışa girmez, kartta yaşar (tasarım §5)
        XCTAssertTrue((model.feeds["s1"] ?? []).isEmpty)

        model.handle(.event(.transcript(sessionId: "s1", item: .turnDone)))
        XCTAssertNil(model.questionCard(for: "s1")?.questions)
    }

    func testGenericCardWhenWaitingWithoutQuestionText() {
        // tasarım §12.3: soru metni yoksa jenerik kart + son tool_use bağlamı
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .toolUse(tool: "Bash", summary: "swift test"))))
        model.handle(.event(.statusChange(sessionId: "s1", status: .waitingUnseen, repoName: "lumi", summary: nil)))

        let card = model.questionCard(for: "s1")
        XCTAssertNotNil(card)
        XCTAssertNil(card?.questions)
        XCTAssertEqual(card?.context, "Bash: swift test")
    }

    func testSendTextRecordsCommandAndClearsQuestion() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        model.handle(.event(.transcript(sessionId: "s1", item: .question([Question(header: "h", question: "q", options: [])]))))

        await model.sendText(sessionId: "s1", text: "evet devam")

        XCTAssertEqual(client.commands.count, 1)
        guard case .sendText(let sid, let text) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(text, "evet devam")
        XCTAssertNil(model.questionCard(for: "s1")?.questions, "cevap verilince kart kalkar")
    }

    func testFailedCommandResultSurfacesErrorForSession() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.pressKey(sessionId: "s1", key: "enter")
        let commandId = client.commands[0].commandId

        model.handle(.commandResult(CommandResult(commandId: commandId, ok: false, error: "terminal kapandı")))
        XCTAssertEqual(model.lastCommandError["s1"], "terminal kapandı")

        // sonraki komut hatayı temizler
        await model.pressKey(sessionId: "s1", key: "1")
        XCTAssertNil(model.lastCommandError["s1"])

        // bilinmeyen commandId (başka telefonun komutu) yok sayılır
        model.handle(.commandResult(CommandResult(commandId: "baska-tel-9", ok: false, error: "x")))
        XCTAssertNil(model.lastCommandError["s1"])
    }

    func testStartSessionLifecycle() async {
        let (model, client, _) = makeModel()
        XCTAssertEqual(model.startState, .idle)

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "merhaba")
        XCTAssertEqual(model.startState, .sending)
        guard case .startSession(let repoPath, let personaId, let prompt) = client.commands[0].action else { return XCTFail() }
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
    }

    func testStartConsumesClientEventStream() async {
        let (model, client, _) = makeModel()
        await model.start()
        XCTAssertEqual(client.started.count, 1, "eşleşme varsa start client'ı başlatır")

        client.continuation.yield(.stateChanged(.connected))
        client.continuation.yield(.message(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: []))))

        // Test @MainActor'da koşar; sleep aktörü bıraktığı için consumeTask ilerler.
        for _ in 0..<200 where !(model.sessions.count == 1 && model.connection == .connected) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.connection, .connected)
    }
}
