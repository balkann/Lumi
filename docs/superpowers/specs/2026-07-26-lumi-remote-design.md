# Lumi Remote — Tasarım Spec'i

**Tarih:** 2026-07-26
**Durum:** Onaylandı (brainstorming oturumu sonucu)
**Kapsadığı iş:** Lumi'deki Claude Code oturumlarını iPhone'dan izleme ve yönlendirme

## 1. Amaç

Mac'te Lumi altında koşan Claude Code oturumlarını telefondan yönetmek. Telefonda
ihtiyaç duyulan görünüm bilinçli olarak basit tutulur: agent ne yapıyor, soru sordu
mu, neler bitirdi — ve metin/hazır cevaplarla yönlendirme. Mac host'tur, telefon
ince istemcidir; telefonda hiçbir agent çalışmaz.

## 2. Kapsam

### Dahil (v1)

- Oturum listesi: repo adı + canlı durum rozeti (`idle / working / waiting / error`)
- Oturum detayı: sadeleştirilmiş olay akışı (asistan metni, tool özetleri, sorular)
- Soru/izin kartları: hazır cevap butonları (`1/2/3`, `Enter`, `Esc`) + serbest metin
- Telefondan yeni oturum açma: repo seç → (opsiyonel) persona seç → ilk prompt
- Push bildirimi: oturum `waiting-unseen` veya `error` durumuna geçince (APNs)
- Mac çevrimdışıyken son bilinen durumu "son görülme" etiketiyle gösterme

### Kapsam dışı (v1)

- Ham terminal görüntüsü/mirror (telefonda okunmuyor; ihtiyaç doğarsa v2)
- E2E şifreleme (kendi relay + TLS yeterli görüldü; mesaj zarfı ileride eklenebilir
  şekilde ayrık tasarlanır)
- Çoklu kullanıcı / çoklu Mac desteği (protokol tek kullanıcı-tek Mac varsayar,
  mesajlarda `macId` alanı ileriye dönük rezerve edilir)
- Codex oturumları için zengin akış (transcript formatı Claude Code'a özgü; Codex
  oturumları "yalnız durum" modunda çalışır)

## 3. Değerlendirilen alternatifler ve kararlar

