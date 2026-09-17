import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiServices

@Suite struct StreamJsonAgentSessionTests {
    @Test func reducesScriptedNdjsonIntoJournalSnapshots() async throws {
        let scripted = [
            #"{"type":"system","subtype":"init","cwd":"/repo","session_id":"S1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"am"}}}"#,
            #"{"type":"assistant","message":{"role":"assistant","id":"msg_1","content":[{"type":"text","text":"Selam"}]}}"#,
            #"{"type":"result","subtype":"success","result":"Selam","total_cost_usd":0.01,"usage":{"output_tokens":2}}"#,
        ]
        let fake = FakeStreamingProcess(scriptedLines: scripted)
        let locator = FixedBinaryLocator(path: "/usr/bin/claude")
        let session = StreamJsonAgentSession(sessionID: "S1", repoPath: "/repo", environment: [:],
                                             spawner: fake, binaryLocator: locator)
        await session.start()
        // Aboneliği emit'ten ÖNCE al: emitAll stream'i hemen bitirir; geç abone
        // olan yalnız başlangıç snapshot'ını görüp finish'i kaçırabilir.
        let stream = await session.snapshots()
        fake.handles.first?.emitAll()
        var final: ChatJournalState?
        for await snap in stream { final = snap }   // stream, child bitince kapanır
        #expect(final?.messages.count == 1)
        #expect(final?.messages.first?.id == "msg_1")
        #expect(final?.turnActive == false)
        #expect(final?.lastCostUSD == 0.01)
    }

    @Test func sendWritesUserMessageNdjson() async throws {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let session = StreamJsonAgentSession(sessionID: "S1", repoPath: "/repo", environment: [:],
                                             spawner: fake, binaryLocator: FixedBinaryLocator(path: "/usr/bin/claude"))
        await session.start()
        await session.send("merhaba")
        let written = fake.handles.first?.written.joined() ?? ""
        #expect(written.contains("\"type\":\"user\""))
        #expect(written.contains("merhaba"))
        #expect(written.hasSuffix("\n"))
        await session.stop()
    }
}

/// Test yardımcısı: sabit yol döndüren binary locator.
struct FixedBinaryLocator: BinaryLocating {
    let path: String?
    func locate(_ name: String, timeout: TimeInterval) async -> String? { path }
}
