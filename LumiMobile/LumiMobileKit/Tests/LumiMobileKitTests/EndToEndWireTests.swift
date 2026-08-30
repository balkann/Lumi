import XCTest
@testable import LumiMobileKit

/// Uçtan-uca (cross-codebase) simülasyon: Mac'in GERÇEK üretici kodunun ürettiği
/// wire baytları (WireContractGeneratorTests → LUMI_WIRE_OUT dosyası), telefonun
/// GERÇEK decoder'ı (PhoneProtocol) + GERÇEK AppModel'iyle oynatılır ve kullanıcının
/// 4 senaryosu doğrulanır. Fixture yolu `LUMI_WIRE_IN` env'inden gelir; verilmezse
/// no-op (hermetik). Böylece Mac→wire→telefon sözleşmesi baytı baytına test edilir.
@MainActor
final class EndToEndWireTests: XCTestCase {

    private struct Fixture {
        let sidA: String
        let sidB: String
        let scenarios: [String: [String]]
    }

    private func loadFixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["LUMI_WIRE_IN"] else {
            throw XCTSkip("LUMI_WIRE_IN verilmedi — uçtan-uca wire simülasyonu atlanıyor")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Fixture(
            sidA: obj["sidA"] as! String,
            sidB: obj["sidB"] as! String,
            scenarios: obj["scenarios"] as! [String: [String]])
    }

    private func makeModel() -> AppModel {
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef"))
        return AppModel(client: FakeRelayClient(), store: store)
    }

    /// Wire string'i GERÇEK decoder'la çözer ve modele verir; decode nil ise test kırılır
    /// (contract drift = decode başarısızlığı = burada yakalanır).
    private func feed(_ model: AppModel, _ wire: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let msg = PhoneProtocol.decodeServerMessage(wire) else {
            XCTFail("wire decode edilemedi (contract drift?): \(wire)", file: file, line: line)
            return
        }
        model.handle(msg)
    }

    private func texts(_ model: AppModel, _ sid: String) -> [String] {
        (model.feeds[sid] ?? []).map { entry in
            switch entry.item {
            case .assistantText(let t): return "text:\(t)"
            case .toolUse(let tool, let s): return "tool:\(tool):\(s)"
            case .question: return "question"
            case .turnDone: return "turn_done"
            case .userMessage(let t, _): return "user:\(t)"
            }
        }
    }

    // MARK: Senaryo 1 — çoklu-oturum crosstalk + reconnect
    func testScenario1NoCrosstalkAndDeadSessionPurged() throws {
        let fx = try loadFixture()
        let frames = fx.scenarios["scenario1_crosstalk_reconnect"]!
        let model = makeModel()

        // Son frame (B'yi düşüren snapshot) hariç hepsini oynat
        for wire in frames.dropLast() { feed(model, wire) }

        let a = texts(model, fx.sidA)
        let b = texts(model, fx.sidB)
        XCTAssertEqual(a, ["text:A-gecmis", "text:A-canli"], "A feed'i yalnız A içeriği")
        XCTAssertEqual(b, ["text:B-gecmis", "text:B-canli"], "B feed'i yalnız B içeriği")
        // Crosstalk yok: A'da B izi, B'de A izi olmamalı
        XCTAssertFalse(a.contains { $0.contains("B-") }, "A feed'inde B içeriği SIZMAMALI")
        XCTAssertFalse(b.contains { $0.contains("A-") }, "B feed'inde A içeriği SIZMAMALI")

        // Son snapshot: B kapandı → B feed'i telefondan düşmeli, A korunmalı
        feed(model, frames.last!)
        XCTAssertEqual(texts(model, fx.sidA), ["text:A-gecmis", "text:A-canli"], "A korunmalı")
        XCTAssertNil(model.feeds[fx.sidB], "ölen oturum feed'i purge edilmeli")
        XCTAssertEqual(model.sessions.count, 1)
    }

