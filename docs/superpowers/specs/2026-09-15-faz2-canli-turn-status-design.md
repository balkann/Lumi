# Faz 2 — Canlı Turn Status (Remote Native Chat)

**Tarih:** 2026-09-15
**Branch:** `feat/remote-orca-main` (main'e commit YOK)
**Bağlam:** Remote native chat Faz 1 (transcript-tail) çalışıyor. Bu spec, telefonda
ajanın "çalıştığını + ne yaptığını" canlı göstermeyi ve turu durdurmayı ekler.
orca paritesi kaynak modeli: **transcript (tam turlar) + hook (working/araç/Stop)**.

## 1. Amaç ve kapsam

Telefon chat görünümünde, bir tur sürerken kullanıcı şunları görür/yapar:

- **"Çalışıyor 12sn"** — tur başından itibaren canlı geçen süre + spinner.
- **Araç çipi** — o an koşan aracın adı (ör. `Bash`, `Read`, `Edit`), sonuç düşmeden.
- **Stop** — turu keser (Ctrl-C).

Araç çağrıları/sonuçları ve araçlar-arası ara metin, Faz 1 transcript-tail'i
sayesinde zaten adım-adım belirir; bu spec onların ÜSTÜNE bir **turn-status
bandı** + **Stop** ekler.

### Kapsam dışı (bilinçli)

- **Nihai düz-metin cevabın token-token akışı.** Ampirik olarak kanıtlandı: claude
  düz-metin cevabı transcript'e **tur bitince tek atomik blok** yazar (token-token
  değil), ve hook'lar düz-metin üretimi sırasında tetiklenmez. Gerçek token akışı
  yalnız ham terminal scrape ile mümkün (kırılgan) — bilinçle dışarıda. Nihai cevap
  tamamlanınca "pop-in" olarak belirir.
- Alt-ajan araçlarının ayrı gösterimi (lider araç gösterilir; detay = Faz 5).
- Ask/permission/soru kartları = Faz 3 (ayrı spec).
- Codex sağlayıcısı için turn-status = ileride (bu spec Claude'a odaklı; model
  sağlayıcı-agnostik, reducer Codex event adlarını da tanır ama UI/uçtan-uca
  doğrulama Claude içindir).

## 2. Mevcut zemin (yeniden kullanılan)

- **`AgentHookServer.events() -> AsyncStream<AgentHookEvent>`** — tüm hook
  olaylarının yayın akışı (her olay `terminalID` taşır). RemoteService'in tapleyeceği
  temiz enjeksiyon noktası.
- **`AgentHookEvent`** alanları: `kind` (userPromptSubmit/preToolUse/postToolUse/
  stop/…), `toolName`, `isInterrupt`, `agentID`, `source`. Araç adı hazır.
- **`SessionMeta.status` (idle/working/error)** — mevcut durum göstergesi; bu spec
  onu OKUMAZ (working otoritesi hook reducer'dır, §4.3), yalnız aynı hook
  kaynağından türediğini not eder. Tur başlangıç zamanı reducer'ın kendi enjekte
  saatinden gelir (§4.2), `statusChangedAt`'ten değil.
- **Chat wire deseni** — `chat`/`chat_append` frame'leri Mac→relay→telefon opak
  geçiyor; yeni frame aynı deseni izler.
- **Ctrl-C input yolu** — `AccessoryBar`'daki `^C` (0x03) ve `sendInput` mevcut.

## 3. Mimari ve veri akışı

```
hook script → AgentHookServer.events() ─┐
                                         ├─► TurnStatusReducer (session başına)
SessionMeta.status/statusChangedAt ──────┘        │  değişince
                                                   ▼
                                RemoteService  ── chat_status frame ──► relay (passthrough)
                                                                          │
                                                                          ▼
                                                     AppModel.turnStatus[sid] (@Observable)
                                                                          │
                                                                          ▼
                                                     MobileChatView turn-status bandı + Stop
```

## 4. Bileşenler

### 4.1 `ChatTurnStatus` modeli (LumiKit + LumiMobileKit kopyası)

```
struct ChatTurnStatus: Sendable, Equatable {
    var working: Bool
    var startedAtMs: Int?   // tur başı (epoch ms); working=false ise nil
    var tool: String?       // o an koşan araç adı; yoksa nil
}
```

Değişmez wire modeli; Faz 1'deki `ChatMessage` gibi LumiKit'te tanımlanır,
LumiMobileKit'e birebir kopyalanır (mevcut kalıp).

### 4.2 `TurnStatusReducer` (LumiServices)

Saf, test-edilebilir reducer. Girdi: `AgentHookEvent` (+ opsiyonel başlangıç
zamanı enjeksiyonu — test için deterministik saat). Session başına durum katlar:

| Event | Etki |
|---|---|
| `userPromptSubmit` | `working=true`, `startedAtMs=now`, `tool=nil` |
| `preToolUse` | `tool = event.toolName` (working korunur) |
| `postToolUse` / `postToolUseFailure` | `tool=nil` |
| `stop` / `stopFailure` | `working=false`, `startedAtMs=nil`, `tool=nil` |
| `sessionStart(source=clear)` | sıfırla (idle) |
| diğer (subagent*, permissionRequest, unknown) | değişiklik yok |

`now` bir enjekte edilen closure'dan (`() -> Date`) gelir → testte sabitlenir
(`Date.now`/`Math.random` yasağıyla uyumlu; üretimde `Date()`).

Çıktı: değişiklik olduğunda yeni `ChatTurnStatus` (idempotent — aynı durum
tekrar yayılmaz).

### 4.3 RemoteService entegrasyonu

- `RemoteService.init`'e `hookEvents: AsyncStream<AgentHookEvent>` (veya
  `any AgentHookEventStreaming`) enjekte edilir; `RemoteFeatureAssembly` gerçek
  `AgentHookServer.events()`'i verir. Test/no-op için boş stream default'u
  (`chatSource`/`trust` kalıbı).
