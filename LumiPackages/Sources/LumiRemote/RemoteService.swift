import Foundation
import LumiKit

/// Tanı günlüğü — telefon↔Mac boru hattının hangi sınırda koptuğunu göstermek
/// için. Kalıcı DiagLog'a her zaman yazar (boyut-tavanlı, ~/.lumi/logs/mac.log);
/// `LUMI_REMOTE_DEBUG` set ise ek olarak stderr'e de düşer. Davranışa etkisi yok.
let remoteDebugEnabled = ProcessInfo.processInfo.environment["LUMI_REMOTE_DEBUG"] != nil
func rlog(_ message: @autoclosure () -> String) {
    let text = message()
    DiagLog.shared.log("remote", text)
    if remoteDebugEnabled {
        FileHandle.standardError.write(Data("[LUMI-REMOTE] \(text)\n".utf8))
    }
}

/// LumiRemote orkestratörü (spec §4.2): config'i okur, relay bağlantısını
/// yönetir ve telefon komutlarını uygular. Servis→store sınırı: EventBroadcaster.
///
/// NOT: Terminal-piping internals (transcript watching, snapshot building) Task 5'te
/// tamamen yeniden yazılacak. Bu scaffold yalnız config/connection lifecycle'ı sağlar.
@MainActor
public final class RemoteService: RemoteServicing {
    public private(set) var state: RemoteConnectionState = .disconnected
    public private(set) var currentConfig: RemoteConfig = .defaults

    private let configService: RemoteConfigService
    private let terminal: any TerminalServicing
    private let repos: any RepoServicing
    private let connection: any RelayConnecting
    private let commandHandler: RemoteCommandHandler
    private let broadcaster = EventBroadcaster<RemoteEvent>()
    private let chatSource: any ChatTranscriptSourcing
    /// Session başına chat tail task'ı (mode=chat aboneliği).
    private var chatSubscriptions: [TerminalID: Task<Void, Never>] = [:]

    private var inboundTask: Task<Void, Never>?
    private var terminalTask: Task<Void, Never>?
    private var running = false
    private var epoch = 0

