# Orca Chat Yaşam Döngüsü — Bug'sız Parite (Design)

**Tarih:** 2026-09-16
**Dal:** `feat/remote-orca-main`
**Kapsam:** Telefondan orca'nın çekirdek ajan yaşam döngüsünü bug'sız klonlamak — (1) ajan başlatma, (2) sohbete devam, (3) var olan chat'i açma. İki somut gereksinim: prompt kartları çalışsın; mesajlar **tamamlandığında** gelsin, token token değil.

---

## 1. Kök bulgu (kanıtlı)

Lumi'nin native chat mimarisi orca ile neredeyse aynıdır: her iki taraf da transcript JSONL'den **tamamlanmış mesaj** teslim eder.

- **Orca:** `src/main/native-chat/transcript-watch-engine.ts` JSONL'i izler → `nativeChat.subscribe` `snapshot`/`appended`/`replacement` frame'leri (merge-by-id). Streaming "yazıyor" balonu efemer hook önizlemesidir, transcript'in parçası değildir.
- **Lumi:** `LumiServices/NativeChat/TranscriptChatSource.swift` `~/.claude/projects/<encoded>/<claudeSessionID>.jsonl`'i 500 ms poll eder, **yalnız tam satır** okur (`readAppended` son newline'da durur) → `ChatMirrorEvent.snapshot`/`.append`.

Yani "token token gelme" native chat'in davranışı **değildir**. Token akışı yalnız **tek** yerde olur: **terminal-mode fallback.**

**Smoking gun:** `LumiPackages/Sources/LumiRemote/RemoteService.swift:248-262` — `handleSubscribe`, `mode=chat` isteğinde oturumun `claudeSessionID`'sini çözemezse sessizce ham PTY terminal moduna düşer (`rlog "chat subscribe DÜŞTÜ→terminal"`, satır 251). O anda telefon tamamlanmış chat mesajı yerine **ham byte akışı** görür → "token token" budur. Aynı düşüşte **prompt kartları da gelmez** (chat frame yolu hiç kurulmaz).

**`claudeSessionID` kaynağı:** `LumiTerminal/Session/TerminalSessionManager.swift:89` — Lumi bir oturum spawn ederken `prepared.sessionID`'yi enjekte edip `TerminalMeta.claudeSessionID`'ye yazar. **Lumi-dışı** oturumlar (Rider/manuel/worktree) bu id'yi taşımaz → `nil` → fallback. Bu, `mobile-external-session-not-mirrored` bulgusuyla birebir örtüşür.

**Sonuç:** Üç yaşam döngüsü akışının da bug'ının ortak paydası tektir — **chat modu her zaman transcript'e bağlanmalı; asla ham-PTY'ye düşmemeli.**

İkincil yapısal sorun: iOS `LumiMobileKit` bağımsız bir SPM paketidir ve `ChatPrompt.swift`, `ChatTurnStatus.swift`, `DiagLog.swift` dosyaları kod yorumlarında bile "LumiKit'in telefon kopyası" der. Her wire değişikliği iki tarafta elle senkronlanır → sürekli kayma (drift). `MobileChatPromptCard.swift:31` gruplu çok-soruyu placeholder ile geçer.

---

## 2. Mimari (orca ↔ Lumi eşlemesi)

| Konu | Orca | Lumi (bugün) | Aksiyon |
| --- | --- | --- | --- |
| Mesaj granülaritesi | Transcript, tamamlanmış, merge-by-id | Transcript poll, tamamlanmış, merge-by-id | Zaten doğru — chat modunda kalınca |
| Session→transcript bağı | Session hep transcript'e bağlı | `claudeSessionID` yoksa **PTY fallback** | **Bileşen A + B** |
| Var olan chat'i aç | `session.tabs.subscribe` → seç → `nativeChat.subscribe` | `sessions` frame → tap → `subscribeChat` | B: dış oturum keşfi |
| Ajan başlat | `agentSession.create(worktree, agent)` | `start_session(repoPath, prompt)` → `claude …` spawn | B: baştan bağla |
| Prompt kartları | shared parse, snapshot teslim | kopyalı tip + gruplu placeholder | **Bileşen C + D** |
| Wire tipleri | tek `/src/shared` | Mac/iOS kopya | **Bileşen C** |

---

## 3. Bileşenler

### Bileşen A — Chat modu asla ham-PTY'ye düşmesin *(birincil "token token" fix)*

