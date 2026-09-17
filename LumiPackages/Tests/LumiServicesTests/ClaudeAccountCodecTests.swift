import Foundation
import LumiKit
import XCTest
@testable import LumiServices

/// Karar 56 — `claudeAccounts` / `activeClaudeAccountId` additive bölümü.
/// Kritik sözleşme: bu bölüm ASLA kimlik bilgisi (token) taşımaz.
final class ClaudeAccountCodecTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)
    /// Id'ler UUID olmak zorunda: dosya yoluna ve Keychain hesap adına
    /// giriyorlar (karar 56 sertleştirmesi).
    private static let first = "22222222-2222-4222-8222-222222222222"
    private static let second = "33333333-3333-4333-8333-333333333333"

    func testMissingKeysDecodeToEmptyListAndSystemDefault() {
        let config = ConfigCodec.decodeConfig(from: ["projectsRoot": "/tmp"])
        XCTAssertEqual(config.claudeAccounts, [])
        XCTAssertEqual(config.claudeAccountSelection, .systemDefault)
    }

    func testAccountRoundTripsWithOptionalOrganizationFields() throws {
        let accounts = [
            ClaudeAccount(
                id: ClaudeAccountCodecTests.first, email: "dev@example.com", organizationUUID: "org", organizationName: "Example",
                createdAt: created, updatedAt: created.addingTimeInterval(10),
                lastAuthenticatedAt: created.addingTimeInterval(20)
            ),
            ClaudeAccount(
                id: ClaudeAccountCodecTests.second, email: "solo@example.com",
                createdAt: created, updatedAt: created, lastAuthenticatedAt: created
            ),
        ]
        var config = AppConfig.defaults
        config.claudeAccounts = accounts
        config.claudeAccountSelection = .account(ClaudeAccountCodecTests.second)

        let overlay = ConfigCodec.configOverlay(config)
        let data = try JSONSerialization.data(withJSONObject: overlay)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = ConfigCodec.decodeConfig(from: dict)

        XCTAssertEqual(decoded.claudeAccounts, accounts)
        XCTAssertEqual(decoded.claudeAccountSelection, .account(ClaudeAccountCodecTests.second))
    }

    /// Token sızıntısına karşı yapısal kapı: overlay'in hiçbir yerinde
    /// credentials alanı görünmemeli (kimlik bilgisi Keychain'de yaşar).
    func testOverlayCarriesNoCredentialFields() throws {
        var config = AppConfig.defaults
        config.claudeAccounts = [
            ClaudeAccount(id: ClaudeAccountCodecTests.first, email: "dev@example.com", createdAt: created, updatedAt: created, lastAuthenticatedAt: created),
        ]
        let data = try JSONSerialization.data(withJSONObject: ConfigCodec.configOverlay(config))
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["accesstoken", "refreshtoken", "credentials", "oauth"] {
            XCTAssertFalse(json.contains(forbidden), "config.json'a \(forbidden) yazılmamalı")
        }
    }

    func testSelectionPointingAtAMissingAccountFallsBackToSystemDefault() {
        let decoded = ConfigCodec.decodeConfig(from: [
            "claudeAccounts": [["id": ClaudeAccountCodecTests.first, "email": "dev@example.com"]],
            "activeClaudeAccountId": "ghost",
        ])
        XCTAssertEqual(decoded.claudeAccountSelection, .systemDefault)
    }

    func testMalformedEntriesAreDroppedAndIdsStayUnique() {
        let decoded = ConfigCodec.decodeConfig(from: [
            "claudeAccounts": [
                ["id": ClaudeAccountCodecTests.first, "email": "dev@example.com"],
                ["id": ClaudeAccountCodecTests.first, "email": "duplicate@example.com"],
                ["id": "", "email": "blank@example.com"],
                ["id": ClaudeAccountCodecTests.second],
                ["email": "no-id@example.com"],
                "not-an-object",
            ],
        ])
        XCTAssertEqual(decoded.claudeAccounts.map(\.id), [ClaudeAccountCodecTests.first])
        XCTAssertEqual(decoded.claudeAccounts.first?.email, "dev@example.com")
    }

    func testMissingTimestampsFallBackToCreatedAt() {
        let decoded = ConfigCodec.decodeConfig(from: [
            "claudeAccounts": [
                ["id": ClaudeAccountCodecTests.first, "email": "dev@example.com", "createdAt": created.timeIntervalSince1970],
            ],
        ])
        let account = decoded.claudeAccounts.first
        XCTAssertEqual(account?.updatedAt, created)
        XCTAssertEqual(account?.lastAuthenticatedAt, created)
    }

    func testDuplicateIdentityMatchIsCaseInsensitiveOnEmailAndExactOnOrganization() {
        let account = ClaudeAccount(
            id: ClaudeAccountCodecTests.first, email: "Dev@Example.com", organizationUUID: "org",
            createdAt: created, updatedAt: created, lastAuthenticatedAt: created
        )
        XCTAssertTrue(account.isSameIdentity(email: "dev@example.com", organizationUUID: "org"))
        XCTAssertFalse(account.isSameIdentity(email: "dev@example.com", organizationUUID: nil))
        XCTAssertFalse(account.isSameIdentity(email: "other@example.com", organizationUUID: "org"))
    }

    /// UUID olmayan id'ler okunurken elenir: `../` taşıyan bir id yönetilen
    /// kökün dışına yazma/silme yapabilirdi.
    func testNonUUIDIdentifiersAreDropped() {
        let decoded = ConfigCodec.decodeConfig(from: [
            "claudeAccounts": [
                ["id": "../../escape", "email": "evil@example.com"],
                ["id": "plain-string", "email": "nope@example.com"],
                ["id": ClaudeAccountCodecTests.first, "email": "dev@example.com"],
            ],
        ])
        XCTAssertEqual(decoded.claudeAccounts.map(\.id), [ClaudeAccountCodecTests.first])
    }
}
