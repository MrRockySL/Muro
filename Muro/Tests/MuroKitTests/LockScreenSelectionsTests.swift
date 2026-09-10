import XCTest
@testable import MuroKit

/// The rule that let one display's lock screen survive another display's apply.
/// Every case here is the owner's Mac on 2026-09-10: a MacBook and a DELL.
final class LockScreenSelectionsTests: XCTestCase {
    let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    let dell = "C4497200-61AC-4C2C-B727-10348E552634"
    var connected: Set<String> { [macBook, dell] }

    /// The bug. Applying to the second display used to leave only the second.
    func testASecondDisplayDoesNotThrowAwayTheFirst() {
        var s = LockScreenSelections.afterApply(
            current: [:], targetKey: dell, wallpaperID: "rabbit",
            connectedDisplays: connected
        )
        s = LockScreenSelections.afterApply(
            current: s, targetKey: macBook, wallpaperID: "bus",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, [dell: "rabbit", macBook: "bus"])
    }

    func testApplyingAgainToOneDisplayReplacesOnlyThatOne() {
        let s = LockScreenSelections.afterApply(
            current: [dell: "rabbit", macBook: "bus"],
            targetKey: macBook, wallpaperID: "forest",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, [dell: "rabbit", macBook: "forest"])
    }

    /// Every display at once supersedes each of them, so it stands alone.
    /// This is the case that was already right and must stay that way.
    func testAllSupersedesEveryPerDisplayChoice() {
        let s = LockScreenSelections.afterApply(
            current: [dell: "rabbit", macBook: "bus"],
            targetKey: LockScreenSelections.allKey, wallpaperID: "snow",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, ["all": "snow"])
    }

    /// A screen saver apply always carries "all", so its record is unchanged.
    func testScreenSaverRecordIsUnchanged() {
        let s = LockScreenSelections.afterApply(
            current: ["all": "old"],
            targetKey: LockScreenSelections.allKey, wallpaperID: "new",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, ["all": "new"])
    }

    /// `all` is kept beside a per-display entry: it is still what a display
    /// without one of its own is reading, and the desktop still writer asks
    /// this record before it writes a picture into a display's slot.
    func testAllSurvivesBesideAPerDisplayChoice() {
        let s = LockScreenSelections.afterApply(
            current: ["all": "snow"], targetKey: macBook, wallpaperID: "bus",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, ["all": "snow", macBook: "bus"])
    }

    /// What stops this growing without limit, which is the reason it was
    /// written the destructive way in the first place. Every staged wallpaper
    /// is a row in System Settings.
    func testADisplayThatIsNoLongerPluggedInIsDropped() {
        let old = "11111111-2222-3333-4444-555555555555"
        let s = LockScreenSelections.afterApply(
            current: [old: "gone", dell: "rabbit"],
            targetKey: macBook, wallpaperID: "bus",
            connectedDisplays: connected
        )
        XCTAssertEqual(s, [dell: "rabbit", macBook: "bus"])
        XCTAssertNil(s[old])
    }

    func testItNeverHoldsMoreThanOnePerConnectedDisplayPlusAll() {
        var s: [String: String] = [:]
        for round in 0..<20 {
            s = LockScreenSelections.afterApply(
                current: s, targetKey: round.isMultiple(of: 2) ? macBook : dell,
                wallpaperID: "w\(round)", connectedDisplays: connected
            )
        }
        XCTAssertEqual(s.count, 2)
    }
}
