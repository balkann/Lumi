import Foundation
import Observation

/// Akışta gösterilen tek öğe; `id` monoton artar (ScrollView kimliği için).
public struct FeedEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let item: FeedItem
}

/// Oturum detayında sabitlenen cevap kartı.
/// `questions == nil` → jenerik kart (tasarım §12.3): "izin bekliyor" + son tool_use bağlamı.
public struct QuestionCard: Sendable, Equatable {
    public let questions: [Question]?
    public let context: String?

    public init(questions: [Question]?, context: String?) {
        self.questions = questions
        self.context = context
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

    private let client: any RelayClienting
    private let store: any SecureStore
    private var consumeTask: Task<Void, Never>?
    private var commandCounter = 0
    private var feedCounter = 0
    private var activeQuestions: [String: [Question]] = [:]
    /// commandId → sessionId; start_session için "" (oturum henüz yok).
    private var commandTargets: [String: String] = [:]
    private static let feedCap = 200

    public init(client: any RelayClienting, store: any SecureStore) {
        self.client = client
        self.store = store
        self.isPaired = store.read() != nil
    }

    // MARK: Yaşam döngüsü

    public func start() async {
        guard consumeTask == nil, let pairing = store.read() else { return }
        let stream = await client.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let state): self.connection = state
                case .message(let message): self.handle(message)
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
        lastCommandError = [:]
        commandTargets = [:]
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
            }

        case .commandResult(let result):
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
        if let questions = activeQuestions[sessionId] {
            return QuestionCard(questions: questions, context: nil)
        }
        guard session(sessionId)?.status.badge == .waiting else { return nil }
        let context = (feeds[sessionId] ?? []).reversed().compactMap { entry -> String? in
            if case .toolUse(let tool, let summary) = entry.item { return "\(tool): \(summary)" }
            return nil
        }.first
        return QuestionCard(questions: nil, context: context)
    }

    // MARK: Komutlar

    public func sendText(sessionId: String, text: String) async {
        await dispatch(target: sessionId, action: .sendText(sessionId: sessionId, text: text))
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

    public func registerPush(deviceToken: String) async {
        await client.registerPush(deviceToken: deviceToken)
    }

    // MARK: Yardımcılar

    private func dispatch(target: String, action: CommandAction) async {
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        commandTargets[commandId] = target
        if !target.isEmpty {
            lastCommandError[target] = nil
            activeQuestions[target] = nil // cevap verildi → kart kalkar
        }
        await client.send(command: OutgoingCommand(commandId: commandId, action: action))
    }

    private func apply(_ snapshot: Snapshot) {
        sessions = snapshot.sessions
        repos = snapshot.repos
        personas = snapshot.personas
        let liveIds = Set(snapshot.sessions.map(\.id))
        feeds = feeds.filter { liveIds.contains($0.key) }
        activeQuestions = activeQuestions.filter { liveIds.contains($0.key) }
        lastCommandError = lastCommandError.filter { liveIds.contains($0.key) }
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
}
