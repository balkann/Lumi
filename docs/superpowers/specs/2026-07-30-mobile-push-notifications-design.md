# Lumi Mobile — Push Bildirimleri (iOS istemci kaydı + toggle)

Tarih: 2026-07-30
İlgili: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` (§ push mimarisi),
`docs/spec/50-remote-protocol.md` (protokol referansı — bu tasarım `unregister_push` ekliyor).

## 1. Amaç ve kapsam

Kullanıcı, bir oturum **cevap bekler** (`waiting-unseen`) veya **hata verir** (`error`)
duruma geçtiğinde telefonuna push bildirimi almak istiyor. App Store yayını
**gerekmez** — push, dev/TestFlight/ad-hoc dağıtımın hepsinde çalışır.

Mevcut durum: push mimarisinin çoğu zaten yazılmış:
- **Relay (`RelayServer/`):** `ApnsPushSender` (`.p8` → JWT → HTTP/2 APNs), `register_push`
  ile oda başına token saklama (`registry.ts`), push kuralı (`bridge.ts`
  `maybePush`): `status_change` + status ∈ {`waiting-unseen`,`error`} → APNs alert.
- **Mac (`LumiRemote`):** `RemoteService.swift:145` geçişlerde `status_change` event'ini
  `repoName` + opsiyonel `summary` ile yayınlıyor.
- **Mobil taşıma:** `RelayClient.registerPush` → `AppModel.registerPush` →
  `PhoneProtocol.registerPushFrame` — hepsi mevcut ama **hiç çağrılmıyor**.

**Bu tasarımın doldurduğu boşluk** (üç parça):
1. iOS istemci: bildirim izni, APNs kaydı, device token alımı, `registerPush` çağrısı.
2. Push Notifications entitlement + `project.yml` capability.
3. Toggle'ın dürüst KAPA'sı için relay'e `unregister_push` mesaj tipi (Seçenek A).

Relay'in APNs gönderme mantığına ve Mac tarafına **dokunulmaz** (tek istisna:
`unregister_push` işleyişi).

## 2. iOS istemci mimarisi

### 2.1 `AppDelegate` (App katmanı, `UIApplicationDelegateAdaptor`)
`LumiMobileApp`'e eklenir. Tek sorumluluğu APNs callback'lerini `PushCoordinator`'a
iletmek — iş mantığı içermez:
- `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` → `Data`'yı
  hex string'e çevirir, `PushCoordinator.didReceive(deviceTokenHex:)` çağırır.
- `application(_:didFailToRegisterForRemoteNotificationsWithError:)` →
  `PushCoordinator.didFailRegistration(_:)` (loglar, toggle'ı kapalı yansıtır).

`AppDelegate`, `PushCoordinator` örneğine erişmek için uygulama başlarken kurulan
tekil referansı kullanır (App katmanında composition; `AppModel` ile aynı yaşam döngüsü).

### 2.2 `PushCoordinator` (LumiMobileKit — yeni, test edilebilir tip)
Köprü mantığının tamamı burada; UIKit/UNUserNotification bağımlılıkları **protokol
arkasında** soyutlanır (test için fake).

Bağımlılıklar (enjekte edilir):
- `NotificationAuthorizing` protokolü — `authorizationStatus() async -> AuthStatus`,
  `requestAuthorization() async -> Bool`. Prod implementasyonu `UNUserNotificationCenter`'ı sarar.
- `RemoteRegistering` protokolü — `registerForRemoteNotifications()`,
  `unregisterForRemoteNotifications()`. Prod implementasyonu `UIApplication.shared`'ı sarar.
- `AppModel` referansı (token geldiğinde `registerPush`/`unregisterPush` tetiklemek için).

Sorumlulukları:
- Sistem izin durumunu okur/normalize eder: `notDetermined | denied | authorized`.
- İzin ister ve `registerForRemoteNotifications()` çağırır.
- En son device token'ı bellekte tutar (`latestToken: String?`).
- Toggle AÇ akışını yürütür (§3.2).

### 2.3 `AppModel` yeni durumu ve API'si
- `notificationsEnabled: Bool` — kullanıcı tercihi, `UserDefaults`'ta kalıcı (hassas
  veri değil; Keychain gerekmez). Uygulama açılışında okunur.
- `notificationAuthStatus: NotificationAuthStatus` — UI'nin toggle davranışını (deep-link
  vs. request) seçmesi için sistem izni.
- `latestPushToken: String?` — `PushCoordinator`'dan gelen son token (re-register için).
- Yeni metotlar:
  - `unregisterPush() async` → `client.unregisterPush(deviceToken:)` (Seçenek A frame'i).
  - Mevcut `registerPush(deviceToken:)` korunur.
- **Re-register kuralı:** `welcome` işlenince, `notificationsEnabled && latestPushToken != nil`
  ise `registerPush` yeniden gönderilir. Gerekçe: relay oda `pushTokens`'ı **bellekte**;
  relay yeniden başlarsa veya oda yeniden kurulursa token kaybolur.

## 3. Akış: iki tetikleyici

### 3.1 Eşleştirme başarılı olunca (bir kez)
`AppModel.pair(...)` başarıyla dönerse **ve** `notificationAuthStatus == notDetermined`
ise → `PushCoordinator` izin ister. İzin verilirse `notificationsEnabled = true`
("bir kere izin verirse açılsın") ve kayıt akışı başlar. Reddedilirse toggle kapalı kalır.

### 3.2 Gearshape menüsünde "Bildirimler" toggle'ı
Konum: `SessionListView.swift` toolbar'ındaki `gearshape` `Menu` (mevcut "Eşleştirmeyi
kaldır" ile aynı menü).

- **AÇ:**
  - `notDetermined` → izin iste; verilirse devam, reddedilirse toggle kapalı kalır.
  - `denied` → sistem Ayarlar'a deep-link (`UIApplication.openSettingsURLString`);
    toggle açılmaz (kullanıcı Ayarlar'dan dönünce durum yeniden okunur).
  - `authorized` → `registerForRemoteNotifications()` → token gelince
    `AppModel.registerPush`; `notificationsEnabled = true`.
- **KAPA:**
  - `notificationsEnabled = false`.
  - `AppModel.unregisterPush()` → relay token'ı odadan siler (Seçenek A).
  - `unregisterForRemoteNotifications()` (uygulama yeni token almayı bırakır).
  - Sonuç: push **anında** durur.

## 4. Seçenek A — `unregister_push` protokol eklentisi

`docs/spec/50-remote-protocol.md` mesaj tablosuna eklenir:

| Tip | Yön | Payload | Davranış |
|---|---|---|---|
| `unregister_push` | phone→relay | `{deviceToken: string}` | Odadan APNs cihaz token'ını siler |

Relay değişiklikleri (minimal):
- `protocol.ts` — bilinen tip allowlist'ine `unregister_push` eklenir (yoksa relay 4002 ile kapatır).
- `registry.ts` / `Room` — token silme yardımcı davranışı (`pushTokens.delete`).
- `bridge.ts` `fromPhone` — `register_push`'ın simetriği: `deviceToken` string ve boş
  değilse `room.pushTokens.delete(token)`.

Mobil değişiklik:
- `PhoneProtocol.unregisterPushFrame(deviceToken:)` — `register_push` ile aynı şekil.
- `RelayClienting.unregisterPush(deviceToken:)` + `RelayClient` implementasyonu.
- `FakeRelayClient` (testler) — yeni metodu kaydeder.

## 5. Entitlement ve ortam eşleşmesi (ops)

### 5.1 project.yml + entitlements
- `LumiMobile/App/LumiMobile.entitlements` (yeni): `aps-environment` anahtarı.
- `project.yml` `LumiMobile` target'ına `entitlements` (XcodeGen) veya
  `CODE_SIGN_ENTITLEMENTS` ayarı; Push Notifications capability.

### 5.2 KRİTİK: token tipi ↔ APNs host eşleşmesi
- **Dev-imzalı build** (yerel cihaz testi) → **sandbox** token → relay
  `APNS_HOST=https://api.sandbox.push.apple.com` olmalı.
