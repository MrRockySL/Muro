import XCTest
@testable import MuroKit

/// Issue #18: the screen saver.
///
/// The screen saver is Apple's `Idle` key, which is a different key from the
/// one the lock screen renders. Everything here is about keeping those two
/// apart: setting one must not disturb the other, and removing one must not
/// take the other with it. The exception is a `linked` node, where macOS
/// itself keeps both on one key, and that is asserted rather than worked
/// around.
///
/// Like `AppleWallpaperStoreTests`, none of the linked shapes can be produced
/// on the machine this was written on, so the assertions are the proof.
final class ScreenSaverSurfaceTests: XCTestCase {
    private let muro = "com.mrrockysl.muro.wallpaper-extension"

    private func choice(_ id: String) -> [String: Any] {
        [
            "Provider": muro,
            "Files": [["relative": "file:///v/\(id).mov"]],
            "Configuration": Data(id.utf8),
        ]
    }

    private func surface(provider: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider]], "Shuffle": "$null"]]
    }

    private func providers(_ store: Any, _ path: [String], _ key: String) -> [String] {
        var current = store
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component]
            else { return [] }
            current = next
        }
        guard let node = current as? [String: Any],
              let surface = node[key] as? [String: Any]
        else { return [] }
        return AppleWallpaperStore.providers(of: surface)
    }

    private func apply(
        _ id: String,
        _ role: AppleWallpaperStore.Surface,
        to store: inout Any,
        target: String = "all"
    ) {
        AppleWallpaperStore.applyChoiceCreatingNode(
            choice(id),
            to: &store,
            targetKey: target,
            surface: role,
            desktopFallback: surface(provider: "apple.desktop"),
            idleFallback: surface(provider: "apple.idle")
        )
    }

    // MARK: - Which key each role lands on

    func testTheScreenSaverIsIdleOnAnIndividualNode() {
        let node: [String: Any] = ["Type": "individual"]
        XCTAssertEqual(AppleWallpaperStore.surfaceName(of: node, for: .screenSaver), "Idle")
        XCTAssertEqual(AppleWallpaperStore.surfaceName(of: node, for: .desktop), "Desktop")
    }

    /// A linked Mac keeps one wallpaper for both. That is what linking means,
    /// so both roles answer with the same key rather than one of them failing.
    func testALinkedNodeGivesBothRolesTheSameKey() {
        let node: [String: Any] = ["Type": "linked"]
        XCTAssertEqual(AppleWallpaperStore.surfaceName(of: node, for: .desktop), "Linked")
        XCTAssertEqual(AppleWallpaperStore.surfaceName(of: node, for: .screenSaver), "Linked")
    }

    /// A screen-saver-only node has nowhere to put a desktop, and that has not
    /// changed. It is now a perfectly good home for a screen saver.
    func testAnIdleOnlyNodeTakesTheScreenSaverButNotTheDesktop() {
        let node: [String: Any] = ["Type": "idle"]
        XCTAssertNil(AppleWallpaperStore.surfaceName(of: node, for: .desktop))
        XCTAssertEqual(AppleWallpaperStore.surfaceName(of: node, for: .screenSaver), "Idle")
    }

    func testTheDesktopShorthandStillAnswersExactlyAsBefore() {
        for type in ["linked", "individual", "desktop", "idle"] {
            let node: [String: Any] = ["Type": type]
            XCTAssertEqual(
                AppleWallpaperStore.desktopSurfaceName(of: node),
                AppleWallpaperStore.surfaceName(of: node, for: .desktop),
                "the shorthand drifted from the rule for \(type)"
            )
        }
    }

    // MARK: - Setting one does not disturb the other

    func testTheScreenSaverGoesToIdleAndLeavesTheLockScreenAlone() {
        var store: Any = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": surface(provider: muro),
                "Idle": surface(provider: "apple.idle"),
            ],
        ]
        apply("saver", .screenSaver, to: &store)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertEqual(
            providers(store, ["AllSpacesAndDisplays"], "Desktop"), [muro],
            "the lock screen's own key must be untouched"
        )
    }

    func testSettingTheLockScreenLeavesAnAppliedScreenSaverAlone() {
        var store: Any = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": surface(provider: "apple.desktop"),
                "Idle": surface(provider: muro),
            ],
        ]
        apply("lock", .desktop, to: &store)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Desktop"), [muro])
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
    }

    /// Both roles on one Mac, applied one after the other, is the case a user
    /// reaches by picking "All".
    func testBothRolesCanBeMuroAtOnce() {
        var store: Any = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": surface(provider: "apple.desktop"),
                "Idle": surface(provider: "apple.idle"),
            ],
        ]
        apply("one", .desktop, to: &store)
        apply("one", .screenSaver, to: &store)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Desktop"), [muro])
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertTrue(AppleWallpaperStore.containsProvider(muro, in: store))
    }

    // MARK: - Nodes that have never had a screen saver

    /// A node typed `desktop` has no `Idle` at all. It gains one, and it says
    /// so: a node carrying both keys is an individual one, and leaving `Type`
    /// on `desktop` would describe a shape it no longer has.
    func testADesktopOnlyNodeGainsAnIdleAndSaysSo() {
        var store: Any = [
            "AllSpacesAndDisplays": [
                "Type": "desktop",
                "Desktop": surface(provider: "apple.desktop"),
            ],
        ]
        apply("saver", .screenSaver, to: &store)

        let node = (store as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertEqual(node?["Type"] as? String, "individual")
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node ?? [:]))
    }

    /// An untyped node is left untyped. Nothing recorded how that Mac is
    /// arranged, so nothing may claim to.
    func testAnUntypedNodeGainsAnIdleWithoutGainingAType() {
        var store: Any = [
            "AllSpacesAndDisplays": ["Desktop": surface(provider: "apple.desktop")],
        ]
        apply("saver", .screenSaver, to: &store)

        let node = (store as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertNil(node?["Type"])
    }

    /// A store with no node at all still gets one, and it is well formed: the
    /// screen saver is ours and the desktop is left to the system.
    func testAnEmptyStoreGetsAWellFormedScreenSaverNode() {
        var store: Any = [String: Any]()
        apply("saver", .screenSaver, to: &store)

        let node = (store as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Desktop"), ["apple.desktop"])
        XCTAssertEqual(node?["Type"] as? String, "individual")
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node ?? [:]))
    }

    // MARK: - The linked Mac from issue #11

    /// On a linked Mac the screen saver lands on `Linked`, which is also the
    /// desktop. There is no second key to write and inventing one would put
    /// the wallpaper where macOS never looks, which is the whole of #11.
    func testOnALinkedMacTheScreenSaverWritesLinked() {
        var store: Any = [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": surface(provider: "apple")],
        ]
        apply("saver", .screenSaver, to: &store)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Linked"), [muro])
        let node = (store as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        XCTAssertNil(node?["Idle"], "a linked node must not grow a second key")
        XCTAssertEqual(node?["Type"] as? String, "linked", "the user's arrangement is not ours")
    }

    // MARK: - Targets and repeats

    func testASingleDisplayScreenSaverLeavesTheOtherDisplayAlone() {
        var store: Any = [
            "Displays": [
                "AAA": [
                    "Type": "individual",
                    "Desktop": surface(provider: "apple.desktop"),
                    "Idle": surface(provider: "apple.idle"),
                ],
                "BBB": [
                    "Type": "individual",
                    "Desktop": surface(provider: "apple.desktop"),
                    "Idle": surface(provider: "apple.idle"),
                ],
            ],
        ]
        apply("saver", .screenSaver, to: &store, target: "AAA")

        XCTAssertEqual(providers(store, ["Displays", "AAA"], "Idle"), [muro])
        XCTAssertEqual(providers(store, ["Displays", "BBB"], "Idle"), ["apple.idle"])
    }

    func testApplyingTheScreenSaverTwiceIsStable() {
        var first: Any = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": surface(provider: "apple.desktop"),
                "Idle": surface(provider: "apple.idle"),
            ],
        ]
        apply("saver", .screenSaver, to: &first)
        var second = first
        apply("saver", .screenSaver, to: &second)

        XCTAssertEqual(providers(second, ["AllSpacesAndDisplays"], "Idle"), [muro])
        let node = (second as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(node ?? [:]))
    }

    func testEmptyAndOddInputsDoNotCrash() {
        var nothing: Any = [String: Any]()
        apply("saver", .screenSaver, to: &nothing, target: "AAA")
        var junk: Any = ["Displays": "not a dictionary"]
        apply("saver", .screenSaver, to: &junk)
        var nested: Any = ["A": ["B": ["C": [String: Any]()]]]
        apply("saver", .screenSaver, to: &nested)
    }
}
