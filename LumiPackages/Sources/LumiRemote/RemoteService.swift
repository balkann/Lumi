import Foundation
import LumiKit

/// Tanı günlüğü — yalnız `LUMI_REMOTE_DEBUG` ortam değişkeni set edildiğinde
/// stderr'e yazar (üretimde sessiz). Telefon↔Mac boru hattının hangi sınırda
/// koptuğunu tek bir tekrar-üretim koşusunda göstermek için (transcript takibi
/// tanısı). Kaldırılabilir; davranışa etkisi yok.
let remoteDebugEnabled = ProcessInfo.processInfo.environment["LUMI_REMOTE_DEBUG"] != nil
let remoteDebugLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("lumi-remote-debug.log")
func rlog(_ message: @autoclosure () -> String) {
    guard remoteDebugEnabled else { return }
    let line = "[LUMI-REMOTE] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    // Ayrıca sabit bir dosyaya ekle — GUI app terminalden başlatılmasa da
    // (~/lumi-remote-debug.log) okunabilsin.
    if let handle = try? FileHandle(forWritingTo: remoteDebugLogURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: remoteDebugLogURL)
    }
}

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
    /// Aynı repoda eş zamanlı terminallerin jsonl'lerini birthtime≈createdAt ile
    /// tekil ayrıştırır (aksi halde mtime sezgiseli tab'lar arası mesaj sızdırır).
    private let claimRegistry = TranscriptClaimRegistry()
    private var lastSummary: [TerminalID: String] = [:]
    private var awaitingDecision: [TerminalID: Bool] = [:]
    /// Ekranda o an duran interaktif prompt (ekran-scrape, spec 4). Birincil kaynak:
    /// varken transcript AskUserQuestion düşürülür (dedup).
    private var screenPrompt: [TerminalID: DetectedPrompt] = [:]
    private var currentModel: [TerminalID: String] = [:]
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
        for meta in terminal.terminals { await startWatcher(for: meta) }
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
        for (id, watcher) in currentWatchers {
            await watcher.stop()
            await claimRegistry.unregister(owner: id)
        }
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
            await startWatcher(for: meta)
            await sendSnapshot()
        case .exited(let id, _):
            await stopWatcher(for: id)
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
        case .promptChanged(let id, let prompt):
            screenPrompt[id] = prompt   // nil → anahtar silinir
            guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
            await connection.send(type: "event",
                payload: SnapshotBuilder.promptEvent(sessionId: meta.id.description, prompt: prompt))
        default:
            break
        }
    }

    // MARK: - Transcript

    private func startWatcher(for meta: TerminalMeta) async {
        guard watchers[meta.id] == nil else { return }
        // Kaydı watcher poll etmeye başlamadan ÖNCE yap: aynı repodaki kardeşler
        // ilk poll'dan itibaren görünür olsun (yoksa tek-oturum sezgiseline düşülür).
        let dir = transcriptsRoot.appendingPathComponent(
            TranscriptParser.projectDirName(forCwd: meta.repoPath))
        await claimRegistry.register(owner: meta.id, dir: dir, createdAt: meta.createdAt)
        let watcher = TranscriptWatcher(
            projectsRoot: transcriptsRoot,
            repoPath: meta.repoPath,
            sessionCreatedAt: meta.createdAt,
            // terminal id'si = claude --session-id (ClaudeSessionID enjeksiyonu) →
            // watcher <id>.jsonl'i KESİN eşler; yoksa registry (kardeş tab ayrımı),
            // o da yoksa mtime heuristiğine düşer.
            sessionId: meta.id.raw.uuidString.lowercased(),
            owner: meta.id,
            registry: claimRegistry)
        watchers[meta.id] = watcher
        rlog("watcher started session=\(meta.id.description) repo=\(meta.repoPath)")
        let sessionId = meta.id
        watcherTasks[sessionId] = Task { [weak self] in
            let stream = await watcher.items()
            for await item in stream {
                await self?.handleFeedItem(item, sessionId: sessionId)
            }
        }
    }

    private func stopWatcher(for id: TerminalID) async {
        watcherTasks[id]?.cancel(); watcherTasks[id] = nil
        if let watcher = watchers.removeValue(forKey: id) {
            await watcher.stop()
        }
        await claimRegistry.unregister(owner: id)
        lastSummary[id] = nil
        awaitingDecision[id] = nil
        screenPrompt[id] = nil
        currentModel[id] = nil
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
            rlog("get_history session=\(payload["sessionId"] as? String ?? "-") -> session_not_found (watchers=\(watchers.keys.map(\.description)))")
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "session_not_found",
            ])
            return
        }
        let items = await watcher.historyItems(limit: 50, maxTailBytes: 262_144)
        rlog("get_history session=\(raw) -> \(items.count) item")
        guard !items.isEmpty else {
            await connection.send(type: "command_result", payload: [
                "commandId": commandId, "ok": false, "error": "no_transcript",
            ])
            return
        }
        await connection.send(type: "event", payload: [
            "kind": "history", "sessionId": raw,
            "items": items.filter { if case .model = $0 { return false }; return true }.map(\.itemPayload),
        ])
        await connection.send(type: "command_result", payload: [
            "commandId": commandId, "ok": true,
        ])
    }

    func handleFeedItem(_ item: FeedItem, sessionId: TerminalID) async {
        switch item {
        case .question(let questions):
            // Ekran-scrape birincil (spec 4 §K1): ekranda aktif prompt varken transcript sorusu düşürülür.
            if screenPrompt[sessionId] != nil { return }
            lastSummary[sessionId] = questions.first?.question
        case .toolUse(let name, let summary):
            lastSummary[sessionId] = summary.isEmpty ? name : "\(name): \(summary)"
        case .model(let model):
            // model sinyaldir, transcript öğesi değil → telefona transcript olarak gitmez
            // Değer, asistan jsonl çıktısındaki message.model'dan okunur; set_model komutu
            // sonrası yeni model ancak bir sonraki asistan mesajında görünür (kasıtlı gecikme —
            // telefon istenen değil, fiilen çalışan modeli gösterir).
            guard currentModel[sessionId] != model else { return }
            currentModel[sessionId] = model
            await connection.send(type: "event",
                payload: SnapshotBuilder.modelChangeEvent(sessionId: sessionId.description, model: model))
            return
        case .sessionReset:
            // İzlenen transcript dosyası değişti (ör. /clear yeni oturum dosyası açtı):
            // oturum-durumunu sıfırla + telefona reset yolla (feed/soru kartı temizlenir).
            // Yeni dosyanın içeriği bunu takip eden canlı transcript öğeleriyle repopüle olur.
            lastSummary[sessionId] = nil
            screenPrompt[sessionId] = nil
            awaitingDecision[sessionId] = nil
            currentModel[sessionId] = nil
            await connection.send(type: "event",
                payload: SnapshotBuilder.sessionResetEvent(sessionId: sessionId.description))
            return
        default:
            break
        }
        rlog("live item session=\(sessionId.description) -> \(item.itemPayload["itemType"] ?? "?")")
        await connection.send(type: "event", payload: item.eventPayload(sessionId: sessionId.description))
    }

    // MARK: - Yardımcılar

    private func sendSnapshot() async {
        let repoList = await repos.repos()
        let personaList = await personas.personas(projectPath: nil)
        let payload = SnapshotBuilder.snapshot(
            terminals: terminal.terminals, repos: repoList, personas: personaList,
            awaitingDecision: awaitingDecision, currentModel: currentModel,
            activePrompts: screenPrompt)
        rlog("snapshot -> \(terminal.terminals.count) session, watchers=\(watchers.count)")
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

    /// Test seam: watcher olmadan feed öğesi enjekte eder (dedup davranışını doğrular).
    func ingestFeedItemForTest(_ item: FeedItem, sessionId: TerminalID) async {
        await handleFeedItem(item, sessionId: sessionId)
    }
}
