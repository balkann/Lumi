import XCTest
@testable import LumiMobileKit

// ---------------------------------------------------------------------------
// EndToEndWireTests — Telefon tarafı E2E tel testi
//
// Gerçek relay'e bağlanmadan, relay'in ürettiği TAM JSON zarf dizgelerini
// gerçek bir AppModel'e enjekte ederek PhoneProtocol decode → AppModel rota
// zincirinin bütünüyle doğrular.
//
// Sahte katman: FakeRelayClient (RelayClientTests'ten) — gelen frame'ler dışarıdan
// itilir, giden frame'ler kaydedilir.
// Gerçek katman: AppModel + PhoneProtocol (kaynak kodu değişmeden).
//
// Örtülen senaryo (task-12-brief §Part B):
//   1. welcome/sessions mesajı → model.sessions dolar.
//   2. model.subscribe("s1") → client'a subscribe frame gönderilir.
//   3. scrollback (base64 "SCROLL") + data (base64 "LIVE") → terminalStream
//      bunları SIRAYLA "SCROLL" sonra "LIVE" olarak verir.
//   4. model.sendInput("s1", Data("hi")) → client'a input frame gönderilir,
//      base64 "aGk=" payload içerir.
// ---------------------------------------------------------------------------

// MARK: - Yardımcılar

/// Verilen frame string'ini relay'den gelen mesaj olarak AppModel'e enjekte eder.
@MainActor
private func injectFrame(_ frame: String, into client: FakeRelayClient) {
    if let message = PhoneProtocol.decodeServerMessage(frame) {
        client.emit(.message(message))
    }
}

