import XCTest
@testable import MuroKit

/// System Settings → Wallpaper → Screen Saver → "Use Screen Saver: Automatic".
///
/// On that setting macOS keeps one `linked` key for the desktop, the lock
/// screen and the screen saver, and a new Mac starts that way: the full check
/// of 2026-10-01 rebuilt Apple's store from nothing on macOS 27.0.1 and got
/// exactly the fresh store below. Muro's places are separate, so before it
/// writes one of them the Mac is switched to Custom, and these tests hold the
/// three places apart on such a store.
final class AutomaticScreenSaverTests: XCTestCase {
    private let muro = "com.mrrockysl.muro.wallpaper-extension"
    private let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

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

    /// What macOS 27.0.1 wrote when its store was rebuilt from nothing.
    private func freshAutomaticStore() -> Any {
        [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": surface(provider: "default")],
            "SystemDefault": ["Type": "linked", "Linked": surface(provider: "default")],
            "Spaces": [String: Any](),
            "Displays": [String: Any](),
        ]
    }

    private func node(_ store: Any, _ path: [String]) -> [String: Any]? {
        var current = store
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component]
            else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    private func providers(_ store: Any, _ path: [String], _ key: String) -> [String] {
        guard let surface = node(store, path)?[key] as? [String: Any] else { return [] }
        return AppleWallpaperStore.providers(of: surface)
    }

    /// The two writes Muro makes, Automatic switched to Custom first.
    private func set(
        _ id: String,
        _ role: AppleWallpaperStore.Surface,
        on store: inout Any,
        target: String = "all"
    ) {
        AppleWallpaperStore.unlinkNodes(in: &store)
        AppleWallpaperStore.applyChoiceCreatingNode(
            choice(id),
            to: &store,
            targetKey: target,
            surface: role,
            desktopFallback: surface(provider: "apple.desktop"),
            idleFallback: surface(provider: "apple.idle")
        )
    }

    // MARK: - The switch itself

    func testALinkedNodeBecomesAWellFormedIndividualOneShowingTheSameWallpaper() throws {
        let linked: [String: Any] = ["Type": "linked", "Linked": surface(provider: "default")]
        let individual = try XCTUnwrap(AppleWallpaperStore.unlinked(linked))

        XCTAssertEqual(individual["Type"] as? String, "individual")
        XCTAssertNil(individual["Linked"])
        XCTAssertEqual(AppleWallpaperStore.providers(of: individual["Desktop"] as? [String: Any] ?? [:]), ["default"])
        XCTAssertEqual(AppleWallpaperStore.providers(of: individual["Idle"] as? [String: Any] ?? [:]), ["default"])
        XCTAssertTrue(AppleWallpaperStore.isWellFormed(individual))
    }

    /// The owner's own Mac is on Custom: an `idle` node for the screen saver
    /// and `individual` nodes everywhere else. Not one of them may change.
    func testAMacAlreadyOnCustomIsLeftExactlyAsItWas() {
        let custom: [String: Any] = [
            "AllSpacesAndDisplays": ["Type": "idle", "Idle": surface(provider: muro)],
            "SystemDefault": [
                "Type": "individual",
                "Desktop": surface(provider: muro),
                "Idle": surface(provider: muro),
            ],
            "Displays": [
                macBook: [
                    "Type": "individual",
                    "Desktop": surface(provider: "apple.desktop"),
                    "Idle": surface(provider: muro),
                ],
            ],
        ]
        var store: Any = custom

        XCTAssertEqual(AppleWallpaperStore.unlinkNodes(in: &store), 0)
        XCTAssertEqual(store as? NSDictionary, custom as NSDictionary)
    }

    func testSwitchingTwiceChangesNothingTheSecondTime() {
        var store = freshAutomaticStore()
        XCTAssertEqual(AppleWallpaperStore.unlinkNodes(in: &store), 2)
        let once = store
        XCTAssertEqual(AppleWallpaperStore.unlinkNodes(in: &store), 0)
        XCTAssertEqual(store as? NSDictionary, once as? NSDictionary)
    }

    func testOddNodesAreLeftAlone() {
        // Says linked but carries nothing to split: not ours to guess at.
        XCTAssertNil(AppleWallpaperStore.unlinked(["Type": "linked"]))
        XCTAssertNil(AppleWallpaperStore.unlinked(["Linked": surface(provider: "default")]))
        var junk: Any = ["Displays": "not a dictionary"]
        XCTAssertEqual(AppleWallpaperStore.unlinkNodes(in: &junk), 0)
    }

