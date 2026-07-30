import Foundation
import Observation

/// Akışta gösterilen tek öğe; `id` monoton artar (ScrollView kimliği için).
public struct FeedEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let item: FeedItem
}

/// Oturum detayında sabitlenen cevap kartı.
/// `questions == nil` → jenerik kart (tasarım §12.3): "izin bekliyor" + son tool_use bağlamı.
/// `isPermission == true` → araç izni bekleniyor (Task 3); Task 4 bunu görsel olarak ayırt eder.
public struct QuestionCard: Sendable, Equatable {
    public let questions: [Question]?
    public let context: String?
    public let isPermission: Bool

    public init(questions: [Question]?, context: String?, isPermission: Bool = false) {
        self.questions = questions
        self.context = context
        self.isPermission = isPermission
    }
}

public enum StartSessionState: Sendable, Equatable {
    case idle, sending, succeeded
    case failed(String)
}

/// Tek view-model: RelayClient olaylarını UI durumuna indirger, komutları yollar.
/// istemci→model AsyncStream, model→UI @Observable (repo kalıbı; Combine yok).
@Observable @MainActor
public final class AppModel {
    public private(set) var isPaired: Bool
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var macOnline = false
    public private(set) var lastSeenAt: Date?
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var repos: [Repo] = []
    public private(set) var personas: [Persona] = []
    public private(set) var feeds: [String: [FeedEntry]] = [:]
    public private(set) var lastCommandError: [String: String] = [:]
    public private(set) var startState: StartSessionState = .idle
    public private(set) var notificationsEnabled: Bool
    public private(set) var notificationAuthStatus: NotificationAuthStatus = .notDetermined
    public weak var pushControl: (any PushControlling)?

    private let client: any RelayClienting
    private let store: any SecureStore
    private let prefs: any PreferenceStore
    private var latestPushToken: String?
    private static let notificationsKey = "notificationsEnabled"
    private var consumeTask: Task<Void, Never>?
    private var commandCounter = 0
    private var feedCounter = 0
    private var activeQuestions: [String: [Question]] = [:]
    /// sessionId → araç izni bekleniyor; nil = beklemiyor.
    private var decisionPending: [String: Bool] = [:]
    /// sessionId → mevcut model id'si; kalıcı bilgi (statusChange temizlemez).
    private var models: [String: String] = [:]
    /// commandId → sessionId; start_session için "" (oturum henüz yok).
    private var commandTargets: [String: String] = [:]
    private var historyCommandIds: Set<String> = []
    /// commandId → gönderilen kullanıcı mesajının FeedEntry.id'si (durum güncellemesi için).
    private var commandUserMessages: [String: Int] = [:]
    private static let feedCap = 200

    public init(client: any RelayClienting, store: any SecureStore, prefs: any PreferenceStore = UserDefaultsPreferenceStore()) {
        self.client = client
        self.store = store
        self.prefs = prefs
        self.isPaired = store.read() != nil
        self.notificationsEnabled = prefs.bool(forKey: Self.notificationsKey)
    }

    // MARK: Yaşam döngüsü

