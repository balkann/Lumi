# Orca Chat Yaşam Döngüsü — Bug'sız Parite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefondan ajan başlatma / sohbete devam / var olan chat'i açma akışlarını orca paritesinde bug'sız kılmak — mesajlar tamamlandığında gelir (token token değil), prompt kartları (gruplu dahil) çalışır, ve wire tipleri tek kaynaktan gelir.

**Architecture:** Kök bug, `RemoteService.handleSubscribe`'ın `mode=chat`'te `claudeSessionID` çözemeyince sessizce ham-PTY terminal moduna düşmesidir (satır 248-262). Bu düşüş kaldırılır (Bileşen A), dış oturumlar için transcript keşfi eklenir (Bileşen B), wire tipleri saf-Foundation `LumiWire` target'ında birleştirilir (Bileşen C), gruplu prompt kartı bitirilir (Bileşen D).

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), swift-testing (`import Testing`, `@Test`/`@Suite`/`#expect`), SwiftPM çok-modüllü paket (LumiPackages) + ayrı iOS paketi (LumiMobileKit) + XcodeGen iOS app, TypeScript relay (değişmez).

## Global Constraints

- **main'e commit YASAK** — tüm iş `feat/remote-orca-main` dalında.
- **Tek Lumi kuralı:** transport = Lumi relay (`RelayServer/`); relay/protokol frame tipleri değişmez, yalnız yeni alanlar additive eklenir.
- **Persistence uyumluluğu:** `~/.lumi` altındaki JSON/YAML aynen okunur/yazılır; Config tipleri Codable değildir.
- **LumiUI literal yok:** font/radius/spacing için `Theme.*` token'ları zorunlu; her `#Preview` `#if DEBUG` içinde.
- **Zorunlu mimari:** PTY→UI ack-backpressure, render-crash izolasyonu, replay güvenliği bozulmaz.
- **LumiWire saf-Foundation:** yalnız `import Foundation`; AppKit/UIKit/SwiftUI import edemez (iOS'tan da derlenir).
- **Test komutları:** `cd LumiPackages && swift build && swift test`; iOS: `cd LumiMobile/LumiMobileKit && swift test`.
- **iOS Xcode projesi üretilir:** yeni dosya/bağımlılıkta `cd LumiMobile && xcodegen generate` (bayat proje build kırar).
- **Diag:** kalıcı log için `DiagLog`/`rlog` kullan; `print` değil.

---

### Task 1: Bileşen A — chat modu asla ham-PTY'ye düşmesin

Kök "token token" fix. `handleSubscribe`, `mode=chat`'te `claudeSessionID` yoksa terminal moduna DÜŞMEZ; boş chat snapshot + `chat_status` yayınlar, PTY stream'i kurmaz. Failing test aynı zamanda teşhis teyididir (mevcut kod `scrollback` yollar).

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift:248-262` (handleSubscribe chat dalı)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift` (yeni)

**Interfaces:**
- Consumes: `RemoteService(paths:terminal:repos:connection:chatSource:hookEvents:)`, `FakeRelayConnection` (`injectInbound`, `waitForSent`, `waitForCount`, `sentTypes()`), `FakeTerminalServicing` (`metas`), `TerminalMeta(id:name:repoPath:createdAt:claudeSessionID:)`.
- Produces: davranış — `claudeSessionID == nil` + transcript yoksa `chat` (messages boş) + `chat_status` gönderilir, `scrollback` **gönderilmez**, PTY output aboneliği kurulmaz.

- [ ] **Step 1: Failing test yaz**

`LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift`:
```swift
import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiRemote

@Suite @MainActor struct RemoteServiceChatFallbackTests {
    @Test func chatSubscribeWithoutClaudeSessionDoesNotFallToTerminal() async throws {
        let conn = FakeRelayConnection()
        let term = FakeTerminalServicing()
        let hooks = FakeAgentHookServer()
        let uuid = UUID()
        // claudeSessionID YOK (dış/taze oturum) → eski kod PTY'ye düşerdi.
        term.metas.append(TerminalMeta(id: TerminalID(raw: uuid), name: "T",
            repoPath: "/no/transcript/repo", createdAt: Date(), claudeSessionID: nil))
        let sid = TerminalID(raw: uuid).description
        let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
            connection: conn, chatSource: FakeChatTranscriptSource(events: []), hookEvents: hooks.events())
        await svc.start()
        await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
        try await conn.waitForSent(types: ["chat_status"])
        // Ham-PTY yolu ASLA kurulmaz:
        #expect(await conn.sentTypes().contains("scrollback") == false)
        #expect(await conn.sentTypes().contains("data") == false)
        svc.stop()
    }
}
```

- [ ] **Step 2: Testi koştur, kırıldığını gör**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatFallbackTests 2>&1 | tail -20`
Expected: FAIL — mevcut kod `scrollback` gönderdiği için `#expect(...contains("scrollback") == false)` başarısız. (Bu, "token token = fallback" teşhisinin kanıtıdır.)

> Not: `FakeRelayConnection` içinde `sentTypes() -> [String]` yoksa ekle (mevcut `waitForSent`/`lastString` gönderilen frame'leri zaten tutuyor; tiplerini döndüren küçük accessor). Dosya: `LumiPackages/Sources/LumiTestSupport/FakeRelayConnection.swift`.

- [ ] **Step 3: Fix — fallback dalını kaldır, chat-unavailable yayınla**

`RemoteService.swift` handleSubscribe chat dalında (satır 250 `guard`), fallback bloğunu (terminal moduna düşen 253-261) şununla değiştir:
```swift
let meta = terminal.terminals.first(where: { $0.id == id })
guard let meta else { return }
guard let claudeSessionID = meta.claudeSessionID else {
    rlog("chat subscribe: claudeSessionID yok, PTY'ye DÜŞMÜYOR — chat-unavailable: repo=\(meta.repoPath)")
    // Ham-PTY'ye düşme. Boş chat + working:false durumu; Task 3 transcript keşfi bağlar.
    await connection.send(type: "chat",
        payload: RemoteProtocol.chatPayload(sessionId: raw, messages: []))
    await emitTurnStatus(id: id, status: .idle)
    chatSubscriptions[id] = Task { [weak self] in await self?.awaitTranscript(id: id, raw: raw, meta: meta) }
    return
}
```
`awaitTranscript` Task 3'te tanımlanacak; şimdilik derlensin diye geçici stub ekle (Task 3 gerçek gövdeyi yazar):
```swift
private func awaitTranscript(id: TerminalID, raw: String, meta: TerminalMeta) async { /* Task 3 */ }
```

- [ ] **Step 4: Testi koştur, geçtiğini gör**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatFallbackTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Tüm LumiRemote testleri yeşil (regresyon)**

Run: `cd LumiPackages && swift test --filter LumiRemoteTests 2>&1 | tail -20`
Expected: PASS (mevcut prompt/turn-status/subscribe testleri kırılmamış).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift \
  LumiPackages/Sources/LumiTestSupport/FakeRelayConnection.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift
git commit -m "fix(remote): chat modu claudeSessionID yokken ham-PTY'ye düşmez (Bileşen A)"
```

---

### Task 2: Bileşen B1 — TranscriptLocator (saf, dış oturum transcript keşfi)

`repoPath` verilince `~/.claude/projects/<encoded>/` altındaki en yeni `.jsonl`'in sessionID'sini bulan saf, enjekte-edilebilir bileşen. Lumi-dışı oturumları chat'e bağlamayı sağlar.

**Files:**
- Create: `LumiPackages/Sources/LumiServices/NativeChat/TranscriptLocator.swift`
- Test: `LumiPackages/Tests/LumiServicesTests/TranscriptLocatorTests.swift` (yeni)

**Interfaces:**
- Produces: `struct TranscriptLocator { init(fileList: @escaping (String) -> [(sessionID: String, modified: Date)]); func locate(repoPath: String) -> String? }` — en yeni `modified`'a sahip sessionID'yi döndürür; liste boşsa `nil`. Kodlama kuralı `RemoteService`'deki ile aynı: `repoPath.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)`.
- Consumes: (yok — saf).

- [ ] **Step 1: Failing test yaz**

`LumiPackages/Tests/LumiServicesTests/TranscriptLocatorTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiServices

@Suite struct TranscriptLocatorTests {
    @Test func picksMostRecentTranscript() {
        let locator = TranscriptLocator(fileList: { _ in
            [("older", Date(timeIntervalSince1970: 100)),
             ("newer", Date(timeIntervalSince1970: 200))]
        })
        #expect(locator.locate(repoPath: "/Users/x/repo") == "newer")
    }
    @Test func returnsNilWhenEmpty() {
        let locator = TranscriptLocator(fileList: { _ in [] })
        #expect(locator.locate(repoPath: "/Users/x/repo") == nil)
    }
    @Test func encodesRepoPathForLookup() {
        var seen: String?
        let locator = TranscriptLocator(fileList: { encoded in seen = encoded; return [] })
        _ = locator.locate(repoPath: "/Users/x/My Repo!")
        #expect(seen == "-Users-x-My-Repo-")
    }
}
```

- [ ] **Step 2: Testi koştur, kırıldığını gör**

Run: `cd LumiPackages && swift test --filter TranscriptLocatorTests 2>&1 | tail -20`
Expected: FAIL — `TranscriptLocator` yok.

- [ ] **Step 3: Implementasyon**

`LumiPackages/Sources/LumiServices/NativeChat/TranscriptLocator.swift`:
```swift
import Foundation

/// repoPath → en yeni Claude transcript sessionID'si. Lumi-dışı (claudeSessionID taşımayan)
/// oturumları chat moduna bağlamak için. fileList enjekte edilir (test + saflık).
public struct TranscriptLocator {
    /// (encoded repo) → o klasördeki [(jsonl adı = sessionID, değişiklik zamanı)].
    private let fileList: (String) -> [(sessionID: String, modified: Date)]

    public init(fileList: @escaping (String) -> [(sessionID: String, modified: Date)]) {
        self.fileList = fileList
    }

    /// Canlı FS ile üretim başlatıcısı.
    public init() {
        self.fileList = { encoded in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(encoded)")
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return [] }
            return urls.filter { $0.pathExtension == "jsonl" }.compactMap { url in
                let m = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                return (url.deletingPathExtension().lastPathComponent, m)
            }
        }
    }

    public func locate(repoPath: String) -> String? {
        let encoded = repoPath.replacingOccurrences(
            of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return fileList(encoded).max(by: { $0.modified < $1.modified })?.sessionID
    }
}
```

- [ ] **Step 4: Testi koştur, geçtiğini gör**

Run: `cd LumiPackages && swift test --filter TranscriptLocatorTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiServices/NativeChat/TranscriptLocator.swift \
  LumiPackages/Tests/LumiServicesTests/TranscriptLocatorTests.swift
git commit -m "feat(remote): TranscriptLocator — dış oturum transcript keşfi (Bileşen B1)"
```

---

### Task 3: Bileşen B2 — TranscriptLocator'ı handleSubscribe'a bağla

Task 1'in `awaitTranscript` stub'ı gerçek gövdeye kavuşur: `claudeSessionID` yoksa locator ile transcript ara; bulunursa chat stream'i başlat (kısa poll ile birkaç kez dene), bulunamazsa chat-unavailable durumda kal.

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (awaitTranscript gövdesi + init'e locator enjeksiyonu)
- Modify: `LumiPackages/Sources/LumiTestSupport/` (gerekirse FakeChatTranscriptSource'a repoPath-bazlı event desteği — zaten var)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift` (yeni test ekle)

**Interfaces:**
- Consumes: `TranscriptLocator.locate(repoPath:) -> String?`, `chatSource.stream(sessionID:repoPath:)`.
- Produces: `RemoteService.init(... , transcriptLocator: TranscriptLocator = TranscriptLocator())` yeni opsiyonel parametre; `awaitTranscript` locator bulursa `emitChat` akışına geçer.

- [ ] **Step 1: Failing test yaz** (dış oturum, locator transcript'i bulur → chat mesajı gelir)

`RemoteServiceChatFallbackTests.swift`'e ekle:
```swift
@Test func externalSessionResolvesViaLocatorThenStreamsChat() async throws {
    let conn = FakeRelayConnection(); let term = FakeTerminalServicing(); let hooks = FakeAgentHookServer()
    let uuid = UUID()
    term.metas.append(TerminalMeta(id: TerminalID(raw: uuid), name: "T",
        repoPath: "/repo", createdAt: Date(), claudeSessionID: nil))   // dış oturum
    let sid = TerminalID(raw: uuid).description
    let chat = FakeChatTranscriptSource(events: [
        .snapshot([ChatMessage(id: "m1", role: .assistant, blocks: [.text("hi", presentation: nil)],
                               timestampMs: nil, turnId: nil)])
    ])
    let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
        connection: conn, chatSource: chat, hookEvents: hooks.events(),
        transcriptLocator: TranscriptLocator(fileList: { _ in [("found-session", Date())] }))
    await svc.start()
    await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
    try await conn.waitForCount(type: "chat", atLeast: 2)   // 1: boş, 2: locator sonrası snapshot
    #expect(await conn.sentTypes().contains("scrollback") == false)
    svc.stop()
}
```

- [ ] **Step 2: Testi koştur, kırıldığını gör**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatFallbackTests 2>&1 | tail -20`
Expected: FAIL — `transcriptLocator` parametresi yok / `awaitTranscript` stub boş, ikinci `chat` gelmez.

- [ ] **Step 3: init'e locator ekle + awaitTranscript gövdesi**

`RemoteService.swift` init imzasına ekle (varsayılanlı, çağıranlar değişmez):
```swift
private let transcriptLocator: TranscriptLocator
// init parametre listesine:
transcriptLocator: TranscriptLocator = TranscriptLocator(),
// init gövdesinde:
self.transcriptLocator = transcriptLocator
```
`awaitTranscript` stub'ını değiştir:
```swift
private func awaitTranscript(id: TerminalID, raw: String, meta: TerminalMeta) async {
    // Dış/taze oturum: transcript belirene kadar sınırlı poll (10 × 500ms).
    for _ in 0..<10 {
        if Task.isCancelled { return }
        if let resolved = transcriptLocator.locate(repoPath: meta.repoPath) {
            rlog("chat subscribe: locator transcript buldu sid=\(resolved.prefix(8)) repo=\(meta.repoPath)")
            let stream = chatSource.stream(sessionID: resolved, repoPath: meta.repoPath)
            for await event in stream {
                guard !Task.isCancelled else { break }
                await emitChat(sessionId: raw, event: event)
            }
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
    rlog("chat subscribe: transcript bulunamadı, chat-unavailable kalıyor repo=\(meta.repoPath)")
}
```

- [ ] **Step 4: Testi koştur, geçtiğini gör**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatFallbackTests 2>&1 | tail -20`
Expected: PASS (iki test de).

> Not: Poll gecikmesi testte 500ms; `FakeChatTranscriptSource` locator ilk denemede bulduğu için beklemeye takılmaz. Gerçek gecikme sorun olursa sleep'i enjekte scheduler'a çevir (mevcut `KeystrokeScheduling` deseni).

- [ ] **Step 5: Tüm LumiRemote + LumiServices testleri yeşil**

Run: `cd LumiPackages && swift test --filter "LumiRemoteTests|LumiServicesTests" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift
git commit -m "feat(remote): dış oturumu locator ile transcript'e bağla (Bileşen B2)"
```

---

### Task 4: Bileşen B3 — start_session claudeSessionID bağını kilitle

Telefondan başlatılan ajanın `claudeSessionID` taşıdığını (chat modu anında çalışsın) karakterizasyon testiyle kilitle. Regresyon koruması; kod zaten `TerminalSessionManager:89`'da bağlıyor.

**Files:**
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift` (varsa ekle, yoksa yeni)
- Modify (yalnız gerekirse): `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`

**Interfaces:**
- Consumes: `RemoteCommandHandler.startSession(...)`, `FakeTerminalServicing.spawn(...)` (spawn edilen meta'yı `metas`'a ekler ve `claudeSessionID` set eder).
- Produces: (davranış doğrulama — yeni API yok, aksi kanıtlanmazsa.)

- [ ] **Step 1: Failing/karakterizasyon test yaz**

```swift
@Test func startSessionBindsClaudeSessionID() async throws {
    let term = FakeTerminalServicing()
    let handler = RemoteCommandHandler(terminal: term)
    _ = await handler.startSession(repoPath: "/repo", prompt: "merhaba")
    let meta = term.metas.last
    #expect(meta != nil)
    #expect(meta?.claudeSessionID != nil)   // chat modu bağlanabilsin
}
```
> `FakeTerminalServicing.spawn` bugün `claudeSessionID` set etmiyorsa, fake'i gerçek `TerminalSessionManager` gibi `prepared.sessionID` atayacak şekilde güncelle (LumiTestSupport). Gerçek kodun davranışını taklit eden minimal düzeltme; üretim kodu değişmez.

- [ ] **Step 2: Testi koştur**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests 2>&1 | tail -20`
Expected: İlk koşuda fake set etmiyorsa FAIL → fake'i düzelt → PASS. Üretim kodu doğruysa doğrudan PASS.

- [ ] **Step 3: (gerekirse) fake'i düzelt**

`LumiPackages/Sources/LumiTestSupport/FakeTerminalServicing.swift` — `spawn` içinde eklenen meta'ya `claudeSessionID: UUID().uuidString` ver (üretimdeki `prepared.sessionID` muadili).

- [ ] **Step 4: Testi koştur, geçtiğini gör**

Run: `cd LumiPackages && swift test --filter RemoteCommandHandlerTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Tests/LumiRemoteTests/RemoteCommandHandlerTests.swift \
  LumiPackages/Sources/LumiTestSupport/FakeTerminalServicing.swift
git commit -m "test(remote): start_session claudeSessionID bağını kilitle (Bileşen B3)"
```

---

### Task 5: Bileşen C1 — LumiWire target (Mac) + tipleri taşı

Saf-Foundation `LumiWire` target'ı oluştur; wire tiplerini LumiKit'ten taşı; LumiKit `@_exported import LumiWire` ile geriye uyumlu kalsın. Mac derlenir + testler yeşil.

**Files:**
- Create: `LumiPackages/Sources/LumiWire/` altına taşınan dosyalar — **YALNIZ iOS'ta da kopyası olan / iki tarafın da (de)serialize ettiği saf wire tipleri**: `ChatPrompt.swift`, `ChatTurnStatus.swift`, `ChatMirrorModels.swift` (ChatMessage/ChatBlock/ChatRole), `DiagLog.swift`
- Modify: `LumiPackages/Package.swift` (LumiWire target + product; LumiKit deps += LumiWire)
- Modify: `LumiPackages/Sources/LumiKit/` — `@_exported import LumiWire` (tek merkezi `LumiKit/Exports.swift`)

**KAPSAM DIŞI (LumiKit'te KALIR):** `PromptJournal.swift` (Mac-only reducer, `AgentHookEvent`'e bağımlı — iOS'ta kopyası yok), `AskAnswerKeys.swift`/`buildAskAnswerKeys`/`AskQuestionInput` (Mac-only keystroke aktörü — iOS'ta kopyası yok), `TranscriptLocating`, `AgentHookModels.swift`. Bunları taşımak drift çözmez, gereksiz bağımlılık sürükler.

**Interfaces:**
- Produces: `LumiWire` product; `ChatPrompt`, `ChatPromptOption`, `ChatPromptQuestion`, `ChatPromptKind`, `ChatPromptState`, `ChatTurnStatus`, `ChatMessage`, `ChatBlock`, `ChatRole`, `DiagLog` artık `LumiWire`'da (public). `PromptJournal`/`buildAskAnswerKeys` LumiKit'te kalır ama `@_exported import LumiWire` sayesinde LumiWire tiplerini görür.
- Consumes: (yok — taban katman.)

- [ ] **Step 1: Package.swift'e LumiWire ekle**

`products`'a: `.library(name: "LumiWire", targets: ["LumiWire"]),`
`targets`'a: `.target(name: "LumiWire"),` ve `.testTarget(name: "LumiWireTests", dependencies: ["LumiWire"]),`
`LumiKit` target'ının `dependencies`'ine `"LumiWire"` ekle.

- [ ] **Step 2: Tipleri taşı (git mv)**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
mkdir -p LumiPackages/Sources/LumiWire
git mv LumiPackages/Sources/LumiKit/Models/ChatPrompt.swift LumiPackages/Sources/LumiWire/
git mv LumiPackages/Sources/LumiKit/Models/ChatTurnStatus.swift LumiPackages/Sources/LumiWire/
git mv LumiPackages/Sources/LumiKit/Models/ChatMirrorModels.swift LumiPackages/Sources/LumiWire/
git mv LumiPackages/Sources/LumiKit/Support/DiagLog.swift LumiPackages/Sources/LumiWire/
```
Bu dört dosya `import Foundation` (AppKit yok — teyit edildi). Taşımadan sonra `swift build 2>&1 | grep "cannot find"` ile başka bir wire tipi eksik çıkarsa (ör. ChatMirrorModels içindeki bir yardımcı başka pür tipe bağlıysa) onu da LumiWire'a taşı; AppKit'e bağlı bir parça çıkarsa LumiKit'te bırak. **`PromptJournal.swift`/`AskAnswerKeys.swift` TAŞINMAZ** — LumiKit'te kalır (yukarıdaki kapsam-dışı notu).

- [ ] **Step 2.5: iOS `decode` metotlarını LumiWire tiplerine birleştir (Task 6'nın iOS build'i için ŞART)**

Taşınan Mac tipleri (`ChatPrompt`, `ChatMessage`, `ChatBlock`, `ChatTurnStatus`) `decode(_:)` içermez — `decode` bugün iOS kopyalarında (`LumiMobile/.../ChatPrompt.swift`, `ChatMirrorModels.swift`, `ChatTurnStatus.swift`). iOS kopyalarındaki `static func decode(_ d: [String: Any]) -> Self?` metotlarını **oku ve LumiWire'daki karşılık gelen tiplere `public static func decode` olarak ekle** (alanlar birebir aynı; Task 6 iOS'u bunları çağıracak). Mac ChatPrompt ile iOS ChatPrompt alan-kümesi aynıdır (itemId, revision, kind, title, detail, options, state, selectedOptionId, multiSelect, allowOther, questions); yalnız decode metotları eklenir. `wirePayload()` (encode) Task 7'de eklenecek — bu adımda sadece decode.

- [ ] **Step 3: Geriye uyumluluk — LumiKit re-export**

`LumiPackages/Sources/LumiKit/Exports.swift` (yeni):
```swift
@_exported import LumiWire
```
Böylece `import LumiKit` yapan mevcut Mac kodu tipleri değişmeden görür.

- [ ] **Step 4: Mac derle**

Run: `cd LumiPackages && swift build 2>&1 | tail -30`
Expected: PASS. Hata `cannot find type` verirse ilgili tipi de LumiWire'a taşı (Step 2) veya import düzelt.

- [ ] **Step 5: Mac testleri yeşil**

Run: `cd LumiPackages && swift test 2>&1 | tail -20`
Expected: PASS (tüm suite — PromptJournal/AskAnswerKeys testleri LumiWireTests altına ya da mevcut yerinde `import LumiWire` ile çalışır; kırılırsa import satırını düzelt).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Package.swift LumiPackages/Sources/LumiWire LumiPackages/Sources/LumiKit
git commit -m "refactor(wire): saf-Foundation LumiWire target + LumiKit re-export (Bileşen C1)"
```

---

### Task 6: Bileşen C2 — iOS LumiMobileKit LumiWire'a bağlansın, kopyalar silinsin

iOS paketinin kendi kopya wire dosyaları silinir; `LumiWire`'a path-bağımlı olur. Xcode projesi yeniden üretilir.

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Package.swift` (`.package(path: "../../LumiPackages")` + target deps `LumiWire`)
- Delete: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift`, `ChatTurnStatus.swift`, `DiagLog.swift` (+ varsa ChatMessage kopyası)
- Modify: kopyaları import eden iOS dosyaları → `import LumiWire`

**Interfaces:**
- Consumes: `LumiWire` (Task 5 product).
- Produces: iOS artık `ChatPrompt`/`ChatMessage`/`ChatTurnStatus`/`DiagLog`'u LumiWire'dan alır (tek kaynak).

- [ ] **Step 1: Package.swift bağımlılığı**

`LumiMobile/LumiMobileKit/Package.swift`:
```swift
    dependencies: [ .package(path: "../../LumiPackages") ],
    targets: [
        .target(name: "LumiMobileKit", dependencies: [
            .product(name: "LumiWire", package: "LumiPackages")
        ]),
        .testTarget(name: "LumiMobileKitTests", dependencies: ["LumiMobileKit"]),
    ]
```
`platforms: [.iOS(.v17), .macOS(.v14)]` korunur.

- [ ] **Step 2: Kopya dosyaları sil**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
git rm LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift \
  LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatTurnStatus.swift \
  LumiMobile/LumiMobileKit/Sources/LumiMobileKit/DiagLog.swift \
  LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatMirrorModels.swift
```
Bu 4 dosya Task 5'te LumiWire'a taşınan 4 dosyanın iOS kopyalarıdır (birebir simetrik). LumiWire tipleriyle alan-uyumsuzluk çıkarsa (ör. iOS `decode`'unun beklediği bir alan LumiWire'da farklı adla) Task 7'de encode/decode simetrisini kurarken eşitle; bu adımda import'ları düzelt.

- [ ] **Step 3: import'ları düzelt**

`LumiMobileKit` içinde silinen tipleri kullanan her dosyanın başına `import LumiWire` ekle (AppModel.swift, PhoneProtocol.swift, ChatFold.swift vb.). Bul: `cd LumiMobile/LumiMobileKit && swift build 2>&1 | grep "cannot find"`.

- [ ] **Step 4: iOS paketi derle + test**

Run: `cd LumiMobile/LumiMobileKit && swift build 2>&1 | tail -30 && swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Xcode projesini yeniden üret**

Run: `cd LumiMobile && xcodegen generate 2>&1 | tail -5`
Expected: "Generated project" (yeni LumiWire bağımlılığı App target'ına yansır).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Package.swift LumiMobile/LumiMobileKit/Sources LumiMobile/*.xcodeproj 2>/dev/null
git rm --cached -r LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatPrompt.swift 2>/dev/null || true
git add -A LumiMobile
git commit -m "refactor(wire): iOS LumiMobileKit LumiWire'a bağlandı, kopyalar silindi (Bileşen C2)"
```

---

### Task 7: Bileşen C3 — encode/decode simetrisi tek yerde + round-trip testi

Wire encode (Mac `RemoteProtocol.*Payload`) ve decode (iOS) mantığı `LumiWire`'daki tiplere taşınır: her tip `wirePayload()` + `decode(_:)`. Round-trip testi iki tarafı da kilitler.

**Files:**
- Modify: `LumiPackages/Sources/LumiWire/ChatPrompt.swift` (+`ChatMessage.swift`) — `wirePayload()`/`decode(_:)` public
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` — `promptPayload`/`chatPayload` artık `wirePayload()` çağırır
- Modify: iOS decode çağrıları LumiWire `decode`'una yönelir (kopya decode zaten LumiWire'da)
- Test: `LumiPackages/Tests/LumiWireTests/WireRoundTripTests.swift` (yeni)

**Interfaces:**
- Produces: `ChatPrompt.wirePayload() -> [String: Any]`, `static ChatPrompt.decode(_ d: [String: Any]) -> ChatPrompt?` (mevcut iOS `decode` public'e alınır); `ChatMessage` için aynısı.
- Consumes: Task 5/6 çıktısı.

- [ ] **Step 1: Round-trip failing test yaz**

`LumiPackages/Tests/LumiWireTests/WireRoundTripTests.swift`:
```swift
import Testing
@testable import LumiWire

@Suite struct WireRoundTripTests {
    @Test func chatPromptRoundTrips() {
        let p = ChatPrompt(itemId: "i1", revision: 2, kind: .question, title: "Pick",
            detail: nil, options: [ChatPromptOption(id: "opt-0", label: "A", description: "d")],
            state: .pending, selectedOptionId: nil, multiSelect: true, allowOther: true,
            questions: [ChatPromptQuestion(id: "q0", question: "Q?", header: "H",
                multiSelect: false, allowOther: false,
                options: [ChatPromptOption(id: "opt-0", label: "X", description: nil)])])
        let decoded = ChatPrompt.decode(p.wirePayload())
        #expect(decoded == p)
    }
}
```

- [ ] **Step 2: Testi koştur, kırıldığını gör**

Run: `cd LumiPackages && swift test --filter WireRoundTripTests 2>&1 | tail -20`
Expected: FAIL — `wirePayload()` yok.

- [ ] **Step 3: `wirePayload()`'ı LumiWire'a ekle**

`ChatPrompt` (ve alt tipleri) için `RemoteProtocol.promptPayload`'daki serileştirmeyi `wirePayload()` metoduna taşı (anahtarlar birebir: `itemId`, `revision`, `kind`, `title`, `detail`, `options`, `state`, `selectedOptionId`, `multiSelect`, `allowOther`, `questions`). `decode` zaten var (iOS'tan taşındı) — `internal`/`static` erişimi `public` yap.

- [ ] **Step 4: RemoteProtocol'ü wirePayload'a yönelt**

`RemoteProtocol.promptPayload(sessionId:prompt:)` gövdesi:
```swift
static func promptPayload(sessionId: String, prompt: ChatPrompt) -> [String: Any] {
    var p = prompt.wirePayload(); p["sessionId"] = sessionId; return p
}
```
`chatPayload`/`chatAppendPayload` için `ChatMessage.wirePayload()` ile aynısını yap.

- [ ] **Step 5: Testler yeşil (round-trip + Mac + iOS)**

Run: `cd LumiPackages && swift test 2>&1 | tail -20`
Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -20`
Expected: İkisi de PASS (prompt/chat wire testleri kırılmadı).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiWire LumiPackages/Sources/LumiRemote/RemoteProtocol.swift \
  LumiPackages/Tests/LumiWireTests LumiMobile
git commit -m "refactor(wire): encode/decode simetrisi LumiWire'da + round-trip testi (Bileşen C3)"
```

---

### Task 8: Bileşen D — gruplu prompt kartı UI + çok-soru cevap sırası

`MobileChatPromptCard`'ın `questions.count > 1` placeholder'ı gerçek UI olur; her soru için seçim + tek Gönder tüm cevabı sırayla yollar.

**Files:**
- Modify: `LumiMobile/App/MobileChatPromptCard.swift:31-33` (placeholder → gruplu UI)
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (`respondPromptSelections` çok-soru sıralı selection)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/GroupedPromptTests.swift` (yeni — model seviyesinde)

**Interfaces:**
- Consumes: `ChatPrompt.questions: [ChatPromptQuestion]` (LumiWire), `onQuestion: ([(indices: [Int], other: String?)]) -> Void`.
- Produces: gruplu kart, soru sırasına göre `[(indices, other)]` listesi (her soru için bir eleman); `AppModel.respondPromptSelections(_:selections:)` bu listeyi `prompt_respond` `selections` dizisi olarak encode eder.

- [ ] **Step 1: Model testini yaz** (respondPromptSelections çok-soruyu sıralı gönderir)

`GroupedPromptTests.swift`:
```swift
import Testing
import LumiWire
@testable import LumiMobileKit

@Suite @MainActor struct GroupedPromptTests {
    @Test func selectionsEncodedInQuestionOrder() {
        let frame = PhoneProtocol.promptRespondSelectionsFrame(
            sessionId: "s", itemId: "q1", expectedRevision: 0,
            selections: [(indices: [1], other: nil), (indices: [0, 2], other: "x")])
        // frame payload selections[0]=={indices:[1]}, selections[1]=={indices:[0,2],other:"x"}
        let payload = frame["payload"] as? [String: Any]
        let sels = payload?["selections"] as? [[String: Any]]
        #expect((sels?[0]["indices"] as? [Int]) == [1])
        #expect((sels?[1]["other"] as? String) == "x")
    }
}
```
> `promptRespondSelectionsFrame` bugün tek-soru için var; çok-soru selection dizisini aynı şekilde kabul ettiğini doğrula/uyarlana.

- [ ] **Step 2: Testi koştur, kırıldığını gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter GroupedPromptTests 2>&1 | tail -20`
Expected: FAIL (çok-soru sırası desteklenmiyorsa) veya derleme hatası.

- [ ] **Step 3: respondPromptSelections çok-soru desteği**

`AppModel.respondPromptSelections` ve `PhoneProtocol.promptRespondSelectionsFrame`'in `[(indices, other)]` listesini soru sırasıyla `selections` dizisine map ettiğinden emin ol (tek-soru = tek elemanlı liste; gruplu = N elemanlı). Gerekli düzeltmeyi yap.

- [ ] **Step 4: Gruplu kart UI'ı**

`MobileChatPromptCard.swift` `case .question` dalında `questions.count > 1` placeholder'ını değiştir:
```swift
case .question:
    if prompt.questions.count > 1 {
        groupedQuestionBody
    } else {
        questionBody
    }
```
`groupedQuestionBody` (yeni, `@State private var groupSel: [Int: [Int]] = [:]` ve `[Int: String]` free-text ile): her `prompt.questions.enumerated()` için başlık (`q.header ?? q.question`) + seçenekler (tek/multi `q.multiSelect`) + `q.allowOther` free-text; altta tek "Gönder" → `onQuestion(prompt.questions.indices.map { (indices: (groupSel[$0] ?? []).sorted(), other: groupText[$0]) })`. Stil mevcut `optionButton` helper'ıyla; literal punto yok (mevcut `.font(.footnote)` desenini izle).

- [ ] **Step 5: Testler + iOS build yeşil**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -20`
Run: `cd LumiMobile && xcodegen generate && xcodebuild -scheme LumiMobile -destination 'generic/platform=iOS' build 2>&1 | tail -15`
Expected: test PASS; build SUCCEEDED (imzasız generic build).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/App/MobileChatPromptCard.swift \
  LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift \
  LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift \
  LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/GroupedPromptTests.swift
git commit -m "feat(mobile): gruplu çok-soru prompt kartı + sıralı selections (Bileşen D)"
```

---

### Task 9: Bileşen E — tam regresyon + deploy doğrulama kontrol listesi

Tüm suite yeşil + iOS build; sonra manuel deploy adımları (proje kuralı: on-device otomatik yapılamaz).

**Files:**
- (Kod yok — doğrulama.)

- [ ] **Step 1: LumiPackages tam test + release build**

Run: `cd LumiPackages && swift build && swift test 2>&1 | tail -20 && swift build -c release --product Lumi 2>&1 | tail -5`
Expected: hepsi PASS/başarılı.

- [ ] **Step 2: iOS tam test + build**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -20 && cd .. && xcodegen generate && xcodebuild -scheme LumiMobile -destination 'generic/platform=iOS' build 2>&1 | tail -10`
Expected: PASS / SUCCEEDED.

- [ ] **Step 3: RelayServer testleri (değişmedi teyidi)**

Run: `cd RelayServer && npm test 2>&1 | tail -15`
Expected: PASS (relay protokolü değişmedi — additive alanlar geriye uyumlu).

- [ ] **Step 4: Manuel deploy kontrol listesi (kullanıcı)**

Aşağıdakileri kullanıcıya rapor et (bu makineden otomatik yapılamaz):
- RelayServer redeploy (Railway) — yalnız additive alanlar; eski istemciyle uyumlu.
- Mac app rebuild + `~/Applications`'a kur (`Scripts/make-app.sh --install`).
- iOS cihaza install (`xcodegen generate` sonrası Xcode'dan run).
- Cihazda teyit: `~/.lumi/logs/mac.log`'da **`chat subscribe DÜŞTÜ→terminal` satırı GÖRÜNMEZ**; var olan chat açıldığında mesajlar tamamlanmış gelir (token token değil); AskUserQuestion tek + gruplu kart telefonda çıkar ve cevaplanır.

- [ ] **Step 5: Final commit (varsa) + özet**

```bash
git add -A && git commit -m "chore(remote): orca chat yaşam döngüsü paritesi — regresyon yeşil" || echo "temiz"
git log --oneline -10
```

---

## Notlar

- **Dış-oturum keşfi heuristiktir** (en yeni jsonl). Çoklu-tab çakışmasına karşı mevcut `TranscriptClaimRegistry` teklik sahipliği korunur; yanlış eşleşme görülürse Task 3 poll'üne repo+mtime penceresi daralt.
- **LumiWire taşımasında** bir tip beklenmedik şekilde AppKit'e bağlıysa (örn. bir extension) o parçayı LumiKit'te bırak, saf çekirdeği LumiWire'a al.
- **iOS ChatMessage kopyası** LumiWire'daki ile alan-uyumsuzsa Task 6 yerine Task 7'de tek modele indir; alanları birebir eşitle.
