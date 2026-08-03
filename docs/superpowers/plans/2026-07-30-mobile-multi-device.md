# Lumi Mobile — Çoklu Cihaz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mobil uygulama birden fazla Mac'e aynı anda canlı bağlı kalsın; üstteki bir cihaz seçiciyle aralarında geçiş yapılsın, seçili olmayan cihazdaki bekleyen izin rozetle görünsün.

**Architecture:** Bugünkü tek-bağlantılı `AppModel`, per-bağlantı birimi `DeviceConnection`'a çıkarılır. Yeni ince `AppModel` koordinatörü `[DeviceConnection]` + `selectedDeviceId` tutar; her cihaz kendi `RelayClient`'ıyla bağımsız bağlanır. Kalıcılık tek-eşleşmeden çoklu-eşleşmeye (token başına Keychain girişi) geçer. Cihaz adı Mac'ten `snapshot.deviceName` ile gelir.

**Tech Stack:** Swift 6, SwiftUI (App target), SwiftPM (`LumiMobileKit`), `@Observable`, `AsyncStream`, XCTest.

## Global Constraints

- Swift 6 strict concurrency; servis→store `AsyncStream`, store→UI `@Observable`, **Combine yok**.
- Platform: iOS 17+ (App), Kit ayrıca macOS 14+ (testler Mac host'ta simülatörsüz koşar).
- `LumiMobileKit`'e UIKit/VisionKit bağımlılığı **giremez**.
- Persistence uyumluluğu: eski tek-eşleşme Keychain girişi (`account = "default"`) **kayıpsız migrate** edilir.
- Spec bağlayıcı: `docs/superpowers/specs/2026-07-30-mobile-multi-device-design.md`. Push ve otomatik-geçiş **kapsam dışı**.
- Gelen decode toleranslı kalır: bilinmeyen/eksik alan akışı kırmaz (`decodeIfPresent`).
- Kit testleri: `cd LumiMobile/LumiMobileKit && swift test`. Mac tarafı: `cd LumiPackages && swift test`.

---

## File Structure

**Mac tarafı (Task 1):**
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift` — `deviceName` alanı.
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift:233` — cihaz adını geçir.
- Modify: `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift` — test.
- Modify: `docs/spec/50-remote-protocol.md` — snapshot payload'a `deviceName`.

**Mobil Kit:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` — `Snapshot.deviceName` (Task 2).
- Rename+Modify: `AppModel.swift` → `DeviceConnection.swift` (Task 3).
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — koordinatör (Task 4).
- Modify: `Pairing.swift` — `SecureStore` çoklu giriş + `InMemorySecureStore` + `KeychainStore` (Task 4).
- Rename+Modify: `Tests/.../AppModelTests.swift` → `DeviceConnectionTests.swift` (Task 3).
- Create: `Tests/.../AppModelTests.swift` — koordinatör testleri (Task 4).
- Modify: `Tests/.../PairingTests.swift` — çoklu-giriş store testleri (Task 4).
- Modify: `Tests/.../ProtocolTests.swift` — `deviceName` decode (Task 2).

**App target (Task 5):**
- Create: `LumiMobile/App/DeviceBarView.swift`.
- Modify: `RootView.swift`, `SessionListView.swift`, `SessionDetailView.swift`, `NewSessionView.swift`, `PairingView.swift`, `LumiMobileApp.swift`.

---

## Task 1: Mac tarafı `deviceName` yayını + spec

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift:6-31`
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift:233-235`
- Test: `LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift`
- Modify: `docs/spec/50-remote-protocol.md:45-60`

**Interfaces:**
- Produces: `SnapshotBuilder.snapshot(terminals:repos:personas:awaitingDecision:deviceName:)` snapshot dict'ine `"deviceName": String` ekler (yalnız non-nil ise). Mobil bunu `snapshot.deviceName` olarak okur.

- [ ] **Step 1: Failing test yaz** — `SnapshotBuilderTests.swift` içine ekle:

```swift
func testSnapshotIncludesDeviceNameWhenProvided() throws {
    let m = meta()
    let snap = SnapshotBuilder.snapshot(
        terminals: [m], repos: [], personas: [], deviceName: "Berkant’s MacBook Pro")
    XCTAssertEqual(snap["deviceName"] as? String, "Berkant’s MacBook Pro")
}

func testSnapshotOmitsDeviceNameWhenNil() throws {
    let m = meta()
    let snap = SnapshotBuilder.snapshot(terminals: [m], repos: [], personas: [])
    XCTAssertNil(snap["deviceName"])
}
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu gör**

Run: `cd LumiPackages && swift test --filter SnapshotBuilderTests`
Expected: FAIL — `snapshot(...)` çağrısı `deviceName:` argümanını tanımıyor (compile error).

- [ ] **Step 3: `SnapshotBuilder.snapshot`'a parametre ekle** — `SnapshotBuilder.swift`:

`static func snapshot(` imzasına son parametreyi ekle ve return dict'ini güncelle:

```swift
    static func snapshot(
        terminals: [TerminalMeta],
        repos: [Repo],
        personas: [Persona],
        awaitingDecision: [TerminalID: Bool] = [:],
        deviceName: String? = nil
    ) -> [String: Any] {
```

`return [ ... ]` bloğunu şununla değiştir:

```swift
        var result: [String: Any] = [
            "sessions": sessions,
            "repos": repos.map { ["name": $0.name, "path": $0.path] },
            "personas": personas.map { ["id": $0.id, "label": $0.label] },
        ]
        if let deviceName { result["deviceName"] = deviceName }
        return result
```

- [ ] **Step 4: Testi çalıştır, geçtiğini gör**

Run: `cd LumiPackages && swift test --filter SnapshotBuilderTests`
Expected: PASS

- [ ] **Step 5: `RemoteService.sendSnapshot`'ta cihaz adını geçir** — `RemoteService.swift:233`:

```swift
        let payload = SnapshotBuilder.snapshot(
            terminals: terminal.terminals, repos: repoList, personas: personaList,
            awaitingDecision: awaitingDecision,
            deviceName: Host.current().localizedName)
```

- [ ] **Step 6: Spec'i güncelle** — `docs/spec/50-remote-protocol.md`, snapshot payload JSON bloğuna (satır ~47-58) `personas` satırından sonra ekle:

```
  "deviceName": "<Mac'in yerel adı, opsiyonel>"
```

ve JSON bloğunun altındaki açıklamalara bir satır ekle:

```
`deviceName` yalnızca Mac gönderdiğinde bulunur (`Host.current().localizedName`); telefon çoklu-cihaz seçicisinde etiket olarak kullanır. Yoksa telefon relay URL host'undan bir yer tutucu türetir.
```

- [ ] **Step 7: Tüm Mac testlerini çalıştır**

Run: `cd LumiPackages && swift test 2>&1 | tail -5`
Expected: tüm testler PASS (mevcut `testSnapshotShape` `deviceName` beklemediği için etkilenmez — non-nil değilse alan yok).

- [ ] **Step 8: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift LumiPackages/Sources/LumiRemote/RemoteService.swift LumiPackages/Tests/LumiRemoteTests/SnapshotBuilderTests.swift docs/spec/50-remote-protocol.md
git commit -m "remote: snapshot'a deviceName ekle (çoklu-cihaz etiketi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Mobil — `Snapshot.deviceName` decode

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift:88-98`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: Task 1'in gönderdiği `snapshot.deviceName`.
- Produces: `Snapshot.deviceName: String?` (varsayılan `nil`). `Snapshot.init(sessions:repos:personas:deviceName:)`.

- [ ] **Step 1: Failing test yaz** — `ProtocolTests.swift` içine ekle:

```swift
func testDecodeSnapshotWithDeviceName() {
    let frame = """
    {"v":1,"type":"snapshot","payload":{
      "sessions":[],"repos":[],"personas":[],"deviceName":"İş Mac"}}
    """
    guard case .snapshot(let snap)? = PhoneProtocol.decodeServerMessage(frame) else {
        return XCTFail("snapshot decode edilmeliydi")
    }
    XCTAssertEqual(snap.deviceName, "İş Mac")
}

func testDecodeSnapshotWithoutDeviceNameIsNil() {
    let frame = #"{"v":1,"type":"snapshot","payload":{"sessions":[],"repos":[],"personas":[]}}"#
    guard case .snapshot(let snap)? = PhoneProtocol.decodeServerMessage(frame) else {
        return XCTFail("snapshot decode edilmeliydi")
    }
    XCTAssertNil(snap.deviceName)
}
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: FAIL — `Snapshot` `deviceName` üyesine sahip değil (compile error).

- [ ] **Step 3: `Snapshot`'a `deviceName` ekle** — `Models.swift`, `Snapshot` struct'ını değiştir:

```swift
public struct Snapshot: Decodable, Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let repos: [Repo]
    public let personas: [Persona]
    public let deviceName: String?

    public init(sessions: [SessionSummary], repos: [Repo], personas: [Persona],
                deviceName: String? = nil) {
        self.sessions = sessions
        self.repos = repos
        self.personas = personas
        self.deviceName = deviceName
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, repos, personas, deviceName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessions: try c.decode([SessionSummary].self, forKey: .sessions),
            repos: try c.decode([Repo].self, forKey: .repos),
            personas: try c.decode([Persona].self, forKey: .personas),
            deviceName: try c.decodeIfPresent(String.self, forKey: .deviceName)
        )
    }
}
```

(`PhoneProtocol` snapshot'ı `Decodable` üzerinden çözdüğü için ayrı değişiklik gerekmez.)

- [ ] **Step 4: Testi çalıştır, geçtiğini gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter ProtocolTests`
Expected: PASS

- [ ] **Step 5: Tüm Kit testlerini çalıştır** (mevcut `Snapshot(...)` çağrıları default `deviceName: nil` ile bozulmamalı)

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: tüm testler PASS.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/ProtocolTests.swift
git commit -m "mobile: Snapshot.deviceName decode (toleranslı)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `AppModel` → `DeviceConnection` (per-bağlantı birimi)

Bu task Kit'i yeniden derlenebilir bırakır ve Kit testleriyle doğrulanır. App target bu task sonunda **geçici olarak derlenmez** (Task 5'te düzeltilir) — Kit test sınırı `swift test`'tir.

**Files:**
- Rename: `AppModel.swift` → `DeviceConnection.swift`; class `AppModel` → `DeviceConnection`.
- Rename: `Tests/.../AppModelTests.swift` → `DeviceConnectionTests.swift`.

**Interfaces:**
- Consumes: `PairingInfo` (Task-öncesi mevcut), `RelayClienting`, `Snapshot.deviceName` (Task 2).
- Produces:
  - `DeviceConnection.init(client: any RelayClienting, pairing: PairingInfo)`
  - `DeviceConnection.id: String` (== `pairing.token`), `Identifiable`.
  - `DeviceConnection.displayName: String`
  - `DeviceConnection.deviceName: String?`
  - `DeviceConnection.pendingDecisionCount: Int`
  - `func start() async`, `func stop() async`
  - Mevcut per-oturum API'leri **değişmeden** kalır: `handle(_:)`, `orderedSessions`, `session(_:)`, `questionCard(for:)`, `sendText`, `pressKey`, `startSession`, `resetStartState`, `deleteSession`, `retrySend`, `requestHistory`, `registerPush`, ve `connection/macOnline/lastSeenAt/sessions/repos/personas/feeds/lastCommandError/startState` özellikleri.
  - **Kaldırılan:** `isPaired`, `pair(from:)`, `unpair()` (koordinatöre taşınır).

- [ ] **Step 1: Dosyayı yeniden adlandır**

```bash
cd /Users/balkan/Desktop/side-projects/Lumi
git mv LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/DeviceConnection.swift
git mv LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/DeviceConnectionTests.swift
```

- [ ] **Step 2: Sınıf başlığını, alanları ve init'i değiştir** — `DeviceConnection.swift`

`@Observable @MainActor public final class AppModel {` satırını değiştir:

```swift
@Observable @MainActor
public final class DeviceConnection: Identifiable {
    public let id: String
    public private(set) var deviceName: String?
```

`public private(set) var isPaired: Bool` satırını **sil**.

`private let client: any RelayClienting` satırından sonraki `private let store: any SecureStore` satırını **sil** ve yerine ekle:

```swift
    private let pairing: PairingInfo
```

Init'i (`public init(client:store:)`) tümüyle değiştir:

```swift
    public init(client: any RelayClienting, pairing: PairingInfo) {
        self.client = client
        self.pairing = pairing
        self.id = pairing.token
        self.deviceName = pairing.deviceName
    }

    public var displayName: String {
        deviceName ?? Self.fallbackName(pairing.relayUrl)
    }

    public var pendingDecisionCount: Int {
        decisionPending.values.filter { $0 }.count
    }

    private static func fallbackName(_ relayUrl: String) -> String {
        URL(string: relayUrl)?.host ?? "Cihaz"
    }
```

- [ ] **Step 3: `start()`'ı pairing tabanlı yap, `pair`/`unpair`'ı sil** — `DeviceConnection.swift`

`start()`'ın ilk satırını değiştir:

```swift
    public func start() async {
        guard consumeTask == nil else { return }
        let pairing = self.pairing
```

`start()`'ın gövdesinin geri kalanı (stream tüketimi + `await client.start(pairing: pairing)`) aynı kalır.

`pair(from:)` ve `unpair()` metotlarının **tümünü sil**. Yerlerine `stop()` ekle:

```swift
    public func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        await client.stop()
    }
```

- [ ] **Step 4: Snapshot'tan `deviceName` öğren** — `DeviceConnection.swift`, `private func apply(_ snapshot:)` başına ekle:

```swift
    private func apply(_ snapshot: Snapshot) {
        if let name = snapshot.deviceName { deviceName = name }
        sessions = snapshot.sessions
```

(geri kalanı aynı.)

- [ ] **Step 5: Test dosyasını uyarla** — `DeviceConnectionTests.swift`

`makeModel` yardımcısını değiştir (store parametresini kaldır):

```swift
@MainActor
private func makeConnection() -> (DeviceConnection, FakeRelayClient) {
    let client = FakeRelayClient()
    let pairing = PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")
    return (DeviceConnection(client: client, pairing: pairing), client)
}
```

Sınıf adını `final class AppModelTests` → `final class DeviceConnectionTests` yap.

Tüm test gövdelerinde `let (model, _, _) = makeModel()` → `let (model, _) = makeConnection()`, `let (model, client, _) = makeModel()` → `let (model, client) = makeConnection()` yap (üçüncü store elemanını kaldır). `makeModel(paired: false)` kullanan varsa o testi sil (aşağıda pair/unpair testleriyle birlikte).

`pair(from:)`, `unpair()` veya `isPaired` içeren **tüm test metotlarını sil** (bunlar Task 4'te koordinatörde test edilir).

- [ ] **Step 6: Yeni davranış testleri ekle** — `DeviceConnectionTests.swift`

```swift
func testIdEqualsToken() {
    let (model, _) = makeConnection()
    XCTAssertEqual(model.id, "0123456789abcdef")
}

func testDisplayNameFallsBackToRelayHostUntilLearned() {
    let (model, _) = makeConnection()
    XCTAssertEqual(model.displayName, "r.example")
}

func testDisplayNameUsesSnapshotDeviceName() {
    let (model, _) = makeConnection()
    model.handle(.snapshot(Snapshot(sessions: [], repos: [], personas: [], deviceName: "Ev Mini")))
    XCTAssertEqual(model.displayName, "Ev Mini")
    XCTAssertEqual(model.deviceName, "Ev Mini")
}

func testPendingDecisionCountReflectsAwaitingSessions() {
    let (model, _) = makeConnection()
    model.handle(.snapshot(Snapshot(sessions: [
        SessionSummary(id: "s1", repoPath: "/r/a", repoName: "a", status: .waitingUnseen, awaitingDecision: true),
        SessionSummary(id: "s2", repoPath: "/r/b", repoName: "b", status: .working, awaitingDecision: false),
    ], repos: [], personas: [])))
    XCTAssertEqual(model.pendingDecisionCount, 1)
}
```

- [ ] **Step 7: Kit testlerini çalıştır**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -8`
Expected: tüm testler PASS (App target'ı `swift test` derlemez — Kit yeşil olmalı).

- [ ] **Step 8: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/DeviceConnection.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/DeviceConnectionTests.swift
git commit -m "mobile: AppModel -> DeviceConnection (per-bağlantı birimi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Çoklu-eşleşme `SecureStore` + `AppModel` koordinatörü

**Files:**
- Modify: `Pairing.swift` — `SecureStore` protokolü + `InMemorySecureStore` + `KeychainStore`.
- Create: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — koordinatör.
- Test: `Tests/.../PairingTests.swift` (store) + Create `Tests/.../AppModelTests.swift` (koordinatör).

**Interfaces:**
- Consumes: `DeviceConnection` (Task 3), `Pairing.parse` (mevcut).
- Produces:
  - `SecureStore`: `func readAll() -> [PairingInfo]`, `func write(_:)` (token'a göre upsert), `func delete(token: String)`, `func clearAll()`.
  - `AppModel.init(store: any SecureStore, makeConnection: @escaping (PairingInfo) -> DeviceConnection)`
  - `AppModel.devices: [DeviceConnection]`, `AppModel.selectedDeviceId: String?`, `AppModel.selectedDevice: DeviceConnection?`, `AppModel.isPaired: Bool`
  - `func start() async`, `@discardableResult func addDevice(from: String) async -> Bool`, `func removeDevice(id: String) async`, `func selectDevice(id: String)`

- [ ] **Step 1: Store testlerini yaz (failing)** — `PairingTests.swift` içine ekle:

```swift
func testInMemoryStoreWritesReadsMultiple() {
    let store = InMemorySecureStore()
    store.write(PairingInfo(relayUrl: "wss://a", token: "aaaaaaaaaaaaaaaa"))
    store.write(PairingInfo(relayUrl: "wss://b", token: "bbbbbbbbbbbbbbbb"))
    XCTAssertEqual(store.readAll().map(\.token), ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
}

func testInMemoryStoreUpsertsByToken() {
    let store = InMemorySecureStore()
    store.write(PairingInfo(relayUrl: "wss://a", token: "aaaaaaaaaaaaaaaa"))
    store.write(PairingInfo(relayUrl: "wss://a2", token: "aaaaaaaaaaaaaaaa"))
    XCTAssertEqual(store.readAll().count, 1)
    XCTAssertEqual(store.readAll().first?.relayUrl, "wss://a2")
}

func testInMemoryStoreDeletesByToken() {
    let store = InMemorySecureStore()
    store.write(PairingInfo(relayUrl: "wss://a", token: "aaaaaaaaaaaaaaaa"))
    store.write(PairingInfo(relayUrl: "wss://b", token: "bbbbbbbbbbbbbbbb"))
    store.delete(token: "aaaaaaaaaaaaaaaa")
    XCTAssertEqual(store.readAll().map(\.token), ["bbbbbbbbbbbbbbbb"])
}

func testInMemoryStoreClearAll() {
    let store = InMemorySecureStore()
    store.write(PairingInfo(relayUrl: "wss://a", token: "aaaaaaaaaaaaaaaa"))
    store.clearAll()
    XCTAssertTrue(store.readAll().isEmpty)
}
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PairingTests`
Expected: FAIL — `readAll`/`delete(token:)`/`clearAll` yok (compile error).

- [ ] **Step 3: `SecureStore` protokolünü ve `InMemorySecureStore`'u değiştir** — `Pairing.swift`

`SecureStore` protokolünü değiştir:

```swift
/// Eşleştirme bilgilerinin güvenli saklanması (token başına bir giriş).
/// Üretimde Keychain; testte in-memory.
public protocol SecureStore: Sendable {
    func readAll() -> [PairingInfo]
    func write(_ info: PairingInfo)   // token'a göre upsert
    func delete(token: String)
    func clearAll()
}
```

`InMemorySecureStore`'u değiştir:

```swift
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PairingInfo] = []

    public init() {}

    public func readAll() -> [PairingInfo] { lock.withLock { stored } }

    public func write(_ info: PairingInfo) {
        lock.withLock {
            if let i = stored.firstIndex(where: { $0.token == info.token }) {
                stored[i] = info
            } else {
                stored.append(info)
            }
        }
    }

    public func delete(token: String) {
        lock.withLock { stored.removeAll { $0.token == token } }
    }

    public func clearAll() { lock.withLock { stored.removeAll() } }
}
```

- [ ] **Step 4: `KeychainStore`'u çoklu girişe + legacy migration'a çevir** — `Pairing.swift`

`KeychainStore`'u tümüyle değiştir:

```swift
/// kSecClassGenericPassword altında token başına bir kayıt (account = token).
/// İnce I/O katmanı — birim testi yok; çoklu-cihaz davranışı koordinatör testleriyle,
/// legacy migration ise Task 5'in gerçek-cihaz doğrulamasıyla kapsanır.
public final class KeychainStore: SecureStore {
    private let service = "com.lumi.LumiMobile.pairing"
    private let legacyAccount = "default"

    public init() {}

    public func readAll() -> [PairingInfo] {
        migrateLegacyIfNeeded()
        var query = serviceQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> PairingInfo? in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return decode(data)
        }
    }

    public func write(_ info: PairingInfo) {
        guard let data = encode(info) else { return }
        var query = accountQuery(info.token)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func delete(token: String) {
        SecItemDelete(accountQuery(token) as CFDictionary)
    }

    public func clearAll() {
        SecItemDelete(serviceQuery() as CFDictionary)
    }

    /// Eski tek-eşleşme (account="default") kaydını token-account şemasına taşır.
    private func migrateLegacyIfNeeded() {
        var query = accountQuery(legacyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let info = decode(data) else { return }
        write(info)                                   // token-account altına yaz
        SecItemDelete(accountQuery(legacyAccount) as CFDictionary)  // eskiyi sil
    }

    private func encode(_ info: PairingInfo) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["relayUrl": info.relayUrl, "token": info.token])
    }

    private func decode(_ data: Data) -> PairingInfo? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let url = dict["relayUrl"], let token = dict["token"] else { return nil }
        return PairingInfo(relayUrl: url, token: token)
    }

    private func serviceQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    private func accountQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
```

- [ ] **Step 5: Store testlerini çalıştır, geçtiğini gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter PairingTests`
Expected: PASS

- [ ] **Step 6: Koordinatör testlerini yaz (failing)** — Create `Tests/.../AppModelTests.swift`:

```swift
import XCTest
@testable import LumiMobileKit

@MainActor
private func makeAppModel() -> (AppModel, InMemorySecureStore) {
    let store = InMemorySecureStore()
    let model = AppModel(store: store,
                         makeConnection: { DeviceConnection(client: FakeRelayClient(), pairing: $0) })
    return (model, store)
}

private let pairA = "lumi-remote://pair?url=wss://a.example&token=aaaaaaaaaaaaaaaa"
private let pairB = "lumi-remote://pair?url=wss://b.example&token=bbbbbbbbbbbbbbbb"

@MainActor
final class AppModelTests: XCTestCase {

    func testAddDeviceParsesAppendsSelectsPersists() async {
        let (model, store) = makeAppModel()
        let ok = await model.addDevice(from: pairA)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.devices.map(\.id), ["aaaaaaaaaaaaaaaa"])
        XCTAssertEqual(model.selectedDeviceId, "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(store.readAll().map(\.token), ["aaaaaaaaaaaaaaaa"])
        XCTAssertTrue(model.isPaired)
    }

    func testAddDeviceRejectsGarbage() async {
        let (model, _) = makeAppModel()
        let ok = await model.addDevice(from: "not a pairing url")
        XCTAssertFalse(ok)
        XCTAssertTrue(model.devices.isEmpty)
    }

    func testAddSameTokenDedupesAndSelects() async {
        let (model, _) = makeAppModel()
        _ = await model.addDevice(from: pairA)
        _ = await model.addDevice(from: pairB)
        _ = await model.addDevice(from: pairA)   // tekrar A
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertEqual(model.selectedDeviceId, "aaaaaaaaaaaaaaaa")
    }

    func testRemoveDeviceDeletesAndReselects() async {
        let (model, store) = makeAppModel()
        _ = await model.addDevice(from: pairA)
        _ = await model.addDevice(from: pairB)   // seçili = B
        await model.removeDevice(id: "bbbbbbbbbbbbbbbb")
        XCTAssertEqual(model.devices.map(\.id), ["aaaaaaaaaaaaaaaa"])
        XCTAssertEqual(model.selectedDeviceId, "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(store.readAll().map(\.token), ["aaaaaaaaaaaaaaaa"])
    }

    func testRemoveLastDeviceLeavesUnpaired() async {
        let (model, _) = makeAppModel()
        _ = await model.addDevice(from: pairA)
        await model.removeDevice(id: "aaaaaaaaaaaaaaaa")
        XCTAssertFalse(model.isPaired)
        XCTAssertNil(model.selectedDeviceId)
        XCTAssertNil(model.selectedDevice)
    }

    func testSelectDevice() async {
        let (model, _) = makeAppModel()
        _ = await model.addDevice(from: pairA)
        _ = await model.addDevice(from: pairB)
        model.selectDevice(id: "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(model.selectedDevice?.id, "aaaaaaaaaaaaaaaa")
    }

    func testInitRestoresDevicesFromStore() {
        let store = InMemorySecureStore()
        store.write(PairingInfo(relayUrl: "wss://a.example", token: "aaaaaaaaaaaaaaaa"))
        store.write(PairingInfo(relayUrl: "wss://b.example", token: "bbbbbbbbbbbbbbbb"))
        let model = AppModel(store: store,
                             makeConnection: { DeviceConnection(client: FakeRelayClient(), pairing: $0) })
        XCTAssertEqual(model.devices.map(\.id), ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
        XCTAssertEqual(model.selectedDeviceId, "aaaaaaaaaaaaaaaa")
    }
}
```

`FakeRelayClient` `DeviceConnectionTests.swift`'te tanımlı; aynı test hedefinde olduğu için erişilebilir.

- [ ] **Step 7: Testi çalıştır, başarısız olduğunu gör**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter AppModelTests`
Expected: FAIL — `AppModel` (koordinatör) yok (compile error).

- [ ] **Step 8: Koordinatörü yaz** — Create `Sources/.../AppModel.swift`:

```swift
import Foundation
import Observation

/// Çoklu cihaz koordinatörü: her eşleşme için bir DeviceConnection tutar,
/// hepsini paralel bağlar, seçili cihazı yönetir (tasarım 2026-07-30).
@Observable @MainActor
public final class AppModel {
    public private(set) var devices: [DeviceConnection] = []
    public private(set) var selectedDeviceId: String?

    private let store: any SecureStore
    private let makeConnection: (PairingInfo) -> DeviceConnection

    public init(store: any SecureStore,
                makeConnection: @escaping (PairingInfo) -> DeviceConnection) {
        self.store = store
        self.makeConnection = makeConnection
        for info in store.readAll() {
            devices.append(makeConnection(info))
        }
        selectedDeviceId = devices.first?.id
    }

    public var isPaired: Bool { !devices.isEmpty }

    public var selectedDevice: DeviceConnection? {
        guard let id = selectedDeviceId else { return nil }
        return devices.first { $0.id == id }
    }

    /// Açılışta tüm cihazları paralel bağlar.
    public func start() async {
        for device in devices { await device.start() }
    }

    @discardableResult
    public func addDevice(from string: String) async -> Bool {
        guard let info = Pairing.parse(string) else { return false }
        if let existing = devices.first(where: { $0.id == info.token }) {
            selectedDeviceId = existing.id
            return true
        }
        store.write(info)
        let device = makeConnection(info)
        devices.append(device)
        selectedDeviceId = device.id
        await device.start()
        return true
    }

    public func removeDevice(id: String) async {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        let device = devices.remove(at: idx)
        await device.stop()
        store.delete(token: id)
        if selectedDeviceId == id {
            selectedDeviceId = devices.first?.id
        }
    }

    public func selectDevice(id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceId = id
    }
}
```

- [ ] **Step 9: Tüm Kit testlerini çalıştır**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -8`
Expected: tüm testler PASS.

- [ ] **Step 10: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Pairing.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/PairingTests.swift LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/AppModelTests.swift
git commit -m "mobile: çoklu-eşleşme SecureStore + AppModel koordinatörü

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: App UI — cihaz barı + view'ları yeni tiplere bağla

Bu task App target'ı yeniden derlenebilir yapar. Kit'te birim test yok (UI); doğrulama derleme + manuel simülatör.

**Files:**
- Create: `LumiMobile/App/DeviceBarView.swift`
- Modify: `RootView.swift`, `SessionListView.swift`, `SessionDetailView.swift`, `NewSessionView.swift`, `PairingView.swift`, `LumiMobileApp.swift`

**Interfaces:**
- Consumes: Task 4 `AppModel` (koordinatör), Task 3 `DeviceConnection`.

- [ ] **Step 1: `SessionDetailView`'ı `DeviceConnection`'a bağla** — `SessionDetailView.swift`

`let model: AppModel` → `let device: DeviceConnection`.
`SessionDetailView` gövdesindeki (satır 4-99, yalnız `struct SessionDetailView`) **tüm `model.` geçişlerini `device.` yap**. Etkilenen çağrılar: `model.feeds`, `model.lastCommandError`, `model.questionCard(for:)`, `model.macOnline`, `model.pressKey`, `model.requestHistory`, `model.session`, `model.sendText`, `model.retrySend`. (`FeedEntryView`, `QuestionCardView` struct'ları `model` kullanmaz — dokunma.)

- [ ] **Step 2: `NewSessionView`'ı `DeviceConnection`'a bağla** — `NewSessionView.swift`

`let model: AppModel` → `let device: DeviceConnection`.
Gövdedeki tüm `model.` → `device.` yap. Etkilenen: `model.repos`, `model.personas`, `model.startState`, `model.resetStartState()`, `model.macOnline`, `model.startSession`.

- [ ] **Step 3: `PairingView`'ı koordinatöre bağla** — `PairingView.swift`

`let model: AppModel` satırından sonra ekle ve iki `model.pair(from:)` çağrısını `model.addDevice(from:)` yap. Sheet olarak kullanılınca kapanması için `onPaired` closure ekle:

```swift
struct PairingView: View {
    let model: AppModel
    var onPaired: (() -> Void)? = nil
    @State private var pastedLink = ""
    @State private var showError = false
```

`Button("Eşleştir")` gövdesini değiştir:

```swift
                    Button("Eşleştir") {
                        Task {
                            let ok = await model.addDevice(from: pastedLink)
                            showError = !ok
                            if ok { onPaired?() }
                        }
                    }
```

`scannerSection` içindeki QR closure'ını değiştir:

```swift
                QRScannerView { value in
                    Task {
                        let ok = await model.addDevice(from: value)
                        showError = !ok
                        if ok { onPaired?() }
                    }
                }
```

- [ ] **Step 4: `DeviceBarView` oluştur** — Create `LumiMobile/App/DeviceBarView.swift`:

```swift
import SwiftUI
import LumiMobileKit

/// Oturum listesinin üstündeki yatay cihaz seçici; her pill = ad + bağlantı noktası +
/// bekleyen-izin rozeti. Sonda `＋` ile yeni cihaz ekleme (tasarım 2026-07-30).
struct DeviceBarView: View {
    let model: AppModel
    @State private var showAdd = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.devices) { device in
                    DevicePill(
                        device: device,
                        isSelected: device.id == model.selectedDeviceId,
                        onTap: { model.selectDevice(id: device.id) },
                        onRemove: { Task { await model.removeDevice(id: device.id) } }
                    )
                }
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .accessibilityLabel("Cihaz ekle")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .sheet(isPresented: $showAdd) {
            PairingView(model: model, onPaired: { showAdd = false })
        }
    }
}

private struct DevicePill: View {
    let device: DeviceConnection
    let isSelected: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(device.displayName).font(.subheadline)
                if device.pendingDecisionCount > 0 {
                    Text("\(device.pendingDecisionCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Cihazı kaldır", role: .destructive, action: onRemove)
        }
    }

    private var dotColor: Color {
        switch device.connection {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        }
    }
}
```

- [ ] **Step 5: `SessionListView`'ı `DeviceConnection` + kaldır-closure'ına bağla** — `SessionListView.swift`

`let model: AppModel` → şununla değiştir:

```swift
    let device: DeviceConnection
    let onRemove: () -> Void
```

Gövdedeki oturum-içerik `model.` çağrılarını `device.` yap: `model.macOnline` (2 yer: offlineBanner koşulu ve connectionDot değil — dikkat), `model.orderedSessions` (2 yer), `model.lastSeenAt`, `model.connection`, `model.deleteSession`. `navigationDestination`'da `SessionDetailView(model: model, ...)` → `SessionDetailView(device: device, sessionId: sessionId)`. `sheet`'te `NewSessionView(model: model)` → `NewSessionView(device: device)`. `plus` butonunun `.disabled(!model.macOnline)` → `.disabled(!device.macOnline)`.

Gear menüsündeki unpair'ı değiştir:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Bu cihazı kaldır", role: .destructive) {
                            onRemove()
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
```

- [ ] **Step 6: `RootView`'ı çoklu-cihaz düzenine çevir** — `RootView.swift`:

```swift
import SwiftUI
import LumiMobileKit

struct RootView: View {
    let model: AppModel

    var body: some View {
        if let device = model.selectedDevice {
            VStack(spacing: 0) {
                DeviceBarView(model: model)
                SessionListView(
                    device: device,
                    onRemove: { Task { await model.removeDevice(id: device.id) } }
                )
                .id(device.id)   // cihaz değişince navigation state sıfırlanır
            }
        } else {
            PairingView(model: model)
        }
    }
}
```

(Step 5'te tanımlandığı gibi `SessionListView` yalnız `device` + `onRemove` alır; `model` almaz.)

- [ ] **Step 7: `LumiMobileApp`'ı koordinatör fabrikasıyla kur** — `LumiMobileApp.swift`:

```swift
import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @State private var model = AppModel(
        store: KeychainStore(),
        makeConnection: { DeviceConnection(client: RelayClient(), pairing: $0) }
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
                .onOpenURL { url in
                    Task { await model.addDevice(from: url.absoluteString) }
                }
        }
    }
}
```

- [ ] **Step 8: App target'ı derle**

Run:
```bash
cd /Users/balkan/Desktop/side-projects/Lumi/LumiMobile && \
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. (Şema adı farklıysa: `xcodebuild -project LumiMobile.xcodeproj -list` ile şemayı bul.)

- [ ] **Step 9: Kit testleri hâlâ yeşil mi (regresyon)**

Run: `cd LumiMobile/LumiMobileKit && swift test 2>&1 | tail -5`
Expected: tüm testler PASS.

- [ ] **Step 10: Commit**

```bash
git add LumiMobile/App/
git commit -m "mobile: çoklu-cihaz UI (cihaz barı + view'ları koordinatöre bağla)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 11: Manuel doğrulama (gerçek/simülatör)**

Simülatörde çalıştır (`swift run` mobil için yok — Xcode/simülatör). Doğrula:
1. İlk açılış eşleşmemişse `PairingView` görünür; bir Mac eşleştir → cihaz barı + oturum listesi.
2. `＋` ile ikinci Mac eşleştir → barda iki pill; ikisi de yeşil noktaya ulaşır (ikisi de canlı bağlı).
3. Seçili olmayan cihazda bir oturum izin bekleyince o pill'de turuncu rozet belirir; pill'e dokununca o cihaza geçilir ve izin kartı görünür.
4. Bir pill'in context menüsünden "Cihazı kaldır" → pill kaybolur, kalan cihaz seçili olur; uygulama yeniden başlatılınca kaldırılan cihaz geri gelmez (Keychain silindi).
5. **Legacy migration:** bu branch öncesi tek-eşleşmeli bir kurulumdan güncelleme senaryosu — mevcut eşleşme açılışta tek cihaz olarak görünmeli (varsa gerçek cihazda doğrula).

---

## Self-Review Notları

- **Spec kapsamı:** N canlı bağlantı (Task 3-4-5), cihaz barı + `＋` (Task 5), per-cihaz durum + rozet (Task 4-5), `deviceName` otomatik (Task 1-2-3), legacy migration (Task 4 + Task 5 manuel). Push ve otomatik-geçiş bilinçli kapsam dışı — plana alınmadı. ✓
- **Tip tutarlılığı:** `DeviceConnection.init(client:pairing:)`, `AppModel.init(store:makeConnection:)`, `SecureStore.readAll/write/delete(token:)/clearAll`, `SessionListView(device:onRemove:)`, `SessionDetailView(device:sessionId:)`, `NewSessionView(device:)`, `PairingView(model:onPaired:)` — tüm task'larda aynı imzalar. ✓
- **Öğrenilen `deviceName` kalıcılığı:** bilinçli olarak in-memory (YAGNI); açılışta henüz bağlanmamış cihaz relay-host yer tutucusu gösterir, bağlanınca gerçek ada geçer. `PairingInfo`'ya isim alanı eklenmedi. ✓
- **Compile sınırı:** Task 3 sonunda App target derlenmez ama Kit `swift test` yeşildir; Task 5 App'i onarır. ✓
