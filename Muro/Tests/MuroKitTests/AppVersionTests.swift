import XCTest
@testable import MuroKit

final class AppVersionTests: XCTestCase {
    /// The failure this exists to prevent. Compared as text, "1.10" sorts
    /// before "1.9", so every install would quietly stop seeing updates.
    func testDoubleDigitMinorIsNewerThanSingleDigit() {
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(AppVersion.isNewer("1.9", than: "1.10"))
    }

    func testMajorVersionWins() {
        XCTAssertTrue(AppVersion.isNewer("3.0", than: "2.9"))
        XCTAssertTrue(AppVersion.isNewer("10.0", than: "9.9"))
        XCTAssertFalse(AppVersion.isNewer("2.0", than: "3.0"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("2.0", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("2.0.0", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("2", than: "2.0.0"))
    }

    func testPatchVersions() {
        XCTAssertTrue(AppVersion.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("2.0", than: "2.0.1"))
    }

    /// GitHub release tags are written "v3.0".
    func testLeadingVIsIgnored() {
        XCTAssertTrue(AppVersion.isNewer("v3.0", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("v2.0", than: "2.0"))
    }

    /// A tag nobody expected must not read as an upgrade.
    func testGarbageIsNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("", than: "2.0"))
        XCTAssertFalse(AppVersion.isNewer("beta", than: "2.0"))
    }

    /// The real comparison this build will make.
    func testThreePointZeroIsNewerThanTwoPointZero() {
        XCTAssertTrue(AppVersion.isNewer("3.0", than: "2.0"))
    }
}