    // MARK: - The places stay apart on a new Mac

    /// The bug the full check found: a screen saver set on a new Mac changed
    /// the desktop and the lock screen too.
    func testTheScreenSaverNoLongerChangesTheLockScreen() {
        var store = freshAutomaticStore()
        set("saver", .screenSaver, on: &store)

        for path in [["AllSpacesAndDisplays"], ["SystemDefault"]] {
            XCTAssertEqual(providers(store, path, "Idle"), [muro], "\(path)")
            XCTAssertEqual(providers(store, path, "Desktop"), ["default"], "the lock screen moved at \(path)")
            XCTAssertNil(node(store, path)?["Linked"])
            XCTAssertTrue(AppleWallpaperStore.isWellFormed(node(store, path) ?? [:]))
        }
    }

    /// The other direction: a lock screen set for the MacBook, which has no
    /// node of its own on a new Mac, so it lands on the shared nodes.
    func testTheLockScreenNoLongerChangesTheScreenSaver() {
        var store = freshAutomaticStore()
        set("lock", .desktop, on: &store, target: macBook)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Desktop"), [muro])
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), ["default"])
    }

    func testTheLockScreenAndTheScreenSaverCanHoldDifferentWallpapers() {
        var store = freshAutomaticStore()
        set("lock", .desktop, on: &store, target: macBook)
        set("saver", .screenSaver, on: &store)

        let shared = node(store, ["AllSpacesAndDisplays"])
        XCTAssertEqual(
            (shared?["Desktop"] as? [String: Any]).flatMap { ($0["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] }?
                .first?["Configuration"] as? Data,
            Data("lock".utf8)
        )
        XCTAssertEqual(
            (shared?["Idle"] as? [String: Any]).flatMap { ($0["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] }?
                .first?["Configuration"] as? Data,
            Data("saver".utf8)
        )
    }

    /// "All" in Muro is the two writes one after the other. On a new Mac it
    /// ends with the same wallpaper in both places, on Custom.
    func testAllEndsWithTheSameWallpaperInBothPlaces() {
        var store = freshAutomaticStore()
        set("one", .desktop, on: &store)
        set("one", .screenSaver, on: &store)

        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Desktop"), [muro])
        XCTAssertEqual(providers(store, ["AllSpacesAndDisplays"], "Idle"), [muro])
        XCTAssertTrue(AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .desktop))
        XCTAssertTrue(AppleWallpaperStore.holdsRole(muro, in: store, targetKey: "all", surface: .screenSaver))
    }

    // MARK: - Removing gives back what was there

    func testASplitNodeIsRestoredFromTheLinkedWallpaperInTheBackup() {
        let backup: Any = [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": surface(provider: "their.aerial")],
        ]
        let desktop = AppleWallpaperStore.linkedSurface(splitAt: ["AllSpacesAndDisplays", "Desktop"], in: backup)
        let idle = AppleWallpaperStore.linkedSurface(splitAt: ["AllSpacesAndDisplays", "Idle"], in: backup)

        XCTAssertEqual(AppleWallpaperStore.providers(of: desktop ?? [:]), ["their.aerial"])
        XCTAssertEqual(AppleWallpaperStore.providers(of: idle ?? [:]), ["their.aerial"])
    }

    /// A node that was never linked keeps its own backup surface, so nothing
    /// about removing on a Custom Mac changes.
    func testANodeThatWasNeverLinkedIsNotAnsweredHere() {
        let backup: Any = [
            "AllSpacesAndDisplays": [
                "Type": "individual",
                "Desktop": surface(provider: "apple.desktop"),
                "Idle": surface(provider: "apple.idle"),
            ],
        ]
        XCTAssertNil(AppleWallpaperStore.linkedSurface(splitAt: ["AllSpacesAndDisplays", "Desktop"], in: backup))
        XCTAssertNil(AppleWallpaperStore.linkedSurface(splitAt: ["AllSpacesAndDisplays", "Idle"], in: backup))
        XCTAssertNil(AppleWallpaperStore.linkedSurface(splitAt: ["AllSpacesAndDisplays", "Linked"], in: backup))
        XCTAssertNil(AppleWallpaperStore.linkedSurface(splitAt: ["Displays", macBook, "Desktop"], in: backup))
    }
}
