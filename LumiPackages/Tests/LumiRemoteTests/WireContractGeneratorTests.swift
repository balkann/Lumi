import Foundation
import XCTest
import LumiKit
@testable import LumiRemote

/// Üretici (Mac) tarafının GERÇEK wire baytlarını üretip diske döker; telefon tarafı
/// (LumiMobileKit) bu baytları GERÇEK decoder + AppModel ile oynatıp doğrular
/// (cross-codebase sözleşme/uçtan-uca simülasyonu). Yalnız `LUMI_WIRE_OUT` env'i
/// verildiğinde çalışır; normal `swift test`te no-op (hermetik kalır).
///
/// Kapsanan 4 senaryo (kullanıcının test istekleri):
///  1. Çoklu-oturum crosstalk + reconnect: A/B oturumları karışmaz; ölen oturum düşer.
///  2. Süren oturumu telefonda açınca sync devam eder (history + canlı append).
///  3. Claude'un soruları telefonda tam & biçimli görünür (AskUserQuestion + ekran-scrape).
///  4. /clear → session_reset: feed + soru kartı sıfırlanır, yeni içerik doldurur.
final class WireContractGeneratorTests: XCTestCase {

    private func env(type: String, payload: [String: Any]) -> [String: Any] {
        // Relay'in telefona ilettiği zarf ({v,type,payload}) — RemoteProtocol.envelope ile birebir.
        ["v": RemoteProtocol.version, "type": type, "payload": payload]
    }

    private func meta(_ id: TerminalID, repo: String, status: TerminalStatus, title: String? = nil) -> TerminalMeta {
        TerminalMeta(id: id, name: "t", repoPath: repo, createdAt: Date(), oscTitle: title, status: status)
    }