    /// Aktif abonelikler: session başına canlı-çıktı stream task'ı.
    private var subscriptions: [TerminalID: Task<Void, Never>] = [:]
    /// Session başına monoton `seq` sayacı (scrollback=0, ilk data=1, …).
    private var seqCounters: [TerminalID: Int] = [:]
    /// Set edilen modellerin son-bilinen değeri (sessions meta'sı için).
    private var modelCache: [TerminalID: String] = [:]

    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        connection: (any RelayConnecting)? = nil,
        chatSource: any ChatTranscriptSourcing,
        trust: any ClaudeWorkspaceTrusting = NoopClaudeWorkspaceTrust()
    ) {
        self.configService = RemoteConfigService(paths: paths)
        self.terminal = terminal
        self.repos = repos
        self.connection = connection ?? RelayConnection()
        self.commandHandler = RemoteCommandHandler(terminal: terminal, trust: trust)
        self.chatSource = chatSource
    }

    public func events() -> AsyncStream<RemoteEvent> { broadcaster.stream() }

    public func start() async {
        currentConfig = await configService.ensureToken()
        guard currentConfig.enabled, !running else { return }
        guard let url = URL(string: currentConfig.relayUrl) else { return }
        running = true
        epoch &+= 1
        let myEpoch = epoch

        let inboundStream = await connection.inbound()
        guard myEpoch == epoch else { return }
        inboundTask = Task { [weak self] in
            for await inbound in inboundStream {
                await self?.handleInbound(inbound)
            }
        }
        let terminalStream = terminal.events()
        terminalTask = Task { [weak self] in
            for await event in terminalStream {
                await self?.handleTerminalEvent(event)
            }
        }
        await connection.start(url: url, hello: ["role": "mac", "token": currentConfig.token])
        guard myEpoch == epoch else { return }
        setState(.connecting)
    }

    public func stop() {
        Task { await self.shutdown() }
    }

    private func shutdown() async {
        epoch &+= 1
        running = false
        inboundTask?.cancel(); inboundTask = nil
        terminalTask?.cancel(); terminalTask = nil
        for task in subscriptions.values { task.cancel() }
        subscriptions.removeAll()
        for task in chatSubscriptions.values { task.cancel() }
        chatSubscriptions.removeAll()
        seqCounters.removeAll()
        await connection.stop()
        setState(.disconnected)
    }

    public func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async {
        var config = await configService.load()
        let old = config
        mutate(&config)
        await configService.save(config)
        currentConfig = config
        guard old != config else { return }
        if running { await shutdown() }
        if config.enabled { await start() }
    }

    public func regenerateToken() async {
        await updateConfig { $0.token = generateToken() }
    }

    // MARK: - Inbound

    private func handleInbound(_ inbound: RelayInbound) async {
        switch inbound {
        case .stateChanged(let newState):
            setState(newState)
        case .message(let type, let payload):
            rlog("inbound message type=\(type) action=\(payload["action"] as? String ?? "-") session=\(payload["sessionId"] as? String ?? "-")")
            switch type {
            case "welcome":
                await sendSessions()
                await sendRepos()
            case "subscribe":
                await handleSubscribe(payload)
            case "unsubscribe":
                handleUnsubscribe(payload)
            case "input":
                handleInput(payload)
            case "command":
                let result = await commandHandler.handle(payload)
                let ok = result["ok"] as? Bool == true
                cacheModelIfSet(payload, ok: ok)
                await connection.send(type: "command_result", payload: result)
            default:
                break
            }
        }
    }

    // MARK: - Terminal olayları → sessions yeniden yayını

    private func handleTerminalEvent(_ event: TerminalEvent) async {
        switch event {
        case .spawned, .exited, .statusChanged:
            if case let .exited(id, _) = event {
                cancelSubscription(id)
                cancelChatSubscription(id)
                modelCache[id] = nil
            }
            await sendSessions()
        case .titleChanged, .awaitingDecisionChanged, .bell, .providerChanged, .writeFailed, .stalled, .viewFocused:
            break
        }
    }

    // MARK: - Sessions

    /// Mevcut terminal listesinden hafif `SessionMeta` üretir ve `sessions` yollar.
    /// NOT: Liste cols/rows'u ucuz-otoriter değil; sabit 80×24 gönderilir.
    /// Telefon emülatörünü `subscribe` sonrası gelen `scrollback` (otoriter
    /// cols/rows) ile boyutlandırır.
    private func sendSessions() async {
        let repoNames = await repoNameLookup()
        let metas: [SessionMeta] = terminal.terminals.map { meta in
            let repoName = repoNames[meta.repoPath] ?? (meta.repoPath as NSString).lastPathComponent
            return SessionMeta(
                id: meta.id.description,
                repoName: repoName,
                status: meta.status.rawValue,
                title: meta.oscTitle,
                model: modelCache[meta.id],
                cols: 80,
                rows: 24
            )
        }
        await connection.send(type: "sessions", payload: RemoteProtocol.sessionsPayload(metas))
    }

    private func repoNameLookup() async -> [String: String] {
        var map: [String: String] = [:]
        for repo in await repos.repos() { map[repo.path] = repo.name }
        return map
    }

    /// Telefonun "yeni oturum" seçicisi için repo listesini yollar. Relay bunu room'da
    /// cache'ler → sonradan bağlanan telefon welcome ile alır; bağlı telefonlara yayınlar.
    private func sendRepos() async {
        let list = await repos.repos().map { ["name": $0.name, "path": $0.path] }
        await connection.send(type: "repos", payload: RemoteProtocol.reposPayload(list))
    }

    // MARK: - Subscribe / Unsubscribe

    private func handleSubscribe(_ payload: [String: Any]) async {
        guard let raw = RemoteProtocol.decodeSubscribe(payload),
              let id = terminalID(from: raw) else { return }

        cancelSubscription(id)
        cancelChatSubscription(id)

        if RemoteProtocol.decodeSubscribeMode(payload) == "chat",
           let meta = terminal.terminals.first(where: { $0.id == id }),
           let claudeSessionID = meta.claudeSessionID {
            let stream = chatSource.stream(sessionID: claudeSessionID, repoPath: meta.repoPath)
            let task = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.emitChat(sessionId: raw, event: event)
                }
            }
            chatSubscriptions[id] = task
            return
        }

        // terminal mode (mevcut davranış)
        seqCounters[id] = 0

        // (a) scrollback (seq=0, otoriter cols/rows)
        let (data, cols, rows) = terminal.serializeScrollback(id)
        await connection.send(
            type: "scrollback",
            payload: RemoteProtocol.scrollbackPayload(sessionId: raw, seq: 0, cols: cols, rows: rows, data: data)
        )

        // (b) canlı çıktı stream'i — batch başına artan seq ile `data`.
        // subscribeOutput terminal exit'inde BİTMEZ; iptal .exited event'inde
        // (handleTerminalEvent) / unsubscribe / stop'ta explicit yapılır.
        let stream = terminal.subscribeOutput(id)
        let task = Task { [weak self] in
            for await batch in stream {
                guard !Task.isCancelled else { break }
                await self?.emitData(id: id, sessionId: raw, batch: batch)
            }
        }
        subscriptions[id] = task
    }

    private func emitChat(sessionId: String, event: ChatMirrorEvent) async {
        switch event {
        case .snapshot(let messages):
            await connection.send(type: "chat",
                payload: RemoteProtocol.chatPayload(sessionId: sessionId, messages: messages))
        case .append(let messages):
            guard !messages.isEmpty else { return }
            await connection.send(type: "chat_append",
                payload: RemoteProtocol.chatAppendPayload(sessionId: sessionId, messages: messages))
        }
    }

    private func cancelChatSubscription(_ id: TerminalID) {
        chatSubscriptions[id]?.cancel()
        chatSubscriptions[id] = nil
    }

    private func emitData(id: TerminalID, sessionId: String, batch: Data) async {
        guard subscriptions[id] != nil else { return }
        let seq = (seqCounters[id] ?? 0) + 1
        seqCounters[id] = seq
        await connection.send(
            type: "data",
            payload: RemoteProtocol.dataPayload(sessionId: sessionId, seq: seq, data: batch)
        )
    }

    private func handleUnsubscribe(_ payload: [String: Any]) {
        guard let raw = RemoteProtocol.decodeSubscribe(payload),
              let id = terminalID(from: raw) else { return }
        cancelSubscription(id)
        cancelChatSubscription(id)
    }

    private func cancelSubscription(_ id: TerminalID) {
        subscriptions[id]?.cancel()
        subscriptions[id] = nil
        seqCounters[id] = nil
    }

    // MARK: - Input

    private func handleInput(_ payload: [String: Any]) {
        guard let (raw, data) = RemoteProtocol.decodeInput(payload),
              let id = terminalID(from: raw) else { return }
        terminal.writeInput(data, to: id)
    }

    // MARK: - Yardımcılar

    /// sessionId string'i (meta.id.description = UUID) → TerminalID.
    /// Parse edilemeyen id güvenle yok sayılır.
    private func terminalID(from raw: String) -> TerminalID? {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return TerminalID(raw: uuid)
    }

    /// set_model komutu başarılıysa modeli cache'le (sessions meta'sı için).
    private func cacheModelIfSet(_ payload: [String: Any], ok: Bool) {
        guard ok,
              payload["action"] as? String == "set_model",
              let model = payload["model"] as? String,
              let raw = payload["sessionId"] as? String,
              let id = terminalID(from: raw) else { return }
        modelCache[id] = model
    }

    /// Test hook'u — verilen session'ın aktif canlı-çıktı task'ı var mı.
    func hasActiveSubscription(_ id: TerminalID) -> Bool {
        subscriptions[id] != nil
    }

    /// Test hook'u — verilen session'ın aktif chat tail task'ı var mı.
    func hasActiveChatSubscription(_ id: TerminalID) -> Bool {
        chatSubscriptions[id] != nil
    }

    // MARK: - Yardımcılar

    private func setState(_ newState: RemoteConnectionState) {
        guard state != newState else { return }
        state = newState
        broadcaster.send(.stateChanged(newState))
    }
}
