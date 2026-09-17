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

        // Tek satır: tam olarak bir \n, sonda.
        let lines = written.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2 && lines[1].isEmpty, "Tam olarak bir NDJSON satırı olmalı")
        #expect(written.hasSuffix("\n"))

        // JSON yapısını decode edip doğrula.
        struct Content: Decodable { let type: String; let text: String }
        struct Message: Decodable { let role: String; let content: [Content] }
        struct Envelope: Decodable { let type: String; let message: Message }

        let data = Data(lines[0].utf8)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.type == "user")
        #expect(envelope.message.role == "user")
        #expect(envelope.message.content.count == 1)
        #expect(envelope.message.content[0].type == "text")
        #expect(envelope.message.content[0].text == "merhaba")

        await session.stop()
    }

    @Test func snapshotsAfterStopFinishesImmediately() async throws {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let session = StreamJsonAgentSession(sessionID: "S1", repoPath: "/repo", environment: [:],
                                             spawner: fake, binaryLocator: FixedBinaryLocator(path: "/usr/bin/claude"))
        await session.start()
        await session.stop()
        // stop'tan SONRA abone olan: state yield + finish; for await asılı kalmaz.
        var count = 0
        for await _ in await session.snapshots() { count += 1 }
        #expect(count == 1)   // yalnız başlangıç state'i, sonra finish
    }
}

/// Test yardımcısı: sabit yol döndüren binary locator.
struct FixedBinaryLocator: BinaryLocating {
    let path: String?
    func locate(_ name: String, timeout: TimeInterval) async -> String? { path }
}
