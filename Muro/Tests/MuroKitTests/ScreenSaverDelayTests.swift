import XCTest
@testable import MuroKit

/// The list and the wording only. Nothing here reads or writes the real
/// preference: these tests run on the owner's own Mac, and a test that set
/// `idleTime` would change when his screen saver starts as a side effect of
/// running the suite.
final class ScreenSaverDelayTests: XCTestCase {

    // MARK: The list

    func testTheChoicesAreApplesOwnList() {
        XCTAssertEqual(ScreenSaverDelay.choices, [
            60,     // After 1 minute
            120,    // After 2 minutes
            180,    // After 3 minutes
            300,    // After 5 minutes
            600,    // After 10 minutes
            1200,   // After 20 minutes
            1800,   // After 30 minutes
            3600,   // After 1 hour
            5400,   // After 1 hour, 30 minutes
            7200,   // After 2 hours
            9000,   // After 2 hours, 30 minutes
            10800,  // After 3 hours
            0,      // Never
        ])
    }

    func testNeverIsLastSoTheDestructiveChoiceIsNotInTheMiddleOfTheDurations() {
        XCTAssertEqual(ScreenSaverDelay.choices.last, ScreenSaverDelay.never)
    }

    /// `never` has to stay below the one-second guard in loginwindow's
    /// `_checkUserIdleDuringReset:`. Raise it above that and "Never" quietly
    /// becomes "almost immediately".
    func testNeverIsBelowTheOneSecondGuardThatMakesItWork() {
        XCTAssertLessThan(ScreenSaverDelay.never, 1)
    }

    func testTheDurationsRiseAndNoneRepeat() {
        let durations = ScreenSaverDelay.choices.filter { $0 > 0 }
        XCTAssertEqual(durations, durations.sorted())
        XCTAssertEqual(Set(durations).count, durations.count)
    }

    // MARK: The wording

    func testMinutesReadAsMinutes() {
        XCTAssertEqual(ScreenSaverDelay.label(60), "1 min")
        XCTAssertEqual(ScreenSaverDelay.label(300), "5 min")
        XCTAssertEqual(ScreenSaverDelay.label(1800), "30 min")
    }

    func testHoursReadAsHours() {
        XCTAssertEqual(ScreenSaverDelay.label(3600), "1 h")
        XCTAssertEqual(ScreenSaverDelay.label(5400), "1 h 30 min")
        XCTAssertEqual(ScreenSaverDelay.label(9000), "2 h 30 min")
        XCTAssertEqual(ScreenSaverDelay.label(10800), "3 h")
    }

    func testZeroReadsAsNever() {
        XCTAssertEqual(ScreenSaverDelay.label(ScreenSaverDelay.never), "Never")
    }

    /// Nothing Muro writes is negative, but Apple's key is a plain integer
    /// anyone can put anything in, and a negative one is still a target below
    /// the guard, so it means the same thing.
    func testANegativeValueAlsoReadsAsNever() {
        XCTAssertEqual(ScreenSaverDelay.label(-30), "Never")
    }

    func testAnAbsentPreferenceSaysSoRatherThanNamingADurationMuroDoesNotKnow() {
        XCTAssertEqual(ScreenSaverDelay.label(nil), "System default")
    }

    /// A value set by hand, or by an older macOS, still has to render.
    func testAValueOutsideTheListStillReads() {
        XCTAssertEqual(ScreenSaverDelay.label(45), "45 s")
        XCTAssertEqual(ScreenSaverDelay.label(2700), "45 min")
    }

    func testEveryChoiceHasALabel() {
        for seconds in ScreenSaverDelay.choices {
            XCTAssertFalse(ScreenSaverDelay.label(seconds).isEmpty)
        }
    }
}
