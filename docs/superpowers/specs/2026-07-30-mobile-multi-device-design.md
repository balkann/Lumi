# Lumi Mobile — Çoklu Cihaz (Eş Zamanlı Bağlantı) Tasarımı

Tarih: 2026-07-30
Branch bağlamı: `mobile-permission-prompt` (izin promptu görünürlüğü işinin üzerine kurulur)

## Amaç

Mobil uygulama şu an tek bir Mac'e (tek eşleşme, tek WebSocket) bağlanır. Bu tasarım,
telefonun **birden fazla Mac'e aynı anda canlı bağlı kalmasını** ve üstteki bir cihaz
seçiciyle bunlar arasında geçiş yapmasını sağlar. Seçili olmayan bir cihazda bekleyen
bir izin (decisionPending) varsa, o cihazın sekmesinde rozet belirir.

## Kapsam kararları

Bu turda yapılacaklar:
- N eşleşme → N canlı WebSocket, hepsi arka planda bağlı.
- Üstte yatay cihaz seçici (pill/segment satırı) + "cihaz ekle" (`＋`).
- Cihaz başına bağlantı durumu ve `decisionPending` rozeti.
- Cihaz etiketi Mac'ten otomatik gelen `deviceName` ile.
- Eski tek-eşleşme kalıcılığından çoklu-eşleşmeye migration.

Bilinçli olarak **kapsam dışı** (sonraya):
- **Push bildirimleri.** Bu turda hiç bildirim yok — yalnızca uygulama içi rozet.
  APNs (uygulama kapalıyken uzak push) tamamen ayrı, kendi spec'ini hak eden bir iş.
