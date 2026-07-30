# Mobile Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS uygulamasının APNs'e kaydolup device token'ını relay'e bildirmesini sağlamak; kullanıcı `waiting-unseen`/`error` oturum geçişlerinde push bildirimi alsın, in-app toggle ile açıp kapatabilsin.

**Architecture:** Relay APNs gönderme mantığı zaten mevcut; bu plan yalnız eksik uçları dolduruyor. iOS istemcisinde tüm iş mantığı `LumiMobileKit` içinde protokol arkasında (UIKit-siz, `swift test` ile test edilebilir); UIKit/UserNotifications sarmalayıcıları App katmanında. Toggle'ın dürüst çalışması için relay'e `unregister_push` mesaj tipi eklenir.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + UIKit adaptor (iOS 17+), `LumiMobileKit` SPM paketi (Foundation-only), Node.js/TypeScript relay (vitest).

## Global Constraints

- **Kit UIKit-siz kalır:** `LumiMobileKit` yalnız Foundation kullanır; `UIKit`/`UserNotifications`/`VisionKit` bu pakete **giremez** (Package.swift notu). Sistem sarmalayıcıları App katmanında yaşar.
- **Swift 6 strict concurrency:** `SWIFT_STRICT_CONCURRENCY: complete`. Yeni tipler `Sendable`; `AppModel`/`PushCoordinator` `@MainActor`.
- **Protokol zarfı:** Tüm mesajlar `{"v":1,"type":"<tip>","payload":{...}}`. Relay bilinmeyen tipte 4002 ile kapatır — yeni tip **hem** `protocol.ts` allowlist'ine **hem** `docs/spec/50-remote-protocol.md`'ye eklenmeli.
- **Bundle ID:** `com.lumi.LumiMobile`.
- **Kalıcılık:** kullanıcı tercihi `UserDefaults` (hassas değil; Keychain `SecureStore` yalnız pairing için).
- **Türkçe kullanıcı metni:** UI ve bildirim metinleri Türkçe (mevcut kodla tutarlı).

## File Structure

**Relay (`RelayServer/`):**
- Modify `src/protocol.ts` — `unregister_push`'ı `KNOWN_TYPES`'a ekle.
- Modify `src/bridge.ts` — `fromPhone`'a `unregister_push` işleyicisi.
- Modify `test/bridge.test.ts` — yeni testler.
- Modify (repo dokümanı) `docs/spec/50-remote-protocol.md` — mesaj tablosuna satır.

**Kit (`LumiMobile/LumiMobileKit/Sources/LumiMobileKit/`):**
- Modify `PhoneProtocol.swift` — `unregisterPushFrame`.
- Modify `RelayClient.swift` — `RelayClienting.unregisterPush` + `RelayClient` impl.
- Create `PushNotifications.swift` — `NotificationAuthStatus`, `EnableResult`, `PushControlling`, `NotificationAuthorizing`, `RemoteRegistering`, `PreferenceStore` + `InMemoryPreferenceStore`/`UserDefaultsPreferenceStore`, `PushCoordinator`.
- Modify `AppModel.swift` — push state + metotlar + welcome re-register.

**Kit tests (`.../Tests/LumiMobileKitTests/`):**
- Modify `AppModelTests.swift` — `FakeRelayClient`'a unregister kaydı + yeni testler.
- Create `PushCoordinatorTests.swift`.

**App (`LumiMobile/App/`):**
- Create `PushSystem.swift` — `SystemNotificationAuthorizer`, `SystemRemoteRegistrar`, `AppDelegate`.
- Modify `LumiMobileApp.swift` — adaptor + composition wiring.
- Modify `SessionListView.swift` — gearshape menüsüne toggle.
- Create `LumiMobile.entitlements`.
- Modify `../project.yml` — entitlements ayarı.

---

## Task 1: Relay `unregister_push`

**Files:**
- Modify: `RelayServer/src/protocol.ts:16-19`
- Modify: `RelayServer/src/bridge.ts:62-82`
- Test: `RelayServer/test/bridge.test.ts`
- Modify: `docs/spec/50-remote-protocol.md`

**Interfaces:**
- Consumes: mevcut `Room.pushTokens: Set<string>` (registry.ts).
- Produces: relay `unregister_push {deviceToken}` mesajını kabul edip token'ı odadan siler.

- [ ] **Step 1: Yeni testleri yaz**

`RelayServer/test/bridge.test.ts` sonuna ekle (dosya başındaki `paired`, `env`, `TOKEN`, `FakeClient` yardımcıları mevcut):

