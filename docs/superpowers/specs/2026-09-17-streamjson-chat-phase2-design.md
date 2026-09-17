# Yol B / Faz 2 — Telefon Native Chat (stream-json) — Tasarım

Tarih: 2026-09-17 · Branch: `feat/remote-orca-main` · Durum: kullanıcı onayladı

## Bağlam

Faz 1 (tamam) Mac'te stream-json chat veri çekirdeğini kurdu: `StreamJsonAgentSession` `claude`'u stream-json child olarak çalıştırıp çıktısını `ChatJournalState`'e (mevcut `ChatMessage`/`ChatBlock` + canlı `streamingText` + `turnActive`) katlıyor ve `snapshots()` yayıyor. UI yoktu. Faz 2 bunu telefona getirir — kullanıcının asıl istediği görünür sonuç: canlı token-token akış + AskUserQuestion sorusundan ÖNCEKİ metnin cevaptan önce görünmesi + temiz orca satırları.

**Karar 1 (kullanıcı):** Telefonda "chat" artık **stream-json chat oturumu** demek. Eski transcript-tail chat modu + terminal şeridi (önceki milestone) **sökülür**. Terminal oturumları sadece terminal-mirror kalır. Orca lane modeli.

**Karar 2 (kullanıcı):** Faz 2 = başlatma + metin gönder + canlı görüntüleme + orca satır/kart görüntüleme + söküm. Soru/izin **cevaplama** (stream-json tool_result / control_request protokolü) **Faz 2b**'ye ertelendi.

**Avantaj:** Telefon zaten `chat`/`chat_append`/`chat_status`/`prompt` frame'lerini render eden bir `MobileChatView`'a sahip. Faz 2 çoğunlukla veri kaynağını transcript-tail'den Faz 1 journal'ına çevirir + canlı streaming katmanı ekler + şeridi söker — sıfırdan UI değil.

## Bileşenler

### A. Mac — `ChatSessionService` (Faz 1'de ertelenen çok-oturum yöneticisi)
`ChatSessionServicing` protokolü (LumiKit) + canlı impl (LumiServices): `create(repoPath:) -> ChatSessionMeta` (yeni UUID session-id + `StreamJsonAgentSession(...).start()`), `list() -> [ChatSessionMeta]`, `close(id:)`, `session(id:) -> StreamJsonAgentSession?`, `send(id:text:)`. Env `TerminalEnvironment` hijyeniyle (mevcut). DI: `ServiceRegistry`'ye `chatSessions` slotu; Live/Fake kayıt. Chat oturumları in-memory; geçmiş claude transcript'inde kalıcı.

### B. Mac — `RemoteService` chat köprüsü
- **Başlatma:** `start_session` payload'ına opsiyonel `kind` eklenir; `kind == "chat"` → `ChatSessionService.create(repoPath:)`; `prompt` boş değilse `send(id:prompt)`; `commandResult`'ta `sessionId` döner. `kind` yoksa bugünkü terminal spawn (geriye uyumlu).
- **Yayın:** chat oturumları `sessions` broadcast'ine `kind: "chat"` ile eklenir (telefon listede ayırt etsin).
- **Köprü (diff):** chat-oturumu `subscribe(mode=chat)` → `session.snapshots()`'a abone; oturum başına son-yayınlanan durum tutulur; her snapshot'ta **diff**: yeni/değişen mesajlar → `chat`(ilk)/`chat_append`; `streamingText`/`turnActive`/tool değişimi → `chat_status`. Token başına tam-journal-serialize YOK (Faz 1 final review notu). Unsubscribe/stop → abonelik iptali.
- **Girdi:** yeni `chat_send` **frame'i** (`sessionId` + `text`; input/submitText gibi fire-and-forget, commandResult beklemez) → `ChatSessionService.send(id:text:)`. (Chat oturumunun PTY'si yok → `input` keystroke frame'i uygulanmaz.)

### C. Wire (additive; yeni frame tipi yok, relay değişmez)
- `ChatTurnStatus`'a additive `streamingText: String?` alanı (encode `RemoteProtocol.chatStatusPayload` + decode `ChatTurnStatus.decode` Mac & iOS).
- `SessionMeta`'ya additive `kind: String?` (`"chat"`/nil=terminal).
- `PhoneProtocol`'a `chatSendFrame(sessionId:text:)` + `RemoteProtocol` decode.

