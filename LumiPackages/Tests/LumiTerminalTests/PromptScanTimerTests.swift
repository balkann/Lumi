import XCTest
@testable import LumiTerminal

final class PromptScanTimerTests: XCTestCase {
    func testTouchSchedulesWithDefaultInterval() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        timer.touch()
        XCTAssertEqual(scheduler.lastInterval, PromptScanTimer.defaultInterval)
    }

    func testFireInvokesOnDue() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        var fired = 0
        timer.onDue = { fired += 1 }
        timer.touch()
        scheduler.fire()
        XCTAssertEqual(fired, 1)
    }

    func testCancelPreventsFire() {
        let scheduler = TestScheduler()
        let timer = PromptScanTimer(scheduler: scheduler)
        var fired = 0
        timer.onDue = { fired += 1 }
        timer.touch()
        timer.cancel()
        scheduler.fire()
        XCTAssertEqual(fired, 0)
    }
}