/// `condition` doğru olana dek bekler (en çok ~2 sn).
@MainActor
private func waitFor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// `client.sentFrames` içinde `needle` geçen bir frame gelene dek bekler.
@MainActor
private func awaitFrame(_ client: FakeRelayClient, containing needle: String) async {
    for _ in 0..<200 where !client.sentFrames.contains(where: { $0.contains(needle) }) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Test

@MainActor
final class EndToEndWireTests: XCTestCase {

    // MARK: Adım 1: welcome+sessions mesajı — model.sessions dolar

    func testStep1_WelcomeWithSessionsPopulatesModel() {
        let client = FakeRelayClient()
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        let model = AppModel(client: client, store: store)

        // Relay'in ürettiği gerçek wire JSON'u (envelope {v:1,type,payload}).
        // sessions: SessionMeta dizisi; alanlar: id, repoName, status, cols, rows.
        let frame = #"""
        {"v":1,"type":"sessions","payload":{"sessions":[
          {"id":"s1","repoName":"lumi","status":"working","cols":220,"rows":50}
        ]}}
        """#

        guard let msg = PhoneProtocol.decodeServerMessage(frame) else {
            return XCTFail("PhoneProtocol frame'i decode edemedi")
        }
        model.handle(msg)

        XCTAssertEqual(model.sessions.count, 1)
        let meta = model.sessions[0]
        XCTAssertEqual(meta.id, "s1")
        XCTAssertEqual(meta.repoName, "lumi")
        XCTAssertEqual(meta.status, "working")
        XCTAssertEqual(meta.cols, 220)
        XCTAssertEqual(meta.rows, 50)
        XCTAssertTrue(model.macOnline, "sessions mesajı Mac'ten gelir → macOnline true")
    }

    // MARK: Adım 2: subscribe → client subscribe frame gönderir

    func testStep2_SubscribeSendsSubscribeFrame() async {
        let client = FakeRelayClient()
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        let model = AppModel(client: client, store: store)

        model.subscribe("s1")
        XCTAssertEqual(model.activeSessionId, "s1")

        await awaitFrame(client, containing: #""type":"subscribe""#)

        let subscribeFrames = client.sentFrames.filter { $0.contains(#""type":"subscribe""#) }
        XCTAssertFalse(subscribeFrames.isEmpty, "subscribe frame gönderilmeli")
        XCTAssertTrue(subscribeFrames.contains { $0.contains("s1") }, "s1 sessionId içermeli")
    }

    // MARK: Adım 3: scrollback + data → terminalStream sıralı verir

    func testStep3_ScrollbackThenDataArrivedInOrder() async throws {
        let client = FakeRelayClient()
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        let model = AppModel(client: client, store: store)

        // Subscribe: hem activeSessionId'yi set eder hem replay tamponunu başlatır.
        model.subscribe("s1")

        // Relay'in ürettiği gerçek wire JSON'ları.
        // "SCROLL" → base64 = "U0NST0xM"
        let scrollB64 = Data("SCROLL".utf8).base64EncodedString()
        let scrollbackFrame = """
        {"v":1,"type":"scrollback","payload":{"sessionId":"s1","seq":0,"cols":80,"rows":24,"data":"\(scrollB64)"}}
        """
        // "LIVE" → base64 = "TElWRQ=="
        let liveB64 = Data("LIVE".utf8).base64EncodedString()
        let dataFrame = """
        {"v":1,"type":"data","payload":{"sessionId":"s1","seq":1,"data":"\(liveB64)"}}
        """

        // scrollback view stream'e bağlanmadan önce geldi → replay tamponuna birikir.
        guard let scrollMsg = PhoneProtocol.decodeServerMessage(scrollbackFrame) else {
            return XCTFail("scrollback frame decode edilemedi")
        }
        model.handle(scrollMsg)

        // Şimdi view stream'e bağlanır → tamponlanan scrollback ilk olarak replay edilir.
        let stream = model.terminalStream("s1")

        // Canlı data chunk'ı gönderilir.
        guard let dataMsg = PhoneProtocol.decodeServerMessage(dataFrame) else {
            return XCTFail("data frame decode edilemedi")
        }
        model.handle(dataMsg)

        // Stream'den 2 chunk toplayıp sırayı doğrula.
        var chunks: [TerminalChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
            if chunks.count == 2 { break }
        }

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].bytes, Data("SCROLL".utf8), "ilk chunk scrollback olmalı")
        XCTAssertEqual(chunks[0].seq, 0)
        XCTAssertEqual(chunks[0].cols, 80)
        XCTAssertEqual(chunks[0].rows, 24)
        XCTAssertEqual(chunks[1].bytes, Data("LIVE".utf8), "ikinci chunk canlı data olmalı")
        XCTAssertEqual(chunks[1].seq, 1)
    }

    // MARK: Adım 4: sendInput → base64 input frame gönderilir

    func testStep4_SendInputSendsBase64InputFrame() async {
        let client = FakeRelayClient()
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        let model = AppModel(client: client, store: store)

        model.sendInput("s1", Data("hi".utf8))

        await awaitFrame(client, containing: #""type":"input""#)

        let inputFrames = client.sentFrames.filter { $0.contains(#""type":"input""#) }
        XCTAssertFalse(inputFrames.isEmpty, "input frame gönderilmeli")

        // "hi" → base64 = "aGk="
        let expectedB64 = Data("hi".utf8).base64EncodedString()  // "aGk="
        XCTAssertEqual(expectedB64, "aGk=")
        XCTAssertTrue(
            inputFrames.contains { $0.contains(expectedB64) },
            "input frame base64(\\'hi\\') = '\(expectedB64)' içermeli"
        )
        XCTAssertTrue(
            inputFrames.contains { $0.contains("s1") },
            "input frame sessionId \\'s1\\' içermeli"
        )
    }

    // MARK: Birleşik tam tur E2E testi

    func testFullRoundTrip_WelcomeSubscribeScrollbackDataInput() async throws {
        let client = FakeRelayClient()
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        let model = AppModel(client: client, store: store)

        // --- Adım 1: welcome sessions ile gelir ---
        let welcomeFrame = #"""
        {"v":1,"type":"welcome","payload":{"macOnline":true,"lastSeenAt":null,"sessions":[
          {"id":"s1","repoName":"myrepo","status":"idle","cols":200,"rows":50}
        ]}}
        """#
        guard let welcomeMsg = PhoneProtocol.decodeServerMessage(welcomeFrame) else {
            return XCTFail("welcome frame decode edilemedi")
        }
        model.handle(welcomeMsg)

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].id, "s1")
        XCTAssertEqual(model.sessions[0].repoName, "myrepo")
        XCTAssertTrue(model.macOnline)

        // --- Adım 2: phone subscribe gönderir ---
        model.subscribe("s1")
        await awaitFrame(client, containing: #""type":"subscribe""#)
        XCTAssertTrue(
            client.sentFrames.contains { $0.contains(#""type":"subscribe""#) && $0.contains("s1") },
            "subscribe frame gönderilmiş olmalı"
        )
        client.clearSentFrames()

        // --- Adım 3: scrollback gelir (view bağlanmadan önce → replay tamponunda) ---
        let scrollB64 = Data("SCROLL".utf8).base64EncodedString()
        let scrollbackFrame = """
        {"v":1,"type":"scrollback","payload":{"sessionId":"s1","seq":0,"cols":80,"rows":24,"data":"\(scrollB64)"}}
        """
        guard let scrollMsg = PhoneProtocol.decodeServerMessage(scrollbackFrame) else {
            return XCTFail("scrollback frame decode edilemedi")
        }
        model.handle(scrollMsg)

        // View stream'e bağlanır.
        let stream = model.terminalStream("s1")

        // Canlı data chunk'ı gelir.
        let liveB64 = Data("LIVE".utf8).base64EncodedString()
        let dataFrame = """
        {"v":1,"type":"data","payload":{"sessionId":"s1","seq":1,"data":"\(liveB64)"}}
        """
        guard let dataMsg = PhoneProtocol.decodeServerMessage(dataFrame) else {
            return XCTFail("data frame decode edilemedi")
        }
        model.handle(dataMsg)

        // Stream'den 2 chunk toplayıp sırayı doğrula.
        var chunks: [TerminalChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
            if chunks.count == 2 { break }
        }

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].bytes, Data("SCROLL".utf8), "ilk chunk scrollback olmalı")
        XCTAssertEqual(chunks[1].bytes, Data("LIVE".utf8), "ikinci chunk canlı data olmalı")

        // --- Adım 4: phone input gönderir → mac alır ---
        model.sendInput("s1", Data("hi".utf8))
        await awaitFrame(client, containing: #""type":"input""#)

        let inputFrame = client.sentFrames.first { $0.contains(#""type":"input""#) }
        XCTAssertNotNil(inputFrame, "input frame gönderilmiş olmalı")
        XCTAssertTrue(inputFrame!.contains("aGk="), "base64(\\'hi\\') = 'aGk=' input frame içinde olmalı")
        XCTAssertTrue(inputFrame!.contains("s1"), "sessionId 's1' input frame içinde olmalı")
    }
}
