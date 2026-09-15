import Foundation
import Observation

public enum StartSessionState: Sendable, Equatable {
    case idle, sending, succeeded
    case failed(String)
}

/// Tek view-model: RelayClient olaylarını UI durumuna indirger, komutları yollar.
/// istemci→model AsyncStream, model→UI @Observable (repo kalıbı; Combine yok).
///
/// Terminal-ayna modeli: Mac ham PTY baytını `data`/`scrollback` mesajlarıyla yollar,
/// model bunları abone olunan session'ın `terminalStream`'ine (SwiftTerm view'ı tüketir)
/// yönlendirir. Tuş vuruşları `sendInput` ile `input` frame'i olarak geri gönderilir.
@Observable @MainActor
public final class AppModel {
    public private(set) var isPaired: Bool
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var macOnline = false
    public private(set) var lastSeenAt: Date?
    /// Aktif terminal oturumlarının listesi (welcome/sessions mesajından).
    public private(set) var sessions: [SessionMeta] = []
    /// Şu an abone olunan (görüntülenen) oturum; reconnect'te yeniden abone olmak için (Task 11).
    public private(set) var activeSessionId: String?
    public private(set) var repos: [Repo] = []
    public private(set) var personas: [Persona] = []
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
    /// sessionId → mevcut model id'si (SessionMeta.model'den; kalıcı bilgi).
    private var models: [String: String] = [:]
    /// commandId → sessionId; start_session için "" (oturum henüz yok).
    private var commandTargets: [String: String] = [:]

    // MARK: Terminal byte-routing

