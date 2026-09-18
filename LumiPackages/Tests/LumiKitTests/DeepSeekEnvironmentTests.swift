import Foundation
import LumiKit
import XCTest

/// Karar 54: env dosyası içeriğinin üretimi/ayrıştırması ve anahtar doğrulaması.
final class DeepSeekEnvironmentTests: XCTestCase {
    func testFileContentsCarriesBaseURLAndQuotedKey() {
        let contents = DeepSeekEnvironment.fileContents(apiKey: "sk-abc123")

        XCTAssertTrue(contents.contains("export ANTHROPIC_BASE_URL=\"https://api.deepseek.com/anthropic\""))
        XCTAssertTrue(contents.contains("export ANTHROPIC_AUTH_TOKEN=\"sk-abc123\""))
        // `[1m]` soneki zsh'te glob olmasın diye değerler tırnaklı yazılır.
        XCTAssertTrue(contents.contains("export ANTHROPIC_MODEL=\"deepseek-flash[1m]\""))
        XCTAssertFalse(contents.contains("ANTHROPIC_API_KEY"))
    }

    func testRoundTripReadsTheKeyBack() {
        let contents = DeepSeekEnvironment.fileContents(apiKey: "sk-round-trip")

        XCTAssertEqual(DeepSeekEnvironment.apiKey(inFileContents: contents), "sk-round-trip")
    }

    /// Kullanıcı dosyayı elle kurmuş olabilir: tırnaksız ve `export`suz biçimler.
    func testParsesManuallyWrittenForms() {
        XCTAssertEqual(
            DeepSeekEnvironment.apiKey(inFileContents: "export ANTHROPIC_AUTH_TOKEN=sk-plain\n"),
            "sk-plain"
        )
        XCTAssertEqual(
            DeepSeekEnvironment.apiKey(inFileContents: "ANTHROPIC_AUTH_TOKEN='sk-single'\n"),
            "sk-single"
        )
        XCTAssertNil(DeepSeekEnvironment.apiKey(inFileContents: "# ANTHROPIC_AUTH_TOKEN=sk-commented\n"))
        XCTAssertNil(DeepSeekEnvironment.apiKey(inFileContents: "export ANTHROPIC_AUTH_TOKEN=\"\"\n"))
        XCTAssertNil(DeepSeekEnvironment.apiKey(inFileContents: "export ANTHROPIC_BASE_URL=\"x\"\n"))
    }

    func testKeyValidationRejectsShellUnsafeValues() {
        XCTAssertTrue(DeepSeekEnvironment.isValidAPIKey("sk-1234567890"))
        XCTAssertTrue(DeepSeekEnvironment.isValidAPIKey("  sk-trimmed  "))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey(""))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey("   "))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey("sk-\"; rm -rf /"))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey("sk-$(whoami)"))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey("sk-`id`"))
        XCTAssertFalse(DeepSeekEnvironment.isValidAPIKey("sk-a\nb"))
    }

    func testLaunchCommandSourcesTheFileAndDetectsAsClaude() {
        let command = DeepSeekEnvironment.launchCommand(envFilePath: "/Users/me/.claude/deepseek.env")

        XCTAssertEqual(command, "source \"/Users/me/.claude/deepseek.env\" && claude")
        // Kart kimliği: zincirin son parçası claude'dur.
        XCTAssertEqual(AgentProvider.detect(launchCommand: command), .claude)
    }

    func testSetupLaunchCommandIsNilUntilInstalled() {
        let missing = DeepSeekSetup(envFilePath: "/tmp/deepseek.env", apiKey: nil)
        let installed = DeepSeekSetup(envFilePath: "/tmp/deepseek.env", apiKey: "sk-x")

        XCTAssertFalse(missing.isInstalled)
        XCTAssertNil(missing.launchCommand)
        XCTAssertTrue(installed.isInstalled)
        XCTAssertEqual(installed.launchCommand, "source \"/tmp/deepseek.env\" && claude")
    }
}