`RemoteService.handleSubscribe`, `mode=chat`'te terminal fallback dalını (satır 250-262) **kaldırır**. `claudeSessionID` çözülemezse:
- Terminal moduna **düşmez**, ham PTY stream'i kurmaz.
- Chat modunda kalır: boş bir `chat` snapshot'ı + "transcript hazırlanıyor / bulunamadı" durumu yayınlar (yeni bir `chat_status` alanı veya boş mesaj listesi + açık bir `chatUnavailable` bayrağı).
- Bileşen B transcript'i çözene kadar chat aboneliği bekler/poll eder; transcript belirince normal `chat`/`chat_append` akışı başlar.

**Değişmez garanti:** Ham PTY byte'ları hiçbir koşulda chat frame'i olarak telefona gitmez.

**Dosyalar:** `LumiRemote/RemoteService.swift` (handleSubscribe).

### Bileşen B — Session→transcript bağını sağlamlaştır *(start + open-existing)*

1. **Başlatma:** telefondan `start_session` ile spawn edilen ajan zaten `prepared.sessionID` → `claudeSessionID` taşır (mevcut). Doğrula: spawn edilen komut gerçekten `--session-id` enjekte ediyor ve meta'ya yazılıyor; testle kilitle. Böylece başlatınca chat modu anında çalışır.
2. **Var olan (Lumi-dışı) oturum:** `claudeSessionID` `nil` olan bir oturum chat'e abone olunca, `repoPath` → `~/.claude/projects/<encoded>/` altındaki **en yeni `.jsonl`**'i keşfet-eşleştir (mtime), ve o oturumun transcript'i olarak bağla (mümkünse `TerminalMeta`'ya geri yaz). Eşleşme bulunamazsa Bileşen A'nın "chat yok" durumu gösterilir — sessiz token düşüşü asla.
   - Keşif saf ve test edilebilir olmalı: yeni `TranscriptLocator` (LumiServices) — `(repoPath) -> claudeSessionID?`, enjekte edilebilir dosya sistemi ile.
3. **Liste doğruluğu:** `sendSessions` / `SessionMeta` (RemoteProtocol) chat'i çözülebilen oturumları işaretler (opsiyonel `hasChat` alanı) ki telefon UI gerekirse net rozet gösterebilsin.

**Dosyalar:** `LumiRemote/RemoteService.swift`, yeni `LumiServices/NativeChat/TranscriptLocator.swift`, `LumiRemote/RemoteProtocol.swift` (SessionMeta), `LumiTerminal/Session/TerminalSessionManager.swift` (doğrulama).

### Bileşen C — Tek kaynak wire katmanı `LumiWire` *(= orca `/src/shared`)*

LumiKit iOS-temiz **değildir** (`TerminalGridFit`/`SyntaxHighlighting`/`TerminalServicing` AppKit import eder), bu yüzden iOS doğrudan LumiKit'e bağlanamaz. Çözüm: saf-Foundation ayrı target.

- Yeni target `LumiPackages/Sources/LumiWire` (yalnız `import Foundation`). İçerik, bugün zaten saf olan tipler + mantık **taşınır**:
  - `ChatMessage` / `ChatBlock` / `ChatRole` (wire modeli)
  - `ChatPrompt` (+ Option/Question/Kind/State)
  - `ChatTurnStatus`
  - `PromptJournal` (saf reducer)
  - `AskAnswerKeys` (`buildAskAnswerKeys` + `AskQuestionInput`)
  - `DiagLog`
- **Encode/decode simetrisi tek yerde:** her wire tipi kendi `wirePayload() -> [String: Any]` (encode) ve `decode(_:) -> Self?` (decode) fonksiyonunu `LumiWire`'da tutar. Mac `RemoteProtocol.promptPayload`/`chatPayload` bu `wirePayload()`'ları çağırır; iOS aynı `decode`'u çağırır. Anahtar sapması imkânsız.
- **Mac:** `LumiKit` `LumiWire`'a bağımlı olur ve `@_exported import LumiWire` yapar → mevcut Mac kodu değişmeden derlenir (churn minimum). LumiState/LumiServices/LumiRemote dolaylı erişir.
- **iOS:** `LumiMobile/LumiMobileKit/Package.swift`, `.package(path: "../../LumiPackages")` ekler ve `LumiWire` product'ına bağlanır. iOS kopya dosyaları (`ChatPrompt.swift`, `ChatTurnStatus.swift`, `DiagLog.swift`, ve varsa `ChatMessage` kopyası) **silinir**, `import LumiWire` olur. `platforms` `.macOS(.v14)` korunur (LumiWire saf olduğundan simülatörsüz test host çalışmaya devam eder).

