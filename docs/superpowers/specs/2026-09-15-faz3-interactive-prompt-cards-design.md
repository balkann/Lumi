# Faz 3 — Etkileşimli Prompt Kartları (Remote Native Chat)

**Tarih:** 2026-09-15
**Branch:** `feat/remote-orca-main` (main'e commit YOK)
**Bağlam:** Native chat Faz 1 (transcript-tail) + Faz 2 (canlı turn-status) çalışıyor.
Bu spec, telefonda **izin (permission) ve soru (AskUserQuestion) prompt'larını
tıklanabilir kart** olarak gösterip cevabı geri göndermeyi ekler.
**Referans: orca** (`../orca` = `/Users/balkan/Desktop/side-projects/orca`), lumi-remote spec-4 DEĞİL.

## 1. Amaç ve kapsam

Telefon chat görünümünde, bir tur sürerken ajan bir **karar** beklediğinde
(bir aracı çalıştırmak için izin, ya da çoktan-seçmeli bir soru) kullanıcı:

- **İzin kartı** görür (ör. "Bash çalıştırılsın mı? `npm install`") → **Allow / Deny** butonları.
- **Soru kartı** görür (Claude'un `AskUserQuestion` aracı) → tek soruda tıklanabilir seçenekler.
- Seçeneğe basınca cevap ajana ulaşır ve kart **resolved** olup kaybolur.

### Kaynak modeli (orca paritesi, bağlayıcı)

orca **hook-first**: prompt'lar terminal-scrape ile değil, **hook'tan gelen tam
tool_input** ile tespit edilir. Bu spec de aynısını yapar — mevcut hook altyapısı
(Faz 2 `AgentHookServer`) genişletilerek `tool_input` taşınır. **Terminal ekran
scraping YOK** (o lumi-remote spec-4'tü; bilinçli olarak kullanılmaz).

### Kritik mimari gerçek (bağlayıcı)

orca claude'u **Agent SDK** ile çalıştırıp prompt'ı SDK promise'iyle resolve eder.
**Biz claude'u ham CLI olarak bir PTY'de mirror ediyoruz — resolve edilecek SDK
promise'i YOK.** Dolayısıyla:

- **Telefon ↔ host: journal** — yapısal prompt item'ı (`itemId`/`revision`/
  `resolution`) host→telefon yayınlanır; telefon yapısal cevap (`itemId`/
  `expectedRevision`/`optionId`) yollar. Temiz mobil UX + revision güvenliği.
- **Host ↔ claude: keystroke** — host, seçilen `optionId`'yi **PTY'ye yazılan tuş
  dizisine** çevirir (mevcut `writeInput`/`sendInput`, Faz 2). Bu kaçınılmaz.

Yani journal telefon UX'ini sağlamlaştırır (fragile keystroke-echo tespiti yerine
gerçek resolution state), ama actuation altta keystroke'tur.

### Kapsam (Faz 3.0)

- **İzin prompt'ları**: Allow / Deny (iki seçenek).
- **AskUserQuestion**: **tek soru, tek seçim** (single-question, single-select).

### Kapsam dışı (bilinçli — sonraki alt-fazlar)

- Çoklu-seçim (multiSelect), gruplu çok-soru (Claude'un tab'lı çok-soru akışı) → Faz 3.1.
- Free-text "Other" cevap satırı → Faz 3.1.
- Codex sağlayıcısı prompt'ları → ileride (model agnostik yazılır, UI/uçtan-uca Claude).
- "Allow and don't ask again" gibi üçüncü izin seçeneği → Faz 3.1 (Faz 3.0 Allow/Deny).
- Optimistic dismiss: cevaba basınca kart hemen kaybolmaz; **resolution broadcast'i
  beklenir** (yanıltıcı durum olmasın; Faz 2 Stop kararıyla tutarlı).

## 2. Mevcut zemin (yeniden kullanılan)

- **`AgentHookServer.events() -> AsyncStream<AgentHookEvent>`** (Faz 2 tap noktası).
  Bu spec olayı `toolInput` ile zenginleştirir.
- **`AgentHookEvent`** (LumiKit): `kind` (preToolUse/permissionRequest/postToolUse/…),
  `toolName`, `isUserQuestionTool`, `agentID`. `toolInput` **eklenecek**.
- **`~/.lumi/hooks` script'leri + `AgentHookInstaller` + `AgentHookServer`** (karar 45):
  hook payload'ı POST eden loopback zinciri. `tool_input` **forward edilecek**.
- **RemoteService hook tap + `chat_status` yayını** (Faz 2): aynı desen `prompt`
  frame'i için kullanılır; `TurnStatusReducer` yanına `PromptJournal` eklenir.
- **`terminal.writeInput(_:to:)`** (Faz 2 Stop/Ctrl-C yolu): keystroke actuation.
- **Chat subscribe/snapshot deseni** (Faz 2): `prompt` de subscribe anında snapshot yollar.
- **Relay opak passthrough** (`chat`/`chat_status`): `prompt`/`prompt_respond` eklenir.

## 3. Mimari ve veri akışı

```
hook script (tool_input dahil) → AgentHookServer.events() ──┐
                                                             ├─► PromptJournal (session başına)
                                                             │      değişince
                                                             ▼
                                 RemoteService ── prompt frame (item+resolution) ──► relay ──► telefon
                                       ▲                                                          │
                                       │                                          AppModel.prompts[sid] (@Observable)
                                       │                                                          │
                                       │                                              MobileChatPromptCard (Allow/Deny/seçenek)
                                       │                                                          │ tap
                            keystroke (writeInput→PTY)  ◄── prompt_respond (itemId/rev/optionId) ◄┘
                                       │
                                       ▼ (host resolution=resolved, revision++)
                                 prompt frame (resolved) ──► relay ──► telefon (kart kaybolur)
```

## 4. Bileşenler

### 4.1 Hook `tool_input` genişletmesi

**Ölçüm çözüldü (orca kodundan):** Feasibility gate, gerçek Claude çalıştırıp ölçmek
yerine orca'nın kanıtlanmış kodundan karşılandı (keystroke haritası §4.4). Ayrıca
mevcut hook altyapımız keşfedildi:

- **`~/.lumi/hooks` script'leri: DEĞİŞİKLİK GEREKMEZ.** `AgentHookScript.posix` zaten hook
  JSON'unun **tamamını** (`--data-binary @-`) POST ediyor — `tool_input` gövdede zaten var.
- **`AgentHookInstaller`/`ClaudeHookSettings`: DEĞİŞİKLİK GEREKMEZ.** `PermissionRequest`
  (matcher `*`) ve `PreToolUse` (`*`) zaten kayıtlı (`ClaudeHookSettings.events`).
- **Tek değişiklik — decoder:** `AgentHookEvent.decode` (`LumiKit/Models/AgentHookModels.swift`,
  ~satır 153-176; `hook_event_name`/`tool_name`/`prompt` okuyan yer) `tool_input`'u okuyup
  (nesne → `JSONSerialization` ile string'e serialize) ve `tool_use_id`'yi çıkarır.
  Boyut tavanı: 16 KB — aşarsa `toolInput=nil` (kart gösterilmez, log'lanır; DoS koruması).
- **`AgentHookEvent`** (LumiKit): yeni alanlar (init'e additive; mevcut çağrı yerleri default'la derlenir)
  ```
  public let toolInput: String?   // PreToolUse/PermissionRequest ham tool_input JSON'u (yoksa nil)
  public let toolUseID: String?   // hook'tan tool_use id (itemId stabilitesi; yoksa nil)
  ```
- **Cihaz doğrulaması** (kullanıcı, launch-env): uçtan-uca gerçek Claude izin/soru senaryosu
  keystroke haritasını (§4.4) canlı teyit eder — ama haritanın kaynağı orca kodu, tahmin değil.

### 4.2 `ChatPrompt` modeli (LumiKit + LumiMobileKit kopyası)

orca alan adları birebir alınır (ileri parite additive olsun):

```
enum ChatPromptKind: String, Sendable { case approval, question }
enum ChatPromptState: String, Sendable { case pending, resolved, cancelled }

struct ChatPromptOption: Sendable, Equatable {
    var id: String
    var label: String
    var description: String?
}

struct ChatPrompt: Sendable, Equatable {
    var itemId: String            // tool_use id varsa o; yoksa "<terminalID>-<seq>"
    var revision: Int             // create=0; her durum değişiminde +1
    var kind: ChatPromptKind
    var title: String             // approval: "Bash çalıştırılsın mı?"; question: soru metni
    var detail: String?           // approval: özet (ör. komut); question: nil
    var options: [ChatPromptOption]
    var state: ChatPromptState    // pending → resolved/cancelled
    var selectedOptionId: String? // resolved ise seçilen
}
```

Değişmez wire modeli (Faz 1/2 kalıbı): LumiKit'te tanımlanır, LumiMobileKit'e birebir kopyalanır.
`toDict()` (encode) LumiKit'te, `decode` LumiMobileKit'te.

### 4.3 `PromptJournal` (LumiKit) + RemoteService entegrasyonu

**`PromptJournal`** (LumiKit, saf, test-edilebilir): session başına bir örnek.
`AgentHookEvent`'i katlar, pending prompt item'larını tutar.

| Event | Etki |
|---|---|
| `preToolUse` + `isUserQuestionTool` (isLead) + `toolInput` parse'lanır | question item ekle/güncelle (pending) |
| `permissionRequest` (isLead) + `toolInput`/`toolName` | approval item ekle (pending); options = §4.4 ölçümüne göre Allow/Deny |
| `postToolUse`/`postToolUseFailure` (ilgili tool) | eşleşen item'ı **cancelled** (out-of-band cevaplandı/tamamlandı) |
| `stop`/`stopFailure` | tüm pending item'ları **cancelled** |
| `sessionStart(source=clear)` | journal'ı sıfırla |
| diğer | değişiklik yok |

Çıktı: değişen item'lar (idempotent — aynı item aynı revision'la tekrar yayılmaz).
`toolInput` JSON parse'ı: `AskUserQuestion` için `{questions:[{question, options:[{label,description?}]}]}`
→ ilk soruyu (Faz 3.0 tek-soru) `ChatPrompt.question`'a map et; `options[i].id = "opt-\(i)"`.

**RemoteService** (LumiRemote, Faz 2 hook tap'ının yanına):
- Session başına `PromptJournal`; `handleHookEvent`'te (Faz 2) hem `TurnStatusReducer`
  hem `PromptJournal` ilerletilir. Değişen prompt item'ı ve session chat modunda abone
  ise `prompt` frame'i yollanır.
- **Chat subscribe anında** mevcut pending item'lar snapshot olarak yollanır (reconnect).
- **`prompt_respond` işleme** (telefon→host): `{sessionId, itemId, expectedRevision, optionId}`.
  - `expectedRevision` eşleşmiyorsa (bayat) → yok say (idempotent; kart zaten resolved).
  - optionId → keystroke (§4.4) → `terminal.writeInput(keys, to: id)`.
  - item'ı `resolved` (selectedOptionId=optionId, revision+1) yap → `prompt` frame yayınla.
- `.exited`/unsubscribe/shutdown'da journal temizlenir (Faz 2 cleanup yanında).

### 4.4 Cevap actuation — optionId → keystroke (orca kodundan, kesin)

orca'nın kanıtlanmış değerleri (deterministik, Faz 3.0 için TEK bayt yazımı):

- **Approval**: `allow` → `Data([0x31])` (`"1"`); `deny` → `Data([0x1b])` (ESC). **Trailing Enter YOK.**
- **Question (tek-soru tek-seçim)**: index `i` seçilince → `Data(String(i+1).utf8)` (ASCII
  `"1"`..`"9"`, yani `0x31`..`0x39`). **Trailing Enter YOK** (tek-soruda digit hem seçer hem gönderir).
- Tek keystroke; `terminal.writeInput(bytes, to: id)` ile yazılır (Faz 2 kanalı). Arrow/pacing
  YOK (onlar yalnız ertelenen multiSelect/gruplu çok-soru için gerekir — orca `buildAskAnswerKeys`).
- **Kaynak:** orca `native-chat-interactive-prompt.ts` (allow=`'1'`, deny=ESC) + `native-chat-ask.ts`
  `buildAskAnswerKeys` (tek-select index → `String(i+1)`, trailing Enter yalnız çok-soru finalinde).

### 4.5 Wire — `prompt` ve `prompt_respond` frame'leri

- **`prompt`** (host→telefon): payload `ChatPrompt.toDict()` + `sessionId`. Opak passthrough
  (relay `chat_status` gibi broadcast). Snapshot + her değişimde.
- **`prompt_respond`** (telefon→host): payload `{sessionId, itemId, expectedRevision, optionId}`.
  Relay `input`/`command` gibi telefon→mac forward eder (fromPhone).
- **`RemoteProtocol`** (encode `promptPayload`, decode `prompt_respond`),
  **`PhoneProtocol`** (decode `prompt`, encode `prompt_respond`).
- **Relay** (`RelayServer/src/{protocol,bridge}.ts`): `KNOWN_TYPES`'a `prompt` +
  `prompt_respond`; `fromMac`'e `prompt` broadcast; `fromPhone`'a `prompt_respond` forward.
  Oda izolasyonu mevcut desenle korunur.

> Not (transport basitliği): orca-mobile awaited-RPC (`respondToApproval` → accepted)
> kullanır. Biz **fire-and-forget `prompt_respond` + resolution broadcast** (observational)
> kullanırız — relay'imiz zaten broadcast; telefon resolution'ı `prompt` güncellemesinden
> öğrenir. Journal'ın sağlamlığı (revision + resolution state) korunur; awaited-response
> nüansı YAGNI olarak dışarıda.

### 4.6 Telefon — AppModel + UI

- **`AppModel`**: `private(set) var prompts: [String: [ChatPrompt]]` (session başına pending
  item listesi). `prompt` mesajı → item merge (itemId ile; resolved/cancelled ise listeden
  düş). Ölü aktif oturumda temizlenir (Faz 2 `turnStatus` paraleli).
- **`ChatPrompt` decode** LumiMobileKit'e eklenir.
- **`prompt_respond` gönderimi**: `AppModel.respondPrompt(sessionId, itemId, revision, optionId)`
  → `client.send(PhoneProtocol.promptRespondFrame(...))`.
- **`MobileChatPromptCard`** (SwiftUI, `LumiMobile/App`): composer'ın hemen üstünde, en son
  pending item'ı çizer:
  - approval: ShieldQuestion ikonu + title + detail + Allow(mavi)/Deny butonları.
  - question: soru metni + seçenek satırları (numara rozeti + label + description); tek-seçim
    → tap'te hemen gönder.
  - tap → `respondPrompt`; "gönderiliyor" (disable) → resolution broadcast'i gelince kaybolur.
  - LumiMobile literalleri (Faz 4 token kapsam dışı; mevcut mobil kalıp).
- Turn-status bandıyla (Faz 2) birlikte yaşar; kart bandın üstünde/altında ayrı satır.

## 5. Hata / kenar durumlar

- **Çift-cevap / yarış**: `expectedRevision` uyuşmazsa host yok sayar. Telefon tap sonrası
  disable eder; resolution broadcast gelmezse (host düştü) bir sonraki snapshot düzeltir.
- **Bayat pending** (claude çöktü, post/stop gelmedi): `stop` tüm pending'i cancelled yapar;
  reconnect snapshot'ı düzeltir. İlk sürümde ek timeout YOK (YAGNI).
- **Out-of-band cevap** (kullanıcı Mac'te cevapladı): `postToolUse` item'ı cancelled yapar →
  telefonda kart kaybolur.
- **`/clear`**: `sessionStart(source=clear)` journal'ı sıfırlar.
- **Reconnect (chat modda)**: subscribe pending snapshot'ı yeniden yollar.
- **Çoklu session**: journal session başına izole; `prompt` yalnız ilgili chat abonesine.
- **`tool_input` parse edilemezse / boşsa**: item oluşturulmaz (kart gösterilmez), log'lanır.
- **`toolInput` boyut tavanı aşılırsa** (§4.1): item oluşturulmaz.

## 6. Test stratejisi

- **`PromptJournal` birim** (LumiKitTests): event dizileri (preTool+AskUserQuestion→question
  item; permissionRequest→approval item; postTool→cancelled; stop→hepsi cancelled; clear→reset;
  idempotent; revision artışı; tool_input parse edge'leri). Enjekte deterministik id/seq.
- **`AgentHookEvent.decode` toolInput/toolUseID** (LumiKitTests): hook JSON'unda `tool_input`
  nesnesi → string; `tool_use_id` → toolUseID; 16 KB tavan aşımında nil; mevcut alanlar korunur.
- **RemoteService** (LumiRemoteTests): fake hook stream (toolInput'lu) + chat abonesi →
  `prompt` frame yayılır; abonesi olmayan session'a yayılmaz; subscribe'da snapshot; `prompt_respond`
  → `writeInput` çağrılır (FakeTerminalServicing.writtenInput doğrulanır) + resolved frame yayılır;
  bayat revision yok sayılır.
- **AppModel** (LumiMobileKitTests): `prompt` decode + merge (pending ekle, resolved düş);
  ölü oturum temizliği; `promptRespondFrame` encode.
- **Wire** (RelayServer): `prompt` mac→phone passthrough; `prompt_respond` phone→mac forward;
  oda izolasyonu.
- **Keystroke actuation + kart** = cihaz doğrulaması (§4.4 kırılgan; gerçek Claude izin/soru).

## 7. Bilinçli sadelik (YAGNI)

- multiSelect / gruplu çok-soru / free-text YOK (Faz 3.1).
- awaited-RPC YOK (fire-and-forget respond + resolution broadcast).
- Terminal scraping YOK (hook-first, orca paritesi).
- Timeout/heartbeat YOK (stop + reconnect snapshot düzeltir).
- Optimistic dismiss YOK (resolution beklenir).
- Codex uçtan-uca YOK.

## 8. Dosya envanteri (tahmini)

| Katman | Dosya | İş |
|---|---|---|
| Hook decoder | `LumiKit/Models/AgentHookModels.swift` (~153-176) | AgentHookEvent.toolInput/toolUseID (tool_input JSON→string) — hook script/installer DEĞİŞMEZ |
| Model | `LumiKit/Models/ChatPrompt.swift` (+ LumiMobileKit kopyası) | wire modeli |
| Journal | `LumiKit/NativeChat/PromptJournal.swift` | hook→prompt item'ları |
| Servis | `LumiRemote/RemoteService.swift` | journal tap + prompt yayını + prompt_respond + keystroke |
| Protokol | `LumiRemote/RemoteProtocol.swift`, `LumiMobileKit/PhoneProtocol.swift` | prompt/prompt_respond |
| Relay | `RelayServer/src/{protocol,bridge}.ts` | passthrough + forward |
| Telefon model | `LumiMobileKit/AppModel.swift` | prompts merge + respondPrompt |
| Telefon UI | `LumiMobile/App/MobileChatPromptCard.swift` (+ MobileChatView insert) | kart + tap |
| Test | yukarıdaki hedefler | birim + wire |

> Not: `PromptJournal` ve `ChatPrompt` **LumiKit**'e konur (Faz 2 `TurnStatusReducer` gibi) —
> LumiRemote yalnız LumiKit'e bağlı olduğundan (Package.swift).

## 9. Build / doğrulama

```bash
cd LumiPackages && swift test --scratch-path /tmp/lumi \
  --filter "PromptJournal|RemoteService|AgentHook"
cd LumiMobile/LumiMobileKit && swift test
cd RelayServer && npm test
# iOS: xcodegen generate (yeni App/ dosyası) → xcodebuild
# Mac + relay deploy + cihaz testi: KULLANICI (launch-env kuralı; relay lumi-relay servisi)
```

**Sıralama:** §4.1 feasibility gate orca kodundan çözüldü (keystroke haritası §4.4 kesin,
hook plumbing değişiklik gerektirmiyor). Doğal sıra: decoder (tool_input) → ChatPrompt modeli →
PromptJournal → RemoteService (journal+prompt+respond+keystroke) → relay → telefon decode/model →
UI. Nihai keystroke doğruluğu cihaz testinde (kullanıcı) teyit edilir.

**Launch-env kuralı:** LumiRework'ü Claude Code bash'ından başlatma; KULLANICI Finder/Dock'tan
temiz env'de başlatır (aksi halde CLAUDECODE env'i spawn edilen claude'lara sızar).
