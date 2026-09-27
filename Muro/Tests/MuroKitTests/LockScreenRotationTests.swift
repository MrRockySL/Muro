import XCTest
@testable import MuroKit

/// The pure rules behind a playlist or automation on the lock screen or the
/// screen saver. The store writes and the file swaps live in
/// `LockScreenService` (MuroApp); everything decidable without a real
/// extension container is here.
final class LockScreenRotationTests: XCTestCase {
    let stepA = "aaaa1111-2222-4333-8444-555566667777"
    let stepB = "bbbb1111-2222-4333-8444-555566667777"

    // MARK: - The fixed ids

    func testEachRoleHasItsOwnFixedID() {
        XCTAssertEqual(LockScreenRotation.fixedID(for: .desktop), LockScreenRotation.lockScreenID)
        XCTAssertEqual(LockScreenRotation.fixedID(for: .screenSaver), LockScreenRotation.screenSaverID)
        XCTAssertNotEqual(LockScreenRotation.lockScreenID, LockScreenRotation.screenSaverID)
    }

    /// The extension recognises a rotation by the prefix alone, and must never
    /// take a wallpaper's own id for one.
    func testOnlyTheFixedIDsCountAsRotations() {
        XCTAssertTrue(LockScreenRotation.isRotationID(LockScreenRotation.lockScreenID))
        XCTAssertTrue(LockScreenRotation.isRotationID(LockScreenRotation.screenSaverID))
        XCTAssertFalse(LockScreenRotation.isRotationID(stepA))
        XCTAssertFalse(LockScreenRotation.isRotationID(nil))
    }

    /// `lockscreen.json` keeps the current wallpaper of each role apart.
    func testEachRoleKeepsItsCurrentWallpaperUnderItsOwnKey() {
        XCTAssertNotEqual(
            LockScreenRotation.stateKey(for: .desktop),
            LockScreenRotation.stateKey(for: .screenSaver)
        )
    }

    /// The first step writes the fixed id for every display, and it stays put
    /// across steps, which only swap the file behind it.
    func testTheFixedIDStandsAloneForEveryDisplay() {
        let displays: Set<String> = ["37D8832A-2D66-02CA-B9F7-8F30A301B230"]
        let fixed = LockScreenRotation.lockScreenID
        let record = LockScreenSelections.afterApply(
            current: ["37D8832A-2D66-02CA-B9F7-8F30A301B230": stepA],
            targetKey: LockScreenSelections.allKey,
            wallpaperID: fixed,
            connectedDisplays: displays
        )
        XCTAssertEqual(record, [LockScreenSelections.allKey: fixed])
    }

    // MARK: - What a selection stands for

    func testTheFixedIDStandsForTheStepShowingNow() {
        let fixed = LockScreenRotation.lockScreenID
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: fixed, rotationID: fixed, currentStepID: stepA
            ),
            stepA
        )
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: fixed, rotationID: fixed, currentStepID: stepB
            ),
            stepB
        )
    }

    func testAWallpaperIDStandsForItself() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: stepA,
                rotationID: LockScreenRotation.lockScreenID,
                currentStepID: stepB
            ),
            stepA
        )
    }

    /// The screen saver's id never stands for the lock screen's step.
    func testTheOtherRolesIDIsNotResolved() {
        XCTAssertEqual(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: LockScreenRotation.screenSaverID,
                rotationID: LockScreenRotation.lockScreenID,
                currentStepID: stepA
            ),
            LockScreenRotation.screenSaverID
        )
    }

    func testAnEmptySelectionResolvesToNothing() {
        XCTAssertNil(
            LockScreenRotation.resolvedWallpaperID(
                selectionValue: nil,
                rotationID: LockScreenRotation.lockScreenID,
                currentStepID: stepA
            )
        )
    }
}