```ts
test('register_push sonra unregister_push token odadan silinir', () => {
  const { bridge, phoneSession, registry } = paired()
  bridge.handleMessage(phoneSession, env('register_push', { deviceToken: 'device-token-abc' }))
  expect([...registry.get(TOKEN)!.pushTokens]).toEqual(['device-token-abc'])
  bridge.handleMessage(phoneSession, env('unregister_push', { deviceToken: 'device-token-abc' }))
  expect(registry.get(TOKEN)!.pushTokens.size).toBe(0)
})

test('unregister_push bilinmeyen token no-op, hata vermez', () => {
  const { bridge, phoneSession, registry } = paired()
  bridge.handleMessage(phoneSession, env('unregister_push', { deviceToken: 'yok' }))
  expect(registry.get(TOKEN)!.pushTokens.size).toBe(0)
})

test('unregister_push sonrası status_change push tetiklemez', () => {
  const { bridge, macSession, phoneSession, push, registry } = paired()
  bridge.handleMessage(phoneSession, env('register_push', { deviceToken: 'device-token-abc' }))
  bridge.handleMessage(phoneSession, env('unregister_push', { deviceToken: 'device-token-abc' }))
  bridge.handleMessage(macSession, env('event', {
    kind: 'status_change', sessionId: 's1', status: 'waiting-unseen', repoName: 'Lumi',
  }))
  expect(push.calls).toHaveLength(0)
})
```

- [ ] **Step 2: Testleri koştur, `unregister_push`'ın protocol tarafından reddedildiğini gör**