- Servis, hook akışını tek bir Task'te tüketir; her olay için ilgili session'ın
  `TurnStatusReducer`'ını ilerletir. Durum değişirse ve o session **chat modunda
  abone** ise `chat_status` frame'i yollar.
- **Chat subscribe anında** mevcut turn-status **snapshot** olarak yollanır
  (reconnect'te bant doğru görünür). working değilse boş/idle snapshot.
- `.exited`/unsubscribe/`/clear`'da session durumu temizlenir (mevcut
  `cancelChatSubscription` yanında).

> Not: "working" için tek kaynak hook reducer'dır (userPromptSubmit→stop).
> `SessionMeta.status` ile çift-kaynak KULLANILMAZ — tek otorite hook, böylece
> bant ile araç çipi aynı olay zincirinden türer ve tutarsızlaşmaz.

### 4.4 Wire — `chat_status` frame

- Yön: Mac→telefon. Payload: `{ sessionId, working, startedAtMs?, tool? }`.
- `RemoteProtocol`'e `chatStatusPayload(...)` + decode; `PhoneProtocol`'e decode.
- Relay: `chat_status`, `chat`/`chat_append` gibi opak passthrough allowlist'ine
  eklenir (`RelayServer/src/{protocol,bridge}.ts`).

### 4.5 Telefon — AppModel + UI

- `AppModel`: `private(set) var turnStatus: [String: ChatTurnStatus]`. `chat_status`
  mesajı handle edilir → `turnStatus[sid]` güncellenir (@Observable).
- **Gizli oturum temizliği**: aktif ölen oturumda `turnStatus[sid]` temizlenir
  (mevcut `chatBySession` paralelinde).
- `MobileChatView`: composer'ın hemen üstünde **turn-status bandı**:
  - `working==true` iken görünür; değilse gizli.
  - Sol: spinner + "Çalışıyor {n}sn" — `n`, `startedAtMs`'ten `TimelineView`/timer
    ile canlı (saniyede bir).
  - Orta: `tool` varsa monospace çip (ör. `Bash`).
  - Sağ: **Stop** butonu → `model.sendInput(sessionId, Data([0x03]))` yani Ctrl-C
    tek baytı. Tek keystroke olduğu için `submitText` (metin→settle→CR) ayrımı
    GEREKMEZ — ham `sendInput` yeterli.
