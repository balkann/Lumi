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

final class FakeAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    var status: NotificationAuthStatus = .notDetermined
    var grantResult = true
    private(set) var requestCount = 0
    func authorizationStatus() async -> NotificationAuthStatus { status }
    func requestAuthorization() async -> Bool { requestCount += 1; return grantResult }
}

@MainActor
final class FakeRegistrar: RemoteRegistering {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    func registerForRemoteNotifications() { registerCount += 1 }
    func unregisterForRemoteNotifications() { unregisterCount += 1 }
}

@MainActor
final class PushCoordinatorTests: XCTestCase {
    private func make() -> (AppModel, PushCoordinator, FakeAuthorizer, FakeRegistrar, FakeRelayClient) {
        let client = FakeRelayClient()
        let model = AppModel(client: client, store: InMemorySecureStore(), prefs: InMemoryPreferenceStore())
        let auth = FakeAuthorizer()
        let reg = FakeRegistrar()
        let coord = PushCoordinator(model: model, authorizer: auth, registrar: reg)
        model.pushControl = coord
        return (model, coord, auth, reg, client)
    }

    func testEnableWhenNotDeterminedRequestsAndRegisters() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .notDetermined; auth.grantResult = true
        let result = await coord.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(auth.requestCount, 1)
        XCTAssertEqual(reg.registerCount, 1)
        XCTAssertTrue(model.notificationsEnabled)
        XCTAssertEqual(model.notificationAuthStatus, .authorized)
    }

    func testEnableWhenDeniedReturnsNeedsSettings() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .denied
        let result = await coord.enable()
        XCTAssertEqual(result, .needsSettings)
        XCTAssertEqual(reg.registerCount, 0)
        XCTAssertFalse(model.notificationsEnabled)
    }

    func testEnableWhenAuthorizedRegistersWithoutPrompt() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .authorized
        let result = await coord.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(auth.requestCount, 0)
        XCTAssertEqual(reg.registerCount, 1)
        XCTAssertTrue(model.notificationsEnabled)
    }

    func testRequestDeclinedReturnsDeclined() async {
        let (model, coord, auth, _, _) = make()
        auth.status = .notDetermined; auth.grantResult = false
        let result = await coord.enable()
        XCTAssertEqual(result, .declined)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(model.notificationAuthStatus, .denied)
    }

    func testDisableMarksModelAndUnregisters() async {
        let (model, coord, auth, reg, _) = make()
        auth.status = .authorized
        _ = await coord.enable()
        await coord.disable()
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(reg.unregisterCount, 1)
    }

    func testOnPairingSucceededRequestsOnlyWhenNotDetermined() async {
        let (_, coord, auth, reg, _) = make()
        auth.status = .authorized
        await coord.onPairingSucceeded()
        XCTAssertEqual(auth.requestCount, 0)   // notDetermined değil → prompt yok
        XCTAssertEqual(reg.registerCount, 0)

        auth.status = .notDetermined; auth.grantResult = true
        await coord.onPairingSucceeded()
        XCTAssertEqual(auth.requestCount, 1)
        XCTAssertEqual(reg.registerCount, 1)
    }

    func testHandleDeviceTokenForwardsToModelAndRegisters() async {
        let (model, coord, auth, _, client) = make()
        auth.status = .authorized
        _ = await coord.enable()               // enabled + token yok → kayıt tetiklenmez
        XCTAssertTrue(client.pushRegistrations.isEmpty)
        await coord.handleDeviceToken("tok-xyz")   // token geldi + enabled → registerPush
        XCTAssertEqual(model.notificationAuthStatus, .authorized)
        XCTAssertEqual(client.pushRegistrations, ["tok-xyz"])
    }
}
