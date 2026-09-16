import Foundation
import LumiKit
import XCTest
@testable import LumiServices

/// Karar 56 — kimlik bilgisinin aranacağı yerlerin saf hesabı.
final class ClaudeAuthLocationsTests: XCTestCase {
    /// Claude Code 2.1+ şeması: `Claude Code-credentials-<sha256(dir)[0..8]>`.
    /// Yanlış hesaplanırsa hesap değişimi CLI'a hiç ulaşmaz.
    func testScopedKeychainServiceUsesTheFirstEightSha256HexChars() {
        let service = ClaudeAuthLocations.scopedKeychainService(configDir: "/Users/dev/.claude")
        XCTAssertTrue(service.hasPrefix("\(ClaudeAuthLocations.legacyKeychainService)-"))
        let suffix = service.dropFirst(ClaudeAuthLocations.legacyKeychainService.count + 1)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(
            service,
            ClaudeAuthLocations.scopedKeychainService(configDir: "/Users/other/.claude"),
            "farklı dizin farklı servis üretmeli"
        )
    }

    func testRuntimeFallsBackToHomeClaudeWhenNoConfigDirIsInherited() {
        let paths = ClaudeAuthLocations.runtime(
            homeDirectory: "/Users/dev", environment: [:], fileExists: { _ in false }
        )
        XCTAssertEqual(paths.configDir, "/Users/dev/.claude")
        XCTAssertEqual(paths.credentialsFile, "/Users/dev/.claude/.credentials.json")
        XCTAssertEqual(paths.configFile, "/Users/dev/.claude.json", "ev dizinindeki dosyaya düşülür")
    }

    func testRuntimePrefersTheColocatedConfigFileWhenItExists() {
        let paths = ClaudeAuthLocations.runtime(
            homeDirectory: "/Users/dev", environment: [:],
            fileExists: { $0 == "/Users/dev/.claude/.claude.json" }
        )
        XCTAssertEqual(paths.configFile, "/Users/dev/.claude/.claude.json")
    }

    func testInheritedConfigDirWins() {
        let paths = ClaudeAuthLocations.runtime(
            homeDirectory: "/Users/dev",
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/isolated"],
            fileExists: { _ in false }
        )
        XCTAssertEqual(paths.configDir, "/tmp/isolated")
        XCTAssertEqual(paths.configFile, "/tmp/isolated/.claude.json")
    }

    func testKeychainUserFallsBackWhenTheEnvironmentIsEmpty() {
        XCTAssertEqual(ClaudeAuthLocations.keychainUser(environment: ["USER": "dev"]), "dev")
        XCTAssertEqual(ClaudeAuthLocations.keychainUser(environment: [:]), "user")
    }
}

/// Kimlik çözümü ve "geçerli kimlik bilgisi" kapısı (karar 56).
final class ClaudeIdentityTests: XCTestCase {
    func testStatusOutputWinsOverOauthAccount() {
        let identity = ClaudeIdentity.resolve(
            statusJSON: #"{"email":"status@example.com","organizationName":"Status Org"}"#,
            oauthAccountJSON: #"{"emailAddress":"oauth@example.com","organizationUuid":"org-1"}"#,
            credentialsJSON: nil
        )
        XCTAssertEqual(identity.email, "status@example.com")
        XCTAssertEqual(identity.organizationName, "Status Org")
        XCTAssertEqual(identity.organizationUUID, "org-1", "status'ta yoksa oauth'tan tamamlanır")
    }

    func testFallsBackToCredentialsWhenNothingElseHasTheEmail() {
        let identity = ClaudeIdentity.resolve(
            statusJSON: "not json",
            oauthAccountJSON: nil,
            credentialsJSON: #"{"claudeAiOauth":{"email":"creds@example.com"}}"#
        )
        XCTAssertEqual(identity.email, "creds@example.com")
        XCTAssertNil(identity.organizationUUID)
    }

    func testBlankFieldsAreTreatedAsMissing() {
        let identity = ClaudeIdentity.resolve(
            statusJSON: #"{"email":"   ","organizationUuid":""}"#,
            oauthAccountJSON: nil, credentialsJSON: nil
        )
        XCTAssertNil(identity.email)
        XCTAssertNil(identity.organizationUUID)
    }

    /// Boş/bozuk bir blob yüzeye yazılırsa kullanıcı sessizce oturumdan düşer.
    func testOnlyCredentialsWithAnAccessTokenAreValid() {
        XCTAssertTrue(ClaudeIdentity.isValidCredentials(#"{"claudeAiOauth":{"accessToken":"t"}}"#))
        XCTAssertFalse(ClaudeIdentity.isValidCredentials(#"{"claudeAiOauth":{"accessToken":"  "}}"#))
        XCTAssertFalse(ClaudeIdentity.isValidCredentials(#"{"claudeAiOauth":{}}"#))
        XCTAssertFalse(ClaudeIdentity.isValidCredentials("{}"))
        XCTAssertFalse(ClaudeIdentity.isValidCredentials("not json"))
        XCTAssertFalse(ClaudeIdentity.isValidCredentials(nil))
    }
}
