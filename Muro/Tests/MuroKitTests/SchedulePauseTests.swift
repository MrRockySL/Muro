import XCTest
@testable import MuroKit

final class SchedulePauseTests: XCTestCase {
    func testRebasingByThePauseDurationKeepsTheRemainingTimeConstant() {
        let stepDuration: TimeInterval = 300
        let start = Date(timeIntervalSince1970: 1_000_000)
        // 120s into the step, pause for 90s.
        let pausedAt = start.addingTimeInterval(120)
        let resumedAt = pausedAt.addingTimeInterval(90)

        let rebased = SchedulePause.rebasedStepStart(start, heldFor: resumedAt.timeIntervalSince(pausedAt))

        // Before: 180s left. After: still 180s left, measured from resume.
        XCTAssertEqual(
            rebased.addingTimeInterval(stepDuration).timeIntervalSince(resumedAt),
            180,
            accuracy: 0.001
        )
    }

    func testANegativeHoldIsIgnored() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SchedulePause.rebasedStepStart(start, heldFor: -50), start)
    }
}