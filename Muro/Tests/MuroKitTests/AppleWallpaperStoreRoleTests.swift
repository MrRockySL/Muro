import XCTest
@testable import MuroKit

/// `holdsRole`, the check an apply needs and did not have.
///
/// Built from the exact shape the owner's Mac was in on 2026-09-10: Muro held
/// the screen saver in `Index2.plist` and Apple's default held it in
/// `Index.plist`, which is the file macOS reads. The old check asked "is Muro
/// anywhere in either file", got `true`, and stopped retrying.
final class AppleWallpaperStoreRoleTests: XCTestCase {
    let muro = "com.mrrockysl.muro.wallpaper-extension"
    let apple = "com.apple.wallpaper.choice.default"

    func surface(_ provider: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider]], "Shuffle": "$null"]]
    }

    /// One node carrying a desktop and a screen saver, each by whoever is named.
    func individual(desktop: String, idle: String) -> [String: Any] {
        ["Type": "individual", "Desktop": surface(desktop), "Idle": surface(idle)]
    }

    // MARK: The bug

    func testTheFileMacOSReadsIsSeenToBeMissingTheScreenSaver() {
        let store: Any = [
            "AllSpacesAndDisplays": individual(desktop: muro, idle: apple),
            "SystemDefault": individual(desktop: muro, idle: apple),
        ]
        // Muro is in the file, so the loose check is happy. That is the trap.
        XCTAssertTrue(AppleWallpaperStore.containsProvider(muro, in: store))
        // Asked per role, the truth comes out.
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .screenSaver)
        )
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .desktop)
        )
    }

    func testBothRolesHeldReadsAsHeld() {
        let store: Any = ["AllSpacesAndDisplays": individual(desktop: muro, idle: muro)]
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .screenSaver)
        )
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .desktop)
        )
    }

    func testAnEmptyOrUnreadableStoreHoldsNothing() {
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(muro, in: nil, targetKey: "all", surface: .screenSaver)
        )
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(
                muro, in: [String: Any](), targetKey: "all", surface: .screenSaver
            )
        )
    }

    // MARK: Node types

    /// A linked node keeps both roles on one key, so holding it holds both.
    func testALinkedNodeHoldsBothRoles() {
        let store: Any = ["AllSpacesAndDisplays": ["Type": "linked", "Linked": surface(muro)]]
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .desktop)
        )
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .screenSaver)
        )
    }

    /// An `idle` node is the screen saver and has no desktop at all, so it can
    /// never satisfy the desktop role however it is filled.
    func testAnIdleNodeNeverSatisfiesTheDesktopRole() {
        let store: Any = ["AllSpacesAndDisplays": ["Type": "idle", "Idle": surface(muro)]]
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .screenSaver)
        )
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .desktop)
        )
    }

    // MARK: Targets

    func testADisplayIsAnsweredByItsOwnNode() {
        let display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let other = "C4497200-61AC-4C2C-B727-10348E552634"
        let store: Any = [
            "Displays": [
                display: individual(desktop: muro, idle: muro),
                other: individual(desktop: apple, idle: apple),
            ]
        ]
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: display, surface: .desktop)
        )
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: other, surface: .desktop)
        )
    }

    /// A Mac that has never been given a wallpaper per screen keeps its one
    /// wallpaper in the shared node, and that node answers for every display.
    /// Without this a per-display apply would retry forever against a store
    /// that is already correct.
    func testASharedNodeAnswersForADisplayWithNoNodeOfItsOwn() {
        let display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let store: Any = ["AllSpacesAndDisplays": individual(desktop: muro, idle: muro)]
        XCTAssertTrue(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: display, surface: .desktop)
        )
    }

    func testAnotherDisplaysNodeDoesNotAnswerForThisOne() {
        let display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let other = "C4497200-61AC-4C2C-B727-10348E552634"
        let store: Any = ["Displays": [other: individual(desktop: muro, idle: muro)]]
        XCTAssertFalse(
            AppleWallpaperStore.holdsRole(muro, in: store, targetKey: display, surface: .desktop)
        )
    }
}
