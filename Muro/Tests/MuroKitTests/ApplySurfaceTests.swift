import XCTest
@testable import MuroKit

final class ApplySurfaceTests: XCTestCase {
    func testRawValuesRoundTrip() throws {
        for surface in ApplySurface.allCases {
            let data = try JSONEncoder().encode(surface)
            let back = try JSONDecoder().decode(ApplySurface.self, from: data)
            XCTAssertEqual(back, surface)
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(ApplySurface.all.rawValue, "All")
        XCTAssertEqual(ApplySurface.desktop.rawValue, "Desktop")
        XCTAssertEqual(ApplySurface.lockscreen.rawValue, "Lockscreen")
        XCTAssertEqual(ApplySurface.screensaver.rawValue, "Screensaver")
    }

    func testScheduleCasesExcludeTheScreenSaver() {
        XCTAssertEqual(ApplySurface.scheduleCases, [.desktop, .lockscreen, .all])
        XCTAssertFalse(ApplySurface.scheduleCases.contains(.screensaver))
    }

    func testScheduleLabels() {
        XCTAssertEqual(ApplySurface.desktop.scheduleLabel, "Desktop")
        XCTAssertEqual(ApplySurface.lockscreen.scheduleLabel, "Lock Screen")
        XCTAssertEqual(ApplySurface.all.scheduleLabel, "Desktop + Lock Screen")
    }

    func testScheduleFanOutIgnoresTheScreenSaverBit() {
        // The rotation tick fans out on coversDesktop / coversLockScreen only.
        // .all carries a screen-saver bit too, but a schedule must never pull
        // the screen saver into a rotation, so the fan-out never reads it.
        let expected: [ApplySurface: (desktop: Bool, lockScreen: Bool)] = [
            .desktop: (true, false),
            .lockscreen: (false, true),
            .all: (true, true),
        ]
        for surface in ApplySurface.scheduleCases {
            let want = expected[surface]!
            XCTAssertEqual(surface.coversDesktop, want.desktop, "\(surface)")
            XCTAssertEqual(surface.coversLockScreen, want.lockScreen, "\(surface)")
        }
    }
}