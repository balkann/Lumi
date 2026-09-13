# Terminal-Ayna Remote — Tasarım Spec'i

**Tarih:** 2026-09-08
**Branch:** `feat/remote-terminal-mirror` (temiz `main` üzerine)
**Durum:** Onaylandı (brainstorming), implementasyon planı bekliyor

## 1. Amaç ve motivasyon

Lumi'nin mevcut mobil remote implementasyonu (`lumi-remote` branch'i) verimli çalışmıyor:
bağlantılar kopuyor, yanlış chat'ler sızıyor (crosstalk), ve Claude'un interaktif
soruları (`1. Yes / 2. No`, `y/n`, TUI'ler) mobil chat ekranında düzgün görünmüyor.

**Kök neden:** mevcut mimari "chat yeniden kurma" yaklaşımı — Mac, Claude Code'un
transcript JSONL dosyalarını parse eder ve ekran-buffer'ı scrape ederek prompt'ları
çıkarır; telefon bunu SwiftUI chat balonları olarak yeniden kurar. Bu yaklaşım
doğası gereği kırılgan: transcript sahiplik karmaşası (crosstalk), tur sınırı
sezgiselleri, ekran-scrape prompt tespiti hep bug üretir.

**Çözüm:** orca projesinin (`/Users/balkan/Desktop/side-projects/orca`) kanıtlanmış
**terminal-ayna** mimarisini native Swift'e port etmek. Ham PTY bayt akışını telefona
aynala, telefonda gerçek bir terminalde render et, tuş vuruşunu geri PTY'ye yaz.
Parse yok, scrape yok — telefonda terminalin birebir aynası. Claude'un soruları
terminalde nasıl görünüyorsa telefonda da aynen öyle görünür.

### Alınan kararlar (brainstorming)

1. **Port stratejisi:** Orca'nın *yaklaşımı* native Swift'e port edilir (orca'nın RN
   uygulaması fork'lanmaz). Lumi native SwiftUI app + pairing/relay kalır; çekirdek
   veri modeli chat-yeniden-kurmadan terminal-aynaya döner.
2. **iOS render:** SwiftTerm iOS (native `TerminalView`). WebView/xterm.js değil —
   SwiftTerm zaten Lumi bağımlılığı ve cross-platform; Mac ile telefon aynı emülatörü
   paylaşır, JS bridge yok.
3. **Mobil UX:** Terminal + aksesuar tuş çubuğu (ok tuşları, Esc, Tab, Enter, Ctrl-C +
   metin girişi). Oturum listesi ve model menüsü korunur.
4. **Branch tabanı:** Temiz `main`'den yeni branch. RelayServer + pairing/QR + push
   scaffold `lumi-remote`'tan seçmeli taşınır; çekirdek stream modeli sıfırdan kurulur.

## 2. Genel mimari

Üç bileşen, tek felsefe:

```
Mac (LumiRemote)                Relay (RelayServer, TS)     iOS (LumiMobile)
TerminalSession.pipeline  ─►    room = token                SwiftTerm TerminalView
  onFlushBatch (Data) ─stream─►   subscribe/data/input ─►    (byte feed → ekran)
PTYProcess.write  ◄─input──      resize/scrollback     ◄─    aksesuar tuşları + klavye
```

Lumi'de "session" = bir terminal (Claude instance başına `TerminalSession`), tek PTY.
Orca'nın çok-terminalli worktree modelinden daha basit: telefon aynı anda tek terminale
abone olur.

## 3. Mac tarafı — `LumiRemote` paketi

### Tap noktaları (main'de doğrulandı)
- `PTYProcess` — ham PTY baytları `readHandler: (Data) -> ReadDirective` ile akar.
  `ReadDirective` zaten **ack-tabanlı backpressure** (zorunlu mimari gereksinim).
  `write` / `resize` mevcut.
- `TerminalPipeline.onFlushBatch: (@Sendable (Data) -> Void)` — coalesce edilmiş bayt
  batch'leri. Remote stream'in çıkış noktası burası.
- `TerminalSession.terminalView` (SwiftTerm) + 5000 satır scrollback — subscribe
  anında ilk buffer dump'ı buradan serialize edilir.

### Sorumluluklar
- **Session-list snapshot (hafif):** `[{id, repoName, statusBadge, title, model}]`.
  Sadece liste görünümü için. Transcript/prompt scraping alanları (`activePrompt`,
  `screenText`) kaldırılır.
- **Stream tap:** yalnızca *abone olunan* terminalin `onFlushBatch` batch'leri relay'e
  `data` mesajı olarak gönderilir (base64/binary). Aboneliği olmayan terminaller
  stream'lenmez (bant genişliği).
- **Subscribe → scrollback:** telefon bir terminale abone olunca SwiftTerm buffer'ı
  serialize edilip tek `scrollback` snapshot'ı olarak gönderilir; ardından canlı delta
  akışı başlar. **Sequence-güvenli kesim + terminal auto-reply filtresi** (zorunlu
  replay güvenliği) korunur — replay sırasında terminal query'lerine sahte otomatik
  yanıt enjekte edilmez.
- **Input:** telefondan gelen `input` baytları `PTYProcess.write`'a (mevcut input
  filter üzerinden) yazılır. `resize` mesajı → `PTYProcess.resize` (telefon viewport
  cols/rows).

### Kaldırılan dosyalar/kod
`TranscriptParser`, `TranscriptWatcher`, `SnapshotBuilder`'ın scrape kısmı,
`TranscriptClaimRegistry`, `DetectedPrompt` ekran-scraping. Bu kaldırma crosstalk /
boş-chat / `/clear` takibi bug sınıflarını kökten yok eder.

## 4. Relay protokolü — `RelayServer` (TypeScript)

Mevcut `hello` / `welcome` / `ping` / `pong` + token-oda izolasyonu **korunur**.
Chat mesajları (`snapshot` / `event` / `command`) yerine terminal-stream tipleri:

| Tip | Yön | Payload |
|---|---|---|
| `sessions` | mac→phone | hafif session listesi (eski `snapshot` yerine) |
| `subscribe` | phone→mac | `{sessionId, cols, rows}` |
| `unsubscribe` | phone→mac | `{sessionId}` |
| `scrollback` | mac→phone | `{sessionId, seq, data}` (ilk buffer dump) |
| `data` | mac→phone | `{sessionId, seq, data}` (canlı delta) |
| `input` | phone→mac | `{sessionId, data}` (tuş baytları) |
| `resize` | phone→mac | `{sessionId, cols, rows}` |

- `data` / `scrollback` payload'ındaki `data` alanı **base64 string**'tir (Lumi relay'i
  JSON envelope tabanlı text WS; ham baytlar base64 ile taşınır). İkili (binary) WS
  frame'leri ileride bir optimizasyon olarak değerlendirilebilir ama ilk sürüm dışı.
- `seq` monoton artan — reconnect'te sıra doğrulama ve kayıp tespiti.
- Push (`register_push` / `unregister_push`) korunur.
- Oda izolasyonu token gizliliğine dayanır (farklı token = farklı oda, chat karşı
  kullanıcıya sızmaz) — mevcut güvenlik sınırı korunur.

## 5. iOS tarafı — `LumiMobile`

- **SessionListView (korunur):** repo adı + durum rozeti (idle/working/waiting/error);
  dokun → terminal görünümü.
- **TerminalView (yeni):** SwiftTerm iOS `TerminalView`; `scrollback` + `data` baytları
  doğrudan emülatöre `feed` edilir. Model değiştirme menüsü üstte kalır.
- **Aksesuar tuş çubuğu:** ok tuşları (↑↓←→), Esc, Tab, Enter, Ctrl-C + metin girişi →
  `input` mesajı. Claude'un `1/2/3`, `y/n` seçeneklerine ve TUI'lere cevap vermek için
  şart.
- **Reconnect:** bağlantı kopunca aktif terminale otomatik yeniden abone olunur; Mac
  taze `scrollback` gönderir → ekran doğru repaint eder.

### Kaldırılan dosyalar/kod
`TurnFilter` (`lastAssistantTurn`, `newestFailedUserMessageId`), chat `FeedItem` /
`FeedEntry` modeli, `QuestionCardView`, screenText/activePrompt render yolları.

## 6. Bağlantı güvenilirliği

"Bağlantılar kopuyor" şikayetine doğrudan yanıt:
- **Heartbeat:** `ping` / `pong` + idle watchdog (belirli süre pong yoksa reconnect).
- **Reconnect controller:** exponential backoff + otomatik subscription replay (aktif
  terminale yeniden abone).
- **Backpressure:** Mac zaten `OutputCoalescer` + `ReadDirective` ack zincirine sahip;
  ayrıca yalnızca abone terminal stream'lenir.

## 7. Taşınacak vs sıfırdan kurulacak

**`lumi-remote`'tan seçmeli taşınır (jenerik, hâlâ iyi):**
- `RelayServer` iskeleti (WS transport, oda izolasyonu, `isolation.test.ts`) → protokol
  terminal-stream'e uyarlanır.
- Pairing / QR akışı (`Pairing.swift`, `PairingView`, `QRScannerView`).
- Push scaffold (`PushNotifications.swift`, `PushSystem.swift`).
- App kabuğu (`LumiMobileApp`, `RootView`, `SessionListView` iskeleti), `project.yml`.

**Sıfırdan kurulur:**
- Çekirdek stream modeli: Mac `LumiRemote` stream tap + input write, iOS `TerminalView`
  byte-feed, relay terminal protokolü.

## 8. Test stratejisi

- **RelayServer:** yeni terminal protokolü + oda izolasyonu (mevcut `isolation.test.ts`
  uyarlanır); subscribe/data/input routing.
- **Mac:** stream tap → `data` mesajı, `input` → `PTYProcess.write`, scrollback
  serialize (saf birim testler; I/O yok).
- **iOS:** byte-feed → SwiftTerm emülatör, accessory-key → input bayt eşlemesi,
  reconnect subscription replay.
- **E2E wire:** Mac ↔ relay ↔ phone gerçek WS (mevcut `EndToEndWireTests` uyarlanır);
  subscribe → scrollback → data → input tam turu.

## 9. Kapsam dışı (YAGNI)

- Orca'nın E2EE / relay-direct-upgrade / endpoint-supervisor transport makinesi
  (Lumi'nin basit relay'i korunuyor).
- Çok-terminalli worktree modeli (Lumi'de session = tek terminal).
- Yapısal prompt tespiti / native soru kartı overlay (hibrit reddedildi — scraping
  kırılganlığını geri getirir).
- Mobil terminal için mouse reporting / reflow / dikte gibi orca-webview'e özgü ileri
  davranışlar (ilk sürüm dışı; gerekirse sonra).

## 10. Zorunlu mimari gereksinimlerle uyum (`docs/spec/00-overview.md` §4)

- **PTY→UI ack backpressure:** `PTYProcess.ReadDirective` zinciri korunur; remote stream
  bu ack'i bypass etmez.
- **Render-crash izolasyonu:** her `TerminalSession` kendi PTY/emülatörünü tutar; remote
  tap read-only broadcast, çökme yayılmaz.
- **Replay güvenliği:** scrollback dump sequence-güvenli kesimle alınır; terminal
  auto-reply filtresi replay sırasında sahte yanıtı engeller.
