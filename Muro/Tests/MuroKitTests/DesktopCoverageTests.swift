import CoreGraphics
import XCTest
@testable import MuroKit

/// Issue #22. The layers and sizes below are the ones a real Mac reported on
/// 2026-09-11: a 1470 × 956 built-in screen with Finder, Safari and Terminal
/// open, desktop widgets, the menu bar, the Dock and a floating overlay.
final class DesktopCoverageTests: XCTestCase {
    typealias Window = DesktopCoverage.Window

    let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
    /// An external display to the right of it.
    let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)

    var screens: [String: CGRect] { ["built-in": builtIn, "external": external] }

    func appWindow(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Window {
        Window(layer: 0, bounds: CGRect(x: x, y: y, width: width, height: height), alpha: 1)
    }

    // MARK: Which screen a window covers

    func testNoWindowsMeansEveryDesktopIsClear() {
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: [], screens: screens), [])
    }

    func testAWindowCoversOnlyTheScreenItIsOn() {
        let safari = appWindow(93, 167, 1272, 794)
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: [safari], screens: screens), ["built-in"])
    }

    func testAWindowOnTheExternalScreenLeavesTheBuiltInScreenClear() {
        let window = appWindow(1600, 100, 800, 600)
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: [window], screens: screens), ["external"])
    }

    func testAWindowAcrossBothScreensCoversBoth() {
        let window = appWindow(1000, 100, 1000, 600)
        XCTAssertEqual(
            DesktopCoverage.coveredScreens(windows: [window], screens: screens),
            ["built-in", "external"]
        )
    }

    func testAFewPointsHangingOverTheEdgeDoNotCoverTheNextScreen() {
        // 20 points of it reach onto the external screen.
        let window = appWindow(500, 100, 990, 600)
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: [window], screens: screens), ["built-in"])
    }

    func testAScreenAboveTheMainOneIsFoundInNegativeCoordinates() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let window = appWindow(200, -900, 800, 600)
        XCTAssertEqual(
            DesktopCoverage.coveredScreens(windows: [window], screens: ["built-in": builtIn, "above": above]),
            ["above"]
        )
    }

    func testAWindowOffEveryScreenCoversNothing() {
        let window = appWindow(5000, 5000, 800, 600)
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: [window], screens: screens), [])
    }

    func testABigPieceOfAWindowCoversAScreenEvenWhenMostOfItIsElsewhere() {
        // 3000 points wide with a 700 × 700 piece on the built-in screen: under
        // a quarter of the window, but plainly covering that desktop.
        let window = appWindow(770, 100, 3000, 700)
        XCTAssertEqual(
            DesktopCoverage.coveredScreens(windows: [window], screens: screens),
            ["built-in", "external"]
        )
    }

    // MARK: Clicking the wallpaper to reveal the desktop

    func testTheStripsLeftByRevealingTheDesktopLeaveItClear() {
        // The window list a real Mac reported while the desktop was revealed:
        // every window slid almost off the screen, a strip of each at an edge.
        let revealed = [
            appWindow(-753, -583, 920, 628),   // Finder, 167 × 45 in the top left corner
            appWindow(-69, -573, 1100, 618),   // Terminal, 1031 × 45 along the top
            appWindow(26, 943, 1272, 794),     // Safari, 1272 × 13 along the bottom
        ]
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: revealed, screens: screens), [])
    }

    func testTheSameWindowsBackInPlaceCoverTheScreenAgain() {
        let inPlace = [
            appWindow(180, 110, 920, 628),
            appWindow(153, 90, 1100, 618),
            appWindow(93, 167, 1272, 794),
        ]
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: inPlace, screens: screens), ["built-in"])
    }

    // MARK: What does not count

    func testTheWallpaperWidgetsDockMenuBarAndOverlaysDoNotCount() {
        let full = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let notAppWindows = [
            Window(layer: -2147483604, bounds: full, alpha: 1),                                      // Muro's wallpaper
            Window(layer: -2147483603, bounds: full, alpha: 1),                                      // Finder's desktop
            Window(layer: -2147483601, bounds: CGRect(x: 4, y: 39, width: 180, height: 180), alpha: 1), // a desktop widget
            Window(layer: 20, bounds: full, alpha: 1),                                               // the Dock
            Window(layer: 24, bounds: CGRect(x: 0, y: 0, width: 1470, height: 33), alpha: 1),        // the menu bar
            Window(layer: 25, bounds: CGRect(x: 1003, y: 0, width: 169, height: 33), alpha: 1),      // a menu bar item
            Window(layer: 1000, bounds: CGRect(x: 479, y: 278, width: 512, height: 586), alpha: 1),  // a floating overlay
        ]
        XCTAssertEqual(DesktopCoverage.coveredScreens(windows: notAppWindows, screens: screens), [])
    }

    func testAFullyTransparentWindowDoesNotCount() {
        let window = Window(layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 0)
        XCTAssertFalse(DesktopCoverage.counts(window))
    }

    func testATinyHelperWindowDoesNotCount() {
        XCTAssertFalse(DesktopCoverage.counts(appWindow(700, 400, 1, 1)))
    }

    func testASmallRealWindowStillCounts() {
        // About the size of Calculator.
        XCTAssertTrue(DesktopCoverage.counts(appWindow(700, 300, 230, 400)))
    }

    // MARK: Settling one look into what is reported

    func testTheFirstLookIsReportedAsItIs() {
        let result = DesktopCoverage.settle(previous: nil, current: ["built-in"], confirming: false)
        XCTAssertEqual(result.report, ["built-in"])
        XCTAssertFalse(result.needsConfirmation)
    }

    func testANewlyCoveredScreenIsReportedAtOnce() {
        let result = DesktopCoverage.settle(previous: [], current: ["built-in"], confirming: false)
        XCTAssertEqual(result.report, ["built-in"])
        XCTAssertFalse(result.needsConfirmation)
    }

    func testANewlyClearScreenWaitsForASecondLook() {
        let result = DesktopCoverage.settle(previous: ["built-in"], current: [], confirming: false)
        XCTAssertEqual(result.report, ["built-in"])
        XCTAssertTrue(result.needsConfirmation)
    }

    func testTheSecondLookReportsItClear() {
        let result = DesktopCoverage.settle(previous: ["built-in"], current: [], confirming: true)
        XCTAssertEqual(result.report, [])
        XCTAssertFalse(result.needsConfirmation)
    }

    func testAWindowBackByTheSecondLookKeepsTheScreenCovered() {
        let result = DesktopCoverage.settle(previous: ["built-in"], current: ["built-in"], confirming: true)
        XCTAssertEqual(result.report, ["built-in"])
        XCTAssertFalse(result.needsConfirmation)
    }

    func testOneScreenClearingDoesNotHoldBackAnotherBeingCovered() {
        let result = DesktopCoverage.settle(previous: ["built-in"], current: ["external"], confirming: false)
        XCTAssertEqual(result.report, ["built-in", "external"])
        XCTAssertTrue(result.needsConfirmation)
    }
}
