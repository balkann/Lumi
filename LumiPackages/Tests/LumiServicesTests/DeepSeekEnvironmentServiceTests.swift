import Foundation
import LumiKit
@testable import LumiServices
import XCTest

/// Karar 54: env dosyasının diske yazımı/okunması. Gerçek `~/.claude`'a
/// dokunulmaz — ev dizini temp'e enjekte edilir.
final class DeepSeekEnvironmentServiceTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumi-deepseek-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private var envFile: URL {
        home.appendingPathComponent(".claude/deepseek.env")
    }

    func testReadReportsNotInstalledWhenFileIsMissing() async {
        let service = DeepSeekEnvironmentService(homeDirectory: home)

        let setup = await service.read()

        XCTAssertFalse(setup.isInstalled)
        XCTAssertEqual(setup.envFilePath, envFile.path)
    }

    func testInstallWritesTheFileWithOwnerOnlyPermissions() async throws {
        let service = DeepSeekEnvironmentService(homeDirectory: home)

        let setup = try await service.install(apiKey: "sk-install")

        XCTAssertEqual(setup.apiKey, "sk-install")
        let contents = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("export ANTHROPIC_AUTH_TOKEN=\"sk-install\""))
        let permissions = try FileManager.default
            .attributesOfItem(atPath: envFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let reread = await service.read()
        XCTAssertEqual(reread.apiKey, "sk-install")
    }

    func testInstallTrimsAndRewritesAnExistingFile() async throws {
        let service = DeepSeekEnvironmentService(homeDirectory: home)
        _ = try await service.install(apiKey: "sk-first")

        _ = try await service.install(apiKey: "  sk-second  ")

        let setup = await service.read()
        XCTAssertEqual(setup.apiKey, "sk-second")
        let contents = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertFalse(contents.contains("sk-first"))
    }

    func testInstallRejectsShellUnsafeKeyAndWritesNothing() async {
        let service = DeepSeekEnvironmentService(homeDirectory: home)

        do {
            _ = try await service.install(apiKey: "sk-\"; rm -rf /")
            XCTFail("geçersiz anahtar kabul edildi")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: envFile.path))
        }
    }

    func testRemoveDeletesTheFileAndIsIdempotent() async throws {
        let service = DeepSeekEnvironmentService(homeDirectory: home)
        _ = try await service.install(apiKey: "sk-remove")

        let afterFirst = try await service.remove()
        let afterSecond = try await service.remove()

        XCTAssertFalse(afterFirst.isInstalled)
        XCTAssertFalse(afterSecond.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFile.path))
    }
}
