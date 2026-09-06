import XCTest
@testable import MuroKit

/// Issue #20: the app menu has no Settings item.
final class AppMenuSettingsTests: XCTestCase {
    /// The menu name must include an ellipsis. The item opens a window.
    func testTitleUsesAnEllipsis() {
        XCTAssertEqual(AppMenuSettings.title, "Settings…")
        XCTAssertNotEqual(AppMenuSettings.title, "Settings")
    }

    /// Command-comma is the shortcut for Settings on macOS.
    func testShortcutIsComma() {
        XCTAssertEqual(AppMenuSettings.shortcut, ",")
    }

    /// The command must open the existing Settings window. A new id makes a second window.
    func testWindowIDIsTheExistingSettingsScene() {
        XCTAssertEqual(AppMenuSettings.windowID, "settings")
    }

    /// The app must become active before the window opens.
    func testPresentMakesTheAppActiveThenOpensTheWindow() {
        var order: [String] = []
        AppMenuSettings.present(
            activate: { order.append("activate") },
            open: { order.append("open") }
        )
        XCTAssertEqual(order, ["activate", "open"])
    }

    /// A missing opener must not stop activation. The gallery may not have set the opener yet.
    func testPresentWithNoOpenerStillActivates() {
        var activated = false
        AppMenuSettings.present(activate: { activated = true }, open: nil)
        XCTAssertTrue(activated)
    }

    /// Two calls must use the same open function. The path must not make a second window.
    func testTwoPresentsUseTheSameOpenFunction() {
        var count = 0
        let open = { count += 1 }
        AppMenuSettings.present(activate: {}, open: open)
        AppMenuSettings.present(activate: {}, open: open)
        XCTAssertEqual(count, 2)
    }
}
