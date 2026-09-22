# iOS'ta branch/worktree ile agent açma — tasarım

Tarih: 2026-09-18 · Durum: **Onaylandı, implementasyona hazır.**
Branch: `feat/remote-orca-main` (main merge sonrası, karar 54–77 dahil).

## Amaç

macOS Lumi'de agent açarken karar 58 ile gelen **dal (branch) seçimi + worktree/workspace
oluşturma** yeteneğini **iOS remote uygulamasına** taşımak. Telefondan yeni bir agent
açarken kullanıcı bir repo seçer, ardından (Git veya Plastic) bir dalda çalışacak bir
workspace/worktree oluşturur ve agent **stream-json chat** olarak o path'te başlar —
telefonda **chat view'de** temiz görünür.

## Kapsam

**Dahil:**
- iOS yeni-oturum akışına dal modu: **Current / Existing / New** (karar 58 paritesi).
- **Git + Plastic** ikisi de (`WorkspaceServicing` ikisini soyutlar).
- Agent worktree path'inde **stream-json chat** olarak açılır (mevcut `kind:"chat"` yolu).
- Wire: `list_branches` komutu + `start_session`'a workspace alanları.
- Mac `RemoteService`/`RemoteCommandHandler`: `WorkspaceServicing` enjekte; dal listeleme +
  workspace oluştur→chat başlat.

**Hariç (ileriye not):**
- **macOS Lumi chat view (Faz 3)** — ayrı oturumda yapılacak; o iş yapılırken "macOS'tan
  açılan chat telefonda sorunsuz görünür" bir gereksinim olarak yazılacak. Bu spec ona
  dokunmaz.
- **Transcript-tail revival:** Faz 2'de terminal oturumları için sökülen transcript-tail
  chat köprüsü GERİ GETİRİLMEZ. Terminal-modundaki Claude agent'ları telefonda terminal
  view'de kalır (kullanıcı kararı: yeni açılanlar sorunsuzsa update yapma).
- Persona / ilk prompt zenginleştirmesi (mevcut sadelik korunur).
- `copyLibrary` (Unity) telefonda opsiyonel/kapalı — macOS'ta çözülür; ilk fazda `false`.

## Mimari ve veri akışı

```
iOS NewSessionView (repo + dal modu + dal)
   │  repo seçilince → command: list_branches(repoPath)
   ▼
Relay (değişmez, forward)
   ▼
Mac RemoteService.command → RemoteCommandHandler
   ├─ list_branches → workspaces.branches(project, limit) → command_result{branches:[…]}
   └─ start_session(kind:chat, workspace alanları)
        ├─ workspace alanı varsa: repo çöz → WorkspaceCreateRequest →
        │     workspaces.create() → ProjectWorkspace.path
        └─ chatSessions.create(repoPath: workspacePath) → send(prompt) → sessionId
   ▼
RemoteService.sendSessions() → telefon oturumu kind:"chat" ile görür → chat view
```

**Önemli:** `RemoteService` pasif bir sunucu; macOS app'in kendi UX'i (`ProjectsPanel`,
`CreateWorkspaceOverlay`, terminal grid) **hiç değişmez**. Relay **değişmez**.

## Bileşenler

### 1. Wire — `LumiMobileKit/PhoneProtocol.swift` + `LumiRemote/RemoteProtocol.swift`

**a) `list_branches` (command action, request-response):**
- Telefon: `command { action:"list_branches", repoPath, commandId }`.
- Mac: `command_result { commandId, ok, branches:[{name}] }` (hata → `ok:false, error`).
- Mevcut `command`/`command_result` boru hattını kullanır (yeni frame tipi gerekmez).