Run: `cd RelayServer && npm test -- bridge`
Expected: yeni testler FAIL (unregister_push henüz `KNOWN_TYPES`'ta değil → `parseEnvelope` null; ya da handler yok → token silinmiyor).

- [ ] **Step 3: `protocol.ts` allowlist'ine ekle**

`RelayServer/src/protocol.ts` içindeki `KNOWN_TYPES`:

```ts
const KNOWN_TYPES = new Set([
  'hello', 'welcome', 'snapshot', 'event', 'command', 'command_result',
  'register_push', 'unregister_push', 'ping', 'pong',
])
```

- [ ] **Step 4: `bridge.ts` `fromPhone`'a işleyici ekle**

`RelayServer/src/bridge.ts` `fromPhone` switch'inde `register_push` case'inden sonra:

```ts
      case 'unregister_push':
        if (typeof env.payload.deviceToken === 'string' && env.payload.deviceToken.length > 0) {
          room.pushTokens.delete(env.payload.deviceToken)
        }
        break
```

- [ ] **Step 5: Testleri koştur, geçtiğini doğrula**

Run: `cd RelayServer && npm test`
Expected: tüm testler PASS.

- [ ] **Step 6: Protokol dokümanını güncelle**

`docs/spec/50-remote-protocol.md` mesaj tablosuna `register_push` satırından sonra ekle:

```markdown
| `unregister_push` | phone→relay | `{deviceToken: string}` | Odadan APNs cihaz token'ını siler (toggle kapatma) |
```

- [ ] **Step 7: Commit**

```bash
git add RelayServer/src/protocol.ts RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts docs/spec/50-remote-protocol.md
git commit -m "relay: unregister_push mesaj tipi (toggle kapatınca token odadan silinir)"
```

---

## Task 2: Kit — `unregister_push` frame + client metodu

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift:115-117`
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/RelayClient.swift:29-35,91-93`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: mevcut `PhoneProtocol.frame`, `RelayClient.sendFrame`.
- Produces:
  - `PhoneProtocol.unregisterPushFrame(deviceToken: String) -> String`
  - `RelayClienting.unregisterPush(deviceToken: String) async` (protokole eklenir)
  - `RelayClient.unregisterPush(deviceToken:)` implementasyonu

- [ ] **Step 1: Frame testini yaz**

`LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift` içine bir test metodu ekle (mevcut `registerPushFrame` testinin yanına; yoksa yeni ekle):

```swift
func testUnregisterPushFrame() {
    let frame = PhoneProtocol.unregisterPushFrame(deviceToken: "abc123")
    let data = frame.data(using: .utf8)!
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(obj["v"] as? Int, 1)
    XCTAssertEqual(obj["type"] as? String, "unregister_push")
    XCTAssertEqual((obj["payload"] as? [String: Any])?["deviceToken"] as? String, "abc123")
}
```

- [ ] **Step 2: Testi koştur, fail olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter testUnregisterPushFrame`
Expected: FAIL — `unregisterPushFrame` derlenmiyor.

- [ ] **Step 3: `unregisterPushFrame`'i ekle**

`PhoneProtocol.swift` `registerPushFrame`'in hemen altına:

```swift
    public static func unregisterPushFrame(deviceToken: String) -> String {
        frame(type: "unregister_push", payload: ["deviceToken": deviceToken])
    }
```

- [ ] **Step 4: `RelayClienting` protokolüne + `RelayClient`'a ekle**

`RelayClient.swift` — protokole (mevcut `registerPush` satırının altına):

```swift
    func unregisterPush(deviceToken: String) async
```

`RelayClient` actor'una (mevcut `registerPush` metodunun altına):

```swift
    public func unregisterPush(deviceToken: String) async {
        _ = await sendFrame(PhoneProtocol.unregisterPushFrame(deviceToken: deviceToken))
    }
```

- [ ] **Step 5: Testi koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter testUnregisterPushFrame`
Expected: PASS. (Not: `FakeRelayClient` henüz protokolü karşılamıyorsa test hedefi derlenmez — Step 6'da düzeltilir; önce bu adımda ana hedefin derlendiğini `swift build` ile doğrula: `swift build`.)

- [ ] **Step 6: `FakeRelayClient`'ı yeni metotla güncelle**

`AppModelTests.swift` içindeki `FakeRelayClient`'a kayıt alanları + metotlar ekle. Mevcut `func registerPush(deviceToken: String) async {}` satırını şununla değiştir:

```swift
    private var _pushRegistrations: [String] = []
    private var _pushUnregistrations: [String] = []
    var pushRegistrations: [String] { lock.withLock { _pushRegistrations } }
    var pushUnregistrations: [String] { lock.withLock { _pushUnregistrations } }
    func registerPush(deviceToken: String) async { lock.withLock { _pushRegistrations.append(deviceToken) } }
    func unregisterPush(deviceToken: String) async { lock.withLock { _pushUnregistrations.append(deviceToken) } }
```

- [ ] **Step 7: Tüm Kit testlerini koştur**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS (regresyon yok).

- [ ] **Step 8: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/RelayClient.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: unregister_push frame + RelayClient.unregisterPush"
```

---

## Task 3: Kit — bildirim tipleri, protokoller, tercih deposu

**Files:**
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PushNotifications.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PushCoordinatorTests.swift`

**Interfaces:**
- Produces (bu dosya, Task 4 ve 5 tarafından tüketilir):
  - `enum NotificationAuthStatus: Sendable, Equatable { case notDetermined, denied, authorized }`
  - `enum EnableResult: Sendable, Equatable { case enabled, needsSettings, declined }`
  - `protocol NotificationAuthorizing: Sendable { func authorizationStatus() async -> NotificationAuthStatus; func requestAuthorization() async -> Bool }`
  - `protocol RemoteRegistering: Sendable { @MainActor func registerForRemoteNotifications(); @MainActor func unregisterForRemoteNotifications() }`
  - `@MainActor protocol PushControlling: AnyObject, Sendable { func onPairingSucceeded() async; func enable() async -> EnableResult; func disable() async; func refreshAuthStatus() async }`
  - `protocol PreferenceStore: Sendable { func bool(forKey: String) -> Bool; func set(_ value: Bool, forKey: String) }`
  - `final class InMemoryPreferenceStore: PreferenceStore` (test)
  - `final class UserDefaultsPreferenceStore: PreferenceStore` (prod)

- [ ] **Step 1: `PreferenceStore` testini yaz**

Yeni dosya `PushCoordinatorTests.swift` başlangıcı (PushCoordinator testleri Task 5'te eklenecek):

```swift
import XCTest
@testable import LumiMobileKit

final class PreferenceStoreTests: XCTestCase {
    func testInMemoryPreferenceStoreRoundTrip() {
        let prefs = InMemoryPreferenceStore()
        XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
        prefs.set(true, forKey: "notificationsEnabled")
        XCTAssertTrue(prefs.bool(forKey: "notificationsEnabled"))
        prefs.set(false, forKey: "notificationsEnabled")
        XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
    }
}
```

- [ ] **Step 2: Testi koştur, fail olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PreferenceStoreTests`
Expected: FAIL — `InMemoryPreferenceStore` yok.

- [ ] **Step 3: `PushNotifications.swift`'i oluştur (tipler + protokoller + tercih deposu)**

```swift
import Foundation

/// Sistem bildirim izni durumu (UNAuthorizationStatus'un UIKit-siz karşılığı).
public enum NotificationAuthStatus: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Toggle AÇ sonucu; UI'nin ne yapacağını belirler.
public enum EnableResult: Sendable, Equatable {
    case enabled        // izin var, kayıt başladı
    case needsSettings  // izin reddedilmiş → Ayarlar'a yönlendir
    case declined       // kullanıcı prompt'ta reddetti
}

/// Sistem izin API'sinin soyutlaması (prod: UNUserNotificationCenter).
public protocol NotificationAuthorizing: Sendable {
    func authorizationStatus() async -> NotificationAuthStatus
    func requestAuthorization() async -> Bool
}

/// APNs kayıt API'sinin soyutlaması (prod: UIApplication).
public protocol RemoteRegistering: Sendable {
    @MainActor func registerForRemoteNotifications()
    @MainActor func unregisterForRemoteNotifications()
}

/// AppModel'in push orkestrasyonuna eriştiği sınır (impl: PushCoordinator).
@MainActor
public protocol PushControlling: AnyObject, Sendable {
    func onPairingSucceeded() async
    func enable() async -> EnableResult
    func disable() async
    func refreshAuthStatus() async
}

/// Basit bool tercih deposu (kullanıcı ayarları; Keychain değil).
public protocol PreferenceStore: Sendable {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

public final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Bool] = [:]
    public init() {}
    public func bool(forKey key: String) -> Bool { lock.withLock { storage[key] ?? false } }
    public func set(_ value: Bool, forKey key: String) { lock.withLock { storage[key] = value } }
}

public final class UserDefaultsPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}
```

- [ ] **Step 4: Testi koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PreferenceStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PushNotifications.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PushCoordinatorTests.swift
git commit -m "mobile: push bildirim tipleri, protokoller ve tercih deposu"
```

---

## Task 4: AppModel push state + davranışı

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `RelayClienting.registerPush/unregisterPush` (Task 2), `PreferenceStore`, `PushControlling`, `NotificationAuthStatus`, `EnableResult` (Task 3).
- Produces (Task 5 ve UI tarafından tüketilir):
  - `AppModel.notificationsEnabled: Bool` (read-only)
  - `AppModel.notificationAuthStatus: NotificationAuthStatus` (read-only)
  - `AppModel.pushControl: (any PushControlling)?` (weak, set edilebilir)
  - `func applyPushToken(_ hex: String) async` — token'ı saklar; enabled ise `registerPush`
  - `func setNotificationAuthStatus(_ status: NotificationAuthStatus)`
  - `func markNotificationsEnabled(_ on: Bool) async` — persist + relay register/unregister
  - `func enableNotifications() async -> EnableResult` — `pushControl.enable()`e delege
  - `func disableNotifications() async` — `pushControl.disable()`e delege
  - `func reRegisterPushIfNeeded() async` — welcome sonrası tazeleme
- Not: `init` yeni `prefs` parametresi alır (varsayılanlı → mevcut çağrılar bozulmaz).

- [ ] **Step 1: Testleri yaz**

`AppModelTests.swift`'e ekle. Yardımcı `makeModel`'i tercih deposu döndürecek şekilde güncelle:

```swift
@MainActor
private func makeModelP(paired: Bool = true) -> (AppModel, FakeRelayClient, InMemoryPreferenceStore) {
    let client = FakeRelayClient()
    let store = InMemorySecureStore()
    let prefs = InMemoryPreferenceStore()
    if paired { store.write(PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")) }
    return (AppModel(client: client, store: store, prefs: prefs), client, prefs)
}

func testApplyPushTokenRegistersWhenEnabled() async {
    let (model, client, prefs) = makeModelP()
    prefs.set(true, forKey: "notificationsEnabled")
    // enabled'ı prefs'ten okuması için taze model:
    let model2 = AppModel(client: client, store: InMemorySecureStore(), prefs: prefs)
    XCTAssertTrue(model2.notificationsEnabled)
    await model2.applyPushToken("tok-1")
    XCTAssertEqual(client.pushRegistrations, ["tok-1"])
    _ = model
}

func testApplyPushTokenNoRegisterWhenDisabled() async {
    let (model, client, _) = makeModelP()
    XCTAssertFalse(model.notificationsEnabled)
    await model.applyPushToken("tok-1")
    XCTAssertTrue(client.pushRegistrations.isEmpty)
}

func testMarkEnabledTrueRegistersTokenAndPersists() async {
    let (model, client, prefs) = makeModelP()
    await model.applyPushToken("tok-1")           // disabled → kayıt yok
    await model.markNotificationsEnabled(true)
    XCTAssertTrue(model.notificationsEnabled)
    XCTAssertTrue(prefs.bool(forKey: "notificationsEnabled"))
    XCTAssertEqual(client.pushRegistrations, ["tok-1"])
}

func testMarkEnabledFalseUnregistersToken() async {
    let (model, client, prefs) = makeModelP()
    await model.applyPushToken("tok-1")
    await model.markNotificationsEnabled(true)
    await model.markNotificationsEnabled(false)
    XCTAssertFalse(model.notificationsEnabled)
    XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
    XCTAssertEqual(client.pushUnregistrations, ["tok-1"])
}

func testReRegisterAfterWelcomeWhenEnabled() async {
    let (model, client, _) = makeModelP()
    await model.applyPushToken("tok-1")
    await model.markNotificationsEnabled(true)   // 1. kayıt
    await model.reRegisterPushIfNeeded()          // 2. kayıt (relay restart senaryosu)
    XCTAssertEqual(client.pushRegistrations, ["tok-1", "tok-1"])
}
```

- [ ] **Step 2: Testleri koştur, fail olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `prefs` parametresi ve yeni metotlar yok.

- [ ] **Step 3: AppModel'e state + init parametresi ekle**

`AppModel.swift` — property bloğuna (mevcut `startState` satırından sonra) ekle:

```swift
    public private(set) var notificationsEnabled: Bool
    public private(set) var notificationAuthStatus: NotificationAuthStatus = .notDetermined
    public weak var pushControl: (any PushControlling)?
```

Özel alanlara ekle:

```swift
    private let prefs: any PreferenceStore
    private var latestPushToken: String?
    private static let notificationsKey = "notificationsEnabled"
```

`init`'i güncelle:

```swift
    public init(client: any RelayClienting, store: any SecureStore, prefs: any PreferenceStore = UserDefaultsPreferenceStore()) {
        self.client = client
        self.store = store
        self.prefs = prefs
        self.isPaired = store.read() != nil
        self.notificationsEnabled = prefs.bool(forKey: Self.notificationsKey)
    }
```

- [ ] **Step 4: Push metotlarını ekle**

`AppModel.swift` — `registerPush(deviceToken:)`'in bulunduğu bölüme ekle:

```swift
    public func applyPushToken(_ hex: String) async {
        latestPushToken = hex
        if notificationsEnabled { await client.registerPush(deviceToken: hex) }
    }

    public func setNotificationAuthStatus(_ status: NotificationAuthStatus) {
        notificationAuthStatus = status
    }

    public func markNotificationsEnabled(_ on: Bool) async {
        notificationsEnabled = on
        prefs.set(on, forKey: Self.notificationsKey)
        guard let token = latestPushToken else { return }
        if on { await client.registerPush(deviceToken: token) }
        else { await client.unregisterPush(deviceToken: token) }
    }

    public func enableNotifications() async -> EnableResult {
        await pushControl?.enable() ?? .declined
    }

    public func disableNotifications() async {
        await pushControl?.disable()
    }

    public func reRegisterPushIfNeeded() async {
        guard notificationsEnabled, let token = latestPushToken else { return }
        await client.registerPush(deviceToken: token)
    }
```

- [ ] **Step 5: Welcome sonrası re-register'ı consume döngüsüne bağla**

`AppModel.swift` `start()` içindeki consume döngüsünde `.message` case'ini güncelle:

```swift
                case .message(let message):
                    self.handle(message)
                    if case .welcome = message { await self.reRegisterPushIfNeeded() }
```

- [ ] **Step 6: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS.

- [ ] **Step 7: Tüm Kit testleri**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: AppModel push state, toggle persistence ve welcome re-register"
```

---

## Task 5: PushCoordinator

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PushNotifications.swift` (dosyaya `PushCoordinator` eklenir)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PushCoordinatorTests.swift`

**Interfaces:**
- Consumes: `NotificationAuthorizing`, `RemoteRegistering`, `AppModel` (setNotificationAuthStatus/applyPushToken/markNotificationsEnabled), `EnableResult`, `NotificationAuthStatus`.
- Produces:
  - `@MainActor final class PushCoordinator: PushControlling`
  - `init(model: AppModel, authorizer: any NotificationAuthorizing, registrar: any RemoteRegistering)`
  - `func handleDeviceToken(_ hex: String) async` (AppDelegate çağırır)
  - `PushControlling` metotları: `onPairingSucceeded`, `enable`, `disable`, `refreshAuthStatus`

- [ ] **Step 1: Testleri yaz**

`PushCoordinatorTests.swift`'e ekle (fake'ler + testler):

```swift
final class FakeAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    var status: NotificationAuthStatus = .notDetermined
    var grantResult = true
    private(set) var requestCount = 0
    func authorizationStatus() async -> NotificationAuthStatus { status }
    func requestAuthorization() async -> Bool { requestCount += 1; return grantResult }
}

