import Foundation
import Observation
import LumiWire

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
    /// Aktif aboneliğin modu (chat mı terminal mi). Reconnect'te AYNI modda yeniden
    /// abone olmak için — aksi halde chat modda kopunca terminal moduna düşer ve
    /// `chat`/`chat_append` frame'leri gelmez, mesajlar telefona ulaşmaz (handoff #6).
    private var activeChatMode = false
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
    /// delete_session komut id'leri — commandResult'ta yerel liste temizliği için.
    private var deleteCommandIds: Set<String> = []
    /// Bu telefonun başlattığı stream-json chat oturumları. `submitText` routing'i
    /// buna bakar — `sessions` broadcast'i gecikirse bile chat mesajı yanlışlıkla
    /// PTY input'a düşmez (final review #1: kind broadcast yarışına bağlı olamaz).
    private var chatSessionIds: Set<String> = []

    // MARK: Terminal byte-routing

    /// Aktif oturumun canlı chunk tüketicisi (SwiftTerm view). Tek tüketici yeterli.
    private var terminalSinks: [String: AsyncStream<TerminalChunk>.Continuation] = [:]
    /// Aktif oturum için, view stream'e bağlanmadan önce gelen chunk'ların replay tamponu.
    /// View `terminalStream` çağırınca önce bunlar sırayla replay edilir, sonra canlı akış.
    private var replayBuffers: [String: [TerminalChunk]] = [:]
    /// Şerit unmount'ken (sink yok) sınırsız bellek birikimini önler. En eski
    /// chunk'lar düşer; claude TUI sık full-repaint yaptığı için orta-akış replayı kabul edilir.
    private static let replayBufferCap = 2048

    // MARK: Chat durumu (mode=chat; orca native-chat)

    /// sessionId → chat mesajları (mode=chat aboneliği; orca native-chat).
    private var chatBySession: [String: [ChatMessage]] = [:]
    /// Optimistic kullanıcı mesajı yankıları (orca pending echo — client-side, anında).
    /// Transcript yankılayınca sayım-tabanlı dedup ile emekliye ayrılır; yankılamazsa kalır.
    private var pendingBySession: [String: [ChatPending]] = [:]
    private var pendingCounter = 0
    /// Session başına streaming geçidi (orca deriveMobileNativeChatStreaming portu).
    private var streamingGates: [String: ChatStreamGate] = [:]
    /// Geçitten geçmiş görünür streaming metni (view okur; gerçek mesaj tail'e
    /// düşünce veya turn bitince gizlenir).
    public private(set) var gatedStreaming: [String: String] = [:]
    /// sessionId → son canlı turn status (Faz 2; chat_status frame'inden).
    public private(set) var turnStatus: [String: ChatTurnStatus] = [:]
    /// Faz 3: session başına aktif (pending) etkileşimli prompt'lar.
    public private(set) var prompts: [String: [ChatPrompt]] = [:]

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
                        let mode = self.activeChatMode ? "chat" : "terminal"
                        Task { await self.client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sid, mode: mode)) }
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
        chatBySession = [:]
        pendingBySession = [:]
        streamingGates = [:]
        gatedStreaming = [:]
        turnStatus = [:]
        prompts = [:]
        models = [:]
        lastCommandError = [:]
        commandTargets = [:]
        deleteCommandIds = []
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
            let wasDelete = deleteCommandIds.remove(result.commandId) != nil
            guard let target = commandTargets.removeValue(forKey: result.commandId) else { return }
            if target.isEmpty {
                startState = result.ok ? .succeeded : .failed(result.error ?? "oturum açılamadı")
                // start_session kind=chat → Mac sessionId döndürür → chat oturumu
                // olarak işaretle (routing için) + otomatik chat abone ol.
                if result.ok, let sid = result.sessionId {
                    chatSessionIds.insert(sid)
                    subscribeChat(sid)
                }
            } else if wasDelete {
                // Silme: Mac chat oturumu silinince güncel `sessions` yayınlamıyor →
                // telefon listesi takılıyordu ("silemiyorum"). Başarıda VEYA hayalet
                // oturumda (session_not_found, Mac restart sonrası) yereli hemen temizle.
                if result.ok || result.error == "session_not_found" {
                    removeSessionLocally(target)
                } else {
                    lastCommandError[target] = result.error ?? "oturum silinemedi"
                }
            } else if !result.ok {
                lastCommandError[target] = result.error ?? "komut iletilemedi"
            }

        case .pong:
            break

        case .chat(let sessionId, let messages):
            macOnline = true
            chatBySession[sessionId] = messages
            pendingBySession[sessionId] = chatRetireLandedPending(
                messages: messages, current: pendingBySession[sessionId] ?? [])
            recomputeStreaming(sessionId)

        case .chatAppend(let sessionId, let messages):
            macOnline = true
            var current = chatBySession[sessionId] ?? []
            for message in messages {
                if let idx = current.firstIndex(where: { $0.id == message.id }) {
                    current[idx] = message
                } else {
                    current.append(message)
                }
            }
            chatBySession[sessionId] = current
            pendingBySession[sessionId] = chatRetireLandedPending(
                messages: current, current: pendingBySession[sessionId] ?? [])
            recomputeStreaming(sessionId)

        case .chatStatus(let sessionId, let status):
            macOnline = true
            turnStatus[sessionId] = status
            recomputeStreaming(sessionId)

        case .prompt(let sessionId, let p):
            macOnline = true
            var list = prompts[sessionId] ?? []
            list.removeAll { $0.itemId == p.itemId }
            if p.state == .pending { list.append(p) }   // resolved/cancelled → listede tutma
            prompts[sessionId] = list
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
        case .chatStatus(let sessionId, _):
            "chat_status \(sessionId.prefix(8))"
        case .prompt(let sessionId, let p):
            "prompt \(sessionId.prefix(8)) \(p.kind.rawValue) \(p.state.rawValue)"
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
            chatBySession[active] = nil
            pendingBySession[active] = nil
            streamingGates[active] = nil
            gatedStreaming[active] = nil
            turnStatus[active] = nil
            prompts[active] = nil
        }
    }

    /// Gelen chunk'ı ilgili session'ın canlı sink'ine yollar; sink henüz bağlı değilse
    /// (view geç mount olduysa) aktif oturum için replay tamponuna biriktirir.
    private func route(_ chunk: TerminalChunk) {
        if let sink = terminalSinks[chunk.sessionId] {
            sink.yield(chunk)
        } else if chunk.sessionId == activeSessionId {
            var buf = replayBuffers[chunk.sessionId, default: []]
            buf.append(chunk)
            // Cap: şerit unmount'ken (sink yok) feed sınırsız birikmesin — en eski
            // chunk düşer. Orta-akıştan replay TUI'de kısa süreli bozuk çizim
            // yapabilir; claude TUI sık full-repaint yaptığı için kabul edilir.
            if buf.count > Self.replayBufferCap { buf.removeFirst(buf.count - Self.replayBufferCap) }
            replayBuffers[chunk.sessionId] = buf
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
        activeChatMode = false
        replayBuffers[sessionId] = []
        Task { await client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sessionId)) }
    }

    /// Aboneliği bırakır: aktif eşleşiyorsa temizler, `unsubscribe` frame'i gönderir,
    /// canlı stream'i sonlandırır.
    public func unsubscribe(_ sessionId: String) {
        if activeSessionId == sessionId { activeSessionId = nil; activeChatMode = false }
        terminalSinks[sessionId]?.finish()
        terminalSinks[sessionId] = nil
        replayBuffers[sessionId] = nil
        Task { await client.send(frame: PhoneProtocol.unsubscribeFrame(sessionId: sessionId)) }
    }

    /// Tuş vuruşu / bayt dizisini `input` frame'i olarak Mac PTY'sine yollar.
    public func sendInput(_ sessionId: String, _ data: Data) {
        Task { await client.send(frame: PhoneProtocol.inputFrame(sessionId: sessionId, data: data)) }
    }

    /// Faz 3: etkileşimli prompt cevabı. Optimistic dismiss yok — kart, resolution
    /// broadcast'i (state=resolved/cancelled) gelince `handle(.prompt)` üzerinden düşer.
    public func respondPrompt(_ sessionId: String, itemId: String, revision: Int, optionId: String) {
        Task { await client.send(frame: PhoneProtocol.promptRespondFrame(
            sessionId: sessionId, itemId: itemId, expectedRevision: revision, optionId: optionId)) }
    }

    /// Faz 3.1: soru cevabı (soru başına indices + free-text). Optimistic dismiss yok.
    public func respondPromptSelections(_ sessionId: String, itemId: String, revision: Int,
                                        selections: [(indices: [Int], other: String?)]) {
        Task { await client.send(frame: PhoneProtocol.promptRespondSelectionsFrame(
            sessionId: sessionId, itemId: itemId, expectedRevision: revision, selections: selections)) }
    }

    /// Serbest metin gönderiminde (`submitText`) metin ile Enter arasındaki "settle"
    /// penceresi. Varsayılan orca paritesi (`AGENT_PROMPT_SUBMIT_SETTLE_MS` = 500 ms);
    /// test'ler hızlandırmak için sıfırlayabilir.
    public var submitSettle: Duration = .milliseconds(500)

    /// Serbest metin gönderimi (chat composer / terminal metin çubuğu):
    /// - Chat oturumu (kind = "chat"): `chat_send` frame'i gönderir (PTY input değil).
    /// - Terminal oturumu: metni bir `input` frame'iyle yollar, ajanın paste'i
    ///   sindirmesi için `submitSettle` bekler, sonra Enter'ı (CR) AYRI bir
    ///   `input` frame'iyle yollar.
    ///
    /// Terminal yolu neden ayrı: tek write'taki birleşik `metin\r`, Claude Code
    /// TUI'sinde paste ingest'i tamamlanmadan gelen Enter olarak yutulur ve submit
    /// tetiklenmez — metin input satırında görünür ama gönderilmez (orca
    /// `runtime-terminal-writer` paritesi: text → settle → CR). İki write'ı TEK
    /// Task içinde sıralı tutar; ayrı `sendInput` çağrıları Task sırasını garanti
    /// etmez ve Enter metni geçebilir.
    public func submitText(_ sessionId: String, _ text: String) {
        // Chat oturumu: chat_send frame'i (PTY bypass). Tek kaynak: isChatSession
        // (yerel izlenen chat id'si VEYA sessions broadcast'inde kind:chat).
        let isChat = isChatSession(sessionId)
        // Faz 2.1 teşhis: hangi dalın çalıştığı + frame'in kuyruğa girdiği cihaz logunda
        // görünsün (kanıt: "sohbet yükleniyor + mesaj gitmiyor" — Mac'e chat_send/input 0 ulaştı).
        DiagLog.shared.log("model", "submitText sid=\(sessionId.prefix(8)) chat=\(isChat) len=\(text.count)")
        if isChat {
            // Optimistic echo: kullanıcının mesajı ANINDA listeye düşer (orca; client-side,
            // sunucu onayı/latency beklenmez). Transcript yankılarsa dedup ile emekliye ayrılır.
            appendChatPending(sessionId, text: text)
            Task {
                let ok = await client.send(frame: PhoneProtocol.chatSendFrame(sessionId: sessionId, text: text))
                DiagLog.shared.log("model", "out chat_send sid=\(sessionId.prefix(8)) ok=\(ok)")
            }
            return
        }
        // Terminal oturumu: metin → settle → CR (orca runtime-terminal-writer paritesi).
        Task {
            if !text.isEmpty {
                await client.send(frame: PhoneProtocol.inputFrame(sessionId: sessionId, data: Data(text.utf8)))
                try? await Task.sleep(for: submitSettle)
            }
            let ok = await client.send(frame: PhoneProtocol.inputFrame(sessionId: sessionId, data: Data([0x0D])))
            DiagLog.shared.log("model", "out input+CR sid=\(sessionId.prefix(8)) ok=\(ok)")
        }
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

    // MARK: Chat abonelik API'si (Task 10)

    /// mode=chat aboneliği: activeSessionId ayarla + chat frame'i gönder.
    public func subscribeChat(_ sessionId: String) {
        // Terminal aboneliğiyle aynı temizlik: eski oturumun sink'i sonlanmazsa
        // geç gelen eski .data ona yield edilir (bkz. subscribe(_:)).
        if let old = activeSessionId, old != sessionId {
            terminalSinks[old]?.finish()
            terminalSinks[old] = nil
            replayBuffers[old] = nil
        }
        activeSessionId = sessionId
        activeChatMode = true
        chatBySession[sessionId] = chatBySession[sessionId] ?? []
        // Şerit mount olmadan gelen scrollback düşmesin (subscribe(_:) paritesi).
        replayBuffers[sessionId] = []
        Task { await client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sessionId, mode: "chat")) }
    }

    public func chatMessages(_ sessionId: String) -> [ChatMessage] {
        chatBySession[sessionId] ?? []
    }

    /// View'ın çizeceği birleşik mesaj listesi: optimistic pending + journal mesajları
    /// + gated streaming balonu (orca buildTransientData). Çağıran `foldChatMessages`
    /// ile turn'lere katlar.
    public func chatRenderMessages(_ sessionId: String) -> [ChatMessage] {
        chatAssembleRenderMessages(
            messages: chatBySession[sessionId] ?? [],
            pending: pendingBySession[sessionId] ?? [],
            streaming: gatedStreaming[sessionId])
    }

    /// Optimistic kullanıcı yankısı ekler (orca pending-echo append).
    private func appendChatPending(_ sessionId: String, text: String) {
        let messages = chatBySession[sessionId] ?? []
        let normalized = normalizeChatUserText(text)
        let baselineOccurrences = chatCountUserTextOccurrences(messages, normalized)
        let baselineTailId = messages.last?.id
        pendingCounter += 1
        pendingBySession[sessionId] = chatPendingAppend(
            current: pendingBySession[sessionId] ?? [],
            id: "pending-\(pendingCounter)", text: text,
            baselineOccurrences: baselineOccurrences,
            baselineTailMessageId: baselineTailId)
    }

    /// Streaming geçidini bir tık ilerletir; sonucu `gatedStreaming`'e yazar. Hem
    /// chat_status hem mesaj değişiminde (chat/chat_append) çağrılır — her ikisi de
    /// güncel turnStatus + folded'a bakar. Turn canlı değilse önizleme verilmez
    /// (orca mobileNativeChatStreamPreview); gerçek mesaj düşünce catch-up ile gizlenir.
    private func recomputeStreaming(_ sessionId: String) {
        let working = turnStatus[sessionId]?.working ?? false
        // Önizleme yalnız turn canlıyken; bitince nil → balon gizlenir (gerçek mesaj
        // o an transcript'te olduğundan boşluk olmaz).
        let preview = working ? (turnStatus[sessionId]?.streamingText) : nil
        let folded = foldChatMessages(chatBySession[sessionId] ?? []).map { $0.message }
        let (newGate, streaming) = chatDeriveStreaming(
            gate: streamingGates[sessionId] ?? ChatStreamGate(),
            folded: folded, incoming: preview, streamLive: working)
        streamingGates[sessionId] = newGate
        gatedStreaming[sessionId] = streaming
        // Teşhis: her chat olayında render listesinin boyutu — vanish'in model mi
        // (items düşüyor) yoksa view mı (items sabit ama ekran boş) olduğunu ayırt eder.
        DiagLog.shared.log("chat", "render sid=\(sessionId.prefix(8)) msgs=\(chatBySession[sessionId]?.count ?? 0) pend=\(pendingBySession[sessionId]?.count ?? 0) stream=\(streaming != nil) items=\(chatRenderMessages(sessionId).count) working=\(working)")
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

    /// Silinen oturumu telefon durumundan tamamen çıkarır (Mac chat silmede
    /// `sessions` yayınlamadığı için — liste + chat/pending/streaming/terminal state).
    private func removeSessionLocally(_ id: String) {
        sessions.removeAll { $0.id == id }
        chatSessionIds.remove(id)
        terminalSinks[id]?.finish()
        terminalSinks[id] = nil
        replayBuffers[id] = nil
        chatBySession[id] = nil
        pendingBySession[id] = nil
        streamingGates[id] = nil
        gatedStreaming[id] = nil
        turnStatus[id] = nil
        prompts[id] = nil
        models[id] = nil
        lastCommandError[id] = nil
        if activeSessionId == id { activeSessionId = nil; activeChatMode = false }
    }

    /// Oturum stream-json chat oturumu mu? Görünüm yönlendirmesi (chat view vs
    /// terminal-mirror) ve `submitText` routing'i BUNU tek kaynak olarak kullanır:
    /// bu telefonun başlattığı chat (yerel izlenen `chatSessionIds`) VEYA `sessions`
    /// broadcast'inde kind:chat — hangisi önce gelirse (broadcast yarışı). Terminal
    /// oturumları (kind nil/"terminal") false döner → mirror görünümü (Faz 2.1: eskiden
    /// TerminalSessionView her oturumu chat modunda açıyordu → terminal oturumu ölü
    /// chat'te "yükleniyor"da takılıyordu).
    public func isChatSession(_ id: String) -> Bool {
        chatSessionIds.contains(id) || sessions.first(where: { $0.id == id })?.kind == "chat"
    }

    // MARK: Komutlar

    public func startSession(repoPath: String, personaId: String?, prompt: String) async {
        startState = .sending
        await dispatch(target: "", action: .startSession(repoPath: repoPath, personaId: personaId, prompt: prompt))
    }

    /// Faz 2: saf chat oturumu başlatır (kind=chat). Mac commandResult'ta sessionId
    /// döndürür; `commandResult` handler otomatik olarak `subscribeChat` çağırır.
    public func startChatSession(repoPath: String) async {
        startState = .sending
        await dispatch(target: "", action: .startSession(repoPath: repoPath, personaId: nil, prompt: "", kind: "chat"))
    }

    public func resetStartState() {
        startState = .idle
    }

    // MARK: Streaming metni (Faz 2 Task 4)

    /// Verilen oturum için canlı streaming metnini döndürür (orca gate paritesi).
    /// working değilse / streaming son assistant metnini geçmiyorsa nil — transcript
    /// yerleşince overlay düşer (spec Faz 2 §E).
    public func chatStreamingText(_ sessionId: String) -> String? {
        let status = turnStatus[sessionId] ?? .idle
        let lastAssistant = chatMessages(sessionId).last(where: { $0.role == .assistant })
        let lastText: String
        if let msg = lastAssistant {
            lastText = msg.blocks.compactMap {
                if case .text(let t, _) = $0 { return t } else { return nil }
            }.joined()
        } else {
            lastText = ""
        }
        return LumiMobileKit.chatStreamingText(working: status.working,
                                               streaming: status.streamingText,
                                               lastAssistantText: lastText)
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
        if case .deleteSession = action { deleteCommandIds.insert(commandId) }
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