**b) `start_session` genişletmesi:**
- Yeni opsiyonel alanlar: `branchMode` ("current"|"existing"|"new"), `branchName`
  (existing→seçilen dal, new→yeni dal adı), `baseBranch` (yalnız new), `workspaceName`
  (opsiyonel; boşsa `branchName`/`current`'tan türetilir).
- `PhoneProtocol.startSession` case'i bu alanları taşır (hepsi opsiyonel; `nil`/"current"
  → bugünkü davranış: doğrudan repoPath'te chat).
- Geriye uyumluluk: alanlar opsiyonel; eski gövdeler aynen çalışır.

### 2. Mac — `LumiRemote/RemoteCommandHandler.swift`

- Yeni bağımlılıklar (init'e eklenir): `workspaces: any WorkspaceServicing`,
  `repos: any RepoServicing`.
- **`list_branches`:** repoPath → `repoFor(repoPath)` → `workspaces.branches(project:limit:)`
  (limit sabit, ör. 100). `command_result` içinde `branches` döner. repo bulunamaz/servis
  hata → `ok:false`.
- **`start_session` (kind:chat):** payload'da `branchMode` var ve `.current` değilse:
  1. `repoFor(repoPath)` ile `Repo` çöz (yoksa `ok:false, error:"unknown_repo"`).
  2. `WorkspaceCreateRequest(project:, name: workspaceName ?? türet, branchName:,
     branchMode:, baseBranch:, copyLibrary:false, knownProjectPaths: repos.repos().map(\.path))`.
  3. `try workspaces.create(request)` → `result.workspace.path`.
  4. `chatSessions.create(repoPath: workspacePath)` + prompt → sessionId döndür.
  5. `create` throw ederse `ok:false, error:"\(error)"` (telefon `.failed` bandında gösterir).
- `.current` veya `branchMode` yok → mevcut davranış (repoPath'te doğrudan chat).
- `repoFor(_ path:)` yardımcı: `repos.repos().first { $0.path == path }`.

### 3. Mac — `RemoteService` + `RemoteFeatureAssembly` + `ServiceRegistry`

- `RemoteFeatureAssembly` (satır ~23): `RemoteService`/`RemoteCommandHandler` kurulurken
  `workspaces: services.workspaces` (zaten `ServiceRegistry.workspaces` mevcut) geçir.
  `repos` zaten geçiliyor.
- `RemoteService`, command handler'ı kurarken yeni bağımlılıkları iletir. `sendSessions`
  değişmez — yeni chat zaten `chatSessions.list()`'te görünür.

### 4. iOS — `NewSessionView.swift` + `AppModel.swift` + `PhoneProtocol`

**`AppModel`:**
- `branchesForRepo: [String]` + `branchesLoading: Bool` + `branchesError: String?` state.
- `loadBranches(repoPath:)`: `command(action:"list_branches")` gönderir, `command_result`
  içindeki `branches`'i state'e yazar. Hata → `branchesError`, UI "current-only"e düşer.
- `startChatSession(repoPath:branchMode:branchName:baseBranch:workspaceName:)`:
  `.startSession`'a workspace alanlarını ekler.

**`NewSessionView`:**
- Repo picker (mevcut). Repo seçilince `loadBranches` tetiklenir.
- **Dal modu** segmenti: Current / Existing / New.
  - Current: ek alan yok (bugünkü davranış).
  - Existing: dal picker (`branchesForRepo`; yüklenirken spinner; hata → uyarı + yalnız
    Current mümkün).
  - New: yeni dal adı `TextField` + base branch picker (opsiyonel; boş → mevcut dal).
- Opsiyonel workspace adı alanı (boşsa Mac türetir).
- "Chat başlat" → `startChatSession(...)` workspace alanlarıyla. Mevcut `startState`
  (`sending`/`failed`/`succeeded`) ve `macOnline`/`repos` guard'ları korunur.

## Hata yönetimi

- **`list_branches` hatası** (repo yok, Plastic sunucu, git yok): telefon `branchesError`
  gösterir; dal modu **Current**'a düşer; agent yine açılır.
- **Workspace oluşturma hatası** (kirli worktree, dal zaten var, Plastic çevrimdışı):
  Mac `start_session`'ı `ok:false, error` ile döner; telefon mevcut `.failed(error)`
  bandında gösterir; oturum açılmaz (yarım state yok — create+chat tek komutta atomik).
- **Mac çevrimdışı:** mevcut `macOnline` guard'ı butonu pasifler.
- **Wire geriye uyumluluk:** yeni alanlar opsiyonel; relay yalnız forward eder.

## Test

- **`LumiMobileKit` (unit):** `PhoneProtocol` — `list_branches` command encode; `start_session`
  workspace alanlarının payload'a doğru serileştiği; `command_result.branches` decode.
- **`LumiRemote` (`RemoteServiceTests`/`RemoteCommandHandlerTests`):**
  - Yeni `FakeWorkspaceServicing` (branches + create + kaydedilen `WorkspaceCreateRequest`).
  - `list_branches` → `workspaces.branches` çağrılır, `branches` result'a girer; repo yok → `ok:false`.
  - `start_session branchMode:new` → `workspaces.create` doğru `WorkspaceCreateRequest`'le
    çağrılır, sonra `chatSessions.create` **workspace path'iyle** çağrılır, `sessionId` döner.
  - `start_session branchMode:current` → `workspaces.create` **çağrılmaz** (bugünkü yol).
  - `create` throw → `ok:false, error`; chat oluşturulmaz.
  - `RemoteService` init'i yeni `workspaces` bağımlılığını alır (mevcut testlerin kurulumu
    güncellenir; `LumiTestSupport`'ta paylaşılan fake varsa kullanılır, yoksa eklenir).
- **iOS `AppModel` (varsa test hedefi):** `startChatSession` workspace alanlarını iletir;
  `loadBranches` state doldurur / hata yolu.

## Zorunlu kurallar (CLAUDE.md)

- **Persistence:** `WorkspaceService`/`ChatSessionService` mevcut; yeni servis yok, config
  formatı değişmez (karar 9).
- **DI:** yeni bağımlılıklar (`workspaces`, `repos`) enjeksiyonla; fake'ler `LumiTestSupport`
  veya test dosyasında.
- **iOS literal:** LumiUI literal yasağı iOS (`LumiMobile`) hedefinde geçerli DEĞİL (ayrı
  uygulama); yine de mevcut `NewSessionView` desenine uy.
- **macOS UX değişmez, relay değişmez.**

## Anahtar dosyalar

- Wire: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`,
  `LumiPackages/Sources/LumiRemote/RemoteProtocol.swift`
- Mac handler: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`,
  `RemoteService.swift`, `LumiAppCore/Features/RemoteFeatureAssembly.swift`
- Workspace: `LumiPackages/Sources/LumiKit/Protocols/WorkspaceServicing.swift`,
  `LumiKit/Models/ProjectWorkspaceModels.swift`, `LumiServices/Workspace/WorkspaceService.swift`
- iOS UI: `LumiMobile/App/NewSessionView.swift`, `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`,
  `Models.swift`
- Testler: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`,
  `LumiMobile/LumiMobileKit/Tests/…`