@MainActor
final class FakeRegistrar: RemoteRegistering {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    func registerForRemoteNotifications() { registerCount += 1 }
    func unregisterForRemoteNotifications() { unregisterCount += 1 }
}

@MainActor
final class PushCoordinatorTests: XCTestCase {
    private func make() -> (AppModel, PushCoordinator, FakeAuthorizer, FakeRegistrar, FakeRelayClient) {
        let client = FakeRelayClient()
        let model = AppModel(client: client, store: InMemorySecureStore(), prefs: InMemoryPreferenceStore())
        let auth = FakeAuthorizer()
        let reg = FakeRegistrar()
        let coord = PushCoordinator(model: model, authorizer: auth, registrar: reg)
        model.pushControl = coord
        return (model, coord, auth, reg, client)
    }

    func testEnableWhenNotDeterminedRequestsAndRegisters() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .notDetermined; auth.grantResult = true
        let result = await coord.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(auth.requestCount, 1)
        XCTAssertEqual(reg.registerCount, 1)
        XCTAssertTrue(model.notificationsEnabled)
        XCTAssertEqual(model.notificationAuthStatus, .authorized)
    }

    func testEnableWhenDeniedReturnsNeedsSettings() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .denied
        let result = await coord.enable()
        XCTAssertEqual(result, .needsSettings)
        XCTAssertEqual(reg.registerCount, 0)
        XCTAssertFalse(model.notificationsEnabled)
    }

    func testEnableWhenAuthorizedRegistersWithoutPrompt() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .authorized
        let result = await coord.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(auth.requestCount, 0)
        XCTAssertEqual(reg.registerCount, 1)
        XCTAssertTrue(model.notificationsEnabled)
    }

    func testRequestDeclinedReturnsDeclined() async {
        let (model, coord, auth, _, _) = make()
        auth.status = .notDetermined; auth.grantResult = false
        let result = await coord.enable()
        XCTAssertEqual(result, .declined)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(model.notificationAuthStatus, .denied)
    }

    func testDisableMarksModelAndUnregisters() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .authorized
        _ = await coord.enable()
        await coord.disable()
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(reg.unregisterCount, 1)
    }

    func testOnPairingSucceededRequestsOnlyWhenNotDetermined() async {
        let (_, coord, auth, reg, _) = make()
        auth.status = .authorized
        await coord.onPairingSucceeded()
        XCTAssertEqual(auth.requestCount, 0)   // notDetermined değil → prompt yok
        XCTAssertEqual(reg.registerCount, 0)

        auth.status = .notDetermined; auth.grantResult = true
        await coord.onPairingSucceeded()
        XCTAssertEqual(auth.requestCount, 1)
        XCTAssertEqual(reg.registerCount, 1)
    }

    func testHandleDeviceTokenForwardsToModelAndRegisters() async {
        let (model, coord, auth, _, client) = make()
        auth.status = .authorized
        _ = await coord.enable()               // enabled + token yok → kayıt tetiklenmez
        XCTAssertTrue(client.pushRegistrations.isEmpty)
        await coord.handleDeviceToken("tok-xyz")   // token geldi + enabled → registerPush
        XCTAssertEqual(model.notificationAuthStatus, .authorized)
        XCTAssertEqual(client.pushRegistrations, ["tok-xyz"])
    }
}
```

- [ ] **Step 2: Testleri koştur, fail olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PushCoordinatorTests`
Expected: FAIL — `PushCoordinator` yok.

