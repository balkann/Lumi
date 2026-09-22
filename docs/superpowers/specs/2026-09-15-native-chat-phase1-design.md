# Native Chat — Faz 1 Tasarımı (transcript-tail chat)

**Tarih:** 2026-09-15
**Branch:** `feat/remote-orca-main` (main'e commit yok; ayrı branch'te kalır)
**Hedef:** Telefonda ham terminal-mirror yerine, orca'nın `native-chat` görünümünün **birebir aynısı** olan native bir chat arayüzü. Bu Faz 1, o hedefin tabanını kurar; Faz 2-5 (streaming, ask/permission kartları, composer paritesi, çoklu-kaynak merge + subagent + Codex) ayrı spec→plan→implementasyon döngülerinde gelir.

**Neden:** Mac terminali 120 kolon (`TerminalSession.initialCols = 120`); bu grid telefona sığmıyor → yatay scroll → okunamıyor. Ham terminal grid'i telefonda hem tam-genişlik hem okunur olamaz. Çözüm orca'nın yolu: transcript'i (JSONL) parse edip native, satır-saran chat mesajları göstermek.

## Referanslar

- **orca parite kaynağı (birebir hedef):**
  - Model: `orca/src/shared/native-chat-types.ts` (`NativeChatMessage`, `NativeChatBlock`)
  - Claude decoder: `orca/src/main/native-chat/transcript-line-decoders-claude.ts`, `transcript-record-blocks.ts`
  - Tail/watch: `orca/src/main/native-chat/transcript-watch.ts`, `transcript-reader.ts`, `transcript-stream-lines.ts`, `transcript-tail-boundary.ts`
  - Tool folding: `orca/src/shared/native-chat-tool-fold.ts`, `native-chat-tool-activity.ts`, `native-chat-tool-summary.ts`
  - Mobil UI: `orca/mobile/src/session/MobileNativeChatView.tsx`, `MobileNativeChatMessage`, `MobileNativeChatToolRun.tsx`, `mobile-native-chat-view-styles.ts`, `mobile/src/theme/mobile-theme.ts`
