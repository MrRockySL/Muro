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

/// The behaviour the owner specified on 2026-09-10, written as a test so the
/// "one at a time" rule cannot come back by accident. Two displays hold five
/// wallpapers: a desktop and a lock screen each, plus one screen saver.
final class TwoDisplayLockScreenSpecTests: XCTestCase {
    let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    let dell = "C4497200-61AC-4C2C-B727-10348E552634"

    /// C on the MacBook, D on the DELL, E as the screen saver. All three
    /// survive, and the screen saver is kept in its own record so a lock
    /// screen apply can never prune its staged file.
    func testCDandEAllSurvive() {
        var locks: [String: String] = [:]
        let connected: Set<String> = [macBook, dell]
        locks = LockScreenSelections.afterApply(
            current: locks, targetKey: macBook, wallpaperID: "C", connectedDisplays: connected
        )
        locks = LockScreenSelections.afterApply(
            current: locks, targetKey: dell, wallpaperID: "D", connectedDisplays: connected
        )
        let saver = LockScreenSelections.afterApply(
            current: [:], targetKey: LockScreenSelections.allKey,
            wallpaperID: "E", connectedDisplays: connected
        )
        XCTAssertEqual(locks, [macBook: "C", dell: "D"])
        XCTAssertEqual(saver, ["all": "E"])
        // Everything that must stay staged: both lock screens and the saver.
        let held = Set(locks.values).union(saver.values)
        XCTAssertEqual(held, ["C", "D", "E"])
    }

    /// Four displays, same shape: four lock screens plus one screen saver.
    func testItScalesToFourDisplays() {
        let ids = (1...4).map { "display-\($0)" }
        let connected = Set(ids)
        var locks: [String: String] = [:]
        for (i, id) in ids.enumerated() {
            locks = LockScreenSelections.afterApply(
                current: locks, targetKey: id, wallpaperID: "lock\(i)",
                connectedDisplays: connected
            )
        }
        XCTAssertEqual(locks.count, 4)
        XCTAssertEqual(Set(locks.values).count, 4)
    }
}
