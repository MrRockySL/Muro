import XCTest
@testable import MuroKit

/// #58: a picture set in System Settings or Finder takes the lock screen with
/// it, and Muro went on saying "Applied".
///
/// The first case is the owner's Mac on 2026-10-26, a MacBook and a DELL, read
/// back after a picture was set on the MacBook alone.
final class LockScreenReplacementTests: XCTestCase {
    let muro = "com.mrrockysl.muro.wallpaper-extension"
    let picture = "com.apple.wallpaper.choice.image"
    let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    let dell = "C4497200-61AC-4C2C-B727-10348E552634"

    let muroApplied = Date(timeIntervalSince1970: 1_791_000_000)
    let pictureSet = Date(timeIntervalSince1970: 1_792_992_899)

    func surface(_ provider: String, _ setAt: Date?) -> [String: Any] {
        var surface: [String: Any] = [
            "Content": ["Choices": [["Provider": provider]], "Shuffle": "$null"]
        ]
        if let setAt { surface["LastSet"] = setAt }
        return surface
    }

    func individual(_ provider: String, _ setAt: Date?) -> [String: Any] {
        [
            "Type": "individual",
            "Desktop": surface(provider, setAt),
            "Idle": surface(muro, muroApplied),
        ]
    }

    /// The shape measured on the owner's Mac: the MacBook's own nodes in the
    /// current Space and outside the Spaces, plus the two shared ones, hold
    /// the picture. Another Space's MacBook node and every DELL node kept Muro.
    var afterPictureOnMacBook: Any {
        [
            "SystemDefault": individual(picture, pictureSet),
            "Displays": [macBook: individual(picture, pictureSet)],
            "Spaces": [
                "": [
                    "Default": individual(picture, pictureSet),
                    "Displays": [
                        macBook: individual(picture, pictureSet),
                        dell: individual(muro, muroApplied),
                    ],
                ],
                "4BAA362B-16C2-D9E9-DB0B-4088B8B3B946": [
                    "Default": individual(muro, muroApplied),
                    "Displays": [
                        macBook: individual(muro, muroApplied),
                        dell: individual(muro, muroApplied),
                    ],
                ],
            ],
        ]
    }

    // MARK: The bug

    func testAPictureOnTheMacBookReplacesOnlyTheMacBooksLockScreen() {
        let replaced = LockScreenReplacement.replacedDisplays(
            claimed: [macBook, dell],
            store: afterPictureOnMacBook,
            provider: muro,
            desktopPictures: [:]
        )
        XCTAssertEqual(replaced, [macBook])
    }

    /// The shared nodes changed too, and they say nothing about the DELL,
    /// which has nodes of its own.
    func testTheDellIsAnsweredByItsOwnNodesNotTheSharedOnes() {
        let latest = LockScreenReplacement.latestDesktopChoice(
            forDisplay: dell, in: afterPictureOnMacBook
        )
        XCTAssertEqual(latest?.providers, [muro])
    }

    func testTheNewestChoiceWinsOverOlderSpaces() {
        let latest = LockScreenReplacement.latestDesktopChoice(
            forDisplay: macBook, in: afterPictureOnMacBook
        )
        XCTAssertEqual(latest, .init(providers: [picture], setAt: pictureSet))
    }

    // MARK: Two witnesses

    /// While macOS names one of the extension's own files as the picture,
    /// Muro is still there, whatever the store says.
    func testMacOSNamingTheExtensionsFileKeepsTheLockScreen() {
        let staged = URL(fileURLWithPath:
            "/Users/x/Library/Containers/\(muro)/Data/Documents/videos/bf0a4e85/wallpaper.mov")
        let replaced = LockScreenReplacement.replacedDisplays(
            claimed: [macBook],
            store: afterPictureOnMacBook,
            provider: muro,
            desktopPictures: [macBook: staged]
        )
        XCTAssertTrue(replaced.isEmpty)
    }

    func testMacOSNamingThePictureAgreesWithTheStore() {
        let cyan = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors/Cyan.png")
        let replaced = LockScreenReplacement.replacedDisplays(
            claimed: [macBook],
            store: afterPictureOnMacBook,
            provider: muro,
            desktopPictures: [macBook: cyan]
        )
        XCTAssertEqual(replaced, [macBook])
    }

