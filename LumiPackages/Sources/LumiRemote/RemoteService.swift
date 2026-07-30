import Foundation
import LumiKit

/// LumiRemote orkestratörü (spec §4.2): config'i okur, relay bağlantısını
/// yönetir, terminal olaylarını + transcript akışını relay'e çevirir ve
/// telefon komutlarını uygular. Servis→store sınırı: EventBroadcaster.
@MainActor
public final class RemoteService: RemoteServicing {
    public private(set) var state: RemoteConnectionState = .disconnected
    public private(set) var currentConfig: RemoteConfig = .defaults

    private let configService: RemoteConfigService
    private let terminal: any TerminalServicing
    private let repos: any RepoServicing
    private let personas: any PersonaServicing
    private let connection: any RelayConnecting
    private let commandHandler: RemoteCommandHandler
    private let transcriptsRoot: URL
    private let broadcaster = EventBroadcaster<RemoteEvent>()

    private var inboundTask: Task<Void, Never>?
    private var terminalTask: Task<Void, Never>?
    private var watchers: [TerminalID: TranscriptWatcher] = [:]
    private var watcherTasks: [TerminalID: Task<Void, Never>] = [:]
    private var lastSummary: [TerminalID: String] = [:]
    private var awaitingDecision: [TerminalID: Bool] = [:]
    private var running = false
    private var epoch = 0

    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        personas: any PersonaServicing,
        connection: (any RelayConnecting)? = nil,
        transcriptsRoot: URL? = nil
    ) {
        self.configService = RemoteConfigService(paths: paths)
        self.terminal = terminal
        self.repos = repos
        self.personas = personas
        self.connection = connection ?? RelayConnection()
        self.commandHandler = RemoteCommandHandler(terminal: terminal, personas: personas)
        self.transcriptsRoot = transcriptsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
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
        for meta in terminal.terminals { startWatcher(for: meta) }
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
        for (id, task) in watcherTasks { task.cancel(); watcherTasks[id] = nil }
        let currentWatchers = watchers
        watchers = [:]
        for (_, watcher) in currentWatchers { await watcher.stop() }
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
            switch type {
            case "welcome":
                await sendSnapshot()
            case "command":
                if payload["action"] as? String == "get_history" {
                    await handleGetHistory(payload)
                } else {
                    let result = await commandHandler.handle(payload)
                    await connection.send(type: "command_result", payload: result)
                }
            default:
                break
            }
        }
    }

    // MARK: - Terminal olayları

    private func handleTerminalEvent(_ event: TerminalEvent) async {
        switch event {
        case .spawned(let meta):
            startWatcher(for: meta)
            await sendSnapshot()
        case .exited(let id, _):
            stopWatcher(for: id)
            await sendSnapshot()
        case .statusChanged(let id, let status):
            guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
            let repoName = await repoName(for: meta.repoPath)
            let payload = SnapshotBuilder.statusChangeEvent(
                meta: meta, status: status, repoName: repoName, summary: lastSummary[id])
            await connection.send(type: "event", payload: payload)
            await sendSnapshot()
        case .awaitingDecisionChanged(let id, let awaiting):
            awaitingDecision[id] = awaiting
            guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
            await connection.send(type: "event", payload:
                SnapshotBuilder.awaitingDecisionEvent(sessionId: meta.id.description, awaiting: awaiting))
        default:
            break
        }
    }

    // MARK: - Transcript

    private func startWatcher(for meta: TerminalMeta) {
        guard watchers[meta.id] == nil else { return }
        let watcher = TranscriptWatcher(
            projectsRoot: transcriptsRoot,
            repoPath: meta.repoPath,
            sessionCreatedAt: meta.createdAt)
        watchers[meta.id] = watcher
        let sessionId = meta.id
        watcherTasks[sessionId] = Task { [weak self] in
            let stream = await watcher.items()
            for await item in stream {
                await self?.handleFeedItem(item, sessionId: sessionId)
            }
        }
    }

    private func stopWatcher(for id: TerminalID) {
        watcherTasks[id]?.cancel(); watcherTasks[id] = nil
        if let watcher = watchers.removeValue(forKey: id) {
            Task { await watcher.stop() }
        }
        lastSummary[id] = nil
        awaitingDecision[id] = nil
    }

    /// get_history (Plan 3.5): watcher'ın jsonl kuyruğunu tek `history`
    /// event'i olarak döner. Watcher'lara erişim gerektiğinden
    /// RemoteCommandHandler yerine burada ele alınır.
    private func handleGetHistory(_ payload: [String: Any]) async {
        let commandId: Any = (payload["commandId"] as? String) ?? NSNull()
        guard let raw = payload["sessionId"] as? String,
              let uuid = UUID(uuidString: raw),
              let watcher = watchers[TerminalID(raw: uuid)]
        else {
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "session_not_found",
            ])
            return
        }
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        guard !items.isEmpty else {
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "no_transcript",
            ])
            return
        }
        await connection.send(type: "event", payload: [
            "kind": "history", "sessionId": raw, "items": items.map(\.itemPayload),
        ])
        await connection.send(type: "command_result", payload: [
            "commandId": commandId, "ok": true,
        ])
    }

    private func handleFeedItem(_ item: FeedItem, sessionId: TerminalID) async {
        switch item {
        case .question(let questions):
            lastSummary[sessionId] = questions.first?.question
        case .toolUse(let name, let summary):
            lastSummary[sessionId] = summary.isEmpty ? name : "\(name): \(summary)"
        default:
            break
        }
        await connection.send(type: "event", payload: item.eventPayload(sessionId: sessionId.description))
    }

    // MARK: - Yardımcılar

    private func sendSnapshot() async {
        let repoList = await repos.repos()
        let personaList = await personas.personas(projectPath: nil)
        let payload = SnapshotBuilder.snapshot(
            terminals: terminal.terminals, repos: repoList, personas: personaList,
            awaitingDecision: awaitingDecision)
        await connection.send(type: "snapshot", payload: payload)
    }

    private func repoName(for path: String) async -> String {
        let repoList = await repos.repos()
        return repoList.first { $0.path == path }?.name
            ?? (path as NSString).lastPathComponent
    }

    private func setState(_ newState: RemoteConnectionState) {
        guard state != newState else { return }
        state = newState
        broadcaster.send(.stateChanged(newState))
    }
}