    /// Aktif oturumun canlı chunk tüketicisi (SwiftTerm view). Tek tüketici yeterli.
    private var terminalSinks: [String: AsyncStream<TerminalChunk>.Continuation] = [:]
    /// Aktif oturum için, view stream'e bağlanmadan önce gelen chunk'ların replay tamponu.
    /// View `terminalStream` çağırınca önce bunlar sırayla replay edilir, sonra canlı akış.
    private var replayBuffers: [String: [TerminalChunk]] = [:]

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
                    // Task 11: Reconnect subscription replay.
                    // Bağlantı yeniden kurulunca aktif session varsa Mac'e yeniden subscribe
                    // gönder; Mac taze scrollback + canlı data akışını yeniden başlatır.
                    // activeSessionId nil ise (ilk bağlantı veya abone yok) işlem yapılmaz.
                    if state == .connected, let sid = self.activeSessionId {
                        Task { await self.client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sid)) }
                    }
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
        guard let info = Pairing.parse(string) else {
            DiagLog.shared.log("model", "pair parse edilemedi")
            return false
        }
        DiagLog.shared.log("model", "pair ok relay=\(info.relayUrl)")
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
        activeSessionId = nil
        for continuation in terminalSinks.values { continuation.finish() }
        terminalSinks = [:]
        replayBuffers = [:]
        models = [:]
        lastCommandError = [:]
        commandTargets = [:]
        startState = .idle
    }

    // MARK: Gelen mesajlar

    public func handle(_ message: ServerMessage) {
        if case .pong = message {} else {
            DiagLog.shared.log("model", "in \(Self.describe(message))")
        }
        switch message {
        case .welcome(let welcome):
            macOnline = welcome.macOnline
            lastSeenAt = welcome.lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if let metas = welcome.sessions { applySessions(metas) }
            if let repos = welcome.repos { self.repos = repos }

        case .sessions(let metas):
            // sessions mesajını yalnız Mac gönderebilir → Mac online.
            macOnline = true
            applySessions(metas)

        case .repos(let repos):
            // repos mesajını yalnız Mac gönderebilir → Mac online.
            macOnline = true
            self.repos = repos

        case .scrollback(let chunk), .data(let chunk):
            macOnline = true
            route(chunk)

        case .commandResult(let result):
            guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
            if target.isEmpty {
                startState = result.ok ? .succeeded : .failed(result.error ?? "oturum açılamadı")
            } else if !result.ok {
                lastCommandError[target] = result.error ?? "komut iletilemedi"
            }

        case .pong:
            break

        case .chat, .chatAppend:
            break
        }
    }

    /// Gelen mesajın tek satırlık teşhis özeti (içerik metni loglanmaz).
    private static func describe(_ message: ServerMessage) -> String {
        switch message {
        case .welcome(let welcome):
            "welcome macOnline=\(welcome.macOnline) sessions=\(welcome.sessions?.count ?? 0)"
        case .commandResult(let result):
            "commandResult \(result.commandId) ok=\(result.ok) err=\(result.error ?? "-")"
        case .pong:
            "pong"
        case .sessions(let list):
            "sessions count=\(list.count)"
        case .scrollback(let chunk):
            "scrollback \(chunk.sessionId.prefix(8)) seq=\(chunk.seq)"
        case .data(let chunk):
            "data \(chunk.sessionId.prefix(8)) seq=\(chunk.seq)"
        case .repos(let repos):
            "repos count=\(repos.count)"
        case .chat(_, let messages):
            "chat count=\(messages.count)"
        case .chatAppend(_, let messages):
            "chat_append count=\(messages.count)"
        }
    }

    /// SessionMeta listesini uygular: model bilgisini kalıcı tutar, ölü oturumların
    /// terminal kaynaklarını temizler.
    private func applySessions(_ metas: [SessionMeta]) {
        sessions = metas
        let liveIds = Set(metas.map(\.id))
        for meta in metas {
            if let m = meta.model { models[meta.id] = m }
        }
        models = models.filter { liveIds.contains($0.key) }
        lastCommandError = lastCommandError.filter { liveIds.contains($0.key) }
        // Aktif oturum listede yoksa (silindi/kapandı) sink'i kapat.
        if let active = activeSessionId, !liveIds.contains(active) {
            terminalSinks[active]?.finish()
            terminalSinks[active] = nil
            replayBuffers[active] = nil
        }
    }

    /// Gelen chunk'ı ilgili session'ın canlı sink'ine yollar; sink henüz bağlı değilse
    /// (view geç mount olduysa) aktif oturum için replay tamponuna biriktirir.
    private func route(_ chunk: TerminalChunk) {
        if let sink = terminalSinks[chunk.sessionId] {
            sink.yield(chunk)
        } else if chunk.sessionId == activeSessionId {
            replayBuffers[chunk.sessionId, default: []].append(chunk)
        }
        // Aktif olmayan/abonesiz oturumun chunk'ı düşürülür (istenmeyen veri).
    }

    // MARK: Terminal abonelik API'si (Task 9/11 tüketir)

    /// Oturumu aktif işaretler ve `subscribe` frame'i gönderir. Mac scrollback + canlı
    /// data ile yanıtlar; bunlar `terminalStream(sessionId)`'e akar.
    public func subscribe(_ sessionId: String) {
        // unsubscribe çağrılmadan session değiştirilirse önceki session'ın kaynaklarını
        // temizle: aksi halde eski view'ın `for await`'i asla sonlanmaz ve geç gelen eski
        // `.data` ona yield edilir.
        if let old = activeSessionId, old != sessionId {
            terminalSinks[old]?.finish()
            terminalSinks[old] = nil
            replayBuffers[old] = nil
        }
        activeSessionId = sessionId
        replayBuffers[sessionId] = []
        Task { await client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sessionId)) }
    }

    /// Aboneliği bırakır: aktif eşleşiyorsa temizler, `unsubscribe` frame'i gönderir,
    /// canlı stream'i sonlandırır.
    public func unsubscribe(_ sessionId: String) {
        if activeSessionId == sessionId { activeSessionId = nil }
        terminalSinks[sessionId]?.finish()
        terminalSinks[sessionId] = nil
        replayBuffers[sessionId] = nil
        Task { await client.send(frame: PhoneProtocol.unsubscribeFrame(sessionId: sessionId)) }
    }

    /// Tuş vuruşu / bayt dizisini `input` frame'i olarak Mac PTY'sine yollar.
    public func sendInput(_ sessionId: String, _ data: Data) {
        Task { await client.send(frame: PhoneProtocol.inputFrame(sessionId: sessionId, data: data)) }
    }

    /// Verilen oturuma gelen scrollback + canlı data chunk'larının akışı.
    /// Bağlanınca önce (subscribe sonrası biriken) replay tamponu sırayla verilir,
    /// sonra canlı chunk'lar akar. Aynı anda tek tüketici desteklenir; yeni stream
    /// eskisini yerinden eder.
    public func terminalStream(_ sessionId: String) -> AsyncStream<TerminalChunk> {
        // Eski tüketici varsa kapat (yeni stream tek sahip olur).
        terminalSinks[sessionId]?.finish()
        let buffered = replayBuffers[sessionId] ?? []
        replayBuffers[sessionId] = []
        return AsyncStream { continuation in
            for chunk in buffered { continuation.yield(chunk) }
            terminalSinks[sessionId] = continuation
            // Consumer-side iptal (view cancellation) sink'i kendi kendine temizlesin.
            // Tek-tüketici varsayımı geçerli → o id'nin sink'ini nil'le.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.terminalSinks[sessionId] = nil
                }
            }
        }
    }

    // MARK: Türetilmiş durum

    /// `waiting` üstte (tasarım §4.3), sonra error/working/idle; grup içi repo adına göre.
    public var orderedSessions: [SessionMeta] {
        func priority(_ badge: Badge) -> Int {
            switch badge {
            case .waiting: 0
            case .error: 1
            case .working: 2
            case .idle: 3
            }
        }
        return sessions.sorted { a, b in
            let pa = priority(a.badge), pb = priority(b.badge)
            if pa != pb { return pa < pb }
            return a.repoName.localizedCaseInsensitiveCompare(b.repoName) == .orderedAscending
        }
    }

    public func session(_ id: String) -> SessionMeta? {
        sessions.first { $0.id == id }
    }

    // MARK: Komutlar

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
        DiagLog.shared.log(
            "push", "token alındı \(hex.prefix(8))… enabled=\(notificationsEnabled)")
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

    // MARK: Yardımcılar

    private func dispatch(target: String, action: CommandAction) async {
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        commandTargets[commandId] = target
        if !target.isEmpty {
            lastCommandError[target] = nil
        }
        let ok = await client.send(command: OutgoingCommand(commandId: commandId, action: action))
        // Mirror ile yalnız case adı loglanır — mesaj içeriği günlüğe düşmez.
        let label = Mirror(reflecting: action).children.first?.label
            ?? String(describing: action)
        DiagLog.shared.log(
            "model", "out \(commandId) \(label) target=\(target.prefix(8)) ok=\(ok)")
        if !ok {
            commandTargets[commandId] = nil
            if target.isEmpty {
                startState = .failed("bağlantı yok")
            } else {
                lastCommandError[target] = "bağlantı yok"
            }
        }
    }
}