| Karar | Seçilen | Elenenler ve neden |
|---|---|---|
| Ağ katmanı | Kendi relay sunucusu (Railway) | Tailscale (kullanıcıya kullanımı zor geldi), sadece-LAN (dışarıdan erişim yok), Cloudflare Tunnel (TLS üçüncü tarafta sonlanıyor) |
| Telefon istemcisi | Native iOS (SwiftUI) | PWA (kullanıcı tercihi native; APNs push daha güvenilir) |
| Akış kaynağı | Transcript JSONL izleme | PTY parse (kalitesi düşük, kırılgan), Claude Code hook'ları (konfigürasyon yönetimi + Codex'te çalışmaz) |
| Barındırma | Railway (~5 $/ay) | Heroku (ücretsiz plan kalktı, WS idle timeout'ları) |

## 4. Mimari

Üç bileşen, tek yönlü bağımlılık: telefon ve Mac birbirini bilmez, ikisi de relay'i
bilir. Her iki taraf da dışarı doğru WebSocket açar — port açma, VPN yok.

```
iOS App (SwiftUI)  ⇄ wss ⇄  Relay (Railway, Node.js)  ⇄ wss ⇄  Lumi (LumiRemote modülü)
                                     │
                                     └─→ APNs (push)
```

### 4.1 Relay (Railway, Node.js/TypeScript)

Tek küçük servis. Sorumlulukları:

1. Token'la eşleşen Mac ve telefon bağlantılarını birbirine köprüler
2. Mac'ten gelen son `snapshot`'ı **bellekte** tutar (telefon bağlanınca anında
   ekran dolsun; Mac offline'ken "son görülme" gösterilebilsin)
3. `waiting-unseen` / `error` geçişlerinde APNs'e push iter

Veritabanı ve disk yok; süreç yeniden başlarsa Mac yeniden bağlanıp snapshot'ı
tazeler. İçerik kalıcı olarak hiçbir yerde saklanmaz.

### 4.2 Lumi tarafı — yeni `LumiRemote` SPM modülü

Mevcut mimari kurallara uyar (servis → store `AsyncStream`, store → UI
`@Observable`, Combine yok, manuel DI — `AppContainer`'a eklenir).

| Birim | Sorumluluk |
|---|---|
| `RelayConnection` | `URLSessionWebSocketTask`; kopunca exponential backoff ile yeniden bağlanır; bağlantı durumunu `AsyncStream` ile yayınlar |
| `SnapshotBuilder` | Repo + terminal + `TerminalStatus` bilgisinden telefon-yönelik özet üretir; durum değişimlerinde artımlı `event` yollar |
| `TranscriptWatcher` | `~/.claude/projects/<proje>/<oturum>.jsonl` dosyalarını tail'ler; terminal↔dosya eşleşmesini cwd + son değişiklik zamanıyla yapar; olay tiplerine çevirir |
| `RemoteCommandHandler` | Gelen komutları doğrular ve yönlendirir: `send_text`/`press_key` → ilgili PTY'ye tuş basımı; `start_session` → `SessionStarterService` |

Lumi UI'ına eklenen tek görünür parça: bağlantı göstergesi + eşleştirme QR'ı
(Ayarlar içinde).

### 4.3 iOS uygulaması (SwiftUI, `LumiMobile/`)

Üç ekran:

1. **Oturumlar** — repo adı + durum rozeti; `waiting` olanlar üstte
2. **Oturum detayı** — olay akışı (aşağıda §5); altta serbest metin kutusu;
   `question` olayı geldiğinde sabitlenmiş cevap kartı
3. **Yeni oturum** — repo listesi (snapshot'tan) → persona seçimi (opsiyonel) →
   ilk prompt → gönder

## 5. Olay akışı modeli

Telefonda görünen akış, transcript JSONL'inden türetilen olaylardır:

| Olay | Kaynak | Telefonda görünümü |
|---|---|---|
| `assistant_text` | jsonl asistan mesajı | Akışın ana gövdesi (markdown düz metne indirgenir) |
| `tool_use` | jsonl tool çağrısı | Tek satır özet: "Edit: ConfigService.swift", "Bash: swift test" |
| `question` | jsonl'de soru/izin istemi | Cevap kartı: soru metni + seçenek butonları |
| `status_change` | Lumi `TerminalStatus` (mevcut mekanizma) | Rozet güncellenir; `waiting`'de push tetiklenir |
| `turn_done` | jsonl tur sonu | Akışta ince ayraç |

Eşleşme bulunamayan oturum (ör. Codex, ya da jsonl henüz oluşmadı) **yalnız durum
moduna** düşer: rozet + metin gönderme çalışır, zengin akış görünmez. Bu bir hata
değil, tanımlı davranıştır.

Cevap butonları ve serbest metin, PTY'ye tuş basımı olarak yazılır — Claude Code
açısından klavyeden ayırt edilemez.

## 6. Protokol

WebSocket üstünde JSON zarflar. Zarf, ileride E2E şifreleme eklenebilsin diye
`payload`'ı ayrık tutar:

```json
{ "v": 1, "type": "...", "payload": { } }
```

- **Mac → relay:** `hello` (rol: mac, token), `snapshot` (tam durum),
  `event` (artımlı olay), `pong`
- **Telefon → relay:** `hello` (rol: phone, token), `command`, `ping`
- **Komutlar:** `send_text {sessionId, text}`, `press_key {sessionId, key}`,
  `start_session {repoPath, personaId?, prompt}`
- Komut sonucu Mac'ten `command_result {commandId, ok, error?}` olarak döner;
  hedef terminal kapandıysa `ok: false` + açıklama.

## 7. Güvenlik

- **Eşleştirme:** Lumi kriptografik rastgele bir gizli token üretir ve QR olarak
  gösterir; telefon okutur. Relay yalnızca aynı token'lı iki tarafı köprüler.
  Token `~/.lumi/remote.json`'da (dev: `~/.lumi-dev/`) ve iOS Keychain'de saklanır.
- **Taşıma:** TLS (Railway'in verdiği `wss://`). Relay kendi sunucumuz olduğundan
  üçüncü taraf trafiği görmez.
- **Relay'de veri:** yalnızca bellekteki son snapshot; log'lara mesaj içeriği
  yazılmaz.
- Yanlış token'lı bağlantılar sessizce kapatılır; kaba kuvvete karşı bağlantı
  başına basit oran sınırı.

## 8. Bildirimler

- Tetik: `status_change` → `waiting-unseen` veya `error`
- İçerik: repo adı + sorunun ilk satırı (ör. "PowerSlap: Bash komutu için izin istiyor")
- Mekanizma: relay → APNs, token tabanlı auth (`.p8` anahtarı Railway env var'ında)
- **Gereksinim:** ücretli Apple Developer hesabı (99 $/yıl). Hesap olana kadar
  push devre dışı kalır; app açıkken canlı akış zaten çalışır.

## 9. Hata durumları

| Durum | Davranış |
|---|---|
| Mac çevrimdışı | Telefon, relay'deki son snapshot'ı "son görülme: HH:mm" etiketiyle gösterir; komut gönderimi kapalı |
| Relay çevrimdışı | Lumi ve telefon exponential backoff ile sessizce yeniden dener; Lumi ayarlarda bağlantı durumunu gösterir |
| Komut hedefi yok | `command_result {ok: false}`; telefonda satır içi hata |
| jsonl eşleşmesi yok | Yalnız durum modu (§5) |
| Relay yeniden başladı | Mac yeniden bağlanınca snapshot'ı tazeler; telefonlar bir sonraki mesajda güncel duruma döner |

## 10. Kod organizasyonu

Monorepo — mevcut Lumi repo'suna eklenir:

```
LumiPackages/Sources/LumiRemote/   Mac tarafı modül (LumiKit ← LumiRemote; AppContainer'a DI)
RelayServer/                        Node.js/TypeScript relay (Railway'e deploy)
LumiMobile/                         Xcode projesi (SwiftUI iOS app)
```

Persistence uyumluluk kuralı (karar 9) korunur: mevcut `~/.lumi` dosya formatlarına
dokunulmaz; remote yapılandırması yeni ve ayrı bir dosyada (`remote.json`) yaşar.

## 11. Test stratejisi

- **`TranscriptWatcher`:** gerçek Claude Code jsonl fixture'larıyla parse birim
  testleri (olay tipleri, eşleşme, bozuk/yarım satır toleransı)
- **`RemoteCommandHandler` / `SnapshotBuilder`:** mevcut Swift Testing altyapısıyla,
  sahte PTY/servislerle birim testleri
- **Relay:** birim + iki sahte istemciyle (mac+phone) WebSocket entegrasyon testleri;
  token eşleştirme ve yeniden bağlanma senaryoları
- **iOS:** view-model birim testleri (akış üretimi, komut kuyruğu)
- **Manuel doğrulama:** gerçek telefonla uçtan uca: soru kartına cevap, dışarıdan
  yeni oturum açma, push alma, Mac uyku/uyanma geçişi

## 12. Açık noktalar / bilinçli riskler

1. **jsonl eşleştirme kesinliği:** ~~cwd + zaman sezgiseli aynı repoda eşzamanlı
   birden çok oturumda yanlış eşleşebilir; v1'de kabul edilen risk~~ **[ÇÖZÜLDÜ]**
   Gözlemlendi (aynı repoda N tab → mesajlar tab'lar arası sızıyordu). Hook yerine
   **birthtime↔createdAt tekil-sahiplik** nokta çözümü uygulandı (`TranscriptClaimRegistry`):
   jsonl'in dosya-yaratılma anı (birthtime) ≈ Claude oturumunun başlangıcı ≈ terminalin
   `createdAt`'i olduğundan, her terminal `createdAt`'inden hemen sonra doğmuş,
   başka terminalce sahiplenilmemiş jsonl'e tekil atanır. Atama kayıtlı terminaller +
   dizin içeriğinden her poll'da deterministik hesaplanır (claim state yok → yarış yok).
   Eski oturum dosyaları (birthtime ≪ güncel createdAt'ler) elenir; bu, mtime sezgiselinin
   ıskaladığı "zaten-açık tab'lar" durumunu da doğru çözer. Tek terminal → mevcut mtime
   sezgiseli (restart fallback dahil) korunur. Kalan kabul edilen kırılganlık: iki tab'ın
   ~saniye-altı arayla açılması (birthtime ayrımı belirsizleşir).
2. **Transcript formatı Anthropic'in iç formatı:** sürüm güncellemelerinde
   kırılabilir; parse katmanı toleranslı yazılır, bilinmeyen kayıtlar atlanır.
3. **İzin istemlerinin metni transcript'te olmayabilir:** izin diyaloğu CLI'ın
   kendi arayüzüdür, jsonl her zaman içermeyebilir. Tanımlı davranış: `waiting`
   sinyali geldiğinde soru metni bulunamazsa telefonda **genel cevap kartı**
   gösterilir ("izin bekliyor" + son `tool_use` bağlamı + 1/2/3/Enter/Esc
   butonları). Metin bulunursa tam kart gösterilir.
4. **Mac'in uyanık kalması:** kapsam dışı ama kullanım için şart; kullanıcı
   dokümantasyonunda `caffeinate`/Amphetamine notu verilir.
