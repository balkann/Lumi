# Remote (orca terminal-mirror) — güncel main entegrasyonu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Orca'nın terminal-mirror remote mimarisini (`feat/remote-terminal-mirror` dalında hazır) güncel `upstream/main` (composition refactor'lı) üstüne, tek Lumi kuralı "kendi relay server'ını kullan" olacak şekilde yeniden entegre etmek.

**Architecture:** Yeni main artık `LumiAppCore` + `FeatureAssembly` deseni kullanıyor (parametre-drilling yok; store'lar `ShellContext` → `@Shell` environment'ından akıyor). Orca remote işinin çekirdek dosyaları (LumiKit modelleri/protokolleri, LumiRemote servisi, RelayServer TS, LumiMobile iOS) neredeyse aynen taşınır; wiring bu yeni desene uyarlanır: bir `RemoteFeatureAssembly`, `ShellContext`'e `remote: RemoteStore`, ve `SettingsTab.remote` + `RemoteSettingsTab`. Persona/Preset sistemi yeni main'den kaldırıldığı için remote'un persona bağımlılığı sökülür.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftPM çok-modüllü paket, SwiftTerm, TypeScript relay (ws), XcodeGen iOS app.

## Global Constraints

- **main'e commit YASAK** — tüm iş `feat/remote-orca-main` dalında (bu bilgisayardan Lumi main'e commit yasak).
- **Taban = `upstream/main` (c832d50).** Dal `feat/remote-orca-main` bu taban üzerine zaten açıldı.
- **Tek Lumi kuralı:** transport = Lumi'nin kendi relay server'ı (`RelayServer/`). Kalan her şey orca mimarisi.
- **Persistence uyumluluğu:** `~/.lumi` altındaki JSON/YAML formatları aynen okunur/yazılır; `remote.json` yeni dosya olarak eklenir.
- **Zorunlu mimari:** PTY→UI ack-tabanlı backpressure, render-crash izolasyonu, replay güvenliği korunur (tap deliver()'a eklenirken flow/ack yolu bozulmaz).
- Swift 6 `@MainActor` izolasyonu: `TerminalServicing` ve `RemoteService` ikisi de `@MainActor` — izolasyon hop'u gerekmez.
- Kaynak dal referansı: wholesale taşınan dosyalar `feat/remote-terminal-mirror:<path>` içeriğiyle birebir (aksi belirtilmedikçe).

---

### Task 1: Çekirdek yeni dosyaları taşı + Package.swift target'ları

Bu dosyalar main'de yok; çakışmasız eklenir. Wiring henüz yok, ama modüller derlenebilir olmalı (LumiRemote testleri hariç, onlar Task 3-4 sonrası).

**Files:**
- Create (LumiKit): `LumiPackages/Sources/LumiKit/Models/RemoteModels.swift`, `LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift`, `LumiPackages/Sources/LumiKit/Support/DiagLog.swift`
- Create (LumiRemote): `LumiPackages/Sources/LumiRemote/{RelayConnection,RemoteCommandHandler,RemoteConfigService,RemoteProtocol,RemoteService}.swift`
- Create (LumiState): `LumiPackages/Sources/LumiState/RemoteStore.swift`
- Create (LumiUI): `LumiPackages/Sources/LumiUI/Support/QRCodeRenderer.swift`
- Modify: `LumiPackages/Package.swift`

**Interfaces:**
- Produces: `LumiKit`: `RemoteConfig`, `RemoteConnectionState`, `RemoteEvent`, `SessionMeta`, `RemoteServicing`, `DiagLog`. `LumiRemote`: `RemoteService` (@MainActor final class, `RemoteServicing`), `RelayConnecting`/`RelayConnection`, `RemoteConfigService`, `RemoteProtocol`, `RemoteCommandHandler`. `LumiState`: `RemoteStore` (@Observable @MainActor).

- [ ] **Step 1: LumiKit çekirdek dosyalarını taşı**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
for f in \
  LumiPackages/Sources/LumiKit/Models/RemoteModels.swift \
  LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift \
  LumiPackages/Sources/LumiKit/Support/DiagLog.swift \
  LumiPackages/Sources/LumiRemote/RelayConnection.swift \
  LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift \
  LumiPackages/Sources/LumiRemote/RemoteConfigService.swift \
  LumiPackages/Sources/LumiRemote/RemoteProtocol.swift \
  LumiPackages/Sources/LumiRemote/RemoteService.swift \
  LumiPackages/Sources/LumiState/RemoteStore.swift \
  LumiPackages/Sources/LumiUI/Support/QRCodeRenderer.swift ; do
  git checkout feat/remote-terminal-mirror -- "$f"
done
```

- [ ] **Step 2: Package.swift'e LumiRemote target + product + test target ekle**

`products` dizisine (LumiUI'dan sonra):
```swift
        .library(name: "LumiRemote", targets: ["LumiRemote"]),
```
`targets` dizisine (LumiState target'ından sonra):
```swift
        .target(name: "LumiRemote", dependencies: ["LumiKit"]),
```
`LumiAppCore` target'ının dependencies'ine `"LumiRemote"` ekle (RemoteService'i assembly'de kurabilmek için):
```swift
        .target(name: "LumiAppCore", dependencies: ["LumiKit", "LumiTerminal", "LumiServices", "LumiState", "LumiRemote", "LumiUI"]),
```
Test target'larına ekle (LumiTestSupport'a bağla — fake'ler orada):
```swift
        .testTarget(name: "LumiRemoteTests", dependencies: ["LumiRemote", "LumiTestSupport"]),
```

- [ ] **Step 3: Sadece çekirdek modülleri derle (wiring/testler hariç)**

Run: `cd LumiPackages && swift build --target LumiRemote 2>&1 | tail -30`
Beklenen: Persona bağımlılığı yüzünden **HATA** — `RemoteCommandHandler`/`RemoteService` `PersonaServicing` bulamaz. Bu beklenen; Task 3 düzeltir. (Not: bu adımda `LumiKit`/`LumiState`/`LumiUI` derlenmeli; sadece `LumiRemote` persona yüzünden kırılır.)

- [ ] **Step 4: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Models/RemoteModels.swift \
  LumiPackages/Sources/LumiKit/Protocols/RemoteServicing.swift \
  LumiPackages/Sources/LumiKit/Support/DiagLog.swift \
  LumiPackages/Sources/LumiRemote LumiPackages/Sources/LumiState/RemoteStore.swift \
  LumiPackages/Sources/LumiUI/Support/QRCodeRenderer.swift LumiPackages/Package.swift
git commit -m "feat(remote): orca çekirdek dosyalarını güncel main'e taşı + LumiRemote target"
```

---

### Task 2: Persona bağımlılığını sök + TerminalEvent exhaustiveness

Yeni main'de Persona/Preset sistemi yok. Remote'un persona kullanımı yalnız `RemoteCommandHandler.startSession` içindeki `personaId` dalında; sök. Ayrıca `RemoteService.handleTerminalEvent` switch'i yeni case'lerle (`.providerChanged`, `.writeFailed`) exhaustive değil.

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`
- Modify: `LumiPackages/Sources/LumiRemote/RemoteService.swift`

**Interfaces:**
- Produces: `RemoteCommandHandler.init(terminal:)` (personas parametresi kaldırıldı). `RemoteService.init(paths:terminal:repos:connection:)` (personas kaldırıldı).

- [ ] **Step 1: RemoteCommandHandler — persona alanını/parametresini kaldır**

`RemoteCommandHandler.swift` içinde şu satırları SİL:
```swift
    private let personas: any PersonaServicing
    /// start_session persona yolunda agent CLI'ın açılması için beklenen süre.
    /// Bilinçli best-effort (tasarım kararı) — test edilebilirlik için enjekte.
    private let personaPromptDelay: Duration
```
`init`'i şu hale getir:
```swift
    init(terminal: any TerminalServicing) {
        self.terminal = terminal
    }
```

- [ ] **Step 2: RemoteCommandHandler — startSession'ı persona'sız yap**

`startSession` gövdesini şununla değiştir (personaId dalı kaldırıldı; her zaman `terminal.spawn`):
```swift
    private func startSession(_ payload: [String: Any], commandId: Any) async -> sending [String: Any] {
        let repoPath = payload["repoPath"] as? String ?? ""
        let prompt = payload["prompt"] as? String ?? ""
        do {
            let command = prompt.isEmpty ? "claude" : "claude " + shellQuoted(prompt)
            _ = try terminal.spawn(repoPath: repoPath, task: nil, command: command)
            return ["commandId": commandId, "ok": true]
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }
```

- [ ] **Step 3: RemoteService — persona alanını/parametresini kaldır**

`RemoteService.swift` içinde SİL:
```swift
    private let personas: any PersonaServicing
```
init parametrelerinden `personas: any PersonaServicing,` satırını ve `self.personas = personas` atamasını SİL. `commandHandler` kurulumunu şu yap:
```swift
        self.commandHandler = RemoteCommandHandler(terminal: terminal)
```
Yeni init imzası:
```swift
    public init(
        paths: LumiPaths,
        terminal: any TerminalServicing,
        repos: any RepoServicing,
        connection: (any RelayConnecting)? = nil
    ) {
```

- [ ] **Step 4: RemoteService — handleTerminalEvent exhaustiveness**

`handleTerminalEvent` içindeki ikinci `case` satırını genişlet (main'in 4 yeni case'i — `.providerChanged`, `.writeFailed`, `.stalled`, `.viewFocused` — ignore grubuna):
```swift
        case .titleChanged, .awaitingDecisionChanged, .bell, .providerChanged, .writeFailed, .stalled, .viewFocused:
            break
```

- [ ] **Step 5: Persona + exhaustiveness hatalarının gittiğini doğrula**

Run: `cd LumiPackages && swift build --target LumiRemote 2>&1 | tail -40`
Beklenen: LumiRemote HÂLÂ derlenmez — ama artık SADECE Task 3'ün eklemedikleri yüzünden: `TerminalServicing`'de `subscribeOutput`/`writeInput`/`serializeScrollback` yok + `LumiPaths`'te `remoteFile` yok. Çıktıda `PersonaServicing` ve `switch must be exhaustive` (TerminalEvent) hataları ARTIK OLMAMALI. Bu, Task 2'nin işini yaptığının kanıtı. (Tam LumiRemote derlemesi Task 3 sonrası gelir.)

- [ ] **Step 6: Commit**

```bash
git add LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift LumiPackages/Sources/LumiRemote/RemoteService.swift
git commit -m "refactor(remote): persona bağımlılığını sök (yeni main'de Preset yok) + TerminalEvent exhaustiveness"
```

---

### Task 3: TerminalServicing protokol tap'i + LumiPaths + TerminalSession/Manager

Additive değişiklikler; yeni `deliver()`'a uyarlanır.

**Files:**
- Modify: `LumiPackages/Sources/LumiKit/Protocols/TerminalServicing.swift`
- Modify: `LumiPackages/Sources/LumiKit/Support/LumiPaths.swift`
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift`
- Modify: `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift`

**Interfaces:**
- Produces: `TerminalSessionControlling` protokolüne `subscribeOutput(_:) -> AsyncStream<Data>`, `writeInput(_:to:)`, `serializeScrollback(_:) -> (data: Data, cols: Int, rows: Int)`. `LumiPaths.remoteFile: URL`.

- [ ] **Step 1: TerminalServicing protokolüne 3 üye ekle**

`TerminalSessionControlling` protokolü gövdesinin sonuna (`func events()`'ten sonra, `}` öncesi) ekle:
```swift

    // MARK: - Remote mirror

    /// Ham PTY bayt batch'leri — RemoteService uzak abone tüketicisi.
    /// Bilinmeyen id → boş/bitirilmiş stream.
    func subscribeOutput(_ id: TerminalID) -> AsyncStream<Data>

    /// Baytları PTY'ye yazar (mevcut input filter üzerinden). Bilinmeyen id → no-op.
    func writeInput(_ data: Data, to id: TerminalID)

    /// Tek atış scrollback snapshot: SwiftTerm buffer'ını UTF-8 Data olarak döker.
    /// Bilinmeyen id → (Data(), 0, 0).
    func serializeScrollback(_ id: TerminalID) -> (data: Data, cols: Int, rows: Int)
```
(Not: `TerminalServicing` `@MainActor` typealias olduğundan bu üyeler otomatik `@MainActor`.)

- [ ] **Step 2: LumiPaths'e remoteFile ekle**

`uiStateFile` satırının hemen altına:
```swift
    public var remoteFile: URL { configDir.appendingPathComponent("remote.json") }
```

- [ ] **Step 3: TerminalSession — remote broadcaster + tap + yardımcılar**

`private let pipeline: TerminalPipeline` civarındaki stored property'lerin yanına ekle:
```swift
    /// Ham PTY bayt batch'leri için broadcaster (remote mirror).
    private let remoteOutputBroadcaster = EventBroadcaster<Data>()
```
`deliver(_ batch:)` gövdesinde `presentation.feed(batch)` satırından SONRA tap ekle (ack/flow yolu değişmeden):
```swift
    private func deliver(_ batch: Data) {
        guard !isTerminated else { return }
        launchGate?.noteOutput()
        pipeline.watchdog.measureFeed { presentation.feed(batch) }
        remoteOutputBroadcaster.send(batch)
        if pipeline.flow.noteConsumed(batch.count) {
            pty.resumeReading()
        }
    }
```
Sınıfa remote API'leri ekle (uygun bir yere, örn. `write(_ data:)` yakınına):
```swift
    // MARK: - Remote mirror

    func subscribeRemoteOutput() -> AsyncStream<Data> {
        remoteOutputBroadcaster.stream()
    }

    func writeRemoteInput(_ data: Data) {
        write(data)
    }

    func serializeScrollback() -> (data: Data, cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (data: terminal.getBufferAsData(), cols: terminal.cols, rows: terminal.rows)
    }
```

- [ ] **Step 4: TerminalSession — test yardımcıları (RemoteTapTests için)**

RemoteTapTests `makeForTest()` + `injectFlushBatch(_:)` kullanıyor. **Önce yeni `TerminalSession.init` imzasını doğrula:**
Run: `git grep -n 'init(' LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift`
Sonra o imzaya uygun bir factory ekle (örnek — gerçek imzaya göre uyarla):
```swift
    // MARK: - Test yardımcıları (LumiTerminalTests)

    static func makeForTest() throws -> TerminalSession {
        // NOT: yeni init imzasına göre uyarla (repoPath/name/task/font vб.)
        try TerminalSession(/* güncel init parametreleri */)
    }

    func injectFlushBatch(_ data: Data) {
        deliver(data)
    }
```
Eğer yeni `init` @MainActor NSFont vб. gerektiriyorsa, `makeForTest`'i `@MainActor` yap.

- [ ] **Step 5: TerminalSessionManager — 3 protokol metodu**

`private func session(for id:)`'in üstüne ekle:
```swift
    // MARK: - Remote mirror

    public func subscribeOutput(_ id: TerminalID) -> AsyncStream<Data> {
        guard let s = session(for: id) else { return AsyncStream { $0.finish() } }
        return s.subscribeRemoteOutput()
    }

    public func writeInput(_ data: Data, to id: TerminalID) {
        session(for: id)?.writeRemoteInput(data)
    }

    public func serializeScrollback(_ id: TerminalID) -> (data: Data, cols: Int, rows: Int) {
        guard let s = session(for: id) else { return (Data(), 0, 0) }
        return s.serializeScrollback()
    }
```

- [ ] **Step 6: LumiTerminal + LumiKit derlensin**

Run: `cd LumiPackages && swift build --target LumiTerminal 2>&1 | tail -30`
Beklenen: PASS.

- [ ] **Step 7: Commit**

```bash
git add LumiPackages/Sources/LumiKit/Protocols/TerminalServicing.swift \
  LumiPackages/Sources/LumiKit/Support/LumiPaths.swift \
  LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift \
  LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift
git commit -m "feat(terminal): remote bayt-stream tap — subscribeOutput/writeInput/serializeScrollback"
```

---

### Task 4: Fake'leri güncelle (LumiTestSupport + varsa stub'lar)

Yeni `TerminalServicing` üyeleri her fake conformance'ını kırar. Fake'ler artık tek yerde: `LumiTestSupport`.

**Files:**
- Create (wholesale port): remote test dosyaları (aşağıda).
- Modify: `LumiPackages/Tests/LumiTestSupport/FakeTerminalService.swift`
- (Varsa) Modify: `TerminalServicing`'e conform eden diğer stub/fake'ler (derleme hatasından bulunur).

**Interfaces:**
- Consumes: Task 3'ün 3 yeni protokol üyesi.

- [ ] **Step 0: Remote test dosyalarını taşı (plan boşluğu — Task 1'de atlanmıştı)**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
rm -f LumiPackages/Tests/LumiRemoteTests/.gitkeep
git checkout feat/remote-terminal-mirror -- \
  LumiPackages/Tests/LumiKitTests/RemoteModelsTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RelayConnectionTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteConfigServiceTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteProtocolTests.swift \
  LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift \
  LumiPackages/Tests/LumiRemoteTests/TerminalWireTests.swift \
  LumiPackages/Tests/LumiStateTests/RemoteStoreTests.swift \
  LumiPackages/Tests/LumiTerminalTests/RemoteTapTests.swift
```
Not: Bu testler henüz derlenmeyebilir (RemoteServiceTests persona'sız init'e, RemoteTapTests yeni `makeForTest`'e bağlı) — derleme/uyum Task 8'de kapatılır. Bu adım sadece dosyaları getirir.

- [ ] **Step 1: FakeTerminalService'e 3 üye ekle**

`FakeTerminalService` gövdesinin sonuna ekle:
```swift
    // MARK: - Remote mirror

    private let remoteOutputBroadcaster = EventBroadcaster<Data>()

    public func subscribeOutput(_ id: TerminalID) -> AsyncStream<Data> {
        remoteOutputBroadcaster.stream()
    }

    public func writeInput(_ data: Data, to id: TerminalID) {}

    public func serializeScrollback(_ id: TerminalID) -> (data: Data, cols: Int, rows: Int) {
        (Data(), 0, 0)
    }
```

- [ ] **Step 2: Diğer conformance'ları bul ve aynısını uygula**

Run: `cd LumiPackages && swift build --build-tests 2>&1 | grep -iE "does not conform|TerminalServicing" | head`
Çıkan her dosyaya (örn. LumiUITests/LumiAppTests içi stub'lar) yukarıdaki 3 üyeyi ekle. `EventBroadcaster` importu için `import LumiKit` gerekebilir.

- [ ] **Step 3: Commit**

```bash
git add LumiPackages/Tests
git commit -m "test(support): fake TerminalServicing'e remote mirror üyeleri"
```

---

### Task 5: RemoteFeatureAssembly + composition kaydı

Yeni main deseni: `FeatureAssembly` + `AppComposition.live()` listesi + `AppContainer(assemblies:)`.

**Files:**
- Create: `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift`
- Modify: `LumiPackages/Sources/LumiAppCore/Composition/AppComposition.swift`

**Interfaces:**
- Consumes: `ServiceRegistry.{paths,terminal,repo}`, `RemoteService`, `RemoteStore`.
- Produces: `RemoteFeatureAssembly` (`FeatureAssembly`), `var remoteStore: RemoteStore` (Task 6 ShellContext'e verir).

- [ ] **Step 1: RemoteFeatureAssembly'yi yaz**

`LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift`:
```swift
import Foundation
import LumiKit
import LumiRemote
import LumiState

/// Remote (terminal-ayna) özelliği: RemoteService + RemoteStore kurar, config
/// etkinse relay'e bağlanır. bootstrapPhase.config — terminal (system) kurulduktan
/// sonra, ama repo/ui'dan önce başlaması yeterli.
@MainActor
final class RemoteFeatureAssembly: FeatureAssembly {
    let bootstrapPhase = BootstrapPhase.config

    private(set) var remoteStore: RemoteStore!
    private var remoteService: RemoteService!
    private var services: (any ServiceRegistry)!

    func build(services: any ServiceRegistry, shared: SharedStores) {
        self.services = services
        remoteService = RemoteService(
            paths: services.paths,
            terminal: services.terminal,
            repos: services.repo
        )
        remoteStore = RemoteStore(service: remoteService)
    }

    func start() async {
        // store event köprüsü + servis bağlantısı (config.enabled=false ise no-op).
        remoteStore.start()
        await remoteService.start()
    }

    func shutdown() async {
        remoteService.stop()
    }
}
```

- [ ] **Step 2: AppComposition.live()'a assembly'yi ekle**

`AppComposition.live()` içinde diğer assembly örneklerinin yanına:
```swift
        let remote = RemoteFeatureAssembly()
```
`AppContainer(... assemblies: [...])` dizisinin sonuna `remote` ekle:
```swift
            assemblies: [agentHooks, terminal, notifications, sessionSchedule, usage, repo, workspaceBoot, statusBar, remote]
```
`AppComposition` struct'ına `remote`'u sakla (Task 6'da ShellComposition'a verilecek). Struct alanlarına ekle:
```swift
    let remote: RemoteFeatureAssembly
```
ve `return AppComposition(...)` çağrısına `remote: remote,` ekle.

- [ ] **Step 3: LumiAppCore derlensin**

Run: `cd LumiPackages && swift build --target LumiAppCore 2>&1 | tail -30`
Beklenen: PASS (henüz ShellContext'e bağlanmadı; sadece assembly + kayıt).

- [ ] **Step 4: Commit**

```bash
git add LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift LumiPackages/Sources/LumiAppCore/Composition/AppComposition.swift
git commit -m "feat(app): RemoteFeatureAssembly + composition kaydı"
```

---

### Task 6: ShellContext'e RemoteStore + ShellComposition wiring

Store'u UI'a `@Shell` üzerinden ulaştırmak için `ShellContext`'e `remote: RemoteStore` eklenir.

**Files:**
- Modify: `LumiPackages/Sources/LumiUI/Shell/ShellContext.swift`
- Modify: `LumiPackages/Sources/LumiAppCore/Composition/ShellComposition.swift`

**Interfaces:**
- Consumes: `RemoteFeatureAssembly.remoteStore` (Task 5).
- Produces: `ShellContext.remote: RemoteStore` (views `shell.remote` ile erişir).

- [ ] **Step 1: ShellContext'e remote alanı + init parametresi**

`ShellContext` stored property'lerine ekle (örn. `settings` yanına):
```swift
    public let remote: RemoteStore
```
`public init(...)` parametre listesine `remote: RemoteStore,` ekle ve gövdede `self.remote = remote` ata. (`RemoteStore` LumiState'te; LumiUI zaten LumiState'e bağımlı — import gerekmez.)

- [ ] **Step 2: ShellComposition.make'e remote'u geçir**

`ShellComposition.make(...)` imzasına parametre ekle:
```swift
        remote: RemoteFeatureAssembly,
```
`ShellContext(...)` çağrısına ekle:
```swift
        remote: remote.remoteStore,
```

- [ ] **Step 3: AppComposition'daki ShellComposition.make çağrısını güncelle**

`AppComposition.live()` içindeki `ShellComposition.make(...)` çağrısına `remote: remote,` ekle (Task 5'te oluşturulan `remote` örneği).

- [ ] **Step 4: LumiUI + LumiAppCore derlensin**

Run: `cd LumiPackages && swift build --target LumiAppCore 2>&1 | tail -30`
Beklenen: PASS.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiUI/Shell/ShellContext.swift LumiPackages/Sources/LumiAppCore/Composition/ShellComposition.swift LumiPackages/Sources/LumiAppCore/Composition/AppComposition.swift
git commit -m "feat(app): ShellContext'e RemoteStore — @Shell ile UI erişimi"
```

---

### Task 7: Settings "Remote" sekmesi (RemoteSettingsTab)

Yeni Settings deseni: `SettingsTab` enum + parametresiz tab view'ı (`@Shell`'den okur).

**Files:**
- Modify: `LumiPackages/Sources/LumiUI/Settings/SettingsTab.swift`
- Create: `LumiPackages/Sources/LumiUI/Settings/Tabs/RemoteSettingsTab.swift`

**Interfaces:**
- Consumes: `ShellContext.remote` (Task 6), `QRCodeRenderer` (Task 1).

- [ ] **Step 1: SettingsTab enum'a .remote ekle**

`enum SettingsTab`'e `case remote`, `title`'a `case .remote: return "Remote"`, `icon`'a `case .remote: return "iphone.and.arrow.forward"`, ve `content`'e:
```swift
        case .remote: RemoteSettingsTab()
```

- [ ] **Step 2: RemoteSettingsTab view'ını yaz**

`LumiPackages/Sources/LumiUI/Settings/Tabs/RemoteSettingsTab.swift` — mevcut bir tab view'ının (örn. `NotificationsSettingsTab.swift`) `@Shell` erişim desenini birebir izle. `feat/remote-terminal-mirror:.../SettingsView.swift`'teki `remoteTab`/`stateColor`/`stateLabel` gövdesini taşı; `remote.` yerine `shell.remote.` kullan. İskelet:
```swift
import SwiftUI
import LumiKit
import LumiState

struct RemoteSettingsTab: View {
    @Shell private var shell
    @State private var relayDraft: String = ""

    private var remote: RemoteStore { shell.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ... remoteTab gövdesi (Toggle, relay TextField, durum noktası,
            //     QR + pairingString + Token yenile) — remote.* → burada remote ...
            Spacer()
        }
        .onAppear { relayDraft = remote.config.relayUrl }
    }
    // stateColor / stateLabel yardımcıları
}
```
(Gerçek gövde ve renk/etiket yardımcıları `feat/remote-terminal-mirror` SettingsView diff'inden; `SettingsSectionTitle`/`Theme` yeni main'de aynı isimle var mı doğrula — yoksa mevcut tab view stilini kullan.)

- [ ] **Step 3: LumiUI derlensin**

Run: `cd LumiPackages && swift build --target LumiUI 2>&1 | tail -30`
Beklenen: PASS.

- [ ] **Step 4: Commit**

```bash
git add LumiPackages/Sources/LumiUI/Settings
git commit -m "feat(ui): Settings Remote sekmesi — QR + toggle + relay + token (yeni @Shell deseni)"
```

---

### Task 8: Tüm paket derlensin + testler yeşil

**Files:**
- Modify: Yalnız derleme/test hatalarını gidermek için ilgili dosyalar (ported testlerin import/fake uyumu dahil).

- [ ] **Step 1: Tam derleme**

Run: `cd LumiPackages && swift build 2>&1 | tail -40`
Beklenen: PASS. Hata çıkarsa API-drift'tir; ilgili çağrıyı yeni imzaya uyarla.

- [ ] **Step 2: Ported testlerin fake/import uyumu**

Run: `cd LumiPackages && swift build --build-tests 2>&1 | tail -60`
`RemoteServiceTests`, `RemoteStoreTests`, `RemoteTapTests`, `TerminalWireTests`, `RemoteProtocolTests`, `RemoteConfigServiceTests`, `RelayConnectionTests`, `RemoteModelsTests` derlenmeli. RemoteService init'i persona'sız değiştiği için `RemoteServiceTests`'te persona kuran satırlar varsa kaldır/uyarla. Fake'i `LumiTestSupport`'tan import et.

- [ ] **Step 3: Test suite'i koştur (kalıcı scratch — disk-I/O workaround)**

Run: `cd LumiPackages && swift test --scratch-path "$HOME/.lumi/lumi-rework-build" 2>&1 | tail -30`
Beklenen: Tüm testler PASS (remote testleri + regresyon yok).

- [ ] **Step 4: RelayServer testleri (transport kuralı — değişmedi, doğrula)**

Run: `cd RelayServer && npm ci && npm test 2>&1 | tail -20`
Beklenen: 46/46 PASS. (RelayServer/ dosyaları Task 9'da taşınır; bu adım Task 9 sonrası da çalıştırılabilir — sıralama için Not.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix(remote): tam derleme + test uyarlamaları (API drift + persona'sız testler)"
```

---

### Task 9: Bağımsız ağaçları taşı (RelayServer, LumiMobile, docs, Scripts)

Swift paketinden bağımsız; çakışmasız. (Task 8'den önce de yapılabilir; sıra bağımsız.)

**Files:**
- Create: `RelayServer/**`, `LumiMobile/**`, `docs/superpowers/{plans,specs}/2026-09-08-*`, `Scripts/make-rework-app.sh`, `.gitignore` (append), `.railwayignore`.

- [ ] **Step 1: Ağaçları taşı**

```bash
cd /Users/balkan/orca/workspaces/Lumi/lumi
git checkout feat/remote-terminal-mirror -- RelayServer LumiMobile Scripts/make-rework-app.sh \
  docs/superpowers/plans/2026-09-08-remote-terminal-mirror.md \
  docs/superpowers/specs/2026-09-08-remote-terminal-mirror-design.md
```

- [ ] **Step 2: .gitignore remote girdilerini ekle**

`.gitignore` sonuna ekle (main'de yoksa):
```
RelayServer/node_modules/

# LumiMobile — XcodeGen üretimi + build çıktıları
LumiMobile/LumiMobile.xcodeproj
LumiMobile/build/
LumiMobile/build-device/
LumiMobile/*.log
LumiMobile/App/Info.plist
```

- [ ] **Step 3: RelayServer testleri**

Run: `cd RelayServer && npm ci && npm test 2>&1 | tail -20`
Beklenen: 46/46 PASS.

- [ ] **Step 4: Commit**

```bash
git add RelayServer LumiMobile Scripts/make-rework-app.sh docs/superpowers .gitignore
git commit -m "chore(remote): RelayServer + LumiMobile + docs + make-rework script taşındı"
```

---

### Task 10: macOS (LumiRework) build + iOS build + cihaz doğrulaması

**Files:** Yok (build/paketleme).

- [ ] **Step 1: macOS test build (çalışan Lumi'ye dokunmaz)**

Run: `Scripts/make-rework-app.sh`
Beklenen: `~/Applications/LumiRework.app` hazır, ad-hoc imza geçerli.

- [ ] **Step 2: iOS projeyi tazele + cihaz build**

```bash
cd LumiMobile && xcodegen generate
xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/lumimobile-dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=FX46XZGU7U build 2>&1 | tail -20
```
Beklenen: BUILD SUCCEEDED.

- [ ] **Step 3: Cihaza kur**

```bash
xcrun devicectl device install app --device 00008120-0009751E0AE2201E \
  /tmp/lumimobile-dd/Build/Products/Release-iphoneos/LumiMobile.app 2>&1 | tail -6
```
Beklenen: App installed (com.lumi.LumiRemoteNew).

- [ ] **Step 4: Manuel doğrulama (kullanıcı)**

LumiRework'ü aç → Settings → Remote → QR. Telefonda "Lumi Remote New" ile eşleştir. Doğrula:
1. Telefondan metin → Gönder → satır otomatik submit.
2. Claude cevabı telefona akıyor (data stream).
3. Bağlantı kararlı (kopma yok).

---

## Self-Review

**Spec coverage:** Tüm orca remote yüzeyi (relay transport, LumiKit modelleri/protokolleri, LumiRemote servisi, terminal tap, RemoteStore, Settings sekmesi, iOS app) bir task'a bağlı. Tek Lumi kuralı (relay server) Task 9 + değişmeyen RelayServer ile korunuyor.

**Bilinen kapsam kesintisi:** Telefondan **persona ile** yeni oturum başlatma özelliği kaldırıldı (yeni main'de Preset sistemi yok). `start_session` düz `claude`/`claude '<prompt>'` spawn'a düşer. Bu, önceden de "ertelenmiş" olarak işaretli ikincil özellikti — kayıp değil, bilinçli kapsam kararı. Persona picker'ları gerekirse ayrı bir iş.

**Type consistency:** Doğrulanan imzalar — `TerminalServicing`: `spawn(repoPath:task:command:)`, `write(id:text:)`, `kill(id:)`, `terminals`, `events()`; `RepoServicing.repos() async -> [Repo]`; `TerminalMeta.{id,repoPath,oscTitle,status}`; `TerminalEvent` (yeni `.providerChanged`/`.writeFailed` dahil); `TerminalPresentation.feed(_:)`; `TerminalSession.write(_ data:)`. `FeatureAssembly`/`ShellContext`/`SettingsTab` desenleri explorer raporlarından birebir.

**Açık doğrulama noktaları (impl sırasında):** (a) yeni `TerminalSession.init` imzası → `makeForTest()` uyarlaması (Task 3.4); (b) `SettingsSectionTitle`/`Theme` sembollerinin yeni main'de varlığı (Task 7.2); (c) ported `RemoteServiceTests`'in persona'sız init'e uyumu (Task 8.2).