- **Lumi mevcut yapı taşları:**
  - `LumiServices/AgentHistory/AgentTranscriptParser.swift` (satır→turn; blok üretecek şekilde genişletilecek)
  - `LumiServices/AgentHistory/AgentDataRoots.swift` + `AgentHistoryService.swift` (transcript dizin/dosya çözümü)
  - `LumiKit/Models/TerminalModels.swift` → `TerminalMeta.claudeSessionID` (+ `repoPath`) = transcript dosyasına anahtar
  - `LumiRemote/RemoteService.swift` (subscribe/abonelik, relay send), `RelayServer` (broadcast)
  - `LumiMobile/App/KeyboardObserver.swift` (klavye-güvenli composer — bug #1'de eklendi)

## Kapsam (Faz 1)

**Var:**
- Chat veri modeli (orca `NativeChatMessage`/blocks birebir; Faz 1'de `text` + `tool-call`/`tool-result` render edilir).
- Mac: abone olunan oturumun Claude transcript JSONL'ini çöz + **canlı tail** et; snapshot + append olarak relay üzerinden yolla.
- Telefon: SwiftUI native chat listesi — markdown metin balonları + **katlanmış araç satırları** (tap → genişlet), turn disclosure, empty/loading state, working göstergesi, klavye-güvenli composer (serbest metin gönderimi mevcut input yoluyla). Terminal-mirror bir **toggle** olarak kalır (orca da her ikisini tutar).
- Görsel parite: orca `mobile-theme` + `mobile-native-chat-view-styles` referans alınır.

**Yok (sonraki fazlar):**
- Faz 2: canlı token streaming, per-turn "Working for N" durumu, canlı araç ilerlemesi, Stop/interrupt.
- Faz 3: ask/permission/question kartları (tappable seçenekler).
- Faz 4: görsel ekleme, diktasyon, @-dosya autocomplete, slash komut, model/session picker, optimistic echo, pagination, pinch-zoom.
- Faz 5: transcript>hook>scrape merge, subagent grupları, Codex decoder, reasoning blokları, edit-patch diff gutter.

Faz 1'de yalnız **Claude** sağlayıcısı hedeflenir (Codex Faz 5). Kaynak yalnız **transcript** (hook/scrape Faz 5).

## Mimari

Orca'nın katmanlarını Lumi stack'ine (Swift host + Swift/SwiftUI telefon) yansıtır. Üç ayrık birim:

### 1) Paylaşılan chat wire modeli
Wire JSON sözleşmesi + her iki tarafta Codable struct'lar (mevcut `SessionMeta` gibi Mac/telefon ikizlenir):

```
ChatMessage { id: String, role: "user"|"assistant"|"tool"|"reasoning"|"system",
              blocks: [ChatBlock], timestamp: Int? (epoch ms), turnId: String? }
ChatBlock =
  | { type: "text", text: String, presentation?: String }
  | { type: "tool-call", name: String, inputPreview: String, state?: "running"|"completed"|"failed" }
  | { type: "tool-result", output: String, isError?: Bool }
  | { type: "image-ref", path?: String, url?: String, alt?: String }   // Faz 1: decode+stub, render Faz 4
  | { type: "subagent-group", groupId: String, agents: [...] }         // Faz 1: decode+stub, render Faz 5
```
`source` alanı orca'da var ama Faz 1 tek-kaynak (transcript) olduğu için gönderilmez (Faz 5'te eklenir). Alanlar orca ile birebir adlandırılır ki ileri fazlar additive olsun.

### 2) Mac — transcript chat kaynağı (`LumiServices` + `LumiRemote`)
- **`TranscriptChatDecoder`** (yeni, LumiServices): bir JSONL satırını (`[String: Any]`) `ChatMessage?`'a çevirir. `AgentTranscriptParser`'ın blok-farkındalıklı genişletmesi: Claude kaydında `message.content` dizisini yürüyerek `text` / `tool_use` (→ tool-call) / `tool_result` (→ tool-result) bloklarını üretir. Parite: `transcript-line-decoders-claude.ts` + `transcript-record-blocks.ts`. Satır-başı tolerans (bozuk satır atlanır).
- **`TranscriptChatSource`** (yeni, LumiServices): `(claudeSessionID, repoPath)` → transcript dosya yolu (`AgentDataRoots`/`AgentHistoryService` yol mantığı). Mevcut satırları okur → `[ChatMessage]` (snapshot); sonra dosyayı **tail** eder (append edilen baytları offset'ten okuyup yeni satırları decode) ve yeni mesajları `AsyncStream<[ChatMessage]>` olarak yayar. Tail tetiği: `RepoServicing` FSEvents (aktif repo zaten izleniyor) veya hafif dosya-boyu polling; parite: `transcript-watch.ts`/`transcript-tail-boundary.ts`.
- **`RemoteService`**: `subscribe` frame'ine opsiyonel `mode: "chat"|"terminal"` eklenir (varsayılan Faz 1 telefonunda `chat`). `chat` modda: terminal scrollback/data yerine `TranscriptChatSource` başlatılır → `chat` (snapshot) sonra `chat_append` (yeni mesajlar) yollanır. Terminal mode mevcut davranış (toggle için korunur). Oturumun `claudeSessionID`'i yoksa (Lumi izlemiyor) boş snapshot + "chat kullanılamıyor" bayrağı.

### 3) Telefon — native chat UI (`LumiMobileKit` + `LumiMobile/App`)
- **`LumiMobileKit`**: `ChatMessage`/`ChatBlock` Codable + `PhoneProtocol` decode (`chat`, `chat_append`). `AppModel`: `chatMessages[sessionId]` durumu; `subscribe` `mode` taşır; append birleştirme (id/turnId ile dedup — orca `native-chat-merge` mantığının Faz 1 alt kümesi). Tool-folding saf fonksiyon (`native-chat-tool-fold` alt kümesi): tool-only mesajları önceki assistant turn'üne katlar.
- **`LumiMobile/App`**: `MobileChatView` (SwiftUI) — mesaj listesi (ScrollViewReader, alta yapış), `MobileChatMessageView` (rol'e göre balon; markdown metin), `MobileChatToolRunView` (katlanmış araç satırı, tap→genişlet→tool-result). Empty/loading state. Composer: klavye-güvenli (mevcut `KeyboardObserver`), serbest metin → `model.sendInput`/`send_text`. Toolbar'da chat↔terminal toggle. Görsel: orca `mobile-theme` renkleri + view-styles birebir.

## Veri akışı

```
telefon: subscribe(sessionId, mode=chat)
  → Mac RemoteService: TranscriptChatSource(claudeSessionID, repoPath)
      → transcript oku+decode → chat{sessionId, messages}  (snapshot)
      → tail: yeni satır → chat_append{sessionId, messages}
  → relay broadcast → telefon AppModel: chatMessages[sessionId] = merge(...)
  → MobileChatView render (fold + markdown)

telefon: composer send(text)
  → mevcut input yolu (writeInput/send_text) → Mac PTY → claude → transcript büyür
  → tail → chat_append → telefonda kullanıcı+assistant balonları belirir
```

## Relay (RelayServer)
- `protocol.ts` `KNOWN_TYPES`'a `chat`, `chat_append` eklenir.
- `bridge.ts` `fromMac`: `chat`/`chat_append` → `broadcast(room, ...)` (sessions/data ile simetrik). Cache **gerekmez** (snapshot her subscribe'da Mac'ten taze gelir). `subscribe`/`input` zaten phone→mac geçiyor; `mode` alanı payload'da taşınır, relay dokunmaz (opak geçiş).

## Hata yönetimi
- Transcript henüz yok (claude yeni spawn, dosya oluşmadı): boş snapshot + telefon "yükleniyor/başlıyor" empty state; tail dosya belirince snapshot'ı doldurur.
- Bozuk/yarım JSONL satırı: o satır atlanır, akış kırılmaz (parite: tolerant decode).
- `/clear` → yeni session dosyası (karar 21 / clear-session-follow): Faz 1 `claudeSessionID` sabit dosyayı izler; `/clear` sonrası yeni dosya takibi **Faz 5** (çoklu-kaynak/lifecycle). Faz 1'de not düşülür.
- Abonelik değişimi/kapanış: tail task iptal (mevcut subscription iptal deseni ile simetrik).

## Test
- **LumiServices** (`TranscriptChatDecoderTests`, `TranscriptChatSourceTests`): Claude JSONL fixture'ları → beklenen bloklar (text/tool-call/tool-result); tail append tespiti (dosyaya yaz → yeni mesaj yayılır); bozuk satır toleransı.
- **RelayServer** (`bridge.test.ts`): `chat`/`chat_append` mac→phone broadcast; `mode` alanı subscribe'da opak geçer.
- **LumiMobileKit** (`ChatDecodeTests`, `AppModel` chat): wire decode; snapshot + append merge/dedup; tool-fold saf fonksiyon.
- **Faz 1 UI** (SwiftUI, cihaz): birim test yok — manuel; görsel parite orca ekran görüntüleriyle karşılaştırılır.

## Riskler / açık noktalar
- **Tail mekaniği:** FSEvents (RepoServicing) vs polling — implementasyon planında netleşir; polling en basit ve güvenli başlangıç.
- **Görsel "birebir":** orca RN stilleri → SwiftUI'ye çeviri; token/renk/spacing `mobile-theme`'den bire bir alınır ama piksel-parite manuel doğrulama ister.
- **claudeSessionID kapsamı:** yalnız Lumi'nin `--session-id` ile başlattığı claude oturumları chat destekler; dışarıdan/`-c` ile açılanlar terminal-mode'a düşer (Faz 1 sınırı, orca'da da session-file-resolver benzer sınıra sahip).
```
