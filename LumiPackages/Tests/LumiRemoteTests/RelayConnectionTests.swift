import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

final class RelayConnectionTests: XCTestCase {
    func testStartPublishesConnectingThenDisconnectedOnUnreachableHost() async throws {
        let connection = RelayConnection()
        let stream = await connection.inbound()
        // Kapalı porta bağlanma → connecting, ardından disconnected beklenir
        await connection.start(
            url: URL(string: "ws://127.0.0.1:1")!,
            hello: ["role": "mac", "token": "secret-token-1234567890"])

        var states: [RemoteConnectionState] = []
        for await inbound in stream {
            if case .stateChanged(let s) = inbound {
                states.append(s)
                if states.count == 2 { break }
            }
        }
        await connection.stop()
        XCTAssertEqual(states, [.connecting, .disconnected])
    }

    func testStopIsIdempotentAndAllowsRestart() async throws {
        let connection = RelayConnection()
        _ = await connection.inbound()
        await connection.stop()
        await connection.stop()
        await connection.start(
            url: URL(string: "ws://127.0.0.1:1")!,
            hello: ["role": "mac", "token": "secret-token-1234567890"])
        await connection.stop()
        // Çökmeden buraya gelmek yeterli
        XCTAssertTrue(true)
    }
}