    func testGenerateWireFixtures() throws {
        guard let outPath = ProcessInfo.processInfo.environment["LUMI_WIRE_OUT"] else {
            throw XCTSkip("LUMI_WIRE_OUT verilmedi — üretici jeneratörü atlanıyor")
        }

        let repo = "/tmp/demo-repo"
        let repos = [Repo(name: "demo-repo", path: repo, isGitRepo: true, source: .projectsRoot)]
        let personas = [Persona(id: "reviewer", label: "Reviewer")]

        let idA = TerminalID(), idB = TerminalID()
        let sidA = idA.description, sidB = idB.description

        var scenarios: [String: [[String: Any]]] = [:]

        // MARK: Senaryo 1 — crosstalk + reconnect
        do {
            var frames: [[String: Any]] = []
            // reconnect: welcome (relay, Mac'in son snapshot'ıyla) — iki oturum canlı
            let snap = SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .working),
                            meta(idB, repo: repo, status: .working)],
                repos: repos, personas: personas)
            frames.append(env(type: "welcome",
                              payload: ["snapshot": snap, "macOnline": true, "lastSeenAt": NSNull()]))
            // telefon her oturumu açınca get_history → history (GERÇEK itemPayload)
            frames.append(env(type: "event", payload: [
                "kind": "history", "sessionId": sidA,
                "items": [FeedItem.assistantText("A-gecmis").itemPayload]]))
            frames.append(env(type: "event", payload: [
                "kind": "history", "sessionId": sidB,
                "items": [FeedItem.assistantText("B-gecmis").itemPayload]]))
            // canlı transcript — her biri kendi oturumuna (GERÇEK eventPayload)
            frames.append(env(type: "event", payload: FeedItem.assistantText("A-canli").eventPayload(sessionId: sidA)))
            frames.append(env(type: "event", payload: FeedItem.assistantText("B-canli").eventPayload(sessionId: sidB)))
            // B oturumu kapanır → yeni snapshot yalnız A (ölen oturum feed'i telefondan düşmeli)
            let snap2 = SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .working)],
                repos: repos, personas: personas)
            frames.append(env(type: "snapshot", payload: snap2))
            scenarios["scenario1_crosstalk_reconnect"] = frames
        }

        // MARK: Senaryo 2 — süren oturumu açınca sync devam
        do {
            var frames: [[String: Any]] = []
            frames.append(env(type: "snapshot", payload: SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .working)],
                repos: repos, personas: personas)))
            // detay açıldı → history (geçmiş)
            frames.append(env(type: "event", payload: [
                "kind": "history", "sessionId": sidA,
                "items": [
                    FeedItem.assistantText("gecmis-1").itemPayload,
                    FeedItem.toolUse(name: "Bash", summary: "swift test").itemPayload,
                    FeedItem.turnDone.itemPayload,
                ]]))
            // sonra canlı akış devam eder
            frames.append(env(type: "event", payload: FeedItem.assistantText("acildiktan-sonra").eventPayload(sessionId: sidA)))
            frames.append(env(type: "event", payload: FeedItem.turnDone.eventPayload(sessionId: sidA)))
            scenarios["scenario2_open_ongoing"] = frames
        }

        // MARK: Senaryo 3 — sorular tam & biçimli
        do {
            var frames: [[String: Any]] = []
            frames.append(env(type: "snapshot", payload: SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .waitingUnseen)],
                repos: repos, personas: personas)))
            // AskUserQuestion (transcript) — 2 soru, çok seçenek (GERÇEK üretici)
            let q1 = Question(header: "Onay", question: "Devam edilsin mi?", options: ["Evet", "Hayır", "Belki"])
            let q2 = Question(header: "Mod", question: "Hangi mod?", options: ["Hızlı", "Güvenli"])
            frames.append(env(type: "event", payload: FeedItem.question(payload: [q1, q2]).eventPayload(sessionId: sidA)))
            // ekran-scrape prompt (izin) — SnapshotBuilder.promptEvent (GERÇEK üretici)
            let detected = DetectedPrompt(kind: .permission,
                                          questionText: "Bash komutunu çalıştırmaya izin ver?",
                                          options: ["Evet", "Evet, bir daha sorma", "Hayır"])
            frames.append(env(type: "event", payload: SnapshotBuilder.promptEvent(sessionId: sidA, prompt: detected)))
            // prompt kalkar → boş questions [] = kartı temizle
            frames.append(env(type: "event", payload: SnapshotBuilder.promptEvent(sessionId: sidA, prompt: nil)))
            scenarios["scenario3_questions"] = frames

            // reconnect'te aktif prompt snapshot.activePrompt'tan kurulmalı
            var frames2: [[String: Any]] = []
            let snapWithPrompt = SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .waitingUnseen)],
                repos: repos, personas: personas,
                activePrompts: [idA: detected])
            frames2.append(env(type: "welcome",
                               payload: ["snapshot": snapWithPrompt, "macOnline": true, "lastSeenAt": NSNull()]))
            scenarios["scenario3_reconnect_activeprompt"] = frames2
        }

        // MARK: Senaryo 4 — /clear session reset
        do {
            var frames: [[String: Any]] = []
            frames.append(env(type: "snapshot", payload: SnapshotBuilder.snapshot(
                terminals: [meta(idA, repo: repo, status: .working)],
                repos: repos, personas: personas)))
            frames.append(env(type: "event", payload: FeedItem.assistantText("clear-oncesi").eventPayload(sessionId: sidA)))
            // /clear → session_reset (GERÇEK üretici)
            frames.append(env(type: "event", payload: SnapshotBuilder.sessionResetEvent(sessionId: sidA)))
            // yeni oturum içeriği
            frames.append(env(type: "event", payload: FeedItem.assistantText("clear-sonrasi").eventPayload(sessionId: sidA)))
            scenarios["scenario4_clear_reset"] = frames
        }

        // Her frame'i wire STRING'e çevir (telefonun aldığı tam bayt) + oturum id'lerini de yaz.
        var out: [String: Any] = ["sidA": sidA, "sidB": sidB]
        var stringScenarios: [String: [String]] = [:]
        for (name, frames) in scenarios {
            stringScenarios[name] = try frames.map { frame in
                let data = try JSONSerialization.data(withJSONObject: frame)
                return String(decoding: data, as: UTF8.self)
            }
        }
        out["scenarios"] = stringScenarios

        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        print("WIRE_FIXTURE_WRITTEN \(outPath) bytes=\(data.count)")
    }
}
