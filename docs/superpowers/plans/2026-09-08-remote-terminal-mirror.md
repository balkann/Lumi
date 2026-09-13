# Terminal-Ayna Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lumi'nin mobil remote'unu chat-yeniden-kurma modelinden orca'nın terminal-ayna modeline çevirmek: Mac ham PTY baytını relay üzerinden telefona stream eder, iOS bunu SwiftTerm native terminalde render eder, tuş vuruşu geri PTY'ye yazılır.

**Architecture:** Üç bileşen tek protokolle bağlı. Mac (`LumiRemote`) `TerminalPipeline.onFlushBatch` bayt batch'lerini tapler; relay (`RelayServer`, TS) token-oda izolasyonuyla yönlendirir; iOS (`LumiMobile`) SwiftTerm `TerminalView`'e feed eder. Transport/pairing/config/push scaffold'ı `lumi-remote` branch'inden `git checkout` ile getirilir; yalnızca chat/transcript veri modeli terminal-stream ile değiştirilir.

**Tech Stack:** Swift 6 (macOS 14+ paketler, iOS 17 app), SwiftTerm (revision-pinned), XcodeGen, TypeScript + `ws` (relay), Swift Testing + vitest.

## Global Constraints

- **Branch:** `feat/remote-terminal-mirror` (temiz `main` üzerine). `main`'e commit YASAK.
- **Kaynak scaffold:** Yeniden kullanılan dosyalar `git checkout lumi-remote -- <path>` ile getirilir (sıfırdan yazılmaz); sonra strip/adapt edilir.
- **SwiftTerm pin:** `https://github.com/migueldeicaza/SwiftTerm.git` revision `24a68bcadc479d945c7ca32f21ac0a8ab895c690` (Mac paketiyle aynı; iOS'a da bu revision eklenir).
- **Protokol sürümü:** `v = 1`. Envelope: `{v, type, payload}`, JSON text WS.
- **Ham bayt taşıma:** `data`/`scrollback`/`input` payload'ındaki `data` alanı **base64 string**.
- **Persistence uyumu:** `~/.lumi/remote.json` formatı korunur (bilinmeyen anahtarlar saklanır, karar 9).
- **Zorunlu mimari (spec/00-overview §4):** PTY→UI ack backpressure (`PTYProcess.ReadDirective`) bypass edilmez; render-crash izolasyonu (per-session PTY); replay güvenliği (scrollback sequence-güvenli + terminal auto-reply filtresi).
- **v1 kapsam kararı — resize:** Telefon Mac PTY'sini resize ETMEZ (canlı Mac oturumunu bozmamak için). Telefon emülatörü Mac'in cols/rows'una uyar; bu değerler `sessions` ve `scrollback` payload'ında taşınır. `resize` mesajı v1 protokolünde YOK (gelecek işi).

## Terminal-Stream Protokol Sözleşmesi (üç bileşen bu tabloya uyar)

| type | Yön | payload |
|---|---|---|
| `hello` | phone→mac(relay) | `{role, token}` (mevcut, korunur) |
| `welcome` | relay→phone | `{sessions:[SessionMeta], macOnline:Bool, lastSeenAt:Double?}` |
| `sessions` | mac→phone | `{sessions:[SessionMeta]}` |
| `subscribe` | phone→mac | `{sessionId:String}` |
| `unsubscribe` | phone→mac | `{sessionId:String}` |
| `scrollback` | mac→phone | `{sessionId, seq:Int, cols:Int, rows:Int, data:base64}` |
| `data` | mac→phone | `{sessionId, seq:Int, data:base64}` |
| `input` | phone→mac | `{sessionId, data:base64}` |
| `command` | phone→mac | `{commandId, action, ...}` (start/delete/set_model — mevcut) |
| `command_result` | mac→phone | `{commandId, ok:Bool, error?}` (mevcut) |
| `register_push`/`unregister_push` | phone→mac(relay) | mevcut, korunur |
| `ping`/`pong` | çift yön | mevcut, korunur |

`SessionMeta = {id:String, repoName:String, status:String, title:String?, model:String?, cols:Int, rows:Int}`

**KALDIRILAN tipler:** `snapshot`, `event`.

---

## Faz A — Relay (TypeScript)

### Task 1: RelayServer'ı branch'e getir ve protokolü terminal-stream'e uyarla

**Files:**
- Create (git checkout): `RelayServer/` (tümü) `git checkout lumi-remote -- RelayServer`
- Modify: `RelayServer/src/protocol.ts` (KNOWN_TYPES)
- Modify: `RelayServer/src/registry.ts` (`snapshot` → `sessions` alanı)
- Modify: `RelayServer/src/bridge.ts` (yönlendirme + welcome payload)
- Test: `RelayServer/src/protocol.test.ts`, `RelayServer/src/bridge.test.ts`, mevcut `RelayServer/src/isolation.test.ts`

**Interfaces:**
- Produces (relay wire): yukarıdaki protokol tablosu. `bridge` mac→phone `sessions`/`scrollback`/`data`/`command_result` broadcast eder; phone→mac `subscribe`/`unsubscribe`/`input`/`command` forward eder (mac offline → `command_result {ok:false,error:"mac_offline"}` yalnız `command` için; `subscribe`/`input` sessizce düşer).
- Consumes: yok (kök).

- [ ] **Step 1: Scaffold'ı getir ve bağımlılıkları kur**

```bash
git checkout lumi-remote -- RelayServer
cd RelayServer && npm install && cd ..
```

- [ ] **Step 2: Failing test — protocol yeni tipleri tanır, eski tipleri reddeder**

`RelayServer/src/protocol.test.ts` içine ekle:

```typescript
import { describe, it, expect } from 'vitest'
import { parseEnvelope } from './protocol'

describe('terminal-stream protocol', () => {
  it('accepts new terminal-stream types', () => {
    for (const type of ['sessions', 'subscribe', 'unsubscribe', 'scrollback', 'data', 'input']) {
      const raw = JSON.stringify({ v: 1, type, payload: {} })
      expect(parseEnvelope(raw)?.type).toBe(type)
    }
  })
  it('rejects removed chat types', () => {
    for (const type of ['snapshot', 'event']) {
      const raw = JSON.stringify({ v: 1, type, payload: {} })
      expect(parseEnvelope(raw)).toBeNull()
    }
  })
})
```

- [ ] **Step 3: Run — fail**

Run: `cd RelayServer && npx vitest run src/protocol.test.ts`
Expected: FAIL (`sessions` reddediliyor / `snapshot` kabul ediliyor).

- [ ] **Step 4: protocol.ts KNOWN_TYPES güncelle**

`RelayServer/src/protocol.ts` içinde `KNOWN_TYPES` set'ini değiştir:

```typescript
const KNOWN_TYPES = new Set([
  'hello', 'welcome', 'sessions', 'subscribe', 'unsubscribe',
  'scrollback', 'data', 'input', 'command', 'command_result',
  'register_push', 'unregister_push', 'ping', 'pong',
])
```

- [ ] **Step 5: Run — pass**

Run: `cd RelayServer && npx vitest run src/protocol.test.ts`
Expected: PASS.

- [ ] **Step 6: registry.ts — `snapshot` alanını `sessions`'a çevir**

`Room` arayüzünde ve tüm kullanımlarda `snapshot: Record<string,unknown> | null` alanını `sessions: unknown[] | null` yap (son yayınlanan session listesini cache'ler; yeni phone `welcome`'da alır). `get`/`attach` imzaları değişmez.

- [ ] **Step 7: Failing test — bridge yönlendirmesi**

`RelayServer/src/bridge.test.ts` içine ekle (fake `ClientLike` ile):

```typescript
import { describe, it, expect } from 'vitest'
import { Bridge } from './bridge'
import { Registry } from './registry'
import { envelope } from './protocol'

function fakeClient() {
  const sent: string[] = []
  return { sent, send: (d: string) => sent.push(d), close: () => {} }
}
const noPush = { send: async () => {} }

describe('bridge terminal routing', () => {
  it('forwards subscribe/input from phone to mac', () => {
    const reg = new Registry(); const bridge = new Bridge(reg, noPush)
    const mac = fakeClient(); const phone = fakeClient()
    const macS = bridge.handleHello(mac as any, JSON.parse(envelope('hello', { role: 'mac', token: 'x'.repeat(16) })))!
    const phoneS = bridge.handleHello(phone as any, JSON.parse(envelope('hello', { role: 'phone', token: 'x'.repeat(16) })))!
    bridge.handleMessage(phoneS, JSON.parse(envelope('subscribe', { sessionId: 's1' })))
    bridge.handleMessage(phoneS, JSON.parse(envelope('input', { sessionId: 's1', data: 'YQ==' })))
    expect(mac.sent.some(m => m.includes('"subscribe"'))).toBe(true)
    expect(mac.sent.some(m => m.includes('"input"'))).toBe(true)
  })
  it('broadcasts scrollback/data from mac to phones', () => {
    const reg = new Registry(); const bridge = new Bridge(reg, noPush)
    const mac = fakeClient(); const phone = fakeClient()
    bridge.handleHello(mac as any, JSON.parse(envelope('hello', { role: 'mac', token: 'x'.repeat(16) })))
    const phoneS = bridge.handleHello(phone as any, JSON.parse(envelope('hello', { role: 'phone', token: 'x'.repeat(16) })))!
    const macS = { client: mac, role: 'mac' as const, room: reg.get('x'.repeat(16))! }
    bridge.handleMessage(macS as any, JSON.parse(envelope('data', { sessionId: 's1', seq: 1, data: 'YQ==' })))
    expect(phone.sent.some(m => m.includes('"data"'))).toBe(true)
  })
})
```

- [ ] **Step 8: Run — fail**

Run: `cd RelayServer && npx vitest run src/bridge.test.ts`
Expected: FAIL (bridge hâlâ snapshot/event/command yönlendiriyor).

- [ ] **Step 9: bridge.ts yönlendirmeyi güncelle**

`handleMessage` içinde:
- mac rolünden gelen: `sessions`(→room.sessions cache + broadcast), `scrollback`, `data`, `command_result` → tüm `room.phones`'a broadcast.
- phone rolünden gelen: `subscribe`, `unsubscribe`, `input`, `command` → `room.mac`'e forward (mac null ise: yalnız `command` için `command_result {ok:false,error:"mac_offline"}` geri gönder; diğerleri düşür).
- `ping`→`pong` korunur.
`handleHello` phone welcome payload'ını `{sessions: room.sessions ?? [], macOnline: !!room.mac, lastSeenAt: room.lastSeenAt}` yap. `snapshot`/`event` case'lerini sil.

- [ ] **Step 10: Run — tüm relay testleri geçsin**

Run: `cd RelayServer && npx vitest run`
Expected: PASS (protocol, bridge, isolation).

- [ ] **Step 11: Commit**

```bash
git add RelayServer
git commit -m "feat(relay): terminal-stream protokolü — subscribe/data/input yönlendirme"
```

---

## Faz B — Mac tarafı (`LumiRemote`)

### Task 2: LumiRemote transport scaffold'ını branch'e getir, transcript'i strip et, target'ı ekle

**Files:**
- Create (git checkout, seçmeli): `LumiPackages/Sources/LumiRemote/{RelayConnection,RemoteConfigService,RemoteProtocol,RemoteService,RemoteCommandHandler}.swift`, `LumiPackages/Sources/LumiKit/Models/RemoteModels.swift`, `LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift`, `LumiPackages/Sources/LumiState/RemoteStore.swift`
- Create (git checkout): ilgili test dosyaları `LumiPackages/Tests/LumiRemoteTests/{RelayConnectionTests,RemoteConfigServiceTests,RemoteProtocolTests}.swift`, `LumiPackages/Tests/LumiStateTests/RemoteStoreTests.swift`, `LumiPackages/Tests/LumiKitTests/RemoteModelsTests.swift`
- **Getirilmeyecek (transcript modeli):** `TranscriptParser.swift`, `TranscriptWatcher.swift`, `TranscriptClaimRegistry.swift`, `SnapshotBuilder.swift` ve ilgili testleri.
- Modify: `LumiPackages/Package.swift` (LumiRemote target + LumiRemoteTests + LumiApp deps + AppContainer)
- Modify: `LumiPackages/Sources/LumiApp/AppContainer.swift` (RemoteService init — sonraki task'ta imza değişecek)

**Interfaces:**
- Consumes: yok (scaffold).
- Produces: `RelayConnecting` (WS client), `RemoteConfigService`, `RemoteStore`, `RemoteConfig`/`RemoteConnectionState`/`RemoteEvent`, `RemoteProtocol.envelope/decode`. Bunlar Task 4/5'te terminal-stream ile kullanılır. Bu task'ta `RemoteService`/`RemoteCommandHandler` derlensin diye transcript referansları geçici olarak stub'lanır (Task 5'te tamamen yeniden yazılacak).

- [ ] **Step 1: Reusable dosyaları getir**

```bash
git checkout lumi-remote -- \
  LumiPackages/Sources/LumiRemote/RelayConnection.swift \
  LumiPackages/Sources/LumiRemote/RemoteConfigService.swift \
  LumiPackages/Sources/LumiRemote/RemoteProtocol.swift \
  LumiPackages/Sources/LumiKit/Models/RemoteModels.swift \
  LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift \
  LumiPackages/Sources/LumiState/RemoteStore.swift \
  LumiPackages/Tests/LumiRemoteTests/RelayConnectionTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteConfigServiceTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift \
  LumiPackages/Tests/LumiStateTests/RemoteStoreTests.swift \
  LumiPackages/Tests/LumiKitTests/RemoteModelsTests.swift
```

- [ ] **Step 2: Package.swift — LumiRemote target ekle**

`LumiPackages/Package.swift`: products'a `.library(name: "LumiRemote", targets: ["LumiRemote"])`; targets'a `.target(name: "LumiRemote", dependencies: ["LumiKit"])` ve `.testTarget(name: "LumiRemoteTests", dependencies: ["LumiRemote"])`; `LumiApp` dependencies'ine `"LumiRemote"` ekle.

- [ ] **Step 3: RemoteService/RemoteCommandHandler'ı getir ve transcript'i geçici stub'la**

```bash
git checkout lumi-remote -- \
  LumiPackages/Sources/LumiRemote/RemoteService.swift \
  LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift
```

`RemoteService.swift` içinde `TranscriptWatcher`/`TranscriptClaimRegistry`/`SnapshotBuilder` referanslarını sil (bu task'ta yalnız derlensin: `start()`/`stop()`/`updateConfig`/`events()`/config lifecycle kalır; terminal→relay piping gövdesi Task 5'te yeniden yazılacağı için `handleTerminalEvent`/`startWatcher`/`handleFeedItem`/`sendSnapshot` gövdelerini boş bırak — `// TODO(Task5)` yerine gerçek boş implementasyon: hiçbir şey yapmayan metotlar). `RemoteCommandHandler` olduğu gibi kalır (start/delete/set_model/send_text/press_key).

- [ ] **Step 4: AppContainer derlensin**

`AppContainer.swift:80` `RemoteService(...)` çağrısını mevcut init imzasıyla eşle (bu task'ta imza değişmiyor).

- [ ] **Step 5: Derle + getirilen testler geçsin**

Run: `swift test --scratch-path /tmp/lumi-build --filter 'RelayConnectionTests|RemoteConfigServiceTests|RemoteProtocolTests|RemoteStoreTests|RemoteModelsTests'`
Expected: PASS (transport/config/store/codec scaffold'ı yeşil).

> Not: derleme disk-I/O sorunları için `--scratch-path /tmp/lumi-build` kullan (bellek: lumi-build-and-remote-findings).

- [ ] **Step 6: Commit**

```bash
git add LumiPackages
git commit -m "chore(remote): LumiRemote transport scaffold'ını main'e getir (transcript strip)"
```

### Task 3: TerminalServicing'i bayt-stream ile genişlet (LumiKit protokolü + LumiTerminal impl)

**Files:**
- Modify: `LumiPackages/Sources/LumiKit/Protocols/TerminalServicing.swift` (protokole 3 metot ekle)
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift` (Data broadcaster + input write + scrollback serialize)
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalPipeline.swift` (onFlushBatch → Data broadcaster besleme, zaten `onFlushBatch: (Data)->Void` var)
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift` (protokol metotlarını session'a delege et)
- Test: `LumiPackages/Tests/LumiTerminalTests/RemoteTapTests.swift` (yeni)

**Interfaces:**
- Consumes: mevcut `TerminalServicing` (LumiKit), `TerminalSession`/`TerminalPipeline`.
- Produces (LumiKit `TerminalServicing`'e eklenen, Task 5 tüketir):
  - `func subscribeOutput(_ id: TerminalID) -> AsyncStream<Data>` — abone olununca canlı bayt batch'leri; birden çok abone destekli (EventBroadcaster).
  - `func writeInput(_ data: Data, to id: TerminalID)` — baytları PTY'ye yaz (mevcut input filter üzerinden).
  - `func serializeScrollback(_ id: TerminalID) -> (data: Data, cols: Int, rows: Int)` — SwiftTerm buffer'ını (scrollback + görünür) düz metin bayt olarak dök; emülatör boyutunu döndür. Sequence-güvenli: çağrı anında tek atış snapshot.

- [ ] **Step 1: Failing test — subscribeOutput onFlushBatch baytlarını yayar**

`LumiPackages/Tests/LumiTerminalTests/RemoteTapTests.swift`:

```swift
import Testing
import Foundation
@testable import LumiTerminal
import LumiKit

@Suite struct RemoteTapTests {
    @Test func outputStreamReceivesFlushedBytes() async throws {
        let mgr = TerminalSessionManager(/* mevcut test init'i kullan */)
        let id = try mgr.spawnForTest()               // test yardımcı: echo shell
        var received = Data()
        let stream = mgr.subscribeOutput(id)
        try await mgr.writeInputForTest(id, "echo hi\r")
        for await batch in stream {                    // ilk batch'i bekle
            received.append(batch)
            if received.contains("hi".data(using: .utf8)!.first!) { break }
        }
        #expect(received.count > 0)
    }
}
```

> Test yardımcıları (`spawnForTest`, `writeInputForTest`) mevcut LumiTerminalTests altyapısına göre uyarlanır; PTY smoke test pattern'i (`PTYSmokeTester`) referans alınır.

- [ ] **Step 2: Run — fail**

Run: `swift test --scratch-path /tmp/lumi-build --filter RemoteTapTests`
Expected: FAIL (`subscribeOutput` yok).

- [ ] **Step 3: TerminalServicing protokolüne 3 metodu ekle**

`TerminalServicing.swift` protokolüne yukarıdaki üç imzayı ekle.

- [ ] **Step 4: TerminalSession'a Data broadcaster + scrollback + input ekle**

`TerminalSession.swift`:
- `private let remoteOutputBroadcaster = EventBroadcaster<Data>()` ekle.
- `TerminalPipeline.onFlushBatch` handler'ında (mevcut) ek olarak `remoteOutputBroadcaster.send(batch)` çağır.
- `func subscribeRemoteOutput() -> AsyncStream<Data>` → broadcaster.subscribe.
- `func writeRemoteInput(_ data: Data)` → mevcut PTY write yoluna (input filter) baytları ilet.
- `func serializeScrollback() -> (Data, Int, Int)` → `terminalView.getTerminal()` üzerinden buffer satırlarını `\r\n` ile birleştirip UTF-8 Data + `(cols, rows)` döndür.

- [ ] **Step 5: Manager delege etsin**

`TerminalSessionManager.swift`: `subscribeOutput/writeInput/serializeScrollback` protokol metotlarını ilgili `TerminalSession`'a delege et (bilinmeyen id → boş stream / no-op / boş Data).

- [ ] **Step 6: Run — pass**

Run: `swift test --scratch-path /tmp/lumi-build --filter RemoteTapTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add LumiPackages
git commit -m "feat(terminal): remote bayt-stream tap — subscribeOutput/writeInput/serializeScrollback"
```

### Task 4: Mac terminal-stream envelope helper'ları

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift` (encode/decode yardımcıları)
- Test: `LumiPackages/Tests/LumiRemoteTests/TerminalWireTests.swift` (yeni)

**Interfaces:**
- Produces (Task 5 tüketir):
  - `RemoteProtocol.sessionsPayload(_ metas: [SessionMeta]) -> [String: Any]`
  - `RemoteProtocol.scrollbackPayload(sessionId:seq:cols:rows:data:) -> [String: Any]` (data→base64)
  - `RemoteProtocol.dataPayload(sessionId:seq:data:) -> [String: Any]`
  - `RemoteProtocol.decodeSubscribe(_ p: [String:Any]) -> String?` (sessionId), `decodeInput(_ p:) -> (String, Data)?` (base64 decode)
  - `struct SessionMeta { let id, repoName: String; let status: String; let title, model: String?; let cols, rows: Int }` (LumiRemote iç tipi; JSON dict'e çevrilir)

- [ ] **Step 1: Failing test — input base64 round-trip + sessions payload**

```swift
import Testing
import Foundation
@testable import LumiRemote

@Suite struct TerminalWireTests {
    @Test func decodeInputBase64() {
        let p: [String: Any] = ["sessionId": "s1", "data": "aGk="]   // "hi"
        let out = RemoteProtocol.decodeInput(p)
        #expect(out?.0 == "s1")
        #expect(out?.1 == "hi".data(using: .utf8))
    }
    @Test func dataPayloadEncodesBase64() {
        let p = RemoteProtocol.dataPayload(sessionId: "s1", seq: 3, data: "hi".data(using: .utf8)!)
        #expect(p["data"] as? String == "aGk=")
        #expect(p["seq"] as? Int == 3)
    }
}
```

- [ ] **Step 2: Run — fail.** Run: `swift test --scratch-path /tmp/lumi-build --filter TerminalWireTests` → FAIL.
- [ ] **Step 3: RemoteProtocol'e helper'ları + SessionMeta'yı ekle** (yukarıdaki imzalar; base64 encode/decode `Data.base64EncodedString()` / `Data(base64Encoded:)`).
- [ ] **Step 4: Run — pass.** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(remote): terminal-stream envelope helper'ları"`

### Task 5: RemoteService'i terminal-ayna orchestrator'ına yeniden yaz

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift` (çekirdek yeniden yazım)
- Modify: `LumiPackages/Sources/LumiApp/AppContainer.swift` (init imzası: `transcriptsRoot` kaldır)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift` (yeni/yeniden)

**Interfaces:**
- Consumes: `RelayConnecting` (Task 2), `TerminalServicing.subscribeOutput/writeInput/serializeScrollback` (Task 3), `RemoteProtocol` helper'ları (Task 4), `RemoteCommandHandler` (start/delete/set_model).
- Produces: `RemoteService(paths:, terminal:, repos:, personas:, connection?:)` — terminal-stream davranışı.

Davranış:
1. `welcome` alınınca (veya terminal listesi değişince) `sessions` mesajı gönder (SnapshotBuilder yerine hafif `SessionMeta` listesi: terminal meta + repoName + status + model + cols/rows).
2. `subscribe {sessionId}` alınınca: (a) `terminal.serializeScrollback(id)` → `scrollback` mesajı (seq=0, cols, rows); (b) `terminal.subscribeOutput(id)` stream'ini başlat, her batch → `data` mesajı (seq artan). Abonelik registry: `[TerminalID: Task]`.
3. `unsubscribe {sessionId}` → o session'ın stream task'ını iptal et.
4. `input {sessionId, data}` → `terminal.writeInput(data, to: id)`.
5. `command` → mevcut `RemoteCommandHandler.handle` → `command_result`.
6. Terminal spawn/exit/statusChange → `sessions` mesajını yeniden yayınla.

- [ ] **Step 1: Failing test — subscribe → scrollback + data**

```swift
import Testing
import Foundation
@testable import LumiRemote
import LumiKit

@Suite @MainActor struct RemoteServiceTests {
    @Test func subscribeSendsScrollbackThenData() async throws {
        let conn = FakeRelayConnection()                 // send'leri kaydeder, inbound enjekte eder
        let term = FakeTerminalServicing()               // subscribeOutput/serializeScrollback stub
        term.scrollback = ("SCROLL".data(using: .utf8)!, 80, 24)
        let svc = RemoteService(paths: .testDefaults, terminal: term, repos: FakeRepos(), personas: FakePersonas(), connection: conn)
        await svc.start()
        conn.injectInbound(type: "subscribe", payload: ["sessionId": "s1"])
        term.emitOutput("s1", "LIVE".data(using: .utf8)!)
        try await conn.waitForSent(types: ["scrollback", "data"])
        #expect(conn.sentPayloads(type: "scrollback").first?["data"] as? String == "U0NST0xM")  // base64 "SCROLL"
        #expect(conn.sentPayloads(type: "data").first?["data"] as? String == "TElWRQ==")          // base64 "LIVE"
    }
    @Test func inputWritesToTerminal() async throws {
        let conn = FakeRelayConnection(); let term = FakeTerminalServicing()
        let svc = RemoteService(paths: .testDefaults, terminal: term, repos: FakeRepos(), personas: FakePersonas(), connection: conn)
        await svc.start()
        conn.injectInbound(type: "input", payload: ["sessionId": "s1", "data": "aGk="])
        try await term.waitForInput()
        #expect(term.writtenInput["s1"] == "hi".data(using: .utf8))
    }
}
```

> `FakeRelayConnection`/`FakeTerminalServicing`/`FakeRepos`/`FakePersonas` bu test dosyasında tanımlanır; mevcut `RemoteServiceTests` (lumi-remote) fake'leri referans alınır ve terminal-stream'e uyarlanır.

- [ ] **Step 2: Run — fail.** Run: `swift test --scratch-path /tmp/lumi-build --filter RemoteServiceTests` → FAIL.
- [ ] **Step 3: RemoteService gövdesini yaz** (yukarıdaki 1–6 davranışı; abonelik task registry'si; seq sayaçları per-session; `sessions` yeniden yayın).
- [ ] **Step 4: AppContainer init imzasını güncelle** (`transcriptsRoot` argümanını kaldır).
- [ ] **Step 5: Run — pass.** → PASS.
- [ ] **Step 6: Tüm Mac remote testleri**

Run: `swift test --scratch-path /tmp/lumi-build --filter 'LumiRemoteTests|LumiStateTests|LumiKitTests|LumiTerminalTests'`
Expected: PASS.

- [ ] **Step 7: Commit** `git commit -m "feat(remote): RemoteService terminal-ayna orchestrator'ı"`

---

## Faz C — iOS tarafı (`LumiMobile`)

### Task 6: LumiMobile shell + transport scaffold'ını getir, chat modelini strip et, SwiftTerm ekle

**Files:**
- Create (git checkout, seçmeli): `LumiMobile/` app shell + LumiMobileKit transport/pairing/push. **Getirilmeyecek chat dosyaları:** `TurnFilter.swift` ve `SessionDetailView.swift` (yerine Task 9/10/11'de yeni).
- Modify: `LumiMobile/project.yml` (SwiftTerm package + LumiMobileKit'e dependency)
- Modify: `LumiMobile/LumiMobileKit/Package.swift` (SwiftTerm dependency + product)

**Interfaces:**
- Produces: `RelayClient`/`RelayClienting`, `WebSocketConnection`, `Pairing`/`SecureStore`/`KeychainStore`, `PushCoordinator`, `DiagLog`, `AppModel` (chat kısımları Task 8'de refactor edilecek), app shell (`LumiMobileApp`, `RootView`, `SessionListView`, `PairingView`, `QRScannerView`, `NewSessionView`).

- [ ] **Step 1: Scaffold'ı getir**

```bash
git checkout lumi-remote -- LumiMobile
git rm -q LumiMobile/LumiMobileKit/Sources/LumiMobileKit/TurnFilter.swift \
          LumiMobile/App/SessionDetailView.swift \
          LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/TurnFilterTests.swift
```

- [ ] **Step 2: SwiftTerm dependency ekle**

`LumiMobile/LumiMobileKit/Package.swift`: `dependencies`'e SwiftTerm (revision `24a68bcadc479d945c7ca32f21ac0a8ab895c690`, platform `.iOS(.v17)`), `LumiMobileKit` target'ına `.product(name: "SwiftTerm", package: "SwiftTerm")`.
`LumiMobile/project.yml`: `packages:` altına SwiftTerm (aynı url+revision); `LumiMobile` target dependency'sine ekle.

- [ ] **Step 3: XcodeGen + derleme dumanı**

```bash
cd LumiMobile && xcodegen generate && cd ..
```
Expected: proje üretilir (bellek: xcodegen şart — ios-xcodeproj-is-generated).

- [ ] **Step 4: Chat referanslarını geçici stub'la**

`AppModel.swift` bu aşamada hâlâ `feeds`/`FeedItem`/`RemoteEvent.transcript` içeriyor — derlensin diye SessionDetailView kaldırıldığından kırılan referansları düzelt (Task 8'de tamamen refactor). `RootView`/`SessionListView` NavigationDestination'ı geçici olarak boş bir `Text("terminal")` placeholder view'a yönlendir.

- [ ] **Step 5: LumiMobileKit testleri (transport/pairing/push) geçsin**

Run: `swift test --package-path LumiMobile/LumiMobileKit --scratch-path /tmp/lumikit-build --filter 'RelayClientTests|PairingTests|ProtocolTests|PushCoordinatorTests|DiagLogTests'`
Expected: PASS (chat'e bağımlı olmayanlar).

- [ ] **Step 6: Commit** `git commit -m "chore(mobile): LumiMobile shell + transport scaffold (chat strip, SwiftTerm dep)"`

### Task 7: iOS PhoneProtocol terminal-stream codec

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` (yeni tipler; chat tipleri kaldır)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/TerminalProtocolTests.swift` (yeni)

**Interfaces:**
- Produces (Task 8 tüketir):
  - `enum ServerMessage { case welcome(Welcome); case sessions([SessionMeta]); case scrollback(TerminalChunk); case data(TerminalChunk); case commandResult(CommandResult); case pong }`
  - `struct SessionMeta { let id, repoName, status: String; let title, model: String?; let cols, rows: Int }`
  - `struct TerminalChunk { let sessionId: String; let seq: Int; let cols, rows: Int?; let bytes: Data }` (base64 decode edilmiş)
  - Encode: `PhoneProtocol.subscribeFrame(sessionId:)`, `unsubscribeFrame(sessionId:)`, `inputFrame(sessionId:, data: Data)` (base64), mevcut `helloFrame/pingFrame/commandFrame/registerPushFrame`.
  - **Kaldırılan:** `FeedItem`, `RemoteEvent`, `decodeFeedItem`, `decodeEvent`, `Snapshot`(chat), `Welcome.snapshot` → `Welcome.sessions`.

- [ ] **Step 1: Failing test — data decode + subscribe/input encode**

```swift
import Testing
import Foundation
@testable import LumiMobileKit

@Suite struct TerminalProtocolTests {
    @Test func decodesDataChunk() {
        let text = #"{"v":1,"type":"data","payload":{"sessionId":"s1","seq":2,"data":"aGk="}}"#
        guard case .data(let chunk)? = PhoneProtocol.decodeServerMessage(text) else { Issue.record("wrong"); return }
        #expect(chunk.sessionId == "s1"); #expect(chunk.seq == 2)
        #expect(chunk.bytes == "hi".data(using: .utf8))
    }
    @Test func encodesInputFrameBase64() {
        let frame = PhoneProtocol.inputFrame(sessionId: "s1", data: "hi".data(using: .utf8)!)
        #expect(frame.contains(#""type":"input""#)); #expect(frame.contains(#""aGk=""#))
    }
}
```

- [ ] **Step 2: Run — fail.** Run: `swift test --package-path LumiMobile/LumiMobileKit --scratch-path /tmp/lumikit-build --filter TerminalProtocolTests` → FAIL.
- [ ] **Step 3: Models.swift + PhoneProtocol.swift'i güncelle** (yukarıdaki tipler; chat tiplerini sil; `decodeServerMessage`'a sessions/scrollback/data case'leri; base64 decode).
- [ ] **Step 4: Run — pass.** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(mobile): PhoneProtocol terminal-stream codec"`

### Task 8: AppModel'i terminal byte-routing'e refactor et

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift` (yeniden)

**Interfaces:**
- Consumes: `ServerMessage` (Task 7), `RelayClienting`.
- Produces (Task 9/11 tüketir):
  - `var sessions: [SessionMeta]`, `var macOnline: Bool`, `var connection: ConnectionState` (korunur).
  - `func subscribe(_ sessionId: String)` → `subscribe` frame gönder + aktif session olarak işaretle.
  - `func unsubscribe(_ sessionId: String)`.
  - `func sendInput(_ sessionId: String, _ data: Data)` → `input` frame.
  - `func terminalStream(_ sessionId: String) -> AsyncStream<TerminalChunk>` → o session'a gelen scrollback+data chunk'ları (aktif session için ring buffer + canlı akış; view mount olunca replay).
  - `handle(_:)`: `.sessions`→güncelle; `.scrollback`/`.data`→ ilgili session sink'ine yield; `.commandResult`→komut durumu.
  - **Kaldırılan:** `feeds`, `questionCard`, `requestHistory`, `sendText`(chat), `pressKey`, `retrySend`, `lastFailedUserMessageId`, `activeQuestions`, `screenTails`.

- [ ] **Step 1: Failing test — data chunk aktif session stream'ine akar**

```swift
@Suite @MainActor struct AppModelTests {
    @Test func routesDataToSessionStream() async throws {
        let client = FakeRelayClient()
        let model = AppModel(client: client, store: InMemorySecureStore(), prefs: InMemoryPreferenceStore())
        await model.start()
        model.subscribe("s1")
        var got = Data()
        let stream = model.terminalStream("s1")
        client.emit(.data(TerminalChunk(sessionId: "s1", seq: 1, cols: nil, rows: nil, bytes: "hi".data(using: .utf8)!)))
        for await chunk in stream { got.append(chunk.bytes); break }
        #expect(got == "hi".data(using: .utf8))
        #expect(client.sentFrames.contains { $0.contains(#""type":"subscribe""#) })
    }
}
```

- [ ] **Step 2: Run — fail.** → FAIL.
- [ ] **Step 3: AppModel'i refactor et** (feed modelini sil; SessionMeta listesi + per-session chunk sink/ring buffer; subscribe/unsubscribe/sendInput/terminalStream).
- [ ] **Step 4: Run — pass.** → PASS.
- [ ] **Step 5: Commit** `git commit -m "refactor(mobile): AppModel terminal byte-routing"`

### Task 9: TerminalSessionView — SwiftTerm render + input

**Files:**
- Create: `LumiMobile/App/TerminalSessionView.swift`
- Create: `LumiMobile/App/TerminalHostView.swift` (UIViewRepresentable → SwiftTerm `TerminalView`)
- Modify: `LumiMobile/App/RootView.swift` / `SessionListView.swift` (NavigationDestination → TerminalSessionView)

**Interfaces:**
- Consumes: `AppModel.terminalStream/subscribe/unsubscribe/sendInput` (Task 8), SwiftTerm `TerminalView` (UIKit).
- Produces: kullanıcı-görülür terminal ekranı.

- [ ] **Step 1: TerminalHostView (UIViewRepresentable)**

`TerminalHostView`: SwiftTerm `TerminalView` sarmalar. `makeUIView` bir `TerminalView` döndürür, `TerminalViewDelegate.send(source:data:)` → `onInput(Data(data))` closure. `feed(_ bytes: [UInt8])` için Coordinator bir referans tutar; `.task` içinde `for await chunk in model.terminalStream(id) { view.feed(byteArray: chunk.bytes[...]) ; if let c=chunk.cols { view.getTerminal().resize(cols:c, rows:chunk.rows!) } }`.

```swift
import SwiftUI
import SwiftTerm

struct TerminalHostView: UIViewRepresentable {
    let onInput: (Data) -> Void
    let register: (TerminalView) -> Void      // Coordinator view'ı üst katmana verir
    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput) }
    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .zero)
        v.terminalDelegate = context.coordinator
        register(v)
        return v
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (Data) -> Void
        init(onInput: @escaping (Data) -> Void) { self.onInput = onInput }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput(Data(data)) }
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
```

- [ ] **Step 2: TerminalSessionView**

`.task(id: sessionId)`: `model.subscribe(sessionId)`; stream'i host view'a bağla. `.onDisappear`: `model.unsubscribe(sessionId)`. Toolbar: status badge + model menüsü (mevcut `model.setModel` command'ı). Alt: accessory bar (Task 10).

- [ ] **Step 3: Navigation'ı bağla** — `SessionListView` destination → `TerminalSessionView(model:sessionId:)`.

- [ ] **Step 4: Derleme dumanı** `cd LumiMobile && xcodegen generate && xcodebuild -scheme LumiMobile -destination 'generic/platform=iOS Simulator' build` → BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `git commit -m "feat(mobile): SwiftTerm terminal görünümü + input"`

### Task 10: Aksesuar tuş çubuğu → input baytları

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AccessoryKeys.swift` (saf bayt eşlemesi)
- Create: `LumiMobile/App/AccessoryBar.swift` (SwiftUI çubuk)
- Modify: `LumiMobile/App/TerminalSessionView.swift` (çubuğu ekle)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AccessoryKeysTests.swift`

**Interfaces:**
- Produces: `enum AccessoryKey { case up,down,left,right,esc,tab,enter,ctrlC }`, `func bytes(for key: AccessoryKey) -> Data`.

- [ ] **Step 1: Failing test — tuş baytları doğru**

```swift
@Suite struct AccessoryKeysTests {
    @Test func mapsControlBytes() {
        #expect(bytes(for: .esc) == Data([0x1B]))
        #expect(bytes(for: .enter) == Data([0x0D]))
        #expect(bytes(for: .tab) == Data([0x09]))
        #expect(bytes(for: .ctrlC) == Data([0x03]))
        #expect(bytes(for: .up) == Data([0x1B, 0x5B, 0x41]))     // ESC [ A
        #expect(bytes(for: .down) == Data([0x1B, 0x5B, 0x42]))
        #expect(bytes(for: .right) == Data([0x1B, 0x5B, 0x43]))
        #expect(bytes(for: .left) == Data([0x1B, 0x5B, 0x44]))
    }
}
```

- [ ] **Step 2: Run — fail.** → FAIL.
- [ ] **Step 3: AccessoryKeys.swift yaz** (yukarıdaki eşleme).
- [ ] **Step 4: Run — pass.** → PASS.
- [ ] **Step 5: AccessoryBar UI + TerminalSessionView'e bağla** — her buton `model.sendInput(sessionId, bytes(for: key))`. Metin girişi (TextField) → UTF-8 bytes + gönder.
- [ ] **Step 6: Commit** `git commit -m "feat(mobile): aksesuar tuş çubuğu → input baytları"`

### Task 11: Reconnect subscription replay

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift` (ekleme)

**Interfaces:**
- Consumes: `ClientEvent.stateChanged` (RelayClient), `AppModel.activeSessionId`.
- Produces: bağlantı `connected`'e döndüğünde aktif session'a otomatik yeniden `subscribe` (Mac taze scrollback gönderir).

- [ ] **Step 1: Failing test — reconnect'te yeniden subscribe**

```swift
@Test func resubscribesActiveSessionOnReconnect() async throws {
    let client = FakeRelayClient()
    let model = AppModel(client: client, store: InMemorySecureStore(), prefs: InMemoryPreferenceStore())
    await model.start()
    model.subscribe("s1")
    client.sentFrames.removeAll()
    client.emit(.stateChanged(.disconnected))
    client.emit(.stateChanged(.connected))
    try await Task.sleep(for: .milliseconds(50))
    #expect(client.sentFrames.contains { $0.contains(#""type":"subscribe""#) && $0.contains("s1") })
}
```

- [ ] **Step 2: Run — fail.** → FAIL.
- [ ] **Step 3: AppModel'de reconnect handler** — `.stateChanged(.connected)` alınınca `activeSessionId` varsa `subscribe(activeSessionId)` tekrar gönder.
- [ ] **Step 4: Run — pass.** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(mobile): reconnect subscription replay"`

---

## Faz D — Uçtan uca

### Task 12: E2E wire testi — Mac ↔ relay ↔ phone

**Files:**
- Modify/Create: `LumiPackages/Tests/LumiRemoteTests/EndToEndWireTests.swift` (Mac↔protokol) veya cross-codebase wire testi (mevcut `EndToEndWireTests` pattern'i uyarlanır)
- Test: yeni `subscribe → scrollback → data → input` tam turu

**Interfaces:**
- Consumes: `RemoteService` (Mac), `RelayServer` (gerçek WS veya in-process bridge), `AppModel`+`PhoneProtocol` (phone). Mevcut `EndToEndWireTests`/`isolation.test.ts` gerçek-WS pattern'i taban alınır.

- [ ] **Step 1: E2E test yaz**

Senaryo: Mac `RemoteService` gerçek `RelayConnection` ile relay'e bağlanır (relay `startServer` in-process, rastgele port); phone tarafı `PhoneProtocol` frame'leri ile aynı token'a bağlanır. Adımlar:
1. Phone `subscribe {sessionId:"s1"}` gönderir.
2. Mac `scrollback` (seq 0) + fake terminal output → `data` (seq 1) yayınlar.
3. Phone `input` ("hi") gönderir → Mac `terminal.writeInput` çağrılır (fake terminal doğrular).
Assert: phone base64-decode edilmiş `scrollback`+`data` baytlarını alır; Mac fake terminal `"hi"` input alır.

- [ ] **Step 2: Run — pass.**

Run: `swift test --scratch-path /tmp/lumi-build --filter EndToEndWireTests`
Expected: PASS.

- [ ] **Step 3: Relay izolasyon regresyonu** Run: `cd RelayServer && npx vitest run` → PASS (farklı token = farklı oda korunur).
- [ ] **Step 4: Commit** `git commit -m "test(remote): E2E terminal-ayna wire turu"`

---

## Self-Review Notları

- **Spec kapsamı:** Spec §3 (Mac tap) → Task 3/4/5; §4 (relay protokol) → Task 1; §5 (iOS terminal) → Task 6–10; §6 (güvenilirlik) → Task 11 + relay heartbeat (Task 1'de mevcut `server.ts`); §8 (test) → her task TDD + Task 12 E2E. §10 zorunlu mimari: ReadDirective (dokunulmaz), per-session PTY (Task 3), scrollback sequence-güvenli tek-atış (Task 3/5).
- **Kapsam sapması (resize):** Global Constraints'te belgelendi; kullanıcıya handoff'ta bildirilecek.
- **Tip tutarlılığı:** `SessionMeta` (Mac `RemoteProtocol` iç tipi ↔ iOS `Models.SessionMeta`) alanları eşleşir: `id,repoName,status,title?,model?,cols,rows`. `TerminalChunk` base64-decode edilmiş `bytes: Data` taşır.
- **Manuel doğrulama (kod dışı, handoff sonrası):** gerçek cihazda pairing + terminal render + accessory tuşlarla Claude sorusuna cevap; reconnect senaryosu; çoklu-cihaz izolasyonu.