    public func start() async {
        guard consumeTask == nil, let pairing = store.read() else { return }
        let stream = await client.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let state):
                    self.connection = state
                    if state == .disconnected { self.macOnline = false }
                case .message(let message):
                    self.handle(message)
                    if case .welcome = message { await self.reRegisterPushIfNeeded() }
                }
            }
        }
        await client.start(pairing: pairing)
    }

    @discardableResult
    public func pair(from string: String) async -> Bool {
        guard let info = Pairing.parse(string) else { return false }
        store.write(info)
        isPaired = true
        await client.stop()
        consumeTask?.cancel()
        consumeTask = nil
        await start()
        await pushControl?.onPairingSucceeded()
        return true
    }

    public func unpair() async {
        store.clear()
        isPaired = false
        consumeTask?.cancel()
        consumeTask = nil
        await client.stop()
        connection = .disconnected
        macOnline = false
        sessions = []
        feeds = [:]
        activeQuestions = [:]
        decisionPending = [:]
        models = [:]
        lastCommandError = [:]
        commandTargets = [:]
        commandUserMessages = [:]
        historyCommandIds = []
        startState = .idle
    }

    // MARK: Gelen mesajlar

    public func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let welcome):
            macOnline = welcome.macOnline
            lastSeenAt = welcome.lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if let snapshot = welcome.snapshot { apply(snapshot) }

        case .snapshot(let snapshot):
            // snapshot'ı yalnız Mac gönderebilir → Mac online.
            macOnline = true
            apply(snapshot)

        case .event(.statusChange(let sessionId, let status, _, _)):
            macOnline = true
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].status = status
            }
            // Soru cevaplanmış / tur ilerlemiş demektir.
            if status.badge == .working || status.badge == .idle {
                activeQuestions[sessionId] = nil
                decisionPending[sessionId] = nil
            }

        case .event(.transcript(let sessionId, let item)):
            macOnline = true
            switch item {
            case .question(let questions):
                activeQuestions[sessionId] = questions
            case .turnDone:
                activeQuestions[sessionId] = nil
                appendFeed(sessionId, item)
            case .assistantText, .toolUse:
                appendFeed(sessionId, item)
            case .userMessage:
                break // transcript kullanıcı mesajı üretmez
            }

        case .event(.history(let sessionId, let items)):
            macOnline = true
            applyHistory(sessionId: sessionId, items: items)

        case .event(.awaitingDecision(let sessionId, let awaiting)):
            macOnline = true
            decisionPending[sessionId] = awaiting ? true : nil

        case .event(.modelChange(let sessionId, let model)):
            macOnline = true
            models[sessionId] = model

        case .commandResult(let result):
            if historyCommandIds.remove(result.commandId) != nil {
                return // geçmiş isteğinin sonucu kullanıcıya yansıtılmaz (ok da olsa hata da)
            }
            if let entryId = commandUserMessages.removeValue(forKey: result.commandId) {
                commandTargets.removeValue(forKey: result.commandId)
                setUserMessageStatus(entryId, result.ok ? .sent : .failed)
                return
            }
            guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
            if target.isEmpty {
                startState = result.ok ? .succeeded : .failed(result.error ?? "oturum açılamadı")
            } else if !result.ok {
                lastCommandError[target] = result.error ?? "komut iletilemedi"
            }

        case .pong:
            break
        }
    }

    // MARK: Türetilmiş durum

    /// `waiting` üstte (tasarım §4.3), sonra error/working/idle; grup içi repo adına göre.
    public var orderedSessions: [SessionSummary] {
        func priority(_ badge: Badge) -> Int {
            switch badge {
            case .waiting: 0
            case .error: 1
            case .working: 2
            case .idle: 3
            }
        }
        return sessions.sorted { a, b in
            let pa = priority(a.status.badge), pb = priority(b.status.badge)
            if pa != pb { return pa < pb }
            return a.repoName.localizedCaseInsensitiveCompare(b.repoName) == .orderedAscending
        }
    }

    public func session(_ id: String) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    public func questionCard(for sessionId: String) -> QuestionCard? {
        // (1) Gerçek soru aktifse → soru kartı (badge bağımsız)
        if let questions = activeQuestions[sessionId] {
            return QuestionCard(questions: questions, context: nil)
        }
        // (2) İzin kararı bekleniyor → izin kartı (badge bağımsız)
        if decisionPending[sessionId] == true {
            return QuestionCard(questions: nil, context: lastToolContext(sessionId), isPermission: true)
        }
        // (3) Waiting rozeti → jenerik kart
        guard session(sessionId)?.status.badge == .waiting else { return nil }
        return QuestionCard(questions: nil, context: lastToolContext(sessionId))
    }

    /// Feed'deki son tool_use öğesinin bağlam dizgesi, yoksa nil.
    private func lastToolContext(_ sessionId: String) -> String? {
        (feeds[sessionId] ?? []).reversed().compactMap { entry -> String? in
            if case .toolUse(let tool, let summary) = entry.item { return "\(tool): \(summary)" }
            return nil
        }.first
    }

    // MARK: Komutlar

    public func sendText(sessionId: String, text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entryId = appendUserMessage(sessionId, text: text)
        await dispatch(target: sessionId,
                       action: .sendText(sessionId: sessionId, text: text),
                       userMessageEntryId: entryId)
    }

    public func pressKey(sessionId: String, key: String) async {
        await dispatch(target: sessionId, action: .pressKey(sessionId: sessionId, key: key))
    }

    public func startSession(repoPath: String, personaId: String?, prompt: String) async {
        startState = .sending
        await dispatch(target: "", action: .startSession(repoPath: repoPath, personaId: personaId, prompt: prompt))
    }

    public func resetStartState() {
        startState = .idle
    }

    public func deleteSession(sessionId: String) async {
        await dispatch(target: sessionId, action: .deleteSession(sessionId: sessionId))
    }

    public func currentModel(for sessionId: String) -> String? {
        models[sessionId]
    }

    public func setModel(sessionId: String, model: String) async {
        await dispatch(target: sessionId, action: .setModel(sessionId: sessionId, model: model))
    }

    /// Ham model id'sini kısa etikete indirger (UI).
    public func modelLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        return raw
    }

    public func registerPush(deviceToken: String) async {
        await client.registerPush(deviceToken: deviceToken)
    }

    public func applyPushToken(_ hex: String) async {
        latestPushToken = hex
        if notificationsEnabled { await client.registerPush(deviceToken: hex) }
    }

    public func setNotificationAuthStatus(_ status: NotificationAuthStatus) {
        notificationAuthStatus = status
    }

    public func markNotificationsEnabled(_ on: Bool) async {
        notificationsEnabled = on
        prefs.set(on, forKey: Self.notificationsKey)
        guard let token = latestPushToken else { return }
        if on { await client.registerPush(deviceToken: token) }
        else { await client.unregisterPush(deviceToken: token) }
    }

    public func enableNotifications() async -> EnableResult {
        await pushControl?.enable() ?? .declined
    }

    public func disableNotifications() async {
        await pushControl?.disable()
    }

    public func reRegisterPushIfNeeded() async {
        guard notificationsEnabled, let token = latestPushToken else { return }
        await client.registerPush(deviceToken: token)
    }

    /// Başarısız bir kullanıcı mesajı baloncuğuna dokununca aynı entry'yi tekrar gönderir.
    public func retrySend(sessionId: String, entryId: Int) async {
        guard let feed = feeds[sessionId],
              let idx = feed.firstIndex(where: { $0.id == entryId }),
              case .userMessage(let text, _) = feed[idx].item else { return }
        setUserMessageStatus(entryId, .sending)
        await dispatch(target: sessionId,
                       action: .sendText(sessionId: sessionId, text: text),
                       userMessageEntryId: entryId)
    }

    /// Oturum detayı açılınca çağrılır: transcript geçmişini ister.
    /// Başarısızlık kullanıcıya yansıtılmaz (eski Mac `unknown_action`,
    /// eşleşmesiz oturum `no_transcript` döndürebilir — ikisi de normaldir).
    public func requestHistory(sessionId: String) async {
        guard macOnline else { return }
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        historyCommandIds.insert(commandId)
        await client.send(command: OutgoingCommand(
            commandId: commandId, action: .getHistory(sessionId: sessionId)))
    }

    private func applyHistory(sessionId: String, items: [FeedItem]) {
        var entries: [FeedEntry] = []
        for item in items {
            switch item {
            case .question, .userMessage:
                continue // sorular karta gider; userMessage transcript'te olmaz
            default:
                feedCounter += 1
                entries.append(FeedEntry(id: feedCounter, item: item))
            }
        }
        // yerelde eklenen kullanıcı mesajlarını koru (id/status ile) — history'nin sonuna
        let userEntries = (feeds[sessionId] ?? []).filter {
            if case .userMessage = $0.item { return true }
            return false
        }
        entries.append(contentsOf: userEntries)
        if entries.count > Self.feedCap {
            entries.removeFirst(entries.count - Self.feedCap)
        }
        feeds[sessionId] = entries

        // waiting rozetli oturumda son turn_done'dan SONRAKİ soru hâlâ açıktır → sabitle
        guard session(sessionId)?.status.badge == .waiting else { return }
        var openQuestion: [Question]?
        for item in items {
            switch item {
            case .question(let questions): openQuestion = questions
            case .turnDone: openQuestion = nil
            default: break
            }
        }
        if let openQuestion {
            activeQuestions[sessionId] = openQuestion
        }
    }

    // MARK: Yardımcılar

    private func dispatch(target: String, action: CommandAction, userMessageEntryId: Int? = nil) async {
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        commandTargets[commandId] = target
        if let userMessageEntryId { commandUserMessages[commandId] = userMessageEntryId }
        if !target.isEmpty {
            lastCommandError[target] = nil
            activeQuestions[target] = nil // cevap verildi → kart kalkar
            decisionPending[target] = nil
        }
        let ok = await client.send(command: OutgoingCommand(commandId: commandId, action: action))
        if !ok {
            commandTargets[commandId] = nil
            commandUserMessages[commandId] = nil
            if let userMessageEntryId {
                setUserMessageStatus(userMessageEntryId, .failed)
            } else if target.isEmpty {
                startState = .failed("bağlantı yok")
            } else {
                lastCommandError[target] = "bağlantı yok"
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        sessions = snapshot.sessions
        repos = snapshot.repos
        personas = snapshot.personas
        let liveIds = Set(snapshot.sessions.map(\.id))
        feeds = feeds.filter { liveIds.contains($0.key) }
        activeQuestions = activeQuestions.filter { liveIds.contains($0.key) }
        lastCommandError = lastCommandError.filter { liveIds.contains($0.key) }
        models = models.filter { liveIds.contains($0.key) }
        for s in snapshot.sessions {
            if let m = s.model { models[s.id] = m }
        }
        // decisionPending: snapshot'tan gelen awaitingDecision alanlarına göre yeniden oluştur.
        decisionPending = decisionPending.filter { liveIds.contains($0.key) }
        for s in snapshot.sessions where s.awaitingDecision {
            decisionPending[s.id] = true
        }
        // snapshot'ta awaiting=false olan oturumların pending'ini temizle
        for s in snapshot.sessions where !s.awaitingDecision {
            decisionPending[s.id] = nil
        }
    }

    private func appendFeed(_ sessionId: String, _ item: FeedItem) {
        feedCounter += 1
        var feed = feeds[sessionId] ?? []
        feed.append(FeedEntry(id: feedCounter, item: item))
        if feed.count > Self.feedCap {
            feed.removeFirst(feed.count - Self.feedCap)
        }
        feeds[sessionId] = feed
    }

    @discardableResult
    private func appendUserMessage(_ sessionId: String, text: String) -> Int {
        feedCounter += 1
        let id = feedCounter
        var feed = feeds[sessionId] ?? []
        feed.append(FeedEntry(id: id, item: .userMessage(text: text, status: .sending)))
        if feed.count > Self.feedCap {
            feed.removeFirst(feed.count - Self.feedCap)
        }
        feeds[sessionId] = feed
        return id
    }

    /// `entryId` feedCap=200 kesimi ya da başka bir nedenle feed'den çıkmışsa tarama
    /// hiçbir şey bulmaz ve sessizce döner — bu bir hata değil, kasıtlı no-op'tur.
    private func setUserMessageStatus(_ entryId: Int, _ status: SendStatus) {
        for (sessionId, feed) in feeds {
            guard let idx = feed.firstIndex(where: { $0.id == entryId }),
                  case .userMessage(let text, _) = feed[idx].item else { continue }
            feeds[sessionId]?[idx] = FeedEntry(id: entryId, item: .userMessage(text: text, status: status))
            return
        }
    }
}
