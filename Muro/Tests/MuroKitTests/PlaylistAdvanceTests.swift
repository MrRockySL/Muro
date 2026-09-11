import XCTest
@testable import MuroKit

final class PlaylistAdvanceTests: XCTestCase {
    private let ids = ["A", "B", "C"]

    // MARK: - D8: a lockscreen-only playlist must still advance

    /// The regression case: nothing here reads any surface's applied state,
    /// so a `.lockscreen`-only playlist advances exactly like a `.desktop` one
    /// across repeated ticks — feeding each result back in as the next tick's
    /// `current`, the way `AutomationScheduler.playlistCurrentID` does.
    func testALockscreenOnlyPlaylistAdvancesAcrossRepeatedReevaluateTicks() {
        var current: String? = ids[0]
        var seen = [current]
        for _ in 0..<(ids.count * 2) {
            let next = PlaylistAdvance.next(ids: ids, current: current, shuffle: false, forward: true)
            current = next
            seen.append(next)
        }
        XCTAssertEqual(seen, ["A", "B", "C", "A", "B", "C", "A"])
    }

    /// A `.desktop` / `.all` playlist's ordering is unaffected: the function
    /// has no notion of surface at all, so this is the same call the desktop
    /// path already made before D8.
    func testForwardAdvancesToTheNextID() {
        XCTAssertEqual(PlaylistAdvance.next(ids: ids, current: "A", shuffle: false, forward: true), "B")
        XCTAssertEqual(PlaylistAdvance.next(ids: ids, current: "C", shuffle: false, forward: true), "A")
    }

    func testBackwardAdvancesToThePreviousID() {
        XCTAssertEqual(PlaylistAdvance.next(ids: ids, current: "A", shuffle: false, forward: false), "C")
        XCTAssertEqual(PlaylistAdvance.next(ids: ids, current: "B", shuffle: false, forward: false), "A")
    }

    func testNoCurrentIDFallsBackToTheFirstEntry() {
        // The scheduler's persisted id is nil only before a playlist's first
        // ever tick — startPlaylist always sets it right after this.
        XCTAssertEqual(PlaylistAdvance.next(ids: ids, current: nil, shuffle: false, forward: true), "B")
    }

    func testAnUnknownCurrentIDFallsBackToTheFirstEntry() {
        XCTAssertEqual(
            PlaylistAdvance.next(ids: ids, current: "not-in-the-list", shuffle: false, forward: true),
            "B"
        )
    }

    func testShuffleNeverRepeatsTheCurrentIDWhenMoreThanOneExists() {
        for _ in 0..<20 {
            let next = PlaylistAdvance.next(ids: ids, current: "A", shuffle: true, forward: true)
            XCTAssertNotEqual(next, "A")
            XCTAssertTrue(ids.contains(next ?? ""))
        }
    }

    func testShuffleWithASingleIDReturnsItself() {
        XCTAssertEqual(PlaylistAdvance.next(ids: ["A"], current: "A", shuffle: true, forward: true), "A")
    }

    func testEmptyIDsReturnsNil() {
        XCTAssertNil(PlaylistAdvance.next(ids: [], current: nil, shuffle: false, forward: true))
    }
}