- **Takımın dağıtım / TestFlight build'i** → **production** token →
  `APNS_HOST=https://api.push.apple.com` (relay varsayılanı).
- Host token tipiyle eşleşmezse APNs `BadDeviceToken` döner ve push sessizce düşer.
- Sonuç: yerel test ile dağıtım testi **ayrı relay konfigürasyonu** ister (ayrı env
  veya ayrı relay instance). Test planında ayrı tutulur.

### 5.3 Apple portal (kullanıcının erişimi var)
- App ID'ye Push Notifications capability.
- APNs `.p8` Auth Key oluştur (Key ID + Team ID not al).
- Railway env var'ları: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`,
  ve test aşamasına göre `APNS_HOST`.

## 6. Bileşen sınırları (özet)

| Birim | Ne yapar | Bağımlılık |
|---|---|---|
| `AppDelegate` | APNs callback → PushCoordinator | PushCoordinator |
| `PushCoordinator` | izin + kayıt orkestrasyonu, token tutar | NotificationAuthorizing, RemoteRegistering, AppModel |
| `AppModel` (ek) | toggle state, kalıcılık, re-register kuralı | RelayClienting, UserDefaults |
| Toggle UI | AÇ/KAPA + deep-link | AppModel |
| Relay `unregister_push` | odadan token siler | registry |

## 7. Test planı

- **LumiMobileKit unit:**
  - `PushCoordinator`: notDetermined→request→authorized→registerForRemote akışı;
    denied→deep-link sinyali; token geldiğinde AppModel.registerPush çağrısı (fake'ler).
  - `AppModel`: toggle AÇ/KAPA state geçişleri, kalıcılık, `welcome` sonrası
    re-register (notificationsEnabled && latestToken).
  - Toggle KAPA → `unregisterPush` frame gönderimi (FakeRelayClient).
- **Relay (vitest):** `unregister_push` → token odadan silinir; bilinmeyen değilse
  bağlantı kapatılmaz; register→unregister→register idempotent.
- **Manuel (gerçek cihaz, dev build + sandbox relay):**
  1. Eşleştir → izin prompt'u çıkar → izin ver.
  2. Cihaz token relay'e ulaşır (relay log).
  3. Mac'te bir oturumu `waiting-unseen`'e sok → telefona bildirim gelsin.
  4. Toggle KAPA → aynı geçiş artık push üretmez.

## 8. Kapsam dışı (YAGNI)

- Bildirim içeriği özelleştirme, kategoriler, aksiyonlu bildirimler.
- Bildirime dokununca ilgili oturuma deep-link (ayrı iş; ileride).
- Badge sayısı yönetimi.
- Birden çok cihaz için token yaşam döngüsü telemetrisi.