- [ ] **Step 3: `PushCoordinator`'ı `PushNotifications.swift` sonuna ekle**

```swift
@MainActor
public final class PushCoordinator: PushControlling {
    private let model: AppModel
    private let authorizer: any NotificationAuthorizing
    private let registrar: any RemoteRegistering

    public init(model: AppModel, authorizer: any NotificationAuthorizing, registrar: any RemoteRegistering) {
        self.model = model
        self.authorizer = authorizer
        self.registrar = registrar
    }

    /// AppDelegate APNs token'ı verince çağrılır.
    public func handleDeviceToken(_ hex: String) async {
        await model.applyPushToken(hex)
    }

    public func refreshAuthStatus() async {
        model.setNotificationAuthStatus(await authorizer.authorizationStatus())
    }

    public func onPairingSucceeded() async {
        let status = await authorizer.authorizationStatus()
        model.setNotificationAuthStatus(status)
        guard status == .notDetermined else { return }
        _ = await requestAndRegister()
    }

    public func enable() async -> EnableResult {
        let status = await authorizer.authorizationStatus()
        model.setNotificationAuthStatus(status)
        switch status {
        case .notDetermined:
            return await requestAndRegister()
        case .denied:
            return .needsSettings
        case .authorized:
            registrar.registerForRemoteNotifications()
            await model.markNotificationsEnabled(true)
            return .enabled
        }
    }

    public func disable() async {
        await model.markNotificationsEnabled(false)
        registrar.unregisterForRemoteNotifications()
    }

    private func requestAndRegister() async -> EnableResult {
        let granted = await authorizer.requestAuthorization()
        guard granted else {
            model.setNotificationAuthStatus(.denied)
            return .declined
        }
        model.setNotificationAuthStatus(.authorized)
        registrar.registerForRemoteNotifications()
        await model.markNotificationsEnabled(true)
        return .enabled
    }
}
```

