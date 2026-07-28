import XCTest
@testable import LumiMobileKit

/// Kontrol edilebilir sahte bağlantı: gelen frame'ler dışarıdan itilir, gidenler kaydedilir.
final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<String, Error>
    private let feed: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var sentFrames: [String] = []

    var sent: [String] { lock.withLock { sentFrames } }

    init() {
        (incoming, feed) = AsyncThrowingStream.makeStream()
    }

    func push(_ text: String) { feed.yield(text) }
    func dropConnection() { feed.finish(throwing: URLError(.networkConnectionLost)) }
    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }
    func close() { feed.finish() }
}

/// Bağlantı fabrikası + backoff uykularını kaydeden test tezgahı.
final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [FakeConnection] = []
    private var _sleeps: [Double] = []

    var connections: [FakeConnection] { lock.withLock { _connections } }
    var sleeps: [Double] { lock.withLock { _sleeps } }

    func makeClient() -> RelayClient {
        RelayClient(
            connect: { [self] _ in
                let conn = FakeConnection()
                lock.withLock { _connections.append(conn) }
                return conn
            },
            sleep: { [self] seconds in
                lock.withLock { _sleeps.append(seconds) }
                await Task.yield()
            }
        )
    }
}

private let pairing = PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")
private let welcomeFrame = #"{"v":1,"type":"welcome","payload":{"snapshot":null,"macOnline":true,"lastSeenAt":null}}"#

/// `condition` doğru olana dek bekler (en çok ~2 sn).
func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

final class RelayClientTests: XCTestCase {

    func testSendsHelloFirstAndBecomesConnectedOnWelcome() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        let helloSent = await waitUntil { (harness.connections.first?.sent.count ?? 0) >= 1 }
        XCTAssertTrue(helloSent)
        let hello = harness.connections[0].sent[0]
        XCTAssertTrue(hello.contains(#""type":"hello""#) || hello.contains(#""type": "hello""#))
        XCTAssertTrue(hello.contains("0123456789abcdef"))

        harness.connections[0].push(welcomeFrame)
        let connected = await waitUntil { await client.state == .connected }
        XCTAssertTrue(connected)
        await client.stop()
    }

    func testDeliversDecodedMessagesToEventStream() async {
        let harness = Harness()
        let client = harness.makeClient()
        let stream = await client.events()

        let collector = Task { () -> [ClientEvent] in
            var events: [ClientEvent] = []
            for await event in stream {
                events.append(event)
                if case .message(.event(.transcript)) = event { break }
            }
            return events
        }

        await client.start(pairing: pairing)
        _ = await waitUntil { !harness.connections.isEmpty }
        harness.connections[0].push(welcomeFrame)
        harness.connections[0].push(#"{"v":1,"type":"event","payload":{"kind":"transcript","sessionId":"s1","item":{"itemType":"turn_done"}}}"#)

        let events = await collector.value
        XCTAssertTrue(events.contains(.message(.event(.transcript(sessionId: "s1", item: .turnDone)))))
        XCTAssertTrue(events.contains(.stateChanged(.connected)))
        await client.stop()
    }

    func testReconnectsWithExponentialBackoff() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        _ = await waitUntil { harness.connections.count >= 1 }
        harness.connections[0].dropConnection()
        _ = await waitUntil { harness.connections.count >= 2 }
        harness.connections[1].dropConnection()
        let thirdConnection = await waitUntil { harness.connections.count >= 3 }

        XCTAssertTrue(thirdConnection, "kopan bağlantı yeniden denenmedi")
        XCTAssertEqual(Array(harness.sleeps.prefix(2)), [1, 2])
        await client.stop()
    }

    func testWelcomeResetsBackoff() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)

        _ = await waitUntil { harness.connections.count >= 1 }
        harness.connections[0].dropConnection()                 // → 1 sn
        _ = await waitUntil { harness.connections.count >= 2 }
        harness.connections[1].push(welcomeFrame)               // backoff sıfırlanır
        _ = await waitUntil { await client.state == .connected }
        harness.connections[1].dropConnection()                 // → yine 1 sn
        _ = await waitUntil { harness.connections.count >= 3 }

        XCTAssertEqual(Array(harness.sleeps.prefix(2)), [1, 1])
        await client.stop()
    }

    func testStopClosesAndStopsReconnecting() async {
        let harness = Harness()
        let client = harness.makeClient()
        let stream = await client.events()

        // Collect events until the stream terminates (proves Finding 1 fix).
        let collector = Task { () -> [ClientEvent] in
            var events: [ClientEvent] = []
            for await event in stream { events.append(event) }
            return events
        }

        await client.start(pairing: pairing)
        _ = await waitUntil { harness.connections.count >= 1 }

        await client.stop()
        harness.connections[0].dropConnection()

        // Deterministic: wait until the client is disconnected, then yield a
        // bounded number of times so any reconnect attempt (fake sleep = one
        // yield) would have surfaced.
        _ = await waitUntil { await client.state == .disconnected }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(harness.connections.count, 1, "stop sonrası yeniden bağlanmamalı")
        let state = await client.state
        XCTAssertEqual(state, .disconnected)

        // The stream must have terminated — collector.value must return.
        let collectedEvents = await collector.value
        _ = collectedEvents  // stream terminated; value is available
    }

    func testStopFinishesEventStream() async {
        let harness = Harness()
        let client = harness.makeClient()
        let stream = await client.events()

        let collector = Task { () -> [ClientEvent] in
            var events: [ClientEvent] = []
            for await event in stream { events.append(event) }
            return events
        }

        await client.start(pairing: pairing)
        _ = await waitUntil { harness.connections.count >= 1 }
        harness.connections[0].push(welcomeFrame)
        _ = await waitUntil { await client.state == .connected }

        await client.stop()

        // collector.value must return (stream must be finished by stop()).
        let events = await collector.value
        XCTAssertTrue(events.contains(.stateChanged(.connected)))
        XCTAssertTrue(events.contains(.stateChanged(.disconnected)))
    }

    func testSendCommandWritesFrame() async {
        let harness = Harness()
        let client = harness.makeClient()
        await client.start(pairing: pairing)
        _ = await waitUntil { !harness.connections.isEmpty }
        harness.connections[0].push(welcomeFrame)
        _ = await waitUntil { await client.state == .connected }

        await client.send(command: OutgoingCommand(commandId: "ph-1", action: .pressKey(sessionId: "s1", key: "enter")))

        let sent = await waitUntil { harness.connections[0].sent.count >= 2 }
        XCTAssertTrue(sent)
        XCTAssertTrue(harness.connections[0].sent[1].contains("press_key"))
        await client.stop()
    }

    func testBackoffSequence() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual([backoff.nextDelay(), backoff.nextDelay(), backoff.nextDelay(), backoff.nextDelay()],
                       [1, 2, 4, 8])
        for _ in 0..<10 { _ = backoff.nextDelay() }
        XCTAssertEqual(backoff.nextDelay(), 60)
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
