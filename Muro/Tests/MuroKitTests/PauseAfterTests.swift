import XCTest
@testable import MuroKit

/// Issue #3, "Pause after x sec". The feature shipped untested, and the one
/// rule inside it is exactly the kind that breaks quietly.
final class PauseAfterTests: XCTestCase {

    // MARK: The global setting

    func testNoSettingAnywhereMeansKeepPlaying() {
        XCTAssertNil(PauseAfter.resolve(wallpaper: nil, global: nil))
    }

    func testTheGlobalSettingAppliesToAWallpaperWithoutOneOfItsOwn() {
        XCTAssertEqual(PauseAfter.resolve(wallpaper: nil, global: 30), 30)
    }

    func testAGlobalSettingOfZeroIsOff() {
        XCTAssertNil(PauseAfter.resolve(wallpaper: nil, global: 0))
    }

    // MARK: The per-wallpaper override

    func testAWallpaperOverridesTheGlobalSetting() {
        XCTAssertEqual(PauseAfter.resolve(wallpaper: 10, global: 300), 10)
        XCTAssertEqual(PauseAfter.resolve(wallpaper: 3600, global: 10), 3600)
    }

    func testAWallpaperCanOptOutWhileTheSettingStillAppliesElsewhere() {
        // The trap. Zero is "never pause", a decision the user made in the
        // wallpaper's own menu. It must not read as "no opinion" and fall
        // through to the global setting, or the one wallpaper someone asked
        // to keep playing is the one that freezes.
        XCTAssertNil(PauseAfter.resolve(wallpaper: 0, global: 30))
        XCTAssertNil(PauseAfter.resolve(wallpaper: 0, global: 3600))
    }

    func testAWallpaperCanPauseWhileTheGlobalSettingIsOff() {
        XCTAssertEqual(PauseAfter.resolve(wallpaper: 15, global: 0), 15)
        XCTAssertEqual(PauseAfter.resolve(wallpaper: 15, global: nil), 15)
    }

    // MARK: Normalising

    func testNegativesAndZeroCollapseToKeepPlaying() {
        XCTAssertNil(PauseAfter.normalise(nil))
        XCTAssertNil(PauseAfter.normalise(0))
        XCTAssertNil(PauseAfter.normalise(-1))
        XCTAssertNil(PauseAfter.normalise(Int.min))
    }

    func testAPositiveDurationSurvivesUntouched() {
        for seconds in [1, 10, 30, 60, 120, 300, 900, 3600, 86_400] {
            XCTAssertEqual(PauseAfter.normalise(seconds), seconds)
        }
    }

    /// A negative value should never reach the engine, and if one ever does it
    /// must not arm a timer with a negative interval.
    func testANegativeOverrideDoesNotBecomeATimer() {
        XCTAssertNil(PauseAfter.resolve(wallpaper: -5, global: 30))
        XCTAssertNil(PauseAfter.resolve(wallpaper: nil, global: -5))
    }

    // MARK: The choices the Settings menu offers

    func testEverySettingsChoiceResolvesToItself() {
        for seconds in [10, 30, 60, 120, 300, 900, 3600] {
            XCTAssertEqual(PauseAfter.resolve(wallpaper: nil, global: seconds), seconds)
        }
        XCTAssertNil(PauseAfter.resolve(wallpaper: nil, global: 0))  // "Off"
    }
}


final class StandardFrameRateTests: XCTestCase {
    /// The live catalog's own rates on 2026-10-01, odd ones included.
    func testEveryCatalogRateLandsOnAStandardOne() {
        XCTAssertEqual(standardFrameRate(59.94), 60)
        XCTAssertEqual(standardFrameRate(60.16), 60)
        XCTAssertEqual(standardFrameRate(29.97), 30)
        XCTAssertEqual(standardFrameRate(28.26), 30)
        XCTAssertEqual(standardFrameRate(33.35), 30)
        XCTAssertEqual(standardFrameRate(36.78), 30)
        XCTAssertEqual(standardFrameRate(44.82), 50)
        XCTAssertEqual(standardFrameRate(66.86), 72)
        XCTAssertEqual(standardFrameRate(69.89), 72)
        XCTAssertEqual(standardFrameRate(23.98), 24)
        XCTAssertEqual(standardFrameRate(24.71), 25)
        XCTAssertEqual(standardFrameRate(120), 120)
    }

    func testNothingIsZeroUnlessItHasNoRate() {
        XCTAssertEqual(standardFrameRate(0), 0)
        XCTAssertEqual(standardFrameRate(.nan), 0)
        XCTAssertEqual(standardFrameRate(240), 240)
    }
}
