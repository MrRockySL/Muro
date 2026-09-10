import XCTest
@testable import MuroKit

/// The pure decisions behind a rotating lock screen. The store writes and the
/// file swaps live in `LockScreenService` (MuroApp) and are covered by the
/// manual playback spikes; everything decidable without a real container is
/// here.
final class LockScreenRotationTests: XCTestCase {
    let schedule = "6b1f2c9e-0000-4a4a-9b9b-111111111111"
    let stepA = "aaaa1111-2222-4333-8444-555566667777"
    let stepB = "bbbb1111-2222-4333-8444-555566667777"

    // MARK: - The fixed id

    func testTheStoreIDIsTheScheduleIDUnchanged() {
        XCTAssertEqual(LockScreenRotation.storeID(scheduleID: schedule), schedule)
    }

    /// The store is written once, so the id that lands in the selection record
    /// is the schedule's own and it stays put across steps.
    func testTheRotationIDFlowsThroughAfterApplyAndStandsAlone() {
        let displays: Set<String> = ["37D8832A-2D66-02CA-B9F7-8F30A301B230"]
        var record = LockScreenSelections.afterApply(
            current: [:],
            targetKey: LockScreenSelections.allKey,
            wallpaperID: LockScreenRotation.storeID(scheduleID: schedule),
            connectedDisplays: displays
        )
        XCTAssertEqual(record, [LockScreenSelections.allKey: schedule])
        // A later step does not re-apply, so the record is identical.
        record = LockScreenSelections.afterApply(
            current: record,
            targetKey: LockScreenSelections.allKey,
            wallpaperID: schedule,
            connectedDisplays: displays
        )
        XCTAssertEqual(record, [LockScreenSelections.allKey: schedule])
    }

    // MARK: - isApplied resolves through the current step

    func testARotationSelectionResolvesToTheStepShowingNow() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: schedule, rotationID: schedule, currentStepID: stepA
            ),
            stepA
        )
    }

    func testAdvancingTheStepMovesWhatCountsAsApplied() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: schedule, rotationID: schedule, currentStepID: stepB
            ),
            stepB
        )
    }

    func testAPlainSelectionStandsForItself() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: stepA, rotationID: schedule, currentStepID: stepB
            ),
            stepA
        )
    }

    func testNoRotationLeavesTheSelectionUntouched() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: stepA, rotationID: nil, currentStepID: nil
            ),
            stepA
        )
    }

    func testAnEmptySelectionResolvesToNothing() {
        XCTAssertNil(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: nil, rotationID: schedule, currentStepID: stepA
            )
        )
    }

    // MARK: - Orphan detection for healIfNeeded

    func testARunningRotationIsNotOrphaned() {
        XCTAssertFalse(
            LockScreenRotation.isOrphaned(
                rotationID: schedule, runningScheduleIDs: [schedule]
            )
        )
    }

    func testARotationWhoseScheduleStoppedIsOrphaned() {
        XCTAssertTrue(
            LockScreenRotation.isOrphaned(rotationID: schedule, runningScheduleIDs: [])
        )
    }

    func testARotationForADifferentScheduleIsOrphaned() {
        XCTAssertTrue(
            LockScreenRotation.isOrphaned(
                rotationID: schedule, runningScheduleIDs: ["some-other-schedule"]
            )
        )
    }

    func testNoRotationIsNeverOrphaned() {
        XCTAssertFalse(
            LockScreenRotation.isOrphaned(rotationID: nil, runningScheduleIDs: [])
        )
    }
}
