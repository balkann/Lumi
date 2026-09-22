# iOS'ta branch/worktree ile agent açma — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Telefondan yeni agent açarken git/Plastic dal seçip worktree/workspace oluşturmak ve agent'ı o path'te stream-json chat olarak başlatmak.

**Architecture:** Telefon `list_branches` komutuyla repo'nun dallarını çeker; `start_session`'a workspace alanları (branchMode/branchName/baseBranch/workspaceName) ekler. Mac `RemoteCommandHandler` bu alanları görürse `WorkspaceServicing.create` ile worktree açar, sonra `ChatSessionService.create` ile o path'te chat başlatır. macOS app UX'i ve relay değişmez.

**Tech Stack:** Swift 6, SPM (LumiPackages: LumiRemote/LumiKit/LumiTestSupport), iOS (LumiMobile/LumiMobileKit), swift-testing + XCTest.

## Global Constraints

- macOS app'in kendi UX'i (`ProjectsPanel`, `CreateWorkspaceOverlay`, terminal grid) DEĞİŞMEZ; `RemoteService` pasif sunucudur.
- Relay (`RelayServer`) DEĞİŞMEZ.
- Yeni servis eklenmez; `WorkspaceServicing`/`ChatSessionServicing` mevcut. Config formatı değişmez (karar 9).
- Transcript-tail revival YAPILMAZ (Faz 2 kararı korunur).
- Wire alanları opsiyonel/geriye uyumlu; eski gövdeler aynen çalışır.
- Mac testleri: `cd LumiPackages && swift test --scratch-path <scratch>`; iOS: `xcodebuild ... test` veya `swift test` (LumiMobileKit).
- `copyLibrary` ilk fazda daima `false`.

---

## File Structure

- `LumiPackages/Sources/LumiRemote/NoopWorkspaceServicing.swift` — **create**: eski init'leri bozmayan no-op `WorkspaceServicing`.
- `LumiPackages/Sources/LumiRemote/RemoteService.swift` — **modify**: init'e `workspaces` (Noop default); handler'a `repos`+`workspaces` geçir.
- `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift` — **modify**: `repos`+`workspaces` bağımlılığı; `repoFor`; `list_branches`; `start_session` workspace dalı.
- `LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift` — **modify**: `workspaces: services.workspaces` geçir.
- `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift` — **modify**: yeni testler.
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` — **modify**: `CommandAction` genişletme + `.listBranches`.
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift` — **modify**: `CommandResult.branches`.
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` — **modify**: `loadBranches` + branch state + `startChatSession` params.
- `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/BranchWorktreeWireTests.swift` — **create**: wire + AppModel testleri.
- `LumiMobile/App/NewSessionView.swift` — **modify**: dal modu UI.

---

## Task 1: Mac — `list_branches` komutu + workspace bağımlılığı

**Files:**
- Create: `LumiPackages/Sources/LumiRemote/NoopWorkspaceServicing.swift`
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift:17-21`, `RemoteService.swift:74-99`, `LumiAppCore/Features/RemoteFeatureAssembly.swift:23-31`
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: `WorkspaceServicing.branches(project:limit:)`, `RepoServicing.repos()`, mevcut `FakeWorkspaceService` (LumiTestSupport, `setBranches`/`branchCalls`), `FakeRepoService`.
- Produces: `RemoteCommandHandler.init(terminal:trust:chatSessions:repos:workspaces:)`; `command_result` payload'unda `"branches": [String]` (list_branches için); `RemoteService.init(..., workspaces:)`.

- [ ] **Step 1: NoopWorkspaceServicing yaz**

