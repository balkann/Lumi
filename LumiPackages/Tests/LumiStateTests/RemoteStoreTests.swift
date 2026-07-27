import Foundation
import XCTest
import LumiKit
@testable import LumiState

@MainActor
private final class FakeRemoteService: RemoteServicing {
    var state: RemoteConnectionState = .disconnected
    var currentConfig = RemoteConfig(enabled: false, relayUrl: "wss://r.test", token: "tok-1234567890123456")
    var startCount = 0
    private var continuation: AsyncStream<RemoteEvent>.Continuation?

    func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async {
        mutate(&currentConfig)
    }
    func regenerateToken() async { currentConfig.token = "yeni-token-1234567890" }
    func start() async { startCount += 1 }
    func stop() {}
    func events() -> AsyncStream<RemoteEvent> {
        let (stream, c) = AsyncStream.makeStream(of: RemoteEvent.self)
        continuation = c
        return stream
    }
    func push(_ e: RemoteEvent) { continuation?.yield(e) }
}

@MainActor
final class RemoteStoreTests: XCTestCase {
    func testStateFollowsServiceEvents() async throws {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        store.start()
        try await Task.sleep(for: .milliseconds(50))
        service.push(.stateChanged(.connected))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.state, .connected)
    }

    func testSetEnabledUpdatesConfig() async {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        await store.setEnabled(true)
        XCTAssertTrue(store.config.enabled)
        XCTAssertTrue(service.currentConfig.enabled)
    }

    func testPairingStringEncodesUrlAndToken() {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        XCTAssertTrue(store.pairingString.hasPrefix("lumi-remote://pair?"))
        XCTAssertTrue(store.pairingString.contains("token=tok-1234567890123456"))
        XCTAssertTrue(store.pairingString.contains("url=wss%3A%2F%2Fr.test"))
    }

    func testRegenerateTokenRefreshesConfig() async {
        let service = FakeRemoteService()
        let store = RemoteStore(service: service)
        await store.regenerateToken()
        XCTAssertEqual(store.config.token, "yeni-token-1234567890")
    }
}
