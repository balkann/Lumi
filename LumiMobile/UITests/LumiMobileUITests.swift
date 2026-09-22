import XCTest

final class LumiMobileUITests: XCTestCase {

    // MARK: - testPairManually
    /// Reads PAIRING_STRING from the test environment, enters it into the pairing
    /// TextField, taps "Pair", and asserts the session list screen appears.
    func testPairManually() throws {
        guard let pairingString = ProcessInfo.processInfo.environment["PAIRING_STRING"],
              !pairingString.isEmpty else {
            throw XCTSkip("PAIRING_STRING environment variable not set — skipping pairing test")
        }

        let app = XCUIApplication()
        app.launch()

        // If the app is already paired and on the list screen, skip.
        let lumiNav = app.navigationBars["Lumi"]
        if lumiNav.waitForExistence(timeout: 3) {
            throw XCTSkip("already paired — list screen visible at launch")
        }

        // Tap the pairing text field and type the pairing string.
        let pairingField = app.textFields["pairingField"]
        XCTAssertTrue(pairingField.waitForExistence(timeout: 5), "pairingField not found")
        pairingField.tap()
        // Small settle pause so the keyboard appears before typing.
        sleep(1)
        pairingField.typeText(pairingString)

        // Tap the Pair button.
        let pairButton = app.buttons["pairButton"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 3), "pairButton not found")
        pairButton.tap()

        // Assert the session list screen appears (nav title "Lumi") within 15s.
        XCTAssertTrue(
            app.navigationBars["Lumi"].waitForExistence(timeout: 15),
            "Expected session list 'Lumi' nav bar to appear after pairing"
        )

        // Assert offline banner is NOT shown: wait up to 10s for either a
        // session row or the empty-state text to appear (meaning we're online).
        let emptyState = app.staticTexts["No active sessions"]
        let firstCell = app.cells.firstMatch

        let deadline = Date().addingTimeInterval(10)
        var connectionSettled = false
        while Date() < deadline {
            if emptyState.exists || (firstCell.exists && firstCell.isHittable) {
                connectionSettled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(connectionSettled, "App did not reach a settled online state within 10s after pairing")

        // Verify the offline banner is absent.
        let offlinePredicate = NSPredicate(format: "label BEGINSWITH %@", "Mac offline")
        let offlineTexts = app.staticTexts.matching(offlinePredicate)
        XCTAssertEqual(offlineTexts.count, 0, "Offline banner should not be visible while Mac is online")
    }

    // MARK: - testSendTextToFirstSession
    /// Requires the app to be already paired with at least one active session.
    /// Navigates into the first session and sends a test message.
    func testSendTextToFirstSession() throws {
        let app = XCUIApplication()
        app.launch()

        // Wait for session list.
        let lumiNav = app.navigationBars["Lumi"]
        XCTAssertTrue(lumiNav.waitForExistence(timeout: 10), "Session list 'Lumi' nav bar not found")

        // Wait for at least one session row (cell).
        let firstCell = app.cells.firstMatch
        let hasCells = firstCell.waitForExistence(timeout: 10)
        XCTAssertTrue(hasCells, "No session cells found — is the app paired with an active session?")
        firstCell.tap()

        // Wait for the message text field in SessionDetailView.
        let messageField = app.textFields["messageField"]
        XCTAssertTrue(
            messageField.waitForExistence(timeout: 10),
            "messageField not found in session detail"
        )
        messageField.tap()
        sleep(1)
        let testMessage = "merhaba lumi e2e testi"
        messageField.typeText(testMessage)

        // Tap the send button.
        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "sendButton not found")
        sendButton.tap()

        // Assert no error label appeared.
        let deadline = Date().addingTimeInterval(10)
        var fieldCleared = false
        while Date() < deadline {
            // Draft field should be cleared after a successful send.
            let currentValue = messageField.value as? String ?? ""
            if currentValue.isEmpty || currentValue == messageField.placeholderValue {
                fieldCleared = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(fieldCleared, "Message field was not cleared after send — send may have failed")

        // Ensure no "command failed to send" error appeared.
        XCTAssertFalse(
            app.staticTexts["command failed to send"].exists,
            "Error label 'command failed to send' should not appear after a successful send"
        )
    }

    // MARK: - testOfflineBanner
    /// Requires the app to be already paired while the Mac side is OFFLINE.
    /// Asserts the offline banner appears within 20s.
    func testOfflineBanner() throws {
        let app = XCUIApplication()
        app.launch()

        // Wait for the session list screen.
        let lumiNav = app.navigationBars["Lumi"]
        XCTAssertTrue(lumiNav.waitForExistence(timeout: 10), "Session list 'Lumi' nav bar not found")

        // Assert offline banner appears within 20s.
        let offlinePredicate = NSPredicate(format: "label BEGINSWITH %@", "Mac offline")
        let offlineBanner = app.staticTexts.matching(offlinePredicate).firstMatch
        XCTAssertTrue(
            offlineBanner.waitForExistence(timeout: 20),
            "Offline banner starting with 'Mac offline' did not appear within 20s"
        )
    }
}
