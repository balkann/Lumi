import Foundation

/// Tek bir ws bağlantısının soyutlaması. `incoming` bağlantı kopunca biter
/// (hata ile ya da normal); RelayClient bunu yeniden bağlanma sinyali sayar.
public protocol WebSocketConnection: Sendable {
    var incoming: AsyncThrowingStream<String, Error> { get }
    func send(_ text: String) async throws
    func close()
}

public typealias ConnectionFactory = @Sendable (URL) -> any WebSocketConnection

/// URLSessionWebSocketTask sarmalayıcısı — ince I/O katmanı, birim testi yok
/// (Task 10 uçtan uca doğrulamasıyla kapsanır).
/// @unchecked Sendable: task'e yalnız init'te atanır; URLSessionWebSocketTask
/// thread-safe API sunar.
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
                        receiveNext() // binary frame beklenmez; atla
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
