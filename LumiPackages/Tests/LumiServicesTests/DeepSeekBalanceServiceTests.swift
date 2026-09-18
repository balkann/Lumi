import Foundation
import LumiKit
import LumiTestSupport
import XCTest

@testable import LumiServices

/// Bakiye servisinin KENAR davranışı (karar 75): anahtar yoksa istek atılmaz,
/// HTTP durumları okunabilir mesaja çevrilir, ağ hatası yutulmaz.
///
/// Host'a hiç çıkılmaz: HTTP `URLProtocol` stub'ıyla, anahtar
/// `FakeDeepSeekEnvironmentService` ile ikame edilir.
final class DeepSeekBalanceServiceTests: XCTestCase {
    private let validBody = Data("""
    {"is_available":true,"balance_infos":[{"currency":"USD",\
    "total_balance":"1.69","granted_balance":"0.00","topped_up_balance":"1.69"}]}
    """.utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset([])
    }

    private func makeService(
        steps: [StubURLProtocol.Step],
        apiKey: String? = "sk-test"
    ) -> DeepSeekBalanceService {
        StubURLProtocol.reset(steps)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DeepSeekBalanceService(
            environment: FakeDeepSeekEnvironmentService(apiKey: apiKey),
            session: URLSession(configuration: configuration)
        )
    }

    func testReadsBalanceFromTheEndpoint() async throws {
        let service = makeService(steps: [.status(200, validBody)])

        let balance = try await service.fetch()

        XCTAssertEqual(balance.primary?.total, Decimal(string: "1.69"))
        XCTAssertEqual(StubURLProtocol.requestedURLs, [DeepSeekBalanceService.balanceURL])
    }

    func testMissingKeyMeansNoRequestAtAll() async {
        let service = makeService(steps: [.status(200, validBody)], apiKey: nil)

        await assertThrows(service) { detail in
            XCTAssertTrue(detail.contains("API key not set"), detail)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "anahtar yokken istek atılmaz")
    }

    func testUnauthorizedNamesTheKey() async {
        let service = makeService(steps: [.status(401, Data())])

        await assertThrows(service) { detail in
            XCTAssertEqual(detail, "HTTP 401 — invalid API key")
        }
    }

    func testServerErrorIsReportedNotRetried() async {
        let service = makeService(steps: [.status(503, Data())])

        await assertThrows(service) { detail in
            XCTAssertEqual(detail, "HTTP 503 — DeepSeek server error")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "yeniden deneme yok")
    }

    func testUnrecognizedBodyIsAnError() async {
        let service = makeService(steps: [.status(200, Data(#"{"nope":1}"#.utf8))])

        await assertThrows(service) { detail in
            XCTAssertEqual(detail, "unrecognized response format")
        }
    }

    func testTransportErrorSurfaces() async {
        let service = makeService(steps: [.transportError])

        await assertThrows(service) { detail in
            XCTAssertFalse(detail.isEmpty)
        }
    }

    // MARK: - Yardımcı

    private func assertThrows(
        _ service: DeepSeekBalanceService,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (String) -> Void
    ) async {
        do {
            _ = try await service.fetch()
            XCTFail("hata bekleniyordu", file: file, line: line)
        } catch let error as LumiError {
            guard case .deepSeekBalanceUnavailable(let detail) = error else {
                return XCTFail("beklenmeyen hata: \(error)", file: file, line: line)
            }
            check(detail)
        } catch {
            XCTFail("beklenmeyen hata: \(error)", file: file, line: line)
        }
    }
}