`LumiPackages/Sources/LumiRemote/NoopWorkspaceServicing.swift`:
```swift
import Foundation
import LumiKit

/// Eski `RemoteService` init çağrılarını bozmamak için no-op `WorkspaceServicing`.
public actor NoopWorkspaceServicing: WorkspaceServicing {
    public init() {}
    public func inspect(project: Repo) async throws -> WorkspaceSource {
        WorkspaceSource(projectPath: project.path, scm: .none, destinationDirectory: NSTemporaryDirectory())
    }
    public func branches(project: Repo, limit: Int) async throws -> [WorkspaceBranch] { [] }
    public func create(_ request: WorkspaceCreateRequest) async throws -> WorkspaceCreateResult {
        throw WorkspaceFailure("noop workspace servisi create desteklemez")
    }
    public func copyLibrary(sourcePath: String, workspacePath: String) async throws {}
    public func remove(_ workspace: ProjectWorkspace, force: Bool) async throws {}
}
```
> NOT: `WorkspaceSource.init` ve `WorkspaceFailure`'ın imzasını doğrula (`ProjectWorkspaceModels.swift` / `WorkspaceServicing.swift`). `WorkspaceSource` minimal init'i `FakeWorkspaceService`'te kullanılan `WorkspaceSource(projectPath:scm:destinationDirectory:)` ile aynı olmalı; farklıysa fake'teki çağrıyı birebir kopyala.

- [ ] **Step 2: RemoteCommandHandler'a bağımlılık + list_branches ekle**