    // MARK: Senaryo 2 — süren oturumu açınca sync devam eder
    func testScenario2OpenOngoingSyncsHistoryThenLive() throws {
        let fx = try loadFixture()
        let frames = fx.scenarios["scenario2_open_ongoing"]!
        let model = makeModel()
        for wire in frames { feed(model, wire) }

        XCTAssertEqual(texts(model, fx.sidA), [
            "text:gecmis-1", "tool:Bash:swift test", "turn_done",
            "text:acildiktan-sonra", "turn_done",
        ], "history sonrası canlı akış kesintisiz devam etmeli")
    }

    // MARK: Senaryo 3 — sorular tam & biçimli (Türkçe karakter dahil)
    func testScenario3QuestionsWellFormattedAndComplete() throws {
        let fx = try loadFixture()
        let frames = fx.scenarios["scenario3_questions"]!
        let model = makeModel()

        // frame 0: snapshot (waiting); frame 1: AskUserQuestion (2 soru)
        feed(model, frames[0])
        feed(model, frames[1])
        let card = model.questionCard(for: fx.sidA)
        XCTAssertNotNil(card?.questions, "AskUserQuestion kartı görünmeli")
        let qs = card!.questions!
        XCTAssertEqual(qs.count, 2, "iki soru da eksiksiz gelmeli")
        XCTAssertEqual(qs[0].header, "Onay")
        XCTAssertEqual(qs[0].question, "Devam edilsin mi?")
        XCTAssertEqual(qs[0].options, ["Evet", "Hayır", "Belki"], "seçenekler tam & Türkçe karakterler bozulmamalı")
        XCTAssertEqual(qs[1].header, "Mod")
        XCTAssertEqual(qs[1].options, ["Hızlı", "Güvenli"])

        // frame 2: ekran-scrape izin promptu → kart bunu gösterir (3 seçenek)
        feed(model, frames[2])
        let perm = model.questionCard(for: fx.sidA)
        XCTAssertEqual(perm?.questions?.first?.header, "İzin isteği")
        XCTAssertEqual(perm?.questions?.first?.options,
                       ["Evet", "Evet, bir daha sorma", "Hayır"], "izin seçenekleri eksiksiz")

        // frame 3: boş questions [] → kart temizlenir
        feed(model, frames[3])
        // waiting rozeti hâlâ var → jenerik kart dönebilir ama gerçek soru kartı kalkmalı
        XCTAssertNil(model.questionCard(for: fx.sidA)?.questions,
                     "prompt kalkınca soru kartı temizlenmeli")
    }

    // MARK: Senaryo 3b — reconnect'te aktif prompt snapshot'tan kurulur
    func testScenario3ReconnectRebuildsActivePrompt() throws {
        let fx = try loadFixture()
        let frames = fx.scenarios["scenario3_reconnect_activeprompt"]!
        let model = makeModel()
        feed(model, frames[0]) // welcome + snapshot.activePrompt
        let card = model.questionCard(for: fx.sidA)
        XCTAssertEqual(card?.questions?.first?.options,
                       ["Evet", "Evet, bir daha sorma", "Hayır"],
                       "reconnect'te aktif prompt kartı snapshot'tan yeniden kurulmalı")
    }

    // MARK: Senaryo 4 — /clear session reset
    func testScenario4ClearResetsFeedThenRepopulates() throws {
        let fx = try loadFixture()
        let frames = fx.scenarios["scenario4_clear_reset"]!
        let model = makeModel()

        feed(model, frames[0]) // snapshot
        feed(model, frames[1]) // clear-oncesi
        XCTAssertEqual(texts(model, fx.sidA), ["text:clear-oncesi"])

        feed(model, frames[2]) // session_reset
        XCTAssertEqual(model.feeds[fx.sidA] ?? [], [], "/clear feed'i sıfırlamalı")

        feed(model, frames[3]) // clear-sonrasi
        XCTAssertEqual(texts(model, fx.sidA), ["text:clear-sonrasi"],
                       "reset sonrası yalnız yeni içerik; eski sohbet dönmemeli")
    }
}