### D. iOS — `AppModel` + oturum başlatma
- Chat oturumu başlatma: `NewSessionView` `kind: "chat"` ile `start_session` yollar; dönen `sessionId`'yi açar.
- `streamingText` `chat_status`'tan okunur → `AppModel.turnStatus[sessionId].streamingText` (mevcut turnStatus kanalı).
- Chat girdisi: `submitText` chat oturumu için `chat_send` yollar (PTY input değil). Oturum-türü `SessionMeta.kind`'dan.
- Söküm sonrası: transcript-tail chat abonelik yolu (mode=chat feed) kaldırılır; chat frame işleme kalır (kaynak artık journal köprüsü).

### E. iOS — `MobileChatView`
- `streamingText` canlı prose öğesi olarak çizilir (streaming gate, saf kural: `turnActive && streamingText` doluysa ve son assistant mesajını "geçiyorsa" göster; snapshot yerleşince düşer — orca `deriveNativeChatStreamingText` paritesi).
- **`ChatLiveTerminalStrip` kaldırılır** (görünürlük çağrısı, view, `ChatLiveStrip.swift` kuralı, `hasFeed`/`gridRows`/feed rotası dahil — Task 2/3 stripleri geri alınır).
- Orca mesaj satırları (balonsuz assistant) + Ask kartı görüntüleme zaten mevcut (önceki iş); korunur. Ask kartının cevap butonları Faz 2'de **görünür ama pasif/bilgilendirici** (cevaplama Faz 2b).

### F. Söküm (retire)
- `ChatLiveTerminalStrip.swift` + `ChatLiveStrip.swift` + `MobileChatView` entegrasyonu + `AppModel` `feedSeen`/`gridRows`/feed rotası (önceki milestone Task 2/3).
- Mac: `RemoteService`'in terminal-oturumları için transcript-tail chat kaynağı + `mode=chat` feed emisyonu (`startFeedEmission` chat kolundan) geri alınır. Terminal oturumları = mirror.
- `TranscriptChatSource`/`TranscriptLocator` chat için artık kullanılmaz (kod kalabilir, çağrı kesilir) — ölü kod temizliği plana dahil.

## Veri akışı

```
telefon "yeni chat" ─start_session{kind:chat,prompt}→ Mac ChatSessionService.create
                                                           → StreamJsonAgentSession.start + send(prompt)
telefon subscribe(mode=chat) → RemoteService köprü ─abone→ session.snapshots()
                                     │ diff
        chat/chat_append (mesajlar) + chat_status(streamingText,turnActive)  → telefon MobileChatView
telefon yazar ─chat_send→ ChatSessionService.send → StreamJsonAgentSession.send → child stdin
```

## Hata durumları
- Chat child exit/çöker → journal turnActive=false → `chat_status(working:false)`; oturum `.ended` → sessions broadcast'ten düşer.
- Mac çevrimdışı → mevcut banner.
- **AskUserQuestion (bilinen Faz 2 sınırı):** görünür (kart/blok) ama cevaplanamaz; chat oturumunun terminali olmadığından o oturum Faz 2b'ye kadar bekler. Sorusuz sohbetler tam çalışır. Kart cevaptan yoksun olduğu belli edilir.
- Diff köprüsü: mesaj id ile eşlenir (journal upsert id'siyle tutarlı); streamingText yalnız değişince yayılır.

## Test stratejisi
- Mac (`LumiRemoteTests`): chat köprüsü diff — Fake ChatSessionService/journal snapshot dizisi → beklenen `chat`/`chat_append`/`chat_status(streamingText)` frame'leri; `start_session kind=chat` chat oturumu yaratır + prompt gönderir; `chat_send` → session.send çağrısı; terminal `start_session` (kind yok) regresyonu.
- Wire round-trip: `ChatTurnStatus.streamingText` + `SessionMeta.kind` Mac-encode → iOS-decode (mevcut `WireRoundTripTests` kalıbı).
- iOS Kit (`LumiMobileKitTests`): streaming gate görünürlük kuralı (saf); `chat_send` frame; chat_status streamingText decode → turnStatus; oturum-türü.
- iOS App: söküm sonrası build; streaming prose + Ask kartı görsel cihaz doğrulaması.
- Sweep + cihaz kurulumu (bu faz GÖRÜNÜR — gerçek build).

## Kapsam dışı
- Soru/izin **cevaplama** (Faz 2b): AskUserQuestion tool_result + Bash-izni control_request protokolü.
- Mac desktop chat view (Faz 3).
- resume/geçmiş transcript seed, interrupt, subagent, model seçimi, attachment (Faz 4).
- Relay değişmez.