`RemoteCommandHandler.swift` init'i (satır 17) — `repos` ve `workspaces` ekle:
```swift
init(terminal: any TerminalServicing, trust: any ClaudeWorkspaceTrusting,
     chatSessions: any ChatSessionServicing,
     repos: any RepoServicing, workspaces: any WorkspaceServicing) {
    self.terminal = terminal
    self.trust = trust
    self.chatSessions = chatSessions
    self.repos = repos
    self.workspaces = workspaces
}
```
Stored property'leri ekle (diğer `private let` bildirimlerinin yanına):
```swift
private let repos: any RepoServicing
private let workspaces: any WorkspaceServicing
```
`handle` switch'ine (mevcut `case "set_model":`'den sonra, `default:`'tan önce) ekle:
```swift
case "list_branches":
    return await listBranches(payload, commandId: commandId)
```
Yeni yardımcılar (dosyanın uygun yerine, `startSession`'ın yanına):
```swift
private func repoFor(_ path: String) async -> Repo? {
    await repos.repos().first { $0.path == path }
}

private func listBranches(_ payload: [String: Any], commandId: Any) async -> sending [String: Any] {
    let repoPath = payload["repoPath"] as? String ?? ""
    guard let repo = await repoFor(repoPath) else {
        return ["commandId": commandId, "ok": false, "error": "unknown_repo"]
    }
    do {
        let branches = try await workspaces.branches(project: repo, limit: 100)
        return ["commandId": commandId, "ok": true, "branches": branches.map(\.name)]
    } catch {
        return ["commandId": commandId, "ok": false, "error": "\(error)"]
    }
}
```

- [ ] **Step 3: RemoteService init'e workspaces ekle + handler'a geçir**

`RemoteService.swift` init imzasına (satır ~86, `chatSessions` default'undan sonra) ekle:
```swift
        chatSessions: any ChatSessionServicing = NoopChatSessionService(),
        workspaces: any WorkspaceServicing = NoopWorkspaceServicing()
```
Handler kurulumunu (satır 92) güncelle:
```swift
self.commandHandler = RemoteCommandHandler(
    terminal: terminal, trust: trust, chatSessions: chatSessions,
    repos: repos, workspaces: workspaces)
```

- [ ] **Step 4: RemoteFeatureAssembly'de gerçek servisi geçir**

`RemoteFeatureAssembly.swift` (satır ~23-31), `RemoteService(` çağrısına ekle:
```swift
            chatSessions: services.chatSessions,
            workspaces: services.workspaces
```
> `repos: services.repo` zaten geçiliyor; dokunma.

- [ ] **Step 5: Başarısız test yaz**

`RemoteServiceTests.swift`'e ekle (dosya sonundaki test bloğuna, mevcut `makeSession` helper'ının yanına). `FakeRepoService`'in bir repo döndürmesi gerekiyor — mevcut `FakeRepoService`'in repo enjeksiyonunu kontrol et; repo listesine `Repo(name:"R", path:"/tmp/r", isGitRepo:true, source:...)` ekleyebilmelisin (gerekirse fake'e setter zaten var mı bak, yoksa init'ten repo geçir):
```swift
@Test @MainActor
func listBranchesReturnsWorkspaceBranches() async throws {
    let term = FakeTerminalServicing()
    let conn = FakeRelayConnection()
    let repo = Repo(name: "R", path: "/tmp/r", isGitRepo: true, source: .discovered)
    let repoSvc = FakeRepoService(repos: [repo])           // ← FakeRepoService repo enjeksiyonu
    let ws = FakeWorkspaceService()
    await ws.setBranches(.success([WorkspaceBranch(name: "main"), WorkspaceBranch(name: "dev")]))
    let svc = RemoteService(paths: .testDefaults(), terminal: term, repos: repoSvc,
        connection: conn, chatSource: FakeChatTranscriptSource(events: []), workspaces: ws)
    _ = svc

    let result = await RemoteCommandHandler(
        terminal: term, trust: NoopClaudeWorkspaceTrust(),
        chatSessions: NoopChatSessionService(), repos: repoSvc, workspaces: ws
    ).handle(["action": "list_branches", "repoPath": "/tmp/r", "commandId": "c1"])

    #expect(result["ok"] as? Bool == true)
    #expect(result["branches"] as? [String] == ["main", "dev"])
    #expect(await ws.branchCalls.map(\.0) == ["/tmp/r"])
}

@Test @MainActor
func listBranchesUnknownRepoFails() async throws {
    let repoSvc = FakeRepoService(repos: [])
    let ws = FakeWorkspaceService()
    let result = await RemoteCommandHandler(
        terminal: FakeTerminalServicing(), trust: NoopClaudeWorkspaceTrust(),
        chatSessions: NoopChatSessionService(), repos: repoSvc, workspaces: ws
    ).handle(["action": "list_branches", "repoPath": "/nope", "commandId": "c1"])
    #expect(result["ok"] as? Bool == false)
    #expect(result["error"] as? String == "unknown_repo")
}
```
> `FakeRepoService`'in `init(repos:)` alıp almadığını doğrula; almıyorsa fake'e ekle (LumiTestSupport, `RepoServicing.repos()` bu listeyi dönsün). `RemoteCommandHandler`'ı doğrudan kurmak testi basitleştirir; erişim `internal` ise `@testable import LumiRemote` mevcut olmalı (dosya başını kontrol et).

- [ ] **Step 6: Testi koştur — FAIL beklenir**

Run: `cd LumiPackages && swift test --scratch-path /private/tmp/claude-502/-Users-balkan-orca-workspaces-Lumi-lumi/10e79037-cc29-430e-8944-3b85233af86a/scratchpad/.build --filter listBranches`
Expected: FAIL (derleme: `RemoteCommandHandler` yeni init imzasını almadan önce) → adımlar 1–4 uygulanınca PASS.

- [ ] **Step 7: Adım 1–4'ü uygula, testi koştur — PASS**

Run: aynı komut. Expected: PASS. Ayrıca tüm suite yeşil kalmalı (Noop default sayesinde eski init çağrıları bozulmaz):
`swift test --scratch-path <scratch> --filter RemoteService`

- [ ] **Step 8: Commit**

```bash
git add LumiPackages/Sources/LumiRemote LumiPackages/Sources/LumiAppCore/Features/RemoteFeatureAssembly.swift LumiPackages/Tests/LumiRemoteTests LumiPackages/Tests/LumiTestSupport
git commit -m "feat(remote): list_branches komutu + RemoteService workspace bağımlılığı"
```

---

## Task 2: Mac — `start_session` workspace/worktree dalı

**Files:**
- Modify: `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift` (`startSession`, satır ~70-96)
- Test: `LumiPackages/Tests/LumiRemoteTests/RemoteServiceTests.swift`

**Interfaces:**
- Consumes: `workspaces.create(WorkspaceCreateRequest)`, `repoFor` (Task 1), `chatSessions.create/send`.
- Produces: `start_session` payload'unda opsiyonel `branchMode`/`branchName`/`baseBranch`/`workspaceName` → worktree path'te chat.

- [ ] **Step 1: Başarısız testler yaz**

`RemoteServiceTests.swift`'e ekle. Chat oluşturmayı doğrulamak için `FakeChatSessionService` gerekir (LumiTestSupport'ta var mı bak; yoksa `create` çağrısını kaydeden minimal fake ekle — `create(repoPath:)` çağrısını `repoPath`'iyle kaydetsin, `list`/`send`/`snapshots` no-op):
```swift
@Test @MainActor
func startSessionNewBranchCreatesWorkspaceThenChat() async throws {
    let repo = Repo(name: "R", path: "/tmp/r", isGitRepo: true, source: .discovered)
    let repoSvc = FakeRepoService(repos: [repo])
    let ws = FakeWorkspaceService()
    let wsPath = "/tmp/r-worktrees/feature-x"
    let created = ProjectWorkspace(projectPath: "/tmp/r", path: wsPath, name: "feature-x",
        branch: "feature-x", scm: .git)                       // ← init imzasını doğrula
    await ws.setCreateOutcome(.success(WorkspaceCreateResult(workspace: created, warning: nil)))
    let chat = FakeChatSessionService()
    let handler = RemoteCommandHandler(
        terminal: FakeTerminalServicing(), trust: NoopClaudeWorkspaceTrust(),
        chatSessions: chat, repos: repoSvc, workspaces: ws)

    let result = await handler.handle([
        "action": "start_session", "kind": "chat", "repoPath": "/tmp/r",
        "prompt": "selam", "branchMode": "new", "branchName": "feature-x", "commandId": "c1"])

    #expect(result["ok"] as? Bool == true)
    let calls = await ws.createCalls
    #expect(calls.count == 1)
    #expect(calls.first?.request.branchMode == .new)
    #expect(calls.first?.request.branchName == "feature-x")
    #expect(await chat.createdRepoPaths == [wsPath])          // ← worktree path'te chat
}

@Test @MainActor
func startSessionCurrentModeSkipsWorkspaceCreate() async throws {
    let repo = Repo(name: "R", path: "/tmp/r", isGitRepo: true, source: .discovered)
    let ws = FakeWorkspaceService()
    let chat = FakeChatSessionService()
    let handler = RemoteCommandHandler(
        terminal: FakeTerminalServicing(), trust: NoopClaudeWorkspaceTrust(),
        chatSessions: chat, repos: FakeRepoService(repos: [repo]), workspaces: ws)
    let result = await handler.handle([
        "action": "start_session", "kind": "chat", "repoPath": "/tmp/r",
        "prompt": "", "branchMode": "current", "commandId": "c1"])
    #expect(result["ok"] as? Bool == true)
    #expect(await ws.createCalls.isEmpty)
    #expect(await chat.createdRepoPaths == ["/tmp/r"])
}

@Test @MainActor
func startSessionWorkspaceCreateFailureSurfacesError() async throws {
    let repo = Repo(name: "R", path: "/tmp/r", isGitRepo: true, source: .discovered)
    let ws = FakeWorkspaceService()
    await ws.setCreateOutcome(.failure(WorkspaceFailure("kirli worktree")))
    let chat = FakeChatSessionService()
    let handler = RemoteCommandHandler(
        terminal: FakeTerminalServicing(), trust: NoopClaudeWorkspaceTrust(),
        chatSessions: chat, repos: FakeRepoService(repos: [repo]), workspaces: ws)
    let result = await handler.handle([
        "action": "start_session", "kind": "chat", "repoPath": "/tmp/r",
        "prompt": "", "branchMode": "existing", "branchName": "dev", "commandId": "c1"])
    #expect(result["ok"] as? Bool == false)
    #expect(await chat.createdRepoPaths.isEmpty)
}
```
> `ProjectWorkspace.init` ve `WorkspaceCreateResult.init` imzalarını `ProjectWorkspaceModels.swift`'ten doğrula ve birebir kullan. `FakeChatSessionService` yoksa LumiTestSupport'a ekle: `createdRepoPaths: [String]` kaydeden actor.

- [ ] **Step 2: Testleri koştur — FAIL**

Run: `cd LumiPackages && swift test --scratch-path <scratch> --filter startSession`
Expected: FAIL (workspace dalı henüz yok — `current` testi bile create'i atlamıyor olabilir; `new` create çağrılmıyor).

- [ ] **Step 3: startSession chat dalını genişlet**

`RemoteCommandHandler.swift` `startSession`, `if kind == "chat" {` bloğunu şöyle değiştir:
```swift
if kind == "chat" {
    var chatRepoPath = repoPath
    let mode = payload["branchMode"] as? String
    if let mode, mode != "current" {
        guard let repo = await repoFor(repoPath) else {
            return ["commandId": commandId, "ok": false, "error": "unknown_repo"]
        }
        let branchMode = WorkspaceBranchMode(rawValue: mode) ?? .new
        let branchName = payload["branchName"] as? String
        let wsName = (payload["workspaceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? branchName ?? "workspace"
        let request = WorkspaceCreateRequest(
            project: repo, name: wsName, branchName: branchName,
            branchMode: branchMode, baseBranch: payload["baseBranch"] as? String,
            copyLibrary: false, knownProjectPaths: await repos.repos().map(\.path))
        do {
            let created = try await workspaces.create(request)
            chatRepoPath = created.workspace.path
        } catch {
            return ["commandId": commandId, "ok": false, "error": "\(error)"]
        }
    }
    let meta = await chatSessions.create(repoPath: chatRepoPath)
    if !prompt.isEmpty {
        await chatSessions.send(id: meta.id, text: prompt)
    }
    return ["commandId": commandId, "ok": true, "sessionId": meta.id]
}
```

- [ ] **Step 4: Testleri koştur — PASS**

Run: `cd LumiPackages && swift test --scratch-path <scratch> --filter startSession`
Expected: PASS (üç test). Ardından tam suite: `swift test --scratch-path <scratch>` yeşil.

- [ ] **Step 5: Commit**

```bash
git add LumiPackages/Sources/LumiRemote LumiPackages/Tests
git commit -m "feat(remote): start_session workspace/worktree ile chat başlatır"
```

---

## Task 3: iOS wire — PhoneProtocol + CommandResult

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift` (`CommandAction` ~26, encode ~180), `Models.swift:220-233`
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/BranchWorktreeWireTests.swift` (create)

**Interfaces:**
- Consumes: mevcut `frame(type:payload:)`, `OutgoingCommand`.
- Produces: `CommandAction.startSession(repoPath:personaId:prompt:kind:branchMode:branchName:baseBranch:workspaceName:)`; `CommandAction.listBranches(repoPath:)`; `CommandResult.branches: [String]?`.

- [ ] **Step 1: Başarısız test yaz**

`BranchWorktreeWireTests.swift`:
```swift
import Testing
import Foundation
@testable import LumiMobileKit

@Suite struct BranchWorktreeWireTests {
    @Test func startSessionEncodesWorkspaceFields() throws {
        let cmd = OutgoingCommand(commandId: "c1", action: .startSession(
            repoPath: "/tmp/r", personaId: nil, prompt: "hi", kind: "chat",
            branchMode: "new", branchName: "feat", baseBranch: "main", workspaceName: "ws1"))
        let text = PhoneProtocol.encode(command: cmd)                 // ← gerçek encode API'sini kullan
        let obj = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        #expect(payload["action"] as? String == "start_session")
        #expect(payload["branchMode"] as? String == "new")
        #expect(payload["branchName"] as? String == "feat")
        #expect(payload["baseBranch"] as? String == "main")
        #expect(payload["workspaceName"] as? String == "ws1")
    }

    @Test func listBranchesEncodes() throws {
        let cmd = OutgoingCommand(commandId: "c2", action: .listBranches(repoPath: "/tmp/r"))
        let text = PhoneProtocol.encode(command: cmd)
        let obj = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        #expect(payload["action"] as? String == "list_branches")
        #expect(payload["repoPath"] as? String == "/tmp/r")
    }

    @Test func commandResultDecodesBranches() throws {
        let json = #"{"v":1,"type":"command_result","payload":{"commandId":"c2","ok":true,"branches":["main","dev"]}}"#
        let msg = PhoneProtocol.decodeServerMessage(json)
        guard case .commandResult(let r) = msg else { Issue.record("beklenen commandResult"); return }
        #expect(r.branches == ["main", "dev"])
    }
}
```
> `PhoneProtocol`'ün komut encode fonksiyonunun GERÇEK adını doğrula (ör. `encode(command:)`). `frame(...)` private; mevcut testlerde (`EndToEndWireTests`) kullanılan public encode giriş noktasını kopyala.

- [ ] **Step 2: Testi koştur — FAIL**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter BranchWorktreeWire`
Expected: FAIL (derleme: yeni `startSession` parametreleri + `.listBranches` + `CommandResult.branches` yok).

- [ ] **Step 3: CommandAction + encode genişlet**

`PhoneProtocol.swift` `CommandAction`:
```swift
    case startSession(repoPath: String, personaId: String?, prompt: String, kind: String? = nil,
                      branchMode: String? = nil, branchName: String? = nil,
                      baseBranch: String? = nil, workspaceName: String? = nil)
    case listBranches(repoPath: String)
```
Encode (satır ~180), `.startSession` case'ini güncelle ve `.listBranches` ekle:
```swift
        case .startSession(let repoPath, let personaId, let prompt, let kind,
                           let branchMode, let branchName, let baseBranch, let workspaceName):
            payload["action"] = "start_session"
            payload["repoPath"] = repoPath
            payload["prompt"] = prompt
            if let personaId { payload["personaId"] = personaId }
            if let kind { payload["kind"] = kind }
            if let branchMode { payload["branchMode"] = branchMode }
            if let branchName { payload["branchName"] = branchName }
            if let baseBranch { payload["baseBranch"] = baseBranch }
            if let workspaceName { payload["workspaceName"] = workspaceName }
        case .listBranches(let repoPath):
            payload["action"] = "list_branches"
            payload["repoPath"] = repoPath
```

- [ ] **Step 4: CommandResult.branches ekle**

`Models.swift` `CommandResult`:
```swift
public struct CommandResult: Decodable, Sendable, Equatable {
    public let commandId: String
    public let ok: Bool
    public let error: String?
    public let sessionId: String?
    public let branches: [String]?

    public init(commandId: String, ok: Bool, error: String?, sessionId: String? = nil, branches: [String]? = nil) {
        self.commandId = commandId
        self.ok = ok
        self.error = error
        self.sessionId = sessionId
        self.branches = branches
    }
}
```

- [ ] **Step 5: Testleri koştur — PASS**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter BranchWorktreeWire`
Expected: PASS. Tüm LumiMobileKit suite'i yeşil: `swift test`.

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift LumiMobile/LumiMobileKit/Tests
git commit -m "feat(mobile): wire — start_session workspace alanları + list_branches"
```

---

## Task 4: iOS AppModel — loadBranches + startChatSession params

**Files:**
- Modify: `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift` (state ~33-49, commandResult ~192, startChatSession ~585, dispatch ~674)
- Test: `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/BranchWorktreeWireTests.swift` (aynı dosyaya AppModel testleri)

**Interfaces:**
- Consumes: `client.send(command:)`, `.listBranches`, `CommandResult.branches` (Task 3).
- Produces: `AppModel.branchesForRepo: [String]`, `branchesLoading: Bool`, `branchesError: String?`, `loadBranches(repoPath:)`, `startChatSession(repoPath:branchMode:branchName:baseBranch:workspaceName:)`.

- [ ] **Step 1: Başarısız test yaz**

Mevcut AppModel test desenini (`AppModelPromptTests`) izle — sahte client enjeksiyonu nasıl yapılıyorsa aynısı. `BranchWorktreeWireTests.swift`'e ekle:
```swift
@Test @MainActor func loadBranchesPopulatesStateOnResult() async {
    let (model, client) = makeModelWithFakeClient()   // ← mevcut test helper'ını kullan/uyarла
    await model.loadBranches(repoPath: "/tmp/r")
    #expect(model.branchesLoading == true)
    // Mac yanıtı simüle: son gönderilen commandId'yi al
    let cid = client.lastCommandId
    model.ingest(.commandResult(CommandResult(commandId: cid, ok: true, error: nil, branches: ["main", "dev"])))
    #expect(model.branchesForRepo == ["main", "dev"])
    #expect(model.branchesLoading == false)
}
```
> `makeModelWithFakeClient()` ve `model.ingest(...)`'ın gerçek adlarını mevcut AppModel testlerinden al (fake client + gelen mesaj enjeksiyonu nasıl yapılıyorsa). Fake client `lastCommandId` sağlamıyorsa gönderilen komutu kaydeden mevcut mekanizmayı kullan.

- [ ] **Step 2: Testi koştur — FAIL**

Run: `cd LumiMobile/LumiMobileKit && swift test --filter loadBranches`
Expected: FAIL (`loadBranches`/`branchesForRepo` yok).

- [ ] **Step 3: AppModel'e branch state + loadBranches ekle**

State (diğer `@Published`/`private(set)` alanların yanına, satır ~33):
```swift
    public private(set) var branchesForRepo: [String] = []
    public private(set) var branchesLoading = false
    public private(set) var branchesError: String?
    private var branchRequestIds: Set<String> = []
```
`loadBranches` (Komutlar bölümüne, `startChatSession`'ın yanına):
```swift
    public func loadBranches(repoPath: String) async {
        branchesForRepo = []
        branchesError = nil
        branchesLoading = true
        commandCounter += 1
        let commandId = "ph-\(commandCounter)"
        branchRequestIds.insert(commandId)
        let ok = await client.send(command: OutgoingCommand(commandId: commandId, action: .listBranches(repoPath: repoPath)))
        if !ok {
            branchRequestIds.remove(commandId)
            branchesLoading = false
            branchesError = "bağlantı yok"
        }
    }
```
commandResult handler'ının EN BAŞINA (satır 192, `let wasDelete`'ten ÖNCE):
```swift
        case .commandResult(let result):
            if branchRequestIds.remove(result.commandId) != nil {
                branchesLoading = false
                if result.ok { branchesForRepo = result.branches ?? [] }
                else { branchesError = result.error ?? "dallar yüklenemedi" }
                return
            }
            let wasDelete = deleteCommandIds.remove(result.commandId) != nil
```

- [ ] **Step 4: startChatSession'ı genişlet**

`startChatSession` (satır 585) imzasını değiştir:
```swift
    public func startChatSession(repoPath: String, branchMode: String? = nil,
                                 branchName: String? = nil, baseBranch: String? = nil,
                                 workspaceName: String? = nil) async {
        startState = .sending
        await dispatch(target: "", action: .startSession(
            repoPath: repoPath, personaId: nil, prompt: "", kind: "chat",
            branchMode: branchMode, branchName: branchName,
            baseBranch: baseBranch, workspaceName: workspaceName))
    }
```

- [ ] **Step 5: Testleri koştur — PASS**

Run: `cd LumiMobile/LumiMobileKit && swift test`
Expected: PASS (tüm suite; eski `startChatSession(repoPath:)` çağrıları default'larla çalışır).

- [ ] **Step 6: Commit**

```bash
git add LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift LumiMobile/LumiMobileKit/Tests
git commit -m "feat(mobile): AppModel loadBranches + startChatSession workspace params"
```

---

## Task 5: iOS UI — NewSessionView dal modu

**Files:**
- Modify: `LumiMobile/App/NewSessionView.swift`

**Interfaces:**
- Consumes: `model.branchesForRepo`, `model.branchesLoading`, `model.loadBranches`, `model.startChatSession(...)` (Task 4).
- Produces: (UI; test yok — build + manuel doğrulama).

- [ ] **Step 1: NewSessionView'i güncelle**

Tam dosya:
```swift
import SwiftUI
import LumiMobileKit

struct NewSessionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoPath = ""
    @State private var branchMode = "current"          // current | existing | new
    @State private var selectedBranch = ""
    @State private var newBranchName = ""
    @State private var baseBranch = ""
    @State private var workspaceName = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoPath) {
                    Text("Seç…").tag("")
                    ForEach(model.repos) { repo in Text(repo.name).tag(repo.path) }
                }
                .onChange(of: repoPath) { _, path in
                    resetBranchFields()
                    if !path.isEmpty { Task { await model.loadBranches(repoPath: path) } }
                }

                if !repoPath.isEmpty {
                    Picker("Dal", selection: $branchMode) {
                        Text("Mevcut dal").tag("current")
                        Text("Var olan dal").tag("existing")
                        Text("Yeni dal").tag("new")
                    }
                    .pickerStyle(.segmented)

                    if branchMode == "existing" {
                        if model.branchesLoading {
                            HStack { ProgressView(); Text("Dallar yükleniyor…") }
                        } else if let err = model.branchesError {
                            Text(err).font(.footnote).foregroundStyle(.orange)
                        } else {
                            Picker("Dal", selection: $selectedBranch) {
                                Text("Seç…").tag("")
                                ForEach(model.branchesForRepo, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } else if branchMode == "new" {
                        TextField("Yeni dal adı", text: $newBranchName)
                            .autocorrectionDisabled()
                        Picker("Baz dal (ops.)", selection: $baseBranch) {
                            Text("Mevcut dal").tag("")
                            ForEach(model.branchesForRepo, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    if branchMode != "current" {
                        TextField("Workspace adı (ops.)", text: $workspaceName)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button(action: submit) {
                        if model.startState == .sending { ProgressView() }
                        else { Text("Chat başlat") }
                    }
                    .disabled(!canSubmit)
                    if case .failed(let error) = model.startState {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Yeni chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
            .onChange(of: model.startState) { _, state in
                if state == .succeeded { model.resetStartState(); dismiss() }
            }
            .onAppear { model.resetStartState() }
        }
    }

    private var canSubmit: Bool {
        guard model.macOnline, !model.repos.isEmpty, !repoPath.isEmpty,
              model.startState != .sending else { return false }
        switch branchMode {
        case "existing": return !selectedBranch.isEmpty
        case "new": return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private func resetBranchFields() {
        branchMode = "current"; selectedBranch = ""; newBranchName = ""
        baseBranch = ""; workspaceName = ""
    }

    private func submit() {
        Task {
            switch branchMode {
            case "existing":
                await model.startChatSession(repoPath: repoPath, branchMode: "existing",
                    branchName: selectedBranch, workspaceName: workspaceName.isEmpty ? nil : workspaceName)
            case "new":
                await model.startChatSession(repoPath: repoPath, branchMode: "new",
                    branchName: newBranchName, baseBranch: baseBranch.isEmpty ? nil : baseBranch,
                    workspaceName: workspaceName.isEmpty ? nil : workspaceName)
            default:
                await model.startChatSession(repoPath: repoPath)
            }
        }
    }
}
```

- [ ] **Step 2: iOS build — derleme yeşil**

Run: `cd LumiMobile && xcodegen generate && xcodebuild -project LumiMobile.xcodeproj -scheme LumiMobile -configuration Release -destination 'id=55DA1E5F-6F85-5746-8171-E25C8C0E0C5C' -derivedDataPath <scratch>/ios-dd -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add LumiMobile/App/NewSessionView.swift
git commit -m "feat(mobile): yeni chat'te dal modu (current/existing/new) UI"
```

---

## Self-Review

- **Spec coverage:** list_branches (Task 1), start_session workspace (Task 2), wire (Task 3), AppModel (Task 4), UI (Task 5), hata yolları (Task 1/2/4 testleri + UI branchesError). Git+Plastic ayrımı gerektirmiyor (WorkspaceServicing soyutluyor; UI SCM'e bakmaz). ✓
- **Placeholder:** yok; imza doğrulama notları (`FakeRepoService(repos:)`, `PhoneProtocol.encode`, `ProjectWorkspace.init`, AppModel test helper) uygulayıcının kod okuyarak birebir eşlemesi için bilinçli bırakıldı — kör placeholder değil.
- **Type consistency:** `branchMode` string wire'da ("current"/"existing"/"new") ↔ Mac `WorkspaceBranchMode(rawValue:)`; `branches: [String]` her katmanda; `startChatSession` params Task 4 ↔ Task 5 ↔ `.startSession` Task 3 tutarlı.

## Doğrulama boşlukları (uygulayıcı çözer)
- `FakeRepoService`'in repo enjeksiyonu (yoksa fake'e `init(repos:)` ekle).
- `FakeChatSessionService` (LumiTestSupport'ta yoksa oluştur; `createdRepoPaths` kaydeder).
- `PhoneProtocol` public encode fonksiyon adı; AppModel test'inde fake client + gelen mesaj enjeksiyon helper'ı.
- `WorkspaceSource`/`ProjectWorkspace`/`WorkspaceCreateResult`/`WorkspaceFailure` init imzaları.
