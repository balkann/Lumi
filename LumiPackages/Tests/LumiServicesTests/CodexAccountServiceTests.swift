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
        XCTAssertEqual(try String(contentsOfFile: managedHome + "/config.toml"), "model = \"gpt-5\"\n")
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

    private func makeService(systemHome: URL) -> CodexAccountService {
        CodexAccountService(
            config: config,
            paths: paths,
            runner: runner,
            locator: locator,
            environment: ["CODEX_HOME": systemHome.path]
        )
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
