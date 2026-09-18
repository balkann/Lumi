import Foundation
import LumiKit
import LumiTestSupport
import XCTest
@testable import LumiServices

final class CodexAccountServiceTests: XCTestCase {
    private var root: URL!
    private var paths: LumiPaths!
    private var config: FakeConfigService!
    private var runner: FakeEnvironmentProcessRunner!
    private var locator: FakeBinaryLocator!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-codex-account-\(UUID().uuidString)")
        paths = LumiPaths(mode: .development, homeDirectory: root)
        try paths.ensureDirectoriesExist()
        config = FakeConfigService()
        runner = FakeEnvironmentProcessRunner()
        locator = FakeBinaryLocator(paths: ["codex": "/usr/local/bin/codex"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddRunsLoginInIsolatedHomeSelectsItAndMirrorsConfig() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(
            to: systemHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        await scriptLogin(email: "dev@example.com", workspace: "Personal")

        let service = makeService(systemHome: systemHome)
        let snapshot = try await service.addAccount()

        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(snapshot.selection, .account(account.id))
        let invocations = await runner.invocations
        let invocation = try XCTUnwrap(invocations.first)
        let managedHome = try XCTUnwrap(invocation.environment["CODEX_HOME"])
        XCTAssertTrue(managedHome.hasSuffix("/codex-accounts/\(account.id)/home"))
        XCTAssertNotEqual(managedHome, systemHome.path)
        XCTAssertTrue(
            try String(contentsOfFile: managedHome + "/config.toml").hasPrefix("model = \"gpt-5\"\n")
        )
        let selectedHome = await service.selectedHome()
        XCTAssertEqual(selectedHome, managedHome)
    }

    func testSystemDefaultIsNeverOverwrittenWhenManagedAccountIsAdded() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        let original = authJSON(email: "system@example.com", workspace: nil)
        try original.write(to: systemHome.appendingPathComponent("auth.json"))
        await scriptLogin(email: "managed@example.com", workspace: nil)

        let service = makeService(systemHome: systemHome)
        _ = try await service.addAccount()
        _ = try await service.select(.systemDefault)

        XCTAssertEqual(try Data(contentsOf: systemHome.appendingPathComponent("auth.json")), original)
        let selectedHome = await service.selectedHome()
        XCTAssertEqual(selectedHome, systemHome.path)
    }

    func testRemovingActiveAccountFallsBackAndDeletesOnlyItsManagedDirectory() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        await scriptLogin(email: "managed@example.com", workspace: nil)
        let service = makeService(systemHome: systemHome)
        let added = try await service.addAccount()
        let account = try XCTUnwrap(added.accounts.first)
        let managedHome = await service.selectedHome()

        let result = try await service.removeAccount(accountID: account.id)

        XCTAssertEqual(result.selection, .systemDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome))
        let selectedHome = await service.selectedHome()
        XCTAssertEqual(selectedHome, systemHome.path)
    }

    func testSelectionRejectsManagedHomeSymlink() async throws {
        let id = UUID().uuidString
        let accountDirectory = paths.codexAccountsDir.appendingPathComponent(id)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try authJSON(email: "outside@example.com", workspace: nil)
            .write(to: outside.appendingPathComponent("auth.json"))
        try FileManager.default.createSymbolicLink(
            at: accountDirectory.appendingPathComponent("home"), withDestinationURL: outside
        )
        let timestamp = Date()
        await config.seed(AppConfig(
            projectsRoot: "", additionalPaths: [], aiProvider: .codex, theme: "dark",
            terminalFontSize: 13, terminalFontFamily: "", terminalCursorStyle: "block",
            terminalCursorBlink: true, notifications: .defaults,
            codexAccounts: [CodexAccount(
                id: id, email: "outside@example.com", createdAt: timestamp,
                updatedAt: timestamp, lastAuthenticatedAt: timestamp
            )]
        ))
        let service = makeService(systemHome: root.appendingPathComponent("system-codex"))

        do {
            _ = try await service.select(.account(id))
            XCTFail("symlink home must not be selected")
        } catch {
            let selection = await config.config().codexAccountSelection
            XCTAssertEqual(selection, .systemDefault)
        }
    }

    func testAddMirrorsHooksAndRekeysTrustForManagedHome() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(
            to: systemHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        try Data("{\"hooks\":{}}".utf8).write(to: systemHome.appendingPathComponent("hooks.json"))
        await scriptLogin(email: "hooks@example.com", workspace: nil)

        let service = makeService(systemHome: systemHome)
        _ = try await service.addAccount()
        let managedHome = URL(fileURLWithPath: await service.selectedHome())

        let hooksData = try Data(contentsOf: managedHome.appendingPathComponent("hooks.json"))
        let hooksRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: hooksData) as? [String: Any]
        )
        let hooks = try XCTUnwrap(hooksRoot["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        let configText = try String(
            contentsOf: managedHome.appendingPathComponent("config.toml"), encoding: .utf8
        )
        XCTAssertTrue(configText.contains(managedHome.appendingPathComponent("hooks.json").path))
    }

    func testManagedHooksFollowEnabledLifecycle() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(
            to: systemHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        var disabled = AppConfig.defaults
        disabled.agentHooksEnabled = false
        await config.seed(disabled)
        await scriptLogin(email: "toggle@example.com", workspace: nil)
        let service = makeService(systemHome: systemHome)

        _ = try await service.addAccount()
        let managedHome = URL(fileURLWithPath: await service.selectedHome())
        var hooks = try hooksObject(at: managedHome)
        XCTAssertNil((hooks["hooks"] as? [String: Any])?["SessionStart"])

        await service.syncManagedHooks(enabled: true)
        hooks = try hooksObject(at: managedHome)
        XCTAssertNotNil((hooks["hooks"] as? [String: Any])?["SessionStart"])
        var configText = try String(
            contentsOf: managedHome.appendingPathComponent("config.toml"), encoding: .utf8
        )
        XCTAssertTrue(configText.contains(managedHome.appendingPathComponent("hooks.json").path))

        await service.syncManagedHooks(enabled: false)
        hooks = try hooksObject(at: managedHome)
        XCTAssertNil((hooks["hooks"] as? [String: Any])?["SessionStart"])
        configText = try String(
            contentsOf: managedHome.appendingPathComponent("config.toml"), encoding: .utf8
        )
        XCTAssertFalse(configText.contains(managedHome.appendingPathComponent("hooks.json").path))
    }

    func testResumeHomeAcceptsKnownHomesAndRejectsArbitraryPath() async throws {
        let systemHome = root.appendingPathComponent("system-codex")
        await scriptLogin(email: "managed@example.com", workspace: nil)
        let service = makeService(systemHome: systemHome)
        _ = try await service.addAccount()
        let managedHome = await service.selectedHome()

        let resolvedManaged = await service.resolvedResumeHome(managedHome)
        let resolvedSystem = await service.resolvedResumeHome(systemHome.path)
        let rejected = await service.resolvedResumeHome(root.appendingPathComponent("outside").path)
        XCTAssertEqual(resolvedManaged, managedHome)
        XCTAssertEqual(resolvedSystem, systemHome.path)
        XCTAssertNil(rejected)
    }

    private func makeService(systemHome: URL) -> CodexAccountService {
        CodexAccountService(
            config: config,
            paths: paths,
            runner: runner,
            locator: locator,
            environment: ["CODEX_HOME": systemHome.path]
        )
    }

    private func hooksObject(at home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent("hooks.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scriptLogin(email: String, workspace: String?) async {
        let data = authJSON(email: email, workspace: workspace)
        await runner.setSideEffect(for: "login") { invocation in
            guard let home = invocation.environment["CODEX_HOME"] else { return }
            let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            try? data.write(to: url)
        }
    }

    private func authJSON(email: String, workspace: String?) -> Data {
        var payload: [String: Any] = ["email": email]
        if let workspace {
            payload["https://api.openai.com/auth"] = ["workspace_name": workspace]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try! JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "x.\(encoded).x"]])
    }
}