    /// The store is the other witness: a picture named by macOS is not enough
    /// while Muro's choice is the newest, as it is just after an apply.
    func testMuroSetAgainAfterThePictureIsNotReplaced() {
        let later = pictureSet.addingTimeInterval(60)
        let store: Any = [
            "Displays": [macBook: individual(muro, later)],
            "Spaces": ["": ["Displays": [macBook: individual(picture, pictureSet)]]],
        ]
        let stale = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors/Cyan.png")
        let replaced = LockScreenReplacement.replacedDisplays(
            claimed: [macBook],
            store: store,
            provider: muro,
            desktopPictures: [macBook: stale]
        )
        XCTAssertTrue(replaced.isEmpty)
    }

    // MARK: Which displays

    func testADisplayMuroDoesNotClaimIsNeverReturned() {
        let replaced = LockScreenReplacement.replacedDisplays(
            claimed: [dell],
            store: afterPictureOnMacBook,
            provider: muro,
            desktopPictures: [:]
        )
        XCTAssertTrue(replaced.isEmpty)
    }

    /// A Mac that has never had a wallpaper per screen keeps it in the shared
    /// nodes, and there they answer.
    func testADisplayWithNoNodesIsAnsweredByTheSharedOnes() {
        let store: Any = [
            "AllSpacesAndDisplays": individual(picture, pictureSet),
            "SystemDefault": individual(muro, muroApplied),
        ]
        XCTAssertEqual(
            LockScreenReplacement.replacedDisplays(
                claimed: [macBook], store: store, provider: muro, desktopPictures: [:]
            ),
            [macBook]
        )
    }

    // MARK: Node shapes

    /// A linked node keeps the lock screen on `Linked`.
    func testAPictureInALinkedNodeReplacesTheLockScreen() {
        let store: Any = [
            "Displays": [macBook: ["Type": "linked", "Linked": surface(picture, pictureSet)]]
        ]
        XCTAssertEqual(
            LockScreenReplacement.replacedDisplays(
                claimed: [macBook], store: store, provider: muro, desktopPictures: [:]
            ),
            [macBook]
        )
    }

    /// An `idle` node is the screen saver only and says nothing about the
    /// lock screen, however new it is.
    func testAScreenSaverOnlyNodeIsIgnored() {
        let store: Any = [
            "Displays": [macBook: individual(muro, muroApplied)],
            "Spaces": ["": ["Displays": [macBook: ["Type": "idle", "Idle": surface(picture, pictureSet)]]]],
        ]
        XCTAssertTrue(
            LockScreenReplacement.replacedDisplays(
                claimed: [macBook], store: store, provider: muro, desktopPictures: [:]
            ).isEmpty
        )
    }

    func testAChoiceWithADateBeatsOneWithout() {
        let store: Any = [
            "Displays": [macBook: individual(picture, nil)],
            "Spaces": ["": ["Displays": [macBook: individual(muro, muroApplied)]]],
        ]
        XCTAssertEqual(
            LockScreenReplacement.latestDesktopChoice(forDisplay: macBook, in: store)?.providers,
            [muro]
        )
    }

    func testAnEmptyOrUnreadableStoreReplacesNothing() {
        for store: Any? in [nil, [String: Any]()] {
            XCTAssertTrue(
                LockScreenReplacement.replacedDisplays(
                    claimed: [macBook], store: store, provider: muro, desktopPictures: [:]
                ).isEmpty
            )
        }
    }

    // MARK: The record

    func testLettingGoUnderAllLeavesAnOptOut() {
        let next = LockScreenSelections.afterReplacedByMacOS(
            current: ["all": "miles", macBook: "miles"],
            displays: [macBook],
            removedMarker: "__none__"
        )
        XCTAssertEqual(next, ["all": "miles", macBook: "__none__"])
    }

    func testLettingGoOfADisplaysOwnLockScreenRemovesIt() {
        let next = LockScreenSelections.afterReplacedByMacOS(
            current: [macBook: "miles", dell: "camper"],
            displays: [macBook],
            removedMarker: "__none__"
        )
        XCTAssertEqual(next, [dell: "camper"])
    }

    /// Setting it again on every display is the way back, and it clears the
    /// opt-out the way it always has.
    func testApplyingToEveryDisplayAgainClearsTheOptOut() {
        let letGo = LockScreenSelections.afterReplacedByMacOS(
            current: ["all": "miles"],
            displays: [macBook],
            removedMarker: "__none__"
        )
        let again = LockScreenSelections.afterApply(
            current: letGo, targetKey: "all", wallpaperID: "miles",
            connectedDisplays: [macBook, dell]
        )
        XCTAssertEqual(again, ["all": "miles"])
    }
}