- **Otomatik öne getirme.** İzin bekleyen cihaza otomatik geçiş yok; geçiş her zaman
  manuel (kullanıcı pill'e dokunur).
- **`macId` tabanlı yönlendirme.** N ayrı oda/soket olduğu için mesajın hangi cihazdan
  geldiği zaten geldiği soketten bellidir; `macId` bu turda kullanılmaz.

## Mevcut mimari (başlangıç noktası)

- `AppModel` (@Observable): tek `client: any RelayClienting`, tek `connection: ConnectionState`,
  `sessions: [SessionSummary]` (düz, host kırılımı yok), per-session state, `isPaired`.
  (`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`)
- `RelayClient` actor: tek WebSocket bağlantısı.
  (`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/RelayClient.swift`)
- `KeychainStore`: tek eşleşme, account `"default"`.
  (`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Pairing.swift`)
- Relay: tek token = tek oda = tek Mac + N telefon (saf geçiş bridge).
  (`RelayServer/src/registry.ts`, `RelayServer/src/bridge.ts`)

## Seçilen yaklaşım: cihaz başına bağımsız bağlantı birimi

İki alternatif değerlendirildi:

- **A (seçildi):** Bugünkü `AppModel`'in per-bağlantı sorumluluğu `DeviceConnection`
  birimine çıkarılır; ince bir koordinatör N birimi yönetir. İzolasyon güçlü, mevcut
  AppModel gövdesi neredeyse 1:1 taşınır, her bağlantı bağımsız test edilebilir.
- **B (reddedildi):** Tek `AppModel` korunur, tüm state `(deviceId, sessionId)` ile
  anahtarlanır. İkinci ekseni her yere serpmek kırılgan; CLAUDE.md'deki SOLID/izolasyon
  hedefine ters.

## Bileşenler

### 1. `DeviceConnection` (@Observable) — yeni

Bugünkü `AppModel`'in tek-bağlantı mantığının taşındığı birim. Sahip olduğu:
- Kendi `RelayClient`'ı (tek WebSocket), `ConnectionState`'i.
- `sessions: [SessionSummary]` ve per-session state (`decisionPending` dahil — branch işi).
- `id` (kararlı yerel eşleşme id'si), `deviceName` (Mac'ten gelen; gelene kadar
  eşleşme URL'inden türetilmiş bir yer tutucu).
- Türetilmiş: `pendingDecisionCount` = `decisionPending` olan oturum sayısı.
- Bağımsız reconnect: bu cihaz offline olsa diğerlerini etkilemez.

### 2. `AppModel` — ince koordinatör (yeniden şekillenir)

- `devices: [DeviceConnection]`, `selectedDeviceId`.
- `addDevice(PairingInfo)` — kalıcılığa yazar, yeni `DeviceConnection` kurar ve bağlar.
- `removeDevice(id)` — soketi kapatır, keychain girişini siler, listeden düşürür;
  kaldırılan seçiliyse başka bir cihaza (veya hiçbirine) geçer.
- `selectDevice(id)`.
- `selectedDevice: DeviceConnection?` — UI'ın içerik için kullandığı.
- Açılışta `readAll()` ile tüm eşleşmeler paralel bağlanır.

### 3. Kalıcılık — `KeychainStore` çoklu girişe geçer

- Tek `"default"` hesabı yerine eşleşme başına bir keychain girişi; account = eşleşme
  token'ından türeyen kararlı yerel id.
- API: `read() -> PairingInfo?` yerine `readAll() -> [PairingInfo]`, `write(PairingInfo)`,
  `delete(id)`.
- **Migration:** açılışta eski tek `"default"` girişi bulunursa 1. cihaz olarak yeni
  şemaya taşınır ve eski giriş temizlenir. Mevcut eşleşmiş kullanıcılar veri kaybetmez.

### 4. Protokol — Mac tarafı küçük eklenti

- Mac, handshake/snapshot mesajında `deviceName` (bilgisayar adı) gönderir; rezerve
  `macId` alanının yanına eklenir.
- Relay saf geçiş olduğundan **relay değişmez**.
- Mobil `SessionSummary`/snapshot decode'una `deviceName` eklenir ve etikette kullanılır.

### 5. UI

- Oturum listesinin üstünde yatay cihaz seçici satırı. Her pill:
  cihaz adı + `pendingDecisionCount > 0` ise rozet + küçük bağlantı-durumu noktası.
  Sonda `＋` → mevcut `PairingView` akışı (QR/URL).
- İçerik: `selectedDevice`'ın `SessionListView`'ı (neredeyse değişmeden — düz oturum
  listesini seçili cihazın birimine bağlar).
- Cihaz kaldırma, bir cihaz ayar sheet'inden.
- Eşleşme varken cihaz barı 1 cihazda da görünür (`＋` keşfedilebilir olsun diye).
- 0 cihaz → mevcut `PairingView` ilk-çalıştırma ekranı.

### 6. Çapraz-cihaz izin davranışı

- Seçili olmayan cihazda `decisionPending` → o cihazın pill'inde rozet.
- Otomatik geçiş yok, push yok. Kullanıcı pill'e dokununca o cihaza geçer ve mevcut
  izin kartı akışı (`QuestionCardView`) çalışır.

## Hata yönetimi

- Her `DeviceConnection` bağımsız bağlanır/yeniden bağlanır. Bir Mac'in offline olması
  yalnızca kendi pill'inde bağlantı-durumu noktasıyla görünür; diğer cihazlar çalışır.
- `removeDevice` sırasında seçili cihaz kaldırılırsa koordinatör kalan bir cihaza geçer;
  hiç kalmazsa `PairingView`'a döner.

## Test planı

- Mevcut `AppModel` (tek-bağlantı) testleri `DeviceConnection`'a taşınır.
- Yeni koordinatör testleri: cihaz ekle/kaldır/seç; `pendingDecisionCount` toplama/rozet;
  seçili cihaz kaldırılınca geçiş; **legacy tek-eşleşme migration'ı**.
- `KeychainStore` çoklu-giriş testleri: birden çok yaz/oku/sil + legacy migration.
- Çoklu-cihaz senaryoları için mevcut `RelayClienting` fake'i birden çok örnekle kurulur.

## Açık olmayan / karara bağlanan noktalar

- Cihaz barı 1 cihazda da görünür (gizleme yok).
- `macId` bu turda kullanılmaz; yalnızca `deviceName` eklenir.
- Push ve otomatik geçiş kapsam dışı.
