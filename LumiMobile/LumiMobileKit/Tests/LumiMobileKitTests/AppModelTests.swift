import XCTest
@testable import LumiMobileKit

final class FakeRelayClient: RelayClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [OutgoingCommand] = []
    private var _started: [PairingInfo] = []
    private var _stopCount = 0
    var sendResult = true
    let stream: AsyncStream<ClientEvent>
    let continuation: AsyncStream<ClientEvent>.Continuation

    var commands: [OutgoingCommand] { lock.withLock { _commands } }
    var started: [PairingInfo] { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func events() async -> AsyncStream<ClientEvent> { stream }
    func start(pairing: PairingInfo) async { lock.withLock { _started.append(pairing) } }
    func stop() async { lock.withLock { _stopCount += 1 } }
    @discardableResult func send(command: OutgoingCommand) async -> Bool {
        let result = lock.withLock { () -> Bool in
            if sendResult { _commands.append(command) }
            return sendResult
        }
        return result
    }
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
        // turn_done clears pinned questions; session still waiting → falls back to generic card
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
        // unpair() clears command state
        XCTAssertTrue(model.lastCommandError.isEmpty)
        XCTAssertEqual(model.startState, .idle)
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

    // MARK: Yeni testler — Fix 1+2

    func testSendTextFailureMarksBubbleFailed() async {
        let (model, client, _) = makeModel()
        client.sendResult = false
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))

        await model.sendText(sessionId: "s1", text: "merhaba")

        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))
        XCTAssertNil(model.lastCommandError["s1"])
    }

    func testStartSessionFailureLandsInFailed() async {
        let (model, client, _) = makeModel()
        client.sendResult = false

        await model.startSession(repoPath: "/r/lumi", personaId: nil, prompt: "merhaba")

        XCTAssertEqual(model.startState, .failed("bağlantı yok"))
    }

    func testHistoryReplacesFeedAndRepinsQuestion() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        // canlı akıştan gelmiş eski bir satır — history bunu da içerir, çiftlenmemeli
        model.handle(.event(.transcript(sessionId: "s1", item: .assistantText("canli"))))

        let question = Question(header: "İzin", question: "Devam?", options: ["Evet", "Hayır"])
        model.handle(.event(.history(sessionId: "s1", items: [
            .assistantText("eski-1"),
            .turnDone,
            .assistantText("canli"),
            .question([question]),
        ])))

        // feed DEĞİŞTİ: history listesi (question feed'e girmez), çiftlenme yok
        XCTAssertEqual((model.feeds["s1"] ?? []).map(\.item),
                       [.assistantText("eski-1"), .turnDone, .assistantText("canli")])
        // id'ler monoton
        let ids = (model.feeds["s1"] ?? []).map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        // waiting + son turn_done'dan sonra soru var → kart yeniden sabitlendi
        XCTAssertEqual(model.questionCard(for: "s1")?.questions, [question])
    }

    func testHistoryDoesNotRepinWhenQuestionAnswered() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .working)], repos: [], personas: [])))
        model.handle(.event(.history(sessionId: "s1", items: [
            .question([Question(header: "h", question: "q", options: [])]),
            .turnDone,
        ])))
        // rozet waiting değil → sabitleme yok; turn_done sorudan sonra → zaten cevaplanmış
        XCTAssertNil(model.questionCard(for: "s1"))
    }

    func testHistoryDoesNotRepinWhenWaitingButQuestionBeforeTurnDone() {
        // rozet waiting AMA soru son turn_done'dan ÖNCE → cevaplanmış, sabitlenmez;
        // waiting sürdüğü için jenerik kart (questions == nil) görünür
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .waitingUnseen)], repos: [], personas: [])))
        model.handle(.event(.history(sessionId: "s1", items: [
            .question([Question(header: "h", question: "q", options: [])]),
            .turnDone,
        ])))
        XCTAssertNil(model.questionCard(for: "s1")?.questions)
    }

    func testHistoryCapsAt200() {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        let items = (0..<250).map { FeedItem.assistantText("m\($0)") }
        model.handle(.event(.history(sessionId: "s1", items: items)))
        XCTAssertEqual(model.feeds["s1"]?.count, 200)
        XCTAssertEqual(model.feeds["s1"]?.last?.item, .assistantText("m249"))
    }

    func testRequestHistorySendsCommandAndFailureIsSilent() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        model.handle(.welcome(Welcome(snapshot: nil, macOnline: true, lastSeenAt: nil)))

        await model.requestHistory(sessionId: "s1")
        XCTAssertEqual(client.commands.count, 1)
        guard case .getHistory(let sid) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")

        // eski Mac: unknown_action → kullanıcıya YANSIMAZ
        model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: false, error: "unknown_action")))
        XCTAssertNil(model.lastCommandError["s1"])
        XCTAssertEqual(model.startState, .idle)
    }

    func testRequestHistoryNoopWhenMacOffline() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        model.handle(.welcome(Welcome(snapshot: nil, macOnline: false, lastSeenAt: nil)))
        await model.requestHistory(sessionId: "s1")
        XCTAssertTrue(client.commands.isEmpty)
    }

    // MARK: Yeni — gönderilen mesaj görünürlüğü + durum

    func testSendTextAppendsOptimisticSendingBubble() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))

        await model.sendText(sessionId: "s1", text: "merhaba")

        let feed = model.feeds["s1"] ?? []
        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed[0].item, .userMessage(text: "merhaba", status: .sending))
        XCTAssertEqual(client.commands.count, 1)
        guard case .sendText(let sid, let text) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(text, "merhaba")
    }

    func testSendTextEmptyIsNoop() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.sendText(sessionId: "s1", text: "   \n ")
        XCTAssertTrue((model.feeds["s1"] ?? []).isEmpty)
        XCTAssertTrue(client.commands.isEmpty)
    }

    func testCommandResultOkMarksBubbleSent() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.sendText(sessionId: "s1", text: "merhaba")
        let commandId = client.commands[0].commandId

        model.handle(.commandResult(CommandResult(commandId: commandId, ok: true, error: nil)))

        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sent))
        XCTAssertNil(model.lastCommandError["s1"], "send_text lastCommandError kullanmaz")
    }

    func testCommandResultFailureMarksBubbleFailed() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.sendText(sessionId: "s1", text: "merhaba")
        let commandId = client.commands[0].commandId

        model.handle(.commandResult(CommandResult(commandId: commandId, ok: false, error: "terminal kapandı")))

        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))
        XCTAssertNil(model.lastCommandError["s1"], "send_text hatası bubble'a yansır, lastCommandError'a değil")
    }

    func testHistoryPreservesLocalUserMessages() async {
        let (model, _, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        // kullanıcı bir mesaj göndersin (iyimser bubble feed'e girsin)
        await model.sendText(sessionId: "s1", text: "kullanici-mesaji")
        let userEntryId = model.feeds["s1"]!.first!.id

        // sonra history gelsin (transcript kullanıcı mesajını İÇERMEZ)
        model.handle(.event(.history(sessionId: "s1", items: [
            .assistantText("eski-1"), .turnDone,
        ])))

        let items = (model.feeds["s1"] ?? []).map(\.item)
        XCTAssertEqual(items, [
            .assistantText("eski-1"),
            .turnDone,
            .userMessage(text: "kullanici-mesaji", status: .sending),
        ])
        // korunan entry'nin id'si değişmedi (commandUserMessages eşlemesi geçerli kalır)
        XCTAssertEqual(model.feeds["s1"]?.last?.id, userEntryId)
    }

    // MARK: Task 3 — retrySend

    func testRetrySendResendsFailedBubble() async {
        let (model, client, _) = makeModel()
        client.sendResult = false
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.sendText(sessionId: "s1", text: "merhaba")
        let entryId = model.feeds["s1"]!.first!.id
        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .failed))

        // bağlantı geri geldi → tekrar dene
        client.sendResult = true
        await model.retrySend(sessionId: "s1", entryId: entryId)

        // aynı bubble tekrar sending'e döndü, YENİ bubble eklenmedi
        XCTAssertEqual(model.feeds["s1"]?.count, 1)
        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sending))
        XCTAssertEqual(client.commands.count, 1)

        // yeni komutun sonucu bubble'ı sent yapar
        model.handle(.commandResult(CommandResult(commandId: client.commands[0].commandId, ok: true, error: nil)))
        XCTAssertEqual(model.feeds["s1"]?.first?.item, .userMessage(text: "merhaba", status: .sent))
    }

    func testDeleteSessionDispatchesCommand() async {
        let (model, client, _) = makeModel()
        model.handle(.snapshot(Snapshot(sessions: [session("s1", repo: "lumi", .idle)], repos: [], personas: [])))
        await model.deleteSession(sessionId: "s1")
        XCTAssertEqual(client.commands.count, 1)
        guard case .deleteSession(let sid) = client.commands[0].action else { return XCTFail() }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(model.sessions.count, 1, "deleteSession iyimser yerel kaldırma yapmaz — snapshot bekler")
    }

    func testDisconnectedStateSetsMacOnlineFalse() async {
        let (model, client, _) = makeModel()
        await model.start()

        // Mac çevrimiçi yap: welcome+snapshot
        client.continuation.yield(.message(.welcome(Welcome(snapshot: nil, macOnline: true, lastSeenAt: nil))))
        for _ in 0..<200 where !model.macOnline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.macOnline, "welcome sonrası mac online olmalı")

        // Bağlantı kesildi
        client.continuation.yield(.stateChanged(.disconnected))
        for _ in 0..<200 where model.macOnline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.macOnline, "disconnected sonrası macOnline false olmalı")
    }
}