- [ ] **Step 4: Testleri koştur, geçtiğini doğrula**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PushCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Tüm Kit testleri**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PushNotifications.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PushCoordinatorTests.swift
git commit -m "mobile: PushCoordinator izin/kayıt orkestrasyonu + testleri"
```

---

## Task 6: App katmanı — sistem sarmalayıcıları, AppDelegate, composition

**Files:**
- Create: `LumiMobile/App/PushSystem.swift`
- Modify: `LumiMobile/App/LumiMobileApp.swift`

**Interfaces:**
- Consumes: `PushCoordinator`, `NotificationAuthorizing`, `RemoteRegistering`, `AppModel.pushControl`.
- Produces: `SystemNotificationAuthorizer`, `SystemRemoteRegistrar`, `AppDelegate` (coordinator'ı APNs callback'lerine bağlar).
- Not: App katmanı unit test edilmez (ince UIKit glue). Doğrulama derleme + manuel.

- [ ] **Step 1: `PushSystem.swift`'i oluştur**

```swift
import UIKit
import UserNotifications
import LumiMobileKit

/// UNUserNotificationCenter sarmalayıcısı (Kit protokolünün prod implementasyonu).
struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func authorizationStatus() async -> NotificationAuthStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

/// UIApplication sarmalayıcısı.
@MainActor
struct SystemRemoteRegistrar: RemoteRegistering {
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
    func unregisterForRemoteNotifications() { UIApplication.shared.unregisterForRemoteNotifications() }
}

