import Foundation

public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected
}

public enum ClientEvent: Sendable, Equatable {
    case stateChanged(ConnectionState)
    case message(ServerMessage)
}

/// 1,2,4,8,…60 sn üstel geri çekilme (Mac tarafındaki ReconnectBackoff'un aynısı).
public struct ReconnectBackoff: Sendable {
    private var attempt = 0
    private let capSeconds: Double = 60

    public init() {}

    public mutating func nextDelay() -> Double {
        let delay = min(pow(2, Double(attempt)), capSeconds)
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}

/// AppModel'in gördüğü sınır — testlerde FakeRelayClient bunu implemente eder.
public protocol RelayClienting: Sendable {
    func events() async -> AsyncStream<ClientEvent>
    func start(pairing: PairingInfo) async
    func stop() async
    @discardableResult func send(command: OutgoingCommand) async -> Bool
    /// Ham zarf frame'i gönderir (terminal-ayna subscribe/unsubscribe/input).
    @discardableResult func send(frame: String) async -> Bool
    func registerPush(deviceToken: String) async
    func unregisterPush(deviceToken: String) async
}

/// Relay'e telefon rolüyle bağlanan istemci: hello → welcome → mesaj akışı;
/// kopunca üstel backoff ile yeniden bağlanır (tasarım §9).
public actor RelayClient: RelayClienting {
    public private(set) var state: ConnectionState = .disconnected

    private let connect: ConnectionFactory
    private let sleep: @Sendable (Double) async -> Void
    private var backoff = ReconnectBackoff()
    private var connection: (any WebSocketConnection)?
    private var runTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]

    public init(
        connect: @escaping ConnectionFactory = { URLSessionWebSocketConnection(url: $0) },
        sleep: @escaping @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.connect = connect
        self.sleep = sleep
    }

    public func events() -> AsyncStream<ClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start(pairing: PairingInfo) {
        guard runTask == nil, let url = URL(string: pairing.relayUrl) else { return }
        let token = pairing.token
        runTask = Task { await run(url: url, token: token) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        connection?.close()
        connection = nil
        backoff.reset()
        setState(.disconnected)
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    @discardableResult
    public func send(command: OutgoingCommand) async -> Bool {
        await sendFrame(PhoneProtocol.commandFrame(command))
    }

    @discardableResult
    public func send(frame: String) async -> Bool {
        await sendFrame(frame)
    }

    public func registerPush(deviceToken: String) async {
        _ = await sendFrame(PhoneProtocol.registerPushFrame(deviceToken: deviceToken))
    }

    public func unregisterPush(deviceToken: String) async {
        _ = await sendFrame(PhoneProtocol.unregisterPushFrame(deviceToken: deviceToken))
    }

    // MARK: İç işleyiş

    private func run(url: URL, token: String) async {
        while !Task.isCancelled {
            setState(.connecting)
            DiagLog.shared.log("relay", "bağlanıyor \(url.host ?? url.absoluteString)")
            let conn = connect(url)
            connection = conn
            do {
                try await conn.send(PhoneProtocol.helloFrame(token: token))
                for try await frame in conn.incoming {
                    guard let message = PhoneProtocol.decodeServerMessage(frame) else {
                        DiagLog.shared.log("relay", "decode edilemeyen frame \(frame.prefix(80))")
                        continue
                    }
                    if case .welcome = message {
                        backoff.reset()
                        setState(.connected)
                    }
                    yield(.message(message))
                }
                DiagLog.shared.log("relay", "akış kapandı (sunucu tarafı)")
            } catch {
                // kopma → aşağıda backoff ile yeniden dene
                DiagLog.shared.log("relay", "koptu: \(error.localizedDescription)")
            }
            connection = nil
            if Task.isCancelled { return }
            setState(.disconnected)
            await sleep(backoff.nextDelay())
        }
    }

    private func sendFrame(_ frame: String) async -> Bool {
        guard let connection else {
            DiagLog.shared.log("relay", "send atlandı (bağlantı yok)")
            return false
        }
        do {
            try await connection.send(frame)
            return true
        } catch {
            DiagLog.shared.log("relay", "send başarısız: \(error.localizedDescription)")
            return false
        }
    }

    private func setState(_ newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        DiagLog.shared.log("relay", "state \(newState)")
        yield(.stateChanged(newState))
    }

    private func yield(_ event: ClientEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
