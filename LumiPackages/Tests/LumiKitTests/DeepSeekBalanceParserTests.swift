import XCTest

@testable import LumiKit

/// Gövde `api.deepseek.com/user/balance`'ın gerçek yanıtından alınmıştır.
final class DeepSeekBalanceParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesRealResponse() {
        let data = Data("""
        {"is_available":true,"balance_infos":[{"currency":"USD",\
        "total_balance":"1.69","granted_balance":"0.00","topped_up_balance":"1.69"}]}
        """.utf8)

        let balance = DeepSeekBalanceParser.parse(data, now: now)

        XCTAssertEqual(balance?.isAvailable, true)
        XCTAssertEqual(balance?.primary?.currency, "USD")
        XCTAssertEqual(balance?.primary?.total, Decimal(string: "1.69"))
        XCTAssertEqual(balance?.primary?.granted, Decimal(string: "0.00"))
        XCTAssertEqual(balance?.primary?.toppedUp, Decimal(string: "1.69"))
        XCTAssertEqual(balance?.fetchedAt, now)
    }

    func testKeepsEveryCurrencyRowInOrder() {
        let data = Data("""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},
          {"currency":"USD","total_balance":"1.69","granted_balance":"0.00","topped_up_balance":"1.69"}]}
        """.utf8)

        let balance = DeepSeekBalanceParser.parse(data, now: now)

        XCTAssertEqual(balance?.accounts.map(\.currency), ["CNY", "USD"])
        XCTAssertEqual(balance?.primary?.currency, "CNY", "birincil = ilk satır")
    }

    func testMissingAmountsDoNotDropTheRow() {
        // Parse hatası veriyi düşürmez (design/05 §5).
        let data = Data("""
        {"is_available":false,"balance_infos":[{"currency":"usd","total_balance":"oops"}]}
        """.utf8)

        let balance = DeepSeekBalanceParser.parse(data, now: now)

        XCTAssertEqual(balance?.isAvailable, false)
        XCTAssertEqual(balance?.primary?.currency, "USD", "kod normalize edilir")
        XCTAssertNil(balance?.primary?.total)
        XCTAssertNil(balance?.primary?.granted)
    }

    func testEmptyBalanceListIsStillAValidResponse() {
        let data = Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)

        let balance = DeepSeekBalanceParser.parse(data, now: now)

        XCTAssertEqual(balance?.isAvailable, true)
        XCTAssertEqual(balance?.accounts.count, 0)
        XCTAssertNil(balance?.primary)
    }

    func testUnrecognizedBodyIsNil() {
        XCTAssertNil(DeepSeekBalanceParser.parse(Data(#"{"error":"nope"}"#.utf8), now: now))
        XCTAssertNil(DeepSeekBalanceParser.parse(Data("not json".utf8), now: now))
    }

    func testAmountsAreParsedAsDecimalNotDouble() {
        // 0.1 + 0.2 tuzağı: para `Double` üzerinden geçerse yuvarlanır.
        XCTAssertEqual(DeepSeekBalanceParser.amount("0.10"), Decimal(string: "0.10"))
        XCTAssertEqual(DeepSeekBalanceParser.amount("1234.56"), Decimal(string: "1234.56"))
        XCTAssertNil(DeepSeekBalanceParser.amount(""))
        XCTAssertNil(DeepSeekBalanceParser.amount(nil))
    }
}
