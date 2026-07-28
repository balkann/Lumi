import XCTest
@testable import LumiMobileKit

final class PairingTests: XCTestCase {

    // Mac tarafı üretimi (RemoteStore.pairingString): ':' ve '/' de encode edilir.
    func testParseMacGeneratedPairingString() {
        let string = "lumi-remote://pair?url=wss%3A%2F%2Flumi-relay-production.up.railway.app&token=abcDEF123-_456789xyzABCDEF0123456789abcdefg"
        let info = Pairing.parse(string)
        XCTAssertEqual(info, PairingInfo(
            relayUrl: "wss://lumi-relay-production.up.railway.app",
            token: "abcDEF123-_456789xyzABCDEF0123456789abcdefg"
        ))
    }

    func testParseTrimsWhitespace() {
        let string = "  lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=0123456789abcdef\n"
        XCTAssertEqual(Pairing.parse(string)?.relayUrl, "wss://r.example")
    }

    func testParseRejectsInvalidInputs() {
        // yanlış şema / host
        XCTAssertNil(Pairing.parse("https://pair?url=wss%3A%2F%2Fr&token=0123456789abcdef"))
        XCTAssertNil(Pairing.parse("lumi-remote://settings?url=wss%3A%2F%2Fr&token=0123456789abcdef"))
        // eksik parametre
        XCTAssertNil(Pairing.parse("lumi-remote://pair?token=0123456789abcdef"))
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=wss%3A%2F%2Fr.example"))
        // kısa token (protokol: ≥16)
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=wss%3A%2F%2Fr.example&token=kisa"))
        // ws(s) olmayan relay url'i
        XCTAssertNil(Pairing.parse("lumi-remote://pair?url=https%3A%2F%2Fr.example&token=0123456789abcdef"))
        // düz metin
        XCTAssertNil(Pairing.parse("hic url degil"))
    }

    func testInMemoryStoreRoundTrip() {
        let store = InMemorySecureStore()
        XCTAssertNil(store.read())
        let info = PairingInfo(relayUrl: "wss://r.example", token: "0123456789abcdef")
        store.write(info)
        XCTAssertEqual(store.read(), info)
        store.clear()
        XCTAssertNil(store.read())
    }
}