- Literaller LumiMobile teması (Faz 4 token'ları kapsam dışı; mevcut mobil
  literal kalıbı korunur — `DesignTokenLintTests` LumiMobile'ı kapsamaz).

## 5. Hata / kenar durumlar

- **Bayat working** (claude çöktü, Stop hook'u gelmedi): bant canlı saymaya devam
  eder; sonraki gerçek `stop`/yeni tur snapshot'u düzeltir. İlk sürümde ek
  heartbeat/timeout YOK (YAGNI); gerekirse sonra eklenir.
- **Stop iki-uçlu**: Ctrl-C gönderimi turu keser; claude `Stop.is_interrupt=true`
  yayar → reducer working=false yapar. Optimistic UI: Stop'a basınca bandı hemen
  "durduruluyor" göstermeyiz; gerçek stop event'ini bekleriz (yanıltıcı durum
  olmasın).
- **`/clear`**: `sessionStart(source=clear)` reducer'ı sıfırlar; transcript takibi
  ayrı (karar 21 / Faz 5 kapsamı) — bu spec yalnız status'u sıfırlar.
- **Reconnect (chat modda)**: `subscribeChat` snapshot'ı yeniden yollar (§4.3);
  ayrıca reconnect zaten chat modunda kalır (mevcut `activeChatMode` fix).
- **Çoklu session**: reducer session başına izole; `chat_status` yalnız ilgili
  chat abonesine gider (oda-içi session ayrımı mevcut).

## 6. Test stratejisi

- **`TurnStatusReducer` birim** (LumiServicesTests): event dizileri → beklenen
  `ChatTurnStatus` (prompt→working, preTool→tool, postTool→tool nil, stop→idle,
  clear→reset, idempotent tekrar yayılmaz). Enjekte saatle deterministik.
- **RemoteService** (LumiRemoteTests): fake hook stream + chat abonesi →
  `chat_status` frame'i yayılır; chat abonesi olmayan session'a yayılmaz; subscribe
  anında snapshot gönderilir. `FakeAgentHookEventStream` LumiTestSupport'a eklenir.
- **AppModel** (LumiMobileKitTests): `chat_status` decode + `turnStatus` merge;
  ölen aktif oturumda temizlenir.
- **Wire** (RelayServer): `chat_status` mac→phone passthrough; oda izolasyonu.
- **iOS bant** = cihaz doğrulaması (SwiftUI; canlı sayaç + Stop).

## 7. Bilinçli sadelik (YAGNI)

- Token-token nihai metin YOK (§1 kapsam dışı).
- Heartbeat/timeout YOK (§5).
- Alt-ajan araç ağacı YOK (lider araç).
- Codex uçtan-uca doğrulama YOK (model hazır, UI Claude).
- Optimistic Stop YOK (gerçek event beklenir).

## 8. Dosya envanteri (tahmini)

| Katman | Dosya | İş |
|---|---|---|
| Model | `LumiKit/Models/ChatTurnStatus.swift` (+ LumiMobileKit kopyası) | wire modeli |
| Reducer | `LumiServices/NativeChat/TurnStatusReducer.swift` | hook→status |
| Servis | `LumiRemote/RemoteService.swift` (+ init) | hook tap + chat_status yayını + snapshot |
| Composition | `LumiAppCore/Features/RemoteFeatureAssembly.swift` | `AgentHookServer.events()` enjeksiyonu |
| Protokol | `LumiRemote/RemoteProtocol.swift`, `LumiMobileKit/PhoneProtocol.swift` | chat_status encode/decode |
| Relay | `RelayServer/src/{protocol,bridge}.ts` | passthrough allowlist |
| Telefon model | `LumiMobileKit/AppModel.swift` | turnStatus merge |
| Telefon UI | `LumiMobile/App/MobileChatView.swift` (+ olası `TurnStatusBar.swift`) | bant + Stop |
| Test | yukarıdaki 4 test hedefi + `FakeAgentHookEventStream` | birim + wire |

## 9. Build / doğrulama

```bash
cd LumiPackages && swift test --scratch-path /tmp/lumi \
  --filter "TurnStatusReducer|RemoteServiceTests|TranscriptChatSource"
cd LumiMobile/LumiMobileKit && swift test
cd RelayServer && npm test
# Mac: Scripts/make-rework-app.sh (KULLANICI temiz env'den başlatır — bkz. launch-env kuralı)
# iOS: xcodegen generate (yeni App/ dosyası varsa) → xcodebuild → devicectl install
```

**Launch-env kuralı (kritik):** LumiRework'ü Claude Code bash aracından `open` ile
başlatma — `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID` env'i spawn edilen claude'lara
sızar ve claude'u "nested child session" moduna sokup transcript yazmasını engeller
(chat boşalır). Her zaman KULLANICI Finder/Dock'tan başlatır (temiz env).
