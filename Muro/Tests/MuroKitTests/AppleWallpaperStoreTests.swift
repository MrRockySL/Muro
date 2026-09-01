import XCTest
@testable import MuroKit

/// Issue #11: the lock screen kept showing Apple's wallpaper on macOS 26.
///
/// None of this can be tried on the machine it was written on. That Mac runs
/// macOS 27 and has never once held a linked node, so every shape below is
/// rebuilt from what the three reporters actually pasted into the issue, and
/// the assertions are the only proof the fix does what it claims.
final class AppleWallpaperStoreTests: XCTestCase {
    private let muro = "com.mrrockysl.muro.wallpaper-extension"

    private func choice(_ id: String) -> [String: Any] {
        ["Provider": muro, "Files": [["relative": "file:///v/\(id).mov"]], "Configuration": Data(id.utf8)]
    }

    private func surface(provider: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider]], "Shuffle": "$null"]]
    }

    private func providers(_ node: Any?, _ key: String) -> [String] {
        guard let node = node as? [String: Any], let s = node[key] as? [String: Any] else { return [] }
        return AppleWallpaperStore.providers(of: s)
    }

    // MARK: - The rule itself

    func testSurfaceNameFollowsType() {
        XCTAssertEqual(AppleWallpaperStore.desktopSurfaceName(of: ["Type": "linked"]), "Linked")
        XCTAssertEqual(AppleWallpaperStore.desktopSurfaceName(of: ["Type": "individual"]), "Desktop")
        XCTAssertEqual(AppleWallpaperStore.desktopSurfaceName(of: ["Type": "desktop"]), "Desktop")
        XCTAssertEqual(AppleWallpaperStore.desktopSurfaceName(of: [:]), "Desktop")
    }

    /// The screen saver is not ours to take.
    func testIdleOnlyNodeIsRefused() {
        XCTAssertNil(AppleWallpaperStore.desktopSurfaceName(of: ["Type": "idle"]))
    }

    // MARK: - kernelpanic-root, the reported failure

    /// His store: one node, `Type = linked`, wallpaper under `Linked`.
    /// The old code wrote `Desktop` here, which macOS never reads.
    func testLinkedNodeGetsLinkedNotDesktop() {
        var store: Any = [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": surface(provider: "aerials")]
        ]
        let written = AppleWallpaperStore.applyChoice(choice("abc"), to: &store, targetKey: "all")

        XCTAssertEqual(written, 1)
        let node = (store as? [String: Any])?["AllSpacesAndDisplays"]
        XCTAssertEqual(providers(node, "Linked"), [muro], "the wallpaper must land under Linked")
        XCTAssertNil((node as? [String: Any])?["Desktop"], "no stray Desktop key on a linked node")
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node as! [String: Any]))
    }

    /// And the apply must then read back as done. The old check looked only at
    /// `Desktop`, so a correct write reported itself as a failure.
    func testLinkedWriteIsSeenBySelectionCheck() {
        var store: Any = ["SystemDefault": ["Type": "linked", "Linked": surface(provider: "aerials")]]
        XCTAssertFalse(AppleWallpaperStore.containsProvider(muro, in: store))
        AppleWallpaperStore.applyChoice(choice("abc"), to: &store, targetKey: "all")
        XCTAssertTrue(AppleWallpaperStore.containsProvider(muro, in: store))
    }

    // MARK: - The developer's own Mac, which already worked

    /// macOS 27, every node `individual` with both surfaces. Behaviour here
    /// must not change: this is the one shape known to work today.
    func testIndividualNodeStillGetsDesktopAndIdleIsUntouched() {
        var store: Any = [
            "SystemDefault": [
                "Type": "individual",
                "Desktop": surface(provider: "aerials"),
                "Idle": surface(provider: "default"),
            ]
        ]
        let written = AppleWallpaperStore.applyChoice(choice("abc"), to: &store, targetKey: "all")

        XCTAssertEqual(written, 1)
        let node = (store as? [String: Any])?["SystemDefault"]
        XCTAssertEqual(providers(node, "Desktop"), [muro])
        XCTAssertEqual(providers(node, "Idle"), ["default"], "the screen saver stays the user's")
        XCTAssertNil((node as? [String: Any])?["Linked"])
    }

    /// An `idle` node sits beside the others on that Mac and must be skipped.
    func testIdleNodeIsLeftAloneWhileOthersAreWritten() {
        var store: Any = [
            "AllSpacesAndDisplays": ["Type": "idle", "Idle": surface(provider: "default")],
            "SystemDefault": [
                "Type": "individual",
                "Desktop": surface(provider: "aerials"),
                "Idle": surface(provider: "default"),
            ],
        ]
        let written = AppleWallpaperStore.applyChoice(choice("abc"), to: &store, targetKey: "all")

        XCTAssertEqual(written, 1, "only the individual node is ours")
        let idle = (store as? [String: Any])?["AllSpacesAndDisplays"]
        XCTAssertEqual(providers(idle, "Idle"), ["default"])
        XCTAssertNil((idle as? [String: Any])?["Desktop"])
    }

    // MARK: - aptonline, the malformed node

    /// His node claims `individual` but carries only a `Desktop`, a shape that
    /// cannot exist. Muro built it, and macOS never asked his extension for a
    /// single frame.
    func testCreatedNodeIsWellFormed() {
        let node = AppleWallpaperStore.makeNode(
            choice: choice("abc"),
            desktopFallback: surface(provider: "default"),
            idleFallback: surface(provider: "default")
        )
        XCTAssertEqual(node["Type"] as? String, "individual")
        XCTAssertEqual(providers(node, "Desktop"), [muro])
        XCTAssertNotNil(node["Idle"], "individual promises an Idle, so there must be one")
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node))
    }

    func testTheOldMalformedShapeIsRecognisedAsWrong() {
        XCTAssertFalse(AppleWallpaperStore.isWellFormed([
            "Type": "individual", "Desktop": surface(provider: "muro"),
        ]))
        XCTAssertFalse(AppleWallpaperStore.isWellFormed([
            "Type": "linked", "Desktop": surface(provider: "muro"),
        ]))
    }

    // MARK: - nodeApplying

    /// A node's own `Type` is the user's arrangement of their desktop and lock
    /// screen. Muro must never quietly relink or unlink them.
    func testNodeApplyingNeverRewritesAnExistingType() {
        let node = AppleWallpaperStore.nodeApplying(
            choice: choice("abc"),
            to: ["Type": "linked", "Linked": surface(provider: "aerials")],
            desktopFallback: surface(provider: "default"),
            idleFallback: surface(provider: "default")
        )
        XCTAssertEqual(node["Type"] as? String, "linked")
        XCTAssertEqual(providers(node, "Linked"), [muro])
    }

    /// The one exception: a screen-saver-only node has to gain a desktop
    /// surface before it can hold one, and must then say so.
    func testIdleOnlyNodeGainsADesktopAndSaysSo() {
        let node = AppleWallpaperStore.nodeApplying(
            choice: choice("abc"),
            to: ["Type": "idle", "Idle": surface(provider: "default")],
            desktopFallback: surface(provider: "default"),
            idleFallback: surface(provider: "default")
        )
        XCTAssertEqual(node["Type"] as? String, "individual")
        XCTAssertEqual(providers(node, "Desktop"), [muro])
        XCTAssertEqual(providers(node, "Idle"), ["default"])
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node))
    }

    // MARK: - Targeting one display

    func testASingleDisplayTargetLeavesTheOthersAlone() {
        let uuid = "AAAA-1111"
        var store: Any = [
            "Displays": [
                uuid: ["Type": "individual", "Desktop": surface(provider: "aerials"), "Idle": surface(provider: "default")],
                "BBBB-2222": ["Type": "individual", "Desktop": surface(provider: "aerials"), "Idle": surface(provider: "default")],
            ]
        ]
        let written = AppleWallpaperStore.applyChoice(choice("abc"), to: &store, targetKey: uuid)

        XCTAssertEqual(written, 1)
        let displays = (store as? [String: Any])?["Displays"] as? [String: Any]
        XCTAssertEqual(providers(displays?[uuid], "Desktop"), [muro])
        XCTAssertEqual(providers(displays?["BBBB-2222"], "Desktop"), ["aerials"], "the other display is untouched")
    }

    // MARK: - Walking

    /// A `Content` dictionary is not a node, however deep the tree goes.
    func testContentIsNeverMistakenForANode() {
        let store: Any = [
            "Spaces": ["S1": ["Default": [
                "Type": "individual",
                "Desktop": ["Content": ["Choices": [["Provider": "aerials", "Desktop": ["x": 1]]]]],
                "Idle": surface(provider: "default"),
            ]]]
        ]
        var count = 0
        AppleWallpaperStore.forEachNode(in: store) { _, _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testEmptyAndOddInputsDoNotCrash() {
        var empty: Any = [String: Any]()
        XCTAssertEqual(AppleWallpaperStore.applyChoice(choice("a"), to: &empty, targetKey: "all"), 0)
        var notADictionary: Any = [1, 2, 3]
        XCTAssertEqual(AppleWallpaperStore.applyChoice(choice("a"), to: &notADictionary, targetKey: "all"), 0)
        XCTAssertFalse(AppleWallpaperStore.containsProvider(muro, in: nil))
    }

    /// Applying twice must not pile up choices or duplicate surfaces.
    func testApplyingTwiceIsStable() {
        var store: Any = ["SystemDefault": ["Type": "linked", "Linked": surface(provider: "aerials")]]
        AppleWallpaperStore.applyChoice(choice("one"), to: &store, targetKey: "all")
        AppleWallpaperStore.applyChoice(choice("two"), to: &store, targetKey: "all")
        let node = (store as? [String: Any])?["SystemDefault"] as? [String: Any]
        let choices = ((node?["Linked"] as? [String: Any])?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
        XCTAssertEqual(choices?.count, 1)
        XCTAssertEqual(choices?.first?["Configuration"] as? Data, Data("two".utf8))
    }
}