/// APNs callback'lerini PushCoordinator'a köprüler.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var coordinator: PushCoordinator?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await coordinator?.handleDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs kayıt başarısız: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 2: `LumiMobileApp.swift`'i güncelle (adaptor + composition)**

```swift
import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let coordinator: PushCoordinator

    init() {
        let model = AppModel(client: RelayClient(), store: KeychainStore())
        let coordinator = PushCoordinator(
            model: model,
            authorizer: SystemNotificationAuthorizer(),
            registrar: SystemRemoteRegistrar()
        )
        model.pushControl = coordinator
        _model = State(initialValue: model)
        self.coordinator = coordinator
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    appDelegate.coordinator = coordinator
                    await coordinator.refreshAuthStatus()
                    await model.start()
                }
                .onOpenURL { url in
                    Task {
                        if await model.pair(from: url.absoluteString) {
                            await coordinator.onPairingSucceeded()
                        }
                    }
                }
        }
    }
}
```

- [ ] **Step 3: PairingView'daki eşleştirme başarısında da tetikle**

`PairingView.swift`'te `model.pair(from:)` çağrısını bul; başarılıysa coordinator'a haber vermek gerekir. PairingView `AppModel`'e erişir ama coordinator'a erişmez. Bu yüzden tetiklemeyi **AppModel** üzerinden yap: `AppModel.pair`'in sonunda `pushControl`'ü çağır. `AppModel.swift`'te `pair` metodunun `return true`'dan hemen önce ekle:

```swift
        await pushControl?.onPairingSucceeded()
```

Ve `LumiMobileApp.onOpenURL`'deki fazladan `await coordinator.onPairingSucceeded()` satırını kaldır (artık `pair` içinde tetikleniyor; çift tetik olmasın):

```swift
                .onOpenURL { url in
                    Task { await model.pair(from: url.absoluteString) }
                }
```

