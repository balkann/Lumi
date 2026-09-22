import Foundation

/// Abstraction for a single WebSocket connection. `incoming` ends when the connection
/// drops (with an error or normally); RelayClient treats this as the reconnect signal.
public protocol WebSocketConnection: Sendable {
    var incoming: AsyncThrowingStream<String, Error> { get }
    func send(_ text: String) async throws
    func close()
}

public typealias ConnectionFactory = @Sendable (URL) -> any WebSocketConnection

/// URLSessionWebSocketTask wrapper — thin I/O layer, no unit tests
/// (covered by Task 10 end-to-end verification).
/// @unchecked Sendable: task is assigned only in init; URLSessionWebSocketTask
/// provides a thread-safe API.
public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    public let incoming: AsyncThrowingStream<String, Error>

    public init(url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        self.incoming = AsyncThrowingStream { continuation in
            @Sendable func receiveNext() {
                task.receive { result in
                    switch result {
                    case .success(.string(let text)):
                        continuation.yield(text)
                        receiveNext()
                    case .success:
                        receiveNext() // binary frames are not expected; skip
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                }
            }
            receiveNext()
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