**Regresyon kilidi:** LumiWire test target'ında her tip için `encode → decode == kimlik` round-trip testi; hem Mac hem iOS suite'i aynı target'ı derlediği için tek testle iki taraf korunur.

### Bileşen D — Gruplu prompt kartını bitir *(AskUserQuestion)*

`MobileChatPromptCard.swift` `questions.count > 1` dalındaki placeholder (satır 31-33) gerçek UI ile değiştirilir:
- Her `ChatPromptQuestion` için: başlık (`header`/`question`) + seçenekler (tek-seçim tap / multiSelect toggle) + `allowOther` free-text satırı.
- Tek "Gönder" tüm soruların cevabını `[(indices: [Int], other: String?)]` listesi (soru sırasıyla) olarak `onQuestion`'a verir — `onQuestion` bu şekli zaten alıyor (bugün yalnız tek-soru için kullanılıyor).
- Mac tarafı **hazır**: `RemoteService.handleQuestionRespond` + `askInputs(gruplu dal)` + `buildAskAnswerKeys` çok-soruyu destekler. Değişiklik yalnız iOS UI + `respondPromptSelections` çok-soru selection dizisini doğru sırada gönderir.

**Dosyalar:** `LumiMobile/App/MobileChatPromptCard.swift`, `LumiMobileKit/AppModel.swift` (respondPromptSelections).

### Bileşen E — Regresyon kilidi + deploy doğrulama

- **Testler:** (a) LumiWire wire round-trip; (b) "chat modu `claudeSessionID` yokken PTY'ye düşmez" (RemoteService); (c) TranscriptLocator dış-oturum keşfi; (d) gruplu prompt cevap sırası; (e) reconnect chat-mode korunur (mevcut `testResubscribesInChatModeOnReconnect...` yeşil kalır).
- **Deploy doğrulama (manuel, proje kuralı):** `swift build`/`swift test` (LumiPackages + LumiMobileKit) yeşil; RelayServer redeploy; iOS cihaza install; Mac app rebuild; cihazda `chat subscribe DÜŞTÜ→terminal` satırının **artık görünmediğini** ve prompt kartlarının çıktığını diag logla teyit. (Bayat build = tekrar-eden-hatanın gizli yarısı — `lumi-build-and-remote-findings`, `mobile-transcript-tracking-diagnosis`.)

---

## 4. İlk implementasyon adımı — teşhis teyidi

Kod yazmadan önce kod seviyesinde doğrula (kanıtla, varsayma):
- `handleSubscribe` fallback dalının gerçekten dış/taze oturumlarda tetiklendiğini (claudeSessionID nil) göster.
- Mümkünse kullanıcı cihaz/Mac logunda (`~/.lumi/logs/mac.log`) `chat subscribe DÜŞTÜ→terminal` satırını ve açılan oturumların `claudeSessionID`'sini teyit etsin.
Teyit "token token = fallback" hipotezini kesinleştirir; aksi çıkarsa Bileşen A yerine gerçek granülarite yeniden incelenir.

---

## 5. Kapsam dışı (bilinçli)

- Codex prompt/agent sağlayıcı — Faz 5'e ertelendi.
- Relay/transport protokolü değişmez (tek Lumi kuralı: kendi relay'i).
- E2EE / orca RPC / React Native mobil — port edilmez.
- Streaming "yazıyor" balonu (orca'daki efemer önizleme) — gereksinim "tamamlanınca gelsin" olduğu için bilinçli olarak eklenmez.

---

## 6. Riskler

- **LumiWire çıkarımı** iki SPM paketini birbirine path-bağımlı yapar; iOS Xcode projesinin (XcodeGen) yeni bağımlılığı görmesi gerekir (`ios-xcodeproj-is-generated` — `xcodegen generate` şart, bayat proje build kırar).
- **Dış-oturum transcript keşfi** heuristiktir (en yeni jsonl); yanlış eşleşme riskine karşı repo+mtime penceresi + `TranscriptClaimRegistry` teklik sahipliği (`multi-session-transcript-crosstalk-fix`) korunur.
- **On-device doğrulama** bu makineden otomatik yapılamaz; kod+test yeşil teslim edilir, cihaz/relay deploy kullanıcıda kalır (proje kuralı).
