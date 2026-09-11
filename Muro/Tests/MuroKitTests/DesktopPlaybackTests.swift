import XCTest
@testable import MuroKit

/// Issue #22. Two switches, both off by default, and one mixed case that is
/// easy to get wrong: Play only on desktop on, Replay off, Pause After set.
final class DesktopPlaybackTests: XCTestCase {

    // MARK: Nothing changes unless a switch is on

    func testWithBothSwitchesOffNothingLooksAtWindows() {
        XCTAssertFalse(DesktopPlayback.needsWindowCheck(playOnlyOnDesktop: false, replayOnClearDesktop: false))
    }

    func testEitherSwitchIsEnoughToLook() {
        XCTAssertTrue(DesktopPlayback.needsWindowCheck(playOnlyOnDesktop: true, replayOnClearDesktop: false))
        XCTAssertTrue(DesktopPlayback.needsWindowCheck(playOnlyOnDesktop: false, replayOnClearDesktop: true))
    }

    func testAConfigWrittenBeforeTheSwitchesLeavesBothOff() throws {
        let config = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"perDisplay":{}}"#.utf8))
        XCTAssertNil(config.playOnlyOnDesktop)
        XCTAssertNil(config.replayOnClearDesktop)
    }

    // MARK: Play only on desktop

    func testAWindowOnTheScreenHoldsItsWallpaper() {
        XCTAssertTrue(DesktopPlayback.holds(isCovered: true, playOnlyOnDesktop: true))
    }

    func testAClearDesktopPlays() {
        XCTAssertFalse(DesktopPlayback.holds(isCovered: false, playOnlyOnDesktop: true))
    }

    func testWithTheSwitchOffAWindowHoldsNothing() {
        XCTAssertFalse(DesktopPlayback.holds(isCovered: true, playOnlyOnDesktop: false))
    }

    func testAScreenNobodyHasLookedAtIsNotHeld() {
        XCTAssertFalse(DesktopPlayback.holds(isCovered: nil, playOnlyOnDesktop: true))
    }

    // MARK: Replay on clear desktop

    func testTheDesktopClearingMakesPauseAfterCountAgain() {
        XCTAssertTrue(DesktopPlayback.restartsPauseAfter(wasCovered: true, isCovered: false, replayOnClearDesktop: true))
    }

    func testWithReplayOffTheDesktopClearingLeavesPauseAfterAlone() {
        // The mixed case. Pause After counts only after a start, an unlock or
        // a new wallpaper, so once it has frozen the wallpaper, a clear
        // desktop leaves it frozen.
        XCTAssertFalse(DesktopPlayback.restartsPauseAfter(wasCovered: true, isCovered: false, replayOnClearDesktop: false))
    }

    func testADesktopThatStaysClearIsAllowedToFreeze() {
        XCTAssertFalse(DesktopPlayback.restartsPauseAfter(wasCovered: false, isCovered: false, replayOnClearDesktop: true))
    }

    func testTheFirstReadingIsNotTheDesktopClearing() {
        XCTAssertFalse(DesktopPlayback.restartsPauseAfter(wasCovered: nil, isCovered: false, replayOnClearDesktop: true))
    }

    func testOpeningAWindowDoesNotMakePauseAfterCount() {
        XCTAssertFalse(DesktopPlayback.restartsPauseAfter(wasCovered: false, isCovered: true, replayOnClearDesktop: true))
    }

    func testTurningTheCheckOffIsNotTheDesktopClearing() {
        XCTAssertFalse(DesktopPlayback.restartsPauseAfter(wasCovered: true, isCovered: nil, replayOnClearDesktop: true))
    }
}