- [ ] **Step 4: Xcode projesini üret ve derle**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (Entitlement Task 8'de eklenecek; `CODE_SIGNING_ALLOWED=NO` ile imzasız derleme yeterli.)

- [ ] **Step 5: Kit testlerini bir daha koştur (pair değişikliği regresyon yaratmasın)**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: PASS. (Not: `pair` artık `pushControl?.onPairingSucceeded()` çağırıyor; testlerde `pushControl` nil → no-op.)

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/App/PushSystem.swift LumiMobile/App/LumiMobileApp.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift
git commit -m "mobile: APNs sistem sarmalayıcıları, AppDelegate ve composition wiring"
```

---

## Task 7: Toggle UI (gearshape menüsü)

**Files:**
- Modify: `LumiMobile/App/SessionListView.swift:64-72`

**Interfaces:**
- Consumes: `AppModel.notificationsEnabled`, `AppModel.enableNotifications() -> EnableResult`, `AppModel.disableNotifications()`.
- Produces: kullanıcıya "Bildirimler" toggle'ı; `.needsSettings` → sistem Ayarlar'ı açar.

- [ ] **Step 1: gearshape menüsüne toggle ekle**

`SessionListView.swift` içindeki `gearshape` `Menu` içeriğini güncelle:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Bildirimler", isOn: Binding(
                            get: { model.notificationsEnabled },
                            set: { isOn in
                                Task {
                                    if isOn {
                                        if await model.enableNotifications() == .needsSettings,
                                           let url = URL(string: UIApplication.openSettingsURLString) {
                                            await UIApplication.shared.open(url)
                                        }
                                    } else {
                                        await model.disableNotifications()
                                    }
                                }
                            }
                        ))
                        Button("Eşleştirmeyi kaldır", role: .destructive) {
                            Task { await model.unpair() }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
```

`SessionListView.swift` üstünde `import UIKit` yoksa ekle (dosya `import SwiftUI` içeriyor; `UIApplication` için `import UIKit` gerekir).

- [ ] **Step 2: Derle**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add LumiMobile/App/SessionListView.swift
git commit -m "mobile: gearshape menüsünde Bildirimler toggle'ı (denied → Ayarlar)"
```

---

## Task 8: Entitlement + Push capability

**Files:**
- Create: `LumiMobile/App/LumiMobile.entitlements`
- Modify: `LumiMobile/project.yml`

**Interfaces:**
- Produces: uygulama `aps-environment` entitlement'ı taşır → `registerForRemoteNotifications()` gerçek cihazda token üretir.

- [ ] **Step 1: Entitlements dosyasını oluştur**

`LumiMobile/App/LumiMobile.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
</dict>
</plist>
```

Not: Dağıtım/TestFlight build'inde takım bu değeri `production` yapmalı (veya otomatik imzalama profile'a göre çözer). Yerel cihaz testi `development` (sandbox) kullanır.

- [ ] **Step 2: project.yml'e entitlements ayarını ekle**

`LumiMobile/project.yml` → `targets.LumiMobile.settings.base` altına ekle (mevcut `INFOPLIST_KEY_UILaunchScreen_Generation` satırının yanına):

```yaml
        CODE_SIGN_ENTITLEMENTS: App/LumiMobile.entitlements
```

- [ ] **Step 3: Projeyi üret ve imzasız derle**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED; üretilen projede `CODE_SIGN_ENTITLEMENTS = App/LumiMobile.entitlements` görünür.

- [ ] **Step 4: Commit**

```bash
git add LumiMobile/App/LumiMobile.entitlements LumiMobile/project.yml
git commit -m "mobile: Push Notifications entitlement (aps-environment) + project.yml"
```

---

## Task 9: Ops kurulumu ve manuel doğrulama (kod yok)

**Files:** yok — bu görev Apple portal + Railway + gerçek cihaz doğrulamasıdır.

**Interfaces:**
- Consumes: Task 1-8'in tamamı.
- Produces: uçtan uca çalışan push zinciri.

- [ ] **Step 1: Apple Developer portal**
  - App ID `com.lumi.LumiMobile` → Push Notifications capability'yi etkinleştir.
  - Keys → yeni **APNs Auth Key** (`.p8`) oluştur; **Key ID** ve **Team ID**'yi not al. `.p8` dosyasını güvenli sakla.

- [ ] **Step 2: Railway env var'ları (yerel/sandbox test için)**
  - `APNS_KEY_P8` = `.p8` içeriği (satır sonları `\n` ile; `index.ts` bunları geri çevirir).
  - `APNS_KEY_ID`, `APNS_TEAM_ID`.
  - `APNS_BUNDLE_ID` = `com.lumi.LumiMobile`.
  - `APNS_HOST` = `https://api.sandbox.push.apple.com` (development-imzalı build sandbox token üretir).
  - Relay'i yeniden başlat; log'da `push: APNs` görülmeli.

- [ ] **Step 3: Gerçek cihaz uçtan uca test**
  1. Xcode'dan (kendi Developer hesabınla imzalı) uygulamayı gerçek cihaza yükle.
  2. Mac'te Lumi ile eşleştir → bildirim izni prompt'u çıkmalı → izin ver.
  3. Relay log'unda `register_push` ve device token'ın geldiğini doğrula.
  4. Mac'te bir oturumu izin/soru bekleyecek duruma sok (`waiting-unseen`) → telefona bildirim gelmeli (title=repoName, body=summary).
  5. gearshape → Bildirimler toggle'ını KAPA → aynı geçiş artık push üretmemeli (relay log: `unregister_push`).
  6. Toggle'ı AÇ → izin authorized olduğundan prompt çıkmadan yeniden kayıt olmalı.

- [ ] **Step 4: Dağıtım build notu**
  - Takımın TestFlight/ad-hoc dağıtım build'i **production** token üretir → o dağıtım için relay `APNS_HOST=https://api.push.apple.com` (varsayılan) olmalı ve entitlement `production`. Yerel sandbox ve dağıtım production **aynı anda** aynı relay env'i ile çalışmaz; test ederken host'u build tipine göre ayarla.

---

## Self-Review Notları

- **Spec kapsamı:** §2 iOS istemci (Task 3-6), §3 iki tetikleyici (Task 6 pair + Task 7 toggle), §4 unregister_push (Task 1-2, 4-5), §5 entitlement/host (Task 8-9), §5.3 ops (Task 9), §7 test planı (her task'ın testleri + Task 9 manuel) — hepsi karşılanıyor.
- **Tip tutarlılığı:** `registerPush`/`unregisterPush`, `applyPushToken`, `markNotificationsEnabled`, `EnableResult`, `NotificationAuthStatus`, `PushControlling` adları tüm task'larda birebir aynı.
- **UIKit izolasyonu:** UIKit/UserNotifications yalnız App katmanında (`PushSystem.swift`, `SessionListView.swift`, `LumiMobileApp.swift`); Kit Foundation-only kalır → `swift test` çalışır.
