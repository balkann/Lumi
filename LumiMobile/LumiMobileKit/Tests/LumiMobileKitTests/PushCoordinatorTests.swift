import XCTest
@testable import LumiMobileKit

final class PreferenceStoreTests: XCTestCase {
    func testInMemoryPreferenceStoreRoundTrip() {
        let prefs = InMemoryPreferenceStore()
        XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
        prefs.set(true, forKey: "notificationsEnabled")
        XCTAssertTrue(prefs.bool(forKey: "notificationsEnabled"))
        prefs.set(false, forKey: "notificationsEnabled")
        XCTAssertFalse(prefs.bool(forKey: "notificationsEnabled"))
    }
}
