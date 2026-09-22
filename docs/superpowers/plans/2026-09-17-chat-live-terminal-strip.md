# Chat Canlı Terminal Şeridi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefon chat ekranında turn sürerken canlı (token-token) terminal şeridi göstermek; assistant metnini balonsuz düz prose yapmak; uzun AskUserQuestion kartını scroll'lu ve ekrana sığar hale getirmek.

**Architecture:** Mac `RemoteService` chat aboneliğinde chat frame'lerine EK olarak mevcut PTY feed'ini (scrollback + data) de yayınlar; iOS `AppModel` chat modunda bu feed'i mevcut `terminalStream` rotasına alır; yeni `ChatLiveTerminalStrip` view'ı `TerminalHostView`'ı salt-okunur, alt-hizalı-kırpılmış kullanır. Relay ve yeni frame tipi YOK.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (Mac LumiPackages), XCTest (iOS LumiMobileKit), SwiftTerm, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-17-chat-live-terminal-strip-design.md` (bağlayıcı).

## Global Constraints

- Branch: `feat/remote-orca-main` — **main'e commit YASAK**.
- Relay (`RelayServer/`) DEĞİŞMEZ; yeni frame tipi eklenmez.
- `PromptJournal` ve Mac desktop UI değişmez.
- Şerit görünürlük kuralı: `(working || hasPendingPrompt) && hasFeed`.
- Şerit yüksekliği 220pt; ayna grid'i Mac cols/rows'unda kalır, ALT bölge görünür (bottom-align + clip).
- Kart yüksekliği ekranın ~%45'i ile sınırlanır; soru metni hiçbir yerde kısaltılmaz (mevcut `detail` 2 satır + middle-truncation KORUNUR).
- Kullanıcı mesajı balonu KALIR; yalnız assistant text blokları balonsuz olur.
- Dış (PTY'siz) oturumda şerit hiç görünmez; chat bugünkü gibi çalışır.
- Mevcut `~/.lumi` persistence formatlarına dokunulmaz.
- Test komutları: Mac `cd LumiPackages && swift build && swift test`; iOS Kit `cd LumiMobile/LumiMobileKit && swift test`; iOS app `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- LumiMobile App target'ına YENİ .swift dosyası eklenirse `xcodegen generate` zorunlu (proje üretilir, elle edit edilmez).

---

### Task 1: Mac — chat aboneliği feed'i de yayınlar

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift:253-313` (handleSubscribe + yeni helper)
- Test (modify): `LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift`

**Interfaces:**
- Consumes: mevcut `terminal.serializeScrollback(id)`, `terminal.subscribeOutput(id)`, `emitData(id:sessionId:batch:)`, `seqCounters`, `subscriptions`.
- Produces: `mode=chat` subscribe'da telefona `scrollback` (seq=0) + PTY çıktısında `data` frame'leri (chat/chat_status/prompt frame'lerine ek). Sonraki task'lerin Mac tarafı bağımlılığı yok.

**Bağlam — bilinçli davranış değişikliği:** Mevcut iki test (`chatSubscribeWithoutClaudeSessionDoesNotFallToTerminal`, `externalSessionResolvesViaLocatorThenStreamsChat`) "chat modunda scrollback/data ASLA gönderilmez" der. O assert'lerin amacı ham PTY'nin CHAT İÇERİĞİ yerine geçmemesiydi (token-token çöp bug'ı). Bu task'te chat frame'leri aynen kalır; feed frame'leri EK kanal olarak gelir (telefon ayrı şeritte çizer). Spec bunu açıkça istiyor → iki testin scrollback/data assert'leri güncellenir, chat assert'leri korunur.

- [ ] **Step 1: Failing test — chat subscribe feed de yayınlar**

`RemoteServiceChatFallbackTests.swift`'e ekle (mevcut suite içine):

```swift
@Test func chatSubscribeAlsoStreamsFeed() async throws {
    let conn = FakeRelayConnection()
    let term = FakeTerminalServicing()
    let hooks = FakeAgentHookServer()
    let uuid = UUID()
    let id = TerminalID(raw: uuid)
    term.metas.append(TerminalMeta(id: id, name: "T", repoPath: "/repo",
        createdAt: Date(), claudeSessionID: "cs-1"))
    let sid = id.description
    let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: FakeRepoService(),
        connection: conn, chatSource: FakeChatTranscriptSource(events: []),
        hookEvents: { hooks.events() })
    await svc.start()
    await conn.injectInbound(type: "subscribe", payload: ["sessionId": sid, "mode": "chat"])
    // Chat kanalı kurulur VE feed kanalı da kurulur.
    try await conn.waitForSent(types: ["scrollback", "chat_status"])
    term.emitOutput(id, Data("token".utf8))
    try await conn.waitForSent(types: ["data"])
    svc.stop()
}
```

- [ ] **Step 2: Testin FAIL ettiğini doğrula**

Run: `cd LumiPackages && swift test --filter RemoteServiceChatFallbackTests`
Expected: `chatSubscribeAlsoStreamsFeed` FAIL (timeout: "expected ... 'scrollback'"). Diğer iki test henüz yeşil.

- [ ] **Step 3: Implementasyon — feed emisyonunu helper'a çıkar, chat dallarından da çağır**

`RemoteService.swift` içinde terminal-mode bloğunu (satır ~292-312: `seqCounters[id] = 0` … `subscriptions[id] = task`) aynen şu private helper'a taşı:

```swift
/// PTY feed emisyonu (scrollback seq=0 + canlı data). Terminal modunun gövdesi;
/// chat modu da çağırır — canlı terminal şeridi chat ekranında bu feed'den çizilir
/// (spec 2026-09-17). Feed chat İÇERİĞİ değildir; telefon ayrı şeritte gösterir.
private func startFeedEmission(id: TerminalID, raw: String) async {
    seqCounters[id] = 0
    let (data, cols, rows) = terminal.serializeScrollback(id)
    await connection.send(
        type: "scrollback",
        payload: RemoteProtocol.scrollbackPayload(sessionId: raw, seq: 0, cols: cols, rows: rows, data: data)
    )
    let stream = terminal.subscribeOutput(id)
    let task = Task { [weak self] in
        for await batch in stream {
            guard !Task.isCancelled else { break }
            await self?.emitData(id: id, sessionId: raw, batch: batch)
        }
    }
    subscriptions[id] = task
}
```

`handleSubscribe`'da: terminal-mode dalının gövdesi `await startFeedEmission(id: id, raw: raw)` olur (yorumlar korunur). Chat dalında `guard let meta`'dan hemen sonra (her iki kol da feed alır):

```swift
// Canlı terminal şeridi: chat modunda PTY feed'i de yayınlanır (spec 2026-09-17).
await startFeedEmission(id: id, raw: raw)
```

Not: `cancelSubscription(id)` + `cancelChatSubscription(id)` handleSubscribe başında zaten çağrılıyor; unsubscribe/stop yolları `subscriptions[id]`'yi zaten kesiyor — ek değişiklik yok.

- [ ] **Step 4: Çelişen iki testi güncelle**

`chatSubscribeWithoutClaudeSessionDoesNotFallToTerminal` içinde:

```swift
// ESKİ:
#expect(await conn.sentTypes().contains("scrollback") == false)
#expect(await conn.sentTypes().contains("data") == false)
// YENİ: feed EK kanal olarak gelir; chat kanalı ham PTY'ye düşmez (chat frame'i boş snapshot'tır).
try await conn.waitForSent(types: ["scrollback"])
#expect(await conn.sentTypes().contains("chat"))
```

`externalSessionResolvesViaLocatorThenStreamsChat` içinde:

```swift
// ESKİ:
#expect(await conn.sentTypes().contains("scrollback") == false)
// YENİ:
try await conn.waitForSent(types: ["scrollback"])
```

Test adını `chatSubscribeWithoutClaudeSessionDoesNotFallToTerminal` → `chatSubscribeWithoutClaudeSessionEmitsChatUnavailablePlusFeed` yap (yorumdaki "Ham-PTY yolu ASLA kurulmaz" satırını "Feed EK kanaldır; chat içeriği ham PTY'ye düşmez" olarak güncelle).

- [ ] **Step 5: Testlerin PASS ettiğini doğrula**

Run: `cd LumiPackages && swift test --filter "RemoteServiceChatFallbackTests|RemoteServiceTests|RemoteServicePromptTests|RemoteServiceRestartTests"`
Expected: tümü PASS (terminal-mode regresyonu yok).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Tests/LumiRemoteTests/RemoteServiceChatFallbackTests.swift
git commit -m "feat(remote): chat aboneliği PTY feed'ini de yayınlar — canlı terminal şeridi veri kanalı"
```

---

### Task 2: iOS Kit — chat modunda feed rotası + şerit görünürlük kuralı

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (subscribeChat, route, handle(.scrollback/.data), applySessions)
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatLiveStrip.swift`
- Test (create): `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatLiveStripTests.swift`

**Interfaces:**
- Consumes: mevcut `AppModel.handle(_:)` (public), `terminalStream(_:)`, `route(_:)`, `replayBuffers`, `terminalSinks`, `applySessions`.
- Produces (Task 3 kullanır):
  - `public func chatLiveStripVisible(working: Bool, hasPendingPrompt: Bool, hasFeed: Bool) -> Bool` (free function, `ChatLiveStrip.swift`)
  - `AppModel.hasFeed(_ sessionId: String) -> Bool`
  - `AppModel.gridRows: [String: Int]` (public private(set); scrollback/data chunk'ının `rows`'undan)
  - `subscribeChat(_:)` artık feed replay tamponunu da hazırlar.

- [ ] **Step 1: Failing testler**

`ChatLiveStripTests.swift` (yeni dosya):

```swift
import XCTest
@testable import LumiMobileKit
import LumiWire

@MainActor
final class ChatLiveStripTests: XCTestCase {
    private func makeModel() -> (AppModel, FakeRelayClient) {
        let client = FakeRelayClient()
        // FakeRelayClient + InMemorySecureStore mevcut test yardımcılarıdır (AppModelTests.swift).
        return (AppModel(client: client, store: InMemorySecureStore()), client)
    }

    func testStripVisibilityRule() {
        // (working || pendingPrompt) && hasFeed
        XCTAssertFalse(chatLiveStripVisible(working: false, hasPendingPrompt: false, hasFeed: true))
        XCTAssertTrue(chatLiveStripVisible(working: true, hasPendingPrompt: false, hasFeed: true))
        XCTAssertTrue(chatLiveStripVisible(working: false, hasPendingPrompt: true, hasFeed: true))
        XCTAssertFalse(chatLiveStripVisible(working: true, hasPendingPrompt: true, hasFeed: false))
        XCTAssertFalse(chatLiveStripVisible(working: false, hasPendingPrompt: false, hasFeed: false))
    }

    func testSubscribeChatRoutesFeedToTerminalStream() async {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        // View (şerit) mount olmadan scrollback geldi → replay tamponuna girmeli.
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 40,
                                               bytes: Data("hi".utf8))))
        var got: [TerminalChunk] = []
        for await chunk in model.terminalStream("s1") { got.append(chunk); break }
        XCTAssertEqual(got.first?.bytes, Data("hi".utf8))
    }

    func testHasFeedAndGridRows() {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        XCTAssertFalse(model.hasFeed("s1"))                 // dış oturum: feed yok
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 40,
                                               bytes: Data())))
        XCTAssertTrue(model.hasFeed("s1"))
        XCTAssertEqual(model.gridRows["s1"], 40)
        // rows'suz data chunk'ı grid'i değiştirmez.
        model.handle(.data(TerminalChunk(sessionId: "s1", seq: 1, bytes: Data("x".utf8))))
        XCTAssertEqual(model.gridRows["s1"], 40)
    }

    func testSubscribeChatCleansPreviousSessionFeed() async {
        let (model, _) = makeModel()
        model.subscribeChat("s1")
        model.handle(.scrollback(TerminalChunk(sessionId: "s1", seq: 0, cols: 80, rows: 24,
                                               bytes: Data("a".utf8))))
        model.subscribeChat("s2")
        // s1 replay tamponu boşaltıldı; s2 için taze tampon var.
        model.handle(.data(TerminalChunk(sessionId: "s2", seq: 0, bytes: Data("b".utf8))))
        var got: [TerminalChunk] = []
        for await chunk in model.terminalStream("s2") { got.append(chunk); break }
        XCTAssertEqual(got.first?.bytes, Data("b".utf8))
    }
}
```

- [ ] **Step 2: FAIL doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ChatLiveStripTests`
Expected: derleme hatası (`chatLiveStripVisible`, `hasFeed`, `gridRows` yok).

- [ ] **Step 3: Implementasyon**

`ChatLiveStrip.swift` (yeni):

```swift
import Foundation

/// Chat ekranındaki canlı terminal şeridinin görünürlük kuralı (spec 2026-09-17):
/// turn çalışıyor VEYA cevapsız prompt var — ve bu oturumdan en az bir feed
/// chunk'ı gelmiş (dış/PTY'siz oturumda şerit hiç görünmez).
public func chatLiveStripVisible(working: Bool, hasPendingPrompt: Bool, hasFeed: Bool) -> Bool {
    (working || hasPendingPrompt) && hasFeed
}
```

`AppModel.swift`:

1. Property'ler (chatBySession civarına):

```swift
/// Feed chunk'ı görülen oturumlar (şerit görünürlüğü) ve otoriter grid satır sayısı
/// (şeridin alt-bölge kırpması scrollback'in rows'una göre hesaplanır).
public private(set) var feedSeen: Set<String> = []
public private(set) var gridRows: [String: Int] = [:]

public func hasFeed(_ sessionId: String) -> Bool { feedSeen.contains(sessionId) }
```

2. `handle(_:)` içindeki `case .scrollback(let chunk), .data(let chunk):` dalına route'tan önce:

```swift
feedSeen.insert(chunk.sessionId)
if let rows = chunk.rows { gridRows[chunk.sessionId] = rows }
```

3. `subscribeChat(_:)` — `subscribe(_:)` ile aynı feed hazırlığı:

```swift
public func subscribeChat(_ sessionId: String) {
    // Terminal aboneliğiyle aynı temizlik: eski oturumun sink'i sonlanmazsa
    // geç gelen eski .data ona yield edilir (bkz. subscribe(_:)).
    if let old = activeSessionId, old != sessionId {
        terminalSinks[old]?.finish()
        terminalSinks[old] = nil
        replayBuffers[old] = nil
    }
    activeSessionId = sessionId
    activeChatMode = true
    chatBySession[sessionId] = chatBySession[sessionId] ?? []
    // Şerit mount olmadan gelen scrollback düşmesin (subscribe(_:) paritesi).
    replayBuffers[sessionId] = []
    Task { await client.send(frame: PhoneProtocol.subscribeFrame(sessionId: sessionId, mode: "chat")) }
}
```

4. `applySessions(_:)` içindeki ölü-oturum temizliğine (mevcut `models = models.filter...` yanına):

```swift
feedSeen = feedSeen.filter { liveIds.contains($0) }
gridRows = gridRows.filter { liveIds.contains($0.key) }
```

- [ ] **Step 4: PASS doğrula (tüm Kit testleri)**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: tümü PASS (mevcut AppModelTests dahil — subscribeChat değişikliği terminal testlerini bozmamalı).

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatLiveStrip.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ChatLiveStripTests.swift
git commit -m "feat(mobile-kit): chat modunda feed rotası + canlı şerit görünürlük kuralı"
```

---

### Task 3: iOS App — ChatLiveTerminalStrip view + MobileChatView entegrasyonu

**Files:**
- Create: `LumiMobile/App/ChatLiveTerminalStrip.swift`
- Modify: `LumiMobile/App/MobileChatView.swift:40-59` (şerit ekleme)
- Regenerate: `LumiMobile/LumiMobile.xcodeproj` (`xcodegen generate` — App target'a yeni dosya)

**Interfaces:**
- Consumes (Task 2'den): `chatLiveStripVisible(working:hasPendingPrompt:hasFeed:)`, `model.hasFeed(_:)`, `model.gridRows`, `model.terminalStream(_:)`; mevcut `TerminalHostView(onInput:buffer:)`, `TerminalFeedBuffer`.
- Produces: `ChatLiveTerminalStrip(model:sessionId:)` view'ı.

Test yok (saf UI); teslim kriteri iOS build yeşil. Kural mantığı Task 2'de test edildi.

- [ ] **Step 1: `ChatLiveTerminalStrip.swift` yaz**

```swift
// LumiMobile/App/ChatLiveTerminalStrip.swift
import SwiftUI
import UIKit
import LumiMobileKit

/// Chat ekranında turn sürerken görünen salt-okunur canlı terminal alanı
/// (spec 2026-09-17). Ayna emülatörü Mac'in grid'inde kalır (chunk'lar resize
/// taşır); view grid yüksekliğinde çizilip ALTA hizalanarak şerit yüksekliğine
/// kırpılır — en güncel içerik (akan metin, spinner, soru) hep görünür.
struct ChatLiveTerminalStrip: View {
    let model: AppModel
    let sessionId: String
    static let stripHeight: CGFloat = 220

    @State private var buffer = TerminalFeedBuffer()

    /// Grid yüksekliği yaklaşıklaması: rows × mono satır yüksekliği. Birkaç
    /// puntoluk sapma kabul — kırpma alttan hizalı olduğu için içerik kaybolmaz.
    private var gridHeight: CGFloat {
        let rows = model.gridRows[sessionId] ?? 24
        let lineHeight = UIFont.monospacedSystemFont(
            ofSize: UIFont.systemFontSize, weight: .regular).lineHeight
        return max(Self.stripHeight, CGFloat(rows) * lineHeight + 4)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Salt-okunur: girişler yok sayılır (MirrorTerminalView zaten
            // first-responder olmaz; şeritten klavye açılmaz).
            TerminalHostView(onInput: { _ in }, buffer: buffer)
                .frame(height: gridHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.stripHeight, alignment: .bottom)
        .clipped()
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .task(id: sessionId) {
            for await chunk in model.terminalStream(sessionId) {
                buffer.feed(chunk)
            }
        }
    }
}
```

- [ ] **Step 2: `MobileChatView` gövdesine şeridi ekle**

`MobileChatView.body`'de `ScrollViewReader { ... }` bloğu ile `if let status ...` (TurnStatusBar) arasına; pending hesabı iki yerde kullanılacağı için body başında değişkene alınır. Mevcut blok:

```swift
            if let status = model.turnStatus[sessionId], status.working {
                TurnStatusBar(status: status) {
                    model.sendInput(sessionId, Data([0x03]))
                }
            }
            if let pending = model.prompts[sessionId]?.last(where: { $0.state == .pending }) {
```

şöyle olur:

```swift
            let pending = model.prompts[sessionId]?.last(where: { $0.state == .pending })
            if chatLiveStripVisible(working: model.turnStatus[sessionId]?.working ?? false,
                                    hasPendingPrompt: pending != nil,
                                    hasFeed: model.hasFeed(sessionId)) {
                ChatLiveTerminalStrip(model: model, sessionId: sessionId)
            }
            if let status = model.turnStatus[sessionId], status.working {
                TurnStatusBar(status: status) {
                    model.sendInput(sessionId, Data([0x03]))
                }
            }
            if let pending {
```

(`if let pending {` altındaki kart bloğu ve `.id(pending.itemId)` aynen kalır.)

- [ ] **Step 3: Proje üret + build doğrula**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/ChatLiveTerminalStrip.swift LumiMobile/App/MobileChatView.swift
git commit -m "feat(mobile): chat ekranında canlı terminal şeridi — turn sürerken token-token akış"
```

---

### Task 4: iOS App — balonsuz assistant metni + scroll'lu soru kartı

**Files:**
- Modify: `LumiMobile/App/MobileChatMessageView.swift:22-51`
- Modify: `LumiMobile/App/MobileChatPromptCard.swift:19-45`

**Interfaces:**
- Consumes: mevcut `FoldedTurn`, `ChatBlock`, `ChatPrompt`.
- Produces: görsel değişiklik; API değişmez.

Test yok (saf UI); teslim kriteri iOS build yeşil + mevcut Kit testleri yeşil kalır.

- [ ] **Step 1: Assistant balonunu kaldır**

`MobileChatMessageView.blockView`'daki `.text` dalını şu hale getir (kullanıcı balonu kalır, assistant düz prose olur):

```swift
        case let .text(text, _):
            if turn.message.role == .user {
                Text(LocalizedStringKey(text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: 300, alignment: .trailing)
            } else {
                // Assistant: balonsuz düz prose (orca dili; spec 2026-09-17).
                Text(LocalizedStringKey(text))
                    .textSelection(.enabled)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
```

`bubbleColor` computed property'si artık kullanılmıyorsa sil.

- [ ] **Step 2: Kart gövdesini ScrollView'a al + yükseklik sınırı**

`MobileChatPromptCard.body`'deki iç `VStack(alignment: .leading, spacing: 8) { ... }` bloğunu (başlık HStack'i, detail, switch — hepsi içeride kalır) şuna sar:

```swift
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // ... mevcut içerik aynen (başlık, detail, switch) ...
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)  // MobileChatView'dan GeometryReader ile gelir (~ekranın %45'i; UIScreen.main deprecated)
            .fixedSize(horizontal: false, vertical: true)
```

Notlar: `.fixedSize(horizontal: false, vertical: true)` kısa içerikte kartın gereksiz 45% yer kaplamasını önler (ScrollView içeriği kadar küçülür, sınırı aşınca scroll). `maxHeight` parametresi `MobileChatView`'daki `GeometryReader`'dan `geo.size.height * 0.45` olarak gelir — `UIScreen.main` iOS 16+ deprecated olduğundan kullanılmaz. Padding (`.padding(.horizontal, 12).padding(.vertical, 8)`) ScrollView'ın DIŞINDA, mevcut yerinde kalır. Soru metni (`prompt.title` / `q.question`) hiçbir yerde `lineLimit` almaz; mevcut `detail`'ın `lineLimit(2)`'si korunur.

- [ ] **Step 3: Build doğrula**

Run: `cd LumiMobile && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/MobileChatMessageView.swift LumiMobile/App/MobileChatPromptCard.swift
git commit -m "feat(mobile): assistant metni balonsuz düz prose + soru kartı scroll'lu/sığar"
```

---

### Task 5: Sweep + build'ler + kurulum

**Files:** yok (doğrulama + paketleme).

- [ ] **Step 1: Mac tam test + release build**

Run: `cd LumiPackages && swift build && swift test 2>&1 | tail -3 && swift build -c release --product Lumi 2>&1 | tail -2`
Expected: tüm testler PASS, release build başarılı. (Disk-I/O hatası çıkarsa `--scratch-path /tmp/lumi-scratch` ekle.)

- [ ] **Step 2: iOS Kit + app build**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -3 && cd .. && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: Kit testleri PASS, `BUILD SUCCEEDED`.

- [ ] **Step 3: Mac app kur + temiz env ile yeniden başlat**

Run:
```bash
pkill -x Lumi 2>/dev/null; sleep 1
cd /Users/balkan/orca/workspaces/Lumi/lumi && Scripts/make-app.sh --install
env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT open /Applications/Lumi.app
```
Expected: kurulum başarılı, app açık, `~/.lumi/logs/mac.log`'da "hook stream dinleme BAŞLADI".

- [ ] **Step 4: Cihaz kurulumu (kullanıcı testi için hazırla)**

iPhone bağlıysa: `xcrun devicectl list devices` ile cihazı bul, Xcode ile "Lumi Remote New" (com.lumi.LumiRemoteNew) hedefine kur; bağlı değilse kullanıcıya "cihaz kurulumu bekliyor" raporla.

- [ ] **Step 5: Ledger + rapor**

`.superpowers/sdd/progress.md`'ye task satırlarını işle; kullanıcıya cihaz test senaryosunu bildir: telefondan oturum aç → turn sürerken şeritte token-token akış → uzun sorulu AskUserQuestion → kart scroll'lu, soru-öncesi metin şeritte görünür → cevap sonrası şerit kapanır, tamamlanmış mesajlar düz prose gelir.
